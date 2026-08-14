# flux-kube-state-metrics

A dedicated, single-purpose [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics)
instance that exports **only** Flux custom-resource state as `gotk_resource_info`. It is the
metrics source for the `FluxReconciliationFailure` / `FluxResourceMetricsMissing` alerts in
`../alerts/app/flux.yaml`.

## Why a separate exporter instead of the bundled KSM?

Flux `v2.9.2` no longer exposes the per-object `gotk_reconcile_condition` controller metric,
so custom-resource readiness must come from kube-state-metrics `customResourceState`
(`gotk_resource_info`). The natural home for that config would be the kube-state-metrics
**bundled inside kube-prometheus-stack** — but this repository has a **confirmed KPS upgrade
wedge**: any change to the KPS HelmRelease values makes its helm upgrade hang
(`failed to wait for object to sync in-cache after patching: context deadline exceeded`,
prime suspect the prometheus-operator admission webhook re-validating the chart's ~30
PrometheusRule objects). Reconfiguring the bundled KSM would trip that wedge.

This instance sidesteps it entirely: it is its own HelmRelease, independently reconciled and
independently removable, and **does not touch KPS values**. It runs CRS-only
(`collectors: []` + `--custom-resource-state-only=true`) so it emits no `kube_*` metrics and
does not duplicate the bundled KSM.

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

## Future consolidation (do NOT do in this PR)

Once the KPS HelmRelease upgrade path is fixed and values changes are proven safe:

1. Move this `customResourceState` config (and the minimal RBAC) into the bundled
   kube-state-metrics under `../kube-prometheus-stack/app/values.yaml`.
2. Verify `gotk_resource_info` parity (same labels/values) from the bundled exporter.
3. Confirm Prometheus scrapes the bundled target and the alerts keep firing/resolving.
4. Remove this application (`ks.yaml` entry + directory).
