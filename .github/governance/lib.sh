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
#   comments.json      [{login, type}]          every comment and review comment
#   reviews.json       [{login, type, state}]   every review, oldest first
# "refs" is gov_issue_refs of the body.
#
# Requires: bash 4, jq 1.6+, GNU sed.

GOV_DIR=${GOV_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

# The paths a pull request may never auto-merge: what runs with credentials,
# produces signed binaries, or steers the bots (so the bots cannot edit their
# own goals). .github/ already covers .github/governance/, which holds the
# scope and decisions files; the explicit entry is for the tests.
GOV_PROTECTED='^\.github/|^archicad-addon/Tools/|^archicad-addon/Installer/|^tools/|^archicad-addon/devkits\.json$|CMakeLists\.txt$|\.cmake$|\.csproj$|(^|/)CLAUDE\.md$|(^|/)AGENTS\.md$|(^|/)SKILL\.md$|^\.claude/|^\.github/governance/'

# Newline separated globs (stdin) -> one ERE. * is any characters, / included.
gov_glob_re () {
  local body
  body=$(sed -e '/^$/d' -e 's/[.+^${}()|\\[]/\\&/g' -e 's/\]/\\]/g' -e 's/\*/.*/g' -e 's/?/./g' | paste -sd'|' -)
  if [ -z "$body" ]; then printf 'a^b'; else printf '^(%s)$' "$body"; fi
}

# The globs under a scope.json path, as an ERE.
gov_scope_re () { jq -r "$1[]" "$GOV_DIR/scope.json" | gov_glob_re; }

# Whether an entry counts: ratified_by names at least min_approvers people,
# not counting the placeholder "DRAFT". Unratified entries are inert.
gov_enforced_filter='($scope.ratification.min_approvers // 1) as $min
  | select((.ratified_by // [] | map(select(. != "DRAFT")) | unique | length) >= $min)'

# "owner/name#12 Fixes #3" -> [{issue: 3, part: null}]; "Part 2 of 4 of #3" ->
# [{issue: 3, part: 2}]. Stdin: the body text.
gov_issue_refs () {
  jq -Rs '[ (scan("(?i)(?:fixes|closes|resolves) +#([0-9]+)") | {issue: (.[0] | tonumber), part: null}),
            (scan("Part ([0-9]+) of [0-9]+ of #([0-9]+)") | {issue: (.[1] | tonumber), part: (.[0] | tonumber)}) ]
          | unique'
}

# Add vs change. Args: files.json. Prints {kind: additive|change, reasons: []}.
gov_change_kind () {
  local nb always max
  nb=$(gov_scope_re .additive_split.non_behavioral)
  always=$(gov_scope_re .additive_split.always_change_when_modified)
  max=$(jq '.additive_split.max_deleted_lines // 0' "$GOV_DIR/scope.json")
  jq --arg nb "$nb" --arg always "$always" --argjson max "$max" '
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
# A ratified entry applies to a change always, to an addition when it says
# blocks_additions. Prints one reason per line.
gov_rule_hits () {
  local files=$1 kind=$2
  local line id text paths re ok
  while IFS=$'\t' read -r id text paths ok; do
    [ "$ok" = "true" ] || continue
    re=$(printf '%s' "$paths" | tr ',' '\n' | gov_glob_re)
    if jq -e --arg re "$re" 'any(.[]; .filename | test($re))' "$files" >/dev/null; then
      printf '%s: %s\n' "$id" "$text"
    fi
  done < <(jq -r --arg kind "$kind" --slurpfile scope "$GOV_DIR/scope.json" '
    $scope[0] as $scope
    | ([ $scope.out_of_scope[]? | {id, text: .statement, paths, blocks_additions, ratified_by} ]
       + [ .decisions[]? | {id, text: .decision, paths, blocks_additions, ratified_by} ])
    | .[]
    | select((.paths // []) | length > 0)
    | select(($kind == "change") or (.blocks_additions == true))
    | '"$gov_enforced_filter"'
    | [.id, .text, (.paths | join(",")), "true"] | @tsv' "$GOV_DIR/decisions.json")
}

# Other open pull requests whose hunks overlap this one's. Args: files.json,
# open_others.json. Prints "#n path".
gov_competing () {
  local ignore
  ignore=$(gov_scope_re .contention.ignore_files)
  jq -r --arg ignore "$ignore" --slurpfile others "$2" '
    def ranges: [ (.patch // "") | scan("(?m)^@@ -([0-9]+)(?:,([0-9]+))? ")
                  | (.[0] | tonumber) as $s
                  | (if .[1] == null then 1 else (.[1] | tonumber) end) as $n
                  | {s: $s, e: ($s + (if $n < 1 then 1 else $n end) - 1)} ];
    def clash($a; $b):
      if $a.status == "added" and $b.status == "added" then true
      elif ($a.patch == null) or ($b.patch == null) then true
      else any(($a | ranges)[]; . as $x | any(($b | ranges)[]; .s <= $x.e and $x.s <= .e)) end;
    . as $mine
    | $others[0][] | . as $o
    | $mine[] | select(.filename | test($ignore) | not) | . as $f
    | (($o.files // [])[] | select(.filename == $f.filename)) as $of
    | select(clash($f; $of))
    | "#\($o.number) \($f.filename)"' "$1" | sort -u
}

# Whether this pull request undoes recently merged work. Args: files.json,
# merged_recent.json, title, body. Prints one reason per line.
gov_reverts () {
  local min
  min=$(jq '.contested.revert_min_matching_lines // 5' "$GOV_DIR/scope.json")
  if printf '%s\n%s\n' "$3" "$4" | grep -qiE '^revert[ :"]|this reverts commit'; then
    echo "declares itself a revert"
  fi
  jq -r --argjson min "$min" --slurpfile merged "$2" '
    def lines($c): [ (.patch // "") | split("\n")[] | select(startswith($c) and (startswith($c + $c + $c) | not))
                     | ltrimstr($c) | gsub("^\\s+|\\s+$"; "") | select(length >= 15) ];
    ([ .[] | lines("-") ] | add // [] | unique) as $removed
    | $merged[0][] | . as $m
    | ([ ($m.files // [])[] | lines("+") ] | add // [] | unique) as $added
    | ([ $removed[] | select(. as $l | $added | index($l)) ] | length) as $n
    | select($n >= $min)
    | "undoes \($n) line(s) added by recently merged #\($m.number)"' "$1"
}

# Another pull request for the same issue. Args: refs (JSON array of this
# pull request), number, open_others.json, merged_recent.json. Prints reasons.
# Parts of a split issue (Part k of N) only clash with the same part.
gov_issue_conflicts () {
  jq -nr --argjson mine "$1" --argjson me "$2" --slurpfile open "$3" --slurpfile merged "$4" '
    def clash($a; $b): $a.issue == $b.issue and ($a.part == null or $b.part == null or $a.part == $b.part);
    ( $open[0][]   | select(.number != $me) | . as $o | select(any($mine[]; . as $r | any($o.refs[]; clash($r; .))))
        | "a second pull request, #\($o.number), is in flight for the same issue" ),
    ( $merged[0][] | select(.number != $me) | . as $o | select(any($mine[]; . as $r | any($o.refs[]; clash($r; .))))
        | "the same issue already has a merged fix, #\($o.number)" )'
}

# Human comments on the pull request. Args: comments.json. Prints the count.
gov_human_comments () {
  jq '[ .[] | select(.type != "Bot" and (.login | test("^(app/)?github-actions(\\[bot\\])?$|\\[bot\\]$") | not)) ] | length' "$1"
}

# Reviewers whose latest decisive review requests changes. Args: reviews.json.
gov_changes_requested () {
  jq '[ .[] | select(.state != "COMMENTED" and .state != "PENDING" and .type != "Bot") ]
      | group_by(.login) | map(last | select(.state == "CHANGES_REQUESTED")) | length' "$1"
}

# The whole verdict. Args: work dir. Prints
#   {verdict: ok|contested|change, contested: [...], change: [...]}
# contested applies to every pull request; change only to the issue bot's.
gov_report () {
  local w=$1 n title body is_bot refs kind max chatter cr
  n=$(jq -r .number "$w/meta.json"); title=$(jq -r .title "$w/meta.json")
  body=$(jq -r '.body // ""' "$w/meta.json"); is_bot=$(jq -r .is_bot "$w/meta.json")
  refs=$(printf '%s' "$body" | gov_issue_refs)
  max=$(jq '.contested.max_human_comments // 8' "$GOV_DIR/scope.json")
  chatter=$(gov_human_comments "$w/comments.json")
  cr=$(gov_changes_requested "$w/reviews.json")

  local contested change
  contested=$( {
      gov_competing "$w/files.json" "$w/open_others.json" | sed 's/^/competes with /'
      gov_reverts "$w/files.json" "$w/merged_recent.json" "$title" "$body"
      gov_issue_conflicts "$refs" "$n" "$w/open_others.json" "$w/merged_recent.json"
      [ "$chatter" -gt "$max" ] && echo "$chatter human comments, more than $max"
      [ "$cr" -gt 0 ] && echo "$cr reviewer(s) request changes"
      true
    } | jq -R . | jq -s .)
  change='[]'
  if [ "$is_bot" = "true" ]; then
    kind=$(gov_change_kind "$w/files.json")
    change=$( {
        jq -r '.reasons[]' <<<"$kind"
        gov_rule_hits "$w/files.json" "$(jq -r .kind <<<"$kind")"
        true
      } | jq -R . | jq -s .)
  fi
  jq -n --argjson c "$contested" --argjson h "$change" \
    '{verdict: (if ($c | length) > 0 then "contested" elif ($h | length) > 0 then "change" else "ok" end),
      contested: $c, change: $h}'
}
