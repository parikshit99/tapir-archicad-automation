# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

'''
Navigator Search
Based on Baaz, the command palette add-on by Parikshit Wadhwa
https://github.com/parikshit99/baaz

Type a few letters of a view name or a layout number and open it: the saved
views of the View Map and the layouts of the Layout Book are searched together,
ignoring case, punctuation and small typos (`a101`, `gfc mas`, `grnd flor`).
Enter (or a double-click) opens the selected result the way a double-click in
the Navigator does, including the view's saved layer combination and scale.
'''

import tkinter as tk
from tkinter import ttk

from utilities.archicad import ArchicadError, run_command, run_tapir
from utilities.navigator_utils import VIEW_NAVITEM_TYPES
from utilities.ui import ScriptWindow, make_tree, require_archicad

SCRIPT_NAME = "Navigator Search"
MAX_RESULTS = 50
FUZZ_THRESHOLD = 60.0  # a typo match scores up to 89, anything below is not shown

# The folders and clone folders of the trees are not openable; only these are.
OPENABLE = {
    "View": [t for t in VIEW_NAVITEM_TYPES if t != "CameraSetItem"] + ["PerspectiveItem", "AxonometryItem"],
    "Layout": ["LayoutItem"],
}
TREES = {"View": "ViewMap", "Layout": "LayoutBook"}


def tokenize(text: str) -> list[str]:
    """ Lower-cased alphanumeric runs; everything else separates tokens. """
    tokens, current = [], []
    for char in text:
        if char.isalnum():
            current.append(char.lower())
        elif current:
            tokens.append("".join(current))
            current = []
    if current:
        tokens.append("".join(current))
    return tokens


def edit_distance(a: str, b: str) -> int:
    """ Levenshtein distance where swapping two neighbouring letters counts as one edit. """
    rows = [[i] + [0] * len(b) for i in range(len(a) + 1)]
    rows[0] = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            rows[i][j] = min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost)
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                rows[i][j] = min(rows[i][j], rows[i - 2][j - 2] + 1)
    return rows[len(a)][len(b)]


def score(query: str, title: str) -> float:
    """ 0-100, the higher the better: exact match, contained in the title,
    every word a word prefix, and finally typo tolerant. """
    query_tokens, title_tokens = tokenize(query), tokenize(title)
    if not query_tokens or not title_tokens:
        return 0.0
    clean_query, clean_title = "".join(query_tokens), "".join(title_tokens)
    if clean_title == clean_query:
        return 95.0
    if len(clean_query) >= 2 and clean_query in clean_title:
        return 93.0
    if len(clean_query) == 1 and clean_title.startswith(clean_query):
        return 93.0
    if all(any(t.startswith(q) for t in title_tokens) for q in query_tokens):
        return 91.0
    total = 0.0
    for q in query_tokens:
        best = 0.0
        for t in title_tokens:
            longest = max(len(q), len(t))
            if (1.0 - abs(len(q) - len(t)) / longest) * 89.0 <= best:
                continue  # cannot beat the best so far
            best = max(best, (1.0 - edit_distance(q, t) / longest) * 89.0)
        total += best
    return total / len(query_tokens)


def search(query: str, items: list[dict], limit: int = MAX_RESULTS) -> list[dict]:
    """ The items matching the query, best first; all of them (in tree order) for an empty query. """
    if not query.strip():
        return items[:limit]
    scored = [(score(query, item["title"]), item) for item in items]
    scored = [(s, item) for s, item in scored if s >= FUZZ_THRESHOLD]
    scored.sort(key=lambda pair: (-pair[0], pair[1]["title"]))
    return [item for _, item in scored[:limit]]


def title_of(item: dict) -> str:
    """ The Navigator ID is part of the title, so sheets can be found by number (A.01). """
    prefix, name = item.get("prefix", "").strip(), item.get("name", "").strip()
    if not prefix or name.startswith(prefix):
        return name
    return f"{prefix} {name}"


def collect(branch: list[dict], kind: str, path: str, items: list[dict]) -> None:
    for wrapper in branch:
        node = wrapper["navigatorItem"]
        if node["type"] in OPENABLE[kind]:
            items.append({"title": title_of(node), "kind": kind, "path": path, "id": node["navigatorItemId"]})
        children = node.get("children")
        if children:
            folder = node.get("name", "")
            collect(children, kind, f"{path} / {folder}" if path and folder else folder or path, items)


class NavigatorSearch:
    def __init__(self):
        self.window = ScriptWindow(
            SCRIPT_NAME,
            "Type to find a view or layout, Enter opens it in Archicad. Up/Down moves the selection.",
            min_height=380)
        self.items: list[dict] = []
        self.results: list[dict] = []
        self._build_body()
        self.window.add_button("Reload list", self.window.guarded(self.load_items))
        self.window.add_button("Open", self.window.guarded(self.open_selected), primary=True)

    def _build_body(self) -> None:
        body = self.window.body
        body.rowconfigure(1, weight=1)
        self.query = tk.StringVar()
        self.entry = ttk.Entry(body, textvariable=self.query)
        self.entry.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        self.query.trace_add("write", lambda *_: self.show_results())
        self.entry.bind("<Down>", lambda _e: self.move(1))
        self.entry.bind("<Up>", lambda _e: self.move(-1))

        self.tree = make_tree(body, [
            ("title", "Name", 280, "w"),
            ("kind", "Type", 70, "w"),
            ("path", "Folder", 160, "w"),
        ], height=12)
        self.tree.container.grid(row=1, column=0, sticky="nsew")
        self.tree.bind("<Double-1>", lambda _e: self.window.guarded(self.open_selected)())

    def load_items(self) -> None:
        with self.window.busy("Reading the Navigator..."):
            self.items = []
            for kind, tree_type in TREES.items():
                tree = run_command("API.GetNavigatorItemTree", {"navigatorTreeId": {"type": tree_type}})
                root = tree["navigatorTree"]["rootItem"]
                collect(root.get("children", []), kind, "", self.items)
        self.show_results()
        self.window.set_status(f"{len(self.items)} views and layouts indexed.", "ok")

    def show_results(self) -> None:
        self.results = search(self.query.get(), self.items)
        self.tree.delete(*self.tree.get_children())
        for index, item in enumerate(self.results):
            self.tree.insert("", "end", iid=str(index), values=(item["title"], item["kind"], item["path"]))
        if self.results:
            self.tree.selection_set("0")
            self.tree.focus("0")

    def move(self, step: int) -> str:
        if self.results:
            current = self.tree.selection()
            index = min(max((int(current[0]) if current else -1) + step, 0), len(self.results) - 1)
            self.tree.selection_set(str(index))
            self.tree.focus(str(index))
            self.tree.see(str(index))
        return "break"

    def open_selected(self) -> None:
        selection = self.tree.selection()
        if not selection:
            self.window.set_status("Nothing to open.", "warning")
            return
        item = self.results[int(selection[0])]
        try:
            run_tapir("ChangeWindow", {"navigatorItemId": item["id"]})
        except ArchicadError as e:
            self.window.set_status(str(e), "error")
            return
        self.window.set_status(f"Opened {item['title']}.", "ok")

    def run(self) -> None:
        self.window.run(on_start=lambda: (self.entry.focus_set(), self.load_items()))


if __name__ == "__main__":
    require_archicad(SCRIPT_NAME)
    NavigatorSearch().run()
