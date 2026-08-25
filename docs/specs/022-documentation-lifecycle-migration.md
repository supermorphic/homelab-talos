# Documentation Lifecycle Migration

## Purpose

Replace the repository's ADR-style decision lifecycle with a specification-driven
documentation model that matches how design and implementation evolve in practice.

The durable artifact is a design specification. A specification is committed before
implementation and may change while implementation is active. Merge is the freeze
boundary: before merge, the specification must be reconciled with the implemented and
validated result; after merge, it is a historical record. A later material redesign uses
a new numbered specification.

Implementation plans are separate, transient execution artifacts. They remain
uncommitted and may be discarded after the work is complete.

## Motivation

The existing decision lifecycle treats accepted decisions as an immutable implementation
baseline. Real implementation work has shown that this boundary occurs too early.
Implementation regularly discovers constraints, invalid assumptions, and better designs.
Representing those discoveries through amendments, findings, superseding records,
reviews, and generated lifecycle indexes has created more reconciliation work without
making the current system easier to understand.

The replacement retains durable design history and rationale without freezing a design
before implementation validates it. Current repository policy, source, and operational
documentation remain authoritative. Historical specifications explain how and why the
repository reached its current state but do not override it.

## Documentation model

The repository uses these documentation roles:

- `AGENTS.md` defines current, vendor-neutral repository policy.
- Source-adjacent `README.md` files describe the current subsystem and its local
  conventions.
- `docs/specs/` contains committed design specifications and their rationale.
- `docs/reference/` contains current facts, contracts, supported values, and lookup
  material.
- `docs/guides/` contains goal-oriented setup and change procedures.
- `docs/runbooks/` contains event-driven operational response procedures.
- `.tmp/plans/` contains uncommitted implementation plans used for execution, resumption,
  and agent handoff.
- Git and pull-request history retain detailed implementation and review history.

`docs/README.md` is a navigation surface for the documentation set. It does not define
repository policy, a specification template, or a required specification outline.
Specification placement and naming rules belong only in `AGENTS.md`. Source-adjacent
README files remain in place rather than being moved into the four `docs/` categories.

The old `docs/decisions/` category and root-level `docs/phase-*.md` files are removed. No
replacement `history/` or `phases/` category is introduced.

## Specification lifecycle

Durable specifications use monotonically increasing numeric identifiers, such as
`001-<name>.md`. The number identifies a design lineage in repository chronology; it is
not a lifecycle status.

The lifecycle is:

1. Brainstorm the design.
2. Commit a numbered design specification.
3. Approve the specification for implementation.
4. Create a corresponding transient implementation plan when needed.
5. Implement and validate the design.
6. Update the specification when implementation materially changes the intended design.
7. Update the plan freely as execution changes.
8. Before merge, reconcile the specification with the implemented and validated result.
9. Merge the change. The specification becomes a historical record and the plan may be
   discarded.
10. Create a new numbered specification for a later material redesign.

Approval for implementation does not make a specification immutable. A specification
may evolve until merge. Small corrections that make an active specification accurately
describe the same design remain within its lineage. A material redesign after merge
starts a new lineage and receives a new identifier.

When a transient implementation plan corresponds to a numbered specification, it uses
the same numeric identifier and descriptive name where practical. Repository-defined
artifact locations override tool and skill defaults.

## Migration method

The migration is a full, lineage-first reconciliation rather than a mechanical file move.
It uses the current source and current documentation as the implementation baseline, then
reconstructs the useful rationale from historical records.

Each migrated specification retains the same categories and approximate depth of durable
design reasoning expected from a new specification. Reconciliation may remove lifecycle
ceremony, transient history, duplication, and obsolete implementation detail, but it must
not compress load-bearing rationale or evidence boundaries into an outcome summary.

An uncommitted migration ledger under `.tmp/plans/` records every legacy artifact and its
disposition. Each artifact must have a destination or an explicit deletion rationale
before it is removed. The ledger is an execution aid, not durable documentation.

