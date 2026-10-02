# n8n Workflow Automation Platform

## Purpose and boundaries

Provide a private, self-hosted workflow platform with explicitly published Internet
webhooks. The platform owns orchestration, execution state, shared synthetic checks,
and recovery. Consumers own event authentication, domain persistence, idempotency,
retry semantics, and business workflows. n8n execution history is operational evidence,
not authoritative domain state.

The public repository owns secret-free platform templates. Live workflows, published
versions, users, and encrypted credentials reside in n8n's PostgreSQL database.
Filesystem binary data resides on the separate n8n claim. Flux distributes templates;
it does not update already imported or published workflows. Stable consumer workflows
and sensitive exports belong in their owning private repository.

## Deployment and ownership

Use the official chart with one process, external dedicated PostgreSQL, and filesystem
binary data. Queue mode, Redis, workers, separate webhook processors, and bundled ingress
are excluded until measured concurrency justifies a different design. Browser or agent
runtimes use explicit external interfaces rather than sharing the n8n pod.

The [n8n package](../../kubernetes/apps/automation/n8n/ks.yaml) owns its workload,
private route, claim, Service grant, metrics, and templates. The
[PostgreSQL package](../../kubernetes/apps/automation/n8n-postgresql/ks.yaml)
owns database storage, logical backups, and SQL monitoring. Dedicated
[public-edge resources](../../kubernetes/apps/networking/public-webhook-gateway/ks.yaml)
own Internet routing. Established monitoring packages own checks, alerts, and dashboards.
Chart/image pins and runtime settings live in
[values](../../kubernetes/apps/automation/n8n/app/values.yaml) and their source references.

The n8n Deployment uses `Recreate` for its `ReadWriteOnce` claim and has no Kubernetes
API permissions or mounted service-account token. PostgreSQL is a single StatefulSet;
Longhorn rescheduling and replication protect ordinary pod/node failure but do not
provide database failover. PostgreSQL major upgrades require a migration design.

Render validation must preserve the single-process topology and supported URL contract.
Inject `N8N_WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` without the deprecated `WEBHOOK_URL`
alias; the chart's compatibility behavior must not silently select that alias.
Code nodes use `require('url').URL` where needed because the sandbox does not guarantee
a global `URL`. The allowed built-in does not authorize external modules or wildcards.

## Access and webhook routing

The editor, owner login, API, metrics, and test webhooks remain private. The private
route supports bounded synchronous calls; caller disconnection does not prove a workflow
stopped and does not authorize resending it. Consumers impose their own execution deadlines.

The public hostname terminates TLS on a dedicated Envoy data plane with a single-host
certificate. The public listener admits only its routing namespace; a narrow
`ReferenceGrant` permits only the n8n Service. The
[HTTPRoute](../../kubernetes/apps/networking/public-webhook-gateway/route/httproute.yaml)
is the allowlist. Each new integration requires a reviewed non-overlapping route and
its own authentication and acceptance. Publishing a workflow alone does not publish
its webhook. Editor/API paths, test webhooks, prefix catch-alls, and unmatched paths
have no public backend. TLS and path matching do not authenticate events.

Cilium admits application traffic only from the designated gateways, metrics only
from Prometheus, and PostgreSQL only from n8n, backup, and exporter workloads. n8n
outbound access is limited to DNS, its database, approved private integrations, and
Internet HTTPS; it cannot initiate arbitrary access to unrelated private services.
Backup and exporter workloads have no general Internet egress.

Internal DNS deliberately resolves the public hostname to the public Envoy data plane.
That Git-managed answer proves neither external DNS nor residential Internet reachability.
UniFi observes the WAN address and updates the public DNS-only Cloudflare record with a
dedicated, zone-restricted token retained outside Git. Router forwarding is operator-owned.
The internal Gatus probe and attended off-network checks establish different paths.

## Persistence and recovery

Pre-created data and backup claims carry Flux prune protection. This prevents routine
workload removal from deleting state, but not namespace/PVC deletion or storage loss.
Longhorn snapshots and off-cluster backups complement portable logical dumps.
A backup advances freshness only after a complete checksum-valid archive has been
atomically published; Job success alone is not a usable-backup oracle.

The recovery unit includes a dated n8n logical dump, the unchanged
`N8N_ENCRYPTION_KEY`, and the filesystem claim when binary data matters. Retain outside
the cluster the operator age identity, encrypted runtime Secret in remote Git history,
the stable key in the operator recovery system, and backup-target access. The dump and
its off-cluster copy are separate from the key's encrypted Git recovery root. Backup
jobs never copy plaintext encryption keys into archives, logs, or metrics.

A replacement key cannot decrypt existing credential ciphertext. Key rotation needs
n8n's supported controlled procedure. Likewise, updating a database Secret alone does
not update the password already initialized in PostgreSQL; coordinate both sides.
The off-cluster recovery-point objective is 24 hours, with no fixed recovery-time promise.

### Choose a recovery path

1. With healthy claims and an unready pod, preserve state and let its controller reschedule;
   use `mise exec -- just kube n8n-verify` after recovery.
2. With unavailable storage, preserve the volume and follow the storage boundary in
   [platform recovery](010-talos-flux-platform.md). Do not recreate claims as rollback.
3. With logical database damage, preserve current state and first restore a selected
   validated archive in isolation with the retained encryption key. Production replacement
   requires explicit operator authority; the isolated drill does not perform it.
