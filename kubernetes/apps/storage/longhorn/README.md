# Longhorn

Longhorn chart `1.12.0` provides replicated block storage for application config
and state. Replicas live on the dedicated Talos user volume at
`/var/mnt/longhorn` (500 GiB per node); the default `longhorn` StorageClass uses
two replicas with **hard** node anti-affinity (`replicaSoftAntiAffinity: false`),
tolerating one node loss.

`ks.yaml` stages two Flux Kustomizations: `longhorn` (the controller HelmRelease)
then `longhorn-config` (`dependsOn: longhorn`) for the CIFS backup credential and
the recurring snapshot/backup jobs.

Backups go to `cifs://192.168.0.3/Longhorn`. Longhorn 1.7+ removed the
`backup-target` settings, so the target is declared as the `default`
**`BackupTarget`** CR (`config/backup-target.yaml`) referencing the
`nas-credentials` Secret (`CIFS_USERNAME`/`CIFS_PASSWORD`). That Secret is
SOPS-encrypted and created only by the guarded `just repo storage-secrets`
workflow — never hand-edited or copied from the legacy repository.
`config/recurring-jobs.yaml` runs a daily snapshot (retain 7) and a daily backup
(retain 7) against the built-in `default` group.

Talos prerequisites: the `siderolabs/iscsi-tools` and
`siderolabs/util-linux-tools` extensions, the `/var/mnt/longhorn` user volume, and
`machine.kubelet.extraMounts` exposing that path with shared propagation.

Use the guarded `just repo storage-secrets` / `just kube storage-validate` /
`just bootstrap storage` / `just kube storage-verify` workflow. The
[platform specification](../../../../docs/specs/011-talos-flux-platform.md) records the
storage design rationale, and the [recovery runbook](../../../../docs/runbooks/recovery.md)
covers storage failures.
