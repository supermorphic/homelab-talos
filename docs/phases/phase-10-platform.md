# Phase 10: Greenfield Platform Applications

## Status

**In progress.** Applications are added one at a time, each as a Flux HelmRelease
(or focused native manifests) reimplemented from the legacy `homelab-gitops`
requirements — never by copying rendered YAML, KSOPS resources, PVCs, or data.

| App | State |
|---|---|
| kube-prometheus-stack (Prometheus + Alertmanager + Grafana + exporters) | **Complete (2026-07-22)** |
| Gatus | **Complete (2026-07-22)** |
| Homepage | **Complete (2026-07-22)** |
| Trivy Operator | **Complete (2026-07-22)** |

## Delivery pattern (every app)

`kubernetes/apps/<domain>/<app>/` with staged `ks.yaml` (`suspend: true`) →
`app/` (HelmRelease/HelmRepository/namespace/values, plus any SOPS secret the
workload needs at start) → `config/` (routes and post-install CRs, `dependsOn`
the app). Guarded workflow: `just repo <app>-secrets` (if secrets) →
`just kube <app>-validate` → commit/push → `just bootstrap <app>` → `just kube
<app>-verify` → durable `suspend: false` flip.

**Exposure:** Gateway API `HTTPRoute` on the `internal` gateway
(`sectionName: https`, wildcard host `*.lab.supermorphic.com`, existing
`wildcard-lab-supermorphic-com-tls`), with `external-dns.k8s.io/audience: internal`
so ExternalDNS publishes the record to Pi-hole. **The app namespace MUST carry
`gateway.supermorphic.com/access: internal`** — the gateway's https listener
allows routes only from namespaces with that label. Envoy Gateway does not
re-evaluate existing routes when a namespace's labels change later, so create the
namespace with the label from the start (see the kube-prometheus-stack note).

## kube-prometheus-stack

`kubernetes/apps/monitoring/kube-prometheus-stack/`, chart `87.19.0` from
`prometheus-community`, namespace `monitoring` (privileged + gateway-access
label). Two Kustomizations: `kube-prometheus-stack` (app, `dependsOn`
cilium + longhorn) → `kube-prometheus-stack-config` (HTTPRoutes, `dependsOn`
the app + internal-gateway).

### Right-sizing (raised from the Raspberry-Pi-5 constraints)

The legacy Pi build was constrained silently through retention/storage caps and
disabled rules, not memory limits. For the 32 GB/node Talos cluster:

| Setting | Pi-5 legacy | This cluster |
|---|---|---|
| Prometheus retention | 7d | 30d |
| Prometheus retentionSize | 8GiB | 45GiB |
| Prometheus PVC | 20Gi | 50Gi longhorn |
| Prometheus resources | none | req 500m/2Gi, limit 4Gi |
| Grafana persistence | off (ephemeral) | on, 10Gi longhorn |
| Grafana resources | 300m/400Mi limit | req 100m/256Mi, limit 512Mi |
| Alertmanager PVC | 1Gi | 5Gi longhorn |
| defaultRules | trimmed | all on except the Talos-unscrapable groups |
| operator / KSM / node-exporter | none | modest req + limits |

### Talos-specific component handling

Cilium replaces kube-proxy, and Talos binds controller-manager/scheduler/etcd
metrics to localhost, so `kubeProxy`, `kubeControllerManager`, `kubeScheduler`,
and `kubeEtcd` scrape targets are disabled along with their `defaultRules` groups
to avoid false "down" alerts. `serviceMonitorSelectorNilUsesHelmValues: false`
(and the pod/rule/probe/scrapeConfig equivalents) let Prometheus scrape every
monitor in the cluster, not only chart-labeled ones.

### Exposure and credentials

Three internal HTTPRoutes: `grafana` / `prometheus` / `alertmanager`
`.lab.supermorphic.com`. The Grafana admin credential is the SOPS-encrypted
`grafana-admin-secret` written by the guarded `just repo monitoring-secrets`
(env `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`, ≥12 chars,
`MONITORING_SECRETS_CONFIRM`) — never copied from the legacy repo.

### Alerting

