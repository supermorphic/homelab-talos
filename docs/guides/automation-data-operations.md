# Automation-data PostgreSQL operations

Use [credential discovery for approved work](nocodb-operations.md#credential-discovery-for-approved-work)
for task selection, readiness decisions, and autonomous helper use.

## Private credential-discovery installation

Credential discovery uses a dedicated private n8n workflow and three restricted
PostgreSQL readers. Installation is separately authorized operator administration.
Routine agents use the inventory header and retained consumer profiles; they do not
run this installer, read Kubernetes Secrets, or ask for a password during approved work.

After the reviewed source is deployed and NocoDB and n8n have initialized their
databases, prepare owned private directories outside every checkout. Use 0700
directories and 0600 regular files without symlinks or hard links. The access directory
is `$XDG_CONFIG_HOME/homelab/automation-data`, or
`$HOME/.config/homelab/automation-data` when XDG_CONFIG_HOME is unset. Place this
non-secret configuration in `access.json`, replacing the marked placeholders:

```json
{
  "schemaVersion": 1,
  "inventoryAuthFile": "/path/to/private/access/inventory-auth",
  "applicationProfileRoot": "/path/to/private/application-profiles",
  "migratorProfileRoot": "/path/to/private/migrator-profiles"
}
```

`applicationProfileRoot` must match the protected root used by the existing
`AUTOMATION_DATA_LOGIN_DIRECTORY` application lifecycle; retain its current domain and
application subdirectories. `inventoryAuthFile` must select `inventory-auth` in the access directory. Supply the
attended n8n enrollment API key through its protected `n8n-api-key` file. Do not paste
it into chat or put it in a command argument. Select the administrative kubeconfig
already authorized for installation using the existing `kubeconfig` Just variable.
Set `AUTOMATION_DATA_DISCOVERY_INSTALL_DIRECTORY` to the absolute access directory
and the execution-intent guard
`AUTOMATION_DATA_DISCOVERY_INSTALL_CONFIRM=install:automation-data:discovery`, then run:

```sh
mise exec -- just kube automation-data-discovery-install
```

The installer verifies deployed source, takes the shared mutation Lease, and creates
fresh backups on both PostgreSQL servers. It installs the same reviewed SQL used for
upgrade and recovery, tests reader authentication and permission boundaries, creates
the four named inventory credentials, binds and publishes the private inventory
workflow, and verifies its independent metadata readback. It removes only its own
temporary Jobs, ConfigMaps, and Secrets. Workflow execution persistence is disabled.
The inventory path is absent from the public webhook route.

The installer does not update either existing mutation workflow. Complete the
[mutation workflow upgrade](#upgrade-existing-mutation-workflows) before declaring
lifecycle readback ready.

Keep the protected `pending/operation.json` and candidate files until installation
and recovery evidence is accepted. Retry with the same directory and candidates.
Existing active readers must authenticate with the retained candidate; a rerun never
changes an existing active reader password. Unrelated fixed-name credentials and
uncertain API creation results require attended reconciliation. Inspect the retained
operation and exact identity before choosing the next action; do not delete the receipt
and repeat creation. Remove the enrollment API-key file when its operator use is done.

For replacement or revocation, deactivate the inventory workflow first and drain its
executions. Confirm the exact retained credential IDs and reader roles. Revoke only the
inventory header or selected reader, prepare protected replacement material through
attended administration, update the corresponding n8n binding and protected local header,
then repeat inventory acceptance before republishing. These steps require separate
authorization and are never a routine discovery fallback.

Automation-data backups retain their existing role and control-schema recovery contract.
n8n backups exclude the derived `platform_discovery` schema: their existing dump format
does not retain role ownership and grants. After an isolated n8n restore, recreate the
restricted reader and reapply the reviewed discovery SQL with retained protected material
before exposing inventory. This also supports older backups that predate discovery.
Application records are unchanged. Lost enrollment material requires attended replacement;
discovery does not export n8n passwords or reset credentials to make recovery succeed.

### Upgrade existing mutation workflows

On a new installation, NocoDB bootstrap requires platform provisioning and restore
acceptance before its database is initialized. For that first platform bootstrap only,
disable **Observe Mutation Inventory** in the platform provisioner and bind its three
existing credentials to their other nodes. Provisioning can then run with readback
reported as `unavailable`. Do not substitute another credential on the disabled node.
This temporary state does not satisfy discovery acceptance.

After the inventory installer passes, use the separately authorized private n8n editor
to update **Automation Data Provisioner** and **NocoDB Source Provisioner** from the
reviewed templates. ConfigMap deployment alone does not update published workflows.

1. Retain the existing workflow graphs, IDs, and credential bindings as protected
   rollback evidence. Unpublish the selected workflow and let in-flight mutations finish
   before replacing its graph. Update the existing workflow; do not publish a second workflow
   with the same webhook path.
2. Restore the existing Postgres and webhook bindings. Bind **Automation Data n8n API**
   in the platform provisioner, or **NocoDB Operator API** in the source provisioner,
   to HTTP Request nodes except **Observe Mutation Inventory**.
3. Bind the installer's **Automation Data Inventory Header** credential to
   **Observe Mutation Inventory** in both workflows and enable the node. It uses
   `X-Automation-Data-Inventory`; do not substitute either broader API credential or
   the mutation webhook header.
4. Verify these bindings and the disabled execution-data persistence settings, then
   publish each updated workflow. For first-time setup, apply the same bindings before
   its first publication, after the inventory installer has completed.
5. During separately authorized lifecycle acceptance, check that successful platform
   provisioning and NocoDB source mutations return `inventoryReadback.status=observed`
   for their exact targets. A readback failure does not undo a successful mutation:
   inspect the binding and retry inventory observation without repeating the mutation.

If rollback is required, restore the retained graph and bindings on the same workflow
before republishing. Older workflows can continue their existing mutation behavior, but
they do not establish the new lifecycle-readback acceptance criterion.

### Bind an installed migrator profile

For automatic migration selection, separately authorize one-time enrollment on clean
deployed main after private inventory acceptance. Retain the already authorized migrator
material under `<migratorProfileRoot>/<domain>/service.conf` and `credential.pgpass`
through the existing protected installation procedure. Do not export it from n8n or
send it through chat. Use owned 0700 directories and 0600 files outside checkouts.
Select that exact service file with `AUTOMATION_DATA_SERVICE_FILE`, its section with
`AUTOMATION_DATA_SERVICE`, and the matching fixed local port with
`AUTOMATION_DATA_LOCAL_PORT` when the default is unsuitable. Set the target guard
`AUTOMATION_DATA_LOGIN_ENROLL_CONFIRM=enroll:automation-data:sample:migrator` for the
synthetic domain below, then run:

```sh
mise exec -- just kube automation-data-login-enroll-migrator sample
```

The helper verifies deployed source, current domain metadata, profile identity and
permissions, and authentication through its fixed tunnel. It writes only non-secret
`binding.json` with the current retained n8n credential ID/update marker, service, and
port. It leaves the installed service/password files intact and invents no generation.
Reconcile a changed or lost binding through this attended procedure before automatic
selection; never relabel old material as current without those checks. Explicitly
selected protected profiles remain supported by the connection helper.

This guide activates and operates the shared PostgreSQL platform used by n8n domain
workflows. The platform database is separate from n8n's own PostgreSQL database.

Adding a domain, repository integration, or n8n workflow must not require a
`homelab-talos` change. Git defines PostgreSQL, provisioning authority, backup and
restore mechanics, monitoring, Cilium policy, and the generic role model once. The
private provisioning workflow creates each domain at runtime.

The platform is active. Provisioning and full-chain recovery passed on 2026-09-04 and
2026-09-05 respectively; [specification 026](../specs/026-automation-data-postgresql-platform.md#implementation-status)
records the acceptance evidence.

Use [Routine operation](#routine-operation) for the active platform. The original
first-deployment procedure is retained under [Staged activation](#staged-activation).
For recovery, use
[n8n / automation-data recovery](../runbooks/platform-disaster-recovery.md#n8n--automation-data-recovery).

## Before you start

For staged activation, start only when these conditions are true:

- the platform implementation is merged and the checkout matches deployed `origin/main`;
- the feature branch used to create the encrypted Secret is clean;
- the operator has the SOPS age private key and access to the private n8n UI; and
- the operator can retain the n8n encryption key and access off-cluster backups.

Stop if the encrypted Secret cannot be reviewed as SOPS ciphertext, Flux does not reach
source revision parity, a guarded command fails, an expected result is absent, or the
required private credential cannot be handled without exposing it. Do not bypass a
guard, broaden cluster credentials, or continue to the next activation step after a
failure.

## Recovery roots

Keep these operator-held recovery roots outside the cluster:

- the SOPS age private key that decrypts the Git-managed platform Secrets;
- access to off-cluster Longhorn and PostgreSQL backup copies; and
- the stable n8n `N8N_ENCRYPTION_KEY` that decrypts restored n8n credentials.

Do not escrow generated domain passwords. A complete automation-data globals dump
preserves their PostgreSQL password verifiers. A restored n8n database preserves the
matching encrypted credentials. The retained n8n encryption key completes that recovery
chain without revealing a domain password.

## Staged activation

These steps record the original rollout from suspended source. Current Git keeps the
platform active, and `bootstrap automation-data` deliberately refuses that state. Do not
repeat bootstrap for routine operation or recovery; use the guarded restore workflow
described in [Recovery](../runbooks/platform-disaster-recovery.md#n8n--automation-data-recovery).

### 1. Create the encrypted platform Secret

Use the guarded writer from a clean feature branch. Enter the PostgreSQL superuser,
provisioner, backup, and exporter values without putting them in shell history. Retain
the provisioner password until the initial n8n Postgres credential is created. These are
platform credentials, not dynamically generated domain passwords.

```bash
(
  set -e
  printf '%s' 'PostgreSQL superuser password: ' >&2
  IFS= read -r -s AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD
  printf '\n%s' 'Provisioner password: ' >&2
  IFS= read -r -s AUTOMATION_DATA_PROVISIONER_PASSWORD
  printf '\n%s' 'Backup role password: ' >&2
  IFS= read -r -s AUTOMATION_DATA_BACKUP_PASSWORD
  printf '\n%s' 'Exporter password: ' >&2
  IFS= read -r -s AUTOMATION_DATA_EXPORTER_PASSWORD
  printf '\n' >&2
  export AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD AUTOMATION_DATA_PROVISIONER_PASSWORD
  export AUTOMATION_DATA_BACKUP_PASSWORD AUTOMATION_DATA_EXPORTER_PASSWORD
  AUTOMATION_DATA_SECRETS_CONFIRM='write:automation-data:postgresql:sops' \
    mise exec -- just repo automation-data-secrets
  unset AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD AUTOMATION_DATA_PROVISIONER_PASSWORD
  unset AUTOMATION_DATA_BACKUP_PASSWORD AUTOMATION_DATA_EXPORTER_PASSWORD
)
```

The writer produces only SOPS ciphertext in
`kubernetes/apps/automation-data/postgresql/app/postgresql-credentials.sops.yaml`.
Validate, review, merge, and wait for Flux source revision parity while
`automation-data-postgresql` remains suspended.

**Expected result:** The committed Secret contains only SOPS ciphertext, Flux reports
the merged source revision, and `automation-data-postgresql` remains suspended.

### 2. Reconcile the private platform

From a clean checkout whose implementation matches deployed `origin/main`, obtain the
task-scoped kubeconfig and run the guarded bootstrap:

```bash
mise exec -- just talos kubeconfig
AUTOMATION_DATA_BOOTSTRAP_CONFIRM='bootstrap:automation-data' \
  mise exec -- just bootstrap automation-data
```

The bootstrap checks that the encrypted Secret is committed and selected without
decrypting it. It reconciles the namespace, resumes only
`automation-data-postgresql`, enables role inheritance and applies the idempotent
`pg_monitor` grant required by the platform exporter, and removes that run-owned
migration Job. It then creates one
run-owned backup Job from the CronJob, removes that Job, and runs read-only verification.
On failure, it removes only its run-owned Jobs and re-suspends only the PostgreSQL
Kustomization it resumed. Claims and database data stay in place.

**Expected result:** The PostgreSQL Kustomization is active, its StatefulSet and both
PVCs are ready, SQL Exporter can report every connectable database without receiving
domain data privileges, the initial run-owned backup completes, and read-only
verification passes.

### 3. Create the three provisioning credentials in n8n

Use the private n8n UI. Do not send any value to an agent or commit it.

| Credential | Type | Secret source | Purpose |
| --- | --- | --- | --- |
| **Automation Data Provisioner** | Postgres | Retained platform provisioner password | Create and reconcile scoped PostgreSQL domain objects |
| **Automation Data n8n API** | Header Auth | Full-access Community-edition n8n API key | Create and rotate encrypted domain credentials in n8n |
| **Automation Data Provisioning Header** | Header Auth | Separately generated private token | Authenticate callers of the provisioning webhook |

1. Create the Postgres credential **Automation Data Provisioner**. Use host
   `automation-data-postgresql.automation-data.svc.cluster.local`, port `5432`, database
   `automation_data_control`, user `automation_data_provisioner`, and the retained
   platform provisioner password.
2. Create a full-access Community-edition n8n API key. The deployed n8n edition does not
   provide the narrowly scoped credential-only API key assumed by an earlier design.
   Store the key in a Header Auth credential named **Automation Data n8n API** with
   header name `X-N8N-API-KEY`.
3. Generate and retain a separate private token for callers of the provisioning
   webhook. Store it in a Header Auth credential named
   **Automation Data Provisioning Header** with header name
   `X-Automation-Data-Provisioning`.

The Community-edition API key is a privileged platform secret. It has broader n8n API
authority than the provisioning workflow exposes. Compromise can affect more than the
automation-data credentials managed by this workflow. Keep the editor and API private,
disable execution-data persistence for provisioning, and use the key only in this
dedicated workflow.

**Expected result:** The private n8n instance contains all three named credentials with
the listed types. Their values do not appear in Git, shell history, workflow JSON, or
agent output.

### 4. Import and publish the provisioning workflow

Import
`kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json`.
Bind:

- **Automation Data Provisioner** to every Postgres node;
- **Automation Data n8n API** to every HTTP Request node except **Observe Mutation Inventory**;
- **Automation Data Inventory Header** to **Observe Mutation Inventory**; and
- **Automation Data Provisioning Header** to **Provisioning Webhook**.

The [discovery installer](#private-credential-discovery-installation) creates the inventory
header after the databases are initialized. For first platform bootstrap, disable
**Observe Mutation Inventory** and proceed with the three existing credentials until
NocoDB is initialized. Follow the
[mutation workflow procedure](#upgrade-existing-mutation-workflows) to finish enrollment.
Keep the workflow's execution-data settings unchanged. Do not add
credential IDs or values to the template in Git.

**Expected result:** **Automation Data Provisioner** is published with all four named
credentials bound, and its execution-data settings remain unchanged.
During first platform bootstrap, the inventory node remains disabled and readback is
`unavailable` until the later discovery enrollment and workflow upgrade.

### 5. Validate provisioning and rotation

Run the attended acceptance workflow with its private token supplied outside command
output:

```bash
(
  set -e
  printf '%s' 'Provisioning webhook token: ' >&2
  IFS= read -r -s AUTOMATION_DATA_PROVISIONING_TOKEN
  printf '\n' >&2
  export AUTOMATION_DATA_PROVISIONING_TOKEN
  AUTOMATION_DATA_PROVISIONING_URL='https://n8n.lab.supermorphic.com/webhook/automation-data-provision' \
    AUTOMATION_DATA_PROVISIONING_CONFIRM='test:automation-data:provisioning' \
    mise exec -- just kube automation-data-provisioning-test
  unset AUTOMATION_DATA_PROVISIONING_TOKEN
)
```

Supply the token bound to **Automation Data Provisioning Header**. The command requires
at least 32 URL-safe letters, digits, underscores, or hyphens.

The test creates or reconciles `automation_data_acceptance`, validates
owner/migrator/runtime permissions, proves that an unchanged request is idempotent,
performs an explicit credential rotation, and creates a complete backup. It does not
install application tables, so the NocoDB acceptance fixture can use the same domain.
Ordinary reconcile never rotates a password or replaces an n8n credential.

For each new domain, the workflow creates:

- `<domain>_owner`, a stable `NOLOGIN` object owner;
- `<domain>_migrator`, a login that can assume the owner for reviewed DDL;
- `<domain>_runtime`, a restricted login with initial CRUD defaults;
- the matching database and schema, grants, and default privileges; and
- n8n credentials named `automation-data/<domain>/migrator` and
  `automation-data/<domain>/runtime`.

The request supplies a domain and a fixed operation, not arbitrary SQL. Supported normal
operations create/reconcile a domain, rotate one login credential, and validate a
domain. The workflow does not expose `DROP DATABASE`, `DROP ROLE`, destructive schema
replacement, or bulk data deletion.

Application migrations may reduce object and default grants. Platform validation
checks the permitted privilege ceiling, not blanket CRUD on all application tables.
It does not certify an application's exact grants or functional behavior. Do not use
provision/reconcile to repair a customized application's grants: these operations still
apply broad initial grants. Use the application's reviewed migration workflow instead.

**Expected result:** The acceptance command passes, the domain and both n8n credentials
exist, unchanged reconciliation preserves their credentials, explicit rotation changes
only the selected login credential, and the resulting backup is complete.

After this rotation, create both a new n8n logical dump and a new automation-data bundle
before the restore drill. A pre-rotation n8n dump paired with a post-rotation database
bundle contains mismatched encrypted credentials and password verifiers, so it cannot
prove recovery. Use the [recorded evidence procedure](test-campaign-operations.md#record-initiative-and-infrequent-assurance)
to retain acceptance results.

If the bundle-validation Job fails, the command prints a bounded
`bundle_check_failed=<check>` diagnostic before cleanup. Stop at that failure; do not
proceed to restore or NocoDB bootstrap. A message that the canonical test run passed
validation confirms the report structure only, not acceptance success. After correcting
the cause, create a fresh backup through the acceptance command; do not edit retained
bundles or bypass their checksums.

### 6. Provision and bind the stable canary

After the provisioning acceptance completes, use the private provisioning workflow to
create the stable empty canary domain with
`{"domain":"automation_data_canary","operation":"provision"}`. This creates the
`automation-data/automation_data_canary/runtime` credential. Do not use the acceptance
domain credential for the canary.

Import `kubernetes/apps/automation/n8n/app/workflows/automation-data-canary.json`. Bind
the existing **Platform Canary Header** credential to **Canary Webhook** and
`automation-data/automation_data_canary/runtime` to **Test Stable Runtime Credential**.
Publish **Automation Data Canary**. Keep its execution-data settings unchanged and do
not add credential IDs or values to the template in Git.

For an active platform that already has **Automation Data Recovery Canary**, do not
import a second workflow. Update that workflow in place and preserve its workflow record
and **Platform Canary Header** binding. Rename it **Automation Data Canary**; change its
webhook to **Canary Webhook** at `POST /webhook/automation-data-canary`; replace its fixed
identity with database `automation_data_canary` and role
`automation_data_canary_runtime`; and bind
`automation-data/automation_data_canary/runtime` to **Test Stable Runtime Credential**.
Retain `saveDataErrorExecution: none`, `saveDataSuccessExecution: none`,
`saveManualExecutions: false`, and `saveExecutionProgress: false`, then publish that same
workflow.

Gatus calls this published workflow every five minutes. Wait for a complete n8n dump and
automation-data bundle that form a compatible pair: the n8n dump must contain the
published workflow and its encrypted stable runtime credential, and the automation-data
bundle must contain the matching `automation_data_canary` role verifier. Then run the
attended full-chain drill:

```bash
AUTOMATION_DATA_RESTORE_CONFIRM='restore:automation-data:full-chain' \
  mise exec -- just kube automation-data-restore-drill
```

Do not claim recoverability until this command passes. It restores n8n and
automation-data into isolated run-owned storage, calls the same authenticated
`POST /webhook/automation-data-canary` workflow used by Gatus, proves that its restored
encrypted runtime credential authenticates against the restored verifier, creates a
fresh post-recovery backup, and removes its temporary resources.

**Expected result:** The full-chain drill passes, the restored n8n credential
authenticates to the isolated restored database, a fresh post-recovery backup exists,
and the run-owned temporary resources are removed.

## Upgrade the NocoDB platform extension

Run from deployed `main` after a complete, healthy pre-upgrade automation-data
logical backup is available:

```bash
AUTOMATION_DATA_UPGRADE_CONFIRM='upgrade:automation-data:nocodb-v3' \
  mise exec -- just kube automation-data-upgrade
```

Wait for the command to succeed. It upgrades the installed NocoDB platform
extension, preserves existing source identities, and adds named source pairs,
durable operation claims, and registered application logins. Reconcile the reviewed
backup-capable code first, require a complete pre-upgrade bundle, and pause provisioning
while the operator runs the upgrade. An unresolved source or login transition blocks
the upgrade. Import and publish the reviewed workflows afterward, preserving their
existing protected credential bindings and disabled execution-data persistence.

After success, create and verify a fresh complete automation-data logical backup
before continuing with NocoDB bootstrap or source changes. If the command reports
an unsupported or partial platform revision, stop and investigate instead of
attempting a manual schema repair.

See [Spec 026](../specs/026-automation-data-postgresql-platform.md) for the
upgrade, validation, backup, and restore design.

## Routine operation

### Check health

Use the read-only verifier for normal health checks:

```bash
mise exec -- just kube automation-data-verify
```

It checks Flux and StatefulSet readiness, both PVCs and Longhorn volumes, the private
Service, monitoring, backup freshness, registry/catalog consistency, and incomplete
operation age. It does not read Secrets, query PostgreSQL directly, or invoke n8n.

### Add a domain

Create new domains and repository integrations only through the provisioning workflow.
Do not add a domain list, domain credential, role, database, schema, grant, or
domain-specific Cilium policy to this repository. PostgreSQL roles enforce domain
isolation; the workload-scoped Cilium policy permits n8n to reach the shared service.

From a private n8n HTTP Request node, send `POST` to
`http://127.0.0.1:5678/webhook/automation-data-provision` using the
**Automation Data Provisioning Header** credential and a JSON body such as
`{"domain":"example_app","operation":"provision"}`. Domain names start with a lowercase
letter and contain at most 48 lowercase letters, digits, or underscores. Use
`operation: reconcile` to repair structure or `operation: validate` to inspect it.

Use the resulting `automation-data/example_app/migrator` credential for reviewed
migrations. Run `SET ROLE example_app_owner` before qualified DDL such as
`CREATE TABLE app.example (...)`, then `RESET ROLE` afterward. This keeps new objects
under the stable owner with the runtime default grants. Use
`automation-data/example_app/runtime` for normal Postgres-node CRUD. Provisioning creates
the database and initial schema; consumer migrations create and evolve their tables.

### Rotate a credential

Use explicit rotation only when a domain credential must change. Retry a failed rotation
through the same explicit operation. Do not use ordinary reconcile as password repair.
Send the same authenticated request with
`{"domain":"example_app","operation":"rotate","credential":"runtime"}` (or `migrator`).

### Update platform control functions

PostgreSQL runs initialization scripts only for an empty data directory. An update to
control functions on an existing database therefore uses the guarded migration command.
Merge the reviewed source and wait for Flux revision parity first.

Deactivate **Automation Data Provisioner** and wait for its running executions to finish.
From the operator checkout with credentials permitted to create the migration Jobs, run:

```bash
AUTOMATION_DATA_CONTROL_MIGRATE_CONFIRM='migrate:automation-data:control' \
  mise exec -- just kube automation-data-control-migrate
```

The command checks deployed source, workload and catalog state, holds the shared mutation
Lease, creates a fresh logical backup, and applies the selected control functions in one
transaction. It uses the same SQL source as fresh initialization and removes its
run-owned Jobs. It does not read or print credential values.

After success, import the current provisioning template, preserve its three credential
bindings and execution-data settings, and publish it. Run the standalone provisioning
acceptance, wait for new backups of both systems, and run the full-chain restore drill.
Finish with `mise exec -- just kube automation-data-verify`. On failure, keep provisioning
paused and retain the backup while classifying the failed step.

## Registered application logins and private CLI access

After deploying v3, register a PostgreSQL identity for agent/application reads and fixed
functions in a ready domain. Consumers own schemas, grants, migrations, CLI role selection,
and acceptance; see the [authority contract](../specs/026-automation-data-postgresql-platform.md#registration-and-authority).
NocoDB source credentials and human UI accounts have separate responsibilities.

### Register, grant, and activate

1. Supply `AUTOMATION_DATA_PROVISIONING_TOKEN` through approved private handling.
   `AUTOMATION_DATA_PROVISIONING_URL`, if set, must equal the fixed endpoint
   `https://n8n.lab.supermorphic.com/webhook/automation-data-provision`. Register the
   synthetic `sample.app` target and retain its returned role:

   ```bash
   AUTOMATION_DATA_LOGIN_REGISTER_CONFIRM='register:automation-data:sample:interview:app' \
     mise exec -- just kube automation-data-login-register sample interview app
   ```

2. Through the distinct migrator, grant that `NOLOGIN` role database `CONNECT`, schema
   `USAGE`, intended reads, and `EXECUTE` on reviewed functions. Review function/definer
   authority and unintended PUBLIC grants. No direct DML, ownership, role membership,
   or schema creation is allowed; effective permissions must remain within the target.

3. Create an owned `0700` directory outside every checkout, then activate and validate:

   ```bash
   mise exec -- just talos kubeconfig
   export AUTOMATION_DATA_LOGIN_DIRECTORY=/ABSOLUTE/PRIVATE/PATH/application-logins
   AUTOMATION_DATA_LOGIN_ACTIVATE_CONFIRM='activate:automation-data:sample:interview' \
     mise exec -- just kube automation-data-login-activate sample interview
   mise exec -- just kube automation-data-login-validate sample interview
   ```

   Activation saves the candidate/operation before submission, authenticates through
   the fixed tunnel, acknowledges the generation, and installs the profile. Output is
   limited to role/generation metadata and `serviceFile`. Ambiguous failure retains the
   same candidate and operation for retry.

### Protected files and connection

Retain `<directory>/<domain>/<application>/` in approved private storage:

| Path | Purpose |
| --- | --- |
| `pending/candidate.pgpass`, `pending/operation.json` | Candidate and target/operation/generation/phase needed for retry. |
| `generation-<n>/` | Versioned `credential.pgpass`, `service.conf`, and `binding.json`. |
| Top-level `service.conf`, `binding.json` | Selected profile and binding after acknowledgment. |

Use owned regular `0600` files and `0700` directories, preserving older generations.
The helper rejects symlinks, unsafe modes/ownership, mismatched targets, inline profile
passwords, and inherited `PG*` settings. Select the returned profile and service section:

```bash
export AUTOMATION_DATA_SERVICE_FILE=/ABSOLUTE/PRIVATE/PATH/application-logins/sample/interview/service.conf
export AUTOMATION_DATA_SERVICE='automation_data_sample_<returned-role>'
mise exec -- just kube automation-data-connect sample application/interview
```

The foreground helper binds `127.0.0.1:15432` to port `5432` on
`automation-data-postgresql-0` and verifies database/session identity. It closes when
interrupted, its child exits, or the Pod changes. `AUTOMATION_DATA_LOCAL_PORT` may select
1024–65535; use the same port for activation and connection. `AUTOMATION_DATA_KUBECONFIG`
defaults to this worktree's `.kube/config` and must contain the approved scoped contexts;
there is no administrative fallback or SQL/query argument.

In another terminal, give the consumer CLI the same profile. Career Ops uses
`CAREER_EVIDENCE_SERVICE_FILE` and `CAREER_EVIDENCE_SERVICE`; issue 197 must update its
role selection and prove reads/functions/export before claiming consumer acceptance.

### Rotation, migration prerequisites, and recovery

```bash
AUTOMATION_DATA_LOGIN_ROTATE_CONFIRM='rotate:automation-data:sample:interview' \
  mise exec -- just kube automation-data-login-rotate sample interview
```

Rotation affects only this login and retains the active profile until authentication
and acknowledgment succeed. Retry ambiguous activation/rotation with the same command
and directory; never delete `pending/` to force a new operation. Missing candidate
material requires a separately confirmed new rotation.

Migration uses `automation-data-connect <domain> migrator` with an explicitly selected,
operator-retained profile for `<domain>_migrator`. Missing credentials require separate
authorization for the existing targeted domain rotation: verify the backup and exact
n8n binding, run the guarded lifecycle, then arrange protected delivery. Onboarding
never retrieves the password from n8n or rotates it automatically.

Keep client credentials alongside the other [recovery roots](../runbooks/platform-disaster-recovery.md#nocodb-metadata-recovery):
backups retain verifiers, not recoverable client passwords. Live upgrade, credential
installation, browser access, and recorded restore require their own authorization.

## Destructive administration

Dropping a table is reviewed domain DDL. Use the domain migrator credential, explicitly
assume `<domain>_owner`, and run the exact reviewed statement through the repository or
workflow-specific migration process. The runtime credential cannot drop tables.

Dropping a database or role is not self-service. A future attended
administrative/decommission workflow must require an explicit target, existence and
ownership validation, a fresh validated backup, and attended execution. Until that
workflow exists, stop and prepare a separately reviewed operator procedure. Never add
destructive operations to the ordinary provisioning webhook.
For a NocoDB-connected domain, use the
[attended decommission boundary](nocodb-operations.md#destructive-administration).

## Rollback

Before the platform has accepted production domain data, a failed bootstrap can
re-suspend `automation-data-postgresql`; the guarded recipe does this automatically when
it resumed that Kustomization. Persistent source changes still go through Git.

After domains exist, preserve both PVCs and backup copies. Do not delete claims or
recreate PostgreSQL as a rollback. Withdraw the failing workflow, keep PostgreSQL
private, and follow the operator boundary in
[n8n / automation-data recovery](../runbooks/platform-disaster-recovery.md#n8n--automation-data-recovery).
