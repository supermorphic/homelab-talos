# Kubernetes test framework

This tree contains declarative, repository-owned test inputs:

- `catalog.yaml` is the machine-validated inventory of validation, verification,
  test, diagnostic, probe, and conformance suites. It owns stable reporting
  metadata and the live Chainsaw dispatch registry.
- `config/` holds the pinned Chainsaw runtime configuration.
- `chainsaw/` holds live `smoke/`, `e2e/`, and `resilience/` scenarios.
- `policy/` holds cluster-independent Conftest/Rego policy.
- `fixtures/` holds controlled test data, including a lint-only Chainsaw test
  that is never part of live scenario discovery.
- `probes/` holds specialized network/API measurements — a measurement
  primitive, not an assurance tier. Each probe's pure analysis logic is
  unit-tested offline; the live capture is operator-run. A probe may create a
  run-owned ephemeral reference workload when its catalog entry explicitly
  declares that mutation. Bash probes reuse the in-cluster exec pattern; Python
  test tools use `uv` with locked dependencies and stdlib `unittest`. Current
  probes: `qbittorrent/` (VPN
  egress + forwarded-port point checks), `vpn/` (the continuous in-netns VPN
  leak sentinel), and `dns/` (active DNS-isolation: DNS resolves only via the
  Gluetun loopback resolver; LAN/home and cluster resolvers stay unreachable).

See `docs/reference/testing-layers.md` for how these layers fit together (Gatus continuous /
Chainsaw smoke routine / Chainsaw resilience controlled-failure / Sonobuoy
`just kube conformance` on-demand). Sonobuoy is ephemeral — never scheduled or standing.
The [repository command lifecycle](../docs/reference/repository-command-lifecycle.md)
defines the shared semantic boundary: verification remains observational toward its
target, while deliberate temporary mutation uses a controlled test and its ownership,
confirmation, evidence, cleanup, and recovery controls.

`mise exec -- just test validate` is the complete cluster-independent command in
this module. It validates `catalog.yaml`, lints Chainsaw configuration and tests,
parses their YAML assets, validates the canonical repository shell source set,
executes the shell unit-test suites, and runs Python unit tests via `uv run
--locked python -m unittest`. It deliberately uses a nonexistent kubeconfig and
unsets SOPS age-key variables. `mise exec -- just test catalog-validate` runs
only the catalog checks.

## Deterministic CI groups and ownership checks

