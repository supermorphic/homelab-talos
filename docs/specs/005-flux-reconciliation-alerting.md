# Flux Reconciliation Alerting

## Intent and signal

Detect when Flux desired state stops converging. Healthy controller scrape targets do
not prove individual Kustomizations, HelmReleases, or sources are Ready. The controller
PodMonitor measures process health; bundled kube-state-metrics supplies resource
readiness through `gotk_resource_info`.

[Exporter configuration](../../kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml)
and [monitoring rules](../../kubernetes/apps/monitoring/alerts/) own exact collectors,
labels, and expressions. Each configured Flux kind needs independent missing-signal
coverage: series from other kinds must not conceal a failed collector. Consumers select
the bundled source explicitly so parallel or unintended collection cannot duplicate
alerts or conceal production signal loss.

## Correctness and authority

Custom-resource collectors need distinct help strings. Identical sanitized metric
headers can cause kube-state-metrics to discard families. Collection also needs read
access to CustomResourceDefinitions for discovery; a healthy target and permission to
list the Flux objects are insufficient without that discovery permission.

Added Flux permissions remain read-only and bounded. The bundled exporter retains its
ordinary Kubernetes collectors; no separate Flux exporter or duplicate `kube_*` source
is required. Consolidation replaced the former dedicated exporter only after API-backed
inventory parity and production alert delivery were verified. A future replacement
must preserve per-resource readiness, per-kind absence, source selection, and lifecycle
semantics.

Readiness warnings ignore suspended resources and include False, Unknown, and absent
Ready conditions. Missing metrics mean that the signal is unavailable, rather than
proving that the underlying resource failed. Both use the existing Alertmanager-to-ntfy
warning path; routine Flux events do not create another notification control plane.

## Assurance

Synthetic promtool fixtures validate readiness, suspension, partial collector loss,
hold behavior, and exclusions against the exact applied rules. Live verification must
separately establish target health, every expected kind, rule health, and routing.

The registered firing-and-resolved scenario deliberately creates a run-owned failed
Flux object and removes it after the production rule fires. It requires run-unique
firing and resolved messages in the read-only ntfy cache with timestamps after run start.
Missing or truncated cache evidence fails delivery acceptance. Aggregate webhook counters
cannot attribute delivery to that alert. Handset receipt remains a separate human result.

## Monitoring upgrade constraint

Grafana's single-writer claim uses `Recreate`; updates incur downtime. The earlier
server-side transition retained defaulted `rollingUpdate` fields even with explicit
null. The shared release therefore uses client-side strategic merging for upgrades via
`.spec.upgrade.serverSideApply: disabled`. Returning to server-side apply requires
transition evidence, not only a render. A successful values upgrade does not by itself
prove exporter migration or external alert delivery.
