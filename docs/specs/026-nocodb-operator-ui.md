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

The current registry and provisioning functions manage only the migrator and runtime
login credentials. The automation-data Flux Kustomization is still suspended, and live
acceptance has not run. This specification therefore defines a source extension and a
dependency gate; it does not assume that the underlying platform is operational.

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
- Preserve NocoDB metadata, encrypted source credentials, saved configuration, and local
  attachments through the established backup systems.
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
- Zero-downtime application upgrades, transactionally synchronized PostgreSQL and PVC
  backups, or application high availability.
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

Removing the NocoDB Deployment, metadata database, or PVC must not remove or invalidate
domain databases, domain migrations, or normal n8n credentials. Reinstalling NocoDB can
recreate its metadata and sources from backups and the provisioning contract.

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
      |-- operator source --> <domain>.operator as <domain>_operator
      `-- attachments --> retained 10 GiB Longhorn PVC

operator lifecycle command
      |
      v
private n8n NocoDB source-provisioning workflow
      |-- fixed automation-data SECURITY DEFINER functions
      `-- fixed NocoDB source API operations
```

The NocoDB application package contains:

- one official Helm release;
- one separately declared, prune-protected attachment PVC;
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
- a `ClusterIP` Service;
- chart Ingress and chart NetworkPolicy disabled in favor of repository patterns;
- the external PostgreSQL URL and both auth keys from an existing Secret; and
- `persistence.existingClaim` bound to the separately declared PVC.

One pod is intentional. The retained `ReadWriteOnce` claim can attach to only one node at
a time. With the worker disabled and Redis absent, NocoDB runs source-creation jobs in the
application pod's fallback queue. Attended acceptance must prove that this mode completes
source creation and supports normal operator read and write behavior. `Recreate` satisfies
the repository invariant for a Deployment that mounts a `ReadWriteOnce` PVC. The two
Longhorn replicas are two storage copies for that one volume, not two NocoDB application
instances. A pod or node move can cause a short outage while the volume detaches and
reattaches.

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

## Attachment storage and recovery

NocoDB mounts a separately declared 10 GiB Longhorn `ReadWriteOnce` PVC at
`/usr/app/data`. The claim uses the default two Longhorn storage replicas and the default
recurring-job group: daily local snapshots and off-cluster CIFS/NAS backups, with seven
backups retained. Flux prune protection prevents ordinary package removal from deleting
the claim.

This volume is required even though PostgreSQL holds application metadata. NocoDB stores
uploaded attachments and related local artifacts outside PostgreSQL. Ephemeral storage
would lose those files whenever the pod is replaced. No MinIO or S3 service is added
because the repository does not currently operate a suitable S3-compatible platform.

Recovery has two independently timed inputs:

1. restore a complete automation-data logical bundle containing the `nocodb` database
   and global roles; and
2. restore the closest corresponding Longhorn backup of the NocoDB attachment PVC.

These backups are not transactionally synchronized. A restored metadata record can
therefore refer to an attachment created outside the selected PVC recovery point, or a
restored file can be unreferenced. This limited inconsistency is accepted for an
operator-only tool. The restore drill must create an attachment before backup and prove
that the restored UI can retrieve it.

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
the database contract and reduce accidental writes. PostgreSQL denial remains the
independent security oracle rather than the normal way the UI distinguishes the two
surfaces.

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

Specification 025, the provisioner workflow contract, registry documentation, backup
manifest tests, and restore validation must be updated during implementation to include
these optional roles and tables.

## Bootstrap workflow

Initial NocoDB setup is an exceptional initialization operation:

```sh
mise exec -- just repo nocodb-secrets
NOCODB_BOOTSTRAP_CONFIRM='bootstrap:nocodb' mise exec -- just bootstrap nocodb
```

The first command writes only the guarded SOPS-encrypted repository Secret. The second is
operator-run because it reads sensitive runtime material and administers private NocoDB
and n8n APIs. It performs this fixed transaction:

1. Validate source, render the package, and check that the running checkout is deployed
   `origin/main`.
2. Prove that issue-317 bootstrap, provisioning acceptance, a current complete backup,
   and the full-chain restore drill have passed.
3. Repeat the source, target, Secret-shape, live suspension, and prerequisite checks
   immediately before mutation.
4. Temporarily reconcile the staged NocoDB package and run the fixed metadata bootstrap
   Job. The Job creates or reconciles only the `nocodb` database and
   `nocodb_metadata` login from the encrypted Secret.
5. Wait for NocoDB rollout and health at `/api/v1/health`.
6. Sign in with the SOPS-managed bootstrap administrator.
7. Set and read back the application settings that require
   invite-only signup and restrict workspace creation to the super administrator.
8. Create one NocoDB API token and send it directly to the local n8n credential API as
   the named **NocoDB Operator API** header credential.
9. Test the credential against fixed NocoDB endpoints and read back its non-secret ID.
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

On failure, bootstrap re-suspends only a Kustomization that it resumed and preserves the
PVC, database, metadata, and API state for diagnosis and retry. It does not delete or
regenerate a connection encryption key, administrator, token, or n8n credential as
compensation. A retry reconciles observed state.

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
6. For a new or failed initial source generation, mark `provisioning`, generate a
   password in workflow memory, pass it to the fixed PostgreSQL function, and create or
   update the matching NocoDB integration with the same credentials. Creation uses
   `POST /api/v2/meta/workspaces/:workspaceId/integrations`; update uses
   `PATCH /api/v2/meta/integrations/:integrationId`. Record the integration ID. A ready
   source never enters this branch.
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
    source ID.
12. Test normal access through NocoDB and independently test the expected PostgreSQL
    privilege matrix.
13. Mark the source generation `ready` only after all asynchronous, read-back, and access
    checks succeed. Return only non-secret IDs, access kinds, states, and timestamps.

The workflow uses execution order `v1` and disables saved manual, successful, failed, and
progress execution data. Passwords exist transiently in n8n memory because both systems
must receive the same generated value.

Each five-second polling delay remains below n8n's 65-second threshold for offloading a
Wait execution to its database. The workflow must not replace the polling loop with a
long Wait that persists execution data. A NocoDB or n8n pod restart can interrupt the
in-memory loop; the stored source-creation job ID lets the next explicit sync resume from
NocoDB state without retaining the password in n8n execution history.

The workflow never calls a source-delete endpoint as compensation. NocoDB `2026.08.2`
does delete its own partially created source when the source-creation processor reports
an error; the registry still retains the failed job and generation. The next explicit
sync first proves that no deterministic source exists, then may start a new initial
generation and set a replacement password because no ready contract exists. A timeout
with a nonterminal job is not a failed generation and only resumes polling.

Once a source is `ready`, sync preserves its PostgreSQL verifier, NocoDB encrypted
credential, source ID, and integration ID. A missing ready-side object is an error that
requires explicit rotation or repair; ordinary sync does not silently replace it.

Credential rotation is separate and target-bound:

```sh
NOCODB_SOURCE_ROTATE_CONFIRM='rotate:nocodb:<domain>:operator' \
  mise exec -- just kube nocodb-source-rotate <domain> operator
