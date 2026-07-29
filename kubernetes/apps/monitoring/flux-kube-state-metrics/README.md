# flux-kube-state-metrics

A dedicated, single-purpose [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics)
instance that exports **only** Flux custom-resource state as `gotk_resource_info`. It is the
metrics source for the `FluxReconciliationFailure` / `FluxResourceMetricsMissing` alerts in
`../kube-prometheus-stack/config/flux-alerts.yaml`.

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
  `OCIRepository`, `HelmRepository` (the Decision-9 kinds).
- **RBAC:** minimal `list`/`watch` on exactly those Flux APIs (`./rbac.yaml`), no wildcards.
- **Scrape:** chart-rendered ServiceMonitor; Prometheus discovers it cluster-wide.
- Controller/scrape health is a separate concern, covered by
  `../kube-prometheus-stack/config/flux-podmonitor.yaml` + the KPS `TargetDown` rule.

## Future consolidation (do NOT do in this PR)

Once the KPS HelmRelease upgrade path is fixed and values changes are proven safe:

1. Move this `customResourceState` config (and the minimal RBAC) into the bundled
   kube-state-metrics under `../kube-prometheus-stack/app/values.yaml`.
2. Verify `gotk_resource_info` parity (same labels/values) from the bundled exporter.
3. Confirm Prometheus scrapes the bundled target and the alerts keep firing/resolving.
4. Remove this application (`ks.yaml` entry + directory).
