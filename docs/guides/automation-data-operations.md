# Automation-data PostgreSQL operations

This guide activates and operates the shared PostgreSQL platform used by n8n domain
workflows. The platform database is separate from n8n's own PostgreSQL database.

Adding a domain, repository integration, or n8n workflow must not require a
`homelab-talos` change. Git defines PostgreSQL, provisioning authority, backup and
restore mechanics, monitoring, Cilium policy, and the generic role model once. The
private provisioning workflow creates each domain at runtime.

The recovery capability in this guide is not established until Issue 317 is merged,
deployed, and the attended full-chain restore drill passes.

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

### 1. Create the encrypted platform Secret

Use the guarded writer from a clean feature branch. Enter the PostgreSQL superuser,
provisioner, backup, and exporter values without putting them in shell history. Retain
the provisioner password until the initial n8n Postgres credential is created. These are
platform credentials, not dynamically generated domain passwords.

```bash
(
  printf '%s' 'PostgreSQL superuser password: ' >&2
  IFS= read -r -s POSTGRES_SUPERUSER_PASSWORD
  printf '\n%s' 'Provisioner password: ' >&2
  IFS= read -r -s POSTGRES_PROVISIONER_PASSWORD
  printf '\n%s' 'Backup role password: ' >&2
  IFS= read -r -s POSTGRES_BACKUP_PASSWORD
  printf '\n%s' 'Exporter password: ' >&2
  IFS= read -r -s POSTGRES_EXPORTER_PASSWORD
  printf '\n' >&2
  export POSTGRES_SUPERUSER_PASSWORD POSTGRES_PROVISIONER_PASSWORD
  export POSTGRES_BACKUP_PASSWORD POSTGRES_EXPORTER_PASSWORD
  AUTOMATION_DATA_SECRETS_CONFIRM='write:automation-data:postgresql:sops' \
    mise exec -- just repo automation-data-secrets
  unset POSTGRES_SUPERUSER_PASSWORD POSTGRES_PROVISIONER_PASSWORD
  unset POSTGRES_BACKUP_PASSWORD POSTGRES_EXPORTER_PASSWORD
)
```

The writer produces only SOPS ciphertext in
`kubernetes/apps/automation-data/postgresql/app/postgresql-credentials.sops.yaml`.
Validate, review, merge, and wait for Flux source revision parity while
`automation-data-postgresql` remains suspended.

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
`automation-data-postgresql`, creates one run-owned backup Job from the CronJob, removes
that Job, and runs read-only verification. On failure, it removes only its Job and
re-suspends only the PostgreSQL Kustomization it resumed. Claims and database data stay
in place.

### 3. Create the three provisioning credentials in n8n

Use the private n8n UI. Do not send any value to an agent or commit it.

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

The API key is broader than the workflow operations that use it. Keep the editor and API
private, disable execution-data persistence for provisioning, and use the key only in
this dedicated workflow.

### 4. Import and publish the provisioning workflow

Import
`kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json`.
Bind:

- **Automation Data Provisioner** to every Postgres node;
- **Automation Data n8n API** to every HTTP Request node; and
- **Automation Data Provisioning Header** to **Provisioning Webhook**.

Keep the workflow's execution-data settings unchanged, then publish it. Do not add
credential IDs or values to the template in Git.

### 5. Validate provisioning and rotation

Run the attended acceptance workflow with its private token supplied outside command
output:

```bash
AUTOMATION_DATA_PROVISIONING_CONFIRM='test:automation-data:provisioning' \
  mise exec -- just kube automation-data-provisioning-test
```

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

### 6. Bind the recovery canary

After the acceptance domain exists, import
`kubernetes/apps/automation/n8n/app/workflows/automation-data-recovery-canary.json`.
Bind the existing **Platform Canary Header** credential to **Recovery Webhook**. Bind
`automation-data/issue317_acceptance/runtime` to **Test Restored Runtime Credential**.
Publish **Automation Data Recovery Canary**.

Wait for a later complete n8n dump and automation-data bundle that contain these
published bindings. Then run the attended full-chain drill:

```bash
AUTOMATION_DATA_RESTORE_CONFIRM='restore:automation-data:full-chain' \
  mise exec -- just kube automation-data-restore-drill
```

Do not claim recoverability until this command passes. It restores n8n and
automation-data into isolated run-owned storage, proves the restored encrypted runtime
credential authenticates against the restored verifier, creates a fresh post-recovery
backup, and removes its temporary resources.

## Routine operation

Use the read-only verifier for normal health checks:

```bash
mise exec -- just kube automation-data-verify
```

It checks Flux and StatefulSet readiness, both PVCs and Longhorn volumes, the private
Service, monitoring, backup freshness, registry/catalog consistency, and incomplete
operation age. It does not read Secrets, query PostgreSQL directly, or invoke n8n.

Create new domains and repository integrations only through the provisioning workflow.
Do not add a domain list, domain credential, role, database, schema, grant, or
domain-specific Cilium policy to this repository. PostgreSQL roles enforce domain
isolation; the workload-scoped Cilium policy permits n8n to reach the shared service.

Use explicit rotation only when a domain credential must change. Retry a failed rotation
through the same explicit operation. Do not use ordinary reconcile as password repair.

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
