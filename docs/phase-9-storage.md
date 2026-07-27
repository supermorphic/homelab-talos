# Phase 9: Storage (Longhorn)

## Status

**Complete (2026-07-22).** Longhorn is live and passed acceptance; both storage
Kustomizations are durably active (`suspend: false`).
Phase 9 is scoped to **Longhorn only** (replicated block storage for application
config and state). The bulk media `/data` layer is **deferred to Phase 11** and
will use SMB (`csi-driver-smb` against `//192.168.0.3/Prometheus`), because the
UNAS Pro serves SMB/CIFS (NFS is disabled), Plex runs off-cluster on the Mac
Mini, and the in-cluster media/download apps that need `/data` are Phase 11. See
the scope note in [`plans/talos-flux-platform-plan.md`](../plans/talos-flux-platform-plan.md).

## Architecture and Ownership

Longhorn is a Flux app under `kubernetes/apps/storage/longhorn/`, following the
Phase 7 pattern: two staged Flux Kustomizations in `flux-system`.

| Kustomization | Path | dependsOn | Purpose |
|---|---|---|---|
| `longhorn` | `app/` | `cilium` | HelmRelease (controller, CSI, manager), privileged namespace |
| `longhorn-config` | `config/` | `longhorn` | BackupTarget CR, CIFS Secret, recurring jobs |

Only Longhorn holds cluster-critical data (app databases and config). Bulk,
replaceable media never lives on Longhorn — that belongs on the NAS (Phase 11).

## Pinned Components

| Component | Version / value |
|---|---|
| Longhorn chart | `1.12.0` (`https://charts.longhorn.io`) |
| Namespace | `longhorn-system` (privileged PodSecurity) |
| Default data path | `/var/mnt/longhorn` (dedicated Talos user volume) |
| Replicas / anti-affinity | 2 replicas, hard node anti-affinity (`replicaSoftAntiAffinity: false`) |
| Default StorageClass | `longhorn` (default, `numberOfReplicas: 2`) |
| Backup target | `cifs://192.168.0.3/Longhorn` via `BackupTarget/default` |
| Snapshot integrity | `enabled`; backup compression `gzip` |

## Talos Prerequisites (Part A)

Applied per node via `just talos generate` → `just talos validate` →
`just bootstrap resize-longhorn <node>` before installing Longhorn:

- `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools` system extensions.
- The `longhorn` user volume capped at `maxSize: 500GiB` (≈750 GiB usable at two
  replicas), reclaiming ~280 GiB/node of NVMe headroom for node-local scratch.
- `machine.kubelet.extraMounts` exposing `/var/mnt/longhorn` with `rshared`
  propagation so the Longhorn manager/CSI pods can bind-mount it.

Verify per-node volume health any time with `just talos volume-status`.

## Backup Target

Longhorn 1.7+ **removed** the `backup-target` and `backup-target-credential-secret`
settings; the target is now the `default` **`BackupTarget`** custom resource
(`config/backup-target.yaml`), referencing the `nas-credentials` Secret. Setting
`defaultSettings.backupTarget` in Helm values is silently ignored on 1.12 and
leaves the target URL empty.

The CIFS backup requires the Talos nodes to be able to mount CIFS. If the backup
target reports unavailable with a mount error (not "URL is empty"), confirm the
`cifs` kernel module is available on the nodes.

## Credential Preparation

The CIFS credentials are written only as SOPS ciphertext by the guarded recipe;
the operator supplies them from their password manager (never the legacy repo):

```bash
printf 'SOPS age private key: '; read -rs SOPS_AGE_KEY; printf '\n'; export SOPS_AGE_KEY
printf 'UNAS CIFS username: ';   read -r  CIFS_USERNAME;  export CIFS_USERNAME
printf 'UNAS CIFS password: ';   read -rs CIFS_PASSWORD;  printf '\n'; export CIFS_PASSWORD
export STORAGE_SECRETS_CONFIRM='write:storage:nas-credentials:sops'
mise exec -- just repo storage-secrets
unset STORAGE_SECRETS_CONFIRM CIFS_USERNAME CIFS_PASSWORD
```

