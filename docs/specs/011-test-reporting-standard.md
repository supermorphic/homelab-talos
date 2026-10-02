# Test Reporting Standard

## Purpose

Use one evidence contract for offline validation, live acceptance, controlled disruption,
measurement, and Kubernetes conformance while choosing each runner for the behavior it
can express clearly. A universal framework would make filesystem, API, and temporal
recovery cases harder to observe without making their evidence more comparable.
[Repository policy](../../AGENTS.md) owns authority, [the catalog](../../tests/catalog.yaml)
owns suite identity, effects, access, membership, and dispatch, and
[result tooling](../../scripts/test/validate-run.sh) owns exact bundle fields.

## Assurance boundaries

Offline validation is cluster-independent and secret-free. Hosted
[merge reconciliation](027-deterministic-ci-gates.md) selects the required offline work;
`mise exec -- just ci` remains its complete local union. Live checks and tests never
enter CI merely because CI validates their runners. Native JUnit findings and lifecycle
outcomes remain visible; fail-fast accounts for remaining suites as skipped rather than
silently omitting them.

Verification and smoke observe live state without deliberate target mutation. Integration
and end-to-end tests prove controlled cross-component or user workflows. Resilience
separately proves disruption and recovery. Measurements capture a property rather than
constituting an assurance tier by themselves. Diagnostics support troubleshooting rather
than assurance campaign membership. Gatus and alerts provide current observability;
they do not replace controlled run history.

Sonobuoy is ephemeral and on demand, never a standing or scheduled cluster workload.
Quick mode proves a validation subset; only certified mode supplies upstream Kubernetes
conformance evidence. Run, retrieve, and delete are one owned transaction. Only the E2E
plugin is used because Talos lacks the conventional systemd journal expected by the log
plugin. Raw archives can include resources and logs with sensitive values: safe summaries
and non-vacuous E2E JUnit enter canonical evidence, while failed-run archives stay in the
ignored private-results area and never enter Allure or public artifacts.

## Execution and serialization

Catalog metadata and reachable operations must agree with actual credential grants.
Adding a suite does not automatically enroll it in a campaign; membership is a reviewed
coverage decision. Unknown live dispatch targets fail closed. Resources created by tests
carry run identity, and cleanup remains limited to that owned state.

Confirmation binds intended action and target, with source and plan binding for disruptive
campaigns. It does not grant authority. Catalog execution ownership, task authorization,
credential capability, confirmation, and publication remain independent controls.
Diagnostic credentials are reduced privilege: approved verifiers can use narrow pod
subresources, so non-mutating metadata is not a claim that the credential is read-only.

Read-oriented suites can run concurrently. Shared state-changing tests and campaigns
hold the renewable disruption Lease; children join the parent's verified holder without
acquiring or releasing it. Holder mismatch or renewal failure invalidates further
mutation. [Node lifecycle](025-node-lifecycle-and-maintenance.md) owns the persistent
containment boundary that remains after a disruptive process exits. Publication has a
separate Lease and cannot release or override disruption ownership.

## Canonical evidence and result meaning

Each child has a collision-resistant canonical run under ignored `.test-results/`.
JUnit plus structured summary, environment, and allowlisted evidence form the durable
interface. The result validator rejects unsafe paths, symlinks, unexpected files,
unindexed evidence, malformed metadata, and finalized zero-case JUnit. Native diagnostic
JUnit is not ingested again as duplicate test cases. The presentation layer must be
regenerable from canonical evidence without a second report schema or database.

- `passed`: assertions and required finalization succeeded.
- `failed`: trustworthy assertion evidence demonstrates a violation.
- `broken`: harness, infrastructure, dependencies, diagnostics, cleanup, recovery, or
  finalization could not provide a valid conclusion.
- `skipped`: deliberately excluded, inapplicable, or unexecuted after fail-fast.

Primary assertion, external dependency, diagnostics, cleanup, recovery, and finalization
remain distinct. Cleanup cannot overwrite a failed experiment; cleanup failure cannot
produce a pass. Restoring service remains an obligation after a failed assertion.

## Recorded evidence and publication

