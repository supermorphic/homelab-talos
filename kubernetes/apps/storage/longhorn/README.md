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
The chart enables `allowRecurringJobWhileVolumeDetached` so those jobs can attach
and process labeled volumes after their last application Pod exits. This is a
Longhorn-wide setting: it applies to every detached volume selected by a recurring
job, including the OpenBao snapshot claim. Review its storage load when adding
other recurring-job groups or labeled claims.

Read-only inventory on 2026-09-27 found 20 selected Longhorn volumes. The live
`allow-recurring-job-while-volume-detached` setting was `false` at that observation.
The proposed `true` value is a global change and can reconcile when this PR merges,
even while OpenBao remains suspended. It requires explicit operator approval.

| Selection | Existing claims/workloads | Observed state |
| --- | --- | --- |
| Default group, `automation` | n8n-data, n8n-postgresql-data, n8n-postgresql-backups | Backup claim detached; two attached |
| Default group, `automation-data` | automation-data-postgresql-data, automation-data-postgresql-backups | Backup claim detached; data attached |
| Default group, `media` | Plex, Tautulli, Sonarr, Radarr, Lidarr, Prowlarr, qBittorrent, Seerr | Eight attached |
| Default group, `monitoring` | Grafana, Prometheus, Alertmanager | Three attached |
| Default group, other namespaces | test-reports, ntfy, Portainer | Three attached |
| Explicit Loki trim job | storage-loki-0 | Attached; not in the default group |

The 19 default-group volumes select snapshots at 02:00 UTC and backups at 03:00 UTC,
both with retention seven and concurrency two. Loki selects filesystem trim at 04:00
UTC on Sundays, concurrency one. Selection is recorded even for attached volumes:
they can become detached later. The setting can attach selected detached volumes
for eligible jobs, and application attachment can wait until the job finishes.
The two currently detached backup claims are the immediate daily-job beneficiaries.
The staged OpenBao backup claim is additional to this inventory. Repeat this inventory
before attended acceptance; this dated observation is not a permanent volume list.

Talos prerequisites: the `siderolabs/iscsi-tools` and
`siderolabs/util-linux-tools` extensions, the `/var/mnt/longhorn` user volume, and
`machine.kubelet.extraMounts` exposing that path with shared propagation.

Use the guarded `just repo storage-secrets` / `just kube storage-validate` /
`just bootstrap storage` / `just kube storage-verify` workflow. The
[platform specification](../../../../docs/specs/010-talos-flux-platform.md) records the
storage design rationale, and the
[platform disaster-recovery runbook](../../../../docs/runbooks/platform-disaster-recovery.md)
covers storage recovery during broader platform reconstruction.
