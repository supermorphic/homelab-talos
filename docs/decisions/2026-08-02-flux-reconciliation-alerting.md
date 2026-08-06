# Flux reconciliation alerting

## Status

- **Status: Accepted.**
- Date: 2026-08-02

## Context

Flux controller scrape health does not establish that each managed Kustomization,
HelmRelease, or source is Ready. The deployed kube-prometheus-stack release also had a
confirmed upgrade wedge, so adding Flux custom-resource configuration to its bundled
kube-state-metrics would have coupled alert coverage to a risky shared upgrade.

## Decision

- Keep the existing Flux controller PodMonitor for controller health. Controller-down
  detection remains covered by the platform monitoring path.
- Export per-object readiness through a dedicated, custom-resource-state-only
  `flux-kube-state-metrics` instance. Do not modify kube-prometheus-stack values to obtain
  these metrics.
- Collect `gotk_resource_info` for Flux Kustomizations, HelmReleases, GitRepositories,
  OCIRepositories, and HelmRepositories. The exporter receives only the list/watch and
  CRD-discovery permissions needed to build those collectors.
- Use a distinct help string for each Flux kind. This preserves all metric families
  across kube-state-metrics header sanitization.
- `FluxReconciliationFailure` selects every unsuspended resource whose Ready condition is
  not `True`, including false, unknown, and missing readiness labels.
- `FluxResourceMetricsMissing` checks every configured kind independently so loss of one
  collector cannot hide behind the remaining series.
- Route warning alerts through the existing `Alertmanager -> alertmanager-ntfy ->
  homelab` path. No notification routing change belongs to this decision.
- Validate alert syntax and behavior offline, then verify exporter target health, all
  configured kinds, rule health, Alertmanager connectivity, and the ntfy receiver through
  the guarded diagnostic workflow.

## Accepted evidence

The dedicated exporter, rules, and corrected discovery permissions reconciled in PRs
#154 and #156. Live acceptance observed all five configured kinds, healthy inactive
rules, an active Alertmanager connection, and the expected ntfy route.

## Explicitly excluded follow-up

A confirmation-guarded firing/resolved phone-delivery experiment is useful end-to-end
evidence, but it is not current rollout work and does not qualify this accepted
architecture. It remains an optional testing-expansion activity under the canonical test
catalog and must not be tracked as an implementation-plan checklist.

## Consequences

Flux object failure is observable without touching the upgrade-fragile shared
kube-prometheus-stack values. Metrics-loss alerting fails per kind, and mobile delivery
reuses the notification architecture rather than creating a Flux-specific channel.
