# Automation-data PostgreSQL operations

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
[Recover automation-data PostgreSQL](../runbooks/automation-data-recovery.md).

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
repeat bootstrap for routine operation or recovery; use the linked recovery runbook.

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
- **Automation Data n8n API** to every HTTP Request node; and
- **Automation Data Provisioning Header** to **Provisioning Webhook**.

Keep the workflow's execution-data settings unchanged, then publish it. Do not add
credential IDs or values to the template in Git.

**Expected result:** **Automation Data Provisioner** is published with all three named
credentials bound, and its execution-data settings remain unchanged.

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

The test creates or reconciles `issue317_acceptance`, validates owner/migrator/runtime
permissions, proves that an unchanged request is idempotent, performs an explicit
credential rotation, and creates a complete backup. Ordinary reconcile never rotates a
password or replaces an n8n credential.

For each new domain, the workflow creates:

- `<domain>_owner`, a stable `NOLOGIN` object owner;
- `<domain>_migrator`, a login that can assume the owner for reviewed DDL;
- `<domain>_runtime`, a CRUD-only login;
- the matching database and schema, grants, and default privileges; and
- n8n credentials named `automation-data/<domain>/migrator` and
  `automation-data/<domain>/runtime`.

The request supplies a domain and a fixed operation, not arbitrary SQL. Supported normal
operations create/reconcile a domain, rotate one login credential, and validate a
domain. The workflow does not expose `DROP DATABASE`, `DROP ROLE`, destructive schema
replacement, or bulk data deletion.

**Expected result:** The acceptance command passes, the domain and both n8n credentials
exist, unchanged reconciliation preserves their credentials, explicit rotation changes
only the selected login credential, and the resulting backup is complete.

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

## Destructive administration

Dropping a table is reviewed domain DDL. Use the domain migrator credential, explicitly
assume `<domain>_owner`, and run the exact reviewed statement through the repository or
workflow-specific migration process. The runtime credential cannot drop tables.

Dropping a database or role is not self-service. A future attended
administrative/decommission workflow must require an explicit target, existence and
ownership validation, a fresh validated backup, and attended execution. Until that
workflow exists, stop and prepare a separately reviewed operator procedure. Never add
destructive operations to the ordinary provisioning webhook.

## Rollback

Before the platform has accepted production domain data, a failed bootstrap can
re-suspend `automation-data-postgresql`; the guarded recipe does this automatically when
it resumed that Kustomization. Persistent source changes still go through Git.

After domains exist, preserve both PVCs and backup copies. Do not delete claims or
recreate PostgreSQL as a rollback. Withdraw the failing workflow, keep PostgreSQL
private, and use [Recover automation-data PostgreSQL](../runbooks/automation-data-recovery.md)
to choose the least destructive recovery path.
