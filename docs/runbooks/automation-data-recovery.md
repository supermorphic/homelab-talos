# Recover automation-data PostgreSQL

Use this runbook when the shared automation-data PostgreSQL service or its logical state
does not recover through normal reconciliation. This database platform is separate from
n8n's own PostgreSQL database, but full credential recovery requires both systems.

The recovery property described here does not exist until Issue 317 is merged, deployed,
and the attended full-chain restore drill passes. Producing backup artifacts alone is
not proof of recovery.

Keep these operator-held recovery roots available:

- the SOPS age private key for the Git-managed platform Secrets;
- off-cluster backup access for the relevant Longhorn and logical backup copies; and
- the stable n8n `N8N_ENCRYPTION_KEY` for restored n8n credential ciphertext.

Do not escrow plaintext passwords for generated domain roles. The automation-data
globals dump preserves their role password verifiers. The restored n8n database and
retained encryption key preserve the matching client credentials.

Collect read-only evidence first:

```bash
mise exec -- just talos kubeconfig
mise exec -- just kube storage-verify
mise exec -- just kube automation-data-verify
mise exec -- kubectl --kubeconfig .kube/config --namespace automation-data get \
  statefulset/automation-data-postgresql \
  pvc/automation-data-postgresql-data \
  pvc/automation-data-postgresql-backups
```

Record both PVC UIDs and their PV names. Do not delete or replace a current claim while
classifying the fault.

## Pod rescheduling

Use this path when both claims are Bound and healthy but the PostgreSQL pod is not Ready.
Let the StatefulSet controller reschedule its pod, or delete only the failed pod through
an approved operator workflow. Require the current StatefulSet revision to become Ready
and both recorded PVC UIDs to remain unchanged.

Then run:

```bash
mise exec -- just kube automation-data-verify
```

Do not restore a logical bundle when rescheduling recovered the existing database.

## Longhorn volume recovery

Use this path when `automation-data-postgresql-data` or
`automation-data-postgresql-backups` is detached, degraded, faulted, or unavailable.
Preserve the PVC and failed volume. Prefer a healthy existing Longhorn replica, then a
verified off-cluster Longhorn backup. Follow the repository's
[platform Longhorn recovery sequence](platform-disaster-recovery.md#recover-longhorn-and-application-state).

Restore into a new claim when replacement is required. Validate it with an isolated
workload before any reviewed production claim switch. A crash-consistent Longhorn
recovery and a logical PostgreSQL restore provide different evidence; run the logical
drill when the database or credential chain also needs proof.

## Logical bundle restore

An automation-data bundle is complete only when its directory name has the exact
`automation-data-YYYYmmddTHHMMSSZ` form and it contains:

```text
globals.sql
registry.tsv
manifest.tsv
databases/db-<encoded-name>.dump  # one for every captured database
SHA256SUMS
COMPLETE
```

`COMPLETE` authenticates `SHA256SUMS`; `SHA256SUMS` covers the globals, registry,
manifest, and every database dump. Reject an extra, missing, empty, corrupt, or
unreadable artifact. Select candidates newest-first and accept only the first exact,
checksum-valid bundle whose custom-format archives all pass `pg_restore --list`.

The globals backup uses `pg_dumpall --globals-only` and MUST NOT use
`--no-role-passwords`. It restores cluster-global roles, memberships, role password
verifiers, tablespaces, and related global state. It does not replace the individual
database dumps. Each `pg_dump` restores database-local schema, object ownership, ACLs,
grants, and data.

Restore into a new empty PostgreSQL instance. Restore `globals.sql` first. Then create or
restore exactly every database recorded in `manifest.tsv`. Compare the restored database
set and platform registry with the captured artifacts. Validate owner, membership,
connection, DDL, CRUD, ACL, and default-privilege behavior for every ready domain.

Use the registered attended drill for the supported isolated proof:

```bash
AUTOMATION_DATA_RESTORE_CONFIRM='restore:automation-data:full-chain' \
  mise exec -- just kube automation-data-restore-drill
```

The drill also restores n8n into a second isolated PostgreSQL instance and starts a
temporary n8n Deployment with `N8N_ENCRYPTION_KEY` supplied by Secret reference. Only
that pod resolves the production automation-data hostname to the restored database. The
restored **Automation Data Recovery Canary** must use the restored
`automation-data/issue317_acceptance/runtime` credential successfully. The drill never
reads or prints its password.

The last required step is a fresh post-recovery backup created with the restored backup
role verifier. Require a new exact, complete, checksum-valid bundle. The drill then
deletes and independently proves the absence of all run-owned Jobs, Services,
StatefulSets, Deployments, policies, and 20Gi temporary PVCs.

Stop if any step fails. Preserve sanitized phase evidence and the source backup copies.
Do not cut production over to the isolated test instances.

## Total-cluster reconstruction

Recover Talos, etcd, Cilium, Flux source access, the SOPS age identity, and Longhorn in
the order defined by
[platform disaster recovery](platform-disaster-recovery.md). Restore the n8n and
automation-data recovery unit together:

1. Reconcile the private n8n PostgreSQL and automation-data PostgreSQL platforms from
   reviewed Git source.
2. Restore the selected n8n dump with the retained `N8N_ENCRYPTION_KEY`.
3. Restore automation-data globals before its individual database dumps.
4. Restore the captured registry and validate the complete database and permission set.
5. Start n8n privately and prove the restored runtime credential authenticates against
   the restored PostgreSQL verifier.
6. Create and validate a fresh post-recovery backup.
7. Run both read-only verifiers and application-specific acceptance before restoring any
   public route or normal workflow traffic.

The SOPS age identity, off-cluster backups, and n8n encryption key are the recovery
roots that prevent a total cluster loss from stranding this chain. Losing a generated
domain plaintext password does not strand it when the verified globals and n8n backups
are intact.

## Destructive boundary

Recovery does not authorize database or role deletion. `DROP DATABASE`, `DROP ROLE`, and
equivalent destructive operations belong to a separate attended
administrative/decommission workflow. Any future workflow must repeat these preconditions
immediately before mutation:

1. identify one explicit target;
2. prove that it exists and is owned by the expected domain owner;
3. create and validate a fresh backup that includes the target; and
4. require attended execution of the exact reviewed action.

Do not expose destructive operations through the normal provisioning workflow.
