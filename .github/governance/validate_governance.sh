#!/usr/bin/env bash
# Checks the shape of scope.json and decisions.json. Run in CI on every change
# to this folder. Prints one problem per line and exits 1 if there are any.
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=$(jq -nr --slurpfile s "$D/scope.json" --slurpfile d "$D/decisions.json" '
  def need($o; $keys; $where): $keys[] | select($o[.] == null) | "\($where): missing \(.)";
  def ids($xs; $re; $where): ($xs | map(.id)) as $i
    | ($i[] | select(test($re) | not) | "\($where): bad id \(.)"),
      ($i | group_by(.)[] | select(length > 1) | "\($where): duplicate id \(.[0])");
  $s[0] as $s | $d[0] as $d
  | need($s; ["schema","ratification","in_scope","out_of_scope","contention","additive_split","contested"]; "scope.json"),
    (($s.in_scope[], $s.out_of_scope[]) as $e | need($e; ["id","statement","source","ratified_by"]; "scope.json \($e.id)")),
    ids($s.in_scope; "^S-[0-9]{3}$"; "scope.json"),
    ids($s.out_of_scope; "^X-[0-9]{3}$"; "scope.json"),
    (if ($s.ratification.min_approvers | type) != "number" or $s.ratification.min_approvers < 1
     then "scope.json: min_approvers must be >= 1" else empty end),
    ($d.decisions[] as $e | need($e; ["id","date","question","decision","kind","paths","source","ratified_by"]; "decisions.json \($e.id // "?")")),
    ($d.decisions[] | select(.kind != null and (.kind | IN("reject", "keep-default", "policy") | not))
       | "decisions.json \(.id): bad kind \(.kind)"),
    ids($d.decisions; "^D-[0-9]{4}$"; "decisions.json")')
if [ -n "$out" ]; then printf '%s\n' "$out"; exit 1; fi
echo "scope.json and decisions.json are well formed"
