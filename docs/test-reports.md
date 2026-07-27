# Persistent test reports

`tests.lab.supermorphic.com` is the always-running, LAN-only archive for
operator-published test evidence. It is not an Allure daemon and does not need an
Allure process after publication: Allure 3 generates static HTML, Caddy serves those
files continuously from a retained Longhorn volume, and the internal Gateway owns
TLS.

## Responsibilities

- Allure 3 (operator workstation): converts canonical JUnit and indexed evidence into
  the Awesome static report.
- `report_publish.py` (operator workstation): validates structured metadata, merges the
  catalog, applies retention, updates lifetime counters, creates stable latest links,
  and builds a checksummed allowlisted bundle.
- `publish-report.sh` (operator workstation): enforces the exact confirmation and
  deployed-source guard, scans for secrets, holds the publication Lease, and streams
  the bundle through a guarded `kubectl exec`.
- Caddy (cluster): serves static files only. It has no upload API, credentials,
  ServiceAccount token, or Kubernetes RBAC.
- `install-report.sh` (cluster): rejects unsafe paths, symlinks, unexpected files, and
  checksum mismatches; installs exact run paths; then atomically replaces the
  `state/current` symlink last.

The persistent layout is:

```text
/srv/
├── reports/<run-id>/awesome/
├── artifacts/<run-id>.tar.gz
└── state/
    ├── generations/<generation>/
    │   ├── index.html
    │   ├── catalog.json
    │   ├── state.json
    │   ├── history.jsonl
    │   ├── api/{homepage.json,metrics.prom}
    │   ├── latest/{overall,validation,platform-smoke,media-smoke,resilience,conformance}/
    │   └── latest/<tier>/<target>/<scenario>/index.html
    └── current -> generations/<generation>
```

The 20 GiB Longhorn claim is `ReadWriteOnce`, so the one-replica Deployment uses
`strategy: Recreate`. The PVC has Flux prune disabled; deleting the Kustomization does
not authorize deleting the archive.

The Caddy runtime ConfigMap is content-addressed by Kustomize. A change to the
Caddyfile or either mounted installer script therefore changes the ConfigMap name in
the Deployment pod template and triggers a `Recreate` rollout. The Grafana dashboard
ConfigMap intentionally keeps its stable name because it is discovered separately by
label. This split prevents Flux from applying new server configuration without the
running Caddy process loading it.

The Caddy container still drops `ALL` Linux capabilities and runs non-root with
privilege escalation disabled. It adds back only `NET_BIND_SERVICE` because the
official Caddy image stamps that file capability onto `/usr/bin/caddy`; omitting it
from the capability bounding set makes Linux reject the executable before Caddy reads
its configuration. Caddy itself listens only on the unprivileged 8080 and 9090 ports.

## Source rollout and activation

The source PR deliberately stages `test-reports` with `suspend: true` and does not add a
Gatus endpoint. After that PR is merged, the operator runs:

```bash
git fetch origin main
TEST_REPORTS_BOOTSTRAP_CONFIRM=bootstrap:test-reports \
  mise exec -- just bootstrap test-reports
```

The bootstrap validates that its guard and application source match `origin/main`,
resumes only the test-report Kustomization, and verifies the PVC, restricted runtime,
route, DNS/TLS, and initial catalog. If acceptance fails it re-suspends the
Kustomization while preserving the PVC.

Next, publish a clean, finalized current-main run and open its returned URL:

```bash
mise exec -- just ci

TEST_REPORT_PUBLISH_CONFIRM=publish:test-report:<run-id> \
  mise exec -- just test publish <run-id>
```

Review the root index and report at `https://tests.lab.supermorphic.com`, the available
Homepage rollups, and the provisioned Grafana `Cluster Verification` dashboard. Then
create the separate activation PR that changes `suspend: false` and adds the Gatus
endpoint.
After that merges, run `mise exec -- just kube test-reports-verify`.

Agents stage and validate the source but do not bootstrap or publish. GitHub Actions
does not have cluster access and never publishes here; its reports remain GitHub
workflow artifacts.

If reconciliation fails, collect the dedicated read-only diagnostics:

```bash
mise exec -- just kube test-reports-diagnostics
```

The command is scoped to the test-report Kustomization and namespace. It prints
Deployment, pod, PVC, events, and the static server's non-secret logs without changing
cluster state.

## Publication and authority

Publishing is intentionally a push operation from the operator workstation. There is
no cluster upload service to attack or authenticate. The recipe requires:

- the exact run-scoped confirmation;
- a canonical, finalized run with complete JUnit/evidence indexing;
- clean captured Git metadata and a locally available commit;
- the publisher and server sources already merged to `origin/main`;
- successful secret scans of both canonical input and exact output bundle;
- the dedicated renewable `flux-system/homelab-test-report-publish-lock` Lease.

A clean historical or feature-commit run may be retained as candidate evidence. Only a
run whose Git SHA equals both current `origin/main` and the Flux artifact revision is
authoritative; candidates never drive Homepage data, stable latest links, or
last-run metrics.

Republishing the same run ID and digest is a no-op. Reusing a run ID with different
content is rejected. Normal retention keeps reports that are both among the newest 200
and no more than 90 days old, while preserving the latest report for every
source/tier/target/scenario key. Lifetime metric counters remain in publication state
when individual reports are pruned.

## Viewing and observability

No command is required to view already-published reports:

- Archive/index: `https://tests.lab.supermorphic.com`
- Machine-readable catalog: `https://tests.lab.supermorphic.com/api/catalog.json`
- Exact report: `https://tests.lab.supermorphic.com/reports/<run-id>/awesome/`
- Canonical download: `https://tests.lab.supermorphic.com/artifacts/<run-id>.tar.gz`
- Stable latest link:
  `https://tests.lab.supermorphic.com/latest/<tier>/<target>/<scenario-or-_>/`
- Stable presentation rollups:
  `/latest/{overall,validation,platform-smoke,media-smoke,resilience,conformance}/`

Caddy exposes its native metrics on the internal-only metrics port. The generated
low-cardinality test metrics are served at `/api/metrics.prom`; the ServiceMonitor
scrapes both. Homepage consumes `/api/homepage.json` as an up-to-six-row Custom API
dynamic list; a category appears after its first authoritative publication. Result
markers are rendered on the left and Homepage formats completion time as a live
relative age on the right. Each row points to its stable rollup URL.

The `Cluster Verification` Grafana dashboard is provisioned from a labeled ConfigMap
and reads only the low-cardinality Prometheus series. It shows latest status and age,
latest passed cases, 30-day pass rate, duration history, failures by scenario, and time
since successful resilience/conformance. Its links resolve to stable report URLs.

Both presentation surfaces are staged inside the suspended application, so neither is
discovered until guarded bootstrap. The Gatus black-box probe remains deferred to the
activation PR to avoid a guaranteed false alarm before human acceptance.
