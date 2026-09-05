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

The dedicated exporter isolates Flux readiness collection from kube-prometheus-stack
values changes. Reported upgrade failures on July 22, 2026 motivated this separation.
The September 5 investigation below revises the original assumption that all values
changes fail; it does not yet establish a validated exporter migration.

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
- Extending the kube-prometheus-stack bundled exporter was deferred because of the
  reported upgrade failures. Consolidation still requires independent migration evidence.
- One family-wide absence alert would allow partial collector loss to remain invisible.

## Reconsideration boundaries

The dedicated exporter can be consolidated into kube-prometheus-stack only after a
bounded values-change upgrade is verified and a migration proves parity for all five metric
families, the scrape target, both alert behaviors, routing, and resolved delivery. A
future Flux-native signal is a replacement only if it again exposes per-resource Ready
state with equivalent missing-signal detection. Routine reconciliation events should
not bypass Alertmanager unless a new design deliberately replaces its grouping,
deduplication, inhibition, repeat, and resolution semantics.

## Consequences

Flux object failures are visible independently of changes to the shared monitoring
release. The extra exporter consumes a small amount of CPU and memory and introduces
one additional component to operate, but it has a narrow read-only authority surface
and produces no duplicate standard Kubernetes metrics.

## September 2026 upgrade investigation and bounded correction

Read-only inspection on September 5, 2026 found kube-prometheus-stack Ready at observed
generation 10, with deployed release revision 52 from July 27. Revision 51 and revision
52 use chart `87.19.0` but have different configuration digests. The July 27 change in
[PR #133](https://github.com/supermorphic/homelab-talos/pull/133) added the Alertmanager
route to ntfy. This is evidence of a successful later values-change upgrade, not proof
that every future upgrade will succeed.

The quoted `failed to wait for object to sync in-cache after patching` message comes
from [helm-controller v1.6.2](https://github.com/fluxcd/helm-controller/blob/v1.6.2/internal/controller/helmrelease_controller.go#L156-L162)
waiting for its cached HelmRelease history after patching the HelmRelease. That message
alone does not identify the cause of a Helm upgrade failure or prove the earlier
admission-webhook or drift-detection hypotheses. The original cause remains unproven.

The bounded correction sets Grafana's Deployment strategy to `Recreate`. Grafana's
persistent-storage setup should not rely on overlapping `RollingUpdate` pods. During
Deployment updates, the old Grafana pod must terminate before its replacement is
created. `ReadWriteOnce` permits access by multiple pods on one node; it does not enforce
a single writer pod or imply that every rolling update deadlocks. `Recreate` supplies
the ordering for Deployment updates, not a universal guarantee for manually deleted
pods or failure recovery. See Kubernetes' [access-mode](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes)
and [Deployment strategy](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#recreate-deployment)
documentation. Updates that replace Grafana's pod incur downtime.

Cluster-independent validation checks that the pinned chart renders exactly one
Grafana Deployment with `Recreate` and no `rollingUpdate` settings. Chart versions,
drift detection, and the dedicated exporter remain unchanged. Pre-change live
`monitoring-verify` passed, including all five Flux resource kinds and both alert rules;
it did not send a notification or prove external ntfy delivery.

Post-merge acceptance remains pending: verify a new successful Helm release revision,
the live Grafana Deployment strategy and readiness, and `monitoring-verify`. Do not
consolidate the exporters on the strength of the offline render alone. If the upgrade
fails, retain the dedicated exporter and diagnose the new conditions, events, and
bounded controller logs before considering another change.
