# Phase 14: Media Platform — Requests (Seerr) + observability wrap-up

## Status

**Staged (`suspend: true`).** **Seerr** — the official merger/successor of Overseerr +
Jellyseerr (`ghcr.io/seerr-team/seerr`) — is the request UI that ties Plex + Sonarr +
Radarr together. Low-risk: no VPN, no privileged containers, no secrets in Git (the Plex
and *arr API links + Seerr's own API key are first-run settings persisted in `/app/config`).

## Why Seerr (not Overseerr/Jellyseerr)

Overseerr and Jellyseerr have merged into **Seerr**; it is the actively-maintained line and
auto-migrates an existing Overseerr/Jellyseerr instance on first start. Pinned to the
current stable **`v3.0.1`**.

## Design

- One bjw-s app-template HelmRelease in `media`, single replica, `strategy: Recreate` on a
  **Longhorn RWO** config PVC (SQLite), `helm.sh/resource-policy: keep`. `568:568`, drops
  all caps. WebUI + API on `:5055`; health via unauthenticated `/api/v1/status`.
- **Config-only** — Seerr holds no media files, so it mounts no shared `/data`. Config +
  request DB live in `/app/config`.
- `dependsOn: [media, internal-gateway]` (needs the namespace/OCIRepository + gateway; the
  Plex/*arr links are runtime API calls, not deploy-order deps).
- HTTPRoute `seerr.lab.supermorphic.com` (internal gateway, wildcard TLS) + a
  `gethomepage.dev` tile. Its Gatus `Media`-group probe on `/api/v1/status` is added
  when Seerr is activated, so the staged workload does not generate a false alarm.
- **UID caveat:** the seerr-team image's runtime user is unverified here; `fsGroup: 568`
  chowns the fresh config PVC, but confirm `/app/config` is writable at rollout and adjust
  `runAsUser` if the image needs a different user.

## Validation

`just ci` includes `seerr-validate` (files, wiring, no-secret ks, dependency graph,
app-template chartRef, config PVC RWO+Recreate+keep at `/app/config`, no `media-data`,
HTTPRoute → `seerr:5055`, activation-aware Gatus probe, pinned render). Operator-only:
`seerr-verify`, `bootstrap seerr`.

## Rollout (operator, after merge)

```bash
export SEERR_BOOTSTRAP_CONFIRM='bootstrap:phase14:seerr'
just bootstrap seerr
just kube seerr-verify
# then set suspend: false in seerr/ks.yaml, commit, push, rerun seerr-verify
```

### First-run wiring (manual, persists in `/app/config`)

Follow the Seerr section of
[`arr-stack-startup.md`](arr-stack-startup.md) for every required field and
in-cluster URL.

Add **Plex** (sign in / server URL), then **Sonarr** and **Radarr** (their in-cluster URLs
`http://{sonarr,radarr}.media.svc.cluster.local:{8989,7878}` + API keys) with the TV/movie
root folders and quality profiles. Requests then flow Seerr → Sonarr/Radarr → qBittorrent →
hardlink import → Plex.

## Observability wrap-up (Phase 14 scope)

Already in place across the media stack:
- **Gatus** `Media` group: `plex`, `qbittorrent-vpn` (VPN health), and each activated
  app. Prowlarr and Sonarr are active; Radarr and Seerr are added at their activation
  commits.
- **Prometheus/Alertmanager:** `QbittorrentVpnDown` (critical) — the VPN kill-switch alert.
- **Homepage:** service tiles for every media app and a secret-backed Prowlarr activity
  widget.

Remaining/optional follow-ups (not blocking Seerr):
- A media/VPN **Grafana dashboard** (the Gatus `gatus_results_endpoint_success` series is
  already scraped and queryable; a bespoke dashboard is optional).
- Alertmanager **notification receiver** so `QbittorrentVpnDown` pushes to a channel
  (needs a channel + secret) — currently visible in Alertmanager/Prometheus/Grafana only.
- Finalize the media **recovery runbook** (config PVCs via Longhorn backups; bulk media
  NAS-owned; forwarded-port loss) once Phase 12 is live.

## End-to-end acceptance (deferred — do not claim the media platform "done" until)

A full **request in Seerr → download via qBittorrent (VPN) → hardlink import by
Sonarr/Radarr → visible in Plex** run. This depends on Phase 12's kill-switch gate having
passed and qBittorrent + the *arr stack being active. Capture the evidence then.
