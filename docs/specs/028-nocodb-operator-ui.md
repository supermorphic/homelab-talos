# NocoDB Operator UI for Automation Data

## Purpose

NocoDB is the optional operator interface for
[issue 334](https://github.com/supermorphic/homelab-talos/issues/334). It provides
browser-based browsing, search, filtering, saved views, and small reviewed decisions or
corrections over selected automation-data PostgreSQL domains.

PostgreSQL remains the system of record and the authority boundary. n8n remains the
orchestration and bulk-change boundary. NocoDB is a removable interface over privileges
and business contracts defined by each domain.

This specification defines architecture, lifecycle invariants, and required evidence.
The [operations guide](../guides/nocodb-operations.md) owns executable procedures and
credential binding. The [recovery runbook](../runbooks/nocodb-recovery.md) owns recovery
execution. Tests, reports, issues, and Git history retain implementation evidence.

## Existing platform context

This design extends the accepted
[automation-data PostgreSQL platform](026-automation-data-postgresql-platform.md).
That platform supplies one PostgreSQL service, a managed-domain registry, fixed
provisioning functions, and logical backup of all non-template databases.

| Existing domain role | Purpose |
| --- | --- |
| `<domain>_owner` | Stable `NOLOGIN` owner of database and schema objects |
| `<domain>_migrator` | Reviewed DDL through explicit owner-role assumption |
| `<domain>_runtime` | Ordinary workflow CRUD under domain-defined privileges |

NocoDB support extends an already-populated service. It must preserve existing domain
state, identities, credentials, and backup compatibility. Ordinary domain provisioning
continues to manage its existing roles independently of optional NocoDB sources.

The cluster supplies private TLS through the internal Gateway, SOPS-encrypted Secrets,
retained PostgreSQL storage, off-cluster backups, and established monitoring and log
collection. NocoDB consumes those services without adding another authoritative data
platform. The automation-data platform must pass bootstrap, provisioning, backup, and
full-chain recovery acceptance before dependent NocoDB activation.

## Goals

- Provide private operator access at `https://nocodb.lab.supermorphic.com`.
- Browse workflow facts and record narrow, reviewed human decisions without exposing
  runtime, migrator, or platform credentials to NocoDB.
- Enforce least privilege in PostgreSQL independently of application/UI controls.
- Opt domains into a repeatable n8n source-provisioning workflow without per-domain
  Kubernetes changes or manual password transfer.
- Preserve metadata, encrypted source credentials, saved views, operator records, and
  artifact references through the automation-data recovery model.
- Keep NocoDB removable without disrupting domain workflows or authoritative data.
- Establish separate evidence for implementation contracts, real component behavior,
  live readiness, attended operator access, and isolated recovery.

## Non-goals

- Workflow execution, schema migrations, backfills, or bulk changes through NocoDB.
- General-purpose editing of workflow-produced facts.
- Domain ownership, DDL, role administration, or platform authority for NocoDB sources.
- Public exposure, public signup, or automation-created public shared views.
- SSO, Authentik integration, or paid features as prerequisites for the initial service.
- High availability, multiple application replicas, Redis, workers, or autoscaling.
- NocoDB-native uploads, Attachment fields, comment attachments, or an attachment PVC.
- A new file store, object-storage service, download proxy, or universal artifact schema.
- Career-specific schemas, grants, or production workflows in this infrastructure effort.
- Destructive self-service decommissioning or deletion as provisioning compensation.

## Governing invariants

### PostgreSQL is the authority boundary

NocoDB settings mirror database authority; they do not create it. Application errors,
misconfiguration, or direct API use must not permit an operation denied by PostgreSQL.

For domain access, NocoDB receives only dedicated reader and operator logins. It never
receives a domain runtime, migrator, owner, provisioner, or backup credential. Its
separate metadata identity has authority only within the NocoDB metadata database.

### Separate read and operator surfaces

Each enabled domain presents two distinct schemas:

- `read_model`: workflow-produced facts and approved read-only projections;
- `operator`: human-owned decisions, notes, priorities, follow-up state, and explicit
  correction or override records.

The reader source reflects only `read_model`. The operator source reflects only
`operator`; it does not inherit access to the read surface. Both sources appear in the
same domain base so an operator can inspect facts and record a related decision.

Human corrections do not mutate workflow-produced facts. Domain workflows explicitly
consume applicable operator records and preserve them when refreshing facts. Business
state needed by automation must reside in the domain database, not solely in NocoDB
comments, views, or other application metadata.

Reviewed domain migrations define the objects, runtime access, and business-specific
operator grants needed for this interaction. Provisioning cannot invent those grants.
Broad changes remain n8n operations; schema changes remain migrator operations.

### Domain opt-in

Ordinary domain provisioning creates no NocoDB dependency. Explicit source sync opts an
existing ready domain into reader access. An `operator` schema requests an optional
controlled-edit surface; the corresponding role remains a `NOLOGIN` candidate until
reviewed grants pass validation.

Opt-in, grant eligibility, source identities, and lifecycle progress are runtime platform
state. Adding a domain requires no per-domain `homelab-talos` manifest, SOPS Secret, or
NetworkPolicy change.

### NocoDB is removable

Removing the application or metadata database must not delete domain databases, invalidate
domain credentials, or prevent n8n/direct database consumers from operating. Domain
migrations and operator-decision contracts remain usable without NocoDB.

Files remain with their workflow/storage owner, and their authoritative metadata and
references remain in PostgreSQL. Replacing the UI requires no movement of those files.
Metadata recovery or explicit source reconciliation can rebuild the operator surface.

## Selected architecture

```text
private operator
      |
      v
internal Gateway / private TLS
      |
      v
one NocoDB application pod
      |-- metadata -------> database "nocodb" as nocodb_metadata
      |-- reader source --> <domain>.read_model as <domain>_reader
      `-- operator source -> <domain>.operator as <domain>_operator
                                  |
                                  v
                       automation-data PostgreSQL

n8n domain workflows <--> workflow facts and operator decisions
workflow-generated files --> workflow-owned external storage
PostgreSQL artifact records --> durable file metadata and references

operator lifecycle command
      |
      v
private n8n source-provisioning workflow
      |-- fixed PostgreSQL SECURITY DEFINER functions
      `-- fixed NocoDB source operations
```

NocoDB runs in the existing `automation-data` namespace under
`kubernetes/apps/automation-data/nocodb/`. The package owns its Helm release, private
HTTPRoute, workload-scoped Cilium policy, fixed-purpose metadata bootstrap Job, and
Secret references. Namespace placement permits the bootstrap Job to use existing
platform Secret references without copying credentials across namespaces; workload
policy still separates application, database, backup, and exporter traffic.

The PostgreSQL platform owns optional roles, fixed functions, and the source registry.
The n8n package owns the secret-free provisioning workflow template and its private API
egress. Gatus and Prometheus alert packages own their monitoring definitions. Homepage
uses route discovery. None of these packages gains domain-specific infrastructure.

## Deployment and version contract

The implemented platform selects the official OCI chart
`oci://ghcr.io/nocodb/charts/nocodb` version `1.0.0` and NocoDB image version
`2026.08.2`. Git-managed chart and image references are authoritative for immutable
pins; this specification does not duplicate their digests. Updates follow repository
review and validation workflows rather than application self-updates.

The application has one replica with `Recreate`, a private `ClusterIP` Service, external
PostgreSQL, and disposable application scratch. Chart Ingress and NetworkPolicy are
replaced by repository Gateway and Cilium patterns. Worker, Redis, autoscaling, and
native persistence are disabled.

This single-instance deployment accepts a short outage during replacement or node
movement. Source-creation work runs through the application's fallback queue. Queue
state is not assumed to survive interruption; the source lifecycle must distinguish
incomplete creation from an established ready source.

The selected Community edition's asynchronous source creation and coarse application
permissions are architectural constraints. The baseline does not require paid features.
The selected licensing model is internal self-hosted use under the Sustainable Use
License; future distribution or service models require review.

## Metadata database

A dedicated `nocodb` logical database holds users, workspaces, bases, source definitions,
encrypted source credentials, API tokens, views, and application configuration. The
`nocodb_metadata` login owns and migrates only that database. This is a platform metadata
database, not a managed domain, and it is absent from `managed_domains`.

The metadata login cannot connect to domain or control databases. Domain source roles
cannot connect to NocoDB metadata. Logical backup discovers `nocodb` from the catalog,
and global-role backup preserves its login and password verifier.

The SOPS-managed `NC_CONNECTION_ENCRYPT_KEY` is retained recovery material. It is created
once and preserved across application replacement, bootstrap retry, and metadata
recovery. It is not an ordinary rotating source credential. A database backup alone
cannot recover encrypted source passwords if this key is lost.

## External artifacts and recovery

Workflow-generated files remain owned by the workflow's external storage system.
PostgreSQL stores durable artifact metadata and references. Each domain defines the
identifiers, locators, versions, checksums, and other attributes its workflow needs;
NocoDB introduces no universal artifact schema.

The UI may display references as links. It does not ingest, proxy, copy, or own the
files. Durable references must not depend on expiring signed URLs or contain reusable
credentials. Storage owners control access and temporary download authorization.

NocoDB has no attachment PVC or native-attachment recovery dependency. Application
scratch may disappear on replacement. Supported durable state must remain recoverable
from PostgreSQL and retained Secrets. Source schema editing stays disabled, including
for attachment configuration. Omitting attachment features does not assert that every
application upload API is disabled; local application storage is not a supported place
for durable files.

A complete automation-data logical bundle contains NocoDB metadata, domain databases,
the source registry, and global roles. Together with the retained encryption key, it
must recover source access, saved configuration, operator decisions, and artifact
metadata/references. Logical recovery does not recover or validate external file bytes.
Their owner supplies retention, backup, recovery, and reference-consistency procedures.

Native attachment support would require a new architectural decision covering ownership,
Community-edition support, schema authority, portability, and complete recovery.

## Authentication and application configuration

NocoDB uses local email/password authentication. Bootstrap establishes restricted signup
and workspace creation and reads the settings back. Provisioning creates no public base
or view links. Telemetry and support chat are disabled, and the application URL matches
the private route.

SOPS-managed configuration supplies metadata credentials, authentication material, the
retained connection encryption key, bootstrap administrator credentials, and fixed
webhook authentication. Plaintext values must not appear in output, command arguments,
tracked artifacts, or saved workflow execution data.

The NocoDB API credential used by n8n has broader authority than an ideal source-only
credential in the selected Community edition. Containment comes from fixed workflow
operations, PostgreSQL privileges, private networking, and the absence of arbitrary
SQL, grants, credentials, or source-target inputs. UI roles and API-token scopes are
not substitutes for those boundaries.

Allowing local external databases is necessary to reach the private PostgreSQL Service.
The workflow derives that fixed target from the platform contract, and Cilium constrains
the application's egress. Application setup and API credential reconciliation remain
operator-run administration; source credential rotation is a separate lifecycle.

## Network contract

The HTTPRoute attaches only to the internal Gateway and uses the repository's private
TLS, DNS, and namespace-admission pattern. Application URL and health monitoring use
`nocodb.lab.supermorphic.com`. Route readiness must be established before bootstrap
uses administrative application access.

Workload-scoped Cilium policy permits:

- internal-Gateway access and n8n fixed API access to the NocoDB Service;
- NocoDB access to cluster DNS and automation-data PostgreSQL;
- established health-probe and monitoring paths; and
- metadata bootstrap access only to DNS and automation-data PostgreSQL.

There is no general Internet ingress or egress. n8n gains only the private NocoDB
Service destination needed for the fixed workflow. Namespace co-location does not
provide unrestricted access among platform workloads.

## Optional domain roles

| Role | Eligibility | Authority |
| --- | --- | --- |
| `<domain>_reader` | Explicit opt-in with a validated `read_model` surface | Connect to its domain; schema usage and read-only access to `read_model` |
| `<domain>_operator` | Optional schema plus reviewed, validated controlled-edit grants | Connect to its domain; only domain-declared access within `operator` |

Neither role has superuser, database-creation, role-creation, inheritance, replication,
RLS-bypass, ownership, or schema-creation authority. Neither can assume another domain
or platform role. Effective `PUBLIC` grants and access to maintenance databases must
not provide a path around domain isolation.

Reader grants include current read-model tables/views and owner default privileges for
future objects in that schema. There is no access to `app` or `operator`, sequence use,
DML, or DDL. Domain migrations control which projections appear in the read surface.

The operator begins as a stable `NOLOGIN` grant target. Reviewed migrations may grant
read/insert access and sequence use on decision tables, update access to exact columns,
and deletion of operator-owned rows. Row-level restrictions remain PostgreSQL policies.
The operator does not inherit reader access.

Fixed catalog validation requires an eligible controlled DML surface and rejects
privileges outside `operator`, forbidden attributes, ownership, schema creation, or
cross-database authority before enabling its login and source. The provisioner accepts
no table, column, SQL, grant, or row-policy expression from the caller.

Reader data editing is disabled in NocoDB; operator data editing is enabled. Schema
editing is disabled for both. These settings distinguish the UI surfaces but need not
represent every column-level grant. PostgreSQL remains the independent denial oracle.

### Domain schema evolution

Reviewed migrations are the only DDL path. Following a migration, validate grants,
explicitly refresh affected NocoDB schema metadata, and reconcile source identity and
access. Additive refresh preserves source credentials, base/integration/source identity,
and saved views whose referenced objects remain valid.

Incompatible renames or removals require attended review. Refresh must not silently
recreate a source, discard views, or widen grants. Automatic metadata refresh through
the provisioning webhook is not required by the initial design.

## Existing-platform upgrade

Empty-data-directory initialization is not an upgrade mechanism for a populated service.
NocoDB support uses one reviewed, versioned, additive platform extension, shared by fresh
initialization and existing-platform upgrade. This extends the control schema; it is
neither a PostgreSQL engine upgrade nor a general migration service.

The migration contract requires:

- validation of expected prior state and installed compatibility revision;
- serialized, atomic schema/function changes and an idempotent validated rerun;
- preservation of domain databases, data, role identities, credentials, and grants;
- installation of the fixed source registry, authority functions, and domain-isolation
  restrictions without recreating the existing platform;
- compatible backup/restore handling for recognized prior and extended state; and
- fail-closed rejection of unknown, incompatible, or ambiguous partial state.

The persisted extension revision is `026-nocodb-v1`. It remains a live compatibility
identifier despite specification renumbering. Revision validation must also detect
installed-contract drift; a matching label alone is insufficient.

Deploy backup compatibility before applying the extension. Backup consistency checks
must reject a capture spanning the platform change. Existing bundles remain restorable;
extended bundles include optional roles, registry state, and required isolation grants.
Dependent activation requires a fresh complete compatible backup after the extension.

The fixed upgrade is operator-run administration under deployed-source and target
preconditions. Scripts and tests own the exact SQL, invocation, compatibility oracle,
and proof that populated upgrades and fresh initialization converge.

## Platform registry and fixed functions

`platform_operations.managed_nocodb_sources` is the single runtime source registry in
the automation-data control database. Each row references a managed domain and the
fixed access kind `reader` or `operator`. Ordinary domain readiness remains independent
of optional UI readiness.

The registry retains role identity; canonical base, integration, and source identities;
asynchronous creation identity; operation and credential generations; lifecycle state;
and bounded validation/error metadata. Passwords and API tokens never enter it.
Identifiers are validated or treated as opaque values, never executable input.

The reader row establishes the canonical base identity, shared by any operator source.
Domain UI readiness is derived from its source rows: reader-only ready, reader ready
with operator awaiting grants, controlled-edit ready, or incomplete/error. A second
domain UI registry would duplicate this state.

The existing provisioner receives execute access only to fixed `SECURITY DEFINER`
functions for optional-role reconciliation, transient credential assignment/rotation,
privilege validation, identity recording, and lifecycle transitions. Functions derive
identifiers from the managed domain and access kind; public execution is revoked.

This boundary exposes no arbitrary SQL, source targets, grants, database creation,
role deletion, or decommissioning. Backup and restore preserve the source registry
and optional roles together with the control database.

## Bootstrap workflow

Bootstrap is an operator-run initialization and authority boundary. It validates deployed
source, platform acceptance, installed extension state, compatible backup, and intended
activation before administering NocoDB or n8n. Consequential mutation repeats current
source, target, and prerequisite checks.

It initializes or reconciles metadata, establishes restricted application settings,
and creates or reconciles the NocoDB API credential used by n8n. Credential transfer
occurs directly through the fixed setup path without exposing plaintext. Recovery roots
and existing metadata survive retries.

Failure preserves existing databases and credentials and supports bounded retry from
observed state. Bootstrap reverses only temporary activation it owns; it does not erase
retained application objects or regenerate the connection encryption key as compensation.
Ambiguous administrative state requires attended repair.

Executable sequencing, API calls, confirmation strings, binding instructions, and
credential recovery mechanics belong in the operations guide.

## Source provisioning workflow

A private n8n workflow accepts one existing ready managed-domain identifier. Eligibility
comes from PostgreSQL catalogs; callers supply no arbitrary target, database credential,
schema, or grant. Reader and operator eligibility are evaluated independently.

Each enabled domain has one base, a reader source, and an optional operator source.
Deterministic names aid reconciliation, while retained base, workspace, integration,
and source IDs are the durable identities. Workspace titles are not recovery roots.
Creation within a base is serialized, completing reader creation before operator
creation where both are needed.

### State model

```text
explicit request / awaiting_grants
              |
              v
         provisioning
              |
              v
      waiting_for_source
              |
              v
            ready
              |
      explicit targeted rotation
              |
              v
           rotating --> ready

incomplete operations retain identity and enter error or await bounded retry
```

A request is an opt-in action; persisted `awaiting_grants` distinguishes an ineligible
operator source from an active source operation. The other persisted lifecycle states
are `provisioning`, `waiting_for_source`, `ready`, `rotating`, and `error`.

### Creation and readiness

Source creation is asynchronous. Queue acceptance is not readiness. The workflow retains
operation identity before resuming observation so interruption does not lead to duplicate
creation. It binds completion to the requested base and integration rather than accepting
an unrelated job or a similarly named source.

A source first becomes `ready` only after its bound creation operation completes and
independent validation confirms unique source identity, reflected schema, UI edit flags,
normal data access, and PostgreSQL privileges. Ambiguous discovery or conflicting
identities fail closed.

Timeout retains resumable state. A missing job for a source not yet established as ready
is not permission to queue a replacement. A new initial generation is allowed only after
proving no matching or conflicting source survives. Partial objects requiring cleanup
remain an attended repair case; the workflow performs no destructive compensation.

### Reconciliation and interruption

Ready state is independent of historical queue retention. Ordinary sync validates current
identity and access without requiring old job records. It preserves ready source and
integration IDs, PostgreSQL credentials, and NocoDB encrypted credentials. Missing or
mismatched ready-side objects require explicit repair, not silent recreation.

Resume state contains non-secret identity and lifecycle information. Passwords exist only
transiently while n8n delivers the same value to PostgreSQL and NocoDB. Saved execution
data is disabled, and waits/retry mechanisms must not persist credential-bearing state.
An interrupted workflow resumes from registry and observed application state rather than
from retained plaintext execution history.

### Explicit targeted rotation

Rotation is separate from sync and bound to one domain and one access kind. It repeats
readiness and identity checks, changes the selected PostgreSQL credential and the same
NocoDB integration, then validates authentication, denials, and generation convergence.
It preserves source identity and does not rotate the other access kind.

The two-system change is convergent, not transactional. Partial rotation retains its
operation kind and exact base/integration/source identity. Explicit retry may converge
both sides only after those identities match current state. Ordinary sync, another
target, or a missing identity cannot resume rotation through blind credential replacement.

There is no self-service operation that deletes a source, base, role, registry row, or
domain. Future decommissioning requires a separate attended design.

## Command lifecycle

The command surface follows the
[repository lifecycle contract](021-repository-command-lifecycle.md): validation is
local, verification is observational, tests are bounded experiments, and bootstrap,
source sync, and rotation are explicit administration or reconciliation.

Mutation workflows bind execution intent to the target, check deployed-source parity,
repeat safety-critical preconditions, and read back postconditions. Confirmation guards
do not grant authority. Repository policy determines agent-owned and operator-run work;
sensitive administrative execution remains with the operator.

Read-only verification does not inspect Secrets, authenticate as a source, or perform a
positive authorization probe. Those checks belong in registered acceptance workflows.
The operations guide owns command syntax and the exact operator procedure.

## Monitoring and logs

Gatus lists NocoDB under **Automation** and checks health through the private route.
Homepage discovers **Platform → NocoDB** from the HTTPRoute and links to the private UI
without an API widget credential. Alloy collects application logs through the existing
namespace path.

Prometheus alerts cover workload/health unavailability, restarts and OOM kills, and
failed or overdue bootstrap/acceptance work. Existing automation-data exporter metrics
cover metadata size, connections, transactions, backup freshness, and catalog consistency.
The selected NocoDB deployment supplies no supported Prometheus endpoint, so no
speculative application ServiceMonitor is added.

Monitoring enrollment follows durable activation. Staged absence must not produce outage
alerts, while absence after intended activation must fail verification. Durable activation
enrolls Gatus, selected alerts, and recurring verification together. Resource usage must
be measured and right-sized before adding production automation domains.

## Validation strategy

### Cluster-independent validation

Repository-selected merge-gating checks validate rendered configuration, fixed authority
boundaries, workflow/command contracts, lifecycle regressions, and secret-safe artifacts.
They provide repeatable evidence without cluster access or production credentials.
They do not establish real application behavior, live authorization, or recovery.

### Disposable local integration

A separate registered full-stack test uses pinned PostgreSQL, n8n, and NocoDB components,
synthetic data, generated local credentials, and isolated disposable storage/networking.
It proves component interoperability across provisioning, decision consumption, schema
refresh, restart, targeted rotation, platform upgrade, backup, and isolated restoration.
It also proves bounded cleanup of test-owned resources.

This layer is outside the cluster-independent gate. It does not prove the live Gateway,
Cilium policy, production backup publication, or browser experience.

### Read-only live verification

Scoped observation proves current Flux/workload readiness, Service and private route,
policy, monitoring enrollment, and logical-backup freshness against intended activation.
It distinguishes staged inactivity from failure of an active service.

It does not read credentials or application metadata, exercise data authorization, or
prove that a fresh backup can restore the operator surface.

### Attended access test

A registered synthetic-domain test proves opt-in without infrastructure changes, source
identity and idempotence, targeted rotation, PostgreSQL-enforced reads/denials, and the
workflow fact → operator decision → workflow consumption → refresh interaction.
Browser acceptance separately confirms usable read-only browsing and the intended small
operator edit. UI flags alone cannot establish authority.

Acceptance retains a bounded record/reference and saved-view canary for recovery while
removing current-run test data. Cleanup must prove absence of run-owned state without
removing retained recovery evidence. Synthetic artifact references are not fetched.
Access acceptance does not establish recovery or validate external file storage.

### Attended restore drill

The isolated drill restores a complete automation-data logical bundle into a separate
database and starts NocoDB with fresh scratch and retained recovery material. Restored
sources must target the isolated database, never the live domain Service.

It proves metadata/role/registry consistency, source credential decryption and authority,
saved-view and record/reference survival, fresh logical backup from the restored system,
and removal of run-owned resources. It must not overwrite production metadata or domain
data. It does not prove Longhorn volume recovery or recover external file bytes.

## Rollout

Rollout follows dependency and authority order:

1. Validate and review the staged application, platform extension, workflow, and backup
   compatibility before enabling dependent behavior.
2. Establish automation-data acceptance, apply the reviewed additive extension, and
   obtain a complete compatible backup before NocoDB bootstrap.
3. Complete operator-managed encrypted configuration, bootstrap, credential binding,
   workflow publication, and source/browser acceptance.
4. Make activation durable through reviewed Git state and enroll monitoring with it.
5. Verify deployed activation and complete isolated recovery using a backup containing
   accepted source state before claiming rollout completion or recoverability.

The operations guide owns executable ordering within these boundaries. Human operators
review and merge PRs; agents prepare reviewable changes and perform authorized scoped
observation. Relevant platform or recovery changes require fresh affected evidence;
unrelated repository changes do not alone invalidate accepted dependency evidence.

## Failure handling

- Application unavailability does not block n8n workflows or direct PostgreSQL access.
- Bootstrap failure preserves metadata and recovery roots and reverses only activation
  owned by that attempt.
- Incomplete source operations retain non-secret identity for deterministic diagnosis and
  bounded retry; ambiguous state never permits duplicate creation or destructive cleanup.
- Ready source credentials change only through targeted rotation or attended repair.
- Metadata loss requires a complete compatible logical restore and the retained encryption
  key. Loss of that key requires operator-led recovery or explicit source credential repair;
  it cannot be repaired from metadata alone.
- PostgreSQL grants and source identity must be revalidated after recovery. Saved UI state
  does not establish continuing authorization.
- Domain/storage owners recover external files independently of NocoDB metadata recovery.

## Implementation status

NocoDB is durably active with private routing, platform monitoring, and Homepage discovery.
Reader/operator source provisioning and attended browser access acceptance passed.
Disposable integration proved the source lifecycle, restart behavior, targeted rotation,
additive schema refresh, backup, and isolated restoration. Attended isolated metadata
recovery passed on September 10, 2026.

Fresh verification of the merged post-activation revision remains the closeout item at
this revision. Individual run records and diagnostic history remain in reports and PRs.

The material implementation findings are reflected in the final architecture: separate
fact and decision schemas, PostgreSQL-owned durable state with external artifact
references and no native attachment storage, asynchronous resumable creation, and ready
sources that do not depend on historical job retention.

## Rejected alternatives

| Alternative | Reason for rejection |
| --- | --- |
| Runtime or migrator credentials for NocoDB | They grant broader CRUD or DDL than the operator surface needs. |
| UI permissions as the security boundary | Application controls cannot replace independent PostgreSQL enforcement. |
| Read-only-only UI | It omits the small decisions and corrections that justify the operator surface. |
| General-purpose UI editing | It blurs ownership of facts and enables changes that belong in domain workflows. |
| Manual source onboarding | Password transfer and manual settings create unnecessary credential handling and drift. |
| Custom provisioning broker | n8n and fixed PostgreSQL functions already provide the needed lifecycle and authority boundary. |
| NocoDB-native attachment storage | It creates file ownership and recovery obligations outside the supported metadata/reference model. |
| Multiple replicas or Redis | Current operator demand does not justify distributed application and queue complexity. |
| NocoDB-specific object storage | It adds a storage platform without a demonstrated requirement; workflows already own their files. |
| Native manifests instead of the supported chart | They duplicate maintained workload conventions without reducing the required repository integration. |

## Review triggers

Revisit the architecture when demonstrated requirements call for native attachments,
application HA, another permission or identity model, or a domain scale that exceeds the
current workspace model. Resource measurements should drive capacity changes.

Changes to NocoDB source lifecycle, queue behavior, token scope, metadata schema,
Community-edition capabilities, licensing, or backup compatibility require review and
new affected evidence. A native attachment proposal must resolve storage ownership,
authority, portability, and recovery before becoming supported.

Keep this specification aligned with accepted architectural changes. Procedures belong
in guides/runbooks and executable details in implementation and tests.

## References

- [Automation-data PostgreSQL specification](026-automation-data-postgresql-platform.md)
- [Repository command lifecycle](021-repository-command-lifecycle.md)
- [NocoDB operations](../guides/nocodb-operations.md)
- [NocoDB recovery](../runbooks/nocodb-recovery.md)
- [NocoDB Kubernetes installation](https://nocodb.com/docs/self-hosting/installation/kubernetes)
- [NocoDB environment variables](https://nocodb.com/docs/self-hosting/environment-variables)
- [NocoDB backup guidance](https://nocodb.com/docs/self-hosting/maintenance/backups)
- [NocoDB self-hosting and license](https://nocodb.com/docs/self-hosting)
- [PostgreSQL privileges](https://www.postgresql.org/docs/17/ddl-priv.html)
- [PostgreSQL role attributes](https://www.postgresql.org/docs/17/role-attributes.html)
