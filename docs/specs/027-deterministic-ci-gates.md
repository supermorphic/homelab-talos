# Deterministic CI Gates — Stage 2

## Purpose and authorization

Reduce recomputation of expensive, unrelated validation after a candidate is rebased onto
current main. [Specification 024](024-ci-runtime-and-merge-throughput-optimization.md)
records the Stage 1 cleanup, retained correctness, final runtime evidence, and measured
decision that authorized selective execution for
[issue 303](https://github.com/supermorphic/homelab-talos/issues/303).

This specification owns the Stage 2 architecture. It does not repeat the Stage 1 audit
or authorize runner placement, live tests, a merge queue, or post-merge substitution.

The design favors a small category selector over a generalized dependency planner.
Its value is safely avoiding unrelated work with bounded configuration and maintenance
cost—not achieving an arbitrary two-minute runtime.

## Goals and constraints

- Fresh required evidence covers the complete candidate containing the current main base.
- `mise exec -- just ci` remains the full, offline, secret-free union of retained validation.
- Runtime classification is deterministic and repository-owned.
- Human, agent, and author input can escalate to full validation, never remove a requirement.
  Renovate is classified by its changed inputs, not its identity.
- Uncertain impact causes more validation or a failed gate, never optimistic omission.
- Every required group and suite must execute and pass with results bound to the plan.
- Provider workflows remain thin wrappers around portable repository commands.
- Normal dependency/input caches can accelerate execution; earlier passing results are
  not reused as fresh evidence.
- CI changes do not obtain cluster/deployment credentials, a privileged socket, or
  unnecessary host access.
- Local publication uses the same repository-owned plan and groups under root policy.
  Full `just ci` remains available; authors cannot manually select a reduced path.

## Decision rationale

Keeping full execution for every change is the simplest model, but the completed Stage 1
measurements showed substantial unrelated work still delaying ordinary merges. Selective
execution is justified for that residual cost, not as a substitute for optimizing the tests.

A category for every service or domain would create mapping and enforcement overhead for
many checks that take only seconds. Coarse runtime-based groups concentrate configuration
on worthwhile savings; inexpensive validation remains intentionally broad in core.
Automation is the explicit growth exception, not a general license for speculative groups.

A generalized dependency DAG would add another build system to maintain. The current
repository can instead express its few conditional boundaries through category patterns
and explicit cross-directory consumers. Independent ownership tests check those boundaries;
uncertainty selects full rather than demanding increasingly precise dependency machinery.

This choice can be reconsidered if repository complexity and measured costs change.
Until then, neither a richer planner nor trusted cross-run passing-result storage is a
prerequisite for a useful and correct gate.

## Architecture

```text
current-main base + complete rebased candidate
  -> deterministic plan
  -> core + selected conditional groups
  -> isolated group execution and canonical results
  -> always-running reconciliation
  -> static required merge-gate
```

### Execution groups

| Group | Responsibility and selection |
| --- | --- |
| `core` | Always runs. Repository invariants and all retained offline validation not assigned to another group. |
| `observability` | Monitoring, logging, Loki, Alloy, Gatus, alerting, and their owned validators and fixtures. Runs when those inputs can be affected. |
| `automation` | n8n, automation-data, and their owned operational scripts, validators, fixtures, and cross-domain consumers. |
| `ci-framework` | Catalog, coordinator, campaign, reporting, dispatch, result, and harness-control evidence. Changes to this infrastructure select full. |
| `full` | The exact union of all four execution groups; not a separate test implementation. |

Media, storage, networking, security, documentation, and platform are not separate
scheduling categories. Their inexpensive evidence remains in core; foundational inputs
can select full because they affect shared validation.

A coherent group contributing at least 30 seconds of measured marginal wall time must
be reviewed for extraction. This is a runner-dependent review trigger, not automatic
permission to split. Extraction also needs clear ownership, useful skip frequency, low
ambiguity, and savings that outweigh the added enforcement surface. Automation is the
approved growth exception because its boundary is clear and its consumers are expanding.
The threshold belongs in this design, not as a fixed numeric rule in AGENTS.md.

### Configuration ownership

| File | Authoritative responsibility |
| --- | --- |
| `tests/impact.yaml` | Category input patterns and full-validation patterns. |
| `tests/catalog.yaml` | Suite commands, ordered group membership, assurance metadata, and result contracts. |
| `scripts/test/validate-chainsaw.sh` | Actual harness work selected for each group and its non-executing listing. |
| `scripts/test/ci_plan.py` | Classification and base/head-bound plan creation. |
| `scripts/test/run-ci.sh` | Catalog execution and canonical group-result binding. |
| `scripts/test/ci_reconcile.py` | Required group and suite reconciliation. |

Do not copy commands or per-test dependencies into the impact map. Do not build a
per-application target registry or generalized DAG merely to support these groups.
Detailed current patterns and memberships live in the executable configuration, not
duplicated lists in this specification.

## Input ownership and fail-broad classification

The existing folder layout supplies broad ownership boundaries:

- Monitoring-owned application paths select observability in addition to core.
- Automation application paths and owned operational commands select automation.
- Cross-directory inputs retain every real consumer. For example, networking routes,
  gateway configuration, alert resources, and monitoring fixtures can affect automation
  or observability even when they are outside those domains' folders.
- Repository-wide public-route and internal-DNS invariants remain in core. An unrelated
  application change must not bypass a global uniqueness check.
- CI workflows, planner/reconciler code, catalog, shared harness libraries, and shared
  foundational infrastructure select full. Owned test files and scenario documents can
  select `ci-framework` with their other actual consumers.
- Other known, non-shared application paths select core.

The flat script and fixture trees need deliberate ownership, not assumptions based on
filenames or programming language. New validation belongs in core unless a reviewed
conditional boundary applies; new unmapped or shared infrastructure must fail broad.

Unknown paths, missing/deleted mappings, malformed configuration, and ambiguous
relationships select full or fail the gate. Invalid revision identities cannot produce
a reduced plan. Renames and copies classify both old and new paths. A changed policy or
classification mechanism itself cannot use a reduced path.

A rebase produces a fresh plan but does not automatically select full. An unrelated
change already validated on main does not make all candidate evidence affected.
Relevant shared inputs broaden the selection, and every selected target still executes
against the complete rebased tree.

### Impact reassessment after validation cleanup

CI selection follows actual executable consumers. General documentation selects `core`
for structural/link checks; it no longer selects framework or automation groups merely
because tests formerly inspected guide prose. Chainsaw test documents still select their
lint/catalog owners, and n8n smoke selects automation as an actual consumer.

Shared bootstrap/repository modules, CI gate code, catalog inputs, and unknown paths
remain fail-broad. The ownership fixture independently identifies required evidence;
planner tests keep `core` mandatory and full selection equal to the ordered group union.
[The earlier reassessment](https://github.com/supermorphic/homelab-talos/pull/471)
records the initial reductions; `tests/impact.yaml` owns the current mapping.

## Harness decomposition and exact-once ownership

The general harness is part of CI, not the whole CI flow. Its decomposed catalog identities
are `validation.test-harness-core`, `validation.test-harness-observability`,
`validation.test-harness-automation`, and `validation.test-harness-ci-framework`.
Each group combines its harness work with existing standalone catalog suites.

Each retained work unit has one owner. Full execution and the group union must contain
the same evidence exactly once. Decomposition does not delete tests or duplicate them
under multiple groups. Shared runner libraries preserve the Stage 1 isolation, bounded
workers, ordering, and failure semantics.

Listing and execution use the same Python discovery rules. Core production-validator
regressions belong with their production checks, rather than in framework-only execution
merely because they are Python modules. Recursive discovery must not silently assign
the same module to multiple groups.

### Independent ownership contracts

`tests/fixtures/ci-impact/ownership.yaml` is a small, test-only set of reviewed
changed-input-to-required-evidence examples. It stores no expected groups and is never
read by the runtime planner.

Planner tests classify each input separately, obtain actual catalog group memberships,
harness listings, and Python discovery, and require the named evidence. Stale input paths
and missing evidence fail. Separate inventory assertions check full/group equality and
unique ownership.

The examples cover core validator regressions, the conditional boundaries, and real
cross-directory consumers. Reviewers derive them from actual scripts, imported helpers,
fixtures, and configuration. They are independent expectations, not generated copies of
the impact map. This guard detects disagreement between intended coverage, classification,
and execution; it is not automatic dependency discovery.

## Plan identity and execution contracts

A plan records its schema version, exact base and candidate-head identities, mode,
selected groups, reasons, and deterministic plan identity. Planning verifies usable commit
identities and required ancestry. Unresolved revisions or an invalid plan fail safely.

Repository commands expose planning, explicit full escalation, group execution, and
reconciliation through `tests/mod.just`. Each group:

1. uses the plan's exact candidate tree;
2. executes its complete ordered catalog membership;
3. preserves the canonical reporting contract from
   [specification 011](011-test-reporting-standard.md); and
4. binds its results to plan identity, base, head, group, and execution identity.

A group cannot substitute another plan's artifact or omit a suite behind a passing
aggregate. Immutable dependencies and intermediate inputs may be cached, but each
required validation obtains fresh passing evidence. Report generation consumes results
without reevaluating validators.

## Merge enforcement and contributor trust

After the authorized transition, branch protection requires one static `merge-gate`,
not separate conditional branch checks. The workflow always starts; top-level path
filters must not skip the required workflow entirely.

Reconciliation checks both required provider job conclusions and canonical artifacts.
Missing, duplicate, unexpected, failed, cancelled, unexpectedly skipped, or mismatched
required results fail the gate. Apparently passing artifacts cannot override failed
planning or execution jobs. Optional presentation/reporting cannot hide failed validation.

The reconciler resolves catalog membership from the immutable candidate commit recorded
in the plan. An unavailable commit or inaccessible/malformed catalog is a configuration
error. Each group must contain exactly its expected suites, with every required suite
passed independently of aggregate status. Downloaded group artifacts remain separate
rather than overwriting one another.

The current single-operator, trusted-contributor model relies on branch/review policy,
full selection for framework changes, and the static required check. Trusted repository
administrators can change their own validation policy. A protected base-owned planner or
hostile-PR bootstrap architecture is not required. Interfaces remain compatible with a
later base-owned planner if the contributor model changes.

These assumptions do not relax public-artifact handling or runner isolation. Forgejo
deployment and runner-isolation initiatives must prove their own PR execution and
credential boundaries before Forgejo becomes authoritative. No author label, agent
judgment, or risk declaration can de-escalate the repository's plan.

## Rollout and rollback

The rollout establishes correctness before skipping validation:

1. **Shadow planning:** full `ci` remains authoritative while the planner reports its
   proposed groups. Review natural PR plans and use local fixtures for absent change classes.
2. **Split-all parity:** run all four groups in isolated provider jobs with advisory
   reconciliation. Temporarily retain the required full job. Prove equivalent evidence,
   failure handling, artifact identity, and reporting before relying on the replacement.
3. **Protection transition:** after the split workflow is merged and proven, change
   protection only with explicit operator authorization and verify strict-main readback.
4. **Selective enforcement:** use the actual plan for PR jobs only after `merge-gate`
   is required. Remove the temporary duplicate full job. Manual full escalation remains.
5. **Post-enable review:** measure savings, skip frequency, overhead, and maintenance cost.

Provider evidence follows publication; protection proof covers the merged workflow.
Keep the temporary full-plus-split phase bounded to parity work. No merge or protection
change is implied by general implementation approval.

Rollback selection by forcing full through the same groups and reconciler. If grouped
execution itself is defective, restore the known full workflow with a coordinated
protection change; never bypass validation or leave a nonexistent required check.

## Measurement and acceptance

### Local publication validation

The optional local `ci-publish` command reuses the hosted planner, grouped execution,
and canonical reconciliation. Its receipt binds the clean candidate and freshly fetched
base, so an edited branch or newer main needs fresh validation. This shared selection
path avoids a second classification system. Current contributor procedure is in the
[repository validation policy](../../AGENTS.md#validation);
the executable contract is in the [CI impact map](../../tests/impact.yaml) and
[planner](../../scripts/test/ci_plan.py).

### Evidence requirements

Measure validation separately from queue/start, checkout, tool setup, report finalization,
and reconciliation. Include runner consumption alongside critical-path wall time.
Record revision, toolchain, cache conditions, selected groups, evidence identity, and
outcome with measurements in retained test evidence, not a running log in this specification.

Compare full and split execution on equivalent candidate trees. Provider synthetic merge
commits and PR heads are distinct identities; establish tree equivalence before comparing
their evidence. Keep fixed-revision measurements valid when main advances, but obtain
fresh merge evidence for a new candidate.

Report small samples as count, median, and range, not a dependable p95. Do not combine
different revisions into a controlled distribution or impose a benchmark quota merely
to finish rollout. Concurrent three/five-job batches measure capacity; serialized
merge/rebase drain requires observing those sequences or clearly labeling a latency model.

Acceptance requires:

- representative core, conditional, combined, full, rename, and uncertain-input coverage;
- independent ownership checks and complete exact-once group/full parity;
- fresh identity-bound evidence and rejection of missing or failed required execution;
- provider failure/cancellation and protection-transition proof;
- useful reduction in unrelated work with bounded map maintenance and runner overhead; and
- a retained full fallback and accurate documentation of unmeasured claims.

If core becomes the bottleneck, continue intrinsic optimization rather than multiplying
categories. No runtime number overrides correctness or justifies unnecessary machinery.

## Implementation status

Stage 2 rollout is complete: pull requests plan affected groups, manual dispatch selects
full validation, and protection requires `merge-gate` with strict current-main checks.
The optional local publisher uses the same planner and checks candidate/base identity.
The [rollout closeout](https://github.com/supermorphic/homelab-talos/pull/402) records
full/grouped equivalence, cancellation failing the gate, selective execution, protection
readback, and local publication acceptance.

Initial provider observations showed comparable core and longest-group durations.
Selection can save aggregate validation work while providing smaller wall-time savings;
optimize core when it limits the critical path. Long-term variance and skip-frequency
observations are ongoing tuning, not unfinished rollout requirements.

Local groups execute sequentially with bounded parallelism inside each harness. Increasing
local group concurrency needs host-wide resource and wall-time measurements because
worktrees share the host; isolated provider runners do not have that same boundary.
Command help owns invocation details; retained reports and PRs own execution evidence.

## Deferred work

Runner placement and advanced evidence reuse are outside this implementation.
The Stage 3 boundary and deployment/isolation dependency handoff remain in
[specification 024](024-ci-runtime-and-merge-throughput-optimization.md).
A later measured decision and new numbered implementation specification must authorize
that work. This design does not assume an off-cluster runner is faster, prescribe a benchmark protocol,
or introduce trusted cross-run attestations.

## Repository protection recovery

[The tracked checker](../../scripts/repository/github_protection.py) owns exact required
repository settings and rules. Its objective is that `main` advances only through a
current successful squash pull-request merge, without bypass actors. Repository merge
settings and the ruleset must agree; an update restriction with no bypass actors would
also block valid GitHub merges.

The checker needs Administration access to inspect the bypass list and effective rules.
A passing ruleset check does not inspect the separate legacy branch-protection API:
also verify no legacy rule targets `main` in GitHub Settings. Ruleset availability is a
protection prerequisite; a plan/visibility-related HTTP 403 is failed protection, not
permission to continue without enforcement. Confirm support before changing visibility.

Use `mise exec -- just repo github-protection-check`, then `github-protection-plan` to
review drift. Repair only through `github-protection-apply` with specific operator
administrative authorization and its exact repository-bound confirmation; it reads back
the effective contract. Duplicate managed rulesets or unrelated effective rules require
deliberate resolution rather than guessing. That authorization does not permit a merge.
Verify functional behavior using a real PR and a new candidate commit. Never probe
protection with a direct push to production: a broken rule could let Flux deploy it.