Intentional initiative completion and infrequent bootstrap, setup, initialization, or
recovery assurance use `mise exec -- just test record <suite-id|scoped-verification>`.
The recording action grants publication intent separately from suite execution authority.
Routine CI, iterative verification, scoped campaigns, and diagnostics stay local.
Record post-operation acceptance rather than rerunning initialization to obtain a report.
Individual offline checks do not all emit a canonical run; use the catalog's CI aggregate.

The scoped `homelab-report-publisher` is selected only for publication, never suite
execution. Its access is confined to report storage, source reads, and the named
publication Lease. Outside that approved linked-worktree path, publication requires exact
run-scoped manual confirmation. Preflight failure never permits broader credentials.

Allure creates inert HTML from canonical evidence. Caddy serves those files without an
upload API, API credentials, or ServiceAccount token. A workstation publisher validates
and secret-scans exact input and output, rejects unsafe paths and oversized or mismatched
content, and streams a deterministic checksummed archive under the publication Lease.
Installer and publisher order complete relative paths identically by bytes. Exact run
installation precedes atomic switching of the active generation. Same ID and digest is
idempotent; different content under the same ID is rejected.

This push model keeps authenticated writes and cluster credentials out of CI and the
report service. The retained single-writer claim uses `Recreate`; prune protection keeps
Kustomization removal from authorizing evidence deletion. Content-addressed runtime
configuration triggers replacement when the serving configuration changes.

Clean feature or historical runs are candidate evidence. Authoritative runs must bind a
clean captured SHA equal to both current main and deployed Flux. Publication rechecks
source and Lease immediately before installation. Only authoritative completions drive
latest links, Homepage status/times, and last-run metrics. Lifetime counters and retained
last-failure state survive pruning; the latest comparison point is protected separately
from normal age/count limits. Service availability remains distinct from test status.
Low-cardinality metrics omit run IDs, SHAs, node identities, and URLs; links lead to exact
reports rather than turning Prometheus into the evidence store.

Retained reports are served through the internal Gateway. Use the exact report URL
printed by publication; the canonical download and exact-run archive remain retrievable
without the local worktree. Detailed execution evidence belongs there, not in a spec or
issue transcript.

## Campaign failure and recovery

A campaign coordinates canonical children; its journal is orchestration state, not a
second aggregate verdict. Execution freezes source, ordered membership, and plan digest.
Operator-published campaigns require clean current main and matching deployed Flux;
confirmation binds the frozen plan. Scoped local verification freezes its local source
and membership, needs no confirmation or disruption Lease, and cannot publish or resume.

Validation failure stops composed campaigns. Smoke failures can be collected but prevent
later state-changing stages. A valid failed assertion may be retained and followed by
independent safe children. Broken/invalid evidence, Lease loss, unsafe or unclassified
cleanup/recovery, publication uncertainty, or source drift stops continuation. Complete
safe child cleanup even when source drifts; a fresh campaign is required for new authority.

Only supported publication failure is resumable. Use the printed
`mise exec -- just test record-resume <session-id>` or guarded campaign-resume command.
Resume validates the frozen catalog/source authority, republishes pending finalized
children, skips completed execution, and continues only eligible unstarted members.
Unsafe results never authorize further suites. If only publication needs retrying after
source advances, `mise exec -- just test publish <run-id>` retains that exact finalized
run under candidate/authoritative rules without running or resuming anything.

Automation-data provisioning is standalone because it rotates runtime credentials and
requires fresh matching n8n/automation-data backups before restore. Host-local disposable
NocoDB integration is likewise standalone; attended electrical node loss is excluded from
automatic campaigns. Exclusion preserves recovery and physical-attendance boundaries,
rather than claiming `full` covers every possible procedure.

## Reconsideration boundaries

An upload service, CI-to-cluster bridge, in-cluster publication, or broader credentials
requires a separate trust-boundary design. A new runner must still emit the canonical
contract. Load or soak coverage needs defined service objectives and failure thresholds.
Controlled media-pipeline, isolated Longhorn restore/replica recovery, and SMB remount
coverage remain incomplete: safe run-owned state and cleanup must be designed before
those results can be claimed. Existing readiness and backup-configuration checks do not
prove those recovery outcomes.
