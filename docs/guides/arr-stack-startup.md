# Media automation startup and acceptance

Use this guide to configure or rebuild the media applications whose runtime settings
live on application-managed persistent volumes. It covers qBittorrent, Prowlarr,
Sonarr, Radarr, Lidarr, Plex, Seerr, and Tautulli.

The current repository keeps these applications active. A genuine greenfield rebuild is
different: start the affected application through the guarded suspended-source workflow
in [Greenfield PVC bootstrap](#greenfield-pvc-bootstrap), complete the gates required by
that application's lifecycle, and make the active state durable through Git at the point
specified by the bootstrap recipe and this guide.

Do not commit application passwords, API keys, tracker credentials, cookies, tokens, or
unencrypted configuration exports. Keep operator credentials in the password manager.
Use a repository SOPS recipe only for a Kubernetes integration Secret that the repository
already defines.

## Mental model

Git and the applications own different parts of the system:

- Git owns Kubernetes resources, images, storage mounts, security controls, routes,
  network policy, monitoring configuration, and SOPS-encrypted integration Secrets.
- qBittorrent, Prowlarr, Sonarr, Radarr, Lidarr, Seerr, Plex, and Tautulli store much of
  their own runtime configuration in files or databases on retained PVCs.
- This guide records the human-configured state that Helm and Git do not currently
  express.
- A Ready Kubernetes workload proves that the process and its declared route are
  available. It does not prove that an indexer works, a download imports, Plex scans a
  library, or a Seerr request completes.

The applications use these paths:

| Service | Operator URL | In-cluster URL | Persistent configuration |
| --- | --- | --- | --- |
| qBittorrent | `https://qbittorrent.lab.supermorphic.com` | `http://qbittorrent.media.svc.cluster.local:8080` | `/config` |
| Prowlarr | `https://prowlarr.lab.supermorphic.com` | `http://prowlarr.media.svc.cluster.local:9696` | `/config` |
| Sonarr | `https://sonarr.lab.supermorphic.com` | `http://sonarr.media.svc.cluster.local:8989` | `/config` |
| Radarr | `https://radarr.lab.supermorphic.com` | `http://radarr.media.svc.cluster.local:7878` | `/config` |
| Lidarr | `https://lidarr.lab.supermorphic.com` | `http://lidarr.media.svc.cluster.local:8686` | `/config` |
| Plex | `https://plex.lab.supermorphic.com` | `http://plex.media.svc.cluster.local:32400` | `/config` |
| Seerr | `https://seerr.lab.supermorphic.com` | `http://seerr.media.svc.cluster.local:5055` | `/app/config` |
| Tautulli | `https://tautulli.lab.supermorphic.com` | `http://tautulli.media.svc.cluster.local:8181` | `/config` |

This guide uses four explanatory labels:

- **UI step** — make or confirm a setting in the application's web interface.
- **Repository check** — run a repository-owned verifier against deployed state.
- **Operator acceptance gate** — exercise real application behavior and judge the result.
- **Git change** — make durable Flux-managed state or encrypted integration data through
  the repository.

These labels explain this guide; they do not define new repository policy.

## Dependency order

For the user-facing applications configured in this guide, the Flux deployment
prerequisites and the recommended operator sequence are related but not identical. Flux
can reconcile independent applications in parallel:

```text
media namespace + internal Gateway -> Prowlarr, Seerr, Tautulli
media storage + internal Gateway   -> qBittorrent, Plex, Sonarr, Radarr, Lidarr
```

The phases below serialize the human setup so credentials and functional evidence exist
before a dependent integration is configured. They do not claim that Prowlarr depends on
Plex or qBittorrent, or that Plex depends on either application.

Important ordering gates are:

1. Configure qBittorrent paths, categories, and its permanent credential before adding
   it to Sonarr, Radarr, or Lidarr.
2. Configure Prowlarr indexers and create each media manager's API key before connecting
   Prowlarr to that application.
3. Prove direct Sonarr and Radarr imports before accepting the Seerr request path.
4. Complete Lidarr's stricter real-import, hardlink, metadata, and Force Recheck gate
   before creating the Plex Music library.
5. Create a Plex library before configuring and accepting the corresponding native
   media-manager-to-Plex refresh connection.

## Greenfield PVC bootstrap

The current manifests have `spec.suspend: false`; do not run these commands as routine
configuration or recovery shortcuts. Use this section when an application has a genuine
empty replacement PVC or is deliberately being rebuilt without a trusted backup.

Every guarded bootstrap in this section requires:

1. An assigned feature worktree for the reviewed Git change.
2. The application's `kubernetes/apps/media/<app>/ks.yaml` set to
   `spec.suspend: true` through Git.
3. That suspended change merged and deployed from `origin/main`.
4. A clean, authorized main clone at the exact deployed `origin/main` revision, with the
   administrator `.kube/config` described in
   [Repository and worktree setup](repository-worktree-setup.md).
5. The same application suspended in the live cluster.
6. The exact confirmation variable shown below.

The recipes validate source, reconcile the parent source, confirm the Git/live suspend
boundary, temporarily resume the child, wait for readiness, and run the matching live
verifier. On failure they re-suspend the child while preserving any created resources.
They do not replace the UI or functional acceptance steps in this guide.

| Application | Guarded command | Additional gate before durable activation |
| --- | --- | --- |
| Plex | `PLEX_BOOTSTRAP_CONFIRM='bootstrap:media:plex' mise exec -- just bootstrap plex` | Run `plex-verify`, activate through Git, then run the cataloged Plex reschedule test when rebuilding the complete service |
| qBittorrent | `QBITTORRENT_BOOTSTRAP_CONFIRM='bootstrap:media:qbittorrent' mise exec -- just bootstrap qbittorrent` | Complete UI setup and the blocking `qbittorrent-vpn-disconnect` resilience test |
| Prowlarr | `ARR_BOOTSTRAP_CONFIRM='bootstrap:arr:prowlarr' mise exec -- just bootstrap arr prowlarr` | Run `arr-verify prowlarr`, activate through Git, then complete UI and indexer acceptance |
| Sonarr | `ARR_BOOTSTRAP_CONFIRM='bootstrap:arr:sonarr' mise exec -- just bootstrap arr sonarr` | Run `arr-verify sonarr`, activate through Git, then complete UI and direct-import acceptance |
| Radarr | `ARR_BOOTSTRAP_CONFIRM='bootstrap:arr:radarr' mise exec -- just bootstrap arr radarr` | Run `arr-verify radarr`, activate through Git, then complete UI and direct-import acceptance |
| Lidarr | `ARR_BOOTSTRAP_CONFIRM='bootstrap:arr:lidarr' mise exec -- just bootstrap arr lidarr` | Keep the source suspended through all Lidarr gates in [Lidarr acceptance](#lidarr-acceptance) |
| FlareSolverr | `FLARESOLVERR_BOOTSTRAP_CONFIRM='bootstrap:media:flaresolverr' mise exec -- just bootstrap flaresolverr` | Run `flaresolverr-verify`, activate through Git, then test one actual protected indexer in Prowlarr |
| Seerr | `SEERR_BOOTSTRAP_CONFIRM='bootstrap:media:seerr' mise exec -- just bootstrap seerr` | Run `seerr-verify`, activate through Git, then complete Plex, Sonarr/Radarr, and request-flow acceptance |
| Tautulli | `MEDIA_APP_BOOTSTRAP_CONFIRM='bootstrap:media-app:tautulli' mise exec -- just bootstrap media-app tautulli` | Keep the source suspended until authentication, Plex library, exact-status verification, and real playback history all pass |

Run the commands from the authorized main clone, not a linked worktree with observer or
diagnostic credentials. The qBittorrent bootstrap also requires the encrypted ProtonVPN
Secret and bootstrapped media storage. Follow
[ProtonVPN and Gluetun](protonvpn-gluetun.md) for that credential and VPN acceptance.

After an application's required gates pass, set its source to `spec.suspend: false` in a
separate reviewed **Git change**. After Flux applies that change, rerun its repository
verifier. Do not use raw `flux resume` or a direct live patch as the durable activation
path.

## Phase 1 — Download and indexer foundation

### qBittorrent

#### What you are configuring

qBittorrent downloads all media through the Gluetun VPN sidecar. “Done” means that the
WebUI has a permanent authenticated login, the shared download paths and three category
paths are correct, and the same credential has been supplied to each intended consumer.

For an empty qBittorrent PVC, first follow the
[greenfield bootstrap prerequisites](#greenfield-pvc-bootstrap). Open
`https://qbittorrent.lab.supermorphic.com` while the guarded bootstrap leaves the
workload available for attended setup.

#### Configure authentication

**UI step**

1. On a new PVC, sign in as `admin` with the temporary password written once to the
   qBittorrent container's startup log. Treat that temporary password as a secret. On an
   existing PVC, use the permanent credential from the password manager. If the
   temporary value is unavailable, use qBittorrent's supported password-reset procedure;
   do not disable authentication.
2. Open **Tools → Options → Web UI**.
3. Set a permanent, unique username and password.
4. Keep WebUI authentication enabled.
5. Enable **Bypass authentication for clients on localhost**. The Gluetun
   port-forward hook is the intended localhost consumer in the same Pod.
6. Disable **Bypass authentication for clients in whitelisted IP subnets** and remove
   any subnet entries. Do not whitelist Pod, Service, RFC1918, or other broad private
   ranges. Gateway requests arrive from in-cluster addresses, so such a whitelist would
   bypass the browser login.
7. Save, sign out, and confirm that the permanent credential signs in again.

Sonarr, Radarr, and Lidarr store this credential in their own PVC-backed application
state. Homepage and qbit_manage use separate SOPS-encrypted Kubernetes Secrets. Store the
credential securely for [Phase 3](#phase-3--connect-applications),
[Homepage integration credentials](#homepage-integration-credentials), and the
[qbit_manage credential procedure](qbit-manage.md#author-the-encrypted-credential).
For a new credential, update qbit_manage through that guide's suspended, reviewed Git
workflow before allowing its active policy to resume; do not leave the scheduler using a
stale password.

#### Configure download paths

**UI step** — open **Tools → Options → Downloads** and set:

| Setting | Value |
| --- | --- |
| Default Torrent Management Mode | `Automatic` |
| Default save path | `/data/downloads` |
| Keep incomplete torrents in | Enabled |
| Incomplete torrents path | `/data/downloads/incomplete` |

The expected shared tree is:

```text
/data/
├── downloads/
│   ├── incomplete/
│   ├── movies/
│   ├── music/
│   └── tv/
└── media/
    ├── movies/
    ├── music/
    └── tv/
```

The media library directories are never qBittorrent save paths. The SMB share and media
Pods use UID/GID `568`. Create `media/music` on the SMB share before adding that root to
Lidarr; saving a root-folder path does not guarantee that Lidarr creates the directory.

#### Configure categories and cleanup ownership

**UI step** — in the transfer-list sidebar, under **Categories**:

1. Add `tv` with save path `/data/downloads/tv`.
2. Add `movies` with save path `/data/downloads/movies`.
3. Add `music` with save path `/data/downloads/music`.

Automatic Torrent Management applies these category paths. Each media manager imports
from its download category to its organized library on the same mounted filesystem, so
the import can create a hardlink rather than a duplicate copy.

For all three media-manager download clients, keep **Remove Completed** disabled,
**Post-Import Category** blank, and **Initial State** set to `Started`. Where a client
shows **Remove Failed**, keep it enabled. qbit_manage alone owns successful-torrent
classification, seeding duration, ratio, stopping, and final download-side cleanup.

#### Before continuing

Confirm in the UI that:

- the permanent login works;
- the default and incomplete paths are under `/data/downloads`;
- the `tv`, `movies`, and `music` categories have the exact paths above; and
- authentication bypass is limited to localhost.

#### Repository verification

**Repository check**

```bash
mise exec -- just kube qbittorrent-verify
```

This read-oriented verifier confirms the Flux Kustomization and HelmRelease are Ready,
the Deployment rolled out, the HTTPRoute is accepted, DNS points at the internal
Gateway, and the WebUI is reachable. It does not authenticate to the WebUI or prove VPN
egress, category settings, download success, hardlinks, or a real media import.

Confirm the `qbittorrent-vpn` endpoint is green in the Gatus UI before downloading. For
a genuine greenfield qBittorrent activation, also run the exact blocking resilience gate
printed by the bootstrap recipe:

```bash
CLUSTER_CHAOS_CONFIRM='chaos:qbittorrent-vpn-disconnect' \
  mise exec -- just test resilience qbittorrent-vpn-disconnect
```

That disruptive, operator-run test proves the VPN path fails closed during an outage and
recovers. It is not a routine verifier.

### Prowlarr

#### What you are configuring

Prowlarr owns indexer definitions and synchronizes them to Sonarr, Radarr, and Lidarr.
“Done” means its login works, at least one authorized indexer passes its own Test and a
real search, and its API key is stored securely for downstream connections.

For an empty Prowlarr PVC, first follow the
[greenfield bootstrap prerequisites](#greenfield-pvc-bootstrap). Open
`https://prowlarr.lab.supermorphic.com`.

#### Configure authentication and indexers

**UI step** — on a new PVC, complete the initial authentication screen:

| Setting | Value |
| --- | --- |
| Authentication Method | `Forms (Login Page)` |
| Authentication Required | Enabled |
| Username | A unique operator username |
| Password | A unique password from the password manager |

Add an indexer from **Indexers → Add Indexer**. Do not confuse this catalog with
**Settings → Indexers → Add Indexer Proxy**. The proxy dialog offers helpers such as
FlareSolverr, HTTP, SOCKS4, and SOCKS5; those are not indexer definitions.

For each intended indexer:

1. Search for and select its definition.
2. Enter only the credentials that the indexer requires.
3. Leave **Redirect** disabled unless that specific indexer requires it.
4. Use the default sync profile unless you need deliberate per-application policy.
5. Select **Test**, require success, and then **Save**.
6. Run a real search and confirm that it returns plausible results.

Indexer choice is an operator decision. Use only sources and content that you are
authorized to use. Do not add qBittorrent under **Settings → Download Clients** for the
normal automation flow; Prowlarr download clients apply only to searches initiated in
Prowlarr. Sonarr, Radarr, and Lidarr use their own clients.

#### Optional FlareSolverr proxy

FlareSolverr is an optional, stateless, in-cluster helper for individual indexers that
require a Cloudflare challenge. It is not a global proxy and it does not put Prowlarr
behind the qBittorrent VPN.

**UI step** — only for an indexer that needs it:

1. Open **Settings → Indexers → Add Indexer Proxy → FlareSolverr**.
2. Set **Name** to `FlareSolverr`, **Host** to
   `http://flaresolverr.media.svc.cluster.local:8191`, and **Tags** to
   `flaresolverr`.
3. Select **Test**, require success, and then **Save**.
4. Add the `flaresolverr` tag only to the protected indexer.
5. Test that indexer and run a real manual search.

Prowlarr and FlareSolverr must use the same direct egress address for the challenge
session. Do not route FlareSolverr through Gluetun. If an optional indexer still fails
after testing a supported alternate URL, disable that indexer rather than adding browser
flags, another proxy, VPN routing, or container privilege.

**Repository check**

```bash
mise exec -- just kube flaresolverr-verify
```

This diagnostic verifier confirms Flux and Helm readiness, the rollout, Service
endpoints, and FlareSolverr's ready response through an approved port-forward. It does
not prove that any Cloudflare-protected indexer works; the Prowlarr Test and real search
are the acceptance gate.

#### Before continuing

Copy Prowlarr's API key from **Settings → General**, in the **Security** area, to the
password manager. It is used later by Gatus and Homepage. Do not paste it into
documentation or chat.

**Repository check**

```bash
mise exec -- just kube arr-verify prowlarr
```

This verifier confirms Ready resources, rollout, route acceptance, DNS, and the
unauthenticated `/ping` path. It does not authenticate, inspect saved indexers, exercise
FlareSolverr, or prove a search or grab.

## Phase 2 — Media managers

Configure each media manager before wiring its external applications. Prowlarr will own
its synchronized indexers later; do not add duplicate indexers directly in Sonarr,
Radarr, or Lidarr.

### Sonarr

#### What you are configuring

Sonarr organizes television downloads below `/data/media/tv`. “Done” means the login,
naming preview, import safety settings, root folder, and API key are ready for the
connections in Phase 3.

For an empty Sonarr PVC, first follow the
[greenfield bootstrap prerequisites](#greenfield-pvc-bootstrap). Open
`https://sonarr.lab.supermorphic.com`.

#### Configure Sonarr

**UI step** — on a new PVC, enable `Forms (Login Page)` authentication and require it,
using a unique password-manager credential.

Open **Settings → Media Management**, enable **Show Advanced**, and set:

| Area | Setting | Value |
| --- | --- | --- |
| Naming | Rename Episodes | Enabled |
| Naming | Replace Illegal Characters | Enabled |
| Naming | Colon Replacement | `Smart Replace` |
| Naming | Standard Episode Format | `{Series Title} ({Series Year}) - S{season:00}E{episode:00}` |
| Naming | Series Folder Format | `{Series Title} ({Series Year})` |
| Naming | Season Folder Format | `Season {season:00}` |
| Naming | Specials Folder Format | `Specials` |
| Naming | Multi Episode Style | `Prefixed Range` |
| Folders | Create Empty Series Folders | Disabled |
| Folders | Delete Empty Folders | Enabled |
| Importing | Episode Title Required | `Never` |
| Importing | Skip Free Space Check | Disabled |
| Importing | Minimum Free Space | `102400 MB` |
| Importing | Use Hardlinks instead of Copy | Enabled |
| Importing | Import Using Script | Disabled |
| Importing | Import Extra Files | Enabled, extension `srt` |
| File management | Unmonitor Deleted Episodes | Disabled |
| File management | Propers and Repacks | `Prefer and Upgrade` |
| File management | Analyse Video Files | Enabled |
| File management | Rescan Series Folder after Refresh | `After Manual Refresh` |
| File management | Change File Date | `None` |
| File management | Recycling Bin | Blank |
| File management | Set Permissions | Disabled |

Leave the Daily and Anime episode formats at their defaults unless the library policy
later includes those formats. Under **Root Folders**, add `/data/media/tv`. Never use
`/data/downloads` as a library root.

Before saving the naming settings, confirm the preview contains the series year, a
zero-padded folder such as `Season 01`, and `S01E01` episode notation. UI labels can vary
between Servarr builds; the previewed path is the human oracle for the intended result.

Copy the API key from **Settings → General**, in the **Security** area, to the password
manager. It will be used by Prowlarr, Seerr, Homepage, and Gatus.

#### Before continuing

Confirm the root folder is `/data/media/tv`, hardlinks are enabled, the naming preview is
correct, and no manually configured indexer duplicates Prowlarr ownership.

**Repository check**

```bash
mise exec -- just kube arr-verify sonarr
```

This verifier proves deployed readiness, rollout, route acceptance, DNS, and `/ping`.
It does not inspect Sonarr's PVC-backed settings, test qBittorrent or Prowlarr, or prove a
download and import.

### Radarr

#### What you are configuring

Radarr organizes movies below `/data/media/movies`. “Done” means its login, naming
preview, import safety settings, root folder, and API key are ready for Phase 3.

For an empty Radarr PVC, first follow the
[greenfield bootstrap prerequisites](#greenfield-pvc-bootstrap). Open
`https://radarr.lab.supermorphic.com`.

#### Configure Radarr

**UI step** — on a new PVC, enable `Forms (Login Page)` authentication and require it,
using a unique password-manager credential.

Open **Settings → Media Management**, enable **Show Advanced**, and set:

| Area | Setting | Value |
| --- | --- | --- |
| Naming | Rename Movies | Enabled |
| Naming | Replace Illegal Characters | Enabled |
| Naming | Colon Replacement | `Smart Replace` |
| Naming | Standard Movie Format | `{Movie CleanTitle} ({Release Year})` |
| Naming | Movie Folder Format | `{Movie CleanTitle} ({Release Year})` |
| Folders | Create Empty Movie Folders | Disabled |
| Folders | Delete Empty Folders | Enabled |
| Importing | Skip Free Space Check | Disabled |
| Importing | Minimum Free Space | `102400 MB` |
| Importing | Use Hardlinks instead of Copy | Enabled |
| Importing | Import Using Script | Disabled |
| Importing | Import Extra Files | Enabled, extension `srt` |
| File management | Unmonitor Deleted Movies | Disabled |
| File management | Propers and Repacks | `Prefer and Upgrade` |
| File management | Analyse Video Files | Enabled |
| File management | Rescan Movie Folder after Refresh | `After Manual Refresh` |
| File management | Change File Date | `None` |
| File management | Recycling Bin | Blank |
| File management | Set Permissions | Disabled |

Under **Root Folders**, add `/data/media/movies`. Never use `/data/downloads` as a
library root. Before saving, confirm the preview shows the movie title followed by the
release year in parentheses.

Copy the API key from **Settings → General**, in the **Security** area, to the password
manager. It will be used by Prowlarr, Seerr, Homepage, and Gatus.

#### Before continuing

Confirm the root folder is `/data/media/movies`, hardlinks are enabled, the naming
preview is correct, and no manually configured indexer duplicates Prowlarr ownership.

**Repository check**

```bash
mise exec -- just kube arr-verify radarr
```

This verifier proves deployed readiness, rollout, route acceptance, DNS, and `/ping`.
It does not inspect Radarr's saved configuration or prove an indexer, download, import,
hardlink, or Plex scan.

### Lidarr

#### Why Lidarr has a stricter lifecycle

Lidarr imports audio as hardlinks. The download-side and library-side names refer to the
same inode, so an in-place metadata or tag rewrite can alter the seeded file and make
qBittorrent's hash check fail. Lidarr also depends on an external metadata service that
is not exercised by `/ping`.

For a genuine empty PVC, keep the source suspended while the operator validates:

- first-run authentication and configuration;
- the music root and write permissions;
- naming previews and conservative monitoring defaults;
- hardlink behavior;
- disabled audio metadata writing;
- a real metadata search, download, and import;
- qBittorrent hash integrity after import; and
- required Prowlarr and Homepage credentials.

Only after those checks pass may a **Git change** make Lidarr durably active. The current
deployed application already passed this lifecycle and is active; do not infer that a
replacement empty PVC may skip it.

For an empty Lidarr PVC, first follow the
[greenfield bootstrap prerequisites](#greenfield-pvc-bootstrap). Open
`https://lidarr.lab.supermorphic.com`.

#### Configure Lidarr

**UI step** — enable `Forms (Login Page)` authentication and require it, using a unique
password-manager credential.

Create `media/music` on the SMB share beside `media/movies` and `media/tv`. Confirm that
Lidarr sees it as `/data/media/music` and can write it as UID/GID `568`. Plex later sees
the same directory as `/Volumes/Prometheus/media/music`. If `/data/media` is absent,
diagnose the mount; if the music directory is visible but not writable, diagnose NAS
ownership and permissions.

Under **Settings → Media Management**, enable **Use Hardlinks instead of Copy**. The
download and music-library paths are on the same mounted filesystem; a copy would waste
bulk storage and would not preserve the accepted seeded-file lifecycle.

Open **Settings → Media Management → Show Advanced → Track Naming** and set:

| Setting | Intended value |
| --- | --- |
| Rename Tracks | Enabled |
| Replace Illegal Characters | Enabled |
| Colon Replacement | `Smart Replace` |
| Artist Folder Format | `{Artist Name}` |
| Standard Track Format | `{Album Title}/1{track:00} - {Track Title}` |
| Multi Disc Track Format | `{Album Title}/{medium:0}{track:00} - {Track Title}` |

The format strings are operator-recorded PVC settings. Before saving them in the pinned
Lidarr build, require the live previews to show this result:

```text
Artist/
└── Album/
    ├── 101 - Track Title.ext
    ├── 102 - Track Title.ext
    ├── 201 - Track Title.ext
    └── ...
```

Do not add the release year to the album folder or create a separate disc directory.
Keep the compilation convention `/data/media/music/Various Artists/{Album}/...`, with
the embedded album artist set to `Various Artists` and the track artist set to the
performer.

Under **Settings → Metadata → Write Metadata to Audio Files**, keep:

| Setting | Value |
| --- | --- |
| Tag Audio Files with Metadata | `Never` |
| Scrub Existing Tags | Disabled |
| Kodi/Emby metadata consumer | Disabled |
| Roksbox metadata consumer | Disabled |
| WDTV metadata consumer | Disabled |

Create a separate quality profile under **Settings → Profiles → Quality Profiles**:

| Setting | Value |
| --- | --- |
| Name | `Lossless Preferred` |
| Upgrades Allowed | Enabled |
| Lossless group | Enabled |
| High Quality Lossy group | Enabled as fallback |
| Upgrade Until/Cutoff | `Lossless` if the pinned UI exposes that field |
| WAV | Disabled |
| Mid, Low, Poor, and Trash Quality Lossy | Disabled |
| Unknown | Disabled |

Do not modify the built-in **Lossless** profile. This policy accepts a high-quality lossy
fallback and upgrades to the Lossless group; it does not claim that FLAC outranks every
other lossless codec.

Reuse the unchanged **Standard** metadata profile for official studio albums. Keep
**Album**, **Studio**, and **Official** enabled and the other primary types, secondary
types, and release statuses disabled. Add a separate profile later if compilation or
other release policy changes.

Under **Settings → Media Management → Root Folders**, add:

| Setting | Value |
| --- | --- |
| Name | `Music` |
| Path | `/data/media/music` |
| Monitor | `None` |
| Monitor New Albums | `No New Albums` |
| Quality Profile | `Lossless Preferred` |
| Metadata Profile | `Standard` |
| Default Lidarr Tags | Blank |

These defaults prevent adding an artist from monitoring its entire discography. Select
the intended album explicitly during acceptance.

Copy Lidarr's API key from **Settings → General**, in the **Security** area, to the
password manager. It will be used by Prowlarr, Homepage, and Gatus.

#### Create the pre-activation Homepage credential

**Git change** — a fresh Lidarr deployment must have its independently rotatable
Homepage credential in Git before durable activation. From the feature worktree, with
the operator's SOPS age identity loaded, use a non-echoing prompt and the guarded writer:

```bash
printf 'Lidarr API key: '
IFS= read -r -s LIDARR_API_KEY
printf '\n'
export LIDARR_API_KEY
export HOMEPAGE_LIDARR_SECRETS_CONFIRM='write:monitoring:homepage-lidarr:sops'
mise exec -- just repo homepage-lidarr-secrets
unset LIDARR_API_KEY HOMEPAGE_LIDARR_SECRETS_CONFIRM
```

Review and commit only
`kubernetes/apps/monitoring/homepage/app/homepage-lidarr.sops.yaml`. Never print or
commit the plaintext key. The guarded bootstrap recipes require a clean checkout, so
commit this encrypted result before running another bootstrap command. This one
credential is an explicit Lidarr activation gate; the complete Gatus Secret is created
later because it also requires the Seerr API key.

**Repository check**

```bash
mise exec -- just kube arr-verify lidarr
```

This verifier proves Ready resources, rollout, route acceptance, DNS, and `/ping`. It
does not exercise `api.lidarr.audio`, inspect naming or metadata settings, test a provider,
or prove a real import. A green result is necessary but insufficient for Lidarr
acceptance.

## Phase 3 — Connect applications

### Connect Sonarr, Radarr, and Lidarr to qBittorrent

**UI step** — in each media manager, open
**Settings → Download Clients → Add → qBittorrent**. Use the shared values below, then
apply the application-specific category.

| Setting | Sonarr | Radarr | Lidarr |
| --- | --- | --- | --- |
| Name | `qBittorrent` | `qBittorrent` | `qBittorrent` |
| Enable | Enabled | Enabled | Enabled |
| Host | `qbittorrent.media.svc.cluster.local` | Same | Same |
| Port | `8080` | `8080` | `8080` |
| Use SSL | Disabled | Disabled | Disabled |
| URL Base | Blank | Blank | Blank |
| Username/password | Permanent qBittorrent credential | Same | Same |
| Category | `tv` | `movies` | `music` |
| Post-Import Category | Blank | Blank | Blank |
| Initial State | `Started` | `Started` | `Started` |
| Remove Completed | Disabled | Disabled | Disabled |

For Lidarr, also keep **Recent Priority** and **Older Priority** at `Last`, **Sequential
Order** and **First and Last First** disabled, **Content Layout** at `Default`, **Client
Priority** at `1`, and **Tags** blank if those fields are present.

Select **Test**, require success, and then **Save** in each application. Do not configure
a Remote Path Mapping: qBittorrent and all three media managers see the same paths under
`/data`. qbit_manage, not the media managers, owns successful-torrent cleanup.

The successful UI Test proves that the application can authenticate to qBittorrent with
the saved settings. It still does not prove that a real download is categorized,
hardlinked, renamed, or imported correctly.

### Connect Prowlarr to the media managers

Return to Prowlarr. Add each application independently under
**Settings → Apps → Add**:

| Setting | Sonarr | Radarr | Lidarr |
| --- | --- | --- | --- |
| Name | `Sonarr` | `Radarr` | `Lidarr` |
| Sync Level | `Full Sync` | `Full Sync` | `Full Sync` |
| Prowlarr Server | `http://prowlarr.media.svc.cluster.local:9696` | Same | Same |
| Application Server | `http://sonarr.media.svc.cluster.local:8989` | `http://radarr.media.svc.cluster.local:7878` | `http://lidarr.media.svc.cluster.local:8686` |
| API Key | Sonarr API key | Radarr API key | Lidarr API key |
| Tags | Blank | Blank | Blank |
| Sync Categories | Defaults | Defaults | Defaults |

For each connection, select **Test**, require success, and then **Save**. `Full Sync`
makes Prowlarr authoritative for the indexers it manages. Confirm that each downstream
application lists synchronized indexers whose names end in `(Prowlarr)`; do not edit
those generated entries independently.

The Prowlarr Test proves API connectivity and that Prowlarr can synchronize the selected
application. It does not prove that every indexer can return a usable release for that
application.

## Phase 4 — Prove direct imports

Before using real media, an operator may run the repository's synthetic filesystem gate:

```bash
mise exec -- just test integration media-hardlink
```

**Operator acceptance gate** — this run creates and removes one run-owned test file. It
proves that `/data/downloads` and `/data/media` on the `media-data` SMB share preserve a
shared inode and link count across the two trees. It mutates only its temporary test
paths. It does not prove that Sonarr, Radarr, or Lidarr is configured to import a real
release correctly.

### Sonarr acceptance

**Operator acceptance gate**

1. Search for one authorized TV series in Sonarr.
2. Start a monitored download.
3. Confirm qBittorrent receives it in category `tv` below `/data/downloads/tv`.
4. Confirm Sonarr imports it below `/data/media/tv` with the intended series, season,
   and episode naming.
5. Confirm the import is a hardlink rather than a second full copy.

The Sonarr workflow is not accepted until all five observations pass.

### Radarr acceptance

**Operator acceptance gate**

1. Search for one authorized movie in Radarr.
2. Start a monitored download.
3. Confirm qBittorrent receives it in category `movies` below
   `/data/downloads/movies`.
4. Confirm Radarr imports it below `/data/media/movies` with the intended folder and
   filename.
5. Confirm the import is a hardlink rather than a second full copy.

The Radarr workflow is not accepted until all five observations pass.

### Lidarr acceptance

**Operator acceptance gate** — this is the blocking Lidarr activation gate for a fresh
PVC.

1. Search for a real artist and confirm that artist and album metadata load. `/ping`
   does not exercise the external Lidarr metadata service.
2. Add one authorized, uncomplicated release with root `/data/media/music`, quality
   profile `Lossless Preferred`, metadata profile `Standard`, and only the intended
   test album monitored. Do not search or monitor the full discography.
3. Confirm qBittorrent uses category `music` and download root
   `/data/downloads/music`.
4. Confirm Lidarr imports the album under `/data/media/music` as
   `Artist/Album/DiscTrack - Title.ext`.
5. Confirm **Tag Audio Files with Metadata** remains `Never`.
6. Using a trusted NAS-side filesystem interface, compare the download-side and
   library-side file for the same track. Require the same inode and link count `2` on
   both names. The repository has no dedicated command for inspecting a chosen real
   media file; do not replace this step with an ad-hoc `kubectl exec`.
7. In qBittorrent, run **Force Recheck** on the imported torrent and require completion
   without a hash error.

Record only non-sensitive results:

```text
qBittorrent category: music
download root: /data/downloads/music
library root: /data/media/music
library naming: Artist/Album/DiscTrack - Title.ext
download-side link count: 2
library-side link count: 2
Tag Audio Files with Metadata: Never
qBittorrent Force Recheck: no hash error
```

Do not activate a fresh Lidarr source or create the Plex Music library until every item
passes. After the accepted result, make `spec.suspend: false` durable through Git, allow
Flux to reconcile, and rerun:

```bash
mise exec -- just kube arr-verify lidarr
```

## Phase 5 — Plex integration

### Verify the libraries and Plex runtime

Plex mounts the same SMB share at `/Volumes/Prometheus` while the media managers use
`/data`. These different container paths are intentional:

| Library | Media-manager path | Plex path |
| --- | --- | --- |
| TV | `/data/media/tv` | `/Volumes/Prometheus/media/tv` |
| Movies | `/data/media/movies` | `/Volumes/Prometheus/media/movies` |
| Music | `/data/media/music` | `/Volumes/Prometheus/media/music` |

**UI step** — open `https://plex.lab.supermorphic.com` and confirm that the existing TV
and Movies libraries use the exact Plex paths above. Do not change a media-manager root
to `/Volumes/Prometheus`.

For an empty Plex PVC, first follow the
[greenfield bootstrap prerequisites](#greenfield-pvc-bootstrap) and complete Plex's own
supported first-run claim and library setup. Do not record the account identity or token.

**Repository check**

```bash
mise exec -- just kube plex-verify
```

This diagnostic verifier confirms Flux and Helm readiness, rollout, Plex's UID 568
runtime identity, absence of a Kubernetes API token, a read-only media mount, writable
config, the exact LoadBalancer contract, route acceptance, DNS, and `/identity` over
TLS. It does not inspect Plex's database, library paths, visible media, scan results,
metadata matching, playback, or user access.

### Configure native Plex refresh connections

These connections notify Plex after a media manager changes an organized library. They
do not control downloads or imports:

```text
media-manager import or rename
  -> organized library changes
  -> native Plex connection notifies Plex
  -> Plex scans the matching library
```

In each media manager, open **Settings → Connect → Add → Plex Media Server**. The exact
dialog title and some trigger labels are version-sensitive PVC UI details. Use the
fields present in the pinned application build and do not invent a missing selector.

Use these shared values:

| Setting | Value |
| --- | --- |
| Name | `Plex Media Server` |
| Host | `plex.media.svc.cluster.local` |
| Port | `32400` |
| Use SSL | Disabled |
| URL Base | Blank |
| Auth Token | Use the application's Plex.tv authentication flow or enter the token securely |
| Update Library | Enabled |
| Tags | Blank |
| Map Paths From / To | Blank if shown |

The blank connector map fields are intentional. They are not qBittorrent Remote Path
Mappings. Select **Test**, require success, and then **Save**.

Use these operator-recorded trigger states in the pinned Sonarr build:

| Sonarr trigger | State |
| --- | --- |
| On Grab | Disabled |
| On File Import | Enabled |
| On File Upgrade | Enabled |
| On Import Complete | Enabled if shown |
| On Rename | Enabled |
| On Series Add | Disabled |
| On Series Delete | Enabled |
| On Episode File Delete | Enabled |
| On Episode File Delete For Upgrade | Enabled |
| On Health Issue / Restored | Disabled |
| On Application Update | Disabled |
| On Manual Interaction Required | Disabled |

Use these operator-recorded trigger states in the pinned Radarr build:

| Radarr trigger | State |
| --- | --- |
| On Grab | Disabled |
| On File Import | Enabled |
| On File Upgrade | Enabled |
| On Rename | Enabled |
| On Movie Added | Disabled |
| On Movie Delete | Enabled |
| On Movie File Delete | Enabled |
| On Movie File Delete For Upgrade | Enabled |
| On Health Issue / Restored | Disabled |
| On Application Update | Disabled |
| On Manual Interaction Required | Disabled |

Grab and entity-add events do not change organized media and therefore do not need a
Plex scan. Sonarr's **On Import Complete** can overlap file-level import events; use the
acceptance test to detect excessive duplicate scans.

**Operator acceptance gate** — after each direct import, cause one controlled import or
media-manager rename. Confirm the application's Test succeeds, its event history records
the connection, Plex scans the intended TV or Movies library, and the item appears
correctly without manually selecting **Scan Library Files**.

### Create and connect the Music library

Only after [Lidarr acceptance](#lidarr-acceptance):

1. **UI step** — create the Plex Music library at
   `/Volumes/Prometheus/media/music`.
2. Run the one initial manual scan and confirm the accepted album appears correctly.
3. In Lidarr, add the native Plex connection using the shared values above.
4. Apply the operator-recorded trigger states below.
5. Select **Test**, require success, and then **Save**.

| Lidarr trigger | State |
| --- | --- |
| On Grab | Disabled |
| On Release Import | Enabled |
| On Upgrade | Enabled |
| On Download Failure | Disabled |
| On Import Failure | Disabled |
| On Rename | Enabled |
| On Track Retag | Enabled |
| On Artist Add | Disabled |
| On Artist Delete | Enable only when the operator wants stale Plex artist entries removed after a Lidarr-managed deletion |
| On Album Delete | Disabled |
| On Application Update | Disabled |
| On Health Issue / Restored | Disabled |

Metadata writing remains disabled even though the connection may react to a future
Lidarr-managed retag event. Do not enable a trigger merely because the pinned UI exposes
it; use events that can change organized-library state.

File-delete and entity-delete triggers cover media-manager changes to the organized
library. qbit_manage cleanup or removing the original torrent changes only
`/data/downloads`; it does not require a Plex library refresh.

**Operator acceptance gate** — perform a second small authorized import or a
Lidarr-managed rename of the accepted album. Confirm a successful connection event, a
Plex Music scan, and the album or renamed tracks appearing without another manual scan.

If a connection Test succeeds but no scan occurs, inspect the relevant media-manager
events and logs, confirm the change happened below `/data/media`, verify the matching
Plex library path, and keep both connector map fields blank. Exact native library
matching is an operator acceptance result, not something the repository verifier can
derive from PVC state.

## Phase 6 — Request layer

### Configure Seerr

Seerr is the household request interface. It stores Plex, Sonarr, Radarr, user,
permission, quota, and request state in its own PVC.

For an empty Seerr PVC, first follow the
[greenfield bootstrap prerequisites](#greenfield-pvc-bootstrap). Open
`https://seerr.lab.supermorphic.com`.

#### Connect Plex

**UI step**

1. Sign in with the Plex administrator account.
2. Open **Settings → Media Server → Plex**.
3. Select the intended Plex server, or enter:

   | Setting | Value |
   | --- | --- |
   | Hostname or IP Address | `plex.media.svc.cluster.local` |
   | Port | `32400` |
   | Use SSL | Disabled |
   | Web App URL | `https://plex.lab.supermorphic.com/web` |

4. Select the TV and Movies libraries. Select Music too only after the Plex Music gate
   has passed.
5. Save, select **Sync Libraries**, and complete the one-time Seerr catalog sync. This
   synchronizes Seerr's view of Plex; it is not Plex **Scan Library Files** and does not
   replace native media-manager-to-Plex acceptance.

#### Connect Sonarr and Radarr

**UI step** — add one server under **Settings → Services → Sonarr** and one under
**Settings → Services → Radarr**:

| Setting | Sonarr | Radarr |
| --- | --- | --- |
| Default Server | Enabled | Enabled |
| 4K Server | Disabled | Disabled |
| Server Name | `Sonarr` | `Radarr` |
| Hostname or IP Address | `sonarr.media.svc.cluster.local` | `radarr.media.svc.cluster.local` |
| Port | `8989` | `7878` |
| Use SSL | Disabled | Disabled |
| API Key | Sonarr API key | Radarr API key |
| URL Base | Blank | Blank |
| Root Folder | `/data/media/tv` | `/data/media/movies` |
| External URL | `https://sonarr.lab.supermorphic.com` | `https://radarr.lab.supermorphic.com` |
| Enable Scan | Enabled | Enabled |
| Enable Automatic Search | Enabled | Enabled |

Select the intended quality profile loaded from each application. For Radarr, choose the
operator's intended minimum availability; `Released` is the recorded conservative
default, not a repository-enforced content policy. Select **Test**, require success, and
then **Save**. At least one Sonarr and one Radarr server must be marked **Default** for
request dispatch.

Open **Settings → Users**. Deliberately review default permissions, new Plex sign-in,
request and auto-approval permissions, administrator access, and household request
quotas. Do not accept application defaults without reviewing their effect on new users.

Copy Seerr's API key from **Settings → General → API Key** to the password manager. It is
used by Homepage and Gatus.

#### Repository verification

**Repository check**

```bash
mise exec -- just kube seerr-verify
```

This verifier proves the Seerr Kustomization and HelmRelease are Ready, the Deployment
rolled out, the HTTPRoute is accepted, DNS is correct, and `/api/v1/status` is reachable.
It does not inspect the saved Plex or media-manager services, authenticate a user, or
submit a request.

#### Request-flow acceptance

**Operator acceptance gate**

1. Request one authorized TV series in Seerr and confirm it appears in Sonarr.
2. Request one authorized movie and confirm it appears in Radarr.
3. Confirm both requests use the expected quality profile, root folder, and permissions.
4. Confirm both progress through the expected qBittorrent category.
5. Confirm the imports appear in Plex and Seerr reports them available.
6. Inspect the resulting media naming and confirm it matches the accepted Sonarr and
   Radarr conventions.

The request layer is not accepted until both paths pass. Gatus's Seerr service reads can
show that stored downstream services are readable, but they do not prove this workflow.

## Phase 7 — Auxiliary integrations

### Tautulli

Tautulli records Plex session and watch history in its own retained PVC. It does not
mount the shared media claim or Plex's configuration claim, so its Plex Logs viewer is
intentionally unavailable.

For an empty Tautulli PVC, first follow the
[greenfield bootstrap prerequisites](#greenfield-pvc-bootstrap). Open
`https://tautulli.lab.supermorphic.com`.

**UI step** — complete the setup wizard:

1. Create a unique Tautulli HTTP username and password and store them in the password
   manager.
2. Use **Sign In with Plex** with the Plex administrator account and require successful
   authentication.
3. Configure the Plex server with hostname
   `plex.media.svc.cluster.local`, port `32400`, and secure connection disabled. Use the
   hostname only, not a URL, Gateway hostname, or transient Pod address.
4. Select **Verify** and require the server to be found.
5. Leave Activity Logging at its defaults unless the operator chooses another retention
   policy. Leave Tautulli notifications unconfigured; Prometheus and Alertmanager own
   cluster alert delivery.
6. Skip database import for a new database and finish the wizard.
7. Open **Settings → Web Interface**, find Tautulli's own **API** section rather than
   **3rd Party APIs**, enable the API, create or copy its key, and save.
8. Confirm that at least one Plex library appears.
9. Play authorized media and require the session to appear in Tautulli history.

Use Plex OAuth administrator authentication for the web interface. The deployed health
contract requires `/status` to return exact HTTP `200` without a redirect through both
the Service and internal Gateway.

**Repository check**

```bash
mise exec -- just kube tautulli-verify
```

This diagnostic verifier proves Ready resources, rollout, route acceptance, DNS, exact
non-redirecting `/status` responses through both paths, the Tautulli Gatus series, and
the health of six loaded media availability rules. It does not prove the saved Plex
server, library visibility, authentication usability, playback, or recorded history.

For a fresh suspended deployment, keep the source suspended until the UI steps, exact
status check, visible library, and real playback history all pass. Then activate it
through Git and rerun the verifier.

### Homepage integration credentials

Homepage reads media application APIs with per-consumer SOPS Secrets. These copies are
independently rotatable; they do not make Kubernetes the authority for the upstream
application credential.

**Git change** — run the writers from the assigned feature worktree with the operator's
SOPS age identity loaded. Each recipe validates the identity, requires its exact guard,
writes only its declared encrypted file, and checks that the plaintext input is absent
from the result.

After all application keys and the Plex token exist, the operator can create or rotate
the remaining media widget credentials in one non-echoing shell session. Lidarr is
intentionally absent: its encrypted Homepage Secret is created before Lidarr activation.
Rerun the dedicated Lidarr writer above only when that API key changes.

```bash
(
  set -euo pipefail

  printf 'qBittorrent WebUI username: '
  IFS= read -r QBITTORRENT_USERNAME
  printf 'qBittorrent WebUI password: '
  IFS= read -r -s QBITTORRENT_PASSWORD
  printf '\nProwlarr API key: '
  IFS= read -r -s PROWLARR_API_KEY
  printf '\nSonarr API key: '
  IFS= read -r -s SONARR_API_KEY
  printf '\nRadarr API key: '
  IFS= read -r -s RADARR_API_KEY
  printf '\nSeerr API key: '
  IFS= read -r -s SEERR_API_KEY
  printf '\nTautulli API key: '
  IFS= read -r -s TAUTULLI_API_KEY
  printf '\nPlex server token: '
  IFS= read -r -s PLEX_TOKEN
  printf '\n'

  export QBITTORRENT_USERNAME QBITTORRENT_PASSWORD
  export PROWLARR_API_KEY SONARR_API_KEY RADARR_API_KEY
  export SEERR_API_KEY TAUTULLI_API_KEY PLEX_TOKEN

  export HOMEPAGE_QBITTORRENT_SECRETS_CONFIRM='write:monitoring:homepage-qbittorrent:sops'
  export HOMEPAGE_PROWLARR_SECRETS_CONFIRM='write:monitoring:homepage-prowlarr:sops'
  export HOMEPAGE_SONARR_SECRETS_CONFIRM='write:monitoring:homepage-sonarr:sops'
  export HOMEPAGE_RADARR_SECRETS_CONFIRM='write:monitoring:homepage-radarr:sops'
  export HOMEPAGE_SEERR_SECRETS_CONFIRM='write:monitoring:homepage-seerr:sops'
  export HOMEPAGE_TAUTULLI_SECRETS_CONFIRM='write:monitoring:homepage-tautulli:sops'
  export HOMEPAGE_PLEX_SECRETS_CONFIRM='write:monitoring:homepage-plex:sops'

  mise exec -- just repo homepage-qbittorrent-secrets
  mise exec -- just repo homepage-prowlarr-secrets
  mise exec -- just repo homepage-sonarr-secrets
  mise exec -- just repo homepage-radarr-secrets
  mise exec -- just repo homepage-seerr-secrets
  mise exec -- just repo homepage-tautulli-secrets
  mise exec -- just repo homepage-plex-secrets
)
```

Across the dedicated Lidarr writer and the combined session, commit only these encrypted
outputs:

| Consumer | Encrypted file |
| --- | --- |
| qBittorrent | `kubernetes/apps/monitoring/homepage/app/homepage-qbittorrent.sops.yaml` |
| Prowlarr | `kubernetes/apps/monitoring/homepage/app/homepage-prowlarr.sops.yaml` |
| Sonarr | `kubernetes/apps/monitoring/homepage/app/homepage-sonarr.sops.yaml` |
| Radarr | `kubernetes/apps/monitoring/homepage/app/homepage-radarr.sops.yaml` |
| Lidarr | `kubernetes/apps/monitoring/homepage/app/homepage-lidarr.sops.yaml` |
| Seerr | `kubernetes/apps/monitoring/homepage/app/homepage-seerr.sops.yaml` |
| Tautulli | `kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml` |
| Plex | `kubernetes/apps/monitoring/homepage/app/homepage-plex.sops.yaml` |

Do not print, inspect, or commit plaintext. The current Homepage Deployment consumes
these values as environment variables but does not stamp a content hash for the media
widget Secrets. Applying a new or rotated Secret therefore does not by itself reload the
running process. Arrange an operator-authorized Homepage Pod replacement after Flux has
applied the reviewed Secret change. This is a current implementation limitation, not a
reason to patch the live Deployment or copy credentials between checkouts.

**Repository check**

```bash
mise exec -- just kube homepage-verify
```

This verifier proves Homepage readiness, rollout, route acceptance, DNS, and dashboard
reachability. It does not call each media widget or prove that the saved credentials are
accepted. Open Homepage and require each configured media widget to show live data.

### Gatus media-integration credentials and acceptance

Gatus uses a separate SOPS Secret containing exactly the Prowlarr, Sonarr, Radarr,
Lidarr, and Seerr API keys. Only Gatus consumes this copy.

This complete five-key Secret is a Phase 7 integration step, not a prerequisite for
activating Lidarr. Seerr's API key does not exist until Seerr has been configured.

**Git change**

```bash
(
  set -euo pipefail
  printf 'Prowlarr API key: '
  IFS= read -r -s PROWLARR_API_KEY
  printf '\nSonarr API key: '
  IFS= read -r -s SONARR_API_KEY
  printf '\nRadarr API key: '
  IFS= read -r -s RADARR_API_KEY
  printf '\nLidarr API key: '
  IFS= read -r -s LIDARR_API_KEY
  printf '\nSeerr API key: '
  IFS= read -r -s SEERR_API_KEY
  printf '\n'

  export PROWLARR_API_KEY SONARR_API_KEY RADARR_API_KEY LIDARR_API_KEY SEERR_API_KEY
  export GATUS_MEDIA_INTEGRATION_SECRETS_CONFIRM='write:monitoring:gatus-media-integration:sops'
  mise exec -- just repo gatus-media-integration-secrets
)
```

Commit only
`kubernetes/apps/monitoring/gatus/app/media-integration-api-keys.sops.yaml`. Gatus reads
the values as environment variables. After Flux applies a new or rotated Secret, an
operator must replace the Gatus Pod so the process loads them; the current source does
not contain a Secret-content rollout stamp or reloader for this Secret.

Gatus evaluates six `Media Integration` endpoints once per minute:

- four authenticated Servarr health API paths, where HTTP `200` is the only success
  condition; and
- two stronger Seerr reads that require the selected Sonarr or Radarr server, profiles,
  and root folders in the response.

The four Servarr checks do not evaluate native health response entries. The Seerr reads
do not submit a request. None of the six proves a search, download, import, Plex refresh,
or end-to-end workflow.

The current alert contract holds the four `*NativeHealthApiUnavailable` warnings and the
two Seerr selected-service read warnings for 15 minutes. The separate
`MediaIntegrationProbeMissing` warning detects an absent required series after five
minutes. A status-only Servarr probe cannot identify which downstream integration, if
any, caused an application health entry.

**Operator acceptance gate** — after the Gatus Pod replacement, open
`https://gatus.lab.supermorphic.com`, find all six entries in the `Media Integration`
group, and require three consecutive successful one-minute cycles for each. Then confirm
that the corresponding media-integration alerts are inactive in Prometheus or
Alertmanager. This preserves the human acceptance criteria without embedding a second
implementation of the Gatus and Prometheus APIs in this guide.

**Repository check**

```bash
mise exec -- just kube gatus-verify
```

This verifier proves Gatus readiness, rollout, route acceptance, DNS, dashboard health,
and the independent Platform `echo` metric, then runs the foundation verifier. It does
not inspect the six media-integration histories or their credentials; use the explicit
operator acceptance gate above for those results.

## Recovery and repeat setup

Pod replacement, image upgrades, and node rescheduling reuse the retained configuration
PVCs and normally do not require this guide. Prefer a trusted Longhorn or
application-native backup when configuration state is lost. An empty replacement PVC is
a genuine greenfield installation and must use the guarded bootstrap lifecycle before
the relevant UI and acceptance steps.

Never reconstruct an application by committing its live SQLite database or plaintext
configuration directory. Keep durable Flux-managed state in Git, and use
[Recovery](../runbooks/recovery.md) for failure-specific procedures.

## Upstream references

- [Prowlarr quick-start guide](https://wiki.servarr.com/en/prowlarr/quick-start-guide)
- [Sonarr quick-start guide](https://wiki.servarr.com/en/sonarr/quick-start-guide)
- [Radarr settings](https://wiki.servarr.com/radarr/settings)
- [qBittorrent 5.x WebUI API and authentication](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-5.0%29)
- [qBittorrent WebUI password recovery](https://github.com/qbittorrent/qBittorrent/wiki/Web-UI-password-locked-on-qBittorrent-NO-X-%28qbittorrent-nox%29)
- [Seerr media-server settings](https://docs.seerr.dev/using-seerr/settings/mediaserver/)
- [Seerr Sonarr/Radarr service settings](https://docs.seerr.dev/using-seerr/settings/services/)
- [Seerr user settings](https://docs.seerr.dev/using-seerr/settings/users/)
- [Seerr backups](https://docs.seerr.dev/using-seerr/backups/)
- [Plex music naming and organization](https://support.plex.tv/articles/200265296-adding-music-media-from-folders/)
