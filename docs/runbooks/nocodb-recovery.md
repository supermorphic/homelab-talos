# Recover NocoDB

Use this runbook when the NocoDB pod, metadata database, source operation, or recovery
root does not recover through normal reconciliation. NocoDB is an
optional operator interface over automation-data PostgreSQL. Preserve the authoritative
domain databases and normal n8n workflows while diagnosing it.

The repository contains the recovery workflow, but live recovery remains unproved until
the attended NocoDB access test, complete logical backup, and restore drill pass. Do not
describe an unrun drill as established recoverability.

This runbook is reconciled with the tested offline and disposable local implementation
in [specification 028](../specs/028-nocodb-operator-ui.md). Its local restore proof does
not establish live backup publication, Longhorn recovery, Gateway access, or browser
behavior. Require the attended checks below before using the result as live rollout or
recovery acceptance.

## Recovery roots and limits

Keep these recovery roots available:

- the SOPS age private key for the Git-managed NocoDB Secret;
- the retained `NC_CONNECTION_ENCRYPT_KEY` from that encrypted Secret;
- complete automation-data logical bundles, including globals, the `nocodb` database,
  the source registry, and opted-in domain databases.

NocoDB application-local storage is disposable. Supported durable state lives in the
automation-data PostgreSQL bundle. Workflow-generated file bytes remain with their
external workflow or storage owner. This runbook validates their durable PostgreSQL
metadata and references, not the external bytes. It does not fetch a URI or define a
file service, registry, proxy, or general artifact schema.

Start with read-only checks:

```bash
mise exec -- just talos kubeconfig
mise exec -- just kube storage-verify
mise exec -- just kube automation-data-verify
mise exec -- just kube nocodb-verify
mise exec -- kubectl --kubeconfig .kube/config --namespace automation-data get \
  deployment/nocodb
mise exec -- kubectl --kubeconfig .kube/config --namespace automation-data get events \
  --sort-by=.lastTimestamp
```

Choose the least destructive path that fits the evidence.

## Pod rescheduling

Use this path when the automation-data PostgreSQL service is healthy but the one NocoDB
pod is not Ready.

Let the Deployment controller reschedule the pod, or delete only the failed pod through
an approved operator workflow. NocoDB uses one replica and `Recreate`; a short outage is
expected during replacement. Local scratch is recreated. Require:

- exactly one new NocoDB pod becomes Ready;
- no worker or Redis workload appears;
- saved bases, views, sources, encrypted credentials, operator decisions, and artifact
  references remain available from PostgreSQL; and
- `mise exec -- just kube nocodb-verify` passes.

Do not restore PostgreSQL when ordinary rescheduling recovers the existing metadata.

## PostgreSQL logical metadata recovery

Use this path when the `nocodb` logical database, source registry, optional roles, or
other PostgreSQL-held metadata is corrupt or missing.

A complete automation-data bundle has the exact
`automation-data-YYYYmmddTHHMMSSZ` directory name and contains:

```text
globals.sql
registry.tsv
manifest.tsv
databases/db-<encoded-name>.dump
SHA256SUMS
COMPLETE
```

Reject an extra, missing, empty, checksum-invalid, or unreadable artifact. The manifest
must list every captured non-template database, including `automation_data_control`,
`nocodb`, and the required domain databases. `globals.sql` preserves the
`nocodb_metadata`, reader, and operator roles and their password verifiers. The restored
control database preserves the single `managed_nocodb_sources` registry.

Restore only into a new empty PostgreSQL instance first. Restore globals before the
individual database archives, compare the restored catalog and registry with the
captured set, and validate every ready reader and operator role through
`platform_operations.validate_nocodb_access`. Keep the production database and
PostgreSQL PVC unchanged until isolated validation passes.

A logical restore recovers artifact metadata and durable references. Recover referenced
external bytes through the owning workflow or storage system.

## Isolated metadata recovery

Use the registered attended drill for the supported isolated proof:

```bash
NOCODB_RESTORE_CONFIRM='restore:nocodb:metadata' \
  mise exec -- just kube nocodb-restore-drill
```

The drill requires the synthetic acceptance domain, its ready reader and operator
sources, the saved view, and the recoveryCanary version 2 decision and artifact-reference
records. It never points restored NocoDB at the live domain service, never overwrites the
production database, and creates no HTTPRoute.

The drill applies these gates in order:

1. Refuse unless confirmation, catalog coordination, the test Lease, deployed-source
   parity, and absence of all run-owned targets pass.
2. Resolve the exact generated backup ConfigMap from both the rendered package and the
   deployed CronJob. Require the same hashed name and both required script keys.
3. Create only a run-owned logical-preflight Job. It mounts the automation-data backup
   claim read-only and validates exact file membership, nested checksums, manifest shape,
   archive lists, and required databases. It performs no PostgreSQL connection or
   restore.
4. Select exactly one complete logical bundle. Delete and prove absence of the preflight
   Job before creating restore resources.
5. Create isolated policy, a new 20 GiB PostgreSQL claim and instance, and a restore Job.
   Restore globals and every database, validate domain and optional NocoDB role grants,
   require exact source-registry identities, and publish a fresh complete logical
   bundle.
