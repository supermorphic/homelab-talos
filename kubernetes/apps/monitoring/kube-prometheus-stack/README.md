# kube-prometheus-stack

The bundled `kube-prometheus-stack-kube-state-metrics` exporter in `monitoring`
supplies standard Kubernetes metrics and Flux readiness metrics. Flux collection is
configured under `kube-state-metrics` in `app/values.yaml`.

## Flux readiness

`gotk_resource_info` covers `Kustomization`, `HelmRelease`, `GitRepository`,
`OCIRepository`, and `HelmRepository`. Each collector has a unique help string to
prevent kube-state-metrics from discarding a resource family during metric-header
sanitization. Standard collectors remain enabled.

Custom-resource collection adds `list`/`watch` permissions for these five Flux APIs
and CustomResourceDefinitions to the bundled exporter's existing role. These are
incremental permissions, not a description of its full Kubernetes collection role.

The chart-rendered ServiceMonitor exposes the exporter to Prometheus. Both Flux rules
in `../alerts/app/flux.yaml` select the exact bundled Service and namespace:

- `FluxReconciliationFailure` warns when an unsuspended resource lacks `Ready=True`
  for 15 minutes.
- `FluxResourceMetricsMissing` warns when metrics for any configured kind are missing
  for 15 minutes, even if the other kinds remain visible.

Controller scrape health is separate: `config/flux-podmonitor.yaml` collects controller
metrics, and the KPS `TargetDown` rule covers unreachable scrape targets.

## Verification and diagnostics

Run `mise exec -- just kube monitoring-verify` for acceptance. It checks the bundled
exporter target, bundled `kube_node_info` and `kube_pod_info` metrics, all five Flux
kinds, both loaded rules, and the Alertmanager connection and ntfy route. It does not
send a notification.

If acceptance fails, run `mise exec -- just kube flux-alerts-diagnostics`. This read-only
workflow checks each stage from Flux objects through exporter permissions and metrics
to Prometheus and Alertmanager. It reports the first broken stage and stores targeted,
sanitized evidence under `.test-results/`.

`mise exec -- just kube flux-alert-delivery-test` is a separate, confirmation-guarded
test that creates a temporary failure and sends external notifications. It requires
operator-run write access. Aggregate webhook counters do not prove delivery of the
specific test messages; independent firing and resolved evidence is required.

See [specification 005](../../../../docs/specs/005-flux-reconciliation-alerting.md)
for the design history and delivery acceptance boundary.