```

The final argument is restricted to `reader` or `operator`. Rotation repeats readiness
and source-identity checks immediately before mutation, updates PostgreSQL and NocoDB,
tests authentication and denials, and reads back the new generation. It is convergent,
not transactional. A retry replaces both sides again if interruption leaves them out of
agreement.

The workflow exposes no operation that deletes a source, base, login, registry row, or
domain. NocoDB's internal cleanup of a partial failed source is the only automatic source
deletion in this lifecycle. Future decommissioning requires a separate attended design.

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

Prometheus alerts cover:

- unavailable Deployment or health target;
- repeated restarts and OOM kills;
- failed or overdue metadata bootstrap or acceptance Jobs; and
- attachment PVC use at the established 70% warning and 85% critical thresholds.

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
- one replica, `Recreate`, disabled worker and Redis, and one existing PVC;
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

CI does not start NocoDB or PostgreSQL, create a source, test live privileges, create an
attachment backup, or perform a restore.

### Read-only live verification

```sh
mise exec -- just kube nocodb-verify
```

The verifier observes Flux readiness, Deployment rollout, Service endpoints, private
route, Gatus, Prometheus rules, workload policy, attachment PVC identity and Longhorn
robustness, and current automation-data backup freshness. It does not read application
metadata, inspect Secrets, authenticate to NocoDB, or alter target state.

### Attended access test

```sh
NOCODB_ACCESS_TEST_CONFIRM='test:nocodb:access' \
  mise exec -- just kube nocodb-access-test
```

The test uses a dedicated synthetic automation-data acceptance domain. Its base, sources,
and registry rows remain as recovery canaries; data mutations within them use a unique
run ID and cleanup never broadens beyond those rows. It proves:

1. exactly one NocoDB application pod is ready, no worker workload exists, and no Redis
   URL or Redis workload is configured;
2. source sync creates a reader source and an eligible operator source without a Git,
   SOPS, Flux, or NetworkPolicy change;
3. each create response yields a job ID, the workflow observes that exact job reach
   `completed`, then discovers exactly one source and reads it by ID before recording
   `ready`;
4. reader creation completes before operator creation in the same base;
5. the reader source reflects `read_model` but not `operator` or `app`, and its normal
   fact query succeeds;
6. the operator source reflects `operator` but not `read_model` or `app`, and normal
   insert, read, approved-column update, and run-owned delete operations succeed;
7. reader DML, DDL, role assumption, and cross-database access fail;
8. operator update of a protected column, access outside `operator`, DDL, role
   assumption, and cross-database access fail;
9. NocoDB reports data editing disabled for the reader, enabled for the operator, and
   schema editing disabled for both;
10. unchanged sync is idempotent and does not alter ready credential generations, job
    IDs, source IDs, or integration IDs;
11. explicit rotation restores one working source without revealing its password; and
12. cleanup removes and proves absence of only the current run's operator rows while
    retaining the synthetic recovery canary.

The PostgreSQL denials are the independent authority oracle. UI flags alone cannot pass
the test.

### Attended restore drill

```sh
NOCODB_RESTORE_CONFIRM='restore:nocodb:metadata' \
  mise exec -- just kube nocodb-restore-drill