4. If incomplete or incorrect public responses are possible, contain exposure below before
   recovery. Re-enable only after private and off-network acceptance.

The guarded `mise exec -- just kube n8n-restore-drill` checks restored authentication,
persistence, and run-owned cleanup. It requires authorized mutation credentials and its
exact confirmation. Failure or cleanup failure stays failed. Independent recovery must
prove that restored n8n can use a retained credential; checksums and healthy replicas
alone cannot establish that chain.

### Public exposure rollback

Remove router TCP/443 forwarding first and prove off-network containment. Disable its
DDNS profile and remove the public record when withdrawing exposure durably; preserve
the Git-managed internal DNS record. Suspension does not delete an applied HTTPRoute.

In the reviewed Git containment change, keep `public-webhook-route` unsuspended with
pruning enabled and make its
[route Kustomization](../../kubernetes/apps/networking/public-webhook-gateway/route/kustomization.yaml)
select `resources: []`. Wait for current-generation reconciliation and prove
`networking-public/n8n-platform-canary` absent before a later Git change suspends the
child. If either containment or absence proof fails, stop; do not suspend early.
Durable withdrawal removes the public Gatus endpoint/Secret reference and n8n alert
selection while preserving their staged activation sources and the private readiness check.

Reactivation restores the exact route and monitoring selections through Git, waits for
current acceptance, verifies DDNS, and restores forwarding last. Keep claims, encryption
material, and dumps throughout withdrawal and rollback.

## Synthetic canary and acceptance

The Platform Canary is an authenticated real webhook execution with a deterministic
correlation value and execution ID. Steady state retains failures and discards successful
production executions. PostgreSQL participates in the execution lifecycle, but a response
ID does not promise a retrievable success record.

For attended activation, upgrade, recovery, or off-network acceptance, temporarily enable
successful execution retention on the exact live workflow. Send a unique correlation,
retrieve the returned execution immediately through private history/API, and require it
matches. Restore success retention to `none`, including on failure, then prove subsequent
successful requests retain the response contract without completed history records.
Reconcile imported/restored canary settings through private n8n; updating its template
alone does not alter the published instance. Failed execution retention remains configured
but unexercised unless a real failure is inspected.

Owner-account creation, importing the template, binding the retained header credential,
and publishing occur privately. Avoid a persistent privileged bootstrap API key. Gatus
checks readiness and authenticated execution independently; invalid authentication must
fail without a successful execution. Off-network acceptance also proves that private
administrative and unrelated paths remain unavailable. Keep private inspection available
on a separate client while the test client is disconnected from LAN/VPN. Put authentication
headers in a protected request configuration rather than process arguments; exclude
credential-bearing request/response files from retained evidence.

## Shared workflow failure notifications

The platform-owned Error Trigger template sends bounded operational metadata to ntfy's
`homelab` topic through the dedicated `n8n` write-only identity. Consumers explicitly bind
its instance via `settings.errorWorkflow`; the platform does not reconcile consumer
workflows or keep a consumer inventory. The token is managed through the existing
ntfy identity and consumer-sync lifecycle, not copied into workflow exports.

The handler emits fixed summaries rather than raw provider errors. Workflow/node names
must remain non-sensitive. It links execution IDs only on the fixed private editor origin,
labels unavailable fields, and disables its own execution persistence because incoming
errors may contain domain data. It has no downstream error workflow, redirect, retry,
queue, or business-workflow retry path. One bounded publish attempt means outages can
lose notifications; there is no deduplication or detection of schedules that never run.

Setup imports the
[handler template](../../kubernetes/apps/automation/n8n/app/workflows/platform-workflow-failure.json),
binds **Platform Failure ntfy**, saves/publishes it, and selects that handler on each
consumer. Use the existing guarded ntfy token generation/synchronization workflow;
manual credentials stay private. Reciprocal workload-specific policy permits its ntfy
connection. Synthetic acceptance uses two independent automatic-failure consumers,
checks secret-marker exclusion and execution links, then bounded delivery failure,
absence of recursion, and cleanup. Recheck native publish/caller permissions on upgrades.

## Activation, upgrades, and validation

First activation follows dependency order: retained Secrets and gateway prerequisites;
PostgreSQL and private n8n; private owner/canary bootstrap; private verification;
reviewed public route and monitoring selection; then off-network positive and negative
acceptance. Do not forward Internet traffic before the private path is accepted.
Workflow publication and Git-managed activation are separate operations.

Before upgrade, require a recent validated dump, review migration compatibility, and run
the isolated restore drill. An image revert cannot be assumed to undo database migrations.
Measure resources, execution duration, storage growth, and backlog before adding queue
components or changing topology.

Source/render checks protect topology, routes, policy, Secret handling, backup ordering,
and monitoring lifecycle. `n8n-verify` observes deployed readiness, monitoring, and backup
freshness without reading Secrets, sending webhooks, or using exec/database access.
Activation-owned alerts remain evaluable through Flux failures and missing metrics;
absence after activation is failure, not permission to unload rules. Registered live tests
own authenticated requests, controlled restarts, persistence, isolated restore, and cleanup.
CI does not establish native acceptance or authorize these mutations.

Implementation details and current suite selection are owned by
[commands](../../kubernetes/mod.just), [validation](../../scripts/validate/n8n.sh),
and the [test catalog](../../tests/catalog.yaml). Revisit the design for measured backlog,
unsupported auth requirements, new runtime boundaries, or tighter recovery objectives.
