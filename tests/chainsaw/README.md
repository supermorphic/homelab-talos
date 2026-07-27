# Chainsaw scenarios

Chainsaw scenarios are organized by operational risk:

- `smoke/`: read-only assertions against existing production resources.
- `resilience/`: explicitly confirmed disruption and recovery workflows.

`tests/catalog.yaml` is the authoritative dispatcher. Every Chainsaw document
must have one exact catalog path/selector entry, and duplicate dispatch tuples,
missing implementations, unsafe paths, or unguarded mutations fail offline
validation.

The first read-only `smoke/cluster/flux-ready` scenario proves the guarded runner
and evidence pipeline. `diagnostics-self-test` is an opt-in, intentionally
failing read-only assertion used to verify catch/fallback diagnostics and primary
failure preservation. Run the target normally with `just test smoke cluster`;
select the self-test explicitly with
`just test smoke cluster diagnostics-self-test`.

Media readiness is split by application:

- `just test smoke media qbittorrent`
- `just test smoke media qbit-manage`

The qbit_manage smoke suite checks reconciliation and workload health without
capturing application logs, which may contain torrent names or tracker URLs.

The VPN disconnect, qBittorrent pod recreation, and Plex cross-node scenarios use
explicit Chainsaw steps for disruption, Kubernetes readiness, assertion, diagnostics,
and guaranteed recovery. Bash is limited to atomic guarded actions such as marker
create/read/remove and exact-node cordon/uncordon. Python phase controllers own
temporal sampling, structured cross-phase state, evidence construction, and
recovery-state validation; the VPN controller invokes `leak_sentinel.py` as a
separate analyzer. Chainsaw's native `JUNIT-STEP` output remains the test-case
source; the runner adds canonical metadata, evidence indexing, diagnostics, and
final contract validation.

The Python `qbit-manage-policy` E2E runs directly through the catalog coordinator and is
guarded by the exact
`CLUSTER_E2E_CONFIRM=e2e:qbit-manage-policy` token. It is deliberately isolated
from production policy by a unique category and run tag; production manages only
`movies`/`tv`. Its one-shot Jobs require both unique selectors, exclude
`tracker-private`, disable global qBittorrent preference mutation, skip global
recycle-bin purging, and mount downloads but never media. No qBittorrent or
qbit_manage application logs are collected.

The focused `media-hardlink` integration and external Talos `plex-node-reboot`
orchestrator also run directly; wrapping either in Chainsaw would add no useful
Kubernetes lifecycle control.
