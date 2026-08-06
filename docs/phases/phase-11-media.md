# Phase 11: Media Platform — Shared Storage and Plex

## Status

**Complete (2026-07-23).** Phase 11 stood up the shared SMB `/data` filesystem and
brought Plex into the cluster (it historically ran off-cluster on the Mac Mini),
migrating the existing server's identity + library database + watch history. The
Mac-mini install has been decommissioned. The VPN download client (Phase 12), the
*arr automation apps (Phase 13), and requests + observability (Phase 14) follow as
their own phases.

| Deliverable | State |
|---|---|
| SMB CSI driver + shared `/data` RWX filesystem | **Complete** (bootstrapped) |
| Plex (single replica, migrated, node-reschedule verified) | **Complete** (2026-07-23) |
| Plex hardware transcoding (Intel QuickSync) | **Complete** (2026-07-23) — enable the Plex "use hardware acceleration" toggle to activate |

## Delivery pattern (every app)

Same as Phase 10: `kubernetes/apps/<domain>/<app>/` with a staged `ks.yaml`
(`suspend: true`) → `app/` (manifests/HelmRelease + any SOPS secret) → optional
`config/`. Guarded workflow: `just repo <app>-secrets` (if secrets) →
`just kube <app>-validate` → commit/push/PR → merge → `just bootstrap <app>` →
`just kube <app>-verify` → durable `suspend: false` flip.

Media apps use the bjw-s **app-template `5.0.1`** chart (OCIRepository
`oci://ghcr.io/bjw-s-labs/helm/app-template`), one HelmRelease per app, all image
tags pinned. UIs are exposed only through the `internal` Envoy Gateway
(`sectionName: https`, `*.lab.supermorphic.com`), with the app namespace carrying
`gateway.supermorphic.com/access: internal`.

## Shared `/data` storage foundation

- `kubernetes/apps/storage/csi-driver-smb/` — the SMB CSI driver
  (`smb.csi.k8s.io`), chart pinned, namespace `csi-driver-smb` (PSA `privileged`),
  `dependsOn: cilium`.
- `kubernetes/apps/media/` — the `media` namespace (PSA `privileged` +
  gateway-access label), a shared `app-template` OCIRepository, and a **single
  static RWX PersistentVolume** bound to `//192.168.0.3/Prometheus` with a
  `media-data` PVC mounted at `/data` in every media pod.
- One share, one PVC: `downloads/` and `media/` are subfolders on the same share so
  Sonarr/Radarr imports **hardlink** instead of copying. Bulk media never lives on
  Longhorn.
- Directory layout:
  ```text
  /data/
  ├── downloads/{incomplete,movies,tv}
  └── media/{movies,tv}
  ```
- SMB credentials come from a SOPS Secret written by `just repo media-smb-secrets`;
  runtime UID/GID and SMB mount modes (`uid=/gid=/file_mode=/dir_mode=`) are chosen
  so Plex and the later *arr/qBittorrent apps share consistent ownership without a
  startup `chown` of the library.

### Acceptance evidence — hardlink proof

**Evidence (2026-07-23):** a guarded Job mounted the `media-data` PVC, created a file
under `/data/downloads` and hardlinked it into `/data/media`; both paths reported the
**same inode (927) with link count 2** — the UNAS SMB share + mount options preserve
hardlinks across the `downloads`↔`media` subtrees. Phase-13 *arr imports will hardlink,
not copy.

## Plex

This is **single-active Plex with automatic Kubernetes + Longhorn recovery across
nodes** — not highly available Plex. On a hard node failure expect a **minutes-not-
seconds** outage while Kubernetes marks the node gone, Longhorn detaches/reattaches the
config volume, and Plex starts and checks its database.

- `kubernetes/apps/media/plex/` — app-template HelmRelease, single Plex container
  (pinned image), config PVC on Longhorn (**ReadWriteOncePod**) with `strategy:
  Recreate`, media from the shared `media-data` RWX PVC mounted at `/Volumes/Prometheus`
  (the SMB share root — matches the paths the previous Mac-mini Plex recorded,
  `/Volumes/Prometheus/media/{movies,tv}`, so a migrated library database resolves with
  zero re-matching; the later *arr apps mount this same share at `/data`), transcode
  scratch on a node-local `emptyDir` (never the NAS). A 120s termination grace period
  lets Plex close its SQLite DB cleanly on planned drains.
- Exposed at `plex.lab.supermorphic.com` through the internal Envoy gateway only,
  LAN-only; remote/public streaming deferred. **No MetalLB LoadBalancer / no direct
  `:32400` LAN IP** — so local GDM auto-discovery does not work; clients connect via the
  custom access URL (below).
- Plex stays a single replica (no active-active support). The RWX SMB share is
  shared across pods/apps, not for Plex replicas.

### First-run (manual, one-time)
- Sign in at `https://plex.lab.supermorphic.com` (the short-lived `plex.tv/claim` token
  is never committed).
- **Settings → Network → Custom server access URLs:** add
  `https://plex.lab.supermorphic.com` so clients reach Plex through the gateway (needed
  because there is no direct `:32400` LAN IP).
- Add libraries from `/data/media/movies` and `/data/media/tv`.
- **Settings → Transcoder:** set the transcode temporary directory to `/transcode`.
- **Enable Plex's scheduled database backups** (Settings → Scheduled Tasks) as a second
  layer beyond Longhorn.
- **Disable "Empty trash automatically after every scan"** so a transient SMB/NAS outage
  does not delete library entries when media briefly disappears.

### Backups
The Plex `/config` PVC is **already covered by the existing Longhorn RecurringJobs**
(`daily-snapshot` + `daily-backup`, group `default`) — no Plex-specific or higher-cadence
jobs are added (they would conflict with the global policy). Longhorn replication is not
a backup; the daily off-cluster backup to the NAS + Plex's own scheduled DB backup are.
Periodically restore a Longhorn backup into a throwaway PVC to prove it (see the test
matrix).

