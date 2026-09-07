# NocoDB Operator UI for Automation Data

## Purpose

Implement the optional operator interface requested by
[issue 334](https://github.com/supermorphic/homelab-talos/issues/334). NocoDB gives an
operator a browser-based view of selected automation-data PostgreSQL domains. It supports
ordinary reading and small, reviewed corrections or decisions without making NocoDB the
system of record or the bulk-change engine.

PostgreSQL remains authoritative. n8n remains the orchestration and bulk-change boundary.
NocoDB is a removable interface over database privileges defined by each domain.

This design extends the platform in
[specification 025](025-automation-data-postgresql-platform.md). It cannot become active
until that platform has completed bootstrap, provisioning acceptance, backup validation,
and its full-chain restore drill.

## Existing platform context

The issue-317 source implementation defines one automation-data PostgreSQL service and
three roles for each managed domain:

| Role | Current purpose |
| --- | --- |
| `<domain>_owner` | Stable `NOLOGIN` owner for database and schema objects |
| `<domain>_migrator` | Login for reviewed DDL through explicit owner-role assumption |
| `<domain>_runtime` | Login for ordinary workflow CRUD in the domain |

The core `managed_domains` registry and ordinary provisioning functions manage only the
migrator and runtime login credentials. The implemented extension keeps optional NocoDB
reader and operator state in the separate, single-purpose `managed_nocodb_sources`
registry. The accepted platform is already active: specification 025 records successful
provisioning and full-chain recovery acceptance on 2026-09-05, and its Flux
Kustomization has `spec.suspend: false`. NocoDB remains suspended and unaccepted.
Introducing NocoDB must upgrade that existing platform without recreating its database,
changing existing domain credentials, or interrupting its backup contract.

The cluster already supplies these relevant patterns:

- private TLS application routes through the internal Gateway;
- SOPS-encrypted application Secrets;
- Longhorn `ReadWriteOnce` volumes with two storage replicas;
- daily Longhorn snapshots and off-cluster CIFS/NAS backups with seven retained;
- PostgreSQL logical backups of every non-template automation-data database;
- Alloy log collection, Prometheus alerts, Grafana, and Gatus; and
- effect-based lifecycle commands from
  [specification 021](021-repository-command-lifecycle.md).

## Goals

- Serve NocoDB at `https://nocodb.lab.supermorphic.com` through the private Gateway.
- Let an operator read approved automation-domain data without runtime or migrator
  credentials.
- Permit narrow, domain-reviewed inserts, updates, or deletes for decisions, notes,
  follow-up state, and exceptional corrections.
- Enforce all data and schema authority in PostgreSQL rather than relying on NocoDB UI
  settings as the security boundary.
- Add NocoDB sources through an explicit, repeatable n8n provisioning workflow without
  displaying or manually copying generated passwords.
- Preserve NocoDB metadata, encrypted source credentials, and saved configuration through
  the automation-data backup system. Keep workflow artifacts external to NocoDB.
- Keep NocoDB optional for each domain and removable without affecting authoritative
  domain data or normal n8n workflows.
- Prove read, controlled-edit, rotation, denial, backup, and restore behavior against a
  synthetic domain before activation.

## Non-goals

- Moving workflow logic, schema migrations, bulk changes, or universal data corrections
  from n8n into NocoDB.
- Giving NocoDB a domain runtime credential, migrator credential, database ownership,
  schema DDL, role-management authority, or automation-data platform authority.
- Exposing NocoDB publicly, publishing shared public views, or adding public signup.
- Authentik, SSO, Enterprise-only NocoDB permissions, or paid NocoDB capabilities.
- Adding Redis, a worker deployment, an application replica, MinIO, S3, or another data
  service.
- NocoDB-native uploads, comment attachments, or Attachment fields in the initial
  operator surface, including temporarily unlocking source schema editing to enable them.
- Defining a generic artifact registry, file-storage service, download proxy, or backup
  system for workflow-generated files.
- Zero-downtime application upgrades or application high availability.
- Defining a career domain, career tables, career grants, or career data in this
  initiative.
- Automatically deleting a NocoDB base, source, database role, or credential after a
  provisioning failure.

## Governing invariants

### PostgreSQL is the authority boundary

NocoDB source settings mirror PostgreSQL authority but do not create it. A NocoDB bug,
misconfiguration, or direct API call must not let its login perform an operation that
PostgreSQL denies.

NocoDB never receives `<domain>_runtime`, `<domain>_migrator`, `<domain>_owner`,
`automation_data_provisioner`, or a platform backup credential. It receives only the
optional reader and operator logins defined here.

### Separate read and operator surfaces

Noco-enabled domains present two distinct PostgreSQL schemas instead of exposing the same
tables through two credentials:

- `read_model` contains workflow-produced facts and read-only projections; and
- `operator` contains decisions, notes, priorities, follow-up state, and explicit
  correction or override records intended for human editing.

The reader source reflects only `read_model`. The operator source reflects only
`operator`. An operator uses both sources in the same NocoDB base: the first to inspect
facts and the second to record a decision or correction. The operator credential does not
gain a second path to the read-model objects.

Domains preserve source facts and represent corrections as records in `operator` rather
than updating source tables in place. Broad changes, schema changes, backfills, and
changes across many records remain n8n or migrator operations.

Domain workflows explicitly consume the applicable operator decisions. A refresh updates
workflow-owned facts without overwriting human-owned decisions. A domain's reviewed
migrations grant its runtime login the access needed to publish `read_model` and consume
`operator`; NocoDB provisioning does not grant that runtime access. Acceptance must prove
the complete fact, decision, consumption, and subsequent-refresh sequence, not just CRUD
on two unrelated tables. Business decisions needed by automation belong in `operator`,
not only in NocoDB comments, views, or attachment metadata.

### Domain opt-in

Ordinary automation-data provisioning continues to create only owner, migrator, and
runtime roles. A NocoDB source-sync operation is the explicit opt-in that adds
`<domain>_reader`. When the domain has an `operator` schema, source sync also creates
`<domain>_operator` as a `NOLOGIN` candidate so a reviewed domain migration has a stable
grant target. A later source sync enables each role as a login and creates its source
only after that role's distinct schema and privileges pass validation.

Enabling or reconciling a NocoDB source is runtime platform state. It does not require a
per-domain `homelab-talos` manifest, SOPS Secret, or NetworkPolicy change.

### NocoDB is removable

Removing the NocoDB Deployment or metadata database must not remove or invalidate
domain databases, domain migrations, or normal n8n credentials. Reinstalling NocoDB can
recreate its metadata and sources from backups and the provisioning contract.
Authoritative artifact metadata and durable file references remain in the domain database;
the underlying files remain with the workflow's external storage owner.

## Selected architecture

```text
private operator
      |
      v
https://nocodb.lab.supermorphic.com
      |
      v
one NocoDB application pod
      |-- metadata --> automation-data PostgreSQL database "nocodb"
      |-- reader source --> <domain>.read_model as <domain>_reader
      `-- operator source --> <domain>.operator as <domain>_operator

workflow-generated files --> workflow-owned external file/object storage
domain PostgreSQL records --> durable artifact metadata and references

operator lifecycle command
      |
      v
private n8n NocoDB source-provisioning workflow
      |-- fixed automation-data SECURITY DEFINER functions
      `-- fixed NocoDB source API operations
```

The NocoDB application package contains:

- one official Helm release;
- one private `HTTPRoute`;
- workload-scoped Cilium policy;
- a fixed-purpose metadata-database bootstrap Job;
- SOPS Secret references; and
- local validation and lifecycle scripts.

NocoDB runs in the existing `automation-data` namespace under
`kubernetes/apps/automation-data/nocodb/`. Its fixed metadata bootstrap Job can therefore
read the existing automation-data provisioner Secret and the separate NocoDB Secret
without copying credentials across namespaces. Workload labels and Cilium policy still
isolate NocoDB from the PostgreSQL, backup, and exporter workloads in that namespace.

The automation-data platform gains the optional roles, fixed provisioning functions, and
NocoDB source registry. Following the existing workflow-template layout, the n8n package
owns the secret-free source-provisioning workflow template and the egress needed for the
private NocoDB Service. The `monitoring/gatus` package owns the endpoint definition and
`monitoring/alerts` owns the application alert rules. Domain-specific Kubernetes
resources are not created.

## Deployment and version contract

The application uses the official OCI Helm chart:

| Component | Pin |
| --- | --- |
| Chart | `oci://ghcr.io/nocodb/charts/nocodb` version `1.0.0` |
| Chart digest | `sha256:b2aa331863ec002e5001db33c2ac257bc0f1df690396c340e3e38e6978fece6c` |
| Image | `docker.io/nocodb/nocodb:2026.08.2` |
| Image index digest | `sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9` |

The Helm values set the image by digest. The tag remains visible for operator context but
does not select mutable content. Version `2026.08.2` is selected instead of the chart's
`2026.06.1` application default because it supplies
`POST /api/v2/meta/bases/:baseId/sources`. This endpoint queues source creation and
returns `{ "id": "<job-id>" }`; it does not return a created source. The workflow must
observe that asynchronous contract rather than treating the HTTP 200 response as source
readiness. Live acceptance must prove this chart and image combination before activation.

The chart is configured with:

- `replicaCount: 1`;
- `updateStrategy.type: Recreate`;
- worker and autoscaling disabled;
- no Redis configuration;
- no configured native attachment surface or attachment-dependent acceptance path;
- a `ClusterIP` Service;
- chart Ingress and chart NetworkPolicy disabled in favor of repository patterns;
- the external PostgreSQL URL and both auth keys from an existing Secret; and
- `persistence.enabled: false`, with disposable application scratch storage.

One pod is intentional. With the worker disabled and Redis absent, NocoDB runs
source-creation jobs in the application pod's fallback queue. Attended acceptance must
prove that this mode completes source creation and supports normal operator read and
write behavior. Keep `Recreate`
for a simple single-instance replacement. A pod or node move can cause a short outage.
Metadata and source credentials survive in PostgreSQL; local scratch files do not.

Native attachment behavior is not an activation requirement. Comment attachments are
unavailable in the selected self-hosted Community deployment and are out of scope.
External sources keep schema editing disabled at all times; no temporary unlock is
permitted to configure Attachment fields. Remove the old upload/comment canary and its
`NC_SECURE_ATTACHMENTS=false` override. Do not claim that omitting native attachment
features disables every upload API in the application. Operators must not use NocoDB
local storage for durable files.

The current Community edition uses NocoDB's Sustainable Use License rather than an
OSI-approved open-source license. Internal self-hosted use is within the selected
deployment model. The design does not depend on Enterprise-only SSO or fine-grained UI
permissions.

## Metadata database

NocoDB uses a dedicated `nocodb` logical database in automation-data PostgreSQL. A
dedicated `nocodb_metadata` login owns and migrates only that database. It is not a
managed automation domain and is not entered in `managed_domains`.

The metadata database contains NocoDB users, workspaces, bases, source definitions,
encrypted source credentials, API tokens, views, and application configuration. The
metadata login cannot connect to domain databases or the automation-data control
database. Domain roles cannot connect to the NocoDB metadata database.

The existing automation-data backup discovers all non-template databases from the live
catalog, so it includes `nocodb` without a Git-managed database list. The globals dump
preserves the metadata login and its password verifier. Implementation must reconcile
specification 025 and its backup tests with this additional platform database.

## External artifacts and recovery

Workflow-generated files remain external to NocoDB. Each owning domain defines the
authoritative PostgreSQL records for durable artifact metadata and references to the
underlying file or object. Metadata can include a stable artifact identifier, storage
locator, object version, media type, byte size, and checksum as required by that workflow.
This feature does not impose a universal artifact schema or create another registry.

NocoDB may present those references as links. It does not ingest, copy, proxy, or own
the files. Durable records must not depend on an expiring signed URL or embed reusable
credentials. The storage owner controls access and any temporary download authorization.
Replacing NocoDB must not require moving files or rewriting authoritative artifact
identities.

Without native attachments, the initial deployment has no NocoDB attachment PVC or
Longhorn attachment-backup dependency. Use ephemeral application scratch storage and
prove that replacing it preserves users, bases, views, encrypted source credentials,
operator decisions, and artifact references through PostgreSQL.

NocoDB recovery restores a complete automation-data logical bundle containing the
`nocodb` database, domain databases, source registry, and global roles. It verifies saved
configuration, access, and durable artifact metadata/references. It does not recover or
claim to validate the underlying external file bytes. Each workflow/storage owner must
define its own file retention, backup, recovery, and reference-consistency checks.

Future native attachment UX requires a separate design change backed by a demonstrated
workflow need. That review must cover storage ownership, backup/recovery, replacement
portability, Community-edition support, and whether schema editing can remain disabled.

The SOPS-managed `NC_CONNECTION_ENCRYPT_KEY` is a recovery root. Losing or replacing it
can make stored source credentials unreadable even when the metadata database survives.
It is created once, retained through recovery, and never rotated as an ordinary
credential operation.

## Authentication and application configuration

NocoDB uses local email-and-password authentication. Community-edition SSO and its
coarse UI role model do not provide a useful security boundary for this design. The
PostgreSQL roles provide that boundary.

The guarded `mise exec -- just repo nocodb-secrets` workflow creates or updates one
SOPS-encrypted Secret containing:

- the metadata database connection and `nocodb_metadata` password;
- `NC_AUTH_JWT_SECRET`;
- `NC_CONNECTION_ENCRYPT_KEY`;
- the initial administrator email and password; and
- fixed webhook authentication material needed by the source-provisioning path.

The workflow never prints plaintext values or places them in command arguments, logs,
temporary tracked files, or commit messages. It retains an existing connection
encryption key unless the operator explicitly performs a separate recovery procedure.

The application sets:

- `NC_SITE_URL=https://nocodb.lab.supermorphic.com`;
- `NC_ALLOW_LOCAL_EXTERNAL_DBS=true` so the private PostgreSQL Service is an allowed
  source target;
- telemetry and support chat disabled; and
- no automation-created public shared views.

`NC_INVITE_ONLY_SIGNUP` is not a supported environment variable in NocoDB `2026.08.2`.
After the first administrator signs in, bootstrap uses that session JWT to call
`POST /api/v1/app-settings` with `invite_only_signup=true` and
`restrict_workspace_creation=true`, then reads the settings back through
`GET /api/v1/app-settings`. The application blocks API-token access to these endpoints,
so the bootstrap session must perform this step before it creates the long-lived API
token. The source workflow creates no shared base or view URL.

The local-database allowance is contained by egress policy and by a source workflow that
accepts no arbitrary hostname, port, database name, or credentials.

## Network contract

The `HTTPRoute`, `NC_SITE_URL`, and Gatus target all use
`nocodb.lab.supermorphic.com`. The route attaches only to the internal Gateway and uses
the repository's private TLS and DNS pattern.

Workload-scoped Cilium policy permits:

- internal-Gateway ingress to the NocoDB Service;
- n8n ingress to the same Service for fixed API operations;
- NocoDB egress to cluster DNS and the automation-data PostgreSQL Service;
- monitoring ingress or observation through the established service paths.

There is no general Internet ingress or egress. The metadata bootstrap Job receives only
DNS and automation-data PostgreSQL egress. The n8n workload gains only the NocoDB Service
and port as a new destination.

## Optional domain roles

Noco-enabled domains add one or two login roles:

| Role | Creation rule | PostgreSQL authority |
| --- | --- | --- |
| `<domain>_reader` | Enabled when the domain has a valid `read_model` schema | `CONNECT`, `USAGE` and `SELECT` only on `read_model` |
| `<domain>_operator` | Created as `NOLOGIN` when `operator` exists; enabled only after its controlled-edit grants exist | `CONNECT`, `USAGE`, and exact `SELECT` and DML grants only on `operator` |

Source sync creates the reader only after `read_model` exists, gives it the fixed schema
read contract, sets its transient password, and enables `LOGIN`. When `operator` exists,
source sync creates the operator as `NOLOGIN`; it remains unable to authenticate until
its controlled-edit grants pass validation. Source sync then changes only that attribute,
sets its transient password, and creates its source. Both roles are `NOSUPERUSER
NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS`. They cannot assume the
owner, migrator, runtime, provisioner, metadata, or backup role. `PUBLIC` privileges
cannot bypass these limits.

The reader receives `USAGE` on `read_model`, `SELECT` on its current tables and views,
and matching owner default privileges for later tables and views in that schema. It
receives no privilege on `app` or `operator`, no sequence use, and no DML, DDL,
ownership, or role membership. Domain migrations control the read surface by creating
reviewed projections in `read_model`; source sync can safely apply the fixed read grant
without accepting table or column input.

The operator does not inherit the reader surface. It receives grants declared by reviewed
domain migrations only on objects in `operator`. Those grants can include:

- `SELECT`, `INSERT`, and sequence use on dedicated decision, note, or override tables;
- `UPDATE` on an exact column list;
- `DELETE` only on tables whose rows are operator-owned state; and
- row-level security policies when a table requires row restrictions.

The platform provisioner never accepts a table, column, schema, grant, SQL fragment, or
row-policy expression from the webhook. After initial reader provisioning, a reviewed
domain migration grants the `NOLOGIN` operator candidate its business privilege surface.
Source sync reads PostgreSQL catalogs and refuses to enable that login or create its
source when it cannot prove that at least one controlled DML grant exists and that no
privilege extends outside `operator`. It also rejects forbidden role attributes,
ownership, schema-create, or cross-database authority.

NocoDB configures the reader source to reflect only `read_model`, with data editing and
schema editing disabled. It configures the operator source to reflect only `operator`,
with data editing enabled and schema editing disabled. Those settings make the UI match
the two broad access surfaces and reduce accidental writes; they do not promise that
Community edition represents every column-level grant in its editor. PostgreSQL denial
remains the independent security oracle rather than the normal way the UI distinguishes
the two surfaces.

### Domain schema evolution

Reviewed domain migrations remain the only DDL path. After a migration changes reflected
objects, validate its grants, explicitly refresh the affected source's schema metadata
through the supported NocoDB UI, and run source sync to validate identity and access.
Schema refresh is metadata reconciliation, not source recreation or credential rotation.
Preserve the existing base, integration, source, and saved views where their referenced
objects remain valid. Report incompatible renames or removals for attended review rather
than silently deleting views or widening grants. The initial implementation need not add
an automatic refresh endpoint to the provisioning webhook.

The local integration test must prove an additive table/column change, refresh, and
unchanged source identity. The guide must document the verified pinned-version UI steps
before this procedure is described as supported.

## Existing-platform upgrade

Initialization SQL runs only for an empty PostgreSQL data directory. It is not the
upgrade mechanism for the accepted platform. Provide one fixed, versioned additive
upgrade for the NocoDB extension, with the same extension definitions used by fresh
initialization. This is a control-schema upgrade, not a PostgreSQL engine upgrade or a
general migration service.

The upgrade must:

- validate the expected existing control schema and installed revision before mutation;
- serialize execution and apply its transactional schema/function changes atomically;
- install the source registry and exact function grants without recreating domains or
  changing existing owner, migrator, runtime, provisioner, exporter, or backup logins;
- revoke inherited `PUBLIC CONNECT` on the `postgres` and `template1` maintenance
  databases while preserving existing domain/object grants and password verifiers;
- record the installed revision and make an unchanged rerun a validated no-op;
- reject an unknown revision or incompatible partial state instead of overwriting it;
- preserve the platform-generation mechanism used by backup consistency checks; and
- read back the resulting schema, grants, existing domain identities, and revision.

Use a fixed, Git-reviewed operator-run lifecycle command for this existing-state
administration. Its bounded Job uses the existing platform credential by Secret
reference; neither an agent nor n8n receives broader credentials or an arbitrary SQL
execution surface. The command repeats deployed-source, target, backup, and revision
preconditions immediately before applying the reviewed upgrade. Its source and command
registration must exist and pass local tests before any operator invocation is published
as an available procedure.

The implemented revision is `026-nocodb-v1`. A single-row
`platform_operations.platform_schema_revision` table records it as platform migration
metadata. The fixed read-only oracle is
`platform_operations.read_platform_revision() RETURNS text`; the function also validates
the installed extension contract before returning the revision. Fresh initialization
and the upgrade both load `nocodb-extension.sql`. The operator command is
`AUTOMATION_DATA_UPGRADE_CONFIRM='upgrade:automation-data:nocodb-v1' mise exec -- just
kube automation-data-upgrade`. The catalog-only install preserves the platform
generation and existing domain rows. Because `capture_backup_state()` gains the
revision and source array in the same transaction, its before/after value still changes
across the install and prevents publication of a backup that spans the schema change.
The same shared SQL applies the two fixed maintenance-database restrictions for fresh
initialization and guarded upgrade. The revision oracle rejects later drift that restores
either `PUBLIC CONNECT` grant. Source isolation checks include every connectable database,
including a connectable template, and allow only the source's exact domain database.

Deploy backup compatibility before applying the upgrade. The updated backup path must
support both the exact accepted pre-extension schema and the upgraded schema while
NocoDB is staged. An absent optional registry is valid only for the recognized old
revision; malformed state or a missing registry in the upgraded revision is an error.
Old logical bundles remain restorable. An upgraded backup captures the source registry
and optional roles without changing ordinary domain readiness. For an oracle-validated
`026-nocodb-v1` capture only, `globals.sql` also records the two fixed maintenance
database `REVOKE` statements because `pg_dumpall --globals-only` and the non-creating
`postgres` restore do not preserve them. Baseline `025` bundle bytes and semantics remain
unchanged. NocoDB bootstrap refuses
to proceed until the extension revision and a post-upgrade backup have been validated.

Test the upgrade against a populated instance initialized from the accepted pre-extension
Git revision, not from the new initialization SQL. Prove data, role identity, grants,
and password verifiers remain unchanged without printing verifier values. Test backup
before and after upgrade, a no-op rerun, incompatible-state rejection, and isolated
restore of both bundle formats. A fresh-install test must converge to the same extension
contract.

## Platform registry and fixed functions

The automation-data control database adds runtime state for NocoDB without changing the
meaning of ordinary domain readiness. It uses one table rather than separate domain and
source registries:

`platform_operations.managed_nocodb_sources` has one row for each requested
`(domain, access_kind)`. It records role name, NocoDB base ID, integration ID, nullable
source ID, nullable source-creation job ID, state, operation generation, credential
generation, operation start time, successful validation time, and non-secret error data.

Rows reference `managed_domains`. Access kind is restricted to `reader` or `operator`,
and states are restricted to `awaiting_grants`, `provisioning`, `waiting_for_source`,
`ready`, `rotating`, or `error`. NocoDB IDs are opaque values rather than executable
input. Passwords and API tokens never enter this table.

A separate domain registry would duplicate the base ID, requested access, state,
generation, and error already represented by the source rows. Domain UI readiness is
therefore derived:

- no reader row means the domain is not Noco-enabled;
- a ready reader row with no operator row means read-only ready;
- a ready reader row plus an `awaiting_grants` operator row means reader ready and
  operator pending;
- ready reader and operator rows mean controlled-edit ready; and
- any active or error source state reports the corresponding incomplete domain state.

The reader row establishes the canonical base ID. An operator row must use that same ID,
which the fixed recording function validates before writing it. This is enough state to
resume an interrupted asynchronous source creation without a second table.

The existing `automation_data_provisioner` login gains execute access only to fixed
NocoDB functions that:

- create or reconcile a requested reader or operator role;
- set or rotate that role's transient password;
- validate its catalog privileges;
- record NocoDB base, integration, source-creation job, and source identifiers;
- advance a source operation state or record a non-secret failure; and
- read the expected source state for a named managed domain and access kind, including
  the stored job and object identifiers required for deterministic resume.

Function bodies use fixed identifiers derived from a validated domain and fixed access
kind. Public execution is revoked. The functions expose no arbitrary SQL, grants,
database creation, role deletion, base deletion, or domain decommissioning.

Specification 025, the provisioner workflow contract, backup capture, and restore
validation include these optional roles and the single source registry. The source rows
remain in the restored `automation_data_control` database; `registry.tsv` continues to
describe managed domains rather than duplicating NocoDB object identifiers.

## Bootstrap workflow

Initial NocoDB setup is an exceptional initialization operation:

```sh
mise exec -- just repo nocodb-secrets
NOCODB_BOOTSTRAP_CONFIRM='bootstrap:nocodb' mise exec -- just bootstrap nocodb
```

The first command writes only the guarded SOPS-encrypted repository Secret. The second is
operator-run because it reads sensitive runtime material and administers private NocoDB
and n8n APIs. It performs this fixed transaction:

1. Capture the remote `main` SHA once, validate the complete tracked checkout against
   that immutable SHA, render the package, and require Flux to report the same revision
   immediately before and after each reconcile. Neither reconcile requests a mutable
   source refresh.
2. Prove that issue-317 bootstrap, provisioning acceptance, a current complete backup,
   and the full-chain restore drill have passed for the relevant platform implementation.
   Also require the installed NocoDB extension revision and a complete post-upgrade
   backup. Evidence records its original Git SHA; a later unrelated repository commit
   does not by itself invalidate it. Reuse is permitted only when the relevant platform
   source trees and shared lifecycle dependencies are identical and current observational
   prerequisites pass. Changed platform or recovery code requires new affected evidence.
   The newest applicable restore evidence must be newer than the applicable provisioning
   acceptance. Retain exact deployed-source checks for the command being executed.
   A fixed ephemeral preflight Job uses the existing backup Secret by reference. In a
   read-only transaction it calls `read_platform_revision()` and accepts only
   `026-nocodb-v1` with the singleton complete logical backup timestamp at or after the
   singleton revision installation timestamp. The command removes only its exact
   run-marked Job and repeats this check after the parent reconcile before NocoDB resume.
3. Repeat the source, target, Secret-shape, live suspension, and prerequisite checks
   immediately before mutation.
4. Temporarily reconcile the staged NocoDB package and run the fixed metadata bootstrap
   Job. The Job creates or reconciles only the `nocodb` database and
   `nocodb_metadata` login from the encrypted Secret.
5. Wait for NocoDB rollout and health at `/api/v1/health`.
6. Sign in with the SOPS-managed bootstrap administrator.
7. Set and read back the application settings that require
   invite-only signup and restrict workspace creation to the super administrator.
8. Reconcile the n8n credential named **NocoDB Operator API**. If it is absent, create a
   fresh NocoDB token with the exact bootstrap-managed description
   `NocoDB Operator API bootstrap/v1` and send it directly to the n8n credential API. If
   one prior bootstrap token exists without the n8n credential, classify it as an
   unrecoverable orphan, preserve it, create one replacement, and report only the
   orphan's non-secret ID for later revocation in NocoDB. More than one orphan is a hard
   stop that prevents unbounded broad-token accumulation.
9. Before discarding the in-memory token, test it directly against a fixed NocoDB
   source-list endpoint. Then read the created n8n credential back through the public API
   and require the expected non-secret ID, name, and `httpHeaderAuth` type. n8n `2.36.7`
   does not expose its stored generic Header Auth probe through API-key authentication;
   the attended source workflow acceptance is the independent proof that n8n can use the
   stored credential.
10. Return only non-secret resource IDs, readiness, and next operator steps.

Secret values travel through standard input, request bodies, and process memory. They do
not appear in arguments, shell tracing, logs, saved workflow executions, or command
output. The NocoDB Community API token is non-expiring and has broad application access.
Restricting the workflow to fixed endpoints is a workflow contract, not a cryptographic
scope on that token.

The operator imports the secret-free source-provisioning workflow, binds **Automation
Data Provisioner**, **NocoDB Operator API**, and the fixed webhook header credential,
then publishes it. The bootstrap command does not guess or silently change workflow
bindings.

The temporary resume uses an ownership marker and resource-version precondition. On
failure, bootstrap re-suspends only the Kustomization mutation carrying its marker and
preserves the database, metadata, and API state for diagnosis and retry. It does not
delete or regenerate a connection encryption key, administrator, token, or n8n credential
as compensation. A retry reconciles the credential from observed state and permits at
most one preserved orphan-token replacement as described above. Bootstrap keeps cleanup
armed until a live read-back proves marker removal and the intended active state.

There is no separate bootstrap-token recovery command. A rare lost token response is
handled by the bounded bootstrap rerun above. The source credential rotation command
rotates a selected PostgreSQL reader or operator login; it does not recover or rotate the
broad NocoDB API token stored by n8n.

## Source provisioning workflow

Ongoing source management is a private n8n workflow invoked by a purpose-specific
lifecycle command:

```sh
NOCODB_SOURCE_SYNC_CONFIRM='sync:nocodb:<domain>' \
  mise exec -- just kube nocodb-source-sync <domain>
```

The command and webhook accept only one existing managed-domain identifier. Access mode
is derived from the domain's catalog privileges; arbitrary source targets and grants are
not inputs. One NocoDB workspace named **Automation Data** contains one base per enabled
domain. Each base contains a reader source and, when eligible, an operator source. Names
are deterministic:

- base: `<domain>`;
- integration: `automation-data/<domain>/<access-kind>`; and
- source alias: `Read Model` or `Operator`.

The reader request restricts PostgreSQL reflection to `read_model`; the operator request
restricts it to `operator`. NocoDB permits only one source-creation job at a time for one
base, so the workflow completes reader creation before it can queue operator creation.

Source sync performs this idempotent state machine:

1. Validate the domain and require its existing automation-data state to be `ready`.
2. Inspect catalogs through fixed functions. Require `read_model`; treat `operator` as an
   optional controlled-edit request.
3. Create or reconcile `<domain>_reader` with the fixed read-model grants. When
   `operator` exists, create `<domain>_operator` as a `NOLOGIN` grant target. If reviewed
   operator grants already pass validation, enable the operator login. Otherwise record
   `awaiting_grants`, leave it unable to authenticate, and omit its NocoDB source.
4. For each eligible source, reconcile the deterministic NocoDB base, inspect any
   existing integration and registry row, and list the base's current sources before
   changing credentials or queueing work. A stored `waiting_for_source` job takes
   precedence over source discovery and resumes at step 8.
5. If exactly one source already matches the deterministic integration and alias, read it
   by ID and continue with validation. Zero matches permits creation; more than one is a
   hard error that requires attended repair.
6. For a new or failed initial source generation, require that the base has no matching
   or conflicting source, mark `provisioning`, generate a
   password in workflow memory, pass it to the fixed PostgreSQL function, and create or
   update the matching NocoDB integration with the same credentials. Creation uses
   `POST /api/v2/meta/workspaces/:workspaceId/integrations`; update uses
   `PATCH /api/v2/meta/integrations/:integrationId`. Record the integration ID, list the
   base sources again, and bind the queue decision to that current integration ID. The
   second list must still contain no matching or conflicting source before creation is
   queued. A ready source never enters this branch.
7. Call `POST /api/v2/meta/bases/:baseId/sources`, require an HTTP 200 body containing
   exactly one job ID, store that ID, and mark the row `waiting_for_source`. The response
   is queue acceptance, not source readiness.
8. Poll `POST /api/v2/jobs/:baseId` with the `source-create` job filter every five seconds
   for at most ten minutes. Select the exact stored job ID. Treat `completed` and
   `failed` as terminal; every other reported state remains nonterminal until the bound.
9. On `failed`, record a non-secret error and stop. On timeout, retain the job ID and
   `waiting_for_source` state so retry resumes polling instead of queueing a duplicate.
   A missing stored job is a hard error, not permission to queue another.
10. On `completed`, list the base sources and require exactly one match on both the
    deterministic integration ID and alias. The job result does not supply the source
    ID, so this discovery step is mandatory.
11. Read the discovered source through
    `GET /api/v2/meta/bases/:baseId/sources/:sourceId`. Verify its base, integration,
    alias, reflected schema, data-edit flag, and schema-edit flag before recording the
    source ID. The integration comparison uses the current integration selected during
    the immediately preceding source discovery, not a stale pre-run registry value.
12. List the base's reflected tables, select a table that belongs to the exact source ID,
    and perform a bounded normal data read through
    `GET /api/v2/tables/:tableId/records?limit=1`. Require the expected HTTP 200 record
    list and page metadata. Then independently test the expected PostgreSQL privilege
    matrix.
13. Mark the source generation `ready` only after all asynchronous, read-back, and access
    checks succeed. Return only non-secret IDs, access kinds, states, and timestamps.

The bounded source response also includes the stored job ID and currently observed job state,
credential generation, source UI edit flags, and the boolean PostgreSQL validation matrix
used for readiness. Attended acceptance uses this non-secret evidence to compare unchanged
sync and targeted rotation without reading the registry or credentials directly.
Each source result names these as `sourceCreateJobId`, `sourceCreateJobState`,
`credentialGeneration`, `dataEditAllowed`, `schemaEditAllowed`, and
`postgresqlValidation`. It also returns `sourceDiscovered`, `sourceReadBack`, the registry
`generation`, and supported `operationStartedAt`, `updatedAt`, and `validatedAt`
timestamps. The command and workflow share one explicit response contract, and a
cluster-independent test executes the real response-producing Code node and passes its
output to the command's validator. Unknown fields or changed types must not drift between
handcrafted fixtures and the real response.

A first transition to `ready` requires the exact creation job to complete, followed by
source discovery, GET, data API, and PostgreSQL validation. The stored source ID and
successful validation record retain that transition's evidence. Subsequent ready syncs
and rotations require fresh source identity, data API, and PostgreSQL checks, but must
not require historical job-list visibility. NocoDB's pinned job-list service omits
completed jobs older than one hour. Retain `sourceCreateJobId` for traceability;
`sourceCreateJobState` is null when not observed in the current operation, not a fabricated
fresh `completed` observation. Acceptance distinguishes creation evidence from current
source validation and tests normal operation after completed jobs age out.

The workflow uses execution order `v1` and disables saved manual, successful, failed, and
progress execution data. Passwords exist transiently in n8n memory because both systems
must receive the same generated value.

Each five-second polling delay remains below n8n's 65-second threshold for offloading a
Wait execution to its database. The workflow must not replace the polling loop with a
long Wait that persists execution data. A NocoDB or n8n pod restart can interrupt the
in-memory loop. The next explicit sync can resume polling only while the stored job is
still observable. The fallback queue does not guarantee that interrupted work survives
a restart. A missing job for a source not yet recorded ready remains an attended
investigation case; it is not proof of failure or permission to queue another source.
An established ready source does not depend on that queue history. No password is
retained in n8n execution history to support retry.

The workflow never calls a source-delete endpoint as compensation. NocoDB `2026.08.2`
can delete its own partially created source when the source-creation processor reports
an error; the registry still retains the failed job and generation. The next explicit
sync first proves that no source has the deterministic alias and that no source uses the
retained integration, then may start a new initial generation and set a replacement
password because no ready contract exists. A surviving error-state or partial alias
requires attended cleanup under the decommission boundary before retry. A timeout with a
nonterminal job is not a failed generation and only resumes polling.

Once a source is `ready`, sync preserves its PostgreSQL verifier, NocoDB encrypted
credential, source ID, and integration ID. A missing ready-side object is an error that
requires explicit rotation or repair; ordinary sync does not silently replace it.

Credential rotation is separate and target-bound:

```sh
NOCODB_SOURCE_ROTATE_CONFIRM='rotate:nocodb:<domain>:operator' \
  mise exec -- just kube nocodb-source-rotate <domain> operator
```

The final argument is restricted to `reader` or `operator`. The workflow preserves that
normalized requested access kind separately from the reader or operator branch currently
being evaluated, so one target can never enter or resume the other target's rotation.
Rotation repeats readiness and source-identity checks immediately before mutation,
updates PostgreSQL and the same NocoDB integration, tests authentication and denials, and
reads back the new generation.
It is convergent, not transactional. The PostgreSQL function records `rotating` with
`operation=rotate`, increments the credential generation, and changes the selected role
with `ALTER ROLE ... LOGIN ... PASSWORD`; it does not set the role to `NOLOGIN`. If a
later workflow step fails, the handled error records `state=error` while retaining
`operation=rotate` and the exact base, integration, and source IDs. PostgreSQL can then
have the new verifier while NocoDB still has the old credential. A later explicit
rotation may replace both sides again only when all three retained IDs match current
NocoDB state. Ordinary sync, a different access kind, or any missing or mismatched
identity is rejected. An error from initial source creation remains a separate case and
can retry only after proving that the base contains zero matching or conflicting
sources; a surviving partial alias requires attended cleanup first.

The workflow exposes no operation that deletes a source, base, login, registry row, or
domain. NocoDB's internal cleanup of a partial failed source is the only automatic source
deletion in this lifecycle. Future decommissioning requires a separate attended design.

The workflow's NocoDB request allowlist is exact. In addition to the fixed workspace,
base, integration, source, and job endpoints above, normal access checks may use only
`GET /api/v2/meta/bases/:baseId/tables` and
`GET /api/v2/tables/:tableId/records`. The workflow does not send data writes as its
reader authentication check.

The synthetic acceptance probe also reads
`GET /api/v2/meta/bases/:baseId/shared` and each reflected table's
`GET /api/v2/meta/tables/:tableId/share` collection. It requires a null base share UUID
and empty shared-view collections. It never creates, changes, or deletes a share. A
successful probe returns only the resulting bounded public-sharing evidence and identifies
the n8n `NocoDB Operator API` credential path; it does not restate the PostgreSQL source
validation matrix as if the acceptance data API calls had measured it.

Every successful synthetic `probe` establishes or verifies persistent PostgreSQL canary
records and the exact observed base, source, table, and default-view identities. Use
reserved synthetic identities that normal run cleanup cannot select. The records include
an operator decision and bounded artifact metadata with a durable synthetic external
reference; acceptance and restore read these values back independently.

This is a record/reference recovery test, not an external storage service test. Synthetic
references use documentation-only targets and are not fetched. Do not upload a file,
create a comment attachment or FileReference, download `/download/*`, add an Attachment
field, or relax source schema flags. Remove the obsolete upload state machine rather
than retaining it as a fallback. Idempotent initialization and subsequent readback must
preserve the same canary, artifact, and saved-view identities across reruns and recovery.

## Command lifecycle

The command surface follows specification 021:

| Command | Effect profile | Confirmation |
| --- | --- | --- |
| `mise exec -- just kube nocodb-validate` | Local source validation | None |
| `mise exec -- just kube nocodb-verify` | Read-only live observation | None |
| `mise exec -- just repo nocodb-secrets` | Guarded encrypted artifact creation | Purpose-specific guard in the workflow |
| `mise exec -- just bootstrap nocodb` | First activation and initialization | `bootstrap:nocodb` |
| `mise exec -- just kube nocodb-source-sync <domain>` | Existing-state reconciliation through private APIs | `sync:nocodb:<domain>` |
| `mise exec -- just kube nocodb-source-rotate <domain> <kind>` | Credential administration | `rotate:nocodb:<domain>:<kind>` |
| `mise exec -- just kube nocodb-access-test` | Bounded synthetic experiment | `test:nocodb:access` |
| `mise exec -- just kube nocodb-restore-drill` | Isolated recovery experiment | `restore:nocodb:metadata` |

`verify` does not read Secrets, call source credentials, mutate APIs, or perform a
positive authorization probe. Mutation commands check deployed-source parity, bind
confirmation to their exact target, repeat safety-critical preconditions immediately
before mutation, and read back the requested postcondition. There is no separate plan
command because these fixed operations have no reusable or independently reviewable
change plan.

## Monitoring and logs

Gatus checks `https://nocodb.lab.supermorphic.com/api/v1/health` through the private
route. Application logs flow through the existing Alloy collection path.

Monitoring enrollment follows intended activation. The staged package must not enable
an unavailable-endpoint check, expected-absence alerts, or recurring NocoDB verification
campaign membership. Enable the endpoint, rule selection, and campaign membership with
the reviewed durable activation change. Their source definitions and offline tests may
exist before enrollment. Attended bootstrap and acceptance verify the temporary active
workload directly; they must not require monitoring that is deliberately unenrolled.
After durable activation, absence is an outage and must not silently skip verification.

Prometheus alerts cover:

- unavailable Deployment or health target;
- repeated restarts and OOM kills; and
- failed or overdue metadata bootstrap or acceptance Jobs.

Existing automation-data SQL Exporter metrics cover metadata-database size, connections,
transactions, backup freshness, and catalog consistency. NocoDB does not expose a
supported Prometheus endpoint, so the design does not add a speculative ServiceMonitor.

## Validation strategy

### Cluster-independent validation

`mise exec -- just ci` remains the canonical pre-PR gate. Focused NocoDB validation is
available through:

```sh
mise exec -- just kube nocodb-validate
```

It reuses repository-wide Helm, Kustomize, Kubernetes-schema, policy, Secret-shape,
ShellCheck, formatting, link, and gitleaks checks. New independent assertions cover:

- immutable chart and image digests;
- one replica, `Recreate`, disabled worker and Redis, and no NocoDB PVC dependency;
- exact private route and application URL;
- no runtime, migrator, owner, provisioner, or backup credential reference;
- fixed source operations and absence of arbitrary SQL or target fields;
- one source registry table with resumable source-creation job state;
- asynchronous create, bounded job polling, unique source discovery, and read-back before
  `ready`;
- distinct `read_model` and `operator` reflection and privilege surfaces;
- reader/operator role attributes and forbidden privileges;
- no ordinary-sync credential replacement for a ready source; and
- no career-domain artifact.

CI does not start NocoDB or PostgreSQL, create a source, test live privileges, or perform
a restore.

### Disposable local integration

Before cluster activation, run a separate registered, agent-owned local integration test
through the pinned toolchain using Podman. Keep it outside `just ci`; it needs a working
local container runtime but no cluster access, production credentials, or age key.
Use the repository's pinned application versions, synthetic data and generated local
credentials, run-owned containers, a private container network, and temporary storage.
Bind any required host port only to loopback. Disable saved provisioning execution data
and redact results; do not publish credential-bearing container or HTTP logs.

The test exercises the actual PostgreSQL definitions, imported n8n workflows, NocoDB API,
and source-command response validation together. It proves:

- populated-platform upgrade and fresh-install equivalence, including backup/restore;
- first-run domain provisioning before the migrator credential is bound to acceptance;
- reader creation, operator grant phase, and operator creation through real async jobs;
- the workflow fact, human decision, workflow consumption, and refresh-preservation loop;
- unchanged sync and targeted rotation after job-history expiry;
- ready-source behavior after application restart, plus fail-closed interrupted creation;
- additive schema refresh without changing source identity or credentials;
- durable operator and artifact-reference records plus saved-view persistence after
  application scratch replacement and recovery; and
- removal of only run-owned containers, networks, and storage, with absence read-back.

Use synthetic aged-job fixtures in the fast contract tests and real aged job metadata in
the disposable environment; do not alter the host clock or production metadata. A local
test does not replace attended proof of the private Gateway, Cilium policy, or live
metadata backup/recovery. Record local and live evidence separately.

### Read-only live verification

```sh
mise exec -- just kube nocodb-verify
```

The verifier observes Flux readiness, Deployment rollout, Service endpoints, private
route, Gatus, Prometheus rules, workload policy, and current automation-data backup
freshness. It does not read application metadata, inspect Secrets, authenticate to
NocoDB, or alter target state.
Before monitoring enrollment, an explicitly invoked verifier checks the staged/attended
phase against Git intent and reports that phase, rather than claiming durable activation.
It must distinguish intentional inactivity from failure of an intended active service.

### Attended access test

```sh
NOCODB_ACCESS_TEST_CONFIRM='test:nocodb:access' \
  mise exec -- just kube nocodb-access-test
```

The test uses a dedicated synthetic automation-data acceptance domain. Its base, sources,
and registry rows remain as recovery canaries; data mutations within them use a unique
run ID and cleanup never broadens beyond those rows. It proves:

On a first run where the synthetic domain does not exist, the command invokes the fixed
automation-data provisioner first and reports the generated non-secret migrator
credential ID. It stops before the acceptance workflow until the operator explicitly
binds that credential and supplies a confirmation containing the same ID. A rerun still
validates the idempotent provisioning response before invoking acceptance; the command
never edits or publishes n8n workflow bindings.

1. exactly one NocoDB application pod is ready, no worker workload exists, and no Redis
   URL or Redis workload is configured;
2. source sync creates a reader source and an eligible operator source without a Git,
   SOPS, Flux, or NetworkPolicy change;
3. each create response yields a job ID, the workflow observes that exact job reach
   `completed`, then discovers exactly one source and reads it by ID before recording
   `ready`;
4. reader creation completes before operator creation in the same base;
5. source GET metadata reports only the reader `read_model` search path. The pinned table
   API returns `schema: null`; bind each table to its exact source ID and that validated
   search path rather than guessing a schema from the null field. The reader reflects
   exactly its `acceptance_facts` table with no unexpected table, and its normal fact query
   succeeds through the NocoDB data API;
6. source GET metadata reports only the operator `operator` search path. Resolve the
   pinned null table schema through that exact source identity as above. The operator
   reflects exactly its `acceptance_decision` table with no unexpected table, and normal insert, read,
   approved-column update, and run-owned delete operations succeed. The pinned table-list
   endpoint returns its complete list without pagination; if it supplies page metadata,
   the test also requires the returned row count to be complete and `isLastPage=true`;
7. a unique run-bound reader insert fails with NocoDB's stable read-only authorization
   response, while reader DDL, role assumption, and cross-database access also fail;
8. operator update of a protected column fails with PostgreSQL SQLSTATE `42501` exposed
   through NocoDB's stable database-operation denial, while access outside `operator`,
   DDL, role assumption, and cross-database access also fail;
9. NocoDB reports data editing disabled for the reader, enabled for the operator, and
   schema editing disabled for both;
10. unchanged sync is idempotent and does not alter ready credential generations, job
    IDs, source IDs, or integration IDs;
11. explicit rotation restores one working source without revealing its password; and
12. every successful probe creates or verifies persistent decision/artifact-reference
    canaries, including their exact PostgreSQL values and saved-view identities, without
    uploading or fetching files or enabling native Attachment fields; and
13. cleanup pages through and deletes at most 1,000 matching rows for the current run,
    then reads again to prove their absence while retaining the synthetic recovery
    canary. Any unexpectedly permitted reader insert is also deleted by its unique ID
    before the test reports failure.

Acceptance also demonstrates the human-feedback loop, schema refresh, aged-job sync,
and ready-source restart behavior defined above. Include an attended browser check that
the reader is visibly read-only and an operator can make the intended small edit. API
checks alone do not establish the usability of this operator interface.

The PostgreSQL denials are the independent authority oracle. UI flags alone cannot pass
the test. Fixed acceptance setup, grants, and residue-cleanup SQL runs through the
NOINHERIT migrator credential and explicitly uses the fixed
`SET LOCAL ROLE issue334_acceptance_owner` command inside each transaction.

### Attended restore drill

```sh
NOCODB_RESTORE_CONFIRM='restore:nocodb:metadata' \
  mise exec -- just kube nocodb-restore-drill
```

The isolated drill uses a complete automation-data logical bundle. It proves:

1. restored NocoDB metadata, global roles, source registry, and catalogs agree;
2. the retained connection encryption key decrypts the restored source credentials;
3. restored reader and operator sources authenticate to the distinct `read_model` and
   `operator` schemas of an isolated restored synthetic domain and retain the expected
   privilege denials;
4. a saved base and view remain available;
5. authoritative operator decisions and durable artifact metadata/references survive;
6. the restored automation-data service can publish a fresh complete logical bundle; and
7. all run-owned workloads, Services, policies, and temporary claims are removed and
   proved absent.

Runtime-created Jobs resolve the exact generated backup ConfigMap selected by the
accepted deployed workload and validate its expected script keys. They must not use an
unhashed generator name or select an arbitrary stale ConfigMap. There is no NocoDB
attachment volume restore or paired file-backup selection. Any temporary PostgreSQL
storage follows the existing automation-data restore contract.

The restore drill never points restored NocoDB at the live domain service and never
overwrites the running metadata database or authoritative domain data.

## Rollout

Rollout follows dependency and authority order:

1. Reconcile with the active platform baseline. Implement the additive upgrade, backup
   compatibility, source lifecycle fixes, staged monitoring, and local integration test.
2. Pass focused validation, disposable Podman integration, and `mise exec -- just ci`.
   Review and merge only with specific operator authorization. Keep NocoDB suspended
   and its monitoring and recurring verification unenrolled.
3. Verify current platform prerequisites. Apply the fixed reviewed control-schema
   upgrade through its operator-run command, then validate a complete post-upgrade
   backup and the affected platform acceptance/recovery evidence.
4. Create and merge the guarded SOPS-encrypted NocoDB Secret while NocoDB remains
   suspended. Do not repeat platform acceptance solely because an unrelated Git SHA
   changed; verify relevant-source equivalence and current prerequisites.
5. From deployed `origin/main`, run the confirmed NocoDB bootstrap command.
6. Import, bind, and publish the private source workflow. Provision the synthetic domain
   before binding its existing migrator credential to the acceptance workflow; publish
   that workflow only after every required credential exists and is bound.
7. Run access and browser acceptance. Wait for a complete automation-data logical backup
   containing NocoDB metadata, source state, and the persistent domain canaries.
8. Run the confirmed NocoDB metadata restore drill.
9. After acceptance passes, make the reviewed Git activation change: set NocoDB's
   `spec.suspend: false`, enroll its monitoring and recurring verification together,
   verify their active behavior, and record dated results in this specification.

Initial administrator login, n8n credential binding, workflow publication, and commands
that read sensitive runtime state or call administrative APIs remain attended operator
actions. Agent-owned implementation, local validation, and approved scoped observation
remain agent-run under repository policy.

## Failure handling

- A NocoDB outage does not block n8n domain workflows or direct PostgreSQL access.
- A failed bootstrap preserves the database and API objects and re-suspends only
  state that bootstrap resumed.
- A failed source operation records non-secret state and retains its registry row,
  operation, job ID, role, base, integration, and source identity for deterministic
  retry. NocoDB can remove only the partial source created by its failed job. Failed
  rotation retries require exact retained identity; failed initial creation retries
  require zero sources.
- A ready credential changes only through explicit targeted rotation or attended repair.
- Loss of NocoDB metadata can be recovered from automation-data logical backup. Local
  scratch loss is expected on replacement and must not lose supported durable state.
- A missing or unavailable external artifact is a workflow/storage-owner recovery issue;
  NocoDB neither owns the file nor repairs its reference automatically.
- Loss of `NC_CONNECTION_ENCRYPT_KEY` cannot be repaired from the metadata database. The
  operator must restore the retained Secret. If the key is permanently lost, a
  separately reviewed recovery must establish replacement encryption material and rotate
  each reader or operator source explicitly; no broad automatic recovery exists.
- The workflow does not use source, base, registry, or role deletion as compensation or
  cleanup.

## Implementation status

As of 2026-09-05, the repository contains the staged NocoDB package, optional
automation-data roles and single source registry, secret-free n8n workflows, lifecycle
commands, monitoring, offline contract tests, operations guide, and recovery runbook.
The NocoDB Flux Kustomization is selected by its parent and remains
`spec.suspend: true`. No NocoDB bootstrap, source sync, access acceptance,
or restore drill has run against the live cluster. No active service or recovery
capability is claimed.

The 2026-09-05 integration audit revised this design after the initial implementation.
The fixed existing-platform upgrade and old/new backup compatibility pass disposable
populated PostgreSQL upgrade, rerun, fresh-equivalence, and isolated restore tests.
Shared response validation, generated restore references, activation-aware monitoring,
and bootstrap evidence fixes are implemented. Local real-component tests prove source
creation, sync after job-history expiry, application restart, selected operator rotation,
and additive metadata refresh with existing table/view identity preserved. Full CI passes
at `d201d6f5b67019f02fe021ee72082d772f543577`. These results are not live acceptance.

On 2026-09-07 the repository implementation removed native attachments from the initial
scope without relaxing source schema-readonly flags. The acceptance path uses exact
PostgreSQL decision and artifact-reference records. The application now uses ephemeral
scratch, has no NocoDB claim or volume alert, and recovery uses one complete logical
bundle with isolated 20 GiB PostgreSQL and fresh NocoDB scratch. The drill retains exact
source routing, credential, view, record, bundle, ownership, and cleanup checks. It does
not select an attachment backup or fetch external artifact bytes.

On 2026-09-07, the disposable full-stack integration passed twice against the pinned
PostgreSQL, n8n, and NocoDB images. It imported and bound the actual workflows, exercised
the complete feedback loop, aged completed jobs, resumed an interrupted initial source
creation, retained source and saved-view identity through additive metadata refresh,
replaced the NocoDB container and scratch, and restored a checksum-valid complete logical
bundle into separate PostgreSQL and fresh NocoDB instances. The restored source was
forced to the separate PostgreSQL address while the original PostgreSQL was stopped;
retained credentials, denials, records, views, references, and a new checksum-valid
backup passed. Run-owned resources were absent after each run.

This local evidence does not establish live Gateway or Cilium behavior, Longhorn
recovery, or browser usability. Attended cluster acceptance and activation remain
outstanding. No native attachment workaround or live activation has been performed. The
transient execution plan remains under `.tmp/plans/026-nocodb-operator-ui.md`; it is not
a committed design artifact.

## Rejected alternatives

### NocoDB runtime or migrator credentials

Reusing an existing domain credential would be simpler but would grant broader CRUD or
DDL than the UI needs. Dedicated reader and operator roles make UI authority explicit
and independently rotatable.

### NocoDB UI permissions as the boundary

Community UI controls can reduce mistakes but cannot replace database enforcement. A
source API call or application defect could bypass UI intent. PostgreSQL grants and row
policies are required.

### Read-only UI

A fully read-only interface would not support the small corrections, decisions, and
notes that justify an operator UI. The separate operator source permits only the domain's
reviewed DML surface.

### General-purpose UI editing

Giving NocoDB full runtime CRUD would make accidental bulk edits possible and blur the
boundary with n8n. Operator editing remains narrow; bulk and universal changes remain
workflow operations.

### Manual source onboarding

Displaying generated database passwords for manual entry would create plaintext handling
and configuration drift. The n8n workflow sends transient credentials directly to the
fixed NocoDB API.

### NocoDB provisioning outside n8n

A custom broker or one-off administrative script would add a separate credential and
state machine. The existing automation-data provisioner pattern can safely add this
fixed, opt-in operation while PostgreSQL functions retain authority.

### NocoDB-native attachment storage in the initial surface

Native attachments are not required for the initial operator surface. Comment attachments
are unavailable in the selected Community deployment, and configuring Attachment fields
must not relax the external-source schema-read-only boundary. The earlier retained
10 GiB attachment PVC and paired-backup requirement are superseded by external artifact
ownership and PostgreSQL reference records. Ephemeral application scratch storage is
appropriate only because supported durable state lives outside it.

### Two application replicas

Multiple application replicas and Redis are not justified for this operator-only
service. One application replica remains proportional to the workload.

### Separate object storage

Adding MinIO or another S3-compatible service only for NocoDB would introduce storage
ownership and recovery obligations outside this feature. Workflow owners select and
operate their artifact storage independently.

### Native Kubernetes manifests

Native manifests would avoid Helm but duplicate the supported chart's workload,
configuration, probe, and application-version conventions. The official chart with
explicit repository-owned overrides is the smaller maintenance surface.

## Review triggers

Revisit this design when a workflow demonstrates a need for native attachment UX; more
than one application replica becomes necessary; NocoDB changes its source API, license,
token scopes, or metadata schema; Enterprise SSO or permission features become available;
or the number of enabled domains makes one workspace operationally difficult. Any native
attachment proposal must satisfy the separate design review described above.

After live rollout or recovery changes, reconcile this specification with actual chart
and image pins, API behavior, role grants, Secret keys, backup coverage, command names,
and dated acceptance results.

## External references

- [NocoDB Kubernetes installation](https://nocodb.com/docs/self-hosting/installation/kubernetes)
- [NocoDB environment variables](https://nocodb.com/docs/self-hosting/environment-variables)
- [NocoDB backup guidance](https://nocodb.com/docs/self-hosting/maintenance/backups)
- [NocoDB self-hosting and license](https://nocodb.com/docs/self-hosting)
- [NocoDB `2026.08.2` source controller](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/controllers/sources.controller.ts)
- [NocoDB `2026.08.2` asynchronous source-create controller](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/modules/jobs/jobs/source-create/source-create.controller.ts)
- [NocoDB `2026.08.2` source-create processor](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/modules/jobs/jobs/source-create/source-create.processor.ts)
- [NocoDB `2026.08.2` job-list controller](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/controllers/jobs-meta.controller.ts)
- [NocoDB `2026.08.2` job-list retention](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/services/jobs-meta.service.ts)
- [NocoDB `2026.08.2` fallback jobs service](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/modules/jobs/fallback/jobs.service.ts)
- [NocoDB `2026.08.2` API-token controller](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/controllers/api-tokens.controller.ts)
- [NocoDB `2026.08.2` application-settings contract](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/interface/AppSettings.ts)
- [NocoDB `2026.08.2` application-settings controller](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/controllers/org-users.controller.ts)
- [n8n Wait node persistence behavior](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.wait/)
- [PostgreSQL 17 privileges](https://www.postgresql.org/docs/17/ddl-priv.html)
- [PostgreSQL 17 role attributes](https://www.postgresql.org/docs/17/role-attributes.html)
- [Automation-data PostgreSQL specification](025-automation-data-postgresql-platform.md)
- [Repository command lifecycle](021-repository-command-lifecycle.md)

## Pull request linkage

Every pull request produced by this initiative links
[GitHub issue 334](https://github.com/supermorphic/homelab-talos/issues/334) in its
description. Partial pull requests use `Related to #334`. Only the pull request that
finishes the accepted issue scope uses `Closes #334`.