Numbered specifications are assigned according to the chronology of the original design
lineages. Records that amended or reported findings about an earlier design inherit that
parent lineage rather than receiving an artificial independent record. The surviving
lineages are numbered consecutively from `001` through `022`, without gaps. This one-time
migration renumbering does not authorize renumbering historical specifications after
merge. A later material redesign receives the next number after the current maximum.

When historical records disagree, the implemented and validated repository state wins.
If neither current source nor current documentation resolves a material conflict, the
migration stops at that item and requests an operator decision rather than inventing one.

## Legacy artifact dispositions

Legacy records are reconciled as follows:

- Design decisions become numbered specifications. Related records are consolidated into
  the same design lineage when they describe the evolution of one design.
- Amendments are merged into their parent specification with the final values and
  rationale, then deleted.
- Findings contribute relevant conclusions to the final specification, runbook, guide,
  reference, or source-adjacent README. The standalone finding record is then deleted.
- Audits retain only conclusions that remain reflected in current policy or source. Those
  conclusions move to the appropriate current document or specification; obsolete audit
  narration is deleted.
- Go/no-go records may become specifications when their still-current outcome, evidence,
  rationale, and conditions for reconsideration explain an important repository design
  choice. `Outcome: No-go` is information in the specification, not a lifecycle state.
- Review artifacts are deleted. Durable conclusions from review must already be reflected
  in the reconciled specification or current repository state.
- Phase documents lose their special category. Design rationale and durable outcomes move
  to specifications; current operating procedures move to guides or runbooks; current
  facts move to references or source-adjacent README files; stale status, rollout logs,
  and duplicated content are deleted.
- Images and other durable supporting assets move with the specification or current
  document that uses them. Image names are descriptive and have no date or specification
  number prefix. Unreferenced or obsolete assets are deleted.
- Tracked and ignored legacy plans are removed. Only plans for genuinely active work are
  recreated under `.tmp/plans/` and reconciled with the current specification and intent.

Every retained document has one primary purpose. Mixed documents are split only when the
resulting parts remain useful; otherwise their useful content moves to the best primary
destination.

## Phase disposition

The former phase documents are not retained as a separate documentation category. Their
durable content has these destinations:

| Former phases | Durable destinations |
| --- | --- |
| 0–6 | Talos and Flux platform specification, NUC reference, Talos and Kubernetes READMEs, and recovery runbook |
| 7 | Platform and certificate specifications, application READMEs, and Pi-hole guide |
| 8 | Validated outcome in the platform specification; dated logs and counters are deleted |
| 9 | Platform specification and Longhorn README |
| 10 | Flux alerting, ntfy, Portainer, platform, and test-reporting specifications, plus application READMEs |
| 11 | Media architecture, Plex Relay and Sonos, and Plex direct-access specifications, plus media guidance and the recovery runbook |
| 12 | Media architecture specification, qbit_manage references, and ProtonVPN and Gluetun guide |
| 13 | Lidarr and media architecture specifications, plus the media startup guide |
| 14 | Tautulli and media architecture specifications, plus the media startup guide |

This table records where the deleted phase history went. Phase numbers are not retained
as current lifecycle or rollout labels.

## Source references to documentation

Source and configuration comments must explain the current constraint without requiring
the reader to open another document. They may link to a specification when its historical
rationale helps explain a non-obvious design choice, accepted tradeoff, or rejected
alternative. The specification supplies context; it is not the source of current
authority.

Current procedures and facts link to the applicable guide, runbook, reference, or
source-adjacent README. Generic specification banners and comprehensive source-to-spec
traceability are not required. During this migration, existing callouts are retained only
when they meet this boundary, and missing callouts are added only where a specific
non-obvious constraint would otherwise be easy to change incorrectly.

## Runbook boundary

A runbook is an event-driven operational procedure for an alert, failure, recovery, or
maintenance event. It should identify the trigger, required authority and preconditions,
diagnosis, mitigation or recovery actions, verification, and rollback or escalation where
applicable.

