# Chainsaw scenarios

Scenarios are organized by operational risk:

- `smoke/`: read-only assertions against existing production resources.
- `e2e/`: guarded functional workflows that can change workload state.
- `resilience/`: explicitly confirmed disruption and recovery workflows.

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

State-changing E2E and resilience scenarios record cleanup/recovery separately
from the primary assertion. A cleanup failure makes the command fail while
preserving the primary result in `summary.json`.
