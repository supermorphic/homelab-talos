# Flux Reconciliation Alerting

## Purpose

Detect when Flux-managed desired state is no longer reconciling. Controller scrape
health proves that a Flux controller process is reachable, but it does not prove that
each Kustomization, HelmRelease, or source reports `Ready=True`.

Flux is the repository's sole Kubernetes reconciler, so resource readiness and dependency
state are part of the platform's desired-state control model rather than incidental
observability metadata. Per-resource readiness is therefore load-bearing: healthy
controller processes do not prove that the declared platform state is converging.

This specification records the accepted rationale and evidence boundary. Current
monitoring source, tests, and source-adjacent documentation define operational behavior.

## Metric architecture

The existing Flux PodMonitor remains responsible for controller-runtime and scrape
health. The kube-prometheus-stack general target-down rules cover loss of those scrape
targets.

Per-resource readiness comes from a dedicated `flux-kube-state-metrics` Helm release in
the `monitoring` namespace. It disables all standard collectors and runs in
custom-resource-state-only mode, so it emits `gotk_resource_info` without duplicating
the bundled exporter's `kube_*` metrics. It collects these Flux kinds:

- Kustomization;
- HelmRelease;
- GitRepository;
- OCIRepository; and
- HelmRepository.

Each collector uses a distinct help string. kube-state-metrics can discard resource
families when multiple custom-resource collectors produce the same sanitized metric
header, so the help strings are part of the correctness contract.

## Isolation and authority boundary

The dedicated exporter avoids changing kube-prometheus-stack values. That release had a
confirmed upgrade wedge in which a values change could leave the Helm upgrade waiting
for an in-cache object. Reusing its bundled kube-state-metrics instance would have
coupled reconciliation visibility to that risky shared upgrade path.

The exporter has only `list` and `watch` access to the five Flux resource kinds and to
CustomResourceDefinitions needed for collector discovery. It cannot read Secrets or
mutate cluster state. The chart's broad RBAC generation is disabled and the repository
owns the focused ClusterRole and binding.

This last permission came from a useful failure. The exporter target was healthy, its
configuration was loaded, and its service account could list and watch each configured
Flux kind, yet it exported no `gotk_resource_info` series. The exporter log identified
CustomResourceDefinition discovery as the first failing boundary. Adding only that read
permission restored collection. This diagnosis prevented a misleading conclusion that
target health or direct access to the five objects was sufficient.

## Alert semantics

`FluxReconciliationFailure` selects any exported resource that is not suspended and
whose Ready condition is not `True`. This includes `False`, `Unknown`, and a missing
Ready label. The condition must persist for 15 minutes before the warning fires.

`FluxResourceMetricsMissing` checks each configured kind independently. A single
family-wide absence check was rejected because series from four working collectors can
hide failure of the fifth. The warning identifies loss of the monitoring signal rather
than asserting that a Flux resource failed.

Both warnings follow the existing Alertmanager route to the synchronous
`alertmanager-ntfy` bridge and the `homelab` topic. Alertmanager retains ownership of
grouping, deduplication, inhibition, repeat timing, and resolved messages. This design
does not create a Flux-specific topic or routine Flux event-notification path.

The `warning` severity is deliberate. A reconciliation failure means desired-state
convergence is degraded; it does not by itself establish the immediate service, data, or
privacy impact reserved for `critical` alerts.

## Validation model

Cluster-independent checks validate the custom-resource configuration, unique help
strings, minimal RBAC, PrometheusRule syntax, and the behavior of readiness, suspension,
and partial metric-loss expressions. This catches errors that a successful YAML render
cannot detect.

The guarded diagnostic workflow checks the independent live stages: exporter target
health, presence of all five resource kinds, rule health, Alertmanager connectivity, and
the expected ntfy receiver and route. Live acceptance observed all five kinds and
healthy inactive rules after adding the required CRD-discovery permission.

The implemented confirmation-guarded firing-and-resolved scenario creates a run-owned
Flux Kustomization with a deliberately missing source. It is designed to exercise the
real path from Flux resource failure through `gotk_resource_info`, the production
15-minute rule, Alertmanager, `alertmanager-ntfy`, and ntfy, then prove resolution after
removing the failure. The retained lineage records the scenario's implementation and
offline validation, but leaves its post-merge live execution pending. It is therefore a
defined acceptance test, not completed firing-and-resolved evidence. Even a successful
run would prove synchronous ntfy publication rather than human handset receipt.

## Rejected alternatives

- Controller metrics alone cannot report readiness of individual Flux objects.
- The removed `gotk_reconcile_condition` metric is not available in the deployed Flux
  version and must not be treated as a source.
- Extending the kube-prometheus-stack bundled exporter would re-enter the known upgrade
  failure path.
- One family-wide absence alert would allow partial collector loss to remain invisible.

## Reconsideration boundaries

The dedicated exporter can be consolidated into kube-prometheus-stack only after its
upgrade path is no longer wedged and a migration proves parity for all five metric
families, the scrape target, both alert behaviors, routing, and resolved delivery. A
future Flux-native signal is a replacement only if it again exposes per-resource Ready
state with equivalent missing-signal detection. Routine reconciliation events should
not bypass Alertmanager unless a new design deliberately replaces its grouping,
deduplication, inhibition, repeat, and resolution semantics.

## Consequences

Flux object failures are visible without changing the upgrade-fragile monitoring
release. The extra exporter consumes a small amount of CPU and memory and introduces
one additional component to operate, but it has a narrow read-only authority surface
and produces no duplicate standard Kubernetes metrics.