Setup and change workflows are guides, not runbooks. Current facts, interfaces, supported
values, and contracts are reference material. Design rationale, experiments, rejected
options, and historical outcomes belong in specifications.

Existing documents are classified by their primary purpose. Mixed documents such as
setup material containing troubleshooting procedures may be divided between a guide and a
runbook when both portions remain current. Directory placement must describe how a reader
uses the document, not the project phase in which it was written.

## Tooling changes

The decision lifecycle parser, generated decision index, lifecycle validation commands,
and lifecycle-specific tests are removed. This includes the decision parser and its test
suite, the decision index and validation recipes, and their validation-catalog and
test-chain entries.

No replacement documentation or specification validator is introduced. Numeric naming
and document placement are repository policy enforced through `AGENTS.md` and review, not
through a parser or generated index.

The tracked ignore file contains only repository-defined generic artifact locations. A
tool-specific local state directory belongs in the clone-local Git exclude file when it
needs an exclusion; it does not belong in repository policy. The generic `/.tmp/` ignore
continues to cover transient repository plans.

The ordinary link-integrity checker remains because it detects useful failures such as
broken links after files move. It is simplified so that it:

- verifies that explicit relative Markdown links resolve within the repository;
- verifies bare paths to current documentation, source-adjacent README files, runbooks,
  guides, and references;
- permits specifications to name planned implementation paths that do not exist yet; and
- has no knowledge of document categories, numeric identifiers, lifecycle states,
  immutability, or changes relative to `origin/main`.

The checker must not fetch a remote branch or invoke a decision parser. Focused link tests
will cover the remaining generic behavior.

## Delivery and branch history

The migration lands atomically through the current pull request. `main` must not receive a
partially migrated state containing both documentation models.

The stale feature branch is rewritten into coherent, reviewable commits. The two existing
Git-hook fixes remain separate independent commits. The rejected lifecycle migration
commits are replaced by commits that establish the new policy and documentation
structure, retire lifecycle tooling, reconcile specifications by lineage, reclassify
current documentation, remove obsolete artifacts, repair references, and validate the
result. Exact commit boundaries may be refined in the implementation plan.

The migration preserves `.claude/settings.json` and unrelated worktree changes. It does
not merge, enable auto-merge, or publish rewritten history without explicit operator
authorization.

Before publication, fetch and inspect `origin/main` and the remote feature branch. If
`origin/main` advanced, rebase the clean rewritten branch and repeat required validation.
Stop if the remote feature branch contains unexpected commits. When rewriting the known
feature branch is authorized, push only with `--force-with-lease`.

## Validation

Migration work uses focused checks while records and links are reconciled. Final
validation includes:

- focused tests for the simplified link-integrity checker;
- repository-wide link validation;
- repository lint and staged-blob or secret checks where applicable; and
- `mise exec -- just ci` as the canonical full, cluster-independent validation gate.

After any required rebase, rerun affected validation including `mise exec -- just ci`.

## Completion criteria

The migration is complete when:

- `AGENTS.md` defines the approved specification lifecycle and transient plan location;
- `/.tmp/` is ignored;
- current durable documents are navigable through `docs/README.md` and classified under
  `specs/`, `reference/`, `guides/`, or `runbooks/`;
- every legacy decision, review, phase document, and plan has a recorded disposition;
- useful design history is reconciled into 22 consecutively numbered specifications;
- durable specification images use descriptive names without date or specification
  number prefixes;
- source-to-document callouts are self-contained and follow the selective-reference
  boundary;
- former phases have documented durable destinations without remaining a lifecycle;
- the tracked ignore file contains no tool-specific local state path;
- current procedures and facts are reconciled into the appropriate current documents;
- obsolete records, legacy lifecycle tooling, and generated lifecycle artifacts are gone;
- generic link validation passes without lifecycle-specific behavior;
- all repository references point to the migrated locations;
- the full validation gate passes on the final branch state; and
- rewritten branch publication and merge remain separate, explicitly authorized actions.
