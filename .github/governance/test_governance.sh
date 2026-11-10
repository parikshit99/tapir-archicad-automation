#!/usr/bin/env bash
# Tests for lib.sh on fixtures: no network. Run: bash .github/governance/test_governance.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok ()  { echo "ok   $1"; }
bad () { echo "FAIL $1"; shift; printf '     %s\n' "$@"; fail=1; }
eq ()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want: $3" "got:  $2"; fi; }

# A governance dir whose entries are ratified, so they are enforced.
mkdir "$T/gov"
jq '.decisions |= map(.ratified_by = ["maintainer"])' "$HERE/decisions.json" > "$T/gov/decisions.json"
jq '.out_of_scope |= map(.ratified_by = ["maintainer"])' "$HERE/scope.json" > "$T/gov/scope.json"
export GOV_DIR="$T/gov"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

f () { # f status filename deletions [patch]  -> one pulls/{n}/files entry
  jq -n --arg s "$1" --arg n "$2" --argjson d "$3" --arg p "${4-}" \
    '{status:$s, filename:$n, deletions:$d} + (if $p == "" then {} else {patch:$p} end)'
}
arr () { jq -s '.'; }

# ---- protected paths (the bots must not be able to edit their own direction)
for p in .github/governance/scope.json .github/governance/decisions.json CLAUDE.md AGENTS.md sub/SKILL.md \
         .claude/settings.json tools/x.py archicad-addon/devkits.json archicad-addon/CMakeLists.txt; do
  if printf '%s\n' "$p" | grep -qE "$GOV_PROTECTED"; then ok "protected: $p"; else bad "protected: $p"; fi
done
for p in archicad-addon/Sources/ElementCommands.cpp marketplace/x/script.py docs/index.html; do
  if printf '%s\n' "$p" | grep -qE "$GOV_PROTECTED"; then bad "not protected: $p"; else ok "not protected: $p"; fi
done

# ---- globs
eq "glob" "$(printf 'docs/*\n*.md\n' | gov_glob_re)" '^(docs/.*|.*\.md)$'
eq "empty glob list matches nothing" "$(printf 'x' | grep -cE "$(printf '' | gov_glob_re)")" 0

# ---- issue refs
eq "refs Fixes" "$(printf 'Fixes #12 and closes #3' | gov_issue_refs | jq -c .)" '[{"issue":3,"part":null},{"issue":12,"part":null}]'
eq "refs Part" "$(printf 'Part 2 of 4 of #9' | gov_issue_refs | jq -c .)" '[{"issue":9,"part":2}]'
eq "refs none" "$(printf 'no issue' | gov_issue_refs | jq -c .)" '[]'

# ---- add vs change
kind () { arr | gov_change_kind /dev/stdin | jq -r .kind; }
eq "new files are additive"   "$( { f added marketplace/x/script.py 0; f added archicad-addon/Examples/A/B.py 0; } | kind)" additive
eq "pure-addition edit"       "$( { f modified archicad-addon/Sources/AddOnMain.cpp 0; } | kind)" additive
eq "deleted lines = change"   "$( { f modified archicad-addon/Sources/ElementCommands.cpp 3; } | kind)" change
eq "removed file = change"    "$( { f removed archicad-addon/Sources/Old.cpp 20; } | kind)" change
eq "renamed file = change"    "$( { jq -n '{status:"renamed",filename:"a/b.cpp",previous_filename:"a/c.cpp",deletions:0}'; } | kind)" change
eq "docs edits do not count"  "$( { f modified docs/x.html 40; f modified README.md 5; f modified archicad-addon/Test/t.py 9; } | kind)" additive
eq "editing a marketplace script = change" "$( { f modified marketplace/x/script.py 0; } | kind)" change
eq "editing builtin-scripts = change"      "$( { f modified builtin-scripts/a.py 0; } | kind)" change

# ---- scope and decisions: only ratified entries are enforced
{ f modified grasshopper-plugin/TapirGrasshopperPlugin/Components/DesignToolsComponents/Walls.cs 2; } | arr > "$T/dk.json"
eq "decision hit (ratified)" "$(gov_rule_hits "$T/dk.json" change | cut -d: -f1)" D-0004
eq "decision not applied to additions" "$(gov_rule_hits "$T/dk.json" additive)" ""
{ f modified archicad-addon/devkits.json 2; } | arr > "$T/rec.json"
eq "record-only decision never holds" "$(gov_rule_hits "$T/rec.json" change)" ""
{ f added builtin-scripts/new.py 0; } | arr > "$T/bi.json"
eq "out of scope blocks an addition" "$(gov_rule_hits "$T/bi.json" additive | cut -d: -f1)" X-001
eq "draft entries are inert" "$(GOV_DIR="$HERE" gov_rule_hits "$T/bi.json" additive)" ""

