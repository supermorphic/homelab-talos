# n8n Workflow Automation Platform

## Purpose

Deploy an initially empty, self-hosted n8n service for
[issue 316](https://github.com/supermorphic/homelab-talos/issues/316). The service is a
general-purpose workflow orchestration platform. Its first planned consumer is a later
career-operations workflow that receives TheirStack job events, persists career-domain
state outside n8n, invokes deterministic and agent-driven processing, and sends
notifications.

This initiative establishes the platform and its operational foundation. It does not
implement the career workflow, career-specific database schemas, browser automation, or
an embedded Codex or Santifer runtime.

The target request path is:

```text
Internet sender
    |
    v
public Envoy Gateway -- hooks.lab.supermorphic.com/webhook/platform-canary --+
                                                                              |
private operator -- n8n.lab.supermorphic.com ------------------------------> n8n
                                                                              |
                                                                              v
                                                                       PostgreSQL
                                                                              |
                              +--------------------------------+
                              |
                              +--> n8n execution state
                              +--> daily logical dump
                              +--> Prometheus SQL metrics
```

## Existing platform context

The repository manages a three-node Talos and Flux cluster. Longhorn supplies replicated
`ReadWriteOnce` storage with two replicas and hard node anti-affinity. Its default
recurring jobs create a daily snapshot at 02:00 and a daily NAS backup at 03:00, retaining
seven of each. The cluster has no shared PostgreSQL, Redis, Valkey, database operator, or
database service that this initiative can reuse.

Existing stateful applications primarily use embedded databases. Their useful patterns
are retained Longhorn claims, `Recreate` deployment strategy for a `ReadWriteOnce` claim,
SOPS-encrypted Secrets, ServiceMonitors, PrometheusRules, dashboards, and scoped Cilium
network policy. They do not supply a PostgreSQL deployment baseline.

Envoy Gateway currently provides an internal wildcard HTTPS Gateway. The controller
admits namespaces labeled for either `internal` or `public` access, but the repository has
no active public Gateway or public HTTPRoute. A previous public Envoy experiment proved
that an isolated data plane can be created; its application-specific outcome does not
invalidate the infrastructure pattern.

## Goals

- Reconcile one n8n instance and one dedicated PostgreSQL instance through Flux.
- Keep the n8n UI and API private while exposing only explicit webhook paths to Internet
  senders.
- Give n8n outbound HTTPS access for later API integrations without giving it access to
  unrelated cluster services.
- Preserve PostgreSQL, n8n filesystem state, and logical dumps through routine pod and
  node failures.
- Make the PostgreSQL logical dump and the persistent `N8N_ENCRYPTION_KEY` one documented
  recovery unit.
- Detect n8n, PostgreSQL, webhook, backup, and storage failures through the existing
  Prometheus, Alertmanager, Grafana, and Gatus stack.
- Validate the platform with one authenticated synthetic webhook workflow that uses the
  normal n8n execution and PostgreSQL persistence path.
- Keep initial resource use appropriate for one operator and a small job-seeking
  workload while leaving safe memory headroom.
- Pin application, chart, database, and exporter versions and update them through the
  repository's normal review process.

## Non-goals

- The TheirStack `job.new` or `job.closed` workflow.
- Career-domain tables, scoring, tailoring, artifact generation, or application tracking.
- Redis, n8n queue mode, worker pools, or separate webhook processors.
- A reusable cluster database platform, PostgreSQL operator, streaming replica, or
  automatic database failover.
- Authentik, OIDC, SAML, or another centralized n8n login integration.
- Public access to the n8n editor, API, metrics, PostgreSQL, or backup artifacts.
- Native n8n source-control environments, which are not part of the selected Community
  deployment.
- A guarantee that n8n execution history is authoritative career or job state.
- Instant restore or zero-data-loss recovery after loss of the Longhorn volume set.

## Selected deployment approach

The implementation uses official n8n Helm chart 1.11.0 and n8n 2.36.7, plus focused
native Kubernetes resources for PostgreSQL. The chart's mutable `stable` application
default is overridden with the exact n8n image version. The rendered n8n workload must
use one replica, external PostgreSQL, filesystem binary-data mode, and no queue
components. Repository-owned HTTPRoutes replace any chart-provided ingress.

The official chart reduces local ownership of n8n-specific probes, ports, and deployment
configuration. PostgreSQL remains a small, understandable StatefulSet rather than
introducing a second chart with its own secret, upgrade, and lifecycle abstractions. This
is the smallest design that uses PostgreSQL from the start without creating a general
database platform for one consumer.

The chart's single-process external-PostgreSQL mode is less prominent in its examples
than queue mode. Rendered-manifest assertions are therefore a release requirement. They
must prove that queue mode, Redis, workers, separate webhook processors, and bundled
ingress remain disabled. They must also prove that the exact supported webhook URL
variable reaches the n8n container without the chart's deprecated compatibility alias.

## Flux and namespace ownership

The application uses an `automation` domain and namespace. The namespace carries the
existing internal-Gateway access label so the n8n UI HTTPRoute can attach to the internal
Gateway.

Flux owns three logical units:

1. `public-webhook-gateway` owns a dedicated public GatewayClass, EnvoyProxy, Gateway,
   single-host certificate, and shared public HTTPRoute policy. It resides in the
   networking domain and uses the existing Envoy Gateway and cert-manager foundations.
2. `n8n-postgresql` owns PostgreSQL, its data and backup claims, database Secrets, logical
   backup job, SQL Exporter, and ServiceMonitor.
3. `n8n` owns the n8n HelmRelease, n8n claim, private HTTPRoute, cross-namespace
   `ReferenceGrant`, canary template, and n8n ServiceMonitor. It depends on PostgreSQL,
   Longhorn, the internal and public Gateway foundations, cert-manager, and the monitoring
   stack.

Existing monitoring packages gain the related PrometheusRules, Grafana dashboard, and
Gatus endpoint. This keeps alerts, dashboards, and synthetic checks in their established
repository ownership locations rather than hiding them inside an application release.

The public HTTPRoute cannot live in `automation` because the current namespace labels
intentionally distinguish internal from public routes. The public Gateway package owns
the route in its public routing namespace. A narrowly scoped `ReferenceGrant` in
`automation` permits HTTPRoutes from that one namespace to reference only the n8n Service.
It does not grant general access to other Services or Secrets.

## n8n runtime

n8n runs as one process and one pod. Queue mode is disabled. Redis is not installed.
Redis would act as a queue broker rather than a useful application cache: the main process
would enqueue execution identifiers, workers would read workflow state from PostgreSQL,
and results would return through PostgreSQL and Redis. That topology adds another
stateful service and more failure paths without improving a one-person deployment.

The main workload uses `Recreate` when it is a Deployment because it mounts a Longhorn
`ReadWriteOnce` claim. It runs without a Kubernetes service-account token and without
cluster API permissions. The n8n container does not include career workers or browser
automation. Later agent or browser work uses an explicit external service interface
rather than adding those runtimes to the n8n pod.

n8n is configured with:

- PostgreSQL as its database;
- filesystem binary-data mode on the n8n claim;
- `N8N_WEBHOOK_URL=https://hooks.lab.supermorphic.com/`;
- `N8N_EDITOR_BASE_URL=https://n8n.lab.supermorphic.com/`;
- one trusted reverse-proxy hop;
- Prometheus metrics on an internal-only endpoint;
- successful and failed execution persistence;
- execution-data pruning after 14 days or 10,000 retained executions, whichever bound
  removes data first; and
- telemetry and unattended application updates disabled.

In n8n 2.36.7, `N8N_WEBHOOK_URL` is the canonical variable and `WEBHOOK_URL` is its
deprecated predecessor. Chart 1.11.0 still renders `WEBHOOK_URL` when `webhook.url` is
set. The Helm values therefore leave `webhook.url` empty and inject both canonical URLs
through `config.extraEnv`. Rendered-manifest assertions require one
`N8N_WEBHOOK_URL`, one `N8N_EDITOR_BASE_URL`, and no `WEBHOOK_URL`. Deprecated names do
not satisfy this design even when they still function.

## PostgreSQL runtime

PostgreSQL runs as one StatefulSet replica with a stable internal ClusterIP Service and a
pre-created Longhorn claim. The StatefulSet provides stable identity and ordered startup;
it does not claim high availability. Kubernetes can reschedule the pod and reattach its
replicated Longhorn volume after a pod or node failure.

No PostgreSQL operator or database replica is installed. Ordinary pod and single-node
failure should retain current data through Longhorn. Loss of the Longhorn volume set uses
the latest logical dump or Longhorn NAS backup and can lose up to 24 hours of changes.
Recovery is manual.

The PostgreSQL image uses an exact supported major and patch version. Renovate may propose
patch and compatible minor image changes. A PostgreSQL major-version change requires an
explicit migration design and is not an ordinary image update.

The database is reachable only from n8n, the logical backup job, and SQL Exporter. It has
no HTTPRoute, LoadBalancer, or NodePort. SQL Exporter uses a dedicated least-privileged
monitoring role. The logical backup job uses a role with only the database access required
to produce a complete n8n dump and update its operational backup marker.

## Access and webhook routing

### Private editor path

`n8n.lab.supermorphic.com` attaches to the existing internal Gateway. It exposes the n8n
editor, owner login, API, and private test surfaces only through the established LAN and
Tailscale access path. n8n's built-in owner authentication protects the UI. Authentik is
deferred because the initial deployment has one operator, private network reachability,
and no selected Community-edition OIDC integration.

### Shared public webhook edge

`hooks.lab.supermorphic.com` terminates TLS on a dedicated public Envoy data plane. Its
certificate contains only that hostname rather than the internal wildcard. The public
Gateway accepts explicitly attached routes and does not expose an n8n administration
path. Its listener accepts routes only from the dedicated public routing namespace, so an
application namespace cannot attach another backend directly.

The initial HTTPRoute uses an `Exact` path match for `/webhook/platform-canary`. It does
not expose `/webhook/*`, `/webhook-test/*`, or another prefix. Each later production n8n
integration, including TheirStack, requires its own exact path to be added through
Git/Flux. Publishing an n8n workflow alone therefore does not make its webhook Internet
reachable.

Future applications may reuse the same hostname only through separately reviewed,
non-overlapping exact paths or top-level prefixes. Adding a Service does not make it
public; every path needs an explicit HTTPRoute rule and any required `ReferenceGrant`.
Unmatched paths have no backend route.

TLS and route matching authenticate neither the sender nor the event. Every production
webhook workflow must enforce an integration-appropriate secret, signature, or token.
The synthetic canary uses n8n header authentication. The later TheirStack integration
must use the provider's verified signing or authentication contract once that contract is
confirmed.

Publishing the edge also requires operator-managed public DNS and router TCP/443
forwarding to the dedicated public LoadBalancer address. Those changes remain outside
Flux. No live public address is recorded in the repository.

The cluster's internal DNS answer for `hooks.lab.supermorphic.com` must resolve to the
dedicated public Envoy LoadBalancer, not the internal Gateway. This makes the in-cluster
Gatus check exercise the correct Envoy data plane. It does not prove that public DNS,
router forwarding, or the residential Internet path works; the attended off-network
acceptance test covers that separate path.

## Network policy

Cilium policy limits traffic by workload role:

- the n8n web Service accepts application traffic only from the internal and public Envoy
  data planes;
- the n8n metrics port accepts only Prometheus scraping;
- PostgreSQL accepts database traffic only from n8n, SQL Exporter, and the backup job;
- n8n egress permits cluster DNS, PostgreSQL, and Internet HTTPS endpoints;
- n8n cannot initiate connections to unrelated cluster Services or private network
  ranges;
- the backup job can reach PostgreSQL and cluster DNS but has no general Internet egress;
  and
- SQL Exporter can reach PostgreSQL and accepts metrics scrapes only from Prometheus.

The temporary restore drill adds run-owned policy only for its lifetime. Its isolated
n8n and database-helper pods receive the minimum DNS and PostgreSQL paths. A separate
policy in `gatus` selects only the run-labeled request Job and permits only DNS and the
run-owned n8n endpoint on TCP/5678. Cleanup must remove and prove absence of both exact
policies.

Inbound TheirStack webhooks do not themselves require n8n to pull data from TheirStack.
Outbound HTTPS remains part of the initial platform because later workflows must call
APIs and external processing services.

## Persistence and recovery

### Claims

The initial claims are:

| Purpose | Size | Access | Protection |
| --- | ---: | --- | --- |
| n8n filesystem and binary data | 5 GiB | Longhorn `ReadWriteOnce` | Retained |
| PostgreSQL data | 10 GiB | Longhorn `ReadWriteOnce` | Retained |
| PostgreSQL logical dumps | 10 GiB | Longhorn `ReadWriteOnce` | Retained |

Each claim is a pre-created manifest with
`kustomize.toolkit.fluxcd.io/prune: disabled`. Removing or renaming the consuming
HelmRelease, Deployment, or StatefulSet therefore does not make routine Flux pruning
delete the stored state. This protection does not survive deliberate namespace deletion,
manual PVC deletion, or storage-system destruction; Longhorn backups and logical dumps
cover those separate cases.

All three claims use the default Longhorn daily snapshot and NAS backup policy. The n8n
claim stores local configuration and binary execution data that PostgreSQL does not own.
The PostgreSQL claim provides current crash-consistent database storage. The backup claim
contains portable logical dumps and is also copied off-cluster by Longhorn's NAS backup.

### Logical backup

A daily CronJob runs at 01:00 UTC, before the existing Longhorn snapshot and NAS backup
windows. It uses `concurrencyPolicy: Forbid`, a bounded execution deadline, and a short
retained Job history. One successful run performs these steps in order:

1. Write a compressed custom-format `pg_dump` archive to a temporary filename on the
   backup claim.
2. Read and expand the archive through `pg_restore` without applying it to a database.
3. Calculate a SHA-256 checksum and write it to a temporary sidecar file.
4. Rename the archive and checksum sidecar to their final timestamped filenames on the
   same filesystem.
5. Recheck the final archive against its checksum and update an operational status row
   with its timestamp, filename, and checksum.
6. Remove archive-and-checksum pairs older than the newest seven successful artifacts and
   remove incomplete temporary or unpaired artifacts.

The status row is not updated when dump creation, archive reading, checksum calculation,
rename, or final inspection fails. Kubernetes Job success is useful diagnostic evidence,
but it is not the backup-freshness oracle.

Only a final archive with its matching checksum sidecar is a successful artifact. The
accepted artifact check proves that the complete archive is readable and internally
processable, and the sidecar permits verification when the source database is no longer
available. A documented temporary-database restore drill supplies the stronger end-to-end
recovery test and must be completed during initial acceptance and after material backup
changes.

### Encryption key and Secrets

SOPS-encrypted manifests hold the PostgreSQL credentials, SQL Exporter credential,
canary authentication value, and one stable `N8N_ENCRYPTION_KEY`. The encryption key is
generated once and never regenerated during a normal reconciliation, reinstall, or
restore.

The canary authentication value uses one contract across Secret creation, Gatus, attended
requests, and the persistence scenario: at least 32 characters from the base64url-safe
alphabet `A-Z`, `a-z`, `0-9`, `_`, and `-`. The guarded writer and request paths reject
spaces, quotes, backslashes, line breaks, padding, and all other characters before they
write a manifest or curl configuration. The guarded writer performs all required
presence, confirmation, minimum-length, and alphabet checks before it creates a temporary
workspace, installs cleanup traps, or runs the age-identity preflight. It never prints the
supplied value.

Database passwords are also generated once and retained. Updating a Secret alone does not
change a password already initialized inside PostgreSQL; database credential rotation is
a coordinated database and Secret operation.

n8n stores integration credentials encrypted in PostgreSQL. A database dump without the
unchanged encryption key cannot recover those credentials. The logical dump and the
encrypted key manifest therefore form one recovery unit. A complete restore also depends
on the operator-held SOPS age identity, which is not stored in Git or copied into the
cluster as backup payload.

The recovery unit is deliberately distributed: the dated logical archive is retained on
the backup claim and its Longhorn NAS backup, while the unchanged SOPS-encrypted key
manifest is retained in the remote Git history. Repository validation confirms that the
encrypted manifest remains present. Restore documentation identifies both artifacts and
does not describe the dump alone as a complete n8n backup. The backup job never reads or
copies the plaintext encryption key into a dump, checksum file, log, or metrics series.

Changing only `N8N_ENCRYPTION_KEY` makes existing credential ciphertext unreadable. Key
rotation is a separate controlled operation using n8n's supported rotation procedure; it
is not a normal Secret refresh.

### Restore objective and procedure

The off-cluster recovery-point objective is 24 hours. There is no fixed recovery-time
objective because database restore and validation are manual. The implementation adds a
runbook that, at minimum, covers:

1. selecting and checksum-validating a logical artifact;
2. preserving the current database volume before destructive recovery;
3. restoring first into a temporary empty database;
4. validating n8n schema access and the synthetic workflow;
5. restoring or retaining the matching SOPS-encrypted `N8N_ENCRYPTION_KEY`;
6. cutting n8n over only after validation; and
7. confirming a new successful dump and freshness metric after recovery.

The runbook must distinguish routine pod rescheduling, Longhorn volume recovery, logical
database restore, and full service reconstruction.

## Workflow and data ownership

PostgreSQL is the runtime source of truth for live n8n workflows, published versions,
users, credential ciphertext, settings, and retained execution history. The n8n claim is
the runtime source of truth for filesystem binary data. The backup design protects both
forms of runtime state.

n8n is not the authoritative store for career or job state. A later career workflow must
persist an authenticated event to an external domain store before it returns a successful
acknowledgement when the provider's retry contract requires that guarantee. Execution
history remains operational evidence and a debugging aid.

The initial operating model is UI-first. The public infrastructure repository owns only
the platform and a secret-free synthetic canary template. Stable career workflows are
later exported to a separate private repository after their behavior is understood.
Credential values are never included in exported workflow commits. Native n8n
source-control environments are not introduced because the selected Community deployment
does not provide that paid feature.

## Synthetic canary

The canary is a real published n8n workflow, not a static Envoy or web-server response. It
contains only a header-authenticated Webhook trigger configured with **Respond: When Last
Node Finishes** and a deterministic final Edit Fields node. The response includes the
request correlation value and `$execution.id`. The workflow contains no Respond to
Webhook node, career logic, SQL node, domain persistence, or external side effect.

This precise response mode is part of the persistence contract. In pinned n8n 2.36.7
regular mode, the last-node response waits for the post-execution promise. The execution
lifecycle awaits its `workflowExecuteAfter` hooks, including the PostgreSQL execution
update, before resolving that promise. The successful response therefore represents a
completed normal execution whose configured success record has been persisted. This
makes PostgreSQL part of the canary semantics without adding an artificial database
query.

Acceptance must verify the implementation behavior rather than infer it only from source.
It sends a unique correlation value, records the returned execution ID, and then retrieves
that execution through the private n8n history or API. The record must be successful and
contain the matching correlation value immediately after the response completes. If the
pinned runtime requires polling because persistence is asynchronous, implementation must
stop and revise this contract before merge rather than claim that the response acknowledges
completed persistence.

The template contains no authentication value. After the initial deployment, the
operator creates the n8n owner account through the private UI, imports the template,
creates and binds its header-auth credential using the SOPS-managed canary value, and
publishes it. This one-time bootstrap avoids a persistent privileged bootstrap API key.

Gatus calls `/webhook/platform-canary` every five minutes from its normal monitoring
context with the same SOPS-managed header value after public activation. Before
activation, the active Gatus Helm values contain neither the required Secret reference nor
the endpoint. Their complete exact values remain in a Git-owned staged activation fragment
and are copied into active values only in the reviewed public-route activation change.
Gatus then verifies the status and correlation response. A separate negative acceptance
request without valid authentication must fail. Gatus never checks the public n8n UI
because no such route exists.

## Error and retry behavior

The public Gateway returns no backend route for unmatched paths. n8n rejects missing or
invalid canary authentication before a successful execution. The chart readiness probe
uses `/healthz/readiness`, which checks database connectivity and migrations before Envoy
can send traffic to the pod. If PostgreSQL becomes unavailable during a canary run, the
required execution-persistence update cannot complete and the request cannot satisfy the
successful last-node response contract.

n8n records workflow failures according to the 14-day and 10,000-execution retention
bounds. Prometheus alerts on platform failure patterns; the UI remains the detailed
execution-debugging surface.

Provider retry behavior, event idempotency keys, dead-letter handling, and reconciliation
are properties of the later TheirStack workflow. The public edge does not invent those
semantics before the provider contract and career-domain store exist.

## Capacity

The initial storage allocation is conservative for one operator and a low-volume
job-seeking workload. Core runtime resources are:

| Workload | CPU request / limit | Memory request / limit |
| --- | ---: | ---: |
| n8n | 100m / none | 256 MiB / 1 GiB |
| PostgreSQL | 50m / none | 256 MiB / 1 GiB |
| SQL Exporter sidecar | 10m / none | 32 MiB / 128 MiB |
| logical-backup Job | 50m / none | 64 MiB / 512 MiB |

The absence of CPU limits lets dumps, migrations, maintenance, and temporary workflow
bursts finish without artificial throttling while Kubernetes scheduling still accounts
for baseline use. The 1 GiB PostgreSQL memory limit avoids a 512 MiB hard ceiling during
dumps, maintenance, migrations, or temporary query growth. Auxiliary backup and exporter
containers have smaller explicit envelopes and do not change the core service topology.

Resource use, execution duration, database size, binary-data growth, and dump size are
reviewed after the platform has representative career workflow traffic. Measurement, not
the presence of PostgreSQL itself, determines later resizing or queue-mode work.

## Observability and alerts

n8n exposes its supported Prometheus metrics on a cluster-internal metrics port with
high-cardinality optional labels disabled. SQL Exporter runs as a sidecar in the
PostgreSQL pod and uses configuration-defined PostgreSQL collectors for availability,
connections, transactions, database size, and the logical-backup marker. When it cannot
reach PostgreSQL, its scrape fails and Prometheus records the target as down.

The backup job owns a repository-defined operational schema separate from n8n-owned
tables. The schema contains one logical-backup status row. n8n receives no permission to
modify it, and SQL Exporter's monitoring role receives read-only access.

The backup collector exposes:

```text
n8n_postgresql_backup_last_success_timestamp_seconds
```

The value comes from the operational status row updated only after a validated artifact
has its final name and checksum. Prometheus alerts when the series is absent or more than
36 hours old. The alert therefore means that no validated logical backup completed in the
expected daily window. CronJob failure and missed-schedule alerts provide supporting
diagnostics but do not replace this invariant.

PrometheusRules cover:

- unavailable n8n or PostgreSQL scrape targets;
- unavailable n8n or PostgreSQL workloads and repeated restarts or OOM kills;
- a sustained increase in failed n8n executions over a 15-minute window;
- absent or stale logical-backup freshness;
- failed or overdue backup Jobs;
- Gatus failure of the authenticated public canary;
- unready public Envoy backends and certificate expiry through existing platform
  signals; and
- claim use for the n8n, PostgreSQL, and logical-backup claims.

The monitoring alerts package owns `n8n.yaml`, but the active pre-activation alerts
Kustomization does not select it. The reviewed public activation change selects the exact
rule file together with the public route and Gatus canary. Git resource selection is the
durable activation identity; runtime Flux health is not an alert-evaluation gate. Once
selected, the rules stay loaded through reconciliation failures and missing Flux metric
series. The n8n and PostgreSQL scrape-target and workload-availability alerts fire for
both an explicit zero and a fully absent matching source series. The absent branches
preserve stable namespace, service, Deployment, or StatefulSet identity labels.

All three claims use the established repository thresholds:

- warning above 70 percent used for 15 minutes; and
- critical above 85 percent used for 5 minutes.

A compact Grafana dashboard shows n8n/PostgreSQL resource use, execution health,
restarts, storage growth, backup freshness, and webhook-canary health. Alertmanager
remains the only alert-delivery path.

## Rollout

The rollout follows dependency order:

1. Reconcile the public Gateway, dedicated certificate, routing namespace, inactive
   Gatus canary contract, and monitoring package with the n8n rule file staged but
   unselected. Do not publish router forwarding.
2. Reconcile the PostgreSQL claims, StatefulSet, Service, backup job, and SQL Exporter.
3. Reconcile n8n with queue mode disabled and confirm database migrations and private UI
   readiness.
4. Complete the owner and synthetic-canary bootstrap through the private UI.
5. Add operator-managed public DNS and TCP/443 router forwarding. In one reviewed Git
   change, unsuspend the exact public route, copy the staged Gatus Secret reference and
   endpoint into the active values, and select `./n8n.yaml` in the monitoring alerts
   Kustomization. The encrypted canary Secret and both private workload Kustomizations
   must already be selected, unsuspended, and ready.
6. Wait for the public route, Gatus probe, and selected n8n rule group to become current,
   then run off-network positive and negative webhook acceptance tests.

The initial pins are n8n chart 1.11.0 and n8n 2.36.7. The implementation also records the
resolved immutable chart artifact digest and exact container image reference. An n8n
upgrade requires a fresh logical dump and review of the upstream release notes. A rollback
must account for database migrations; reverting an image is not assumed safe when the new
version changed the schema.

Removing or rolling back workloads does not delete retained claims. Destructive data
removal is never part of application rollback.

Public containment removes router TCP/443 forwarding first. Flux suspension does not
delete an already applied HTTPRoute. The Git rollback therefore keeps the route child
reconciling with pruning enabled while its Kustomization stops selecting
`httproute.yaml`, waits for current-generation reconciliation, and proves the route is
absent. Only then may a later Git change suspend that child. Public activation and later
reactivation remain Git-owned. A durable withdrawal also removes the n8n Secret reference
and endpoint from active Gatus values and unselects `./n8n.yaml` from the monitoring
alerts Kustomization while retaining the staged Gatus fragment and rule file.

## Validation and acceptance

Cluster-independent validation includes the canonical `mise exec -- just ci` gate.
CI runs one complete n8n source/render validator against the candidate tree. CI retains
focused backup, Secret-writer, and verifier-helper behavior tests. CI does not copy and
corrupt production manifests to self-test the validator. The existing verification,
scoped-verification, smoke, integration, and resilience tiers retain their n8n suites.
The documented focused operator sequence runs verification, smoke, isolated restore, and
persistence/recovery assurance in that order. The existing standard, weekly, and full
campaigns compose the applicable tier suites without adding an app-specific n8n campaign.
Intentional validator-failure fixtures are diagnostics, not authoritative campaign
evidence.

Focused tests and rendered-manifest assertions verify:

- the selected official chart renders one n8n process with external PostgreSQL;
- queue mode, Redis, workers, separate webhook processors, and bundled ingress are absent;
- the n8n container has one `N8N_WEBHOOK_URL`, one `N8N_EDITOR_BASE_URL`, and no
  deprecated `WEBHOOK_URL`;
- a Deployment mounting the n8n `ReadWriteOnce` claim uses `Recreate`;
- all three claims are Longhorn-backed and carry Flux prune protection;
- the only initial public route is an `Exact` match for `/webhook/platform-canary`, with
  no editor, API, metrics, PostgreSQL, test-webhook, prefix, or catch-all route;
- only the public routing namespace receives the cross-namespace Service grant;
- network policies implement the approved ingress and egress boundaries;
- resource and execution-retention settings match this specification;
- the backup script cannot update freshness before final artifact validation; and
- Prometheus alert expressions cover absent metrics and both storage thresholds;
- the active pre-activation Gatus render has no required n8n Secret reference or canary
  endpoint, while the staged activation fragment renders their complete exact contract;
- the active pre-activation monitoring render omits the n8n rule, complete Git activation
  selects it exactly once, and incomplete or early selection fails source validation;
- selected n8n rules remain evaluable when Flux readiness metrics are false or absent; and
- zero-valued and fully absent n8n and PostgreSQL scrape-target and workload-replica
  series produce the same post-activation availability alerts with stable identity labels.

The read-only verifier uses only observational Kubernetes and Prometheus/Gatus state. It
requires unsuspended current-generation Flux resources, complete current workload
rollouts, one exact healthy Prometheus target for each ServiceMonitor, and the complete
canonical shape of every route to the n8n Service. It does not read Secrets, access the
database, use pod exec, or send a canary request. Authenticated canary execution belongs
to the attended mutating persistence, restore, and off-network acceptance paths.

Combined read-only and attended live acceptance verifies:

1. Flux reports the public Gateway, PostgreSQL, n8n, and monitoring resources ready.
2. The n8n UI works through the private hostname and has no public route.
3. The public hostname serves only the exact `/webhook/platform-canary` path.
4. An authenticated canary request returns its correlation value and execution ID only
   after a matching successful execution is immediately retrievable from n8n history;
   invalid authentication fails without a successful execution.
5. Controlled n8n and PostgreSQL pod restarts preserve configuration, workflow, database,
   and required filesystem state.
6. A logical backup creates a validated final artifact and advances the Prometheus
   freshness timestamp.
7. The documented procedure restores that artifact into a temporary database, identifies
   the exact active Platform Canary workflow and its exact bound Header Auth credential
   from non-secret metadata, rejects an unauthenticated request, and accepts a structurally
   exact authenticated response. This proves that the unchanged encryption key permits
   n8n to read restored credential ciphertext.
8. Prometheus scrapes n8n and SQL Exporter, the new rules evaluate without errors, and the
   Grafana dashboard shows data for both services.
9. An off-network client reaches the authenticated public webhook while public editor,
   API, metrics, and unrelated paths remain unavailable.

Secret generation, the owner and canary credential bootstrap, public DNS and router
changes, controlled restart testing, and the restore drill are operator actions whenever
they require credential or live-mutation authority outside the agent's approved scoped
workflow. Independent repository and read-only cluster validation remains agent-owned.

## Rejected alternatives

### SQLite

SQLite would avoid PostgreSQL initially but create a later database migration and couple
more application state to the n8n filesystem. PostgreSQL from the start gives clearer
backup, monitoring, and growth behavior.

### Redis and queue mode

Redis is a broker in n8n queue mode, not a general cache that makes this single-instance
deployment simpler. Queue mode adds workers, coordination, another stateful service, and
more failure paths. It remains a later scaling option based on measured concurrency or
execution backlog.

### Reusable PostgreSQL platform or operator

The cluster has one planned database consumer and no established database service.
Operators, database replicas, automated failover, and shared lifecycle policy add more
operational surface than this workload needs. A later multi-consumer database initiative
can use its own specification.

### PostgreSQL Helm chart

A second application chart would add chart-specific secret generation, persistence, and
upgrade behavior around a one-pod database. A focused StatefulSet, Service, retained
claim, and backup job are easier to audit and recover in this repository.

### Native n8n manifests

Owning every n8n-specific deployment field would duplicate maintained chart behavior.
The official chart is preferred, with render tests guarding its underdocumented
single-process external-PostgreSQL mode.

### Public n8n UI

Path filtering on a shared public n8n origin would leave more administrative behavior at
the Internet boundary and make future route changes riskier. Separate private and public
Gateways provide a clearer trust boundary.

### Pushgateway for backup freshness

A Pushgateway would add a service solely to remember one batch timestamp and still would
not make CronJob status an artifact oracle. The artifact-gated database marker and SQL
Exporter provide the custom timestamp together with PostgreSQL availability and resource
metrics.

## Review triggers

Revisit this design when measured concurrent executions create backlog, long-running work
blocks interactive use, a separate execution worker becomes necessary, more applications
need managed PostgreSQL, the 24-hour recovery point is no longer acceptable, claims
regularly cross 70 percent, or centralized SSO becomes a supported operational
requirement. Those conditions may justify Redis queue mode, worker pools, a database
operator, larger claims, more frequent off-cluster backups, or Authentik integration.
They do not require those components in advance.

Before merge, reconcile this specification with the implemented chart and image versions,
actual configuration fields, rendered resources, runbook, and validated cluster result.

## External references

- [n8n Kubernetes hosting repository](https://github.com/n8n-io/n8n-hosting)
- [n8n Helm chart 1.11.0](https://github.com/n8n-io/n8n-hosting/tree/v1.11.0/charts/n8n)
- [n8n 2.36.7 release](https://github.com/n8n-io/n8n/releases/tag/n8n%402.36.7)
- [n8n 2.36.7 canonical URL environment
  variables](https://github.com/n8n-io/n8n/blob/n8n%402.36.7/packages/%40n8n/config/src/index.ts)
- [n8n 2.36.7 webhook response
  sequence](https://github.com/n8n-io/n8n/blob/n8n%402.36.7/packages/cli/src/webhooks/webhook-helpers.ts)
- [n8n 2.36.7 execution persistence
  hooks](https://github.com/n8n-io/n8n/blob/n8n%402.36.7/packages/cli/src/execution-lifecycle/execution-lifecycle-hooks.ts)
- [n8n PostgreSQL
  configuration](https://docs.n8n.io/hosting/configuration/supported-databases-settings/)
- [n8n queue mode](https://docs.n8n.io/hosting/scaling/queue-mode/)
- [n8n Prometheus metrics](https://docs.n8n.io/hosting/logging-monitoring/monitoring/)
- [n8n execution-data retention](https://docs.n8n.io/hosting/scaling/execution-data/)
- [n8n encryption
  key](https://docs.n8n.io/hosting/configuration/configuration-examples/encryption-key/)
- [n8n reverse-proxy webhook
  URL](https://docs.n8n.io/hosting/configuration/configuration-examples/webhook-url/)
- [n8n source-control environments](https://docs.n8n.io/source-control-environments/)
- [PostgreSQL `pg_dump`](https://www.postgresql.org/docs/current/app-pgdump.html)
- [PostgreSQL `pg_restore`](https://www.postgresql.org/docs/current/app-pgrestore.html)
- [SQL Exporter](https://github.com/burningalchemist/sql_exporter)
- [Gateway API cross-namespace routing](https://gateway-api.sigs.k8s.io/guides/multiple-ns/)

## Pull request linkage

Every pull request produced by this initiative links
[GitHub issue 316](https://github.com/supermorphic/homelab-talos/issues/316) in its
description. Partial pull requests use `Related to #316`. Only the pull request that
finishes the accepted issue scope uses `Closes #316`.
