# Application-owned Flux deployment

## Status and scope

Proposed design for platform issue 593. The selected namespace is `career-ops`.
The remaining allocations and recovery tradeoffs are proposed for review. No
application resources have been deployed or accepted by this work.

Provide one application domain with restricted Flux deployment from its own
repository. Career Ops' offline CV renderer is the first consumer. Later Jobs
and services using the approved capabilities must require only application
repository changes. Independently deployed future domains receive their own
namespaces when needed, following the same onboarding pattern.

This design preserves the first consumer's asynchronous HTTP coordinator,
embedded SQLite request ledger, separate render Jobs, and separate preparation
and qualification stages. It does not implement application behavior, a generic
execution API, a deployment broker, or an image registry. Existing Career Ops
execution and upstream consumer activation retain their separate authority.

The application and platform specifications must agree on the coordinator,
storage, and recovery interfaces before deployment.

## Ownership and domain boundaries

The platform owns namespaces, Flux source connections, reconciliation permissions,
admission, network policies, route allocations, storage capabilities, retained
data protections, resource ceilings, and privileged recovery. The application
owns workload manifests, compatible runtime identities, release/image selection,
preparation, qualification, request handling, retries, and artifact lifecycle.

Keep application source, inputs, outputs, and detailed release behavior outside
this public repository. Enroll credentials through guarded operator workflows
that write only SOPS-encrypted artifacts. Flux's source credential and the
preparation repository credential are separate, repository-scoped read identities.
Application API authentication uses separate dedicated material; the application
owns its authentication behavior and rotation procedure.

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

Propose the Career Ops repository's protected `main` branch and an explicit
`./deploy/` Kustomize root. Initially that root includes `./cv/`; additional
approved workloads can be included without changing the platform's source path.
The application repository must provide and review this root before activation.
The exact repository binding and credential scope are checked during enrollment.

Create a platform-owned GitRepository and application Kustomization in
`career-ops`. Use a dedicated namespace-local service account for Flux
impersonation. The application cannot change its source, revision policy,
Kustomization, impersonation account, or reconciliation permissions. Do not enable
application-controlled Secret decryption, source substitution from arbitrary
Secrets, remote bases, or additional sources through this connection.

Reconcile platform restrictions before the application connection. Keep the
application Kustomization suspended until those restrictions, source credentials,
and reviewed bootstrap manifests are ready. Removing application workloads must
not remove the namespace, platform controls, or retained claims.

The reconciliation identity has explicit permissions for approved workload kinds,
ClusterIP Services, internal HTTPRoutes, ConfigMaps, retained PVC declarations,
and constrained ServiceAccounts and RoleBindings. It has no namespace, Secret,
Role, network-policy, quota, storage-class, Flux-resource, or admission-policy
administration. No wildcard permissions, impersonation grants, token minting,
exec, port-forward, or privilege-escalation authority are delegated.

RoleBindings may reference only exact platform-approved Roles and approved
namespace-local subjects. Account creation does not confer permissions by itself.
Any necessary RBAC `bind` permission is limited to those named Roles and paired
with admission checks on binding subjects. Application workloads cannot select
the Flux reconciliation identity as a runtime identity.

## Runtime capabilities and admission

Reuse capabilities across compatible workloads. Rendering-specific commands,
image digests, release versions, and request semantics remain application-owned.

| Capability | Access | Exclusions |
| --- | --- | --- |
| Preparation | Reviewed release source and approved dependency downloads; new candidate release storage | Request/control stores, Kubernetes token, accepted artifacts |
| Private service | Allocated Gateway traffic; explicitly approved application storage and authentication material | Kubernetes API authority and download access by default |
| Job coordinator | Private-service access plus management of admitted offline Jobs | Preparation Jobs, Secret/RBAC management, arbitrary workload creation |
| Offline worker | Published release and assigned request mounts; bounded temporary workspace | Network, Kubernetes token, credentials, control store |

Qualification uses the offline-worker capability with synthetic inputs. The CV
coordinator uses the Job-coordinator capability. A later simple private service
does not need Job authority or the CV ledger. Create distinct identities where
effective permissions differ; do not impose a fixed identity count per workload.

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
Only the Job coordinator receives the Kubernetes token needed for its runtime
Role. Preparation and offline workers receive no token, including explicit
projected-token alternatives to automatic mounting.

## Networking and route allocation

Default-deny traffic and allow only the selected profile's connections. Propose
`cv.lab.supermorphic.com` for the initial coordinator, attached to the existing
`networking/internal` Gateway HTTPS listener. Admit only allocated hostnames,
namespace-local backends, approved ports, and supported route filters. Services
cannot create public exposure, arbitrary external endpoints, or cross-domain
backends.

Allow Gateway-to-coordinator traffic and the coordinator's necessary Kubernetes
API connectivity. Preparation gets DNS and HTTPS access only to reviewed release
and dependency destinations. The application supplies the exact lockfile/font/
package download destinations before the platform approves this allowlist; no
general Internet access is an initial default. Validate redirect and shared-host
behavior before claiming that an egress rule restricts destinations as intended.

Offline workers have no network access, including DNS. Platform storage mounts
must remain functional without permitting application network traffic. Prove this
with Longhorn RWX mounts in the actual cluster. Image pulls performed by nodes
do not justify renderer egress permissions.

