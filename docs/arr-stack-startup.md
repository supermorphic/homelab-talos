# Media automation greenfield startup

Use this runbook after deploying the media applications onto empty configuration
PVCs. It covers the runtime setup that cannot be expressed by the existing Helm
values alone: qBittorrent, Prowlarr, Sonarr, Radarr, Lidarr, and Seerr.

The Kubernetes resources remain declarative in Git. These application settings are
written by their web UIs into configuration files and SQLite databases on retained
Longhorn PVCs:

| Service | Public operator URL | In-cluster URL | Persistent configuration |
|---|---|---|---|
| qBittorrent | `https://qbittorrent.lab.supermorphic.com` | `http://qbittorrent.media.svc.cluster.local:8080` | `/config` |
| Prowlarr | `https://prowlarr.lab.supermorphic.com` | `http://prowlarr.media.svc.cluster.local:9696` | `/config` |
| Sonarr | `https://sonarr.lab.supermorphic.com` | `http://sonarr.media.svc.cluster.local:8989` | `/config` |
| Radarr | `https://radarr.lab.supermorphic.com` | `http://radarr.media.svc.cluster.local:7878` | `/config` |
| Lidarr | `https://lidarr.lab.supermorphic.com` | `http://lidarr.media.svc.cluster.local:8686` | `/config` |
| Seerr | `https://seerr.lab.supermorphic.com` | `http://seerr.media.svc.cluster.local:5055` | `/app/config` |
| Plex | `https://plex.lab.supermorphic.com` | `http://plex.media.svc.cluster.local:32400` | `/config` |

Do not commit application passwords, API keys, tracker credentials, cookies, or
unencrypted configuration exports. Store operator credentials in the password
manager. Only use a repository SOPS recipe when a specific integration Secret is
already designed for Git.

## Order of operations

Configure the stack in this order:

1. qBittorrent download paths, categories, and permanent WebUI credentials.
2. Prowlarr authentication and indexers.
3. Sonarr authentication, TV root folder, and qBittorrent client.
4. Radarr authentication, movie root folder, and qBittorrent client.
5. Lidarr authentication, media management, music root folder, naming, and
   qBittorrent client.
6. Prowlarr application connections to Sonarr, Radarr, and Lidarr.
7. Verify the existing Plex TV and Movies library paths, then complete a direct
   Sonarr import and configure and validate its Plex refresh connection.
8. Complete a direct Radarr import and configure and validate its Plex refresh
   connection.
9. Complete the blocking Lidarr authorized real-import acceptance.
10. In PR 2, make Lidarr's activation durable, then run
    `mise exec -- just kube arr-verify lidarr`.
11. Create the Plex Music library at `/Volumes/Prometheus/media/music` and run
    its initial manual scan.
12. Configure and validate the Lidarr Plex refresh connection.
13. Seerr connections to Plex, Sonarr, and Radarr, followed by a Seerr request
    test.

Complete a service's guarded bootstrap and durable `suspend: false` activation
before configuring it here. **Lidarr is the exception:** keep its PR 1 source at
`suspend: true` after bootstrap until its first-run configuration, authorized import,
and Homepage Secret acceptance gate pass; PR 2 performs the activation. Work through the
steps incrementally as each service is activated — you do not need every application live
at once. For example, connect Prowlarr to Sonarr as soon as Sonarr is up (step 6's Sonarr
connection), before Radarr has been activated, and complete Radarr's steps later.

## qBittorrent

Open `https://qbittorrent.lab.supermorphic.com`.

### Authentication

1. On a new PVC, sign in as `admin` with the temporary password qBittorrent emits
   during its first startup. It is printed once in the qBittorrent container's
   startup log (the line begins `The WebUI administrator password was not set. A
   temporary password is provided...`). On an existing PVC, use the saved permanent
   credential. If the temporary password is unavailable, use qBittorrent's official
   password-reset procedure; do not disable WebUI authentication.
2. Open **Tools → Options → Web UI**.
3. Set a permanent, unique username and password from the password manager.
4. Keep WebUI authentication enabled.
5. Enable **Bypass authentication for clients on localhost**. This bypass is only
   for the Gluetun port-forward hook in the same Pod.
6. Disable **Bypass authentication for clients in whitelisted IP subnets** and remove
   any existing subnet entries. In particular, do not whitelist the Kubernetes Pod
   CIDR, Service CIDR, or RFC1918 ranges. Requests through the internal Gateway arrive
   from an in-cluster address, so a Pod-CIDR bypass also bypasses the browser login.
7. Save, sign out, and confirm the permanent credential signs back in.

qBittorrent exposes one WebUI credential to integrations supported here. Sonarr,
Radarr, Lidarr, and Homepage use it; Prowlarr uses it only if direct Prowlarr searches
are enabled. Keep the human copy in the password manager and create Homepage's
independently rotatable SOPS Secret without printing either value:

```bash
printf 'qBittorrent WebUI username: '
IFS= read -r QBITTORRENT_USERNAME
printf 'qBittorrent WebUI password: '
IFS= read -r -s QBITTORRENT_PASSWORD
printf '\n'
export QBITTORRENT_USERNAME QBITTORRENT_PASSWORD
export HOMEPAGE_QBITTORRENT_SECRETS_CONFIRM='write:monitoring:homepage-qbittorrent:sops'
mise exec -- just repo homepage-qbittorrent-secrets
unset QBITTORRENT_USERNAME QBITTORRENT_PASSWORD HOMEPAGE_QBITTORRENT_SECRETS_CONFIRM
```

Commit only the resulting encrypted `homepage-qbittorrent.sops.yaml`. Never commit
the temporary password, plaintext permanent credential, or an unencrypted application
configuration export.

### Download paths

Open **Tools → Options → Downloads** and set:

| Setting | Value |
|---|---|
| Default Torrent Management Mode | `Automatic` |
| Default save path | `/data/downloads` |
| Keep incomplete torrents in | Enabled |
| Incomplete torrents path | `/data/downloads/incomplete` |

The media library directories are not download targets:

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

The SMB mount and every media Pod use UID/GID `568`. Create the `media/music`
directory on the SMB share before adding it in Lidarr; saving a root-folder path
does not necessarily create a missing directory. The library path is not a
qBittorrent save path.

### Categories

In the transfer-list sidebar, under **Categories**:

1. Add category `tv` with save path `/data/downloads/tv`.
2. Add category `movies` with save path `/data/downloads/movies`.
3. Add category `music` with save path `/data/downloads/music`.

