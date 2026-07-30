# Handoff: complete Flux reconciliation alerting (Decision 9)

**Status: PR #156 merged as `dd17d79`; Flux reconciled it and live acceptance passes.
Prometheus now has 82 `gotk_resource_info` series across all five configured kinds, both
Flux alert rules are healthy/inactive, and every guarded diagnostic stage passes. The
remaining work is the confirmation-guarded firing/resolved phone-delivery E2E.**

Original design/decisions: `plans/ntfy-flux-implementation-plan.md` (Decision 9). This
feature was built and merged as **PR #154** (`feat(monitoring): alert on Flux reconciliation
failures via dedicated kube-state-metrics`, squash `c1201e6` on `main`).

## Objective

Notify the phone when Flux fails: a wedged `Kustomization`/`HelmRelease` or an unreachable
Git/OCI/Helm source must raise a `warning` that routes to the ntfy **`homelab`** topic via
the existing `Alertmanager → alertmanager-ntfy` path (no routing change).

## Architecture

```
Flux controllers ──> PodMonitor ─────────────> Prometheus            (scrape health; KPS TargetDown covers controller-down)  ✅ LIVE
Flux CRDs ──> dedicated flux-kube-state-metrics ──> gotk_resource_info ──> Prometheus ──> flux PrometheusRule ──> Alertmanager ──> ntfy/homelab   ✅ LIVE
```

Why a dedicated kube-state-metrics (not the bundled one): the **kube-prometheus-stack
HelmRelease has a confirmed upgrade wedge** — any change to KPS values hangs its helm
upgrade. So **KPS values must stay untouched** and Flux CR metrics come from a separate,
`--custom-resource-state-only` KSM instance. Do not "fix" this by editing KPS values.

## Live diagnosis before PR #156

- Everything reconciled; `flux-kube-state-metrics` Kustomization + HelmRelease Ready.
- **KPS untouched** (still revision .v52) — the wedge was avoided. Keep it that way.
- PodMonitor works: `gotk_reconcile_duration_seconds`, `gotk_event_*`, `gotk_token_*` are in
  Prometheus (these come from the controllers, not KSM).
- The dedicated KSM **target is UP and scraped**, but produces **zero** custom metrics:
  `gotk_resource_info` returns empty; `{__name__=~"kube_customresource.*"}` is also empty
  (so the `gotk` prefix DID apply — it's not a naming problem, the metric simply isn't
  emitted).
- The repository's guarded diagnostic proved the service account can list/watch all five Flux
  resource kinds but **cannot list/watch CRDs**. The exporter log contains the corresponding
  `customresourcedefinitions.apiextensions.k8s.io is forbidden` error.
- KSM reports a successful custom-resource config load. Therefore the current zero-series
  failure is CRD discovery RBAC, not YAML parsing or Prometheus discovery.
- Independent comparison with the canonical Flux example found that the five collectors used
  one repeated help string. KSM's metric-header sanitization has historically dropped resource
  families in that configuration; canonical Flux uses a kind-specific help string.
- Side effect: `FluxResourceMetricsMissing` (the watchdog) will fire a `warning` to `homelab`
  until metrics flow. PR #156 changes the watchdog to remain active if any configured kind is
  missing instead of only when the entire metric family disappears.

## Changes staged in PR #156

- Minimal `list`/`watch` access to
  `customresourcedefinitions.apiextensions.k8s.io`, which KSM requires before constructing its
  custom-resource collectors.
- A unique help string for each Flux kind contributing to `gotk_resource_info`, with a CI
  assertion preventing regression to repeated help strings.
- `FluxReconciliationFailure` selects every unsuspended resource with `ready!="True"`, covering
  `False`, `Unknown`, and a missing Ready label.
- `FluxResourceMetricsMissing` checks each Decision-9 kind independently.
- Promtool behavior tests for readiness, suspension, and partial metric loss.
- `mise exec -- just kube monitoring-verify` as the fail-fast live acceptance gate.
- `mise exec -- just kube flux-alerts-diagnostics` as the read-only, stage-by-stage diagnostic.

KPS values remain untouched.

## Completed live acceptance

After PR #156 reconciled, these guarded checks passed:

```
mise exec -- just kube monitoring-verify
mise exec -- just kube flux-alerts-diagnostics
```

The live gate found an up exporter target, all five configured kinds in Prometheus, both
healthy/inactive alert rules, an active Alertmanager connection, and the expected ntfy
receiver/route.

## End-to-end proof (operator confirmation required)

Run the guarded, run-owned failure test after its follow-up PR has merged:

```
FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved' \
mise exec -- just kube flux-alert-delivery-test
```

It creates one labeled Flux Kustomization referencing a deliberately nonexistent source,
waits through the real 15-minute `FluxReconciliationFailure` window, proves that Alertmanager
routed both firing and resolved events through a synchronous successful ntfy webhook, and
deletes that exact test resource. Confirm the two messages arrived on the phone's `homelab`
topic to close the plan.

## Workflow constraints (must follow)

- This checkout is the absolute filesystem boundary. Do not use another checkout.
- Work only on the assigned feature branch; never commit/push to `main`; **never merge**
  (no `gh pr merge`) — the operator merges.
- `mise exec -- just ci` must pass locally before opening/updating the PR. Prefix all
  operator commands with `mise exec --`.
- Do not touch `kube-prometheus-stack/app/values.yaml` (upgrade wedge).
- Never run raw cluster mutations or health checks; use the guarded `just` recipes above.

## Key files

- App: `kubernetes/apps/monitoring/flux-kube-state-metrics/{ks.yaml,README.md,app/{helmrelease.yaml,values.yaml,rbac.yaml,kustomization.yaml}}`
- Alerts/PodMonitor: `kubernetes/apps/monitoring/kube-prometheus-stack/config/{flux-podmonitor.yaml,flux-alerts.yaml}`
- Validation: `scripts/validate/monitoring.sh` (Flux assertions near the end)
- Wiring: `kubernetes/apps/monitoring/kustomization.yaml`, `.../kube-prometheus-stack/config/kustomization.yaml`

## Key facts

- Flux **v2.9.2**; `gotk_reconcile_condition` (per-object) is REMOVED — must use
  `gotk_resource_info` from KSM. Do not reintroduce `gotk_reconcile_condition`.
- KSM standalone chart **8.0.0** = the version KPS `87.19.0` bundles (app `v2.19.1`).
- Controllers: source/kustomize/helm/notification (no image-*); label
  `app.kubernetes.io/part-of: flux`; metrics port `http-prom` (8080).
- Decision-9 kinds: Kustomization (v1), HelmRelease (v2), GitRepository/OCIRepository/
  HelmRepository (v1).
- severity `warning` → `homelab` (mapping in `alertmanager-ntfy/app/config.yml`; route matcher
  `severity =~ "critical|warning"` in KPS values — already live, no change needed).
