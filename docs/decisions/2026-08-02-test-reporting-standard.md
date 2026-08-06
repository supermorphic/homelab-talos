# Test reporting standard

## Status

- **Status: Accepted.**
- Date: 2026-08-02

## Context

Repository validators, live verifiers, scenarios, probes, and conformance originally
produced incompatible results and sometimes blurred read-only verification with
state-changing tests. A common contract was needed without forcing every assurance into
one framework or giving CI cluster access.

## Decision

- Use precise suite classes: validation is offline; verification is read-only live
  acceptance; integration exercises a component contract; E2E exercises a complete
  controlled workflow; resilience introduces and recovers from deliberate disruption;
  conformance is upstream Kubernetes behavior; probes are measurements; continuous
  Gatus and Prometheus signals are observability rather than run history.
- Keep `mise exec -- just ci` as the fail-fast, cluster-independent, secret-free pull
  request gate. GitHub Actions does not contact the cluster or publish into it.
- Describe every runnable suite in the machine-validated catalog with stable identity,
  source, framework, class, target, intent, mutation status, execution owner,
  confirmation type, access tier, runner, and native-result strategy.
- Normalize each run into `.test-results/<run-id>/` with `junit.xml`, `summary.json`,
  `environment.json`, `evidence.json`, logs, and indexed sanitized diagnostics. Assertion
  failures are `failed`; harness, infrastructure, diagnostic, or cleanup failures are
  `broken`; excluded or fail-fast remainder cases are `skipped`. A finalized zero-case run
  is invalid.
- Preserve the primary assertion separately from cleanup and recovery so successful
  cleanup cannot overwrite a failed experiment.
- Use the framework that matches the behavior. Chainsaw owns declarative Kubernetes
  steps where that adds lifecycle control; focused Bash or Python runners remain valid
  for filesystem, API, Talos, and structured temporal workflows.
- Serialize state-changing live suites with a renewable Kubernetes Lease. Read-only smoke
  and verification remain concurrent.
- Generate Allure reports from canonical JUnit while preserving stable suite identity and
  allowlisted evidence attachments.
- Host only operator-published authoritative reports on an internal, static Caddy
  service. Publishing is a guarded workstation push; the in-cluster service has no
  upload API, credentials, ServiceAccount token, or Kubernetes RBAC.
- A published run is authoritative only when its Git commit matches both current
  `origin/main` and the deployed Flux revision. Candidate and historical runs may be
  retained but never drive stable latest links or operational summaries.
- Keep report archives on a retained Longhorn RWO claim with a one-replica `Recreate`
  Deployment. Validate archive paths, symlinks, checksums, sizes, metadata, and secret
  scans before installation; update the active generation atomically.

## Consequences

Console behavior and exit codes remain native while every suite yields comparable,
machine-readable evidence. CI stays safe and reproducible; live and disruptive work
retains explicit ownership and confirmation. Gatus, Homepage, and Grafana summarize
authoritative results without becoming the evidence store.

Current execution guidance lives in [`tests/README.md`](../../tests/README.md),
[`docs/testing-layers.md`](../testing-layers.md),
[`docs/test-reports.md`](../test-reports.md), and
[`docs/test-campaigns.md`](../test-campaigns.md).