Additional internal Jobs and Services can use existing capabilities. New external
hostnames, dependencies, credentials, or cross-domain access require platform
allocation. This issue does not enable n8n consumption or any upstream workflow.

## Storage, retention, and trust

Provide a retaining Longhorn storage capability using established replication and
backup infrastructure. The CV consumer uses these separate purposes:

| Purpose | Access mode and mounts | Writer |
| --- | --- | --- |
| Candidate/published releases | RWX; published releases read-only to offline workers | Preparation writes a new candidate |
| Requests and attempt staging | RWX; assigned input read-only, assigned staging writable | Coordinator and assigned worker within their application contract |
| SQLite ledger, accepted artifacts, receipts, deletion records | RWO; inaccessible to preparation and workers | Single coordinator with Recreate deployment |

Other workloads may use the approved storage capabilities without adopting the CV
ledger layout. Claims must use permitted names, sizes, access modes, and classes.
Forbid routine PVC deletion, workload owner references, removal of Flux prune
protection, arbitrary PV prebinding, and unapproved restore/clone sources. Retained
claims and a retaining reclaim policy protect different stages of the lifecycle;
both are required. Release reclamation remains a deliberate privileged operation
when physical claim deletion is necessary.

The application controls publication, release immutability, and candidate writer
ownership. The platform enforces allowed claims, mount structure, credentials,
and read-only requirements. It does not infer request ownership from a directory
path. The trusted coordinator maps authenticated requests to immutable inputs and
attempt directories. Application path-isolation tests are separate from platform
admission tests.

Expose per-volume backup identity, successful completion, and recovery point
through the existing observation and recovery interfaces. Reuse scheduled backups
for detached volumes. Do not claim an atomic backup across separate volumes or
recovery beyond the latest verified backup. Platform restore acceptance proves
storage mechanics with synthetic data; the application must separately prove
ledger/artifact consistency and deletion-record behavior after restoration.

## Writer recovery proposal

Propose platform-controlled placement of the SQLite coordinator on one selected
node, with attended relocation after an uncertain failure. This trades automatic
cross-node availability for an explicit recovery boundary. The operator must
review that tradeoff before implementation. A node selection alone is not evidence
that a writer terminated.

Ordinary restart recovery requires positive evidence of prior container termination
on the expected node, or verified node restart that ended its previous processes.
Application recovery must preserve attempt identity and treat missing or ambiguous
termination evidence as recovery pending. Elapsed time, RWO attachment, replica
count, a missing API object, and a deployment strategy are not fencing evidence.

Before relocation or replacement of an uncertain writer:

1. Stop new request admission and automatic retry of uncertain attempts through
   the application's supported control. Preserve its durable ledger and receipts.
2. Record the affected workload/node identities and last verified storage state.
3. Use the attended node/storage recovery boundary in
   [node lifecycle and maintenance](025-node-lifecycle-and-maintenance.md) to
   establish prior termination or actual fencing. Cordon alone is insufficient.
4. Recheck the evidence immediately before changing placement or attaching restored
   storage. If evidence cannot be established, keep the workload unavailable.
5. Perform application recovery validation before reopening request admission.

The supported commands and evidence fields must be made concrete during
implementation and exercised in acceptance. Do not introduce a fencing controller
or change global failover behavior for unrelated workloads as an incidental part
of this onboarding. Automatic relocation is an alternative requiring a separately
demonstrated fencing mechanism; it is not assumed to be provided by storage.

## Proposed initial capacity

These are proposed starting ceilings for review and synthetic qualification, not
a throughput or ten-way scheduling guarantee. Executable manifests will own the
exact values once implemented.

| Namespace allocation | Proposed ceiling |
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
CPU/2 GiB. Ten workers at those limits fit within the proposed namespace ceilings;
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

Offline validation must compile and evaluate the actual admission policies, render
the manifests, and exercise independent positive/negative cases. Include forbidden
profile transitions, coordinator-created preparation Jobs, alternate mounts and
token projections, unsupported controllers, sidecars, route escape, claim deletion,
and changes to platform controls. Mechanical documentation checks are sufficient
for prose; do not add tests that require specific documentation wording.

Live acceptance must demonstrate:

- Harmless workload reconciliation from the approved application source with
  namespace-scoped Flux authority and denied changes outside that authority.
- Required private-service/API/preparation connectivity and offline-worker denial,
  including working storage mounts with renderer networking disabled.
- RWO and multi-node RWX use, read-only releases, retained data after ordinary
  removal/pruning, and isolated restore from an identified successful backup.
- A usable termination/fencing evidence path, recovery-pending behavior when proof
  is missing, and attended recovery where required.
- A second non-rendering workload added solely in the application repository using
  the same deployed platform capability boundary.

Record scoped acceptance against the exact platform/application revisions and
actual deployed state. Keep feature-branch candidate evidence distinct from clean
deployed-main evidence. Platform acceptance does not establish rendering quality,
API authentication, ten-way application admission, or accepted-artifact recovery.

Enrollment of exact source/dependency destinations and required credentials,
reviewed application bootstrap manifests, agreement on the recovery proposal,
hosted platform validation, explicit merge authorization, and scoped live
acceptance are prerequisites to the completed handoff. Application image/release
qualification and upstream activation retain their own acceptance gates.