```

The isolated drill uses a complete automation-data logical bundle and the closest
Longhorn attachment backup. It proves:

1. restored NocoDB metadata, global roles, source registry, and catalogs agree;
2. the retained connection encryption key decrypts the restored source credentials;
3. restored reader and operator sources authenticate to the distinct `read_model` and
   `operator` schemas of an isolated restored synthetic domain and retain the expected
   privilege denials;
4. a saved base and view remain available;
5. an attachment created before backup is retrievable from the restored PVC;
6. the restored automation-data service can publish a fresh complete logical bundle; and
7. all run-owned workloads, Services, policies, and temporary claims are removed and
   proved absent.

The restore drill never points restored NocoDB at the live domain service and never
overwrites the running metadata database or PVC.

## Rollout

Rollout follows dependency and authority order:

1. Implement the staged NocoDB package, optional automation-data role contract, workflow
   templates, lifecycle commands, monitoring, tests, and reconciled specifications.
2. Run `mise exec -- just ci`, review, merge, and leave the NocoDB Flux Kustomization
   suspended.
3. Complete issue-317 bootstrap, provisioning acceptance, complete backup, and
   full-chain restore drill if they have not already passed.
4. Create and merge the guarded SOPS-encrypted NocoDB Secret while NocoDB remains
   suspended.
5. From deployed `origin/main`, run the confirmed NocoDB bootstrap command.
6. Import, bind, and publish the private NocoDB source-provisioning workflow.
7. Run the confirmed access test and wait for complete automation-data and Longhorn
   backups that contain its persistent NocoDB state.
8. Run the confirmed NocoDB restore drill.
9. Only after all acceptance passes, change the NocoDB Kustomization's `spec.suspend` to
   `false` through a reviewed Git change and reconcile this specification with the dated
   result.

Initial administrator login, n8n credential binding, workflow publication, and commands
that read sensitive runtime state or call administrative APIs remain attended operator
actions. Agent-owned implementation, local validation, and approved scoped observation
remain agent-run under repository policy.

## Failure handling

- A NocoDB outage does not block n8n domain workflows or direct PostgreSQL access.
- A failed bootstrap preserves the database, PVC, and API objects and re-suspends only
  state that bootstrap resumed.
- A failed source operation records non-secret state and retains its registry row, job
  ID, role, base, and integration for deterministic retry. NocoDB can remove only the
  partial source created by its failed job.
- A ready credential changes only through explicit targeted rotation or attended repair.
- A full or unavailable attachment PVC makes NocoDB unavailable rather than falling back
  to ephemeral storage.
- Loss of NocoDB metadata can be recovered from automation-data logical backup; loss of
  attachments can be recovered separately from Longhorn backup.
- Loss of `NC_CONNECTION_ENCRYPT_KEY` cannot be repaired from the metadata database. The
  operator must restore the retained Secret or explicitly rotate every source after
  recovery.
- The workflow does not use source, base, registry, or role deletion as compensation or
  cleanup.

## Implementation status

As of 2026-09-04, this specification records the approved design. NocoDB resources,
optional reader/operator provisioning, workflow templates, Secrets, monitoring, and
command surfaces are not implemented. The issue-317 automation-data source exists but
remains suspended and has not completed live acceptance. No recovery capability or live
NocoDB service is claimed.

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

### Ephemeral application storage

Ephemeral `/usr/app/data` would lose uploaded attachments during normal pod replacement.
A retained 10 GiB PVC avoids that behavior without introducing another data platform.

### Two application replicas

Multiple replicas require Redis and a different attachment-storage design. Two Longhorn
replicas already protect the single volume from one storage-copy failure; they do not
make the application highly available. One application replica is proportional to this
operator-only service.

### Separate object storage

Adding MinIO or another S3-compatible service only for NocoDB would create a larger
platform, backup, monitoring, and recovery obligation than the current attachment load
justifies.

### Native Kubernetes manifests

Native manifests would avoid Helm but duplicate the supported chart's workload,
configuration, probe, and application-version conventions. The official chart with
explicit repository-owned overrides is the smaller maintenance surface.

## Review triggers

Revisit this design when attachment growth approaches the PVC alert thresholds; more
than one application replica becomes necessary; the cluster gains a supported
S3-compatible platform; NocoDB changes its source API, license, token scopes, metadata
schema, or attachment behavior; Enterprise SSO or permission features become available;
or the number of enabled domains makes one workspace operationally difficult.

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
