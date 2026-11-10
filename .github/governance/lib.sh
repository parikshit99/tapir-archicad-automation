#!/usr/bin/env bash
# Mechanical governance checks for claude_auto_merge.yml. Source this file.
#
# Everything here is a pure function of JSON files: no network, no model, so
# test_governance.sh can run it on fixtures. The workflow gathers the JSON from
# the GitHub API into one work directory and calls gov_report. See README.md.
#
# Work directory contract (all JSON):
#   meta.json          {number, title, body, is_bot}
#   files.json         the pull request's files, as GET pulls/{n}/files returns them
#   open_others.json   [{number, files, refs}]  the other open pull requests
#   merged_recent.json [{number, files, refs}]  pull requests merged in the window
#   comments.json      [{login, type, result}]  every comment and review comment
#   reviews.json       [{login, type, state}]   every review, oldest first
# "refs" is gov_issue_refs of the body.
#
# Requires: bash 4, jq 1.6+.

GOV_DIR=${GOV_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

# The paths a pull request may never auto-merge: what runs with credentials,
# produces signed binaries, or steers the bots (so the bots cannot edit their
# own goals). ^\.github/ also covers .github/governance/, which holds the
# scope and decisions files.
GOV_PROTECTED='^\.github/|^archicad-addon/Tools/|^archicad-addon/Installer/|^tools/|^archicad-addon/devkits\.json$|CMakeLists\.txt$|\.cmake$|\.csproj$|(^|/)CLAUDE\.md$|(^|/)AGENTS\.md$|(^|/)SKILL\.md$|^\.claude/'

# jq definitions shared by the checks:
#   glob_re  list of globs -> one regex; * is any characters, / included
#   refs     body text -> [{issue, part}] from "Fixes #n" and "Part k of N of #n"
GOV_JQ='
  def glob_re: map(gsub("(?<c>[.+^${}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; "."))
               | if length == 0 then "a^b" else "^(" + join("|") + ")$" end;
  def refs: [ (scan("(?i)(?:fixes|closes|resolves) +#([0-9]+)") | {issue: (.[0] | tonumber), part: null}),
              (scan("Part ([0-9]+) of [0-9]+ of #([0-9]+)") | {issue: (.[1] | tonumber), part: (.[0] | tonumber)}) ]
            | unique;
'

# Newline separated globs (stdin) -> one regex.
gov_glob_re () { jq -Rrn "$GOV_JQ"'[inputs | select(length > 0)] | glob_re'; }

# Body text (stdin) -> refs.
gov_issue_refs () { jq -Rs "$GOV_JQ"'refs'; }

# Lines (stdin) -> JSON array of strings.
gov_lines_json () { jq -Rn '[inputs]'; }

# The scope settings, read once.
{ read -r GOV_NB_RE; read -r GOV_ALWAYS_RE; read -r GOV_IGNORE_RE
  read -r GOV_MAX_DEL; read -r GOV_MAX_COMMENTS; read -r GOV_REVERT_MIN; } < <(
  jq -r "$GOV_JQ"'(.additive_split.non_behavioral | glob_re),
                  (.additive_split.always_change_when_modified | glob_re),
                  (.contention.ignore_files | glob_re),
                  (.additive_split.max_deleted_lines // 0),
                  (.contested.max_human_comments // 8),
                  (.contested.revert_min_matching_lines // 5)' "$GOV_DIR/scope.json")

# Add vs change. Args: files.json. Prints {kind: additive|change, reasons: []}.
gov_change_kind () {
  jq --arg nb "$GOV_NB_RE" --arg always "$GOV_ALWAYS_RE" --argjson max "$GOV_MAX_DEL" '
    [ .[] | select(.filename | test($nb) | not)
      | if .status == "removed" then "removes \(.filename)"
        elif .status == "renamed" then "renames \(.previous_filename // "?") to \(.filename)"
        elif .status != "added" and (.filename | test($always))
          then "modifies existing \(.filename), which reaches end users"
        elif .status != "added" and (.deletions // 0) > $max
          then "removes \(.deletions) line(s) of existing \(.filename)"
        else empty end ] as $r
    | {kind: (if ($r | length) > 0 then "change" else "additive" end), reasons: $r}' "$1"
}

# Scope and decisions the pull request runs into. Args: files.json, kind.
# An entry counts only when ratified_by names at least min_approvers people
# besides the placeholder "DRAFT"; it applies to a change always, to an
# addition when it says blocks_additions. Prints "id: text" per hit.
gov_rule_hits () {
  jq -r --arg kind "$2" --slurpfile scope "$GOV_DIR/scope.json" --slurpfile dec "$GOV_DIR/decisions.json" \
     "$GOV_JQ"'
    [ .[].filename ] as $names
    | ($scope[0].ratification.min_approvers // 1) as $min
    | ( ($scope[0].out_of_scope[]? | .text = .statement), ($dec[0].decisions[]? | .text = .decision) )
    | select((.paths // []) | length > 0)
    | select($kind == "change" or .blocks_additions == true)
    | select((.ratified_by // [] | map(select(. != "DRAFT")) | unique | length) >= $min)
    | (.paths | glob_re) as $re
    | select(any($names[]; test($re)))
    | "\(.id): \(.text)"' "$1"
}

# Other open pull requests whose hunks overlap this one's. Args: files.json,
# open_others.json. Prints "#n path".
gov_competing () {
  jq -r --arg ignore "$GOV_IGNORE_RE" --slurpfile others "$2" '
    def ranges: [ (.patch // "") | scan("(?m)^@@ -([0-9]+)(?:,([0-9]+))? ")
                  | (.[0] | tonumber) as $s
                  | {s: $s, e: ($s + ([(.[1] // "1" | tonumber), 1] | max) - 1)} ];
    def clash($a; $b):
      if $a.status == "added" and $b.status == "added" then true
      elif ($a.patch == null) or ($b.patch == null) then true
      else ($b | ranges) as $rb | any(($a | ranges)[]; . as $x | any($rb[]; .s <= $x.e and $x.s <= .e)) end;
    . as $mine
    | $others[0][] | . as $o
    | (($o.files // []) | INDEX(.filename)) as $byname
    | $mine[] | select(.filename | test($ignore) | not)
    | select($byname[.filename] and clash(.; $byname[.filename]))
    | "#\($o.number) \(.filename)"' "$1" | sort -u
}

# Whether this pull request undoes recently merged work. Args: files.json,
# merged_recent.json, title, body. Prints one reason per line.
gov_reverts () {
  if printf '%s\n%s\n' "$3" "$4" | grep -qiE '^revert[ :"]|this reverts commit'; then
    echo "declares itself a revert"
  fi
  jq -r --argjson min "$GOV_REVERT_MIN" --slurpfile merged "$2" '
    def lines($c): [ (.patch // "") | split("\n")[] | select(startswith($c))
                     | ltrimstr($c) | gsub("^\\s+|\\s+$"; "") | select(length >= 15) ];
    ([ .[] | lines("-")[] ] | unique) as $removed
    | $merged[0][] | . as $m
    | ([ ($m.files // [])[] | lines("+")[] ] | map({key: ., value: true}) | from_entries) as $added
    | ([ $removed[] | select($added[.]) ] | length) as $n
    | select($n >= $min)
    | "undoes \($n) line(s) added by recently merged #\($m.number)"' "$1"
}

# Another pull request for the same issue. Args: refs (JSON array of this
# pull request), number, open_others.json, merged_recent.json. Prints reasons.
# Parts of a split issue (Part k of N) only clash with the same part.
gov_issue_conflicts () {
  jq -nr --argjson mine "$1" --argjson me "$2" --slurpfile open "$3" --slurpfile merged "$4" '
    def clash($a; $b): $a.issue == $b.issue and ($a.part == null or $b.part == null or $a.part == $b.part);
    def hits($xs): $xs[] | select(.number != $me) | . as $o
                   | select(any($mine[]; . as $r | any($o.refs[]?; clash($r; .))));
    (hits($open[0])   | "a second pull request, #\(.number), is in flight for the same issue"),
    (hits($merged[0]) | "the same issue already has a merged fix, #\(.number)")'
}

# Human comments on the pull request. Args: comments.json. Prints the count.
# A community test result (a comment starting "tapir-test:", marked result by
# the workflow) is a report, not a discussion, and is not counted.
gov_human_comments () { jq '[ .[] | select(.type != "Bot" and .result != true) ] | length' "$1"; }

# Reviewers whose latest decisive review requests changes. Args: reviews.json.
# As on GitHub, a request stands until that reviewer approves or it is
# dismissed; a later COMMENTED review does not clear it.
gov_changes_requested () {
  jq '[ .[] | select(.state != "COMMENTED" and .state != "PENDING" and .type != "Bot") ]
      | group_by(.login) | map(last | select(.state == "CHANGES_REQUESTED")) | length' "$1"
}

# The whole verdict. Args: work dir. Prints
#   {verdict: ok|contested|change, contested: [...], change: [...]}
# contested applies to every pull request; change only to the issue bot's.
# Fails (prints nothing) when any check cannot run, so the caller holds the
# pull request rather than passing it on a broken check.
gov_report () {
  local w=$1 n is_bot title body refs kind chatter cr part contested='' change=''
  { read -r n; read -r is_bot; read -r title; } < <(jq -r '.number, .is_bot, (.title | gsub("\n"; " "))' "$w/meta.json")
  [ -n "$n" ] && [ -n "$is_bot" ] || return 1
  body=$(jq -r '.body // ""' "$w/meta.json") || return 1
  refs=$(printf '%s' "$body" | gov_issue_refs) || return 1
  chatter=$(gov_human_comments "$w/comments.json") || return 1
  cr=$(gov_changes_requested "$w/reviews.json") || return 1

  part=$(set -o pipefail; gov_competing "$w/files.json" "$w/open_others.json" | sed 's/^/competes with /') || return 1
  contested+=${part:+$part$'\n'}
  part=$(gov_reverts "$w/files.json" "$w/merged_recent.json" "$title" "$body") || return 1
  contested+=${part:+$part$'\n'}
  part=$(gov_issue_conflicts "$refs" "$n" "$w/open_others.json" "$w/merged_recent.json") || return 1
  contested+=${part:+$part$'\n'}
  [ "$chatter" -gt "$GOV_MAX_COMMENTS" ] && contested+="$chatter human comments, more than $GOV_MAX_COMMENTS"$'\n'
  [ "$cr" -gt 0 ] && contested+="$cr reviewer(s) request changes"$'\n'

  if [ "$is_bot" = "true" ]; then
    kind=$(gov_change_kind "$w/files.json") || return 1
    part=$(jq -r '.reasons[]' <<<"$kind") || return 1
    change+=${part:+$part$'\n'}
    part=$(gov_rule_hits "$w/files.json" "$(jq -r .kind <<<"$kind")") || return 1
    change+=${part:+$part$'\n'}
  fi
  jq -n --argjson c "$(printf '%s' "$contested" | gov_lines_json)" --argjson h "$(printf '%s' "$change" | gov_lines_json)" \
    '{verdict: (if ($c | length) > 0 then "contested" elif ($h | length) > 0 then "change" else "ok" end),
      contested: $c, change: $h}'
}
