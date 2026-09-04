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

### Read facts; edit decisions and explicit corrections

Workflow-produced facts are read-only through NocoDB. The normal controlled-edit surface
contains operator-owned state such as review status, approve or reject decisions,
priority, notes, and follow-up state.

Domains should preserve source facts and represent corrections as explicit override
records or fields. A domain may grant a targeted column update on a source table only
when its reviewed migration defines that as the intended business contract. Broad table
updates, schema changes, backfills, and changes across many records remain n8n or
migrator operations.

### Domain opt-in

Ordinary automation-data provisioning continues to create only owner, migrator, and
runtime roles. A NocoDB source-sync operation is the explicit opt-in that adds
`<domain>_reader`. It also creates `<domain>_operator` as a `NOLOGIN` candidate so a
reviewed domain migration has a stable grant target. A later source sync enables that
role as a login and creates its source only after a controlled-edit privilege surface
exists and passes validation.

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
      |-- reader source --> selected domain as <domain>_reader
      |-- operator source --> selected domain as <domain>_operator
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
`2026.06.1` application default because it supplies the stable source-creation endpoint
`POST /api/v2/meta/bases/:baseId/sources` needed by the provisioning workflow. Live
acceptance must prove this chart and image combination before activation.

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
a time, and NocoDB background work does not justify Redis or a worker at this scale.
`Recreate` satisfies the repository invariant for a Deployment that mounts a
`ReadWriteOnce` PVC. The two Longhorn replicas are two storage copies for that one volume,
not two NocoDB application instances. A pod or node move can cause a short outage while
the volume detaches and reattaches.

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
- `NC_INVITE_ONLY_SIGNUP=true` to disable public signup;
- `NC_ALLOW_LOCAL_EXTERNAL_DBS=true` so the private PostgreSQL Service is an allowed
  source target;
- telemetry and support chat disabled; and
- no public shared views.

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
- NocoDB egress required for its own image-independent application operation only when
  explicitly documented and tested; and
- monitoring ingress or observation through the established service paths.

There is no general Internet ingress or egress. The metadata bootstrap Job receives only
DNS and automation-data PostgreSQL egress. The n8n workload gains only the NocoDB Service
and port as a new destination.

## Optional domain roles

Noco-enabled domains add one or two login roles:

| Role | Creation rule | PostgreSQL authority |
| --- | --- | --- |
| `<domain>_reader` | Every explicitly enabled domain | `CONNECT`, schema `USAGE`, and `SELECT` on the approved read surface |
| `<domain>_operator` | Created as `NOLOGIN`; enabled only after an explicit controlled-edit surface exists | Reader access plus exact domain-declared DML grants |

The reader is `LOGIN`. The operator remains `NOLOGIN` until its controlled-edit grants
pass validation; source sync then changes only that attribute and sets its transient
password. Both roles are `NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
NOBYPASSRLS`. They cannot assume the owner, migrator, runtime, provisioner, metadata, or
backup role. `PUBLIC` privileges cannot bypass these limits.

The reader normally receives `SELECT` on current domain tables and matching owner default
privileges for later tables in the approved `app` schema. It receives no sequence use,
DML, DDL, ownership, or role membership.

The operator receives the same read surface plus grants declared by reviewed domain
migrations. Those grants can include:

- `INSERT` and sequence use on dedicated decision, note, or override tables;
- `UPDATE` on an exact column list;
- `DELETE` only on tables whose rows are operator-owned state; and
- row-level security policies when a table requires row restrictions.

The platform provisioner never accepts a table, column, schema, grant, SQL fragment, or
row-policy expression from the webhook. After initial reader provisioning, a reviewed
domain migration grants the `NOLOGIN` operator candidate its business privilege surface.
Source sync reads PostgreSQL catalogs and refuses to enable that login or create its
source when it cannot prove that at least one controlled DML grant exists and that no
forbidden role attribute, ownership, schema-create, or cross-database authority exists.

NocoDB configures a reader source with data editing and schema editing disabled. It
configures an operator source with data editing enabled and schema editing disabled.
Those settings reduce mistakes in the UI; PostgreSQL denial remains the independent
oracle.

## Platform registry and fixed functions

The automation-data control database adds runtime state for NocoDB without changing the
meaning of ordinary domain readiness:

- `platform_operations.managed_nocodb_domains` records domain, NocoDB base ID,
  requested access mode, state, generation, last operation, and non-secret error data;
- `platform_operations.managed_nocodb_sources` records domain, access kind, role name,
  NocoDB integration ID, source ID, credential generation, successful validation time,
  and non-secret error data.

Rows reference `managed_domains`. Access kind is restricted to `reader` or `operator`.
Identifiers are validated against the existing domain contract, and IDs are treated as
opaque values rather than executable input. Passwords and API tokens never enter these
tables.

