# Agent Rules Runtime Refinements

## Status

- **Status: Accepted.** Approved by the operator on 2026-08-03, after reviewing the
  merged runtime contract as an agent that must execute it.
- Date: 2026-08-03
- Branch: `agent-rules-runtime-refinements`

## Relationship to the accepted amendment

This record amends
[`2026-08-03-agent-rules-runtime-contract-amendment.md`](2026-08-03-agent-rules-runtime-contract-amendment.md),
which in turn amends [`2026-08-02-agent-rules-audit.md`](2026-08-02-agent-rules-audit.md).
The operator reviewed the merged runtime contract as an agent that must execute it,
identified the defects below, and approved this record and its exact rule wording on
2026-08-03.

This is a partial amendment. All three records remain Accepted, and no earlier accepted
body is edited. Where they conflict, this latest and narrowest record controls only these
parts of the amendment:

- the commit-scope rule wording and its disposition-matrix row;
- the order of the semantic runtime headings; and
- the rebase precondition for a worktree with uncommitted changes.

Every other decision in both earlier records is reaffirmed: the single-policy-surface
rule, the effect-based cluster boundary, credential custody, the public-repository
contract, the repository invariants, the validation gate, and the completion report.

A full `Superseded by` status is deliberately not applied to the amendment, because that
would incorrectly retire the decisions this record does not touch. Accepted text remains
immutable; later narrow records carry the correction.

## Problem

The merged contract was read back as an executing agent rather than as a document, and
three execution defects surfaced.

First, `Keep commits scoped and reviewable` named a quality without a decidable test. Two
agents could disagree on whether a commit was "scoped" with neither being wrong.

Second, `Validation` preceded `Repository invariants`. An agent reads the root contract
in order at task entry, and that order asked it to validate before it had been told which
repository-specific constraints its work must satisfy.

Third, and materially, three rules could bind at once with no permitted action. Preserving
unrelated changes, refusing to rebase a dirty branch, and rebasing before a push when
`origin/main` advanced together describe a state with no legal move. The amendment's own
scenario matrix already treated a dirty branch as a stop condition, but the runtime
contract stated the prohibition without naming the exit, leaving an agent to improvise
either an unrebased push or a commit sweeping in unrelated work. Both are wrong, and both
are what an agent under instruction pressure will reach for.

## Decision

### Commit scope is stated as a decidable test

The commit rule becomes:

> Keep each commit limited to one coherent change. Do not include unrelated edits, and
> split changes when they can be independently reviewed or reverted.

Independent reviewability and revertibility are properties an agent can evaluate against
a specific diff. This replaces the amendment's disposition-matrix row for the same rule.

### Runtime headings follow execution flow

The semantic headings are reordered so that `Repository invariants` precedes
`Validation`:

- Repository context
- Git and worktrees
- Authority boundaries
- Secrets and credentials
- Public repository
- Repository invariants
- Validation
- Completion

The order follows the sequence an agent actually works in: establish context, establish
branch and worktree boundaries, learn what agent and operator may each do, avoid
credential and disclosure mistakes, apply repository-specific implementation constraints,
validate the result, and report completion.

The order is not a ranking of authority. Earlier placement is foundational, not stronger;
a prohibition near the end of the file is exactly as mandatory as one near the start. No
heading text and no rule wording changed as part of the reorder.

### A rebase never runs with uncommitted changes

The rebase rule becomes:

> Never rebase with uncommitted changes. If unrelated changes prevent a required rebase,
> stop and ask the operator.

This names the exit the amendment's scenario matrix already assumed, and closes the
three-rule deadlock. Stopping is the correct outcome because the alternatives — pushing
without the required rebase, or committing unrelated work to clear the tree — each break
a different accepted rule. `--force-with-lease` handling and the failed-lease hard stop
are unchanged.

## Exact runtime contract

Only these lines of root `AGENTS.md` change. The remaining contract is unchanged from the
amendment.

```markdown
- Keep each commit limited to one coherent change. Do not include unrelated edits, and
  split changes when they can be independently reviewed or reverted.
- Never rebase with uncommitted changes. If unrelated changes prevent a required rebase,
  stop and ask the operator. When pushing rebased commits requires rewriting the assigned
  remote feature branch, use only `--force-with-lease`; a failed lease is a hard stop.
```

## Mechanical acceptance

The amendment recorded that `scripts/test/hooks-test.sh` asserts that all eight semantic
headings exist. That check ran one presence assertion per heading and therefore passed
under any ordering, so it could not have detected the defect this record corrects.

The check now compares the file's extracted heading sequence against the approved order
above and prints a unified diff on mismatch. It continues to fail on a missing or extra
heading, and it still enforces no exact rule count and no exact prose. The amendment's
other mechanical invariants are unchanged.

## Consequences

- Two of the three corrections are wording only; the third closes a genuine deadlock
  rather than restating an existing rule.
- Heading order is now machine-enforced, so a future reorder is a deliberate act that
  updates this record rather than an unnoticed edit.
- Root `AGENTS.md` gains two lines and no new rule.
- Agents gain a decidable commit test and a defined stop for a blocked rebase.
- No accepted record was revised, and no implementation plan is committed.
