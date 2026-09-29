# Testing entry point

[`catalog.yaml`](catalog.yaml) is the authoritative inventory of test and
verification suites. It records each suite's command, effects, access tier,
execution owner, and reporting identity. Use the catalog and `mise exec -- just
test` to find current workflows; this README does not maintain a second test
list.

- `chainsaw/` contains live smoke, end-to-end, and resilience scenarios.
- `config/` pins Chainsaw configuration.
- `fixtures/` contains controlled data, including lint-only scenarios that are
  never discovered as live tests.
- `policy/` contains offline Conftest/Rego policy.
- `probes/` contains specialized network and API measurements.

`mise exec -- just ci` runs the full, cluster-independent, secret-free suite.
Pull requests use selected offline groups and the required hosted `merge-gate`;
[`impact.yaml`](impact.yaml) owns path-to-group selection. Live verification and
mutating acceptance stay outside CI and require the authority declared by their
catalog entries.

Canonical local results go under ignored `.test-results/`. Use
`mise exec -- just test record <suite-id>` for retained initiative or infrequent
assurance evidence; it publishes each completed child automatically. The
[test campaign guide](../docs/guides/test-campaign-operations.md) covers selection,
recording, publication, and resume. See [testing layers](../docs/reference/testing-layers.md)
for cadence and [persistent test reports](../docs/reference/test-reports.md) for
evidence and hosting. Repository authority rules are in [`AGENTS.md`](../AGENTS.md).
