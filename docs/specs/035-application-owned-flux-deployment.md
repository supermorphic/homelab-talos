# Application-owned Flux deployment

## Status and scope

Platform contract for issue 593. The namespace is `career-ops`.

Provide one application domain with restricted Flux deployment from its own
repository. Career Ops' CV renderer is the first consumer. Later Jobs and
services that fit the approved capabilities must need only application
repository changes. Independently deployed future domains receive their own
namespaces when needed, following the same onboarding pattern.

The restricted source connection, admission, retained claims, the private route
and two harmless application-owned workloads are deployed and accepted. The
first CV coordinator design used one Kubernetes Job per render, shared request
and artifact volumes, and an on-cluster release-preparation pipeline. It is
being replaced by the renderer-service design below, delivered in the phases
under [Migration](#migration). Until a phase merges, the deployed manifests
remain the source of truth for that phase's controls.

This specification owns the platform boundary: namespace, Flux connection,
identities, admission, network policy, route allocation, storage, credentials,
resource ceilings, monitoring rules and platform acceptance. The Career Ops
specifications own request handling, the ledger, the render API, package
versions, artifact storage schema and application acceptance. Link to them
instead of restating their behavior here.

## Design goals

The consumer is a single-operator job-application pipeline. Deep analysis passes
a job, composition writes CV JSON, the CV is rendered to PDF and stored as the
job's current package version, and the operator downloads it from the NocoDB
dashboard. Expected load is a few CVs per day in bursts. Nobody waits on a render;
minutes of latency are acceptable. Correct, immutable, recoverable PDFs matter;
render throughput and capacity guarantees do not.

Therefore:

- Use the upstream RenderCV image unchanged. Deliver application code, design,
  fonts, Typst packages and pure-Python dependencies from Git through Flux.
  No custom image, registry, pull credential or on-cluster build pipeline.
- Run the document compiler in a separate Pod with no network, credentials or
  Kubernetes token. Keep it stateless so that a stuck or unreachable renderer
  cannot change state, which removes any need for worker fencing.
- Store accepted artifacts and their records in the existing Career Ops
  PostgreSQL database, so one backup restores them consistently.
- Reuse the existing Flux, Cilium, Gateway, PostgreSQL, backup and
  Prometheus → Alertmanager → ntfy capabilities. Add no controller, queue,
  recovery framework or warm worker pool.

## Ownership and domain boundaries

The platform owns namespaces, Flux source connections, reconciliation
permissions, admission, network policies, route allocations, storage
capabilities, retained data protections, resource ceilings, monitoring rules
and privileged recovery. The application owns workload manifests, runtime code
and configuration, request handling, retries, artifact lifecycle and its own
acceptance.

Keep application source, inputs, outputs and detailed release behavior outside
this public repository. Enroll credentials through guarded workflows that write
only SOPS-encrypted artifacts. Application API authentication uses dedicated
material whose behavior and rotation the application owns; the coordinator
receives only token hashes through `cv-api-auth`.

Use the existing Flux, Cilium, Gateway, Longhorn, and credential conventions in
[the platform specification](010-talos-flux-platform.md). Group platform
onboarding manifests under `kubernetes/apps/applications/career-ops/`. The
`applications` directory is an organizational grouping; each application domain
has its own namespace and authority. A shared namespace for unrelated
repositories, or a namespace per render, is not selected.

## Source and reconciliation

Use the Career Ops repository's protected `main` branch and an explicit
`./deploy/` Kustomize root. Additional approved workloads can be added under that
root without changing the platform's source path.

Use a dedicated Forgejo repository-specific token with `read:repository` for
Flux. Forgejo's
[token scope contract](https://forgejo.org/docs/v15.0/user/authentication/token-scope/)
also permits public repository reads. Guarded enrollment verifies the binding
and effective access, writes only SOPS ciphertext using the public recipient, and
retains a non-secret receipt. Rotation retains the old token until replacement
access is verified. Neither credential creation nor ciphertext merge authorizes
activation.

Create a platform-owned GitRepository and application Kustomization in
`career-ops`, reconciled through a dedicated namespace-local service account. The
application cannot change its source, revision policy, Kustomization,
impersonation account or reconciliation permissions. Do not enable
application-controlled Secret decryption, source substitution from arbitrary
Secrets, remote bases or additional sources. The shared kustomize-controller runs
with [`--no-remote-bases=true`](https://fluxcd.io/flux/components/kustomize/options/),
set through the owning bootstrap Kustomize patch.

Reconcile platform restrictions before the application connection. Removing
application workloads must not remove the namespace, platform controls or
retained claims.

The reconciliation identity has explicit permissions for Deployments, Jobs,
ClusterIP Services, internal HTTPRoutes, ConfigMaps, retained PVC declarations,
and constrained ServiceAccounts and RoleBindings, plus read access to ReplicaSets
for Flux health checks. It has no namespace, Secret, Role, network-policy, quota,
storage-class, Flux-resource or admission-policy administration. No wildcard
permissions, impersonation grants, token minting, exec, port-forward or
privilege-escalation authority are delegated. Platform-owned object names are
reserved; admission rejects their update, deletion, ownership transfer or
inclusion in the application inventory.

## Identities and capabilities

Use `career-ops-reconciler` for Flux impersonation. Admission binds each runtime
account to its capability; creating an account or copying a label grants
nothing. An identity never gains credentials, a Kubernetes token or storage
access in place; a capability that needs them gets a new, separately enrolled
identity. Narrow connectivity changes, such as the renderer's coordinator-only
ingress, are reviewed platform changes.

| Account | Capability | Has | Never has |
| --- | --- | --- | --- |
| `cv-coordinator` | Private service | Gateway and Prometheus ingress; egress to DNS, PostgreSQL and `cv-renderer`; Secrets `cv-render-database`, `application-packages-database`, `cv-api-auth`; read-only ConfigMaps | Kubernetes token and PersistentVolumeClaims (after P2), internet egress |
| `cv-renderer` | Sandboxed renderer service | Ingress from `cv-coordinator` only; read-only ConfigMaps; bounded `emptyDir` | Any egress including DNS, Kubernetes token, Secrets, claims |
| `career-ops-service` | Reserved private service | Nothing until separately enrolled | — |

During migration the transitional capabilities remain enrolled: `cv-coordinator`
keeps its Job-management Role, token and claim mounts, `cv-renderer` keeps its
offline Job-worker profile, `cv-prepare` keeps its preparation profile, and the
platform test identities `career-ops-boundary-coordinator` and
`career-ops-boundary-renderer` keep their fixtures. P2 removes them; see
[Migration](#migration).

Use native `ValidatingAdmissionPolicy` and bindings, with failure policy `Fail`,
namespace-wide matching and deny enforcement. Validate controller templates and
resulting Pods, including controller-created Pods and relevant updates. Check the
effective identity, every container, security context, token and Secret
references, volume sources, mounts, image pull Secrets and resource bounds. No
application-selected label exempts an object. Deny sidecars, init or ephemeral
containers, alternative controllers or forged identity labels as routes to
greater authority.

Every container is non-root, has a read-only root filesystem, drops all
capabilities, disallows privilege escalation and sets bounded CPU, memory and
ephemeral storage. Forbid host namespaces, host mounts, privileged execution and
arbitrary storage drivers. Every workload sets automatic token mounting
explicitly. Private image pull Secrets are rejected, so workloads use public
images; the application pins them by digest and its review enforces that, not
admission.

Use Cilium's service-account identity for capability-specific connections rather
than an application-supplied label. Services and workload labels are checked so
the route and monitoring selectors cannot be redirected to another capability.
NodePort, LoadBalancer, ExternalName, arbitrary EndpointSlices and ingress
resources are not admitted. Admitted Services are `cv-coordinator` (ports `http`
8080 and `metrics` 9090), `cv-renderer` (port `http` 8080) and the reserved
`career-ops-service`, each with its fixed selector.

## Networking and route allocation

Default-deny all traffic in `career-ops` and allow only these connections:

| From | To | Purpose |
| --- | --- | --- |
| `networking/internal` Gateway | `cv-coordinator` 8080 | Private API and downloads |
| Prometheus | `cv-coordinator` 9090 | Metrics scrape |
| `cv-coordinator` | `cv-renderer` 8080 | Render calls |
| `cv-coordinator` | `automation-data-postgresql` 5432, with reciprocal policy | Ledger and artifacts |
| `cv-coordinator` | Cluster DNS | Service resolution |
| Kubelet | Both Deployments | Health probes; allowed by Cilium's default host policy, not by a rule here |

`cv-renderer` has no egress, including DNS. Node image pulls do not justify
workload egress.

Allocate `cv.lab.supermorphic.com` to `cv-coordinator` on the existing
`networking/internal` Gateway HTTPS listener, with the
`external-dns.k8s.io/audience: internal` annotation. Admit only allocated
hostnames, namespace-local backends and approved ports, with no route filters.
Download URLs carry bearer tokens in their path, so the internal Gateway access
log excludes the `cv.lab` authority, as it already does for search URLs.

New external hostnames, dependencies, credentials or cross-domain access require
platform allocation. This specification does not enable n8n consumption or any
upstream workflow.

## Runtime delivery

Both Deployments run the upstream `ghcr.io/rendercv/rendercv` image pinned by
digest. Flux delivers, as ConfigMaps generated from the application's `./deploy/`
root:

- application code;
- one or more zip archives of pure-Python dependencies, built by a repository
  command from a hash-checked lockfile;
- the CV design and the Typst packages the template imports;
- the approved fonts, one ConfigMap per font file.

Every object must stay under the Kubernetes object size limit of about 1 MiB,
counting base64 encoding of binary data, so large dependencies or fonts are split
across ConfigMaps. A change to any delivered file changes the generated ConfigMap
name and rolls the Deployment.

The approved font is Liberation Serif 2.1.5 (SIL Open Font License), pinned by
file checksum. It has the same character widths as Times New Roman, so line
breaks match; its slightly tighter line spacing can move a page break, so the
application's page-count check runs with this font. Fonts whose licenses forbid
storage in Git are not used.

An image digest change alters the application's runtime. The application tests
run inside the pinned image before a digest change merges, and the service checks
its runtime versions at startup.

## Persistence

Use the existing Career Ops PostgreSQL database; add no database service, queue
or second job system. Application migrations own the ledger, the artifact store
and package versions; the canonical schema and behavior are in the Career Ops
[CV rendering](https://forgejo.infra.supermorphic.com/supermorphic/career-ops/src/branch/main/docs/specs/019-cv-rendering.md)
and
[package](https://forgejo.infra.supermorphic.com/supermorphic/career-ops/src/branch/main/docs/specs/021-application-package-selection.md)
specifications. The platform relies on these properties:

- Accepted artifact bytes and the records that reference them commit in one
  transaction, and both are covered by the database's nightly logical backup.
- Artifacts are immutable and addressed by SHA-256; deletion is a guarded
  application transition that every referencing record can block.
- No PDF previews are generated or stored.

Enroll each database login through the existing
[application-login boundary](026-automation-data-postgresql-platform.md#registration-and-authority).
The platform validates effective privileges and delivers each credential through
its protected enrollment and SOPS workflow. Do not reuse an n8n, owner, migrator
or provisioner credential. The renderer never receives a login. PostgreSQL must
accept only SCRAM authentication for these logins, because the pure-Python client
driver does not enforce an authentication floor.

The PostgreSQL runtime is one StatefulSet replica with a 24-hour off-cluster
recovery-point objective and an attended restore procedure; no automatic failover
is assumed. During an outage the coordinator admits, stores and serves nothing,
and resumes when the database returns.

## Storage

The retained Longhorn claims `cv-releases`, `cv-requests` and `cv-artifacts`
(class `career-ops-retain`: Longhorn CSI, `Retain`, two replicas, existing backup
group) belong to the replaced design. They stay enrolled and protected until the
migration has verified the database copy, then are reclaimed by the attended P3
action. The target design needs no PersistentVolumeClaim.

Claims must use permitted names, sizes, access modes and classes. Forbid routine
PVC deletion, workload owner references, removal of Flux prune protection,
arbitrary PV prebinding and unapproved restore or clone sources. Physical claim
reclamation remains a deliberate privileged operation.

## Failure visibility

Use existing [alert delivery](015-alerting-architecture.md#delivery-boundary)
through Prometheus, Alertmanager and ntfy. The ServiceMonitor and PrometheusRule
stay platform-owned; application Flux has no monitoring-resource permission.
Scrape only the `cv-coordinator` Service every minute with a 10-second timeout.
Metrics follow the application's versioned metric schema and carry no document
data or per-request labels.

| Alert | Severity | Condition |
| --- | --- | --- |
| CV service down | Critical after 5 minutes | Target absent or down, service not ready, or required metrics missing |
| CV work stuck | Warning after 15 minutes | The oldest unfinished request is past its deadline |
| CV renders failing | Warning after 1 minute; resolves when no such failure remains in the last hour | A request exhausted its automatic retries, or failed with an infrastructure reason |

These three replace the earlier ten. Designed outcomes such as a page overflow
returned to composition do not alert.
A missing workload or Service must not disable the rules. The rules are armed
whenever the coordinator is expected to run; an attended restore scales it to
zero and accepts the service-down alert.

## Capacity

Namespace ResourceQuota and object counts stay as deployed while migrating; the
manifests own the exact values. They were sized for the Job-per-render design.
P2 lowers compute and object ceilings to the measured needs of the two
Deployments plus headroom, and P3 removes the claim allocation. Quotas are
ceilings, not throughput guarantees.

The renderer handles one render at a time within 1 CPU, 1 GiB memory and a
1 GiB `emptyDir`; the coordinator queues further work.

## Migration

Convert the deployed coordinator in place. The package API, workstation uploads
and downloads keep working at every step. Each step is a reviewed change or an
explicit operator approval.

| Step | Owner | Change |
| --- | --- | --- |
| 1 | Platform P1 | Admit the `cv-renderer` Service; restrict renderer claim mounts to Jobs; Cilium rules for renderer ingress and coordinator egress; Gateway access-log exclusion for `cv.lab`; replace the ten CV alerts and the scrape metric list with the three schema-version-2 alerts, still disabled |
| 2 | Career Ops | Renderer service, HTTP render path, pure-Python dependencies, database artifact store with read fallback to the existing volume, download tokens. Merged code stays outside `./deploy/` until step 3, because that root deploys on merge |
| 3 | Career Ops | Guarded database migration, then deployment from the upstream image and ConfigMaps; download tokens are issued only from here on |
| 4 | Platform | Enable the alerts once schema-version-2 metrics are healthy |
| 5 | Career Ops | Coordinator copies every receipt-listed file except retired previews into the database, verifying each SHA-256 and honoring deletion records; then removes the volume fallback and claim mounts |
| 6 | Joint | Acceptance below; the application starts accepting render requests only after it passes |
| 7 | Career Ops | Set the coordinator's `automountServiceAccountToken: false` and remove its `cv-coordinator-jobs` RoleBinding; remove Job launch, worker permissions, release preparation, promotion, qualification and preview code and manifests |
| 8 | Platform P2 | Remove every reference to retired identities, Roles and kinds: the `cv-render-jobs` Role and the reconciler's RoleBinding and `bind` permissions for it; the coordinator token and Kubernetes API egress; Job-worker, preparation and test-fixture admission rules; `cv-prepare`, `cv-prepare-source` and preparation egress; the `career-ops-boundary-*` identities, their PostgreSQL policy entry, Role, admission policy and fixtures; the storage-network test; PVC, RoleBinding and ServiceAccount allowances nothing uses; then lower quota |
| 9 | Operator P3 | Reclaim the three CV claims and three fixture claims after a retained final backup; revoke the preparation token in Forgejo |

Historical ledger rows from the replaced design remain as read-only history.

## Acceptance

Record scoped acceptance against exact platform and application revisions and
actual deployed state, through the existing
[scoped test execution](032-openbao-scoped-test-execution.md) and report
workflows. Keep feature-branch evidence distinct from deployed-main evidence.

- Private API: DNS, trusted TLS and route; missing and invalid tokens rejected;
  a rotated `cv-api-auth` delivered through SOPS accepts the new token and
  rejects the old one without a Pod restart. Caller behavior (submit, poll,
  download, repeated and conflicting requests, download-link scope) is the
  application's acceptance in its CV rendering specification and runs as part of
  the joint gate.
- Boundary: offline admission cases and a live server-side dry run deny the
  renderer a token, Secrets, claims, pull Secrets and wider network profiles;
  the dry run is repeated after P2.
  At startup the renderer attempts one DNS query and one TCP connection and
  reports through the coordinator's metrics that both were blocked; Hubble drop
  counters for that attempt provide independent positive evidence.
- Monitoring: offline rule tests cover all three alerts; one real ntfy
  notification is delivered and resolved for stuck work.
- Recovery: the existing automation-data restore drill restores a backup
  containing synthetic artifacts, an upload and a deletion; every restored
  record's bytes match their checksum and the deletion survives.

Platform acceptance does not establish rendering quality or composition behavior.
Close issue 593 when these pass on deployed main, P2 is merged, the boundary
checks have been repeated after P2, and this
specification matches the deployed state. P3 may follow as an operator task.

## Rollback and recovery

A bad application release is reverted through Git; Flux rolls the Deployment. Do
not delete retained data, reset ledger history or run a down migration to roll
back code. For a platform-policy failure, restore the last reviewed restrictive
policy through Git; do not remove admission or network controls to make a
workload start.

Credential rotation uses the owning provisioner and protected enrollment,
followed by identity and denial checks. The application-login provisioner
replaces the password on the same PostgreSQL role and does not accept old and new
passwords together. Stage replacement database ciphertext from the freshly
validated ready profile with `just repo career-ops-runtime-secret`, requiring the
reviewed existing ciphertext checksum and expected new generation, then verify
projection reload, new authentication and rejection of the previous password.

For a database restore, scale `cv-coordinator` to zero through Git, restore with
the attended [database recovery](026-automation-data-postgresql-platform.md#recovery)
procedure, then scale it back. Requests accepted and uploads made after the
selected backup are lost and must be resubmitted; the application specification
defines how composition resubmits affected jobs.
