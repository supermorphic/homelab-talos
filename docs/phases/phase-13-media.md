# Phase 13: Media Platform — Automation (Prowlarr, Sonarr, Radarr)

## Status

**In progress.** **Prowlarr** and **Sonarr** passed their guarded live acceptance gates
on 2026-07-24 (Ready, rollout complete, HTTPRoute Accepted, DNS and `/ping`) and are
durable with `suspend: false`. **Radarr** is activated with `suspend: false` on
2026-07-25 for its guarded operator rollout; the direct download acceptance test is the
remaining Phase 13 gate. All three are low-risk relative to Phase 12 — no VPN, no
privileged containers, and no plaintext secrets in Git. API keys and inter-app links are
first-run settings persisted in each config PVC; any Homepage integration copy is stored
only in an independently rotatable SOPS-encrypted Secret.

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
- **Image pins:** `prowlarr 2.5.2.5491`, `sonarr 4.0.18.2978`, `radarr 6.4.0.10523`.
  Radarr was bumped from the initial conservative **v5** pin to the current **v6** once the
  stack was live. The v6 upgrade runs a **one-way config-DB migration** — snapshot the
  radarr config PVC before the rollout, as it cannot be cleanly downgraded afterward.

## Dependency graph

```text
media  (namespace + app-template OCIRepository)
├── prowlarr        [media, internal-gateway]
├── flaresolverr    [media]                       (stateless, in-cluster only; optional per-indexer proxy)
media-storage  (static RWX SMB PV + media-data PVC)
├── sonarr          [media-storage, internal-gateway]
└── radarr          [media-storage, internal-gateway]
```

**FlareSolverr (optional):** a stateless headless-Chromium proxy (ClusterIP `:8191`, no
PVC, no HTTPRoute, no VPN) that Prowlarr uses as a **per-indexer** Indexer Proxy to reach
Cloudflare-protected indexers (e.g. 1337x). It shares Prowlarr's direct egress (same NAT
IP — routing it through the VPN would break the Cloudflare session). Activated
`suspend: false` on 2026-07-25 after its guarded `just bootstrap flaresolverr` rollout
passed live acceptance (Ready, rollout, Service endpoints, `GET /` ready). Pinned to the
image's own uid/gid `1000` (`runAsNonRoot` cannot verify the image's non-numeric `USER`, so
a numeric UID is required to start). It is exempt in `media.rego` from the config-PVC and
HTTPRoute requirements via `stateless_internal_apps`; all other policies (pinned tag,
drop-ALL caps, dependency order) still apply. Its Gatus probe hits the ClusterIP Service DNS
directly (no HTTPRoute) and means "solver alive," not "1337x works." See
[`arr-stack-startup.md`](../arr-stack-startup.md) for the Prowlarr proxy wiring and the
experiment's abort condition.

## Observability

Gatus `Media`-group `/ping` probes are activation-aware: Prowlarr, Sonarr, and Radarr
are monitored now, each added when its `suspend` flag is durably set to `false`. This
proves DNS → gateway → app without creating false alarms for staged workloads that do
not exist yet. Homepage shows a pod-status tile per app and live Prowlarr widget.

## Validation

`just ci` includes `arr-validate` (one recipe over all three): files, wiring, no-secret
`ks`, dependency graph, app-template chartRef, config PVC (RWO + Recreate + keep), shared
`/data` for sonarr/radarr, HTTPRoutes, activation-aware Gatus probes, and the pinned render.
The Prowlarr checks also enforce its Homepage widget type, in-cluster URL, secret-backed
key placeholder, while leaving the widget to display its complete default field set.

## Rollout (operator, after merge — per app)

Recommended order: **Prowlarr first**, then Sonarr and Radarr. All three sources are now
activated (`suspend: false`); run each app's guarded `just bootstrap arr <app>` rollout
if it has not been brought up yet, then confirm with `arr-verify`. The confirmation token
changed: `bootstrap:phase13:<app>` is no longer accepted; use `bootstrap:arr:<app>`.
For the canonical current runbook, see [`arr-stack-startup.md`](../arr-stack-startup.md).

```bash
# from any clean checkout after the rollout source is merged to main
git fetch origin main
git status --short  # must print nothing
export ARR_BOOTSTRAP_CONFIRM='bootstrap:arr:prowlarr'
mise exec -- just bootstrap arr prowlarr
mise exec -- just kube arr-verify prowlarr
# then set suspend: false in Git for prowlarr/ks.yaml, commit, push, rerun arr-verify
```

Repeat with `sonarr` / `radarr` (confirm string `bootstrap:arr:<app>`).

### First-run wiring (manual, persists in config PVCs)

Follow the canonical greenfield checklist in
[`arr-stack-startup.md`](../arr-stack-startup.md). The summary below records the
Phase 13-specific requirements.

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
3. In Sonarr, select **Forms (Login Page)** with authentication **Enabled**, then set
   **root folder** `/data/media/tv` and **download client** qBittorrent at
   `http://qbittorrent.media.svc.cluster.local:8080` using qBittorrent's permanent
   WebUI username/password. Use the equivalent settings in Radarr. qBittorrent's subnet
   authentication bypass stays disabled.
4. In Prowlarr, add indexers and add **Sonarr** as an App using
   `http://sonarr.media.svc.cluster.local:8989` plus Sonarr's API key. Add Radarr after
   its rollout using the equivalent in-cluster URL and API key.
5. Confirm the qBittorrent save path is under `/data/downloads` so Sonarr imports
   hardlink rather than copy.

## End-to-end gate (do not claim Phase 13 "done" until)

Run a direct Sonarr/Radarr **search → download → hardlink import → visible in Plex**
test. Phase 12's kill-switch gate has passed and qBittorrent is active, so this gate
does not depend on Seerr. Capture the test evidence and repeat the hardlink proof from
`docs/phases/phase-11-media.md`. The full **Seerr request → download → import → Plex** flow is
the separate Phase 14 acceptance gate.
