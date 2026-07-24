# Chainsaw scenarios

Scenarios are organized by operational risk:

- `smoke/`: read-only assertions against existing production resources.
- `e2e/`: guarded functional workflows that can change workload state.
- `resilience/`: explicitly confirmed disruption and recovery workflows.

The first read-only `smoke/cluster/flux-ready` scenario proves the guarded runner
and evidence pipeline. `diagnostics-self-test` is an opt-in, intentionally
failing read-only assertion used to verify catch/fallback diagnostics and primary
failure preservation.
