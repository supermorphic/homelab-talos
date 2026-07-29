# Handoff: complete Flux reconciliation alerting (Decision 9)

**Status: ~75% — merged & deployed, but the core metric `gotk_resource_info` is not being
produced, so the primary alert cannot fire. One runtime bug blocks completion.**

Original design/decisions: `plans/ntfy-flux-implementation-plan.md` (Decision 9). This
feature was built and merged as **PR #154** (`feat(monitoring): alert on Flux reconciliation
failures via dedicated kube-state-metrics`, squash `c1201e6` on `main`).

## Objective

Notify the phone when Flux fails: a wedged `Kustomization`/`HelmRelease` or an unreachable
Git/OCI/Helm source must raise a `warning` that routes to the ntfy **`homelab`** topic via
the existing `Alertmanager → alertmanager-ntfy` path (no routing change).

## Architecture (as shipped)

```
Flux controllers ──> PodMonitor ─────────────> Prometheus            (scrape health; KPS TargetDown covers controller-down)  ✅ WORKING
Flux CRDs ──> dedicated flux-kube-state-metrics ──> gotk_resource_info ──> Prometheus ──> flux PrometheusRule ──> Alertmanager ──> ntfy/homelab   ❌ metric not produced
```

Why a dedicated kube-state-metrics (not the bundled one): the **kube-prometheus-stack
HelmRelease has a confirmed upgrade wedge** — any change to KPS values hangs its helm
upgrade. So **KPS values must stay untouched** and Flux CR metrics come from a separate,
`--custom-resource-state-only` KSM instance. Do not "fix" this by editing KPS values.

## What is TRUE right now (verified on cluster)

- Everything reconciled; `flux-kube-state-metrics` Kustomization + HelmRelease Ready.
- **KPS untouched** (still revision .v52) — the wedge was avoided. Keep it that way.
- PodMonitor works: `gotk_reconcile_duration_seconds`, `gotk_event_*`, `gotk_token_*` are in
  Prometheus (these come from the controllers, not KSM).
- The dedicated KSM **target is UP and scraped**, but produces **zero** custom metrics:
  `gotk_resource_info` returns empty; `{__name__=~"kube_customresource.*"}` is also empty
  (so the `gotk` prefix DID apply — it's not a naming problem, the metric simply isn't
  emitted).
- Manifests render correctly and match the canonical Flux CRS config, so this is a **runtime
  rejection inside kube-state-metrics v2.19.1** (config parse OR RBAC), not a manifest typo.
- Side effect: `FluxResourceMetricsMissing` (the watchdog) will fire a `warning` to `homelab`
  until the metric flows — that is correct behavior, not a new bug. It self-resolves once
  fixed.

## STEP 1 — Assess current state (run these first; state may have changed)

Kubeconfig is at repo-root `.kube/config`. Run tools via mise.

```
# The definitive diagnostic — exporter startup logs (parse error vs forbidden):
mise exec -- kubectl --kubeconfig .kube/config -n monitoring \
  logs -l app.kubernetes.io/instance=flux-kube-state-metrics --tail=120

# RBAC yes/no — can the SA list Flux resources?
mise exec -- kubectl --kubeconfig .kube/config auth can-i \
  list kustomizations.kustomize.toolkit.fluxcd.io \
  --as=system:serviceaccount:monitoring:flux-kube-state-metrics

# What the exporter actually serves at the source (rules out Prometheus-side issues):
mise exec -- kubectl --kubeconfig .kube/config -n monitoring \
  exec deploy/flux-kube-state-metrics -- wget -qO- localhost:8080/metrics | grep -c gotk_resource_info

# Is the config actually mounted/what did it load:
mise exec -- kubectl --kubeconfig .kube/config -n monitoring \
  exec deploy/flux-kube-state-metrics -- cat /etc/customresourcestate/config.yaml | head -40

# Confirm the ClusterRole/Binding + SA exist and match:
mise exec -- kubectl --kubeconfig .kube/config get clusterrole flux-kube-state-metrics -o yaml
mise exec -- kubectl --kubeconfig .kube/config get clusterrolebinding flux-kube-state-metrics -o yaml
mise exec -- kubectl --kubeconfig .kube/config -n monitoring get sa
```

## STEP 2 — Fix based on the diagnosis

Branch off fresh `origin/main`: `feat/flux-ksm-fix` (see workflow rules below). All edits stay
in `kubernetes/apps/monitoring/flux-kube-state-metrics/`. **Do not touch kube-prometheus-stack
values.**

- **`auth can-i` → `no`, or logs show `forbidden ... cannot list kustomizations`** → RBAC.
  The SA name is `flux-kube-state-metrics` (from `fullnameOverride`). Verify the rendered
  Deployment `serviceAccountName`, the actual SA name on-cluster, and that
  `app/rbac.yaml`'s ClusterRoleBinding subject matches (name + `namespace: monitoring`). Fix
  `app/rbac.yaml`.

- **Logs show `failed to parse ... custom resource state ... config`** → CRS schema. Compare
  `app/values.yaml` `customResourceState.config` against the **current**
  `fluxcd/flux2-monitoring-example` KSM config for a KSM version matching `v2.19.1` (chart
  `8.0.0`). Likely suspects: the `each`/`labelsFromPath` placement, the `Info` metric shape,
  or the `'[type=Ready]'` path-selector syntax. Fix `app/values.yaml`.

- **Logs clean, `can-i` = `yes`, but metric still absent** → confirm the config file is
  actually being read (check the `--custom-resource-state-config-file` flag in logs and the
  mounted file), and curl the `/metrics` endpoint directly. Consider whether KSM emitted the
  metric under a different name than expected.

After the fix: `mise exec -- just ci` must pass (it runs `scripts/validate/monitoring.sh`,
which already asserts the architecture and that KPS values are unchanged — extend those
assertions if the fix changes shape). Open a PR; **do not merge** (operator's job).

## STEP 3 — Verify the live label schema (after the metric flows)

The alert in `kube-prometheus-stack/config/flux-alerts.yaml` assumes `ready="False"`,
`suspended!="true"`, and label `exported_namespace`. Confirm against real series:

```
count by (__name__) ({__name__=~"gotk.*"})        # expect gotk_resource_info present
count by (ready) (gotk_resource_info)             # expect "True"/"False"/"Unknown"
count by (suspended) (gotk_resource_info)         # expect "false"/"true"
count by (exported_namespace) (gotk_resource_info)# expect your namespaces
gotk_resource_info{ready="False", suspended!="true"}   # expect empty on a healthy cluster
```

If any casing differs, adjust `flux-alerts.yaml` (`FluxReconciliationFailure.expr` and the
`monitoring.sh` assertion) and re-run `just ci`.

## STEP 4 — End-to-end proof (operator, optional but closes the plan)

Hold a safe Flux resource `Ready=False` for >15 min (e.g. point a throwaway `GitRepository`
at a bad URL). Confirm `FluxReconciliationFailure` → `warning` → ntfy `homelab` → phone, then
restore → resolves. Confirm a genuinely *suspended* resource does NOT trip it, and that
`FluxResourceMetricsMissing` is inactive while metrics exist.

## Workflow constraints (must follow)

- This checkout is a **linked worktree**; it is the absolute boundary. No new worktrees.
- Branch off `origin/main`; never commit/push to `main`; **never merge** (no `gh pr merge`) —
  the operator merges.
- `mise exec -- just ci` must pass locally before opening/updating the PR. Prefix all
  operator commands with `mise exec --`.
- Do not touch `kube-prometheus-stack/app/values.yaml` (upgrade wedge).
- Never run raw cluster mutations; diagnostics above are read-only.

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
