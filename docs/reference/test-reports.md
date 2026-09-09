# Persistent test reports

`tests.lab.supermorphic.com` is the always-running, LAN-only archive for
retained test evidence. It is not an Allure daemon and does not need an
Allure process after publication: Allure 3 generates static HTML, Caddy serves those
files continuously from a retained Longhorn volume, and the internal Gateway owns
TLS.

## Responsibilities

- Allure 3 (operator workstation): converts canonical JUnit and indexed evidence into
  the Awesome static report.
- `report_publish.py` (operator workstation): validates structured metadata, merges the
  catalog, applies retention, updates lifetime counters, creates stable latest links,
  and builds a checksummed allowlisted bundle plus a deterministic portable tar stream.
- `publish-report.sh` (workstation): enforces explicit publication intent and the
  deployed-source guard, scans for secrets, holds the publication Lease, and streams
  the prebuilt archive through a guarded `kubectl exec`.
- `run-campaign.sh` (workstation): resolves explicit catalog acceptance or a campaign,
  captures each canonical run ID, and invokes the guarded publisher automatically.
  Child reports remain authoritative instead of being replaced by an aggregate run.
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
the Deployment pod template and triggers a `Recreate` replacement. The Grafana dashboard
ConfigMap intentionally keeps its stable name because it is discovered separately by
label. This split prevents Flux from applying new server configuration without the
running Caddy process loading it.

The Caddy container still drops `ALL` Linux capabilities and runs non-root with
privilege escalation disabled. It adds back only `NET_BIND_SERVICE` because the
official Caddy image stamps that file capability onto `/usr/bin/caddy`; omitting it
from the capability bounding set makes Linux reject the executable before Caddy reads
its configuration. Caddy itself listens only on the unprivileged 8080 and 9090 ports.

## Publication and authority

Publishing is intentionally a push operation from the workstation. There is
no cluster upload service to attack or authenticate. The recipe requires:

- explicit recorded acceptance or the manual publisher's exact run-scoped confirmation;
- a canonical, finalized run with complete JUnit/evidence indexing;
- clean captured Git metadata and a locally available commit;
- the publisher and server sources already merged to `origin/main`;
- successful secret scans of both canonical input and exact output bundle;
- deterministic archive construction independent of the operator host's `tar`
  implementation or filesystem metadata;
- the dedicated renewable `flux-system/homelab-test-report-publish-lock` Lease.

A clean historical or feature-commit run may be retained as candidate evidence. Only a
run whose Git SHA equals both current `origin/main` and the Flux artifact revision is
authoritative; candidates never drive Homepage data, stable latest links, or
last-run metrics.

For initiative completion and infrequent assurance, use
`mise exec -- just test acceptance <suite-id|scoped-verification>`. In a linked worktree,
this uses the existing verifier identities to execute approved scoped checks, then selects
`homelab-report-publisher` only for publication. Agents need no operator confirmation for
that publication. The observer remains the kubeconfig's default context. Publisher access
is restricted to the report namespace, named Flux source reads, and get/update on the
Git-created publication Lease. It grants no authority to execute mutating suites.
`mise exec -- just test acceptance-publish <run-id>` deliberately retains an existing
finalized canonical run using the same publication authority, without rerunning its suite.

For routine multi-suite publication, use the catalog-backed campaigns documented in
[`docs/guides/test-campaign-operations.md`](../guides/test-campaign-operations.md). Operator-published campaign mode requires exact
current-main authority and therefore never uploads candidate children. Standalone
`just test publish` keeps the historical and candidate workflow above.

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
scrapes both. Homepage consumes `/api/homepage.json` as three Custom API blocks:
`LATEST`, `LAST RUN`, and `LAST FAILURE`. The latest result and both completion times
use authoritative evidence only; Homepage formats timestamps as relative ages. Publication
state retains the most recent failed or broken completion even after its report is pruned.
Unavailable history leaves a blank value. The Kubernetes `RUNNING` badge measures service
availability separately from test evidence health. When upgrading an existing archive,
the first fresh publication creates the new summary contract from retained authoritative
history. Until that publication, the new widget fields remain blank; republishing an
identical run remains a no-op.

The `Cluster Verification` Grafana dashboard is provisioned from a labeled ConfigMap
and reads only the low-cardinality Prometheus series. It shows latest status and age,
latest passed cases, 30-day pass rate, duration history, failures by scenario, and time
since successful resilience/conformance. Its links resolve to stable report URLs.

Homepage and Grafana presentation are served by the active application. Gatus probes
the archive index every minute through the complete internal user-facing path.