Alertmanager is the alerting backbone (the enabled Prometheus rules route to it;
Grafana's own unified alerting is left unused). It ships with the chart's default
(null) route, so **alerts evaluate but do not notify** until a real receiver
(ntfy/email/Slack) is wired — a later follow-up.

### Rollout

```bash
export MONITORING_BOOTSTRAP_CONFIRM='bootstrap:phase10:monitoring:kube-prometheus-stack'
mise exec -- just bootstrap monitoring
```

### Acceptance evidence (2026-07-22)

`just kube monitoring-verify` passed: both Kustomizations and the HelmRelease
Ready, ≥3 PVCs Bound on Longhorn, all three HTTPRoutes Accepted, and all three
UIs reachable with trusted HTTPS through the internal gateway
(Grafana `/api/health` → `database: ok`); `foundation-verify` still green.

### Lesson: internal-gateway namespace label

The first rollout created the `monitoring` namespace without
`gateway.supermorphic.com/access: internal`; the HTTPRoutes were rejected. Adding
the label later did not help because Envoy Gateway does not re-evaluate existing
routes on a namespace label change — a one-time
`kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway` cleared its
cache. The label is now in the namespace manifest and asserted by
`monitoring-validate`, so future apps avoid this.

## Gatus

`kubernetes/apps/monitoring/gatus/`, chart `1.5.0` from `twin`, namespace `gatus`
(baseline PodSecurity + gateway-access label), a single Kustomization
(`dependsOn` cilium + longhorn + internal-gateway; no secret). Uptime history is
sqlite on a 1Gi Longhorn PVC (`/data`); a ServiceMonitor exposes Gatus metrics to
Prometheus. Endpoints probe the real user-facing HTTPS URLs (grafana, prometheus,
alertmanager, echo) so a green board proves the full DNS→TLS→gateway path.
Exposed at `gatus.lab.supermorphic.com`. The legacy ArgoCD/Traefik/Longhorn-UI
endpoints were dropped (they don't exist on this cluster).

Workflow: `just kube gatus-validate` → `just bootstrap gatus`
(`GATUS_BOOTSTRAP_CONFIRM='bootstrap:phase10:gatus'`) → `just kube gatus-verify`.

**Acceptance evidence (2026-07-22):** `gatus-verify` passed — Kustomization +
HelmRelease Ready, HTTPRoute Accepted, and the dashboard reachable with trusted
HTTPS at `gatus.lab.supermorphic.com`; `foundation-verify` still green.

**Storage note:** Gatus started on a sqlite PVC (Longhorn, ReadWriteOnce) which
deadlocked RollingUpdate on the first config update (see the README RWO note). It
was switched to `storage.type: memory` — no PVC, no deadlock; uptime history
resets on restart, which is fine for a status board.

## Homepage

`kubernetes/apps/monitoring/homepage/`, image `v1.13.2`, raw manifests (not Helm),
namespace `homepage` (baseline PodSecurity + gateway-access label), a single
Kustomization (`dependsOn` cilium + internal-gateway; no PVC, no secret). Config
is a hashed ConfigMap so a config change rolls the pod. A read-only ClusterRole
lets the Kubernetes/Gateway widgets list nodes/pods/namespaces/HTTPRoutes.
Rebuilt from the legacy requirements but **dropped** the ArgoCD API token, the
Traefik/proxmox integrations, and the cleartext-password widget annotation;
services link to Grafana/Prometheus/Alertmanager plus a no-auth Gatus uptime
widget. Exposed at `homepage.lab.supermorphic.com`.

Cluster CPU/memory widgets render empty until **metrics-server** is installed
(not present on Talos by default); pod counts, node status, links, and the Gatus
widget work without it.

Workflow: `just kube homepage-validate` → `just bootstrap homepage`
(`HOMEPAGE_BOOTSTRAP_CONFIRM='bootstrap:phase10:homepage'`) → `just kube
homepage-verify`.

**Acceptance evidence (2026-07-22):** `homepage-verify` passed — Kustomization
Ready, deployment rolled out, HTTPRoute Accepted, dashboard reachable with trusted
HTTPS at `homepage.lab.supermorphic.com`; `foundation-verify` still green.

**Config note:** Homepage initializes any missing skeleton config file into
`/app/config`, which is a read-only ConfigMap mount — a missing file crashes it
with `EROFS`. All skeleton files must be shipped (including empty `docker.yaml`,
`proxmox.yaml`, `custom.css`, `custom.js`).

## Trivy Operator

`kubernetes/apps/security/trivy-operator/`, chart `0.34.0` from Aqua, namespace
`trivy-system` (privileged), a single Kustomization (`dependsOn` cilium; no
exposure, no secret, no PVC). Continuously scans workload images/configs and
publishes results as CRs (view with `kubectl get vulnerabilityreports -A`). Tuned
for the homelab: concurrency 5, `ignoreUnfixed` + severity `MEDIUM,HIGH,CRITICAL`,
a ServiceMonitor, and **SBOM generation + cluster-compliance disabled** (both
write large/many CRs to etcd).

**Talos incompatibility:** `infraAssessmentScannerEnabled: false`. Its
node-collector does `mkdir /etc/systemd` on the host and fails on Talos's
read-only host filesystem (`CreateContainerError`). The other four scanners
(vulnerability, config-audit, RBAC, exposed-secret) work fine.

Workflow: `just kube trivy-validate` → `just bootstrap trivy`
(`TRIVY_BOOTSTRAP_CONFIRM='bootstrap:phase10:trivy-operator'`) → `just kube
trivy-verify`.

**Acceptance evidence (2026-07-22):** `trivy-verify` passed — Kustomization +
HelmRelease Ready, operator rolled out, report CRDs installed; vulnerability scan
jobs running; `foundation-verify` still green.
