# Media Stack Plan (single source of truth)

The one plan for the `homelab-talos` media platform — Plex, qBittorrent + Gluetun
(ProtonVPN WireGuard), Prowlarr, Sonarr, Radarr, and **Seerr**. It consolidates the
original handoff brief and the repo-native architecture into one document. Per-phase
execution detail + acceptance evidence live in the phase runbooks
(`docs/phase-11-media.md`, `docs/phase-12-media.md`, …); this plan is the durable
requirements + design + status.

> **Seerr, not Overseerr.** The request UI is **Seerr** — the current, maintained
> distribution (`docs.seerr.dev`), the successor to the original (now-stale)
> `sctx/overseerr`. Do **not** deploy the legacy Overseerr. Pin the exact current Seerr
> image at Phase-14 build time.

## Phase status

| Phase | Scope | Status |
|---|---|---|
| 11 | Shared SMB `/data` + Plex (single replica, reschedule-verified, QuickSync) | **Complete** (2026-07-23) |
| 12 | VPN download client — qBittorrent + Gluetun (ProtonVPN) | **Complete** (2026-07-24) |
| 13 | Automation — Prowlarr, Sonarr, Radarr | **In progress** — all three activated; direct download acceptance test pending (2026-07-25) |
| 14 | Requests + observability — **Seerr**, Gatus/Homepage/dashboards | **In progress** — Seerr activated; first-run wiring + request test pending (2026-07-25) |

## Objective & boundaries

Deploy the stack as separate single-replica workloads, one exception: **qBittorrent +
Gluetun share one Pod** (one network namespace) so all of qBittorrent's traffic egresses
through the VPN. Plex is in-cluster (migrated from the Mac Mini). Do **not** tunnel the
*arr/Seerr apps through the VPN. Kubernetes + Flux GitOps only — no Compose/Ansible.

## Repository conventions (verified)

- App dir `kubernetes/apps/<domain>/<app>/{ks.yaml, app/, [config/]}`; `ks.yaml` in
  `flux-system`, `dependsOn` uses other `ks.yaml` names; `decryption {provider: sops,
  secretRef {name: sops-age}}` when the path holds a `*.sops.yaml`.
- **Chart:** bjw-s **app-template `5.0.1`** via the shared `media`-namespace
  OCIRepository (`oci://ghcr.io/bjw-s-labs/helm/app-template`); one HelmRelease per app;
  all image tags pinned. Values → standalone `values.yaml` → `configMapGenerator`
  (`disableNameSuffixHash: true`, label `reconcile.fluxcd.io/watch: Enabled`) →
  `valuesFrom`.
- **Exposure:** HTTPRoute → Gateway `internal`/`networking`/`sectionName: https`, host
  `<app>.lab.supermorphic.com`, annotation `external-dns.k8s.io/audience: internal`;
  namespace label `gateway.supermorphic.com/access: internal`. Wildcard
  `*.lab.supermorphic.com` cert already covers all names. No public Gateway. Homepage
  auto-discovers tiles via `gethomepage.dev/*` annotations (incl. `pod-selector`).
- **Secrets:** SOPS-encrypted, created only via guarded `just repo *-secrets`
  (operator-run, `*_CONFIRM`, never printing values). Age recipient `age1da2cy…ne9wlx`.
- **`just`:** each app adds a cluster-independent `<app>-validate` to the root `.justfile
  ci`; `<app>-verify` + `bootstrap <app>` stay operator-only.

## Architecture decisions (locked)

1. **Namespace:** one `media` namespace, PSA `privileged` (the qBittorrent/Gluetun pod
   needs NET_ADMIN, Plex needs `/dev/dri`).
2. **Shared media `/data`:** one static **RWX** PV via `csi-driver-smb` bound to
   `//192.168.0.3/Prometheus`, `media-data` PVC, `downloads/` + `media/` siblings on the
   one share (hardlink-safe — proven). Bulk media never on Longhorn.
3. **App config:** Longhorn RWO/RWOP PVC per app, Deployment `strategy: Recreate`,
   `helm.sh/resource-policy: keep`; covered by the daily Longhorn snapshot+backup jobs.
   Longhorn `nodeDownPodDeletionPolicy=delete-both-…` gives auto-failover on a hard
   node-down (cluster-wide, covers every Longhorn-backed workload).
4. **Plex:** single replica, QuickSync via the Intel GPU device plugin (`/dev/dri`),
   media mounted at `/Volumes/Prometheus` (matches the migrated DB paths).
5. **VPN:** Gluetun native sidecar (fail-closed startup + firewall kill switch),
   `NET_ADMIN` + `hostPath /dev/net/tun`, no privileged mode; ProtonVPN WireGuard;
   Gluetun-native port forwarding; control API in-cluster only, role-authed.
6. **Config = manual first-run** for *arr/Seerr API keys and inter-app links (persisted
   in config PVCs); declarative *arr API automation is intentionally rejected.

## Dependency graph (Flux `dependsOn`)

```text
cilium
├── csi-driver-smb                                   (Phase 11)
├── media (namespace + shared app-template OCIRepository)
│   └── media-storage [media, csi-driver-smb] (static RWX PV + media-data PVC)
│       ├── plex        [media-storage, internal-gateway]   (Phase 11)
│       ├── qbittorrent [media-storage, internal-gateway]   (Phase 12)
│       ├── prowlarr    [media-storage, internal-gateway]   (Phase 13)
│       ├── sonarr      [media-storage, internal-gateway]   (Phase 13)
│       ├── radarr      [media-storage, internal-gateway]   (Phase 13)
│       └── seerr       [media-storage, internal-gateway]   (Phase 14)
└── intel-gpu-plugin (kube-system)                   (Phase 11, Plex QuickSync)
```

