# Recover n8n

Use this runbook when n8n, its retained filesystem data, or PostgreSQL does not recover
through normal reconciliation. The logical dump and the matching Git-held
`n8n-runtime.sops.yaml` are one recovery unit. Existing n8n credential ciphertext is
readable only with the stable `N8N_ENCRYPTION_KEY` from that encrypted manifest and the
operator password manager.

Start by removing the router TCP/443 forwarding rule if the failure can expose incorrect
responses, authentication failures, or partial data. Keep `public-webhook-route`
suspended in Git during recovery. Do not delete any current claim while collecting
evidence.

## Classify the fault

Use the least destructive recovery path that matches the evidence:

- **Pod rescheduling:** The claims are Bound and healthy, but the n8n Deployment or
  PostgreSQL StatefulSet pod is not Ready. Let the controller recreate the pod. Do not
  recreate a claim or restore a dump.
- **Longhorn recovery:** A retained claim is unavailable, detached, degraded, or faulted.
  Preserve its PVC and use Longhorn replica or NAS-backup recovery. A crash-consistent
  Longhorn recovery is different from a logical PostgreSQL restore.
- **Logical restore:** PostgreSQL storage is available but its database is missing,
  corrupt, or logically incorrect. Restore a checksum-valid custom-format dump into an
  empty database and retain the matching encryption key.
- **Full reconstruction:** The cluster, namespace, claims, and current database cannot be
  recovered. Rebuild foundation services in dependency order, restore storage, and then
  perform the logical restore and n8n validation before public cutover.

Collect read-only status first:

```bash
mise exec -- just talos kubeconfig
mise exec -- just kube storage-verify
mise exec -- kubectl --kubeconfig .kube/config --namespace automation get \
  deployment/n8n statefulset/n8n-postgresql \
  pvc/n8n-data pvc/n8n-postgresql-data pvc/n8n-postgresql-backups
mise exec -- kubectl --kubeconfig .kube/config --namespace automation get events \
  --sort-by=.lastTimestamp
```

Record all three PVC UIDs and their bound PV names before any change. The normal
Deployment and StatefulSet controllers can replace pods without changing those UIDs.

## Pod rescheduling

If all three claims are Bound and Longhorn reports healthy volumes, inspect rollout and
pod events. Reconcile the existing Git source or delete only the failed pod through an
approved operator workflow. Require the Deployment and StatefulSet to return Ready and
the three recorded PVC UIDs to remain unchanged.

Load the canary token without shell history and run the read-only acceptance command:

```bash
IFS= read -r -s -p 'Platform Canary token: ' N8N_CANARY_TOKEN; printf '\n'
export N8N_CANARY_TOKEN
mise exec -- just kube n8n-verify
unset N8N_CANARY_TOKEN
```

Do not restore PostgreSQL when pod rescheduling has recovered the existing database.

## Longhorn volume recovery