Sonarr, Radarr, and Lidarr use these exact category names. Automatic Torrent
Management applies the category save paths. For music, `/data/downloads/music`
is the download path and `/data/media/music` is the organized library path;
they are on the same mounted filesystem, so Lidarr can hardlink imported tracks
rather than copy them.

### Cleanup authority

For Sonarr, Radarr, and Lidarr, keep **Remove Completed** disabled,
**Post-Import Category** blank, and **Initial State** set to `Started`. This
does not disable their normal completed-download monitoring and import. Where a
client exposes **Remove Failed**, keep it enabled; it is a separate failed-job
control, not a reason to describe it as Usenet-only.

qbit_manage alone owns successful torrent seeding duration, ratio, maximum seed
time, and final cleanup. The responsibilities are deliberately separate:

- Sonarr, Radarr, and Lidarr monitor, grab, import, rename, and organize.
- qBittorrent downloads and seeds.
- qbit_manage owns torrent lifecycle, seeding policy, and final cleanup.

### Check

Run the read-only guarded verification:

```bash
mise exec -- just kube qbittorrent-verify
```

Confirm `qbittorrent-vpn` is green in Gatus before testing downloads.

## Prowlarr

Open `https://prowlarr.lab.supermorphic.com`.

### Authentication

On a new PVC, complete the initial authentication screen:

| Setting | Value |
|---|---|
| Authentication Method | `Forms (Login Page)` |
| Authentication Required | `Enabled` |
| Username | A unique operator username |
| Password | A unique password from the password manager |

The account is persisted in `prowlarr.db`. It is not recreated on Pod restarts,
upgrades, or node rescheduling.

### Indexers