For retained acceptance after initiative completion, bootstrap, setup, or recovery, use
the [recorded evidence procedure](../docs/guides/test-campaign-operations.md#record-initiative-and-infrequent-assurance).

The Stage 2 runtime selector has four execution groups: always-running `core`, plus
`observability`, `automation`, and `ci-framework`. `full` selects their exact union.
The provider workflow plans affected groups for pull requests and exports that plan
to the job matrix. `core` always runs. Manual dispatch requests all four groups.
The required `merge-gate` reconciles their separate results; the duplicate full `ci`
job has been removed. The local publication gate uses the same plan and groups.

| File | Responsibility |
| --- | --- |
| `tests/impact.yaml` | Runtime path rules: select groups or full fallback. |
| `tests/catalog.yaml` | Commands and suite membership for each execution group. |
| `scripts/test/validate-chainsaw.sh` | Run or list the actual harness work in each group. |
| `scripts/test/core/test_public_webhook_routes.py` and `test_internal_dns_endpoints.py` | Core-owned production-validator regressions, discovered separately from framework tests. |
| `tests/fixtures/ci-impact/ownership.yaml` | Test-only examples connecting changed inputs to required catalog or harness evidence; no expected groups. |
| `scripts/test/test_ci_plan.py` | Test the real selector against rules and independent coverage examples. |
| `scripts/test/validate-harness-groups-test.sh` | Check exact-once harness membership and full/group equality. |
| `scripts/test/ci_plan.py` | Create a deterministic plan bound to base and candidate commits. |
| `scripts/test/run-ci.sh` | Execute catalog suites and bind canonical group results to the plan. |
| `scripts/test/ci_reconcile.py` | Require complete passed results for every selected group and suite. |
| `.github/workflows/ci.yml` | Provider checkout, execution, and artifact handling. |

The ownership fixture does not schedule CI. It checks that the actual selected groups
contain the catalog suites and harness evidence reviewers know are required. Catalog
suite identities use `catalog:<suite-id>`; shell and Python identities come from the
real harness listings and discovery:

```text
reviewed changed input -> real classifier -> selected groups -> catalog + harness listings
reviewed required tests --------------------------------------> membership assertion
```

For example, editing the internal DNS validator must select a group that executes its
Python regression tests. Checking only that its path selects `core` would miss a test
accidentally assigned to `ci-framework`. Review source consumers and fixtures when adding
conditional coverage; do not infer ownership solely from the language or test directory.

Inspect work without running it:

```sh
mise exec -- bash scripts/test/validate-chainsaw.sh --list core
mise exec -- bash scripts/test/validate-chainsaw.sh --list observability
mise exec -- bash scripts/test/validate-chainsaw.sh --list automation
mise exec -- bash scripts/test/validate-chainsaw.sh --list ci-framework
```

Run the focused ownership and group-union checks:

```sh
mise exec -- uv run --locked python -m unittest scripts/test/test_ci_plan.py
mise exec -- bash scripts/test/validate-harness-groups-test.sh
```

The enforced workflow is:

```text
exact current-main base + rebased candidate head
  -> ci-plan -> core + selected groups -> ci-group -> ci-reconcile -> merge-gate
```

The full `mise exec -- just ci` command remains available. See
[Spec 027](../docs/specs/027-deterministic-ci-gates.md)
for the shadow, split-all, and selective rollout checkpoints and protection transition.

### Optional local publication validation

For a local reproduction of hosted selection or a CI change, commit the candidate,
leave the worktree clean, and run `mise exec -- just test ci-publish`. The command fetches
`origin/main`, requires it to be an ancestor of the candidate, and runs the groups
selected by the same impact map used on GitHub. For example, ordinary spec edits
select core; an automation-owned edit also selects automation; shared framework edits
select all groups. Documentation with declared consumers can select more than core.

Groups run sequentially locally, preserving each harness's bounded concurrency.
`mise exec -- just test ci-publish-full` escalates to all groups. No command option
allows choosing a reduced group set or supplying an older base.

Keep this worktree untouched while validation runs. The command rejects staged,
unstaged, and untracked changes and checks the branch/head again during and after
execution. It fetches main again before success; if main advanced, rebase and rerun.
Fetch failures cannot fall back to stale remote tracking refs. The wrapper needs network
access to Git; the validation groups remain offline, secret-free, and cluster-independent.

Each invocation retains its plan, separate canonical group results, reconciliation,
and final `publication.json` receipt under ignored `.tmp/ci-publication/`. A receipt
applies only to its recorded branch, head, and base. Failed or cancelled runs do not
produce a passing publication receipt. A successful group reconciliation alone is not
publication approval if the final candidate/base checks fail. Never reuse an earlier
receipt after edits or rebase. The command does not push or modify branch protection;
the pre-push fetch and remote-branch checks in AGENTS.md still apply.

### Retrying a provider run

Use **Re-run all jobs** when retrying this workflow, or run
`mise exec -- gh run rerun <run-id>`. Do not select only failed jobs or an individual
group or gate. Plans and result artifacts include the workflow run attempt in their
names. A partial retry starts a new attempt without recreating successful dependencies'
artifacts, so the group or gate cannot download its required inputs and fails safely.
A complete retry produces a fresh plan and every required result in the same attempt.

After editing or rebasing the candidate, use the new PR run. Retrying an older run
validates its original revision, not the updated branch.

## Offline harness execution

The offline harness keeps its cheap/high-signal and repository-mutating shell
checks in a serial preflight. It then runs the remaining isolated shell cases
with four bounded workers. Each worker receives a private temporary directory;
console output and JUnit fragments remain in repository declaration order. A
failure stops new work, cancels and accounts for active workers, and leaves the
unstarted tail absent for the outer fail-fast reporter. Set
`TEST_HARNESS_JOBS=1` for a diagnostic serial run. Values from 1 through 8 are
accepted. This changes how the complete suite executes; it does not select or
omit tests based on changed files.

The logging verifier fixture covers 65 layouts, including delayed port-forward startup.
The harness runs them as four deterministic groups: topology/storage/runtime, labels,
counts/compaction, and Prometheus targets. The existing four-worker harness
owns their concurrency; the fixture does not create a nested worker pool.

Repository validation owns Bash syntax and one batched machine-readable
ShellCheck execution. The historical audit count of 166 shell files is audit
history, not a fixed contract. The current sorted set is derived independently
from tracked and unignored `.sh` files under the repository shell directories,
including `scripts/operations`, `scripts/talos`, and the automation-data PostgreSQL
application scripts. Bash
checks run first and stop at the first exact file and stderr failure; ShellCheck
runs only after Bash passes. During one full CI run, the harness reuses only the
matching passed repository artifact and does not emit a duplicate JUnit
fragment. A standalone harness run, or any missing, failed, stale, malformed,
truncated, schema-invalid, status-inconsistent, or corrupt artifact, always
recomputes the complete canonical validation and writes its harness JUnit
fragment when result fragments are enabled.

For campaign selection, cadence, recorded acceptance, publication, and resume, use the
[test campaign guide](../docs/guides/test-campaign-operations.md). Current membership and
effects come from [`catalog.yaml`](catalog.yaml).

Application acceptance steps are in the
[n8n guide](../docs/guides/n8n-operations.md#activation-upgrade-and-recovery-change-acceptance)
and the [automation-data guide](../docs/guides/automation-data-operations.md#5-validate-provisioning-and-rotation).

Live commands remain outside `just ci`. [`AGENTS.md`](../AGENTS.md) defines their
authority boundaries: agents may run approved scoped verification with task-local
credentials, while deliberate mutation or broader access requires the applicable
authorization. Use the [agent cluster access guide](../docs/guides/agent-cluster-access.md)
and each suite's catalog access tier to select an approved workflow.

- `mise exec -- just test smoke cluster`
- `mise exec -- just test smoke cluster diagnostics-self-test` (expected failure)
- `mise exec -- just test smoke media qbittorrent`
- `mise exec -- just test smoke media qbit-manage`
- `mise exec -- just test smoke platform` (all platform readiness suites) or
  `mise exec -- just test smoke platform <cluster|flux|gateway|dns|cilium|longhorn|portainer|smb>` (one).
  Read-only resource-readiness per subsystem. The `just kube *-verify` recipes provide
  deeper observational checks according to their catalog access tiers. Deliberate
  mutation, such as the Cilium connectivity test or a test-PVC provisioning check,
  uses a separate registered test workflow. The scenario list is an explicit
  registry — a bare `smoke platform` runs only suites labelled `homelab-talos/suite=platform`.
- `mise exec -- just test diagnostics cluster`
- `mise exec -- just test probe qbittorrent`
- `mise exec -- just test probe vpn-leak`
- `mise exec -- just test probe dns-isolation`
- `mise exec -- just test integration media-hardlink` (run-owned mutation only: proves the media-data SMB
  share preserves hardlinks across `/data/downloads` ↔ `/data/media` and checks both
  concurrent-open orders between the qBittorrent and Plex containers. It uses one
  throwaway file, no external download, and removes its test paths.)
- `NTFY_PUBLISH_TEST_CONFIRM=test:ntfy:publish:media-critical-homelab mise exec -- just kube ntfy-publish-test`
  (runs the observational ntfy verifier first, then sends exactly three positive ACL test
  notifications to `media`, `critical`, and `homelab`; included in integration and weekly)
- `CLUSTER_E2E_CONFIRM=e2e:qbit-manage-policy mise exec -- just test e2e qbit-manage-policy`
  (up to 60 minutes; downloads WebTorrent's legal Sintel fixture through qBittorrent's VPN
  egress, observes the deployed public classification, proves private-tag exclusion, applies
  isolated one/two-minute share limits, verifies Stop + recycle cleanup and hardlink survival,
  reruns cleanup idempotently, and tears down only exact run-owned state). A download timeout
  records a bounded summary of tracker states, reported swarm size, DHT state, and web-seed
  count for that fixture. The summary excludes tracker URLs, messages, peer addresses, and
  credentials. The test force-starts only its run-owned fixture while downloading, so an
  existing qBittorrent download queue cannot stall the fixture. It clears force-start
  before testing share limits and cleanup. On failure, teardown also attempts to clear
  force-start on the owned fixture before deletion, and still attempts deletion if the
  reset fails. Failed cleanup remains a failed result that requires operator recovery.
- `FLUX_ALERT_E2E_CONFIRM=test:flux-alert:firing-resolved mise exec -- just kube flux-alert-delivery-test`
  (about 25 minutes; creates one labeled Flux Kustomization with a deliberately nonexistent
  source, waits through the production 15-minute alert timer, proves the firing and resolved
  notifications reached ntfy by exact run-specific cached titles, and deletes only that
  run-owned resource; requires the private read-only `flux-alert-test` token to be
  available to the suite, including when run through `test record` or an operator campaign)
- `CLUSTER_CHAOS_CONFIRM=chaos:<target> mise exec -- just test resilience <target>`
- `CLUSTER_CHAOS_CONFIRM=chaos:qbittorrent-vpn-disconnect mise exec -- just test resilience qbittorrent-vpn-disconnect`
  (controlled VPN stop→recovery: continuous leak-sentinel evidence that the kill switch
  fails closed across the outage, then pod-recreation recovery; records recovery status
  separately in `summary.json`)
- `CLUSTER_CHAOS_CONFIRM=chaos:qbittorrent-pod-recreation mise exec -- just test resilience qbittorrent-pod-recreation`
  (deletes the qBittorrent pod and proves startup-gating — the app container starts only
  after Gluetun's native-sidecar startup gate — and config persistence — the same Longhorn
  PV re-attaches and a marker survives — across the recreation)
- `CLUSTER_CHAOS_CONFIRM=chaos:plex-cross-node-reschedule mise exec -- just test resilience plex-cross-node-reschedule`
  (controlled cross-node reschedule under cordon — NOT a drain: cordons Plex's node and
  evicts the pod, proving the Longhorn RWOP config volume re-attaches on the landing node
  (Longhorn currentNodeID moves), a /config marker survives, and the SMB share re-mounts;
  restores only the node it cordoned)
- `CLUSTER_CHAOS_CONFIRM=chaos:node-abrupt-loss NODE_ABRUPT_LOSS_CONFIRM=remove-power:<node>:<ip> mise exec -- just test resilience node-abrupt-loss <node>`
  (DOUBLE-GATED, attended, and standalone: starts external five-second probes, requests
  actual electrical disconnection without a prior cordon or drain, proves Talos,
  Kubernetes, and target-etcd loss while the two-member quorum survives, then persists
  containment. It observes autonomous workload, PVC, Longhorn, Cilium, API, DNS, and HTTPS
  behavior for ten minutes before requesting electrical restoration and completing the
  common cordoned recovery acceptance. It is intentionally excluded from campaigns.)

The retired Plex-node reboot assertions remain allocated to
`plex-cross-node-reschedule`: replacement readiness, unchanged PVC identity, Longhorn
attachment, persistence marker, and SMB remount. Routine node reboot behavior belongs to
`mise exec -- just node reboot <node>` and is not a resilience test.

Every live command requires an explicit registered target. Smoke additionally
accepts an optional registered scenario after the target; target and scenario
names are not interchangeable. Integration includes `media-hardlink` and the cataloged
`test.ntfy-publish` command; E2E registers the
exact-confirmation-gated `qbit-manage-policy`; resilience targets are explicitly registered.
The Flux alert E2E is exposed as a guarded `just kube` recipe because it exercises the
production alert duration rather than the generic direct-test dispatcher. Unknown targets
fail closed. Live commands must never enter `just ci`.

Every coordinated run writes a collision-resistant canonical directory. This
includes `just ci`, live verification, focused script tests, probes, Chainsaw,
diagnostics, and Sonobuoy:

```text
.test-results/<UTC>-<sha12>-<origin>-<random8>/
├── junit.xml
├── summary.json
├── environment.json
├── evidence.json
├── logs/
└── diagnostics/
```

Nothing else is allowed at the run root. Native evidence lives below
`diagnostics/`, including phase records, generated non-secret manifests, and
timelines. `evidence.json` indexes every regular file below `logs/` and
`diagnostics/` with sanitized relative paths. Run `mise exec -- just test
result-validate <run-id>` to validate a stored run.

`summary.json` carries the catalog dimensions, result classification, JUnit
counts, and independent assertion/diagnostic/cleanup/recovery phases.
`environment.json` carries Git, host, tool, and cluster context. Artifacts record
only a confirmation variable name, never its value. A failed cleanup makes the
command non-zero without replacing the primary assertion outcome; fixture
unavailability is an external-dependency failure rather than a policy assertion.
A failed diagnostic collection is recorded separately and cannot turn a failed
assertion into a pass. Canonical JUnit adds stable external-dependency, cleanup,
recovery, diagnostics, and finalization lifecycle cases; non-applicable phases
are skipped and harness failures are errors. Untouched Chainsaw `JUNIT-STEP` XML
is retained as `diagnostics/chainsaw-junit.xml`.

Sonobuoy archives are retained below `diagnostics/sonobuoy/`.

`just ci` is one fail-fast multi-suite run. Conftest and kubeconform emit native
JUnit, ShellCheck JSON and Python unittest are adapted without collapsing their
individual findings/cases, and Bash-only commands receive wrapper cases. A
failed suite stops execution while every remaining catalog suite is recorded as
skipped. Each hosted validation group writes its own canonical run. In the workflow
run's **Artifacts** section, download `ci-group-<group>-<run>-<attempt>` for canonical
results and `allure-group-report-<group>-<run>-<attempt>` when static report generation
succeeded. These artifacts have 90-day retention. The required gate also uploads
`merge-gate-<run>-<attempt>` with its reconciliation result and writes a job summary.

The coordinator resolves the complete ordered CI execution list before it starts
the first suite. Each suite receives `/dev/null` as stdin. A validator cannot
consume later suite IDs or wait for interactive input, and an empty or failed
execution-list lookup fails before suite execution.

`mise exec -- just test ci-reconcile PLAN RESULTS OUTPUT` checks downloaded group
results against the plan and the complete catalog executions from its exact candidate
Git commit. Every expected suite must be present and passed; unexpected suites fail.
The candidate commit and its `tests/catalog.yaml` blob must be available locally.
Reconciliation does not use a changed working-tree catalog as evidence for that commit.
The hosted `merge-gate` runs this reconciliation for all groups selected by the plan.

Node.js and Allure are pinned through mise. Generate static Awesome reports with
`mise exec -- just test report <run-id>` or `report-latest`; output is
`.test-reports/<run-id>/awesome/`. `report-open <run-id>` starts Allure's local
static server and opens a browser until Ctrl+C. Latest selection uses the
finalized `summary.json` `end` timestamp, not directory modification time.
Only canonical `junit.xml`, validated root metadata, and evidence-indexed files
are staged for Allure, preventing native diagnostic XML from being counted
twice and excluding unindexed files.

Use the [campaign guide](../docs/guides/test-campaign-operations.md#run-a-standalone-suite)
to publish a finalized run. The [persistent report reference](../docs/reference/test-reports.md)
covers archive viewing, storage, and retention. GitHub Actions retains its own artifacts
and does not publish to the cluster archive.

`scripts/test/junit_report.py` owns JUnit XML structure; `junit_tools.py` is its
thin CLI. The library inspects and merges native reports, creates wrapper cases,
appends lifecycle cases, and provides ShellCheck/unittest adapters. Bash
runners own process and cluster orchestration and consume only the CLI's plain
count output; they do not parse, render, or text-edit XML.

All state-changing integration, E2E, resilience, mutating probe, and conformance
runs use the renewable `flux-system/homelab-test-run-lock` Kubernetes Lease.
The Lease is acquired only after the command's confirmation guard and is
released only while the current run remains its holder. Read-only smoke and
verification remain concurrent when run individually. A campaign holds this Lease
for its complete ordered sequence; mutating child runners verify and join the
campaign holder without releasing it.

The report archive's pre-activation persistence proof is a cataloged Chainsaw
resilience scenario:

```bash
TEST_REPORT_RUN_ID=<published-run-id> \
CLUSTER_CHAOS_CONFIRM=chaos:test-reports-persistence \
  mise exec -- just test resilience test-reports-persistence
```

It recreates only the Caddy pod and verifies that the selected authoritative
report and its retained PVC survive. It is operator-only and must not be added
to `just ci`.
