# Kubernetes test framework

This tree contains declarative, repository-owned test inputs:

- `catalog.yaml` is the machine-validated inventory of validation, verification,
  test, diagnostic, probe, and conformance suites. It owns stable reporting
  metadata and the live Chainsaw dispatch registry.
- `config/` holds the pinned Chainsaw runtime configuration.
- `chainsaw/` will hold live `smoke/`, `e2e/`, and `resilience/` scenarios.
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

`mise exec -- just test validate` is the complete cluster-independent command in
this module. It validates `catalog.yaml`, lints Chainsaw configuration and tests,
parses their YAML assets, runs ShellCheck over `scripts/test/` and
`tests/probes/`, executes the shell unit-test suites, and runs Python unit tests
via `uv run --locked python -m unittest`. It deliberately uses a nonexistent
kubeconfig and unsets SOPS age-key variables. `mise exec -- just test
catalog-validate` runs only the catalog checks.

For routine grouped execution and automatic Allure publication, use
`mise exec -- just test campaign-plan <name>` followed by its printed
`mise exec -- just test campaign <name>` command. The `standard`, `weekly`, and
`full` compositions provide nightly, weekly, and complete coverage respectively.
See `docs/guides/test-campaign-operations.md` for campaign selection, cadence, safety stops, and resume
behavior.

Live commands are operator-only:

- `mise exec -- just test smoke cluster`
- `mise exec -- just test smoke cluster diagnostics-self-test` (expected failure)
- `mise exec -- just test smoke media qbittorrent`
- `mise exec -- just test smoke media qbit-manage`
- `mise exec -- just test smoke platform` (all platform readiness suites) or
  `mise exec -- just test smoke platform <cluster|flux|gateway|dns|cilium|longhorn|portainer|smb>` (one).
  Read-only resource-readiness per subsystem; the deep functional checks (cilium connectivity
  test, dig/curl DNS+HTTPS, talosctl/etcd, helm-value parity, test-PVC replica anti-affinity)
  remain operator-only in the `just kube *-verify` recipes. The scenario list is an explicit
  registry — a bare `smoke platform` runs only suites labelled `homelab-talos/suite=platform`.
- `mise exec -- just test diagnostics cluster`
- `mise exec -- just test probe qbittorrent`
- `mise exec -- just test probe vpn-leak`
- `mise exec -- just test probe dns-isolation`
- `mise exec -- just test integration media-hardlink` (run-owned mutation only: proves the media-data SMB
  share preserves hardlinks across `/data/downloads` ↔ `/data/media` — the filesystem
  contract every *arr "hardlink not copy" import depends on — using a throwaway test file,
  no external download; cleans up after itself)
- `CLUSTER_E2E_CONFIRM=e2e:qbit-manage-policy mise exec -- just test e2e qbit-manage-policy`
  (up to 60 minutes; downloads WebTorrent's legal Sintel fixture through qBittorrent's VPN
  egress, observes the deployed public classification, proves private-tag exclusion, applies
  isolated one/two-minute share limits, verifies Stop + recycle cleanup and hardlink survival,
  reruns cleanup idempotently, and tears down only exact run-owned state)
- `FLUX_ALERT_E2E_CONFIRM=test:flux-alert:firing-resolved mise exec -- just kube flux-alert-delivery-test`
  (about 25 minutes; creates one labeled Flux Kustomization with a deliberately nonexistent
  source, waits through the production 15-minute alert timer, proves the firing and resolved
  notifications synchronously reached ntfy, and deletes only that run-owned resource)
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
- `CLUSTER_CHAOS_CONFIRM=chaos:plex-node-reboot TALOS_REBOOT_CONFIRM=reboot:<node>:<ip> mise exec -- just test resilience plex-node-reboot`
  (DOUBLE-GATED: reboots the Talos node hosting Plex via the authoritative
  `just bootstrap reboot` recipe — which owns quorum/TPM/etcd/foundation recovery — then
  proves Plex recovers with its config volume re-attached + SMB re-mounted. First check
  which node Plex is on: `kubectl -n media get pod -l app.kubernetes.io/name=plex -o wide`,
  then set `TALOS_REBOOT_CONFIRM` for that exact node. `talosctl reboot` is bootstrap-tier,
  so this is operator-run.)

Every live command requires an explicit registered target. Smoke additionally
accepts an optional registered scenario after the target; target and scenario
names are not interchangeable. Integration registers `media-hardlink`; E2E registers the
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
skipped. GitHub Actions uploads `.test-results/` on both success and failure
with 90-day retention; open the workflow run's **Artifacts** section and
download `canonical-test-results-<run>-<attempt>`. It also generates and uploads
`allure-test-report-<run>-<attempt>` when canonical finalization succeeded and
writes the run/suite counts to the job summary.

Node.js and Allure are pinned through mise. Generate static Awesome reports with
`mise exec -- just test report <run-id>` or `report-latest`; output is
`.test-reports/<run-id>/awesome/`. `report-open <run-id>` starts Allure's local
static server and opens a browser until Ctrl+C. Latest selection uses the
finalized `summary.json` `end` timestamp, not directory modification time.
Only canonical `junit.xml`, validated root metadata, and evidence-indexed files
are staged for Allure, preventing native diagnostic XML from being counted
twice and excluding unindexed files.

After the persistent report host is bootstrapped, an operator can publish a
clean finalized run with
`TEST_REPORT_PUBLISH_CONFIRM=publish:test-report:<run-id> mise exec -- just test
publish <run-id>`. Published reports remain continuously viewable at
`https://tests.lab.supermorphic.com`; Caddy serves Allure's static output from a
retained Longhorn PVC, so viewing does not require a local command or a running
Allure process. GitHub Actions has no cluster path and does not publish there.
See `docs/reference/test-reports.md` for authority, retention, and activation details.

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
