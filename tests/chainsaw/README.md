# Chainsaw scenarios

Scenarios are organized by operational risk:

- `smoke/`: read-only assertions against existing production resources.
- `e2e/`: guarded functional workflows that can change workload state.
- `resilience/`: explicitly confirmed disruption and recovery workflows.

The first read-only `smoke/cluster/flux-ready` proof scenario lands with the
guarded runner and evidence pipeline. This tooling phase intentionally contains
no live test.
