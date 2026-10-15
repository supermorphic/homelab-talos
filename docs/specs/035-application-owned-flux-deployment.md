# Application-owned Flux deployment

## Status and scope

Platform contract for issue 593. The namespace is `career-ops`.
This specification defines the initial boundary and its acceptance requirements;
it does not establish deployed capability or authorize merge, credential enrollment,
or live mutation. The restricted source connection, retained claims and two
non-rendering application workloads have passed deployed acceptance. Preparation,
coordinator, monitoring delivery and isolated recovery still require native
qualification; production rendering remains held.

Provide one application domain with restricted Flux deployment from its own
repository. Career Ops' offline CV renderer is the first consumer. Later Jobs
and services using the approved capabilities must require only application
repository changes. Independently deployed future domains receive their own
namespaces when needed, following the same onboarding pattern.

This design preserves the first consumer's asynchronous HTTP coordinator,
RenderCV runtime, separate render Jobs, and separate preparation and qualification
stages. Use application-owned records in the existing Career Ops PostgreSQL
database for the ledger. It does not implement
application behavior, a generic execution API, a deployment broker, or an image
registry. Existing Career Ops execution and upstream consumer activation retain
their separate authority.

The application specification owns coordinator behavior and ledger migrations.
The two specifications must agree on storage, monitoring and recovery interfaces
before deployment. SQLite, a coordinator control PVC and node pinning are excluded.
Upstream composition, inference and application submission have separate activation
boundaries. Metrics-export migration and privileged maintenance Jobs are separate
future work; neither broadens this initial enrollment.

## Ownership and domain boundaries

The platform owns namespaces, Flux source connections, reconciliation permissions,
admission, network policies, route allocations, storage capabilities, retained
data protections, resource ceilings, and privileged recovery. The application
owns workload manifests, compatible runtime identities, release/image selection,
preparation, qualification, request handling, retries, and artifact lifecycle.
Application issue 351 owns the ledger, coordinator reconciliation, worker-start
protocol, and artifact consistency. Platform issue 593 supplies restricted database
connectivity, credential delivery, retained storage, independent monitoring, and
the existing privileged node/storage recovery boundary.

Keep application source, inputs, outputs, and detailed release behavior outside
this public repository. Enroll credentials through guarded operator workflows
that write only SOPS-encrypted artifacts. Flux's source credential and the
preparation repository credential are separate, repository-scoped read identities.
Application API authentication uses separate dedicated material; the application
owns its authentication behavior and rotation procedure. Initial qualification
uses a separate caller principal with an owner-only local bearer file; the
coordinator receives only its hash through `cv-api-auth`. Enrolling the production
pipeline is a separate caller activation. Bootstrap enrollment preserves the
bearer on delivery retries and cannot replace existing ciphertext.

Use the existing Flux, Cilium, Gateway, Longhorn, and credential conventions in
[the platform specification](010-talos-flux-platform.md). Group platform onboarding
manifests under `kubernetes/apps/applications/career-ops/`. The `applications`
directory is an organizational grouping; each application domain has its own
namespace and authority.

A shared namespace for unrelated repositories would require additional controls
to separate their object names, claims, credentials, and capacity. Separate
namespaces make those allocations explicit. A namespace per individual render
would add lifecycle work without improving the application's trusted
request-directory mapping. Neither alternative is selected.

## Source and reconciliation

Use the Career Ops repository's protected `main` branch and an explicit
`./deploy/` Kustomize root. Initially that root includes `./cv/`; additional
approved workloads can be included without changing the platform's source path.
The application repository must provide and review this root before activation.
The exact repository binding and credential scope are checked during enrollment.

