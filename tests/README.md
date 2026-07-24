# Kubernetes test framework

This tree contains declarative, repository-owned test inputs:

- `config/` holds the pinned Chainsaw runtime configuration.
- `chainsaw/` will hold live `smoke/`, `e2e/`, and `resilience/` scenarios.
- `policy/` holds cluster-independent Conftest/Rego policy.
- `fixtures/` holds controlled test data, including a lint-only Chainsaw test
  that is never part of live scenario discovery.
- `probes/` is reserved for scenario-local behavioral probes.

`mise exec -- just test validate` is the only cluster-independent command in this
module. It lints Chainsaw configuration and tests, parses their YAML assets, and
runs ShellCheck over `scripts/test/`. It deliberately uses a nonexistent
kubeconfig and unsets SOPS age-key variables.

Live commands are operator-only:

- `mise exec -- just test smoke cluster`
- `mise exec -- just test smoke diagnostics-self-test` (expected failure)
- `mise exec -- just test diagnostics cluster`
- `mise exec -- just test e2e <registered-target>`
- `CLUSTER_CHAOS_CONFIRM=chaos:<target> mise exec -- just test resilience <target>`

Only registered targets are accepted. E2E and resilience have no registered
targets yet and fail closed. Live commands must never enter `just ci`.

Each smoke run writes a collision-resistant directory under `.test-results/`
containing `junit.xml`, `summary.json`, `environment.json`, the Chainsaw log, and
allowlisted fallback diagnostics. Artifacts record only the confirmation
variable name, never its value. A failed diagnostic collection is recorded
separately and cannot turn a failed assertion into a pass.