6. Validate the exact run-owned PostgreSQL Service and its ClusterIP. Start one isolated
   NocoDB Deployment with `Recreate`, no worker or Redis, fresh `emptyDir` scratch, the
   retained Secret keys, and host aliases that route both fixed PostgreSQL hostnames only
   to that restored Service.
7. Recheck that no HTTPRoute targets the temporary Service. Through an isolated request
   Job, verify workspace, base, saved view, distinct sources, source registry identities,
   reader denial, approved operator write and denial, and exact decision and artifact
   metadata/reference records. The request uses actual NocoDB sources, resolves each
   table's `schema:null` through its source ID and validated search path, and never fetches
   the synthetic URI.
8. Remove and independently prove the absence of every run-owned Job, Deployment,
   StatefulSet, Service, policy, and isolated PostgreSQL PVC. Failed cleanup is a failed
   drill.

Stop on the first failed gate. Preserve sanitized result evidence and the selected source
bundle. Do not cut production over to the isolated resources.

## Lost connection encryption key

`NC_CONNECTION_ENCRYPT_KEY` encrypts the source credentials stored in the `nocodb`
metadata database. Restore the exact retained encrypted Secret through the approved SOPS
workflow. Do not generate a replacement key during ordinary recovery.

If the retained key is unavailable, restored source credentials can remain unreadable
even when metadata restores successfully. Stop and prepare a separately
reviewed attended recovery design that establishes replacement encryption material and
then rotates each source explicitly. `nocodb-source-rotate` changes only one selected
PostgreSQL reader or operator login and its matching integration; it is not a broad key
or token recovery operation. It does not rotate the broad NocoDB API token.

## Lost bootstrap token response

There is no separate lost-token recovery command. If bootstrap lost the response after
NocoDB created its broad API token but before n8n stored it, rerun the same guarded
bootstrap from the exact deployed `origin/main` checkout:

```bash
NOCODB_BOOTSTRAP_CONFIRM='bootstrap:nocodb' mise exec -- just bootstrap nocodb
```

When the n8n credential is absent, the retry may preserve one matching orphan, create
one replacement, and report only the orphan's non-secret ID. Verify the n8n credential,
then revoke the reported orphan through attended NocoDB administration. More than one
matching orphan is a hard stop. Do not keep rerunning bootstrap or create tokens
manually.

## Failed source-creation job

A failed asynchronous source job records non-secret error state plus its operation, job,
base, integration, role, and generation identities. NocoDB `2026.08.2` can remove only
the partial source created by its failed processor; the workflow does not call a source
delete endpoint as compensation.

Before retrying, inspect the bounded workflow result and correct the fixed prerequisite.
An explicit sync may start a replacement initial generation only after it proves that
the base contains no source with the deterministic alias and no source tied to the
retained integration. A surviving error-state or partial source with that alias is not
adopted, even when it is the only match. Stop for attended cleanup under the existing
decommission and destructive-change boundaries before retrying. The workflow does not
delete a base, source, role, or registry row as automatic cleanup. If NocoDB has already
removed its own failed partial source, the zero-source proof permits the explicit retry.

## Timed-out source-creation job

A timeout is not a failed generation. The registry remains `waiting_for_source` with
the exact job ID after ten minutes of five-second polling. Run the same confirmed source
sync again:

```bash
NOCODB_SOURCE_SYNC_CONFIRM='sync:nocodb:<domain>' \
  mise exec -- just kube nocodb-source-sync <domain>
```

The retry resumes polling the stored job before source discovery. It must not generate a
new password or queue another source. A missing stored job is a hard error and requires
attended investigation.

## Explicit source credential rotation

Use rotation only for a ready source whose exact base, integration, and source identities
still match:

```bash
NOCODB_SOURCE_ROTATE_CONFIRM='rotate:nocodb:<domain>:operator' \
  mise exec -- just kube nocodb-source-rotate <domain> operator
```

Choose `reader` or `operator`. The PostgreSQL function first records `rotating` with
`operation=rotate`, increments the credential generation, and changes only the selected
role with `ALTER ROLE ... LOGIN ... PASSWORD`. It does not set the role to `NOLOGIN`.
The workflow then updates the matching NocoDB integration and retests privileges and
authentication. If a later step fails, the handled error records `state=error`, retains
`operation=rotate` and the exact base, integration, and source IDs, and can leave the
PostgreSQL and NocoDB credentials temporarily mismatched. Retry only the same
target-bound rotation after verifying all three retained IDs. Ordinary sync and rotation
of the other access kind are rejected while that recorded rotation error remains.

This workflow is not broad NocoDB-token rotation. No supported lifecycle command rotates
the token in the n8n **NocoDB Operator API** credential.

## Attended decommission boundary

Recovery does not authorize deletion. The implemented workflows expose no deletion of a
base, source, integration, registry row, role, metadata database, or domain. A future
decommission must use a separately reviewed attended procedure that:

1. identifies one explicit target and all of its dependencies;
2. proves current object identity, ownership, and source-registry agreement;
3. creates and validates a fresh complete logical bundle;
4. repeats every safety-critical precondition immediately before each mutation; and
5. removes only the reviewed objects, with post-action absence checks.

Do not add destructive compensation to bootstrap, source sync, rotation, or restore.
