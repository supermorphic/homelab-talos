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
    │   └── latest/<tier>/<target>/<scenario>/index.html
    └── current -> generations/<generation>
```

The 20 GiB Longhorn claim is `ReadWriteOnce`, so the one-replica Deployment uses
`strategy: Recreate`. The PVC has Flux prune disabled; deleting the Kustomization does
not authorize deleting the archive.

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

Review the root index and report at `https://tests.lab.supermorphic.com`. Then create
the separate activation PR that changes `suspend: false` and adds the Gatus endpoint.
After that merges, run `mise exec -- just kube test-reports-verify`.

Agents stage and validate the source but do not bootstrap or publish. GitHub Actions
does not have cluster access and never publishes here; its reports remain GitHub
workflow artifacts.

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
- Exact report: `https://tests.lab.supermorphic.com/reports/<run-id>/awesome/`
- Canonical download: `https://tests.lab.supermorphic.com/artifacts/<run-id>.tar.gz`
- Stable latest link:
  `https://tests.lab.supermorphic.com/latest/<tier>/<target>/<scenario-or-_>/`

Caddy exposes its native metrics on the internal-only metrics port. The generated
low-cardinality test metrics are served at `/api/metrics.prom`; the ServiceMonitor
scrapes both. The source PR includes PVC-bound and archive-capacity alerts. Homepage's
dynamic rows, the Grafana dashboard, and the Gatus black-box probe are activated in the
following presentation/activation phase so a suspended application cannot create a
false alarm.