The existing `automation_data_provisioner` login gains execute access only to fixed
NocoDB functions that:

- create or reconcile a requested reader or operator role;
- set or rotate that role's transient password;
- validate its catalog privileges;
- record NocoDB base, integration, and source identifiers;
- advance a source operation state or record a non-secret failure; and
- read the expected source state for a named managed domain.

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
6. Sign in with the SOPS-managed bootstrap administrator and create one NocoDB API token.
7. Send the token directly to the local n8n credential API as the named
   **NocoDB Operator API** header credential.
8. Test the credential against fixed NocoDB endpoints and read back its non-secret ID.
9. Return only non-secret resource IDs, readiness, and next operator steps.

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
- source alias: `Read` or `Operator`.

Source sync performs this idempotent state machine:

1. Validate the domain and require its existing automation-data state to be `ready`.
2. Inspect catalogs through fixed functions and derive reader-only or controlled-edit
   eligibility.
3. Mark the NocoDB source operation as `provisioning` with a new generation.
4. Create or reconcile `<domain>_reader` as a login and `<domain>_operator` as a
   `NOLOGIN` candidate. If reviewed operator grants already pass validation, enable the
   operator login. Otherwise leave it unable to authenticate and omit its source.
5. For each new or incomplete eligible source, generate a password in workflow memory
   and pass it to the fixed PostgreSQL function and the matching NocoDB source request.
6. Create or reconcile the deterministic NocoDB base, integrations, and sources with
   schema editing disabled and the correct data-edit setting.
7. Test each source, read back its settings and IDs, and independently test the expected
   PostgreSQL privilege matrix.
8. Mark the generation `ready` only after all checks succeed.
9. Return only non-secret IDs, access kinds, state, and timestamps.

The workflow uses execution order `v1` and disables saved manual, successful, failed, and
progress execution data. Passwords exist transiently in n8n memory because both systems
must receive the same generated value.

Partial failure never triggers deletion compensation. An incomplete initial generation
remains `provisioning` or `error`; retry can set a replacement password because no ready
source contract exists. Once a source is `ready`, sync preserves its PostgreSQL verifier,
NocoDB encrypted credential, source ID, and integration ID. A missing ready-side object
is an error that requires explicit rotation or repair; ordinary sync does not silently
replace it.

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

No automatic operation deletes a source, base, login, registry row, or domain. Future
decommissioning requires a separate attended design.

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

The test creates only run-labeled state in a synthetic automation-data domain. It proves:

1. source sync creates a reader source and an eligible operator source without a Git,
   SOPS, Flux, or NetworkPolicy change;
2. reader `SELECT` succeeds;
3. reader `INSERT`, `UPDATE`, `DELETE`, DDL, role assumption, and cross-database access
   fail;
4. operator read and one approved column update succeed;
5. operator update of a protected column, DDL, role assumption, and cross-database access
   fail;
6. NocoDB reports data editing disabled for the reader, enabled for the operator, and
   schema editing disabled for both;
7. unchanged sync is idempotent and does not alter ready credential generations or IDs;
8. explicit rotation restores one working source without revealing its password; and
9. cleanup removes only test-owned rows and objects and proves their absence.

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
3. restored reader and operator sources authenticate to an isolated restored synthetic
   domain and retain the expected privilege denials;
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
- A failed source operation records non-secret state and retains partial objects for
  deterministic retry.
- A ready credential changes only through explicit targeted rotation or attended repair.
- A full or unavailable attachment PVC makes NocoDB unavailable rather than falling back
  to ephemeral storage.
- Loss of NocoDB metadata can be recovered from automation-data logical backup; loss of
  attachments can be recovered separately from Longhorn backup.
- Loss of `NC_CONNECTION_ENCRYPT_KEY` cannot be repaired from the metadata database. The
  operator must restore the retained Secret or explicitly rotate every source after
  recovery.
- Source or role deletion is not automatic compensation or cleanup.

## Implementation status

As of 2026-09-03, this specification records the approved design. NocoDB resources,
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
- [NocoDB `2026.08.2` API-token controller](https://github.com/nocodb/nocodb/blob/2026.08.2/packages/nocodb/src/controllers/api-tokens.controller.ts)
- [PostgreSQL 17 privileges](https://www.postgresql.org/docs/17/ddl-priv.html)
- [PostgreSQL 17 role attributes](https://www.postgresql.org/docs/17/role-attributes.html)
- [Automation-data PostgreSQL specification](025-automation-data-postgresql-platform.md)
- [Repository command lifecycle](021-repository-command-lifecycle.md)

## Pull request linkage

Every pull request produced by this initiative links
[GitHub issue 334](https://github.com/supermorphic/homelab-talos/issues/334) in its
description. Partial pull requests use `Related to #334`. Only the pull request that
finishes the accepted issue scope uses `Closes #334`.