### Acceptance evidence — node-failure reschedule (Phase-11 gate)

The point of this phase: prove the single Plex replica recreates on another NUC when
its node goes away, with the Longhorn config volume re-attaching and the SMB media
re-mounting.

- **Safe form (Chainsaw resilience scenario):**
  `CLUSTER_CHAOS_CONFIRM='chaos:plex-cross-node-reschedule' just test resilience
  plex-cross-node-reschedule` cordons the node running Plex, deletes the pod,
  waits for it to come back **Ready on a different node**, then uncordons. This
  exercises the config re-attach + SMB re-mount + Recreate path without a full outage.
- **Full node-down form:** power off the node running Plex and confirm the pod
  reschedules automatically. This requires Longhorn `nodeDownPodDeletionPolicy=
  delete-both-statefulset-and-deployment-pod` (set in the Longhorn values) — the default
  `do-nothing` leaves the pod stuck `Terminating` (RWOP blocks the replacement) and it
  never recreates.

Full acceptance test matrix to record before calling Phase 11 done:

| Test | Expectation |
|---|---|
| Controlled cross-node reschedule (`just test resilience plex-cross-node-reschedule`) | Plex stops cleanly, config re-attaches on another NUC, same server identity + library |
| Hard node-down (power off the Plex node) | Automated recovery after Longhorn's node-down timeout; measure RTO |
| One Longhorn replica lost | Plex keeps serving from the surviving replica; replica rebuilds |
| SMB/NAS outage | `/config` DB stays healthy; media returns when the share is back; library not trashed |
| Longhorn restore | Restore the `/config` backup into a throwaway PVC and start an isolated Plex against it |

**Evidence — graceful (2026-07-23):** the predecessor guarded reschedule proof
passed — pod moved `nuc2 -> nuc1`, the RWOP config volume re-attached, SMB media
re-mounted, and Plex became Ready. That proof is now owned by the richer
`plex-cross-node-reschedule` Chainsaw resilience scenario. `plex-verify` also
passed (Kustomization + HelmRelease Ready, rollout, HTTPRoute Accepted, Pi-hole
DNS, `/identity` over TLS).

**Evidence — hard node-down (2026-07-23):** nuc2 (running Plex) was **physically powered
off**. With `nodeDownPodDeletionPolicy=delete-both-…` set, Longhorn force-deleted the
stuck pod (~235 s), Kubernetes rescheduled Plex onto **nuc1**, the RWOP config volume
re-attached from the surviving nuc1 replica, and `/identity` returned 200 — **RTO ≈ 8 min,
fully automatic, no manual intervention.** Library intact (same `machineIdentifier`
`c71409d6…`, `claimed=1` → the migrated config volume, not a fresh one). After nuc2 was
powered back on it rejoined `Ready` and Longhorn rebuilt the nuc2 replica → `robustness=
healthy` (2 replicas). RTO is on the high end (dominated by the 300 s
`node.kubernetes.io/unreachable` toleration); lower that toleration on the pod if faster
recovery is ever wanted.

<!-- TODO (optional, deferred): one-replica-loss check, SMB-outage behavior, and a
     Longhorn restore-into-new-PVC test. -->

## Plex hardware transcoding (Intel QuickSync)

- Confirm the `siderolabs/i915` extension exposes `/dev/dri/renderD128` on every
  NUC, deploy the Intel GPU device plugin, validate `gpu.intel.com/i915` resource
  discovery, and request it in the Plex pod.
- The `gpu.intel.com/i915` request itself targets Plex to GPU-capable nodes (the device
  plugin advertises the resource only where `/dev/dri` exists), so no hard node-pin; a
  `media.supermorphic.com/plex-capable` label + nodeAffinity is the fallback for finer
  control.
- Gated after the reschedule milestone so GPU scheduling does not complicate that
  proof. All three NUCs carry `i915`, so the pod can still schedule anywhere.

### Acceptance evidence — hardware transcode

**Evidence (2026-07-23):** the standalone Intel GPU device plugin
(`intel/intel-gpu-plugin:0.36.0`, DaemonSet in `kube-system`) is live and **all three
NUCs advertise `gpu.intel.com/i915=1`** — the `siderolabs/i915` extension exposes
`/dev/dri`. Plex requests `gpu.intel.com/i915: 1`, so it schedules onto a GPU-capable
node and the plugin (via CDI) injects `/dev/dri/renderD128` **owned by the runtime user
`568` and world-writable** — verified inside the Plex pod, so no `supplementalGroups`
are needed. Final activation is the Plex UI toggle **Settings → Transcoder → "Use
hardware acceleration when available"**; a transcode then shows **"(hw)"** in the
dashboard.

## Migration note (Mac-mini → cluster, 2026-07-23)

The existing Mac-mini Plex was migrated by copying its data dir into the `/config`
volume (through the SMB share as the transfer conduit) — preserving server identity,
library database, watch history, and metadata. Gotchas encountered: 17,515 macOS `._*`
AppleDouble files from `tar` hung Plex's boot (purged); the auth token didn't survive
(re-claimed via `/myplex/claim` over a localhost port-forward); and smart-collection
composite art referenced a stale server ID (`75cfa7ee…`) from an earlier server —
repointed in `metadata_items.extra_data` to the current ID with a DB copy + integrity
check as safeguards. A pre-repoint Longhorn backup to the NAS was taken first.

## Recovery notes

<!-- TODO (finalized in Phase 14): Plex config PVC recovery via Longhorn backup;
     bulk media is NAS-owned (not in Longhorn backups); reschedule behavior. -->
