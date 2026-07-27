# Test Correctness, Standardized Results, and Reporting

## Summary and current baseline

This plan is based on freshly fetched `origin/main` at
`4529d5e2a5e7aab956b4c5d641f71d7f29976036`
(`fix(test): enable qbit_manage custom policy tags (#110)`). Its authoritative
[GitHub CI run passed](https://github.com/7yXwscXEzv6phzUnKfrw/homelab-talos/actions/runs/30225778806).

Current inventory:

- `just ci`: 26 sequential, offline, secret-free validation steps.
- Chainsaw: 12 smoke, 2 E2E, and 5 resilience scenarios.
- Unit tests: 41 Rego, 52 Python, and 9 Bash tests.
- 20 validation scripts and 21 live verification scripts.
- Three specialized live probes.
- Sonobuoy quick and certified-conformance modes.
- Fifteen continuous Gatus endpoints.
- Only Chainsaw currently approaches the desired artifact structure; CI, validators,
  verifiers, probes, and Sonobuoy do not share one result contract.
- CI publishes no JUnit, summary, diagnostics, or report artifacts.

Immediate correctness defects:

- Six validator negations can silently pass because bare `! command` is non-gating under
  `set -e`.
- Five live verifier negations have the same defect and suppress ShellCheck SC2251.
- `scripts/validate` is not comprehensively ShellChecked by `just ci`.
- Mutating operations are incorrectly named `*-verify`, notably Cilium connectivity,
  storage provisioning, Plex rescheduling, and qBittorrent kill-switch testing.
- The disruptive-test lock is worktree-local, not cluster-wide.
- Several Chainsaw E2E/resilience documents are primarily one large shell/Python script
  operation, producing poor Chainsaw step reporting.
- The latest qbit-manage policy E2E, Plex node-reboot recovery, and current conformance
  evidence have not been durably demonstrated against this main revision.

Phase 1 implementation status on this branch:

- The eleven non-gating absence assertions are corrected and SC2251 suppressions are
  prohibited.
- CI parses and ShellChecks all Bash under validation, verification, test, and probe
  paths; a tenth Bash fixture suite proves forbidden values and execution errors fail.
- Bash 5.x is enforced and reported.
- Verification is read-only; Cilium connectivity and Longhorn provisioning are
  explicit state-changing tests.
- The duplicate Plex reschedule and qBittorrent kill-switch verifiers are retired in
  favor of the richer Chainsaw resilience scenarios.
- Current branch inventory after the split is 20 validation scripts and 19 live
  verification scripts.

Phase 2 implementation status:

- `tests/catalog.yaml` inventories 80 validation, verification, test,
  diagnostic, probe, and conformance suites with stable reporting dimensions,
  ownership, mutation, confirmation, runner, and native-result metadata.
- Every one of the 26 ordered `just ci` child commands has exactly one catalog
  entry; validation fails if either side drifts.
- The catalog is the authoritative Chainsaw dispatcher; offline validation
  rejects duplicate tuples, missing implementations, unsafe paths, unguarded
  mutations, vacuous selectors, and uncataloged Chainsaw documents.
- Chainsaw and diagnostic runs use the canonical run ID and six-entry artifact
  root, retain native `JUNIT-STEP`, normalize native files below
  `diagnostics/`, and index sanitized evidence paths.
- A machine validator enforces schema, non-vacuous JUnit, count/identity
  consistency, safe complete evidence indexing, and confirmation-variable-only
  metadata. Contract regression tests cover malformed counts, zero tests,
  symlinks, unsafe paths, origins, result precedence, and confirmation-value
  leakage.
- Phase 3 adds the shared coordinator and JUnit normalization of CI
  validators/unit tests, live verifiers, probes, and Sonobuoy.

Phase 3 implementation status on `feat/test-result-coordinator`:

- `just ci` is driven by the catalog's ordered `executions.ci` list and emits
  one canonical multi-suite run while retaining the existing fail-fast
  behavior. Unexecuted children become explicit skipped JUnit cases.
- Conftest and kubeconform use native JUnit; ShellCheck JSON and Python
  unittest are normalized to finding/method-level cases; Bash commands receive
  wrapper cases. The stdlib Python JUnit adapter is the sole owner of XML
  inspection, generation, merging, and lifecycle mutation; Bash owns process
  orchestration only. Merge, fail-fast, non-vacuous output, status precedence,
  interruption finalization, and evidence-size behavior have offline regression
  tests.
- GitHub Actions sets `execution_origin=github-actions` and uploads canonical
  results after both successful and failed CI runs with 90-day retention.
- Live Bash verifiers, focused integration/resilience scripts, and probes run
  through the single-suite coordinator. The VPN leak timeline is stored inside
  its canonical diagnostics tree.
- The worktree-local disruptive lock is replaced by a renewable,
  resourceVersion-guarded Kubernetes Lease in `flux-system`, shared by
  state-changing script, Chainsaw, probe, and conformance runs.
- Sonobuoy is normalized into the same contract: its archive is retained,
  non-vacuous native E2E JUnit is merged, and teardown/harness failures remain
  independent errors.

Phase 4 implementation status on `refactor/test-runner-right-sizing`:

- The catalog's live dispatcher supports typed `chainsaw`, `diagnostics`, and
  `direct` backends without evaluating catalog shell strings. Direct Bash and
  uv/Python paths still use the canonical coordinator and renewable Lease.
- `media-hardlink` is a focused Bash integration; `qbit-manage-policy` is a
  direct Python E2E with per-phase native JUnit; `plex-node-reboot` is a direct
  guarded Bash/Talos resilience orchestrator.
- qBittorrent pod recreation, VPN disconnect, and Plex cross-node reschedule
  remain in Chainsaw, but now expose explicit baseline/preparation, disruption,
  readiness, assertion, diagnostics, and recovery steps. Chainsaw owns pod
  deletion, Kubernetes readiness/resource assertions, diagnostics, and
  catch/cleanup. Atomic Bash actions own guards, marker operations, and
  cordon/uncordon. Python phase controllers own temporal sampling, structured
  cross-phase JSON, evidence, and recovery-state validation; the VPN controller
  invokes the existing `leak_sentinel.py` analyzer.
- The stdlib JUnit writer is an importable Python module with a thin CLI adapter;
  the direct qbit_manage E2E writes phase cases through the module rather than
  launching the CLI for every phase.
- Mocked offline controller tests cover state transitions, interrupted cordons,
  exact-node uncordon, cleanup failure propagation, startup-order sampling, and
  VPN API-key non-persistence.
- The live cleanup-failure Chainsaw scenario is removed. Its invariant—cleanup
  failure produces a broken run without masking a passed primary assertion—is
  enforced by the offline result-contract regression.
- The catalog contains 79 suites after reclassifying three incorrectly wrapped
  entries and removing the cluster-dependent harness self-test.

Phase 5 implementation status on `feat/test-allure-reports`:

- Node.js 24.18.0 and Allure 3.14.3 are pinned through mise, with the Awesome UI
  configured as the static report output.
- `just test report <run-id>`, `report-latest`, and `report-open <run-id>`
  validate canonical inputs, stage only canonical JUnit plus allowlisted
  attachments, and generate/serve `.test-reports/<run-id>/awesome/`.
- Latest selection uses the finalized summary end timestamp rather than
  filesystem mtime. Staged JUnit is copied byte-for-byte so package, suite,
  class, and case identities remain stable for later history aggregation.
- GitHub Actions keeps `just ci` unchanged, then best-effort generates the
  static report and Markdown job summary on success or failure. Canonical and
  static report artifacts are retained separately for 90 days.
- Offline coverage exercises passed, failed, broken, and skipped Allure output,
  static entrypoint generation, latest selection, safe evidence attachments,
  traversal/symlink rejection, and Markdown counts.

Phase 6 implementation status on `feat/test-report-server`:

- A suspended `test-reports` Flux application stages a digest-pinned Caddy
  2.11.4 static host behind the internal Gateway. Its restricted one-replica,
  no-RBAC Deployment uses `strategy: Recreate` with a retained 20 GiB Longhorn
  RWO claim.
- The server exposes no upload API. The exactly confirmed operator publisher
  validates the canonical run, deployed source and Git metadata, scans secrets,
  holds a dedicated renewable Lease, generates Allure history, and streams a
  checksummed allowlisted bundle through the guarded recipe.
- Python owns catalog merge, authority classification, 90-day/200-run
  retention, protected latest-per-key selection, monotonic counters, Homepage
  JSON, Prometheus exposition, stable redirects, and canonical artifact
  creation. The in-pod POSIX installer validates paths/checksums and atomically
  swaps `state/current` last.
- Candidate evidence remains inspectable, but only clean runs matching both
  current `origin/main` and the deployed Flux revision drive stable latest links
  and last-run observability.
- Offline tests cover authority, idempotency, conflicting duplicate IDs,
  retention, monotonic counters, unindexed/symlink exclusion, checksummed
  installation, and failure-safe generation switching.
- The source remains suspended and intentionally lacks Gatus until human
  bootstrap, sanitized publication, and persistence acceptance. Activation and
  Gatus are separate follow-up changes.

Phase 7 implementation status on `feat/test-report-presentation`:

- Publisher-owned presentation rollups select only authoritative runs for
  Latest Overall, Validate, Platform Smoke, Media Smoke, Resilience, and
  Conformance. Each emits a stable redirect plus a Homepage row with a result
  marker and RFC3339 completion time for live relative-age formatting.
- The report HTTPRoute declares an up-to-six-row Homepage Custom API
  dynamic-list widget; a category appears after its first authoritative
  publication. Cilium permits only the Homepage namespace to fetch its static
  JSON over port 8080; no credential or upload path is added.
- A provisioned, stable-UID `Cluster Verification` Grafana dashboard shows
  latest status/age, passed cases, 30-day pass rate, durations, failures by
  scenario, and days since successful resilience/conformance, with links back
  to stable report URLs.
- Homepage and Grafana source remains inside the suspended `test-reports`
  application. Gatus and `suspend: false` remain the final, post-acceptance
  activation PR.

Phase 8 activation status on `chore/test-reports-activation`:

- Guarded bootstrap, sanitized authoritative publication, and the cataloged
  test-report persistence scenario have passed against deployed main.
- The persistence proof is published as canonical run
  `20260727T224640Z-ca4bcd1e50fb-operator-e58961e6`; it proves that the exact report,
  canonical artifact, catalog entry, PVC identity, and bound Longhorn volume survived
  Caddy pod recreation.
- The final source changes `test-reports` to durable `suspend: false` and adds a
  one-minute Gatus probe for the archive index through internal DNS, TLS, Gateway,
  Caddy, and the retained current generation.
- Offline validation enforces the Gatus endpoint only while the application is active.
  After this activation merges, the remaining operator action is the read-only
  `mise exec -- just kube test-reports-verify` confirmation.

## Canonical terminology and responsibility

| Class | Contract | Proper implementation |
|---|---|---|
| Validate | Offline proof of repository source, rendering, schemas, policy, lint, and pure logic. Never contacts the cluster. | Bash is appropriate for CLI/file orchestration; Conftest, kubeconform, ShellCheck, and Python are used where they provide better structure. |
| Verify | Read-only proof that the live cluster matches intended deployed state. It must not create, delete, restart, cordon, or patch resources. | Plain Bash is appropriate for combining Helm, Flux, DNS, TLS, and API checks. Declarative Kubernetes readiness may delegate to Chainsaw smoke to avoid duplication. |
| Test | Umbrella for an experiment or scenario; it is not synonymous with Chainsaw. | Chainsaw is one backend. Python remains appropriate for qbit-manage's complex API lifecycle; Talos reboot remains a guarded external orchestrator. |
| Smoke | Fast, read-only, shallow runtime readiness and routing. | Chainsaw is correctly scoped here and remains the primary framework. |
| Integration | A contract between components, such as Longhorn provisioning or SMB hardlinks, without claiming a complete user workflow. | Chainsaw when it owns Kubernetes resources; a focused script when the contract is primarily filesystem or CLI based. |
| E2E | A complete workload or user lifecycle with controlled inputs and exact cleanup. | Chainsaw only when it owns meaningful steps/assertions; otherwise use the domain runner directly. |
| Resilience | Deliberate disruption, observed failure behavior, recovery, and cleanup. | Operator-only, confirmation-gated, cluster-wide locked, with recovery represented independently from the primary assertion. |
| Conformance | Upstream Kubernetes behavior through Sonobuoy. Quick is a subset; certified is actual conformance evidence. | Sonobuoy-native output normalized into the common contract. |
| Unit | Pure isolated logic with no cluster or external dependencies. | Rego, Python unittest, and Bash unit fixtures. |
| Regression / feature / system | These describe intent or scope, not exclusive runners. | Record them as `intent` and `scope` metadata rather than inventing parallel command families. |
| Probe | A measurement primitive that may inform diagnosis but is not automatically a pass/fail assurance gate. | Preserve raw timeline and verdict evidence under `tier=measurement`. |
| Continuous | Always-on service and alert health. | Gatus and Prometheus remain observability, not synthetic test-run history. |

Execution ownership:

- GitHub Actions runs only `just ci`, emits downloadable artifacts, and never connects to
  the cluster.
- Agents run focused offline validation plus `just ci`; they set
  `execution_origin=agent`. They do not run or publish state-changing live tests.
- Humans run live verification, smoke, integration, E2E, resilience, probes,
  conformance, report publishing, rollout, review, and merge.
- Read-only live verification by an agent requires explicit operator authorization and
  cluster access.
- Gatus and Prometheus run continuously without being folded into `just ci`.

## Implementation changes

### 1. Correct the existing gates first

- Replace all non-gating bare negations with explicit
  `if command; then ... exit 1; fi` assertions. Remove the SC2251 suppressions from live
  verifiers.
- ShellCheck every tracked Bash file under `scripts/validate`, `scripts/verify`,
  `scripts/test`, and `tests/probes` in `just ci`; add negative fixtures proving each
  corrected absence assertion fails when the forbidden value is present.
- Enforce Bash 5.x consistently for every Bash validation/verification entrypoint,
  print the active version in CI, and document it as a platform prerequisite.
  Mise has no supported Bash runtime entry, so do not introduce an untrusted
  third-party build plugin merely to claim a toolchain pin.
- Split mutating recipes:
  - `cilium-verify` becomes read-only; move connectivity workloads and failed-pod cleanup
    to `cilium-connectivity-test`.
  - `storage-verify` becomes read-only; move the temporary PVC/replica experiment to
    `storage-provisioning-test`.
  - Retire `plex-reschedule-verify` in favor of the richer resilience scenario.
  - Consolidate `qbittorrent-killswitch-verify` into the VPN-disconnect resilience
    scenario.
  - Keep `portainer-persistence-test` as a test because its name already reflects
    mutation.
- Correct all documentation and success messages so they claim only assertions actually
  performed.

### 2. Introduce a suite catalog and canonical artifact contract

Add a machine-validated test catalog containing, per suite:

- `id`, `source`, `framework`, `suite`, `tier`, `target`, `scenario`
- `scope`, `intent`
- `mutates_cluster`, `execution_owner`, required confirmation type
- command/runner and native-result strategy

Required result structure:

```text
.test-results/<run-id>/
├── junit.xml
├── summary.json
├── environment.json
├── evidence.json
├── logs/
└── diagnostics/
```

All additional native files live below `diagnostics/`; generated manifests move to
`diagnostics/manifests/`, Sonobuoy archives to `diagnostics/sonobuoy/`, and timelines to
`diagnostics/timelines/`. `evidence.json` is always present and indexes only sanitized
relative paths.

Run IDs use `<UTC>-<sha12>-<origin>-<random8>`. A run represents one command execution
and may contain multiple suites, such as all of `just ci` or platform smoke.

Required summary metadata:

- `schema_version`, `run_id`
- `source`, `framework`, `suite`, `tier`, `target`, `scenario`
- `scope`, `intent`
- `git_sha`, `execution_origin`
- nullable `cluster` and `node`
- RFC3339 UTC `start` and `end`, duration
- `result`: `passed`, `failed`, `broken`, or `skipped`
- JUnit counts and per-suite results

Status rules:

- Assertion/product failure produces JUnit `<failure>` and `failed`.
- Harness, infrastructure, diagnostics, or cleanup failure produces `<error>` and
  `broken`.
- Intentional exclusion or an unexecuted fail-fast remainder produces `<skipped>`.
- Cleanup/recovery never overwrites the primary assertion; both appear as separate
  cases/phases.
- A finalized run with zero executed cases is invalid.

`environment.json` records repository branch/dirty state, host OS/architecture, pinned
tool versions, cluster version, namespace, Flux deployed revision, and node/pod identity
where applicable. Confirmation variable names may be recorded; values never are.

### 3. Normalize every runner

Create a common result coordinator that streams normal console output, captures logs,
merges JUnit fragments, finalizes on failure/signals, and preserves the original exit
code. `just ci` remains fail-fast, with remaining catalog entries recorded as skipped.

- Conftest and kubeconform use their native JUnit formats.
- Chainsaw retains native `JUNIT-STEP`.
- Python unittest uses a repository-owned JUnit runner so all test methods remain
  individual cases.
- ShellCheck JSON is normalized to cases per file/finding.
- Bash validator, verifier, and unit scripts receive wrapper-generated JUnit; logs retain
  failed command context.
- Sonobuoy's retrieved E2E JUnit is extracted and merged while its native archive remains
  diagnostic evidence.
- Probes emit a verdict case plus referenced timelines.
- Existing Chainsaw result handling is migrated into the coordinator rather than
  maintaining a parallel schema.

Replace the local disruptive lock with a renewable Kubernetes `Lease` in `flux-system`.
All state-changing integration, E2E, resilience, and conformance runs acquire it after
confirmation and release only their holder identity. An expired lease can be reclaimed
safely; smoke remains concurrent and read-only.

### 4. Right-size Chainsaw usage and close coverage gaps

Keep the declarative smoke suites in Chainsaw; they are correctly scoped.

Refactor live scenarios as follows:

- `qbit-manage-policy`: run the Python orchestrator directly as an E2E backend; emit its
  lifecycle phases as JUnit cases instead of wrapping one Python command in Chainsaw.
- `plex-node-reboot`: keep the guarded Talos/host orchestrator direct; Chainsaw adds no
  meaningful control over the external reboot primitive.
- `media-hardlink`: reclassify as integration, retaining a focused filesystem runner.
- `qbittorrent-pod-recreation` and `plex-cross-node-reschedule`: move Kubernetes deletion,
  readiness, Longhorn assertions, and guaranteed recovery into explicit Chainsaw steps;
  use Python for temporal/structured evidence and retain Bash only for atomic marker and
  node-scheduling actions.
- `qbittorrent-vpn-disconnect`: split baseline, disruption, fail-closed observation,
  recovery, and final state into reportable Chainsaw steps while reusing the probe
  analyzer.
- Move `cleanup-failure-self-test` to offline result-coordinator regression tests; it is
  not a cluster resilience scenario.

Add coverage in this order:

1. Run and publish current-main platform/media smoke, qbit-manage policy E2E, Plex
   node-reboot recovery, and Sonobuoy quick evidence.
2. Add a controlled media-pipeline E2E using the existing legal Sintel fixture: create a
   run-owned Seerr/Radarr request, inject the known legal download into qBittorrent,
   verify VPN transfer, Radarr import/hardlink, and Plex visibility, then remove only
   run-owned API objects/files. External indexer search remains a non-gating
   dependency/probe.
3. Add isolated Longhorn snapshot-restore and replica-recovery scenarios using throwaway
   test volumes.
4. Add an isolated SMB remount/recovery scenario against a run-owned workload without
   disrupting production media applications.
5. Treat load, performance, and soak as a later program only after measurable SLOs are
   defined.

### 5. Generate local and CI Allure reports

Pin Node.js 24.18.0 and Allure 3.14.3 through mise. Allure 3 has a built-in
[generic JUnit XML reader](https://github.com/allure-framework/allure3/blob/v3.14.3/packages/reader/src/junitxml/index.ts),
generates the Awesome static report by default, and can open generated reports locally.
Its static output is appropriate for Caddy hosting.
[Allure 3 documentation](https://allurereport.org/docs/v3/),
[report configuration/history](https://allurereport.org/docs/v3/configure/).

Add:

```text
just test report <run-id>      # generate .test-reports/<run-id>/awesome/
just test report-latest        # resolve by finalized end time, not filesystem mtime
just test report-open <run-id> # operator/human interactive browser view
```

JUnit package/suite/class names remain stable and never include run IDs, preserving
history identity. Evidence-indexed safe files are staged as Allure attachments; arbitrary
diagnostic globs are not included.

GitHub Actions:

- Set `execution_origin=github-actions`.
- Run the unchanged authoritative `mise exec -- just ci`.
- On success or failure, generate Allure where possible, write a Markdown job summary,
  and upload the canonical run plus static report with 90-day retention.
- Do not publish GitHub CI results into the cluster; that bridge is explicitly deferred.
- Preserve the existing single `ci` required status check.

### 6. Host operator-published reports inside the cluster

Stage a new `test-reports` monitoring application using the repository's normal
suspended-bootstrap-activate workflow:

- Caddy 2.11.4 static server, pinned by digest.
- One replica with `strategy: Recreate`.
- 20 GiB Longhorn `ReadWriteOnce` PVC.
- Restricted non-root security context, read-only root filesystem, no Kubernetes RBAC.
- Internal-only `HTTPRoute` for `tests.lab.supermorphic.com`; no public ingress and no
  separate authentication proxy.
- Cilium policy allowing only internal Gateway and Prometheus access.
- Gatus availability probe, ServiceMonitor, and archive-capacity PrometheusRule.

Operator publishing:

```text
TEST_REPORT_PUBLISH_CONFIRM=publish:test-report:<run-id> \
  mise exec -- just test publish <run-id>
```

The recipe validates schemas, JUnit, path safety, symlinks, file sizes, git metadata, and
secret scans; acquires a publish Lease; generates Allure; and streams an allowlisted
archive through the guarded cluster recipe. There is no network upload API.

Persistent layout:

```text
/srv/reports/<run-id>/
/srv/artifacts/<run-id>.tar.gz
/srv/state/generations/<generation>/
/srv/state/current -> generations/<generation>
```

A new state generation contains the report index, Homepage JSON, Prometheus metrics,
Allure history, and stable `/latest/...` redirect pages. The `current` symlink is swapped
last, making publication atomic and idempotent. Orphan staging data is reconciled on the
next publish.

Retention is 90 days or 200 runs, whichever is reached first, while always preserving the
latest run for each suite/target/scenario. Allure history is capped at 200. Lifetime
metric counters never decrease when reports are pruned.

### 7. Homepage and Grafana presentation

Generate a static Homepage Custom API response and add a "Test Results" service showing:

- Latest overall
- Validation
- Platform smoke
- Media smoke
- Resilience
- Conformance

Each row contains `✓`, `✗`, or `!`, relative age, and a stable report link. Homepage's
[Custom API dynamic-list widget](https://gethomepage.dev/widgets/services/customapi/)
can consume this static JSON without another application service.

Expose low-cardinality Prometheus metrics:

```text
homelab_test_last_run_status
homelab_test_last_run_timestamp_seconds
homelab_test_last_success_timestamp_seconds
homelab_test_last_run_duration_seconds
homelab_test_last_run_cases{status=...}
homelab_test_runs_total{result=...}
homelab_test_cases_total{status=...}
```

Labels are limited to `source`, `tier`, `target`, `scenario`, `cluster`, and
`execution_origin`. Do not label metrics with run ID, Git SHA, node, or report URL.
Grafana data links use stable `/latest/<tier>/<target>/<scenario>/` paths.

Provision a "Cluster Verification" dashboard with latest status/age, passed cases,
30-day pass rate, durations, failures by scenario, and days since last successful
resilience/conformance run.

## Validation and acceptance

Each implementation PR must pass `just ci`. Additional acceptance:

- Unit-test schema validation, JUnit merging, fail-fast skipped cases, crash
  finalization, status precedence, stable identities, and non-vacuous reports.
- Test evidence path traversal, symlink, oversized-file, secret, duplicate-run, and
  dirty/incomplete-run rejection.
- Test retention, latest selection, atomic generation switching, idempotent republish,
  and monotonic counters.
- Generate an Allure Awesome report from passed, failed, broken, and skipped fixtures and
  assert its static entrypoint exists.
- Validate all new Kubernetes manifests, RWO/Recreate policy, Cilium policy,
  ServiceMonitor, PrometheusRule, Homepage JSON, and Grafana dashboard in `just ci`.
- Human bootstrap acceptance: publish a sanitized fixture; verify PVC, Caddy, internal
  DNS/TLS, HTTPRoute, Homepage widget, Prometheus scrape, Grafana links, and Gatus probe.
- After activation, the human runs the current-main live suites listed above and
  publishes their artifacts. Agents prepare PRs but never bootstrap, publish, merge, or
  run disruptive scenarios.

## Assumptions

- `tests.lab.supermorphic.com` is LAN-only through the existing internal Gateway; there
  is no outside-to-cluster connection.
- GitHub-to-cluster report synchronization is deferred. CI artifacts remain downloadable
  from GitHub.
- Only clean, finalized runs are publishable. Reports whose test-harness SHA and Flux
  deployed SHA do not match current `origin/main` are retained as candidate evidence but
  excluded from authoritative Homepage/Grafana "latest" values.
- Existing local pre-schema artifacts are not automatically migrated or treated as
  authoritative.
- The report-server source and activation are separate PRs around the required operator
  bootstrap.