Keep the affected PVC and PV objects. Identify whether the failure affects `n8n-data`,
`n8n-postgresql-data`, or `n8n-postgresql-backups`. Follow the Longhorn recovery controls
and prefer a healthy existing replica before its NAS backup. Recover the original volume
or bind a reviewed replacement claim only after preserving the failed volume for
diagnosis. Follow the repository's
[Longhorn recovery sequence](platform-disaster-recovery.md#recover-longhorn-and-application-state)
for the storage operation.

After storage recovery, require Bound claims, healthy Longhorn volumes, PostgreSQL Ready,
n8n Ready, and an authenticated canary. If database checks still fail, continue with a
logical restore. If `n8n-data` was lost, restore its matching Longhorn backup because
filesystem binary execution data is not present in the PostgreSQL dump.

## Logical restore

### 1. Preserve current state and select an artifact

Suspend public access first. Preserve the current `n8n-postgresql-data` PVC and its
Longhorn volume; do not delete or reuse it as the restore target. Preserve
`n8n-postgresql-backups` and record its UID.

A candidate is valid only when both final files exist:

```text
n8n-postgresql-YYYYmmddTHHMMSSZ.dump
n8n-postgresql-YYYYmmddTHHMMSSZ.dump.sha256
```

Select candidates newest-first. The checksum sidecar must name the matching dump,
`sha256sum --check` must pass from the backup directory, and `pg_restore --list` must
read the complete archive. Do not accept a `.tmp`, unpaired, checksum-mismatched, or
unreadable artifact.

Use the guarded drill to perform those checks against the retained backup claim and
restore the newest valid candidate into a run-named temporary database:

```bash
N8N_RESTORE_DRILL_CONFIRM='restore:n8n-postgresql:temporary' \
  mise exec -- just kube n8n-restore-drill
```

The drill fails unless it can start an isolated temporary n8n instance with the existing
key and database password through `secretKeyRef`, call the restored published canary with
the namespace-local credential, and remove its temporary database and Kubernetes
resources. It does not create an HTTPRoute or modify the production database.

Stop if the drill fails. Preserve its canonical test result and fix artifact, key,
credential, policy, or cleanup faults before production recovery.

### 2. Identify the matching encrypted key

Find the Git revision that operated at the selected dump timestamp. Confirm that revision
contains
`kubernetes/apps/automation/n8n/app/n8n-runtime.sops.yaml` and that its SOPS recipient
matches this repository. Use the operator-held age identity to recover the already saved
key through the approved SOPS workflow. Never print the plaintext value, put it in a
command argument, copy it into the dump, or commit it unencrypted.

The selected dump, its checksum, and that encrypted key manifest are the recovery unit.
If the matching key is unavailable, stop: restoring the rows does not make their
credential ciphertext usable.

### 3. Restore into an empty production database

Use a reviewed recovery change or operator-approved Job based on
[`n8n-restore-drill.sh`](../../scripts/test/scenarios/n8n-restore-drill.sh). Pass PostgreSQL
passwords and `N8N_ENCRYPTION_KEY` only with `secretKeyRef`. Keep the old PVC and database
preserved. The target database must not already exist; create it empty, restore with
`pg_restore --no-owner --no-privileges --role=n8n`, and require the `workflow_entity`,
`credentials_entity`, `webhook_entity`, and `execution_entity` tables.

Do not cut the production Deployment over yet. Start an isolated, cluster-internal n8n
instance at the pinned version against the restored database. Give it no HTTPRoute.
Require an authenticated Platform Canary response with the submitted correlation and a
non-empty execution ID. Open the matching successful execution history record. This
proves the retained key can decrypt the restored Header Auth credential.

### 4. Cut over and validate

After the isolated validation passes, update the reviewed production database target and
retained Secret selection through Git. Keep the public route suspended. Wait for
PostgreSQL and n8n readiness, then run private acceptance. Preserve the former PVC,
database, dump, and result evidence until the operator accepts the recovery.

Run a fresh logical backup. Require a new final dump-and-checksum pair, a successful
archive inspection, and a newer
`n8n_postgresql_backup_last_success_timestamp_seconds` value. Complete the guarded
temporary restore drill again against the new artifact. Only then restore public DNS and
router TCP/443 forwarding by following the
[n8n operations guide](../guides/n8n-operations.md).

## Full reconstruction

Rebuild the platform in this order:

1. Talos, etcd, and Kubernetes;
2. Cilium, Flux, SOPS identity, Longhorn, private Gateway, monitoring, and the dedicated
   public Gateway while its route stays suspended;
3. the `n8n-data` and `n8n-postgresql-backups` Longhorn backups;
4. the three SOPS-encrypted n8n/PostgreSQL/canary Secret manifests from Git;
5. an empty PostgreSQL database restored from the selected checksum-valid dump; and
6. private n8n, temporary canary validation, a new logical dump, and full read-only
   acceptance.

Publish the public route only after the private editor, restored credential, execution
history, backup freshness, monitoring, and off-network negative-path controls all pass.

## Failure and cleanup rules

- A failed cleanup is a failed recovery. Do not start another drill while its temporary
  database or run-owned Deployment, Service, Cilium policy, or Jobs remain.
- Do not adopt resources from another test run. Use the catalog's shared Lease and exact
  confirmation.
- Do not delete retained claims as application rollback.
- Do not expose a temporary Service with an HTTPRoute.
- Do not log, display, or copy Secret values into diagnostics or evidence.
- Do not re-enable the router rule until the exact public route and negative-path tests
  pass.
