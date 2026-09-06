# flux-kube-state-metrics

A dedicated, single-purpose [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics)
instance that exports **only** Flux custom-resource state as `gotk_resource_info`. It is the
metrics source for the `FluxReconciliationFailure` / `FluxResourceMetricsMissing` alerts in
`../alerts/app/flux.yaml`.

## Why a separate exporter instead of the bundled KSM?

Flux `v2.9.2` no longer exposes the per-object `gotk_reconcile_condition` controller metric,
so custom-resource readiness must come from kube-state-metrics `customResourceState`
(`gotk_resource_info`). The natural home for that config would be the kube-state-metrics
**bundled inside kube-prometheus-stack**. Reported upgrade failures on July 22, 2026
motivated keeping Flux readiness collection separate from that release.

Read-only verification on September 5 found a later successful values-change upgrade:
release revision 52 deployed on July 27 after the Alertmanager routing change in PR #133,
using the same chart version, `87.19.0`. The earlier claim that every values change hangs
is therefore not supported. The recorded in-cache timeout concerns the HelmRelease's
cached status; it does not establish an admission-webhook failure. The original root
cause remains unproven. See [specification 005](../../../../docs/specs/005-flux-reconciliation-alerting.md)
for the evidence and staged validation boundary.

This instance remains its own HelmRelease and is the explicit production source
for Flux alerts. It runs CRS-only (`collectors: []` +
`--custom-resource-state-only=true`) so it emits no `kube_*` metrics and does
not duplicate the bundled KSM's standard metrics.

The bundled KPS exporter now shadow-collects the same five Flux kinds. Its
ServiceMonitor renames only `gotk_resource_info` to
`gotk_candidate_resource_info`, so the candidate cannot match production
rules. It retains standard collectors and receives only the CRD-discovery and
Flux list/watch additions required for custom-resource collection.

## Scope

- **Metrics:** `gotk_resource_info` for `Kustomization`, `HelmRelease`, `GitRepository`,
  `OCIRepository`, `HelmRepository` (the Decision-9 kinds). Each collector uses a unique
  help string as required by kube-state-metrics' metric-header sanitization.
- **RBAC:** minimal `list`/`watch` on those Flux APIs plus CRDs, which kube-state-metrics
  must discover before constructing custom-resource collectors (`./rbac.yaml`); no wildcards.
- **Scrape:** chart-rendered ServiceMonitor; Prometheus discovers it cluster-wide.
- Controller/scrape health is a separate concern, covered by
  `../kube-prometheus-stack/config/flux-podmonitor.yaml` + the KPS `TargetDown` rule.

## Runtime verification and diagnostics

`mise exec -- just kube monitoring-verify` is the fail-fast acceptance gate. It requires
Prometheus to discover an up exporter target, ingest `gotk_resource_info` for every
configured Flux kind, load both Flux alert rules without evaluation errors, and maintain an
active Alertmanager connection with the expected ntfy route. It does not send a notification.
The PrometheusRule treats every unsuspended resource without `Ready=True` as failed and
independently watches for missing metrics from each configured resource kind.

When that gate fails, run `mise exec -- just kube flux-alerts-diagnostics`. The read-only
diagnostic follows the signal path from Flux objects through exporter RBAC/workload/raw
metrics, ServiceMonitor discovery, Prometheus ingestion/rules, and Alertmanager visibility.
It continues after failures, prints the first broken stage, and stores only targeted,
sanitized canonical evidence under `.test-results/`.

A synthetic notification is intentionally outside both commands. It must remain a separate
explicit, confirmation-guarded E2E test because it delivers an external ntfy message.

## Future consolidation

The next stage validates candidate parity and alert behavior while production
continues to use this exporter. Only a later accepted cutover may select the
candidate metric and remove this application (`ks.yaml` entry + directory).
