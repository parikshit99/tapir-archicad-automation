# Governance: direction as data

DRAFT, local to the fork. Nothing here is filed upstream.

`claude_auto_merge.yml` used to ask "green, old enough, not a release path". It now
also asks "not contested", with plain rules over metadata. The AI reviews and triages;
it does not decide what the project should be, with one exception the owner chose: the
review bot says whether a bot pull request that removes lines of existing code is a
contained bug fix (see "Bug fixes" below).

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
| **Change, not addition**: removes or renames a file, or edits an existing file in `builtin-scripts/` or `marketplace/`. Docs, tests and examples do not count. | the issue bot |
| Removes more than `max_deleted_lines` lines of an existing file, unless the review judged the pull request a bug fix | the issue bot |
| A ratified scope or decision entry matches | the issue bot |
| **Repeated code**: more than `quality.duplicate_max_percent` of the added source lines sit in blocks of `duplicate_window` lines that already exist on `main` or earlier in the same pull request (only from `duplicate_min_lines` added lines up) | the issue bot |
| **No check**: registers a new command in `AddOnMain.cpp` without a check that calls it in `archicad-addon/Test/checks/` (in the pull request or already on `main`) | the issue bot |

A held pull request gets the `needs-direction` label and one comment; auto-merge and the
steward leave it alone. A maintainer who removes the label releases it, and the gate is not
applied to it again (a later conflict needs a new decision).

## Bug fixes

Nearly every bug fix removes lines, so a rule on removed lines alone would send every
fix to a person. `claude_pr_review.yml` therefore ends its review of a bot pull request
with one more nonce-tagged marker, which a job without a model records as the commit
status `claude-behaviour`: `fix` (everything altered was wrong by the code's own schema,
description or documentation) and `none` (only adds) are a success, `change` (different
behaviour for correct use: renames, removals, defaults, reworks, reverts) is a failure.
The gate lets removed lines through only on a success for the head commit; a failure or
no status holds the pull request. A fix verdict never covers a removed or renamed file,
an edit to an existing shared script, a ratified decision or the contested signals.

This is a model's judgement, and the issue text it reads is written by anyone. What
bounds it: the verdict is per commit, the review is told to judge by the code and not by
what the issue calls a bug, and the waiting time and every other gate still apply.

## Website lane

A bot pull request that touches only `docs/` waits `BOT_AUTO_MERGE_SITE_DELAY_HOURS`
(repository variable, default 12) after its clean review instead of 72. The site is live
on merge, so a bug there stays public while its fix waits, and nothing under `docs/`
reaches the signed release. The shorter wait is also less time for a person to notice a
bad change to the site's scripts.

## Not built yet

* Classifying new issues against scope and decisions in `claude_issue_triage.yml`, and
  refusing a second parallel PR for an issue at the bot (the gate only holds the merge).
* A human acknowledgment before a contested change rides into the weekly release.
