# Test Agent Instructions

Binding constraints for all files under `tests/` and test result and guard
machinery under `scripts/test/`. Root `AGENTS.md` remains the floor and this file
may only narrow or strengthen it.

- Live and cluster-dependent suites never enter `executions.ci`.
- Validation-tier suite entries and `executions.ci` entries stay 1:1.
- Generated result artifacts record only a confirmation variable name, never its
  value.
- Guards fail closed.
- Sonobuoy is ephemeral, never scheduled or standing.
