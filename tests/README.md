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

Live test recipes are added in the next phase with explicit safety guards. They
must never enter `just ci`.
