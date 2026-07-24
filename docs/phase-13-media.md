# Phase 13: Media Platform — Automation (Prowlarr, Sonarr, Radarr)

## Status

**In progress.** **Prowlarr** passed its guarded live acceptance gate on 2026-07-24
(Ready, rollout complete, HTTPRoute Accepted, DNS and `/ping`) and is now durable with
`suspend: false`. **Sonarr** and **Radarr** remain staged with `suspend: true` for their
separate operator rollouts. All three are low-risk relative to Phase 12 — no VPN, no
privileged containers, and no secrets in Git; API keys and inter-app links are first-run
settings persisted in each config PVC.

## Design (uniform across the three)

- One HelmRelease per app (app-template `5.0.1`, OCIRepository `app-template`), single
  replica, `strategy: Recreate` on a **Longhorn RWO** config PVC (single-writer SQLite),
  `helm.sh/resource-policy: keep` so config survives a teardown. Runtime `568:568`, drops
  all caps, no privilege escalation. Health via `/ping` (unauthenticated 200) for all
  three probes — a hung app fails readiness instead of falsely passing a TCP check.
- **Prowlarr** — config-only (`:9696`); it pushes indexers to Sonarr/Radarr over their
  APIs, so it needs no `/data`. `dependsOn: [media, internal-gateway]`.
- **Sonarr** (`:8989`) / **Radarr** (`:7878`) — also mount the shared SMB PVC
  `media-data` at `/data`, so imports **hardlink** from `/data/downloads` into
  `/data/media/{tv,movies}` (same filesystem — never a copy). `dependsOn:
  [media-storage, internal-gateway]`.
- HTTPRoutes `{prowlarr,sonarr,radarr}.lab.supermorphic.com` (internal gateway, wildcard
  TLS) with `gethomepage.dev` service tiles (pod-selector). Prowlarr includes its live
  activity widget; Homepage receives the API key from the independently rotatable,
  SOPS-encrypted `homepage-prowlarr` Secret.
- **Image pins:** `prowlarr 2.1.5.5216`, `sonarr 4.0.18.2978`, `radarr 5.28.0.10205`.
  Radarr is pinned to the latest **v5** rather than the new **v6.0.0** major — deliberately
  conservative for a fresh, not-yet-live-tested install; bump to 6.x when ready.

## Dependency graph

```text
media  (namespace + app-template OCIRepository)
├── prowlarr        [media, internal-gateway]
media-storage  (static RWX SMB PV + media-data PVC)
├── sonarr          [media-storage, internal-gateway]
└── radarr          [media-storage, internal-gateway]
```

## Observability

Gatus `Media`-group `/ping` probes are activation-aware: Prowlarr is monitored now;
Sonarr and Radarr are added only when their `suspend` flags are durably set to `false`.
This proves DNS → gateway → app without creating false alarms for staged workloads that
do not exist yet. Homepage shows a pod-status tile per app and a live Prowlarr widget.

## Validation

`just ci` includes `arr-validate` (one recipe over all three): files, wiring, no-secret
`ks`, dependency graph, app-template chartRef, config PVC (RWO + Recreate + keep), shared
`/data` for sonarr/radarr, HTTPRoutes, activation-aware Gatus probes, and the pinned render.
The Prowlarr checks also enforce its Homepage widget type, in-cluster URL, secret-backed
key placeholder, and supported activity fields.

## Rollout (operator, after merge — per app)

Recommended order: **Prowlarr first**, then Sonarr and Radarr.

```bash
# from any clean branch/worktree after the rollout source is merged to main
git fetch origin main
git status --short  # must print nothing
export ARR_BOOTSTRAP_CONFIRM='bootstrap:phase13:prowlarr'
mise exec -- just bootstrap arr prowlarr
mise exec -- just kube arr-verify prowlarr
# then set suspend: false in Git for prowlarr/ks.yaml, commit, push, rerun arr-verify
```

Repeat with `sonarr` / `radarr` (confirm string `bootstrap:phase13:<app>`).

### First-run wiring (manual, persists in config PVCs)

1. On Prowlarr's initial authentication screen select **Forms (Login Page)**, keep
   **Authentication Required** set to **Enabled**, and create a strong unique login.
   The account is stored in `prowlarr.db` on the retained config PVC; pod replacement,
   upgrades, and node rescheduling do not require recreating it. Recover an empty/lost
   PVC from Longhorn/Prowlarr backups rather than committing the dynamic config database.
2. Create the Homepage widget Secret from Prowlarr **Settings → General → API Key**:

   ```bash
   read -rs PROWLARR_API_KEY
   export PROWLARR_API_KEY
   export HOMEPAGE_PROWLARR_SECRETS_CONFIRM='write:monitoring:homepage-prowlarr:sops'
   mise exec -- just repo homepage-prowlarr-secrets
   unset PROWLARR_API_KEY HOMEPAGE_PROWLARR_SECRETS_CONFIRM
   ```

   Commit only the resulting `homepage-prowlarr.sops.yaml`; never the plaintext key.
3. **Prowlarr** → add indexers → add Sonarr & Radarr as **Apps** (their URLs +
   API keys) so indexers sync automatically.
4. **Sonarr/Radarr** → **Download client** = qBittorrent at
   `http://qbittorrent.media.svc.cluster.local:8080`; **root folders**
   `/data/media/tv` and `/data/media/movies`.
5. Confirm the qBittorrent save path is under `/data/downloads` so imports hardlink.

## End-to-end gate (do not claim Phase 13 "done" until)

Run a direct Sonarr/Radarr **search → download → hardlink import → visible in Plex**
test. Phase 12's kill-switch gate has passed and qBittorrent is active, so this gate
does not depend on Seerr. Capture the test evidence and repeat the hardlink proof from
`docs/phase-11-media.md`. The full **Seerr request → download → import → Plex** flow is
the separate Phase 14 acceptance gate.
