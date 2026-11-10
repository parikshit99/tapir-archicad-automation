# Governance: direction as data

DRAFT, local to the fork. Nothing here is filed upstream.

`claude_auto_merge.yml` used to ask "green, old enough, not a release path". It now
also asks "not contested", with plain rules over metadata. The AI reviews and triages;
it does not decide what the project should be.

## Files

| File | What it is |
| --- | --- |
| `scope.json` | What the project takes on (`in_scope`) and will not (`out_of_scope`), plus the numbers the checks use. |
| `decisions.json` | Questions already settled. Append one entry each time a maintainer decides one. |
| `lib.sh` | The checks, as functions of JSON files. Sourced by the workflow. |
| `test_governance.sh` | Tests on fixtures. `validate_governance.sh` checks the two files' shape. |

Both JSON files are under `.github/`, which auto-merge never merges, so the bots cannot
edit their own direction. `lib.sh` also protects `CLAUDE.md`, `AGENTS.md`, `SKILL.md`
and `.claude/`.

### Entries

An entry **counts only when `ratified_by` names at least `ratification.min_approvers`
maintainers** other than the placeholder `DRAFT`. Every entry now is `DRAFT` and copied
from rules already written in `CLAUDE.md` or a workflow header (see its `source`), so
nothing is enforced until a maintainer ratifies it.

Decision: `id` (`D-0001`), `date`, `question`, `decision`, `kind` (`reject`,
`keep-default`, `policy`), `paths` (globs, `*` also crosses `/`), `source`,
`ratified_by`, and optionally `blocks_additions` (default false) and `note`. Scope
entries: `id` (`S-`/`X-`), `statement`, `source`, `ratified_by`, and for
`out_of_scope` also `paths` and `blocks_additions`. An entry with no `paths` is a
record only: it documents a decision but never holds a pull request (D-0001 to
D-0003 guard release critical paths, which gate 3 already keeps from auto-merge).

A ratified entry holds a **change** (below) that touches its `paths`, and an **addition**
only if `blocks_additions` is true.

## The gate

Each rule is a jq/shell test; the reasons are posted on the pull request.

| Signal | Applies to |
| --- | --- |
| Hunks that overlap another open, ready pull request's (files in `contention.ignore_files` excepted; two new files with one path) | all |
| Removes at least `revert_min_matching_lines` lines that a pull request merged in the last `revert_window_days` added, or says it is a revert | all |
| Another open pull request, or a merged one, for the same issue (`Fixes #n`; `Part k of N` only clashes with the same part) | all |
| A reviewer's latest review requests changes, or more than `max_human_comments` human comments (community test results, `tapir-test:`, are not counted) | all |
| **Change, not addition**: removes or renames a file, removes more than `max_deleted_lines` lines of an existing file, or edits an existing file in `builtin-scripts/` or `marketplace/`. Docs, tests and examples do not count. | the issue bot |
| A ratified scope or decision entry matches | the issue bot |

A held pull request gets the `needs-direction` label and one comment; auto-merge and the
steward leave it alone. A maintainer who removes the label releases it, and the gate is not
applied to it again (a later conflict needs a new decision).

## Not built yet

* Classifying new issues against scope and decisions in `claude_issue_triage.yml`, and
  refusing a second parallel PR for an issue at the bot (the gate only holds the merge).
* A human acknowledgment before a contested change rides into the weekly release.