Use a dedicated Forgejo repository-specific token with `read:repository` for
Flux, separate from preparation's read identity. Forgejo's
[token scope contract](https://forgejo.org/docs/v15.0/user/authentication/token-scope/)
also permits public repository reads. Guarded enrollment verifies the binding
and effective access, writes only SOPS ciphertext using the public recipient,
and retains a non-secret receipt for recovery.

Initial Flux-source enrollment leaves reconciliation suspended. Separate
preparation-source enrollment preserves the existing bootstrap connection and
cannot replace either credential. Delivery retries reuse the pending token. Rotation retains the old
token until replacement access is verified. Neither credential creation nor
ciphertext merge authorizes activation.

Create a platform-owned GitRepository and application Kustomization in
`career-ops`. Use a dedicated namespace-local service account for Flux
impersonation. The application cannot change its source, revision policy,
Kustomization, impersonation account, or reconciliation permissions. Do not enable
application-controlled Secret decryption, source substitution from arbitrary
Secrets, remote bases, or additional sources through this connection. Enforce
remote-base denial with the shared kustomize-controller
[`--no-remote-bases=true` option](https://fluxcd.io/flux/components/kustomize/options/),
using the owning bootstrap Kustomize patch rather than editing generated controller
YAML. Audit and render existing overlays before this controller-wide change; do
not trade an application boundary for an unreviewed change to other workloads.

Reconcile platform restrictions before the application connection. Keep the
application Kustomization suspended until those restrictions, source credentials,
and reviewed bootstrap manifests are ready. Removing application workloads must
not remove the namespace, platform controls, or retained claims.

The initial reconciliation identity has explicit permissions for Deployments, Jobs,
ClusterIP Services, internal HTTPRoutes, ConfigMaps, retained PVC declarations,
and constrained ServiceAccounts and RoleBindings. It has no namespace, Secret,
Role, network-policy, quota, storage-class, Flux-resource, or admission-policy
administration. No wildcard permissions, impersonation grants, token minting,
exec, port-forward, or privilege-escalation authority are delegated.

RoleBindings may reference only exact platform-approved Roles and approved
namespace-local subjects. Account creation does not confer permissions by itself.
Any necessary RBAC `bind` permission is limited to those named Roles and paired
with admission checks on binding subjects. Application workloads cannot select
the Flux reconciliation identity as a runtime identity. Reserve platform-owned
object names and reject their update, deletion, ownership transfer or inclusion
in the application inventory, even where the reconciler has permissions for that
resource kind. This includes its ServiceAccount and all platform-owned ConfigMaps,
Services, accounts and bindings; broad kind-level RBAC alone is insufficient.

### Initial identities and enrollment

Use `career-ops-reconciler` for Flux impersonation. The platform owns that account
and its permissions. Initial runtime accounts are `cv-prepare`, `cv-coordinator`
and `cv-renderer`; qualification uses `cv-renderer`. Reserve `career-ops-service`
for a simple private service with no Kubernetes authority or credentials until
separately enrolled. Default accounts have no application capability. Admission
binds each permitted account to its capability and approved mounts/Secrets; merely
creating an account or copying a label does not grant access.

Use native `ValidatingAdmissionPolicy` and bindings, with failure policy `Fail`,
namespace-wide matching and deny enforcement. Reuse the repository's Kubernetes
CEL compiler/evaluator and synthetic admission tests. Platform-owned policy is
installed before the application source can reconcile. Include controller-created
Pods and relevant updates/subresources; no application-selected label may exempt
an object. This requires no additional admission controller.

Flux may manage permitted runtime accounts and only the fixed binding of
`cv-coordinator` to the platform-owned `cv-render-jobs` Role. That Role allows
Job create/get/list/watch/delete and Pod get/list/watch for reconciliation; no
Pod create/delete, logs, exec, arbitrary controller, or credential authority.
Admission restricts coordinator-created Jobs to the offline-worker capability.
Use application-owned cleanup of proven-safe Jobs; the Role's delete permission
is not proof that a worker has stopped. No other runtime RoleBinding is enrolled
initially. A future binding requires platform enrollment.

Use Cilium's service-account identity for capability-specific connections rather
than trusting an application-supplied network label. Services and workload labels
must also be checked so the approved route and monitoring selectors cannot be
redirected to an unenrolled capability. Non-initial controller kinds, NodePort,
LoadBalancer, ExternalName, arbitrary EndpointSlices and ingress resources are
not admitted through the application connection.

## Runtime capabilities and admission

Reuse capabilities across compatible workloads. Rendering-specific commands,
image digests, release versions, and request semantics remain application-owned.

| Capability | Access | Exclusions |
| --- | --- | --- |
| Preparation | Reviewed release source and approved dependency downloads; new candidate release storage | Private requests, database, Kubernetes token, accepted artifacts |
| Private service | Allocated Gateway traffic; approved storage/authentication and separately enrolled database access | Kubernetes API authority and download access by default |
| Job coordinator | Private-service access, restricted application database login, and management of admitted offline Jobs | Preparation Jobs, Secret/RBAC management, arbitrary workload creation |
| Offline worker | Published release and assigned request mounts; bounded temporary workspace | Network, Kubernetes token, credentials, database, accepted artifacts |

Qualification uses the offline-worker capability with synthetic inputs. The CV
coordinator uses the Job-coordinator capability. A later simple private service
does not need Job authority or the CV ledger. Create distinct identities where
effective permissions differ; do not impose a fixed identity count per workload.

These capabilities describe reusable permissions, not mandatory application
components. A later Career Ops UI, API, or background Job need not adopt the CV
ledger, worker-start protocol, or artifact layout. An explicitly enrolled database
login may also belong to a private service without giving it Job-management
authority. Database grants, credentials, and network access stay specific to that
workload. The initial database binding below is only for the CV coordinator.

Coordinator RBAC may read namespaced Job and Pod metadata needed for reconciliation;
standard RBAC cannot restrict list results by application-selected labels. This
does not grant logs, exec, Secrets, or volume contents. Admission restricts its
Job mutations to offline workers. The application must not place credential
values or private request payloads in readable workload metadata or arguments.

Validate both controller templates and resulting Pods, including controller-created
Pods. Check the effective identity, network profile, every container, security
context, token/Secret references, volume sources, mounts, resource bounds, and
update/subresource behavior. Profile selection cannot rely solely on mutable
application labels. Deny routes to greater authority through sidecars, init or
ephemeral containers, alternative controllers, or forged platform identity labels.

Require non-root operation, a read-only root filesystem, dropped capabilities,
no privilege escalation, and bounded CPU, memory, and ephemeral storage. Forbid
host namespaces, host mounts, privileged execution, and arbitrary storage drivers.
Require every workload to set automatic token mounting explicitly. Among
application runtime accounts, only the Job coordinator may enable it when its
runtime Role is needed; coordinator checks may disable it. Private services also
default to no token. Preparation and offline workers receive no token, including explicit
projected-token alternatives to automatic mounting.

## Networking and route allocation

Default-deny traffic and allow only the selected profile's connections. Allocate
`cv.lab.supermorphic.com` to the initial coordinator on the existing
`networking/internal` Gateway HTTPS listener. Admit only allocated hostnames,
namespace-local backends, approved ports, and supported route filters. Services
cannot create public exposure, arbitrary external endpoints, or cross-domain
backends.

Allow Gateway-to-coordinator traffic and the coordinator's necessary Kubernetes
API connectivity. Permit only the coordinator identity to reach the existing
automation-data PostgreSQL Service and port, with reciprocal Cilium policy and
necessary DNS access. Preparation and workers receive no database connectivity or
credential. Preparation gets DNS and HTTPS access only to reviewed release
and dependency destinations. The application supplies the exact lockfile/font/
package download destinations before the platform approves this allowlist; no
general Internet access is an initial default. Validate redirect and shared-host
behavior before claiming that an egress rule restricts destinations as intended.

Offline workers have no network access, including DNS. Platform storage mounts
must remain functional without permitting application network traffic. Prove this
with Longhorn RWX mounts in the actual cluster. Existing Longhorn node-loss
actions may remove Pods or restart storage services; they do not establish that
an unreachable renderer has stopped and must never release an application slot. Image pulls performed by nodes
do not justify renderer egress permissions.

Additional internal Jobs and Services can use existing capabilities. New external
hostnames, dependencies, credentials, or cross-domain access require platform
allocation. This issue does not enable n8n consumption or any upstream workflow.

## First consumer handoff

The initial application is the CV service delivered by Career Ops issue 351.
The platform supplies an application space through `./deploy/`, not a renderer
implementation. Candidate-facing UI and later Career Ops services can use that
space within the allocated capabilities. The initial hostname is a CV endpoint,
not an allocation of all future routes or authorization of upstream automation.

Before application deployment, 593 supplies the exact namespace, source/revision
binding, private route, permitted workload identities and resources, database
Service/port and credential reference, approved claims/mounts, numeric ceilings,
and monitoring interface. These are explicit handoff values, not values for 351
to discover through administrator credentials.

The initial allocation is:

| Platform-owned allocation | Initial value |
| --- | --- |
| Namespace / source objects | `career-ops`; GitRepository `career-ops`, Kustomization `career-ops-apps` in that namespace |
| Application source | Reviewed Career Ops `main`, `./deploy/`; initial child `./cv/` |
| Private route | `cv.lab.supermorphic.com`, Gateway `networking/internal`, listener `https` |
| Coordinator endpoint | Service `cv-coordinator`, HTTP port 8080; `/readyz` includes database readiness |
| Monitoring endpoint | Service `cv-coordinator`, named port `metrics` on 9090, `/metrics`; no CV contents |
| Database endpoint | `automation-data-postgresql.automation-data.svc.cluster.local:5432`, database `career_ops` |
| Registered database application | `cv_render`, schema `cv_render`; application-owned grants and functions |
| Runtime credentials | Secret `cv-render-database` for the coordinator login; `cv-api-auth` for application authentication |
| Source credentials | `career-ops-source` for Flux; separate `cv-prepare-source` for preparation |
| Retained claims | `cv-releases` 8 GiB, `cv-requests` 16 GiB, `cv-artifacts` 32 GiB; all RWX |
| Storage class | Platform-owned `career-ops-retain`, Longhorn CSI, `Retain`, two replicas, existing backup policy |

These are contract names, not evidence that Secrets, roles, claims or DNS records
exist. Credential key/file formats are owned by the existing enrollment workflow
and application adapter; record the validated references without values before
unsuspending. Only `cv-coordinator` receives database/API credentials; only
`cv-prepare` receives its source credential. No runtime mounts the Flux credential.
If the application requires a different allocation, resolve it in the reviewed
handoff before deployment rather than silently choosing a broader identity.

The database application registration precedes application-owned schema/grant
installation. Platform activation follows effective-grant validation. Neither
Flux nor the coordinator receives a migrator credential; existing guarded
application migration procedures perform installation. Missing repository access,
source artifacts, fonts or approved download destinations leave preparation and
rendering suspended; they do not justify broader egress. A reviewed tokenless,
non-rendering bootstrap may reconcile independently when it uses no database,
private inputs or prepared release.

The application-facing contract below belongs to 351. Its versioned
API schema must freeze exact paths, fields, limits, and errors before integration.
This table summarizes the cross-issue handoff; its canonical application behavior
and API schema belong in the application specification.

| Consumer operation | Required application behavior |
| --- | --- |
| Submit | Authenticate the caller; accept versioned CV JSON, a caller-scoped idempotency key, and supported render options. Freeze the qualified release and all rendering inputs. Return HTTP 202 with request identity and status location only after durable acceptance. |
| Repeat submission | Same key and same inputs return the existing request/status/receipt. Changed inputs with the same key return a conflict; neither case starts duplicate work. |
| Observe | Return queued, running, retrying, completed, failed, or recovery-pending status with bounded reason and retryability. Artifact availability is separate from historical completion. |
| Retrieve | Authorize access to that request and return its validated PDF, preview, and receipt/manifest with checksums. Never expose another caller's artifacts or a partial candidate. |
| Reject or defer | Reject invalid/oversized input before acceptance. Bound backlog and request size. Queue accepted work when physical slots are occupied; reject new admission explicitly when backlog is full or durable storage is unavailable. |

The caller supplies no Kubernetes objects, volume paths, database credentials, or
worker identity. Rendering workers run on demand, from zero to at most ten active
renders including qualification and uncertain workers. Submission acceptance does
not mean rendering completed, operator approval was granted, or a job application
was submitted. Composition quality and submission remain separate application work.

First-release acceptance must exercise this contract from a caller identity:
submit synthetic JSON, poll to completion, download and verify artifacts, repeat
the request without new work, reject a conflicting request, and observe structured
failure/recovery status. Platform connectivity checks alone do not establish it.

Keep the delivery limited to this consumer and the reusable permissions it needs.
No generic queue service, recovery controller, automatic database failover, warm
worker pool, or new platform-wide framework is required. Rare unsafe recovery uses
the existing attended boundary; its handling must not complicate ordinary calls.

## Persistence and ownership

Use the existing Career Ops PostgreSQL database, not a new database service or a
second job system. Application-owned migrations add rendering requests, attempts,
physical worker reservations, publication receipts, and deletion records using
its existing durable-action and guarded-function pattern. Rendering remains
independent of deep-analysis activation and paid-inference permissions.

The relevant existing application contracts are
[pre-analysis recovery](https://forgejo.infra.supermorphic.com/supermorphic/career-ops/src/branch/main/docs/specs/007-pre-analysis-execution-and-recovery.md)
and [deep-analysis ownership and completion](https://forgejo.infra.supermorphic.com/supermorphic/career-ops/src/branch/main/docs/specs/018-deep-analysis-progression.md).
Reuse transactional ownership checks, distinct attempts, receipts, and periodic
reconciliation. Do not import inference-specific prohibitions on repeating paid
calls into offline rendering, or build a general recovery framework.

Enroll a dedicated coordinator login through the existing
[application-login boundary](026-automation-data-postgresql-platform.md#registration-and-authority).
The application grants only required reads and reviewed rendering functions;
the platform validates effective privileges and delivers the dedicated credential
through its existing protected enrollment and SOPS workflow. Do not reuse an n8n,
owner, migrator, or provisioner credential. Preparation and workers never receive
this login. Its workload Secret delivery and network binding are onboarding work;
the existing workstation connection helper is not a deployed workload connection.
The application retains ownership of guarded migration installation and grants.

Keep the exact validated JSON input and immutable rendering identity in the
application database; materialize worker input on retained request storage.
Include the selected release, design, fonts, and as-of inputs in request identity.
An idempotency key is scoped to the authenticated caller: reuse with different
inputs is a conflict, not another render. Matching requests return existing status
or the original accepted receipt. Database operations use short transactions and
recheck ownership after lock waits; no transaction spans rendering or file copying.

The coordinator has no local authoritative ledger or RWO control claim. It can
restart on another eligible node without a SQLite-specific placement or relocation
procedure. A single desired coordinator replica is sufficient initially, but
correctness must survive overlap during restart and stale processes. PostgreSQL
ownership checks, immutable storage writes, and physical worker reservations supply
that protection, not replica count.

This removes an additional stateful writer; it does not add database high
availability. The existing [PostgreSQL runtime](026-automation-data-postgresql-platform.md#postgresql-runtime)
is one StatefulSet replica, with an existing 24-hour off-cluster recovery-point
objective and no fixed restore-time objective. During its outage, no coordinator
may admit requests, authorize new workers, or commit publication. Already
authorized workers may start or finish isolated output within their held physical
reservations. Reconciliation resumes when the same authoritative
database returns. Database/storage disaster recovery retains the platform's
attended procedure; no automatic database failover is assumed.

## Storage, retention, and trust

Provide retaining Longhorn storage using established replication and backups.
The non-default `career-ops-retain` class uses the existing driver and two-replica
placement, with expansion enabled and the existing daily snapshot/backup group.
Do not alter the default class or replica/failover settings for other workloads.
The three initial claims total 56 GiB within the 64 GiB namespace allocation;
additional claim names and mounts require enrollment even when quota remains.

The mount contract is:

| Purpose | Access mode and mounts | Writer |
| --- | --- | --- |
| Candidate/published releases | RWX; published releases read-only to offline workers | Preparation writes a new candidate; coordinator promotes a qualified candidate |
| Materialized requests, start permissions, and attempt staging | RWX; assigned input/start permissions read-only; Pod-specific staging writable | Coordinator creates input/permissions; each authorized worker writes its own staging |
| Immutable artifact bundles and deletion markers | RWX; inaccessible to preparation and workers | Coordinator writes new immutable objects; guarded application cleanup |
| Authoritative ledger, accepted receipts, and deletion records | Existing Career Ops PostgreSQL; no new application PVC | Dedicated coordinator login through application functions |

RWX artifact storage avoids reintroducing coordinator placement through an RWO
artifact claim. It still depends on Longhorn's shared-volume availability; RWX is
neither a transactional store nor a promise of uninterrupted access. Qualify
exclusive creation, completed-file visibility, and durable writes on actual mounts.

Claims must use permitted names, sizes, access modes, and classes. Forbid routine
PVC deletion, workload owner references, removal of Flux prune protection,
arbitrary PV prebinding, and unapproved restore/clone sources. Retained claims and
a retaining reclaim policy protect different lifecycle stages; both are required.
Physical claim reclamation remains a deliberate privileged operation.

Preparation writes only candidate release directories. Qualification workers may
read a candidate release with the same read-only restrictions as published
releases. The coordinator may write the release volume to promote a qualified
candidate into the published layout; it receives no preparation source credential
or preparation-Job authority. The application must seal and qualify a candidate
before promotion and preserve published release immutability. This publication
step does not broaden worker write access.

The application controls publication, release immutability, and directory mapping.
The platform enforces allowed claims, mount structure, credentials, and read-only
requirements. It does not infer request ownership from paths. The trusted
coordinator maps authenticated requests and Pod identities to directories.
Application path-isolation tests remain separate from platform admission tests.

## Ordinary recovery and physical worker safety

The coordinator reconciles durable work on startup and every minute, using the
same claim/recheck pattern as existing Career Ops recovery. An initial render may
receive up to two automatic replacement attempts for classified transient failures,
with finite backoff and per-attempt/request deadlines. Qualification establishes
those time limits in application configuration. Malformed input, unsupported
content, and deterministic validation failure are terminal. Repeated client calls,
coordinator restarts, and lost acknowledgments do not reset retry counters or clocks.

Persist attempt identity and intended Job name before creating the Job. An
ambiguous create response is reconciled against that same identity; never create
a new attempt simply because an acknowledgment was lost. A replacement coordinator
first observes existing Jobs and output. It can resume tracking a running worker,
validate completed output, or return a committed receipt without rerendering.
Expired coordinator ownership rejects stale publication; it does not mean the
physical worker has ended. Retry only after the previous worker is proven stopped.

Preserve the ceiling of ten physically active renders across ordinary and
qualification work. Include possibly running workers in that count. A database
claim, Kubernetes Job parallelism, and Pod quota are not sufficient alone:
[Kubernetes explicitly permits duplicate Job starts](https://kubernetes.io/docs/concepts/workloads/controllers/job/).
Use one-shot worker execution with controller retries disabled, but also require
an application-owned start gate before launching RenderCV:

1. Each worker obtains its own Pod UID through the downward API and waits for a
   matching start permission in its assigned read-only input directory. It has
   no network access or Kubernetes/database credential.
2. The coordinator transactionally records an authorization bound to that Pod UID,
   attempt, Job identity, and one of the ten physical reservations before writing
   the immutable permission. Only one Pod may be authorized for an attempt.
3. A duplicate Pod has no matching permission and cannot render. Its wait is
   bounded. Output directories are Pod-specific, so duplicate or stale Pods
   cannot modify another worker's candidate. Before launching RenderCV, the worker
   must exclusively create and durably flush a one-time consumption marker on
   retained Pod-specific storage. An existing marker or ambiguous write prevents
   launch. Pod UID alone is insufficient:
   [Kubernetes can rerun containers after runtime state loss](https://v1-35.docs.kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#individual-container-restart-policy-and-rules).
   Keep consumption markers beyond ordinary
   staging cleanup; another invocation cannot reuse the permission after the
   original process exits and its slot is released.
4. Keep the reservation while an authorized Pod might run, even if its ownership
   lease expires, its permission write is ambiguous, or its API object disappears.
   A delayed permission write from an old coordinator remains covered by that
   reservation. Release requires positive termination evidence for that Pod or
   verified node/process fencing; absence or a controller-generated failure alone
   is insufficient.

This is a small renderer startup protocol owned by 351, not a new controller or
platform recovery service. The concrete Job settings, termination evidence, and
mount behavior require native acceptance, including atomic exclusive creation
and durability of consumption markers. Do not claim the ten-render guarantee
until duplicate Pods, same-Pod container reruns, delayed permissions, and uncertain
node loss are covered.
There is no proposed relaxation to ten logical requests or ten visible Pods.

Healthy-node exits and coordinator crashes recover without attendance. An
unreachable worker keeps its slot and blocks replacement of that attempt. Other
requests may use remaining slots. A returning node that supplies adequate exit
or restart evidence permits automatic reconciliation. If evidence remains
unavailable, alert and use existing
[node/storage recovery](025-node-lifecycle-and-maintenance.md); do not force
release on a timeout or treat cordon, API deletion, or lease expiry as fencing.

## Artifact publication and restore

There is no atomic transaction between PostgreSQL and retained PDF storage, and
no atomic backup across them. Application issue 351 owns this protocol:

1. After proven worker completion, validate the candidate and copy the complete
   PDF/preview/manifest bundle into a unique immutable artifact location. Compute
   checksums and byte lengths from the copied bytes, complete durable writes, and
   verify them before database acceptance. Never overwrite a shared current path.
2. Commit the accepted receipt and request completion together in PostgreSQL,
   checking current ownership and request identity again. The immutable receipt
   binds request identity, producing attempt, release, artifact location, and
   checksums. A bundle manifest carries matching identity, but only the committed
   database receipt confers acceptance. Download access resolves that receipt.
3. A lost response returns the same committed receipt. A crash before acceptance
   leaves a candidate that reconciliation can verify and accept under current
   ownership without repeating rendering. A stale coordinator may leave an
   unreferenced immutable candidate; it cannot change accepted state or overwrite
   accepted bytes. Before cleanup, transactionally retire the exact artifact
   generation so it cannot subsequently be accepted; never reuse a retired path.
   Cleanup also requires physical writer safety. A stale cleanup operation cannot
   delete a replacement generation.

Deletion is an application state transition. Record its tombstone in PostgreSQL
and a durable marker on retained artifact storage before acknowledging deletion;
then remove bytes through bounded cleanup. Reconciliation completes interrupted
deletions. Never erase a deletion record merely because its artifact is missing.

Expose database-bundle and volume-backup identities, completion, and recovery
points through existing backup observation. During restore, keep admission and
artifact serving closed. Stop or fence pre-restore coordinators and all potentially
authorized workers before trusting restored claims or freeing physical slots:
rollback can lose reservations that once authorized live work. Restoring a ledger
is not ordinary coordinator restart. Retire pre-restore authorized Pod identities
and their owning Jobs as well as stopping their processes; old desired workloads
must not restart against restored or removed consumption markers. Keep markers
until those identities cannot execute again. A missing API object alone remains
insufficient evidence. Apply this boundary to request-volume rollback too.

Reconcile the restored database against actual bytes and retained deletion markers:

| Restored evidence | Required behavior |
| --- | --- |
| Accepted receipt with matching bundle | Make available only after checksum, identity, and deletion checks |
| Accepted receipt with missing/corrupt bytes | Mark unavailable; restore matching bytes or rerender exact retained input with the qualified release after worker-safety checks |
| Regenerated bytes equal the original receipt | Record a verified repair location and provenance separately; retain the immutable receipt and original location history |
| Regenerated bytes differ | Preserve the old receipt as unavailable; validate and accept a distinct replacement receipt through the normal application contract |
| Bundle absent from the restored ledger | Quarantine; file presence cannot reconstruct acceptance or authorize replay |
| Deletion in either retained source | Suppress serving and replay; reconcile deletion before cleanup |
| Missing inputs/releases, uncertain identity/deletion history, or unresolved old worker | Keep affected work unavailable and require operator resolution |

Resume only after the application reports the reconciled availability and loss
boundary. Neither checksums nor receipts recover unbacked-up transactions. Newer
acceptances or deletions can be absent from both backups; the attended restore
must resolve that uncertainty before re-exposing affected artifacts. Do not
promise zero data loss, exactly-once behavior across database rollback, or recovery
beyond independently verified database and artifact backups. Routine missing-file
repair with an intact current ledger may run unattended; uncertain historical
restore requires review.

Automatic artifact repair is one durable operation per accepted artifact
generation, with a separate finite deadline and at most two replacement render
attempts after its first attempt. It may run after the original request deadline
without resetting that request's accounting. Repeated checks and restarts join
the same repair operation; exhaustion requires review, not a fresh automatic
budget. Repair rendering uses the same ten physical reservations and termination
rules. A distinct replacement receipt preserves its link to the original receipt;
status must disclose replacement rather than silently substitute different bytes.

## Failure visibility and operator attention

The application exposes durable progress, automatic retry, terminal failure,
artifact unavailability, and unsafe recovery as distinct states with bounded
reasons and supported next actions. A failed request is not a successful render;
waiting for an absent worker is not ordinary queue progress.

Use existing [alert delivery](015-alerting-architecture.md#delivery-boundary)
through Prometheus, Alertmanager, and ntfy. Platform-owned rules and observation
access are enrolled with the initial workload; the application Flux identity does
not gain monitoring-namespace authority. Application-owned status and bounded
aggregate signals describe queue age, last reconciliation progress, exhausted
retries, and unresolved worker/artifact recovery. They contain no document data
or per-request metric labels.

Keep the ServiceMonitor and PrometheusRules platform-owned in the application
platform manifests; no monitoring resource permission is delegated to application
Flux. Select only the enrolled coordinator Service, scrape every minute with a
10-second timeout, and permit Prometheus-to-metrics traffic explicitly. Dashboard
and alert expressions use stable service identity, never a request ID. Enable the expected-service alert contract explicitly when coordinator
qualification starts; an intentionally suspended bootstrap is not an outage.
Once enabled, a declared but absent target or missing required series must alert
as well as `up == 0`; missing workload or Service objects must not disable the rule.

The app/platform metrics handoff contains database readiness, the timestamp of
the last successful reconciliation, overdue request count, exhausted retry count,
unrepairable artifact count and unsafe-recovery count. The application owns the
exact names and meanings in its versioned metric schema; bind the rules and
fixtures to that reviewed schema before activation. No new metrics exporter is
needed for the coordinator. Lack of the schema blocks monitoring enrollment,
not offline platform policy implementation.

Independently monitor coordinator availability and missing/stale telemetry, and
probe its ability to reach authoritative state. Existing database and storage
alerts remain responsible for their infrastructure. A fresh successful
reconciliation with no queued work is healthy idle time, not a stall. Pending
work beyond its progress deadline, missed reconciliation, exhausted recovery,
and unsafe workers require explicit signals; a running Pod alone proves none of
these conditions. Monitoring must still alert if the coordinator cannot execute.

Use these initial detection objectives, and verify them during acceptance:

| Condition | Detection and delivery |
| --- | --- |
| Coordinator unavailable, database readiness failed, or required telemetry missing | Critical after five minutes |
| No successful reconciliation, including an otherwise healthy idle service | Critical after five minutes without a fresh successful pass |
| Pending work exceeds its qualified progress deadline | Warning after two further reconciliation intervals; retain original timestamps across restarts |
| Automatic retries exhausted or an accepted artifact cannot be repaired | Warning after one reconciliation interval |
| Uncertain worker safety or unresolved restore consistency | Critical after one reconciliation interval; identify held slots and affected requests privately |

Notification text identifies the service, condition, processing impact, and
private status/recovery link. Group repeated signals through the existing Alertmanager policy
and send resolution on verified recovery. Missing state telemetry leaves the related
condition unresolved or unknown until healthy telemetry returns; its existing
alert hold interval still applies. Application deadlines must distinguish
ordinary queueing, active rendering, backoff, and infrastructure outage before
activation. Do not send raw errors, CV contents, or credentials. The n8n
[workflow failure handler](023-n8n-workflow-automation-platform.md#shared-workflow-failure-notifications)
may supplement this path when explicitly bound; it neither detects silent stalls
nor performs recovery.

## Initial capacity

These are initial ceilings for synthetic qualification, not a throughput or
ten-way scheduling guarantee. Executable manifests will own the
exact values once implemented.

| Namespace allocation | Initial ceiling |
| --- | --- |
| Aggregate CPU requests / limits | 6 / 16 cores |
| Aggregate memory requests / limits | 12 / 24 GiB |
| Aggregate ephemeral-storage requests / limits | 16 / 32 GiB |
| Nonterminal Pods / Jobs | 16 / 64 objects |
| Deployments / Services / HTTPRoutes | 4 / 8 / 4 objects |
| ConfigMaps / application ServiceAccounts / RoleBindings | 64 / 16 / 16 objects |
| PVC count / requested storage | 10 claims / 64 GiB |

Start renderer qualification with one worker limited to one CPU and 1 GiB memory,
with at most 1 GiB temporary workspace inside a 2 GiB ephemeral-storage limit.
Reserve room for preparation up to two CPUs/4 GiB and the coordinator up to one
CPU/2 GiB. Ten workers at those limits fit within the namespace ceilings;
actual dependencies and workloads may require a reviewed adjustment.

The application reserves at most ten active renders across ordinary and
qualification work. It may choose a lower concurrency. Kubernetes quotas do not
implement that admission invariant, prevent duplicate attempts, guarantee spare
node capacity, or establish performance after a node failure. Measure impact on
existing workloads before activating concurrency. Retained objects consume their
object/storage budgets until the supported lifecycle removes them.

## Delivery and acceptance

Implement and validate the platform boundary before enabling application
reconciliation. Use the existing scoped credential and result workflows from
[scoped test execution](032-openbao-scoped-test-execution.md). Define the minimum
test authority required for this boundary; do not use administrator credentials
or unrelated test profiles as a fallback.

The registered `validation.application-boundary` runs offline controls and alert
fixtures. `verification.application-boundary` observes installed controls and
source/retained-volume metadata without reading Secrets or volume contents.
`test.application-boundary-admission` submits only a fixed server-side dry-run Job;
its result is admission evidence, not the complete native acceptance below. The
`test.application-boundary-storage-network` uses fixed tokenless test identities
and a platform-owned program. It shares the production execution/mount profiles
and coordinator egress destinations, but cannot mount application claims or
Secrets. Its three separately enrolled 1 GiB RWX claims remain platform-owned
and retained across Job removal. Flux reconciles the fixture claims in a separate
unit that depends on the platform controls. This installs admission policy changes
before Flux dry-runs claims that need those changes. A fresh reader on another
node verifies stored data after the writer is removed. Fixed single-target Jobs on each worker node
provide Hubble `POLICY_DENIED` counters attributed to the run and target phase.
Each process attempts only its declared API, database, TCP DNS, or UDP DNS target;
destination workload labels are not required because service-IP drops can omit
them. The matching protocol and positive connectivity before and after worker
checks distinguish denial from an unavailable
destination. The existing private Prometheus read path supplies the drop evidence;
missing telemetry never counts as a denial. These fixtures establish TCP database/API connectivity, not database
grants or authenticated application behavior.

The test creates only its twelve named Jobs and records their API ownership before
cleanup. Its fixed program removes only synthetic directories whose run markers
match. It never deletes PVCs or PVs. A failed ownership or cleanup check preserves
the local ledger and requires scoped follow-up; no broader credential fallback is
allowed. Removing the fixture claims themselves requires a separately reviewed, attended
reclamation action. They consume 3 GiB of the namespace storage
budget while enrolled.

The full boundary suite remains unenrolled until application-source workloads,
ingress, notification delivery and isolated restore acceptance are ready. Neither
partial suite establishes application pruning or completion of issue 593.

Offline validation must compile and evaluate the actual admission policies, render
the manifests, and exercise independent positive/negative cases. Include forbidden
profile transitions, coordinator-created preparation Jobs, alternate mounts and
token projections, unsupported controllers, sidecars, route escape, claim deletion,
and changes to platform controls. Mechanical documentation checks are sufficient
for prose; do not add tests that require specific documentation wording.

Live acceptance must demonstrate:

- Harmless workload reconciliation from the approved application source with
  namespace-scoped Flux authority and denied changes outside that authority.
- Required private-service/API/database/preparation connectivity and offline-worker denial,
  including working storage mounts with renderer networking disabled.
- Multi-node RWX use, read-only releases and start permissions, exclusive immutable
  bundle publication, retained data after ordinary removal/pruning, and isolated
  restore from identified database and volume backups.
- Dedicated database identity, permitted application functions, denied broader
  authority, credential rotation, and no worker/preparation database access.
- A usable termination/fencing evidence path, recovery-pending behavior when proof
  is missing, and attended recovery where required. Joint application acceptance
  must prove restart/lost-acknowledgment recovery, bounded retry, stale-owner
  rejection, duplicate-Pod and same-Pod rerun denial, and ten physical reservations including
  uncertain workers across ordinary and qualification work.
- Application-led receipt/checksum reconciliation for database-newer and
  artifact-newer backups, missing/corrupt bundles, retained deletions, uncertain
  history, and database rollback with pre-existing workers. Platform restore
  success alone does not satisfy these application checks.
- Delivered notifications for recovery pending, exhausted retries, overdue work,
  and coordinator unavailability, including a coordinator that cannot emit its
  own failure signal. Verify resolution after recovery and harmless duplicate
  request delivery without duplicate accepted results with the application owner.
- A second non-rendering workload added solely in the application repository using
  the same deployed platform capability boundary.

Record scoped acceptance against the exact platform/application revisions and
actual deployed state. Keep feature-branch candidate evidence distinct from clean
deployed-main evidence. Platform acceptance does not establish rendering quality,
API authentication, ten-way application admission, or accepted-artifact recovery.

### Enrollment and activation sequence

1. Implement and validate namespace restrictions, named identities, admission,
   retained storage capability and reciprocal network rules. Keep the application
   source connection suspended. Prepare platform-controlled encrypted Secret
   artifacts through the approved enrollment procedure for deployment through Git;
   no private age key enters agent work.
2. Review the application's bootstrap root, immutable image/release inputs,
   dependency/font destinations, API authentication configuration and metric schema.
   Record the exact non-secret bindings. Register `cv_render`, have the application
   install its schema/grants through its guarded path, then validate and activate
   the login before database-dependent workloads. The harmless bootstrap requires
   only its reviewed source, source credential and installed platform restrictions;
   other missing prerequisites keep their dependent workloads suspended.
3. After exact-candidate hosted validation and explicit merge authorization,
   deploy platform main through Flux. Register and run the approved scoped
   synthetic acceptance. Suspend reconciliation on a failed boundary check;
   preserve resources/evidence needed for diagnosis without exposing private data.
4. Unsuspend the application connection only through a reviewed platform change
   once its source and restrictions are ready. A harmless app-owned workload proves
   the connection before private inputs or renderer activation. Prove an additional
   non-rendering workload can use an existing capability with only app-repo changes.
5. Hand off exact deployed revisions, source readiness, validated grants, retained
   claims/backup identities, monitoring bindings, denial evidence and remaining
   consumer prerequisites. Application 351 then qualifies preparation, rendering,
   caller behavior, concurrency, retries and artifact consistency on-cluster.
   Joint notification/recovery acceptance precedes declaring the service ready.

Platform acceptance with synthetic data may precede the finished coordinator.
Use a bounded fixture for metric signals and database connectivity; it must not
claim that real rendering or application recovery has passed. No permanent demo
service, general recovery framework or upstream workflow activation is required.

### Rollback and recovery operations

A bad application release first stops new admission. Suspend the platform-owned
application Kustomization through Git to stop further desired-state changes;
suspension does not stop already-running processes. Revert the application to a
reviewed compatible release and reconcile only after admission/ownership conditions
are safe. Do not delete retained claims, reset ledger history or run a down migration
to roll back application code. Observe or fence uncertain old workers before
replacement work, using the physical-safety contract above.

For a platform-policy failure, keep the application connection suspended and
restore the last reviewed restrictive policy through Git. Do not temporarily
remove admission/network controls to make a workload start. Credential rotation
uses the owning provisioner and protected enrollment, followed by identity and
denial checks; it does not recover credentials from application Pods or n8n.
The existing application-login provisioner replaces the password on the same
PostgreSQL role; it does not provide simultaneous acceptance of old and new
passwords for new connections. Keep qualification held during that transition.
Retain the protected candidate on ambiguous failures and retry the same operation.
Stage replacement database ciphertext from the freshly validated ready profile
with `just repo career-ops-runtime-secret`, requiring the reviewed existing
ciphertext checksum and expected new generation. Merge that credential change
separately, then verify projection reload, new authentication, stable role/epoch
and rejection of the previous password. Staging alone does not rotate a password
or prove workload delivery. A future active consumer must plan for the reconnect
gap through reviewed drain/readiness behavior; this qualification does not claim
uninterrupted database access or revoke already-authenticated sessions.

For a database or volume restore, the prerequisite is verified backups and the
existing attended platform restore authority. Stop/fence pre-restore writers and
workers, restore into isolated targets, then perform the application's receipt,
checksum and deletion reconciliation before reopening admission or artifact access.
Use [database recovery](026-automation-data-postgresql-platform.md) and
[node/storage recovery](025-node-lifecycle-and-maintenance.md) independently of the
coordinator. Record the selected backup identities, retained loss boundary and
application validation result. Infrastructure restore alone cannot mark artifacts
available or release a physical reservation.