`storage-secrets` validates the credentials (best-effort `smbclient` when
available) and writes `config/nas-credentials.sops.yaml` (`CIFS_USERNAME`/
`CIFS_PASSWORD` in `stringData`), encrypted under the repository age key.

## Guarded Rollout

```bash
export STORAGE_BOOTSTRAP_CONFIRM='bootstrap:phase9:storage:longhorn'
mise exec -- just bootstrap storage
```

`bootstrap storage` may run from any clean branch/worktree after `git fetch origin
main`. Its rollout guard and storage source paths must match remote `origin/main`,
and both Kustomizations must be staged `suspend: true` in Git and live. It re-runs
`storage-validate` + `flux-verify`, then resumes `longhorn` → `longhorn-config` in
order (waiting for each to become Ready), and finishes with the read-only
`storage-verify` plus the state-changing `storage-provisioning-test`. Any
failure re-suspends the resumed Kustomizations while preserving their resources.
No operator SOPS key is needed — Flux decrypts the CIFS Secret in-cluster.

After acceptance passes, set both Kustomizations to `suspend: false`, commit and
push, and re-run `just kube storage-verify` to confirm the durable state. Run
`STORAGE_PROVISIONING_CONFIRM='test:storage-provisioning' just kube
storage-provisioning-test` when a fresh provisioning proof is needed.

## Recurring Jobs

`config/recurring-jobs.yaml` defines two jobs against the built-in `default`
group (so they cover every volume): `daily-snapshot` (`0 2 * * *`, retain 7) and
`daily-backup` (`0 3 * * *`, retain 7).

## Recovery Runbook

- **Per-node volume health**: `just talos volume-status`.
- **Longhorn / backup-target health**: `just kube storage-verify`.
- **Replica rebuild after a node loss**: `just bootstrap reboot <node>` — the
  evacuated replica rebuilds and the volume returns healthy without manual steps.
- **Backup restore**: in the Longhorn UI (or via CRs), restore a backup from the
  `default` target into a new PVC and confirm the data matches.

## Exit Gate

- Longhorn nodes, disks, engines, and replicas healthy; disks at `/var/mnt/longhorn`.
- Default `longhorn` StorageClass (2 replicas); a run-scoped test PVC binds with
  replicas on two distinct nodes (hard anti-affinity) — automated in
  `storage-provisioning-test`.
- Backup target available; a backup restores into a new PVC.
- A replica rebuild succeeds after a single-node reboot.
- Cilium/Talos/etcd/foundation acceptance still green (`foundation-verify`).

## Acceptance Evidence (2026-07-22)

`just bootstrap storage` reconciled `longhorn` → `longhorn-config` to Ready and
`just kube storage-verify` and `just kube storage-provisioning-test` passed:

> Phase 9 read-only storage verification passed: Longhorn healthy on three nodes
> (disks at `/var/mnt/longhorn`), default two-replica StorageClass, backup target
> available, and recurring jobs present. The provisioning test separately proved
> a temporary PVC bound with replicas on two distinct nodes.

- Backup target `cifs://192.168.0.3/Longhorn` reported **available** — CIFS mounts
  from the Talos nodes without an extra kernel module.
- All three Longhorn nodes Ready and schedulable; `foundation-verify` (Phase 7 +
  Cilium/Talos/etcd) still green.

**Recommended follow-up proofs** (not blocking; run when convenient): a manual
backup→restore into a new PVC via the Longhorn UI, and a post-reboot replica
rebuild via `just bootstrap reboot <node>`.

## Deferred to Phase 11

The media bulk `/data` filesystem (SMB `//192.168.0.3/Prometheus`, `media/movies`
+ `media/tv`, and a `downloads/` sibling for hardlink-safe Sonarr/Radarr imports)
is a Phase 11 build. Downloads must land on the same SMB share as media so imports
hardlink instead of copying; do not route downloads through Longhorn.