The **Settings → Indexers** page has two separate `+` buttons: **Add Indexer**
(the indexer catalog) and, lower down, **Add Indexer Proxy**. If the `+` you press
only offers **FlareSolverr**, **Http**, **SOCKS4**, and **SOCKS5**, that is the
*proxy* dialog — those four are connection proxies, not indexers. Close it and use
the **Add Indexer** button in the **Indexers** panel instead. See
[Indexer proxies](#indexer-proxies) for when (and whether) a proxy is needed.

To add an indexer:

1. Open **Settings → Indexers**.
2. In the **Indexers** panel, select **Add Indexer** (`+`). Prowlarr opens a
   searchable catalog of several hundred indexer definitions.
3. Search for and choose the specific tracker or indexer.
4. Enter its required API key, cookie, username/password, or other credential.
5. Leave **Redirect** disabled unless that specific indexer requires it.
6. Select the default sync profile unless a deliberate per-application policy is
   needed.
7. Select **Test**, require a successful result, and then **Save**.
8. Repeat for every desired indexer.

Which indexers to add is a deliberate operator choice and depends on your sources.
Usenet indexers (Newznab definitions, paired with a paid Usenet provider) are the
most reliable and lowest-maintenance; public torrent indexers are free but variable
and some sit behind Cloudflare; private torrent trackers require their own
membership and credentials. Add only indexers you are entitled to use, and only for
content you have the right to download. The servarr wiki and the community
[TRaSH guides](https://trash-guides.info/) track which definitions are currently
healthy.

#### Indexer proxies

The **Add Indexer Proxy** dialog offers **FlareSolverr**, **Http**, **SOCKS4**, and
**SOCKS5**. These are optional, and **none are required for the normal flow** —
leave this section empty unless a specific indexer forces it.

- **FlareSolverr** — a headless-browser helper that solves Cloudflare anti-bot
  challenges for the few public indexers that still require it (e.g. 1337x, which
  otherwise fails with "Unable to access 1337x.to, blocked by CloudFlare Protection").
  It **is deployed in this cluster** as a stateless, in-cluster-only app
  (`kubernetes/apps/media/flaresolverr/`, ClusterIP `:8191`, no UI, no VPN). Add it as
  a **per-indexer** proxy — see [FlareSolverr for Cloudflare indexers](#flaresolverr-for-cloudflare-indexers).
  It is experimental: Cloudflare actively counters FlareSolverr, so it may not unblock
  every indexer. Prefer indexers that do not need it where you can.
- **Http / SOCKS4 / SOCKS5** — forward an indexer's traffic through an external
  proxy. Not needed here: Prowlarr reaches indexers directly, and it is qBittorrent
  — not Prowlarr — that egresses through the ProtonVPN tunnel.

##### FlareSolverr for Cloudflare indexers

FlareSolverr is a **per-indexer** proxy — attach it only to the indexers that need it,
never globally. It and Prowlarr must share the same outward-facing IP (both egress
directly, no VPN), or the Cloudflare session breaks; do not route FlareSolverr through
Gluetun.

1. **Settings → Indexers → Add Indexer Proxy → FlareSolverr.**
   - **Name:** `FlareSolverr`
   - **Host:** `http://flaresolverr.media.svc.cluster.local:8191`
   - **Tags:** `flaresolverr`
   - **Test**, require success, **Save**.
2. Open the Cloudflare-protected indexer (e.g. **1337x**) and add the tag
   `flaresolverr` to it — **and only to it**. Do not tag indexers that do not need it.
3. **Test the indexer.** Success requires all three: the proxy Test passes, the 1337x
   indexer Test passes, **and** a manual 1337x search in Prowlarr returns real results.

If 1337x still fails after confirming the tag, confirming Prowlarr and FlareSolverr share
one egress IP, and trying the primary plus one current alternate 1337x URL — **stop**.
Do not escalate to custom Chrome flags, extra proxies, VPN routing, or a privileged
container to force one optional public indexer. Disable 1337x, leave FlareSolverr for the
next indexer that needs it, and continue with your other indexers.

Do not add qBittorrent under **Prowlarr → Settings → Download Clients** for the
normal automation flow. Prowlarr download clients are only used for searches
initiated directly in Prowlarr; Sonarr, Radarr, and Lidarr use their own clients.
If direct Prowlarr searches are deliberately enabled, configure the same in-cluster
qBittorrent URL and permanent WebUI credential used by the downstream apps, with a
separate category chosen for those searches.

### API key

The Prowlarr API key is under **Settings → General → Security**. Do not paste it
into documentation or chat.

The Homepage widget uses an independently rotatable SOPS Secret created by:

```bash
printf 'Prowlarr API key: '
IFS= read -r -s PROWLARR_API_KEY
printf '\n'
export PROWLARR_API_KEY
export HOMEPAGE_PROWLARR_SECRETS_CONFIRM='write:monitoring:homepage-prowlarr:sops'
mise exec -- just repo homepage-prowlarr-secrets
unset PROWLARR_API_KEY HOMEPAGE_PROWLARR_SECRETS_CONFIRM
```

Run this only when creating or rotating the widget Secret. Commit only the
resulting encrypted `homepage-prowlarr.sops.yaml`.

Application connections are completed after the downstream apps have generated
their API keys; see [Connect Prowlarr to Sonarr, Radarr, and Lidarr](#connect-prowlarr-to-sonarr-radarr-and-lidarr).

### Check

```bash
mise exec -- just kube arr-verify prowlarr
```

## Sonarr

Open `https://sonarr.lab.supermorphic.com`.

### Authentication

On a new PVC, configure:

| Setting | Value |
|---|---|
| Authentication Method | `Forms (Login Page)` |
| Authentication Required | `Enabled` |
| Username | A unique operator username |
| Password | A unique password from the password manager |

### Media management

1. Open **Settings → Media Management**.
2. Enable **Show Advanced**.
3. Configure episode naming:

   | Setting | Value |
   |---|---|
   | Rename Episodes | Enabled |
   | Replace Illegal Characters | Enabled |
   | Colon Replacement | `Smart Replace` |
   | Standard Episode Format | `{Series Title} ({Series Year}) - S{season:00}E{episode:00}` |
   | Daily Episode Format | Leave at the default |
   | Anime Episode Format | Leave at the default; anime is not currently used |
   | Series Folder Format | `{Series Title} ({Series Year})` |
   | Season Folder Format | `Season {season:00}` |
   | Specials Folder Format | `Specials` |
   | Multi Episode Style | `Prefixed Range` |

4. Configure folders:

   | Setting | Value |
   |---|---|
   | Create Empty Series Folders | Disabled |
   | Delete Empty Folders | Enabled |

5. Configure importing:

   | Setting | Value |
   |---|---|
   | Episode Title Required | `Never` |
   | Skip Free Space Check | Disabled |
   | Minimum Free Space | `102400 MB` |
   | Use Hardlinks instead of Copy | Enabled |
   | Import Using Script | Disabled |
   | Import Extra Files | Enabled (extensions: `srt`) |

6. Configure file management:

   | Setting | Value |
   |---|---|
   | Unmonitor Deleted Episodes | Disabled |
   | Propers and Repacks | `Prefer and Upgrade` |
   | Analyse Video Files | Enabled |
   | Rescan Series Folder after Refresh | `After Manual Refresh` |
   | Change File Date | `None` |
   | Recycling Bin | Blank |
   | Set Permissions | Disabled |

7. Under **Root Folders**, select **Add Root Folder**.
8. Enter `/data/media/tv` and save.

The root folder is the organized Plex TV library. Never set it to
`/data/downloads` or one of its children.

Sonarr leaves qBittorrent's release names unchanged and creates the Plex-facing
library structure during import. For example:

```text
/data/media/tv/
└── Better Call Saul (2015)/
    └── Season 01/
        ├── Better Call Saul (2015) - S01E01.mkv
        ├── Better Call Saul (2015) - S01E02.mkv
        └── ...
```

After entering the naming tokens, verify that Sonarr's previews show a series
year, a zero-padded season folder such as `Season 01`, and `S01E01` episode
notation before saving.

### Indexers

Do not add indexers in Sonarr. Prowlarr owns them and pushes them here during the
[application connection](#connect-prowlarr-to-sonarr-radarr-and-lidarr) with `Full Sync`.
After that step, Sonarr's **Settings → Indexers** lists entries ending in
`(Prowlarr)`; if it is empty, the Prowlarr app connection has not run yet.

### qBittorrent download client

Open **Settings → Download Clients → Add → qBittorrent** and enter:

| Setting | Value |
|---|---|
| Name | `qBittorrent` |
| Enable | Enabled |
| Host | `qbittorrent.media.svc.cluster.local` |
| Port | `8080` |
| Use SSL | Disabled |
| URL Base | Blank |
| Username | The permanent qBittorrent WebUI username |
| Password | The permanent qBittorrent WebUI password |
| Category | `tv` |
| Post-Import Category | Blank |
| Initial State | `Started` |
| Remove Completed | Disabled |

Select **Test**, require a successful result, and then **Save**. qbit_manage,
not Sonarr, owns successful-torrent seeding and cleanup; see
[Cleanup authority](#cleanup-authority).

Do not add a remote path mapping. Sonarr and qBittorrent mount the same PVC at
the same `/data` path.

### Quality profile

Sonarr ships default quality profiles. The repository does not prescribe a
release-quality policy; the profile is chosen per series when you add it (and again
in Seerr's [Sonarr service](#sonarr-service) step). No setup action is required here.

### API key

Sonarr's API key is under **Settings → General → Security**. You do **not** paste it
into Sonarr — it is entered elsewhere: Prowlarr, in
[Connect Prowlarr to Sonarr, Radarr, and Lidarr](#connect-prowlarr-to-sonarr-radarr-and-lidarr);
Seerr, in the [Sonarr service](#sonarr-service) step; and the Homepage widget below.
Copy it only when entering it into those screens; never commit it.

The Homepage Sonarr widget reads the same key from an independently rotatable SOPS
Secret. Create it without printing the value:

```bash
printf 'Sonarr API key: '
IFS= read -r -s SONARR_API_KEY
printf '\n'
export SONARR_API_KEY
export HOMEPAGE_SONARR_SECRETS_CONFIRM='write:monitoring:homepage-sonarr:sops'
mise exec -- just repo homepage-sonarr-secrets
unset SONARR_API_KEY HOMEPAGE_SONARR_SECRETS_CONFIRM
```

Run this only when creating or rotating the widget Secret. Commit only the resulting
encrypted `homepage-sonarr.sops.yaml`. The widget stays blank until the Secret exists
and Flux reconciles it.

### Check

```bash
mise exec -- just kube arr-verify sonarr
```

## Radarr

Open `https://radarr.lab.supermorphic.com`.

### Authentication

On a new PVC, configure:

| Setting | Value |
|---|---|
| Authentication Method | `Forms (Login Page)` |
| Authentication Required | `Enabled` |
| Username | A unique operator username |
| Password | A unique password from the password manager |

### Media management

1. Open **Settings → Media Management**.
2. Enable **Show Advanced**.
3. Configure movie naming:

   | Setting | Value |
   |---|---|
   | Rename Movies | Enabled |
   | Replace Illegal Characters | Enabled |
   | Colon Replacement | `Smart Replace` |
   | Standard Movie Format | `{Movie CleanTitle} ({Release Year})` |
   | Movie Folder Format | `{Movie CleanTitle} ({Release Year})` |

4. Configure folders:

   | Setting | Value |
   |---|---|
   | Create Empty Movie Folders | Disabled |
   | Delete Empty Folders | Enabled |

5. Configure importing:

   | Setting | Value |
   |---|---|
   | Skip Free Space Check | Disabled |
   | Minimum Free Space | `102400 MB` |
   | Use Hardlinks instead of Copy | Enabled |
   | Import Using Script | Disabled |
   | Import Extra Files | Enabled (extensions: `srt`) |

6. Configure file management:

   | Setting | Value |
   |---|---|
   | Unmonitor Deleted Movies | Disabled |
   | Propers and Repacks | `Prefer and Upgrade` |
   | Analyse Video Files | Enabled |
   | Rescan Movie Folder after Refresh | `After Manual Refresh` |
   | Change File Date | `None` |
   | Recycling Bin | Blank |
   | Set Permissions | Disabled |

7. Under **Root Folders**, select **Add Root Folder**.
8. Enter `/data/media/movies` and save.

The root folder is the organized Plex movie library. Never set it to
`/data/downloads` or one of its children.

Radarr leaves qBittorrent's release name unchanged and creates the Plex-facing
movie folder and filename during import. For example:

```text
/data/media/movies/
└── The Substance (2024)/
    └── The Substance (2024).mkv
```

After entering the naming tokens, verify that Radarr's previews show the movie
title followed by the release year in parentheses before saving.

### Indexers

Do not add indexers in Radarr. Prowlarr owns them and pushes them here during the
[application connection](#connect-prowlarr-to-sonarr-radarr-and-lidarr) with `Full Sync`.
After that step, Radarr's **Settings → Indexers** lists entries ending in
`(Prowlarr)`; if it is empty, the Prowlarr app connection has not run yet.

### qBittorrent download client

Open **Settings → Download Clients → Add → qBittorrent** and enter:

| Setting | Value |
|---|---|
| Name | `qBittorrent` |
| Enable | Enabled |
| Host | `qbittorrent.media.svc.cluster.local` |
| Port | `8080` |
| Use SSL | Disabled |
| URL Base | Blank |
| Username | The permanent qBittorrent WebUI username |
| Password | The permanent qBittorrent WebUI password |
| Category | `movies` |
| Post-Import Category | Blank |
| Initial State | `Started` |
| Remove Completed | Disabled |

Select **Test**, require a successful result, and then **Save**. qbit_manage,
not Radarr, owns successful-torrent seeding and cleanup; see
[Cleanup authority](#cleanup-authority).

Do not add a remote path mapping. Radarr and qBittorrent mount the same PVC at
the same `/data` path.

### Quality profile

Radarr ships default quality profiles. The repository does not prescribe a
release-quality policy; the profile is chosen per movie when you add it (and again in
Seerr's [Radarr service](#radarr-service) step). No setup action is required here.

### API key

Radarr's API key is under **Settings → General → Security**. You do **not** paste it
into Radarr — it is entered elsewhere: Prowlarr, in
[Connect Prowlarr to Sonarr, Radarr, and Lidarr](#connect-prowlarr-to-sonarr-radarr-and-lidarr);
Seerr, in the [Radarr service](#radarr-service) step; and the Homepage widget below.
Copy it only when entering it into those screens; never commit it.

The Homepage Radarr widget reads the same key from an independently rotatable SOPS
Secret. Create it without printing the value:

```bash
printf 'Radarr API key: '
IFS= read -r -s RADARR_API_KEY
printf '\n'
export RADARR_API_KEY
export HOMEPAGE_RADARR_SECRETS_CONFIRM='write:monitoring:homepage-radarr:sops'
mise exec -- just repo homepage-radarr-secrets
unset RADARR_API_KEY HOMEPAGE_RADARR_SECRETS_CONFIRM
```

Run this only when creating or rotating the widget Secret. Commit only the resulting
encrypted `homepage-radarr.sops.yaml`. The widget stays blank until the Secret exists
and Flux reconciles it.

### Check

```bash
mise exec -- just kube arr-verify radarr
```

## Lidarr

Lidarr is staged suspended. From a clean checkout of the authorized deployment
source, the operator performs its guarded first bootstrap:

```bash
export ARR_BOOTSTRAP_CONFIRM='bootstrap:arr:lidarr'
mise exec -- just bootstrap arr lidarr
unset ARR_BOOTSTRAP_CONFIRM
```

Then open `https://lidarr.lab.supermorphic.com` and configure the new PVC to reach
every required state below.

### Authentication

On a new PVC, configure **Forms (Login Page)** authentication as enabled with a
unique username and password-manager credential.

### SMB music directory

Create the library directory on the SMB share before adding it to Lidarr:

```text
media/
├── movies/
├── music/
└── tv/
```

The paths are two views of the same SMB share:

| Consumer | Music-library path |
|---|---|
| Lidarr | `/data/media/music` |
| Future Plex Music library | `/Volumes/Prometheus/media/music` |

Use this prerequisite sequence:

1. Create `media/music` on the SMB share beside `media/movies` and `media/tv`.
2. Confirm Lidarr sees it as `/data/media/music`.
3. Confirm Lidarr can write it using stack UID/GID `568`.
4. Never use `/data/downloads/music` as the library root.
5. Keep Plex Music library creation deferred until real-import acceptance passes.

If `/data/media` is absent, diagnose the mount. If `/data/media/music` is visible
but not writable, diagnose its ownership and permissions. A missing directory can
produce `Path '/data/media/music' does not exist`; saving the root-folder path does
not necessarily create it.

### Importing

Under **Settings → Media Management**, keep **Use Hardlinks instead of Copy**
enabled. The shared `/data` filesystem and the separate download and library
paths allow this setting to avoid a duplicate copy during import.

### Track naming

Open **Settings → Media Management → Show Advanced → Track Naming** and set:

| Setting | Value |
|---|---|
| Rename Tracks | Enabled |
| Replace Illegal Characters | Enabled |
| Colon Replacement | `Smart Replace` |
| Artist Folder Format | `{Artist Name}` |

The required output is:

```text
Artist/
└── Album/
    ├── 101 - Track Title.ext
    ├── 102 - Track Title.ext
    ├── 201 - Track Title.ext
    └── ...
```

Do not put a release year in the album folder; do not repeat the artist or album
in the track filename; and do not create `CD 01`, `Disc 1`, or any other
per-disc directory. Disc 1 track 1 is `101`, disc 2 track 1 is `201`, and all
discs stay in one album directory.

The completed walkthrough recorded these intended values:

| Setting | Intended value |
|---|---|
| Standard Track Format | `{Album Title}/1{track:00} - {Track Title}` |
| Multi Disc Track Format | `{Album Title}/{medium:0}{track:00} - {Track Title}` |

The repository does not independently prove the deployed Lidarr version's saved
token strings. The deployed saved value and its preview are authoritative. Do
not save until previews show all of the following:

- Single-disc: `The Album Title/103 - Track Title`
- Multi-disc, disc 1: `The Album Title/103 - Track Title`
- Multi-disc, disc 2: `The Album Title/203 - Track Title`

Keep the compilation output contract: `/data/media/music/Various Artists/{Album}/...`,
with embedded `Album Artist` equal to `Various Artists` and embedded `Artist`
equal to the performer.

### Audio metadata writing

Open **Settings → Metadata → Write Metadata to Audio Files** and confirm the
saved state:

| Setting | Value |
|---|---|
| Tag Audio Files with Metadata | `Never` |
| Scrub Existing Tags | Disabled |
| Kodi/Emby metadata consumer | Disabled |
| Roksbox metadata consumer | Disabled |
| WDTV metadata consumer | Disabled |

The library file and download file are hardlinks to one inode. Writing or
scrubbing embedded tags therefore changes the seeded file and can cause a
qBittorrent hash-check failure.

### Quality profile

Create a new profile; do not modify the built-in **Lossless** profile. Open
**Settings → Profiles → Quality Profiles → Add** and set:

| Setting | Value |
|---|---|
| Name | `Lossless Preferred` |
| Upgrades Allowed | Enabled |
| Lossless group | Enabled |
| High Quality Lossy group | Enabled as fallback |
| Upgrade Until/Cutoff | `Lossless`, when exposed |
| WAV | Disabled |
| Mid Quality Lossy | Disabled |
| Low Quality Lossy | Disabled |
| Poor Quality Lossy | Disabled |
| Trash Quality Lossy | Disabled |
| Unknown | Disabled |

This accepts high-quality lossy as a fallback, prefers acceptable lossless, and
upgrades later until the Lossless cutoff. Do not claim that FLAC is preferred
over every codec: without a custom format or group ordering, the built-in
Lossless group contains multiple codecs.

### Metadata profile

Reuse the unchanged **Standard** profile at **Settings → Profiles → Metadata
Profiles → Standard**:

| Group | Enabled | Disabled |
|---|---|---|
| Primary Types | Album | Broadcast, EP, Other, Single |
| Secondary Types | Studio | Spokenword, Soundtrack, Remix, Mixtape/Street, Live, Interview, DJ-mix, Demo, Compilation, Audio drama |
| Release Statuses | Official | Pseudo-Release, Promotion, Bootleg |

This is a conservative official-studio-album policy. Compilation naming remains
supported, but this profile excludes compilation releases; add a separate profile
later if that policy changes.

### Root-folder defaults

After creating `Lossless Preferred` and confirming the unchanged `Standard`
metadata profile, open **Settings → Media Management → Root Folders → Add Root
Folder** and set:

| Setting | Value |
|---|---|
| Name | `Music` |
| Path | `/data/media/music` |
| Monitor | `None` |
| Monitor New Albums | `No New Albums` |
| Quality Profile | `Lossless Preferred` |
| Metadata Profile | `Standard` |
| Default Lidarr Tags | Blank |

Both monitoring defaults are conservative: detecting or importing an artist must
not unexpectedly monitor its whole discography. Select albums explicitly.

### qBittorrent download client

Open **Settings → Download Clients → Add → qBittorrent** and set:

| Setting | Value |
|---|---|
| Name | `qBittorrent` |
| Enable | Enabled |
| Host | `qbittorrent.media.svc.cluster.local` |
| Port | `8080` |
| Use SSL | Disabled |
| URL Base | Blank |
| Username/password | Permanent qBittorrent WebUI credentials |
| Category | `music` |
| Post-Import Category | Blank |
| Recent Priority | `Last` |
| Older Priority | `Last` |
| Initial State | `Started` |
| Sequential Order | Disabled |
| First and Last First | Disabled |
| Content Layout | `Default` |
| Client Priority | `1` |
| Tags | Blank |
| Remove Completed | Disabled |

Select **Test**, require a successful result, then **Save**. Do not add a remote
path mapping: Lidarr and qBittorrent see the same `/data` path. Leaving
**Post-Import Category** blank preserves `music`; do not use `Forced`. qbit_manage,
not Lidarr, owns successful-torrent seeding and cleanup; see
[Cleanup authority](#cleanup-authority).

Lidarr's API key becomes available only after first boot. Once the application is
configured, create the independently rotatable Homepage Secret without echoing the key:

```bash
printf 'Lidarr API key: '
IFS= read -r -s LIDARR_API_KEY
printf '\n'
export LIDARR_API_KEY
export HOMEPAGE_LIDARR_SECRETS_CONFIRM='write:monitoring:homepage-lidarr:sops'
mise exec -- just repo homepage-lidarr-secrets
unset LIDARR_API_KEY HOMEPAGE_LIDARR_SECRETS_CONFIRM
```

Run this recipe only after first boot. Only the resulting SOPS-encrypted
`homepage-lidarr.sops.yaml` enters PR 2; do not add it to the initial staging PR,
and never commit the plaintext API key. Keep `kubernetes/apps/media/lidarr/ks.yaml`
at `suspend: true` until this Secret, the first-run configuration, and the authorized
real-import acceptance gate all pass; PR 2 is the only activation change.

The recipe leaves that encrypted file untracked in the checkout, and every guarded
`bootstrap` recipe refuses to run from a checkout with any uncommitted change. Commit
the Secret to the PR 2 branch (or stash it) before attempting another guarded rollout
from this worktree.

## Connect Prowlarr to Sonarr, Radarr, and Lidarr

Return to `https://prowlarr.lab.supermorphic.com`. Add each application as soon as it
is available — you do not need all three at once. Connect **Sonarr** immediately after
its rollout, then connect **Radarr** after its activation. Connect **Lidarr** after its
guarded bootstrap and first-run configuration, once its staged endpoint is available,
while `kubernetes/apps/media/lidarr/ks.yaml` remains Git-suspended. Lidarr's durable
activation remains deferred to PR 2 until the Prowlarr-backed authorized real-import
acceptance gate passes. Each app connection is independent, and this is where each
application's API key is used.

### Sonarr application

Open **Settings → Apps → Add → Sonarr**:

| Setting | Value |
|---|---|
| Name | `Sonarr` |
| Sync Level | `Full Sync` |
| Prowlarr Server | `http://prowlarr.media.svc.cluster.local:9696` |
| Application Server | `http://sonarr.media.svc.cluster.local:8989` |
| API Key | Sonarr's API key |
| Tags | Blank |
| Sync Categories | Defaults |

Select **Test**, require a successful result, and then **Save**.

### Radarr application

Open **Settings → Apps → Add → Radarr**:

| Setting | Value |
|---|---|
| Name | `Radarr` |
| Sync Level | `Full Sync` |
| Prowlarr Server | `http://prowlarr.media.svc.cluster.local:9696` |
| Application Server | `http://radarr.media.svc.cluster.local:7878` |
| API Key | Radarr's API key |
| Tags | Blank |
| Sync Categories | Defaults |

Select **Test**, require a successful result, and then **Save**.

### Lidarr application

Open **Prowlarr → Settings → Apps → Add → Lidarr**:

| Setting | Value |
|---|---|
| Name | `Lidarr` |
| Sync Level | `Full Sync` |
| Prowlarr Server | `http://prowlarr.media.svc.cluster.local:9696` |
| Application Server | `http://lidarr.media.svc.cluster.local:8686` |
| API Key | Lidarr's API key |
| Tags | Blank |
| Sync Categories | Defaults |

Select **Test**, require a successful result, and then **Save**.

`Full Sync` makes Prowlarr authoritative for the indexers it manages. Do not edit
those generated indexers independently in Sonarr, Radarr, or Lidarr. Confirm that each
application now lists indexers whose names end in `(Prowlarr)`.

## Plex

Plex is the destination for imported media rather than part of the download
automation path. Open `https://plex.lab.supermorphic.com`.

1. Confirm the existing TV library reads from
   `/Volumes/Prometheus/media/tv`.
2. Confirm the existing movie library reads from
   `/Volumes/Prometheus/media/movies`.
3. A manual scan belongs to a newly created library only. Do not make routine
   Sonarr or Radarr imports depend on manually choosing **Scan Library Files**;
   their direct Plex connections below notify Plex after organized-library changes.

Creating the Plex Music library is explicitly deferred until the blocking Lidarr
real-import acceptance succeeds, PR 2 makes activation durable, and
`mise exec -- just kube arr-verify lidarr` passes. Then create it at
`/Volumes/Prometheus/media/music`, run one initial manual scan, and only then
configure the Lidarr connection below.

Plex mounts the same SMB share under `/Volumes/Prometheus`, while qBittorrent,
Sonarr, Radarr, and Lidarr mount it under `/data`. These are two views of the same
share; do not change the *arr paths to match the Plex container path.

Run:

```bash
mise exec -- just kube plex-verify
```

## Seerr

Complete this section only after the Phase 14 Seerr rollout is live. Open
`https://seerr.lab.supermorphic.com`.

### Plex

1. Sign in with the Plex administrator account.
2. Open **Settings → Media Server → Plex**.
3. Select the existing Plex server, or enter it manually:

   | Setting | Value |
   |---|---|
   | Hostname or IP Address | `plex.media.svc.cluster.local` |
   | Port | `32400` |
   | Use SSL | Disabled |
   | Web App URL | `https://plex.lab.supermorphic.com/web` |

4. Select the TV and movie libraries.
5. Save, select **Sync Libraries**, and complete Seerr's one-time Plex catalog
   synchronization/import. This is not Plex **Scan Library Files** and does not
   replace direct *arr → Plex connector validation.

### Sonarr service

Open **Settings → Services → Sonarr → Add Sonarr Server**:

| Setting | Value |
|---|---|
| Default Server | Enabled |
| 4K Server | Disabled |
| Server Name | `Sonarr` |
| Hostname or IP Address | `sonarr.media.svc.cluster.local` |
| Port | `8989` |
| Use SSL | Disabled |
| API Key | Sonarr's API key |
| URL Base | Blank |
| Root Folder | `/data/media/tv` |
| External URL | `https://sonarr.lab.supermorphic.com` |
| Enable Scan | Enabled |
| Enable Automatic Search | Enabled |

Select the intended Sonarr quality profile when Seerr loads the available
profiles. The repository does not prescribe a release-quality policy. Test the
connection and save.

### Radarr service

Open **Settings → Services → Radarr → Add Radarr Server**:

| Setting | Value |
|---|---|
| Default Server | Enabled |
| 4K Server | Disabled |
| Server Name | `Radarr` |
| Hostname or IP Address | `radarr.media.svc.cluster.local` |
| Port | `7878` |
| Use SSL | Disabled |
| API Key | Radarr's API key |
| URL Base | Blank |
| Root Folder | `/data/media/movies` |
| External URL | `https://radarr.lab.supermorphic.com` |
| Enable Scan | Enabled |
| Enable Automatic Search | Enabled |

Select the intended Radarr quality profile. Where Seerr requires a minimum
availability choice, `Released` is a conservative general default; change it only
as an explicit content policy. Test the connection and save.

At least one Sonarr server and one Radarr server must be marked **Default** or
Seerr cannot dispatch requests.

### Users

Open **Settings → Users**:

1. Review the default permissions before allowing new Plex sign-ins.
2. Import Plex users or allow new Plex users to sign in, as desired.
3. Grant request, auto-approve, and administrative permissions deliberately.
4. Set request quotas if the household needs them.

### API key (Homepage widget)

Seerr's own API key is under **Settings → General → API Key** (it exists as soon as
Seerr boots, independent of the Plex/*arr wiring above). The Homepage Seerr widget reads
it from an independently rotatable SOPS Secret. Create it without printing the value:

```bash
printf 'Seerr API key: '
IFS= read -r -s SEERR_API_KEY
printf '\n'
export SEERR_API_KEY
export HOMEPAGE_SEERR_SECRETS_CONFIRM='write:monitoring:homepage-seerr:sops'
mise exec -- just repo homepage-seerr-secrets
unset SEERR_API_KEY HOMEPAGE_SEERR_SECRETS_CONFIRM
```

Run this only when creating or rotating the widget Secret. Commit only the resulting
encrypted `homepage-seerr.sops.yaml`. The widget stays blank until the Secret exists and
Flux reconciles it.

### Check

```bash
mise exec -- just kube seerr-verify
```

## End-to-end acceptance

### Direct Lidarr test — blocking operator gate

Perform this gate at step 9 of [Order of operations](#order-of-operations): only
after the Sonarr and Radarr direct-import and Plex refresh validations. Then make
activation durable in PR 2 and run `mise exec -- just kube arr-verify lidarr`
before creating the Plex Music library. It appears here with the other acceptance
evidence for reference.

This is the blocking gate between the initial staging PR and the follow-up activation
PR, not automated E2E coverage. Before grabbing, search for a real artist and confirm
its artist and album metadata loads. Add it with root `/data/media/music`, quality
profile `Lossless Preferred`, metadata profile `Standard`, and only the intended test
album monitored. Do not search or monitor the whole discography. Choose one authorized,
uncomplicated release and record all of this evidence:

```text
qBittorrent category: music
download root: /data/downloads/music
library root: /data/media/music
library naming: Artist/Album/DiscTrack - Title.ext
download-side link count: 2
library-side link count: 2
Tag Audio Files with Metadata: Never
qBittorrent force recheck: completes with no hash error
```

Verify the qBittorrent category is `music`, its download path is
`/data/downloads/music`, and Lidarr's library is `/data/media/music`. Confirm the
imported naming is `Artist/Album/DiscTrack - Title.ext`, **Tag Audio Files with
Metadata** remains `Never`, and the download-side link count is `2`. Run
qBittorrent's force recheck after import and require it to complete with no hash
error. Collect both link counts from the download-side and library-side files for
the same track. If a shell is needed to inspect inode or link counts, use an
existing guarded recipe or a NAS-side shell; never use raw `kubectl exec`.

Do not begin the follow-up PR or create the Plex Music library until every item above
passes. If the deployed saved naming values or labels differ from this recorded
walkthrough, preserve the authoritative preview output and safety states, then record
the deployed values for a follow-up runbook correction.

The required Lidarr order is: guarded bootstrap; create the required profiles and
root folder; connect Prowlarr while the Git source remains suspended and the staged
endpoint is available; complete authorized acceptance; activate in PR 2; then run
the guarded verification:

```bash
mise exec -- just kube arr-verify lidarr
```

The `/ping` endpoint used by the Pod probes and later by Gatus does not exercise
`api.lidarr.audio`. A green Pod or Gatus endpoint therefore does not guarantee that
artist or album searches work; the real search is verified during first-run acceptance.

### Direct Sonarr test

1. Search for one TV series in Sonarr.
2. Start a monitored download.
3. Confirm qBittorrent receives it with category `tv`.
4. Confirm its download path is below `/data/downloads/tv`.
5. Confirm Sonarr imports it below `/data/media/tv`.

### Direct Radarr test

1. Search for one movie in Radarr.
2. Start a monitored download.
3. Confirm qBittorrent receives it with category `movies`.
4. Confirm its download path is below `/data/downloads/movies`.
5. Confirm Radarr imports it below `/data/media/movies`.

The download and imported files must be hardlinks, not duplicate copies. The
shared-filesystem proof and prior acceptance evidence are in
[`phase-11-media.md`](phase-11-media.md).

## Direct Plex library-refresh connections

These are post-import library-refresh notifications, not download or import
configuration:

```text
Sonarr/Radarr/Lidarr
        → import or modify organized library files
        → notify Plex
        → Plex scans the affected library
```

Use each application's native **Settings → Connect → Add → Plex Media Server**
dialog. Select **Test**, require success, and only then **Save**. Never put a
username, password, token, screenshot, shell-history value, or example secret in
this runbook or Git. Obtain **Auth Token** through the application's
**Authenticate with Plex.tv** flow, or enter the existing token securely.

Unless an app-specific section says otherwise, use these deployed values:

| Setting | Value |
|---|---|
| Name | `Plex Media Server` |
| Host | `plex.media.svc.cluster.local` |
| Port | `32400` |
| Use SSL | Disabled |
| URL Base | Blank |
| Auth Token | Authenticate with Plex.tv or enter the existing token securely; never document or store it |
| Update Library | Enabled |
| Tags | Blank |
| Map Paths From | Blank |
| Map Paths To | Blank |

The applications and Plex view the same SMB-backed media through different
container paths:

| Application | *arr library path | Plex library path |
|---|---|---|
| Sonarr | `/data/media/tv` | `/Volumes/Prometheus/media/tv` |
| Radarr | `/data/media/movies` | `/Volumes/Prometheus/media/movies` |
| Lidarr | `/data/media/music` | `/Volumes/Prometheus/media/music` |

Do not change an *arr root folder to `/Volumes/Prometheus`. Although the deployed
connectors expose **Map Paths From** and **Map Paths To**, leave both blank for
all three connections by operator instruction. These optional Plex connector
fields are not qBittorrent download-client Remote Path Mapping. Acceptance must
prove that each connection refreshes its intended Plex library.

### Sonarr → Plex

After the successful direct Sonarr import and Plex TV path verification, open
**Sonarr → Settings → Connect → Add → Plex Media Server**. The deployed dialog
title is **Edit Connection - Plex Media Server**. Authenticate, then select the
deployed Plex server in **Server** without recording account or credential data.
Use the common values above and set these deployed triggers:

| Trigger | State |
|---|---|
| On Grab | Disabled |
| On File Import | Enabled |
| On File Upgrade | Enabled |
| On Import Complete | Enabled |
| On Rename | Enabled |
| On Series Add | Disabled |
| On Series Delete | Enabled |
| On Episode File Delete | Enabled |
| On Episode File Delete For Upgrade | Enabled |
| On Health Issue | Disabled |
| On Health Restored | Disabled |
| On Application Update | Disabled |
| On Manual Interaction Required | Disabled |

**On Grab** is disabled because a grab event itself does not modify organized
library files. Import, upgrade, rename, and selected delete events are the refresh
triggers regardless of current library contents. **On Import Complete** was enabled
in the recorded walkthrough and can overlap file-level import events; use controlled
acceptance to assess scan frequency. The captured
walkthrough had **On Series Add** enabled, but leave it disabled for this minimal
library-changing policy because adding a series does not import a file.

Validate with a controlled Sonarr import or Sonarr-managed rename. Confirm a
successful Plex connection event, a Plex TV scan, and the correct appearance
without manually choosing **Scan Library Files**.

### Radarr → Plex

After the successful direct Radarr import and Plex Movies path verification, open
**Radarr → Settings → Connect → Add → Plex Media Server**. The deployed dialog
title is **Edit Notification - Plex Media Server**. Authenticate using **Start
OAuth** under **Authenticate with Plex.tv**, then select the deployed Plex server
in **Server** without recording account or credential data. Use the common values
above and set these deployed triggers:

| Trigger | State |
|---|---|
| On Grab | Disabled |
| On File Import | Enabled |
| On File Upgrade | Enabled |
| On Rename | Enabled |
| On Movie Added | Disabled |
| On Movie Delete | Enabled |
| On Movie File Delete | Enabled |
| On Movie File Delete For Upgrade | Enabled |
| On Health Issue | Disabled |
| On Health Restored | Disabled |
| On Application Update | Disabled |
| On Manual Interaction Required | Disabled |

**On Grab** is disabled because a grab event itself does not modify organized
library files. Import, upgrade, rename, and selected delete events are the refresh
triggers regardless of current library contents. The deployed help describes
**Map Paths From** as the Radarr path and
**Map Paths To** as the Plex path, but leave both blank by operator instruction.
The captured walkthrough did not use **On Movie Added**; leave it disabled because
adding a movie does not import a file.

Validate with a controlled Radarr import or Radarr-managed rename. Confirm a
successful Plex connection event, a Plex Movies scan, and the correct appearance
without manually choosing **Scan Library Files**.

### Create the Plex Music library

Only after the blocking Lidarr authorized real-import acceptance passes, PR 2
makes activation durable, and `mise exec -- just kube arr-verify lidarr` passes,
create the Plex Music library at `/Volumes/Prometheus/media/music` and run its
initial manual scan. This is the one manual scan for the new library; subsequent
Lidarr-organized changes use the connection below.

### Lidarr → Plex

Do not configure this connection until all five conditions are complete:

1. Authorized real-import acceptance passed.
2. Download/library link counts verified.
3. Force Recheck completed without hash error.
4. Plex Music library created at `/Volumes/Prometheus/media/music`.
5. Initial manual Plex Music scan succeeded.

Then open **Lidarr → Settings → Connect → Add → Plex Media Server**. The deployed
dialog title is **Edit Connection - Plex Media Server**. Unlike the captured
Sonarr and Radarr dialogs, the captured Lidarr view did not show a **Server**
selector; do not invent one. Use the common values above and set these deployed
triggers:

| Trigger | State |
|---|---|
| On Grab | Disabled |
| On Release Import | Enabled |
| On Upgrade | Enabled |
| On Download Failure | Disabled |
| On Import Failure | Disabled |
| On Rename | Enabled |
| On Track Retag | Enabled |
| On Artist Add | Disabled |
| On Artist Delete | Enabled when the operator wants stale Plex artist entries removed after a Lidarr-managed deletion |
| On Album Delete | Disabled |
| On Application Update | Disabled |
| On Health Issue | Disabled |
| On Health Restored | Disabled |

**On Grab** is disabled because a grab event itself does not modify organized
library files. Import, upgrade, rename, retag, and selected delete events are the
refresh triggers regardless of current library contents. **On Track Retag** is
enabled because retagging changes organized library files. The captured walkthrough
had **On Artist Add** enabled, but leave it disabled for this minimal
library-changing policy because adding an artist does
not import a file. **On Album Delete** was disabled in the recorded walkthrough;
enable it only if later controlled testing proves it operationally required.

Validate with a second small authorized import or a Lidarr-managed rename of the
acceptance album. Confirm a successful Plex connection event, a Plex Music scan,
and the album or renamed tracks appear without a manual scan.

### Delete events and ownership

Do not blindly enable every delete event. File-delete events refresh Plex after an
*arr-managed deletion of an organized-library file. Entity-delete events (artist,
series, or movie) are useful only when the *arr-managed entity removal also deletes
organized media or would otherwise leave stale Plex entries. This is distinct from
removing the original torrent from qBittorrent or qbit_manage cleaning
`/data/downloads`; neither changes the organized library and neither must trigger
Plex refresh.

### Troubleshooting direct Plex refresh

1. **Test fails:** verify Pod reachability to
   `plex.media.svc.cluster.local:32400`, in-cluster SSL is disabled, the token is
   valid, and the Plex server is claimed and available.
2. **Test succeeds but no scan:** verify the relevant exact trigger, inspect
   *arr **System → Events** and **System → Logs**, confirm an
   organized-library import rather than a change only in `/data/downloads`, and
   confirm the Plex library uses the matching `/Volumes/Prometheus/media/...`
   folder.
3. **Wrong or no library match:** compare the paths in the table above, retain
   blank map fields per deployed configuration, and do not add download-client
   Remote Path Mapping. Exact native matching behavior remains
   acceptance-tested rather than repository-verifiable.
4. **Duplicate or excess scans:** use only library-changing events, keep **On
   Grab** disabled, and avoid redundant broad events unless controlled testing
   proves they are necessary.

### Seerr request test

1. Request a TV series in Seerr and confirm it appears in Sonarr.
2. Request a movie in Seerr and confirm it appears in Radarr.
3. Confirm both requests progress through qBittorrent.
4. Confirm the imported media becomes available in Plex and then in Seerr.

The video automation setup is not accepted until both direct *arr flows and their
Plex refresh validations pass. The request workflow is not accepted until the
Seerr request flow passes.

## Recovery and repeat setup

Pod replacement, image upgrades, and node rescheduling reuse the existing PVCs
and do not require this setup again. An empty replacement PVC is a genuine
greenfield install.

Prefer restoring the application configuration PVC or an application-native
backup. Repeating this guide is the fallback when no trusted backup exists.
Never reconstruct a service by committing its live SQLite database or plaintext
configuration directory to Git.

## Upstream references

- [Sonarr quick-start guide](https://wiki.servarr.com/en/sonarr/quick-start-guide)
- [Radarr settings](https://wiki.servarr.com/radarr/settings)
- [Prowlarr quick-start guide](https://wiki.servarr.com/en/prowlarr/quick-start-guide)
- [Plex music naming and organization](https://support.plex.tv/articles/200265296-adding-music-media-from-folders/) — authority for the bare album folder, flat disc/track numbering, and `Various Artists` convention
- [qBittorrent 5.x WebUI API and authentication](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-5.0%29)
- [qBittorrent WebUI password recovery](https://github.com/qbittorrent/qBittorrent/wiki/Web-UI-password-locked-on-qBittorrent-NO-X-%28qbittorrent-nox%29)
- [Seerr media-server settings](https://docs.seerr.dev/using-seerr/settings/mediaserver/)
- [Seerr Sonarr/Radarr service settings](https://docs.seerr.dev/using-seerr/settings/services/)
- [Seerr backups](https://docs.seerr.dev/using-seerr/backups/)