# ---- competing solutions
P1=$'@@ -10,3 +10,4 @@\n a\n+b\n c'
P2=$'@@ -11,2 +11,3 @@\n a\n+x'      # overlaps lines 10-12
P3=$'@@ -200,2 +200,3 @@\n a\n+x'    # far away
{ f modified archicad-addon/Sources/ElementCommands.cpp 0 "$P1"; f modified archicad-addon/Sources/AddOnMain.cpp 0 "$P1"; } | arr > "$T/mine.json"
others () { jq -n --argjson fs "$1" --argjson n "${2:-7}" '[{number: $n, files: $fs}]'; }
eq "overlapping hunks compete" "$(gov_competing "$T/mine.json" <(others "$({ f modified archicad-addon/Sources/ElementCommands.cpp 0 "$P2"; } | arr)"))" "#7 archicad-addon/Sources/ElementCommands.cpp"
eq "distant hunks do not"      "$(gov_competing "$T/mine.json" <(others "$({ f modified archicad-addon/Sources/ElementCommands.cpp 0 "$P3"; } | arr)"))" ""
eq "shared registry ignored"   "$(gov_competing "$T/mine.json" <(others "$({ f modified archicad-addon/Sources/AddOnMain.cpp 0 "$P2"; } | arr)"))" ""
eq "same new path competes"    "$(gov_competing <({ f added marketplace/s/a.py 0 "@@ -0,0 +1 @@"; } | arr) <(others "$({ f added marketplace/s/a.py 0 "@@ -0,0 +1 @@"; } | arr)"))" "#7 marketplace/s/a.py"
eq "no patch = assume clash"   "$(gov_competing <({ f modified a.bin 0; } | arr) <(others "$({ f modified a.bin 0; } | arr)"))" "#7 a.bin"

# ---- reverts
R=$'@@ -1,6 +1,1 @@\n-this is a long line one\n-this is a long line two\n-this is a long line three\n-this is a long line four\n-this is a long line five\n x'
A=$'@@ -1,1 +1,6 @@\n x\n+this is a long line one\n+this is a long line two\n+this is a long line three\n+this is a long line four\n+this is a long line five'
{ f modified s.cpp 5 "$R"; } | arr > "$T/rv.json"
others "$({ f modified s.cpp 0 "$A"; } | arr)" 40 > "$T/m.json"
eq "undoing merged lines"  "$(gov_reverts "$T/rv.json" "$T/m.json" "Tidy" "")" "undoes 5 line(s) added by recently merged #40"
eq "unrelated edit"        "$(gov_reverts <({ f modified s.cpp 1 $'@@ -1 +1 @@\n-short\n+x'; } | arr) "$T/m.json" "Tidy" "")" ""
eq "explicit revert title" "$(gov_reverts <(echo '[]') <(echo '[]') 'Revert "Add thing"' "")" "declares itself a revert"
eq "reverts commit body"   "$(gov_reverts <(echo '[]') <(echo '[]') 'x' 'This reverts commit abc')" "declares itself a revert"

# ---- one solution per issue
OPEN='[{"number":5,"refs":[{"issue":3,"part":null}]},{"number":6,"refs":[{"issue":8,"part":1}]}]'
MERGED='[{"number":2,"refs":[{"issue":4,"part":null}]}]'
echo "$OPEN" > "$T/o.json"; echo "$MERGED" > "$T/mg.json"
eq "parallel pr"       "$(gov_issue_conflicts '[{"issue":3,"part":null}]' 9 "$T/o.json" "$T/mg.json")" "a second pull request, #5, is in flight for the same issue"
eq "own entry ignored" "$(gov_issue_conflicts '[{"issue":3,"part":null}]' 5 "$T/o.json" "$T/mg.json")" ""
eq "already fixed"     "$(gov_issue_conflicts '[{"issue":4,"part":null}]' 9 "$T/o.json" "$T/mg.json")" "the same issue already has a merged fix, #2"
eq "other part is fine" "$(gov_issue_conflicts '[{"issue":8,"part":2}]' 9 "$T/o.json" "$T/mg.json")" ""
eq "same part clashes"  "$(gov_issue_conflicts '[{"issue":8,"part":1}]' 9 "$T/o.json" "$T/mg.json" | wc -l | tr -d ' ')" 1

# ---- people
eq "bots do not count as chatter" "$(echo '[{"login":"github-actions[bot]","type":"Bot"},{"login":"a","type":"User"}]' > "$T/c.json"; gov_human_comments "$T/c.json")" 1
RV='[{"login":"a","type":"User","state":"CHANGES_REQUESTED"},{"login":"a","type":"User","state":"COMMENTED"},{"login":"b","type":"User","state":"CHANGES_REQUESTED"},{"login":"b","type":"User","state":"APPROVED"}]'
eq "request stands until approval" "$(echo "$RV" > "$T/r.json"; gov_changes_requested "$T/r.json")" 1

# ---- the whole report
W="$T/w"; mkdir "$W"
echo '{"number":9,"title":"Add command","body":"Fixes #50","is_bot":true}' > "$W/meta.json"
{ f added archicad-addon/Sources/New.cpp 0 "@@ -0,0 +1 @@"; } | arr > "$W/files.json"
echo '[]' > "$W/open_others.json"; echo '[]' > "$W/merged_recent.json"; echo '[]' > "$W/comments.json"; echo '[]' > "$W/reviews.json"
eq "clean additive pr" "$(gov_report "$W" | jq -r .verdict)" ok
{ f modified archicad-addon/Sources/ElementCommands.cpp 4; } | arr > "$W/files.json"
eq "bot change goes to a person" "$(gov_report "$W" | jq -r .verdict)" change
sed -i 's/"is_bot":true/"is_bot":false/' "$W/meta.json"
eq "a maintainer's change is not held" "$(gov_report "$W" | jq -r .verdict)" ok
jq -n '[range(0;9) | {login:"p", type:"User"}]' > "$W/comments.json"
eq "back-and-forth holds any pr" "$(gov_report "$W" | jq -r .verdict)" contested
echo '[]' > "$W/comments.json"
echo '[{"number":3,"refs":[{"issue":50,"part":null}]}]' > "$W/open_others.json"
eq "parallel solution holds any pr" "$(gov_report "$W" | jq -r '.verdict + " " + .contested[0]')" "contested a second pull request, #3, is in flight for the same issue"

# ---- the committed files
bash "$HERE/validate_governance.sh" >/dev/null && ok "committed scope/decisions validate" || bad "committed scope/decisions validate"

exit $fail