## File tree

```text
kubernetes/apps/storage/csi-driver-smb/            (Phase 11)
kubernetes/apps/kube-system/intel-gpu-plugin/      (Phase 11)
kubernetes/apps/media/
├── kustomization.yaml
├── namespace/   (media ns + shared app-template OCIRepository)
├── storage/     (static RWX SMB PV/PVC + smb-credentials.sops)
├── plex/        (Phase 11)
├── qbittorrent/ (Phase 12; protonvpn.sops)
├── prowlarr/ sonarr/ radarr/  (Phase 13)
└── seerr/       (Phase 14)
```

## Storage / networking / security / secrets

- **Consistent paths:** qBittorrent/Sonarr/Radarr mount the one share at `/data`
  (`/data/downloads/{incomplete,movies,tv}`, `/data/media/{movies,tv}`); Plex reads
  `/data/media`. Runtime UID/GID `568:568` (SMB mount forces ownership; no startup
  `chown`). Hardlinks between `downloads`↔`media` verified (same inode).
- **Service-to-service:** in-cluster DNS only. Sonarr/Radarr →
  `http://qbittorrent.media.svc.cluster.local:8080`; Prowlarr → Sonarr/Radarr APIs;
  Seerr → Sonarr/Radarr + Plex. Never via the gateway.
- **Security:** only the qBittorrent/Gluetun pod is privileged (NET_ADMIN +
  `/dev/net/tun`); Plex uses `/dev/dri`, no NET_ADMIN; *arr/Seerr run non-root drop-ALL.
  No host networking/hostPort/runtime socket; dedicated ServiceAccounts, automount off
  where unused. Gluetun control API never exposed via HTTPRoute/LB.
- **Secrets:** `smb-credentials` (SMB), `protonvpn` (WireGuard key + Gluetun control
  apikey), `homepage-grafana` + `homepage-plex` + `homepage-prowlarr` (split
  per-service widget creds, rotate independently) — SOPS, via guarded recipes.

## VPN kill switch (Phase 12) — the hard requirement

Two layers: **(1) startup gating** — Gluetun as a native sidecar (`restartPolicy:
Always` + startup probe on the control server) so qBittorrent starts only after the
tunnel+firewall are up; **(2) ongoing firewall** — Gluetun drops all egress except the
tunnel + allowed cluster subnets. qBittorrent holds no NET_ADMIN, so it cannot alter
routes — but fail-closed still *depends on* Gluetun retaining its rules, hence the
**blocking, live `qbittorrent-killswitch-verify`** gate: VPN public IP ≠ home WAN; stop
the VPN → egress fails closed (never the home IP); a hard Gluetun-container kill also
holds; recovery reacquires + reapplies the forwarded port. Phase 12 is not activated
until it passes. Details: `docs/phase-12-media.md`.

## Per-app scope

- **Plex** — media server (in-cluster). Libraries `/data/media/{movies,tv}`. Done.
- **qBittorrent + Gluetun** — download client behind ProtonVPN; config on Longhorn, `/data`
  shared; WebUI via gateway; localhost-auth bypass only for the Gluetun port-forward hook.
- **Prowlarr** — indexer manager; config PVC only; syncs indexers into Sonarr/Radarr.
- **Sonarr / Radarr** — TV/movies; config PVC + `/data`; root folders
  `/data/media/{tv,movies}`; download client = the qBittorrent Service; hardlink imports.
- **Seerr** — household request UI (the current maintained Seerr, not Overseerr); links
  Sonarr/Radarr + Plex. Primary request interface; does not replace the *arr admin UIs.

## Requirements & constraints (from the brief)

- Keep qBittorrent behind Gluetun/ProtonVPN; do not tunnel the whole namespace; do not
  let qBittorrent use the node WAN path.
- Do not store bulk media on Longhorn; do not use node-local `hostPath` for bulk media.
- No `:latest` tags; no plaintext secrets; do not expose Gluetun's control API or a
  public Gateway; do not run multiple active replicas of any stateful app.
- Do not break existing Flux dependency chains or bypass the gateway/DNS/cert/SOPS
  patterns.

## Validation & Definition of Done

Per app: `just ci` (`<app>-validate` + kubeconform render) → guarded `bootstrap <app>` →
`<app>-verify` (Kustomization/HelmRelease Ready, rollout, HTTPRoute Accepted, Pi-hole
DNS, TLS). Phase gates: hardlink proof; Plex node-failure reschedule (graceful + hard) +
QuickSync; **VPN kill-switch** (public-IP=ProtonVPN + fail-closed + port-forward
reacquire); end-to-end request→download→hardlink-import→visible-in-Plex; Gatus detects
app + VPN failures. Done when all of the above are in Git, reconciled, and verified, and
recovery + manual first-run settings are documented.

## Open items

1. Exact pinned Seerr image at Phase 14 (current maintained `docs.seerr.dev` distribution).
2. Prowlarr/Sonarr/Radarr resource sizing for library scans (generous mem, no CPU limit).
3. Whether Sonarr+Radarr ship as one PR or two (Phase 13).
