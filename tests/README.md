# Kubernetes test framework

This tree contains declarative, repository-owned test inputs:

- `config/` holds the pinned Chainsaw runtime configuration.
- `chainsaw/` will hold live `smoke/`, `e2e/`, and `resilience/` scenarios.
- `policy/` holds cluster-independent Conftest/Rego policy.
- `fixtures/` holds controlled test data, including a lint-only Chainsaw test
  that is never part of live scenario discovery.
- `probes/` holds specialized read-only network/API probes — a measurement
  primitive, not an assurance tier. Each probe's pure analysis logic is
  unit-tested offline; the live capture is operator-run. Bash probes reuse the
  in-cluster exec pattern; Python probe analyzers use `uv` (pinned via mise, no
  third-party deps — stdlib `unittest`). Current probes: `qbittorrent/` (VPN
  egress + forwarded-port point checks), `vpn/` (the continuous in-netns VPN
  leak sentinel), and `dns/` (active DNS-isolation: DNS resolves only via the
  Gluetun loopback resolver; LAN/home and cluster resolvers stay unreachable).

`mise exec -- just test validate` is the only cluster-independent command in this
module. It lints Chainsaw configuration and tests, parses their YAML assets, runs
ShellCheck over `scripts/test/` and `tests/probes/`, executes the shell unit-test
suites, and runs the Python probe unit tests via `uv run python -m unittest`. It
deliberately uses a nonexistent kubeconfig and unsets SOPS age-key variables.

Live commands are operator-only:

- `mise exec -- just test smoke cluster`
- `mise exec -- just test smoke cluster diagnostics-self-test` (expected failure)
- `mise exec -- just test smoke media qbittorrent`
- `mise exec -- just test smoke platform` (all platform readiness suites) or
  `mise exec -- just test smoke platform <cluster|flux|gateway|dns|cilium|longhorn|smb>` (one).
  Read-only resource-readiness per subsystem; the deep functional checks (cilium connectivity
  test, dig/curl DNS+HTTPS, talosctl/etcd, helm-value parity, test-PVC replica anti-affinity)
  remain operator-only in the `just kube *-verify` recipes. The scenario list is an explicit
  registry — a bare `smoke platform` runs only suites labelled `homelab-talos/suite=platform`.
- `mise exec -- just test diagnostics cluster`
- `mise exec -- just test probe qbittorrent`
- `mise exec -- just test probe vpn-leak`
- `mise exec -- just test probe dns-isolation`
- `mise exec -- just test e2e media-hardlink` (non-destructive: proves the media-data SMB
  share preserves hardlinks across `/data/downloads` ↔ `/data/media` — the filesystem
  contract every *arr "hardlink not copy" import depends on — using a throwaway test file,
  no external download; cleans up after itself)
- `mise exec -- just test e2e <registered-target>`
- `CLUSTER_CHAOS_CONFIRM=chaos:<target> mise exec -- just test resilience <target>`
- `CLUSTER_CHAOS_CONFIRM=chaos:qbittorrent-vpn-disconnect mise exec -- just test resilience qbittorrent-vpn-disconnect`
  (controlled VPN stop→recovery: continuous leak-sentinel evidence that the kill switch
  fails closed across the outage, then pod-recreation recovery; records recovery status
  separately in `summary.json`)
- `CLUSTER_CHAOS_CONFIRM=chaos:cleanup-failure-self-test mise exec -- just test resilience cleanup-failure-self-test`
  (opt-in self-test, the cleanup analogue of `diagnostics-self-test`: deliberately records
  a failed recovery while the primary assertion passes; confirm `summary.json` shows
  `assertion.status: passed` and `recovery.status: failed`. Non-destructive.)
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
names are not interchangeable. E2E and resilience have no registered targets
yet and fail closed. Live commands must never enter `just ci`.

Each smoke run writes a collision-resistant directory under `.test-results/`
containing `junit.xml`, `summary.json`, `environment.json`, the Chainsaw log, and
allowlisted fallback diagnostics. Artifacts record only the confirmation
variable name, never its value. Environment metadata records tier and target,
plus the scenario when one was explicitly selected. A failed diagnostic
collection is recorded separately and cannot turn a failed assertion into a
pass.
