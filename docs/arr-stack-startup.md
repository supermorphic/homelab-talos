# Media automation greenfield startup

Use this runbook after deploying the media applications onto empty configuration
PVCs. It covers the runtime setup that cannot be expressed by the existing Helm
values alone: qBittorrent, Prowlarr, Sonarr, Radarr, and Seerr.

The Kubernetes resources remain declarative in Git. These application settings are
written by their web UIs into configuration files and SQLite databases on retained
Longhorn PVCs:

| Service | Public operator URL | In-cluster URL | Persistent configuration |
|---|---|---|---|
| qBittorrent | `https://qbittorrent.lab.supermorphic.com` | `http://qbittorrent.media.svc.cluster.local:8080` | `/config` |
| Prowlarr | `https://prowlarr.lab.supermorphic.com` | `http://prowlarr.media.svc.cluster.local:9696` | `/config` |
| Sonarr | `https://sonarr.lab.supermorphic.com` | `http://sonarr.media.svc.cluster.local:8989` | `/config` |
| Radarr | `https://radarr.lab.supermorphic.com` | `http://radarr.media.svc.cluster.local:7878` | `/config` |
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
5. Prowlarr application connections to Sonarr and Radarr.
6. Plex library-path verification.
7. Seerr connections to Plex, Sonarr, and Radarr.
8. Direct Sonarr/Radarr download tests, followed by a Seerr request test.

Complete a service's guarded bootstrap and durable `suspend: false` activation
before configuring it here. Work through the steps incrementally as each service is
activated — you do not need every application live at once. For example, connect
Prowlarr to Sonarr as soon as Sonarr is up (step 5's Sonarr half), before Radarr has
been activated, and complete Radarr's steps later.

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
Radarr, and Homepage use it; Prowlarr uses it only if direct Prowlarr searches are
enabled. Keep the human copy in the password manager and create Homepage's independently
rotatable SOPS Secret without printing either value:

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
│   └── tv/
└── media/
    ├── movies/
    └── tv/
```

### Categories

In the transfer-list sidebar, under **Categories**:

1. Add category `tv` with save path `/data/downloads/tv`.
2. Add category `movies` with save path `/data/downloads/movies`.

Sonarr and Radarr use these exact category names. Automatic Torrent Management
applies the category save paths. Keeping downloads and media under the same
`/data` filesystem allows imports to hardlink rather than copy.

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
initiated directly in Prowlarr; Sonarr and Radarr use their own clients.
If direct Prowlarr searches are deliberately enabled, configure the same in-cluster
qBittorrent URL and permanent WebUI credential used by Sonarr and Radarr, with a
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

Application connections are completed after Sonarr and Radarr have generated
their API keys; see [Connect Prowlarr to Sonarr and Radarr](#connect-prowlarr-to-sonarr-and-radarr).

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
[application connection](#connect-prowlarr-to-sonarr-and-radarr) with `Full Sync`.
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

Leave priority and seeding-policy fields at their defaults unless a separate
policy has been chosen. Select **Test**, require a successful result, and then
**Save**.

Do not add a remote path mapping. Sonarr and qBittorrent mount the same PVC at
the same `/data` path.

### Quality profile

Sonarr ships default quality profiles. The repository does not prescribe a
release-quality policy; the profile is chosen per series when you add it (and again
in Seerr's [Sonarr service](#sonarr-service) step). No setup action is required here.

### API key

Sonarr's API key is under **Settings → General → Security**. You do **not** paste it
into Sonarr — it is entered elsewhere: Prowlarr, in
[Connect Prowlarr to Sonarr and Radarr](#connect-prowlarr-to-sonarr-and-radarr);
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
[application connection](#connect-prowlarr-to-sonarr-and-radarr) with `Full Sync`.
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

Leave priority and seeding-policy fields at their defaults unless a separate
policy has been chosen. Select **Test**, require a successful result, and then
**Save**.

Do not add a remote path mapping. Radarr and qBittorrent mount the same PVC at
the same `/data` path.

### Quality profile

Radarr ships default quality profiles. The repository does not prescribe a
release-quality policy; the profile is chosen per movie when you add it (and again in
Seerr's [Radarr service](#radarr-service) step). No setup action is required here.

### API key

Radarr's API key is under **Settings → General → Security**. You do **not** paste it
into Radarr — it is entered elsewhere: Prowlarr, in
[Connect Prowlarr to Sonarr and Radarr](#connect-prowlarr-to-sonarr-and-radarr);
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

## Connect Prowlarr to Sonarr and Radarr

Return to `https://prowlarr.lab.supermorphic.com`. Add each application as soon as it
is available — you do not need both at once. Connect **Sonarr** immediately after its
rollout; connect **Radarr** once its own activation is live. Each app connection is
independent, and this is the step where each application's API key is finally used.

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

`Full Sync` makes Prowlarr authoritative for the indexers it manages. Do not edit
those generated indexers independently in Sonarr or Radarr. Confirm that each
application now lists indexers whose names end in `(Prowlarr)`.

## Plex

Plex is the destination for imported media rather than part of the download
automation path. Open `https://plex.lab.supermorphic.com`.

1. Confirm the TV library reads from
   `/Volumes/Prometheus/media/tv`.
2. Confirm the movie library reads from
   `/Volumes/Prometheus/media/movies`.
3. Scan both libraries after the first Sonarr/Radarr import.

Plex mounts the same SMB share under `/Volumes/Prometheus`, while qBittorrent,
Sonarr, and Radarr mount it under `/data`. These are two views of the same share;
do not change the *arr paths to match the Plex container path.

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
5. Save, select **Sync Libraries**, and run the initial manual library scan.

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

### Direct Sonarr test

1. Search for one TV series in Sonarr.
2. Start a monitored download.
3. Confirm qBittorrent receives it with category `tv`.
4. Confirm its download path is below `/data/downloads/tv`.
5. Confirm Sonarr imports it below `/data/media/tv`.
6. Confirm the episode appears in Plex.

### Direct Radarr test

1. Search for one movie in Radarr.
2. Start a monitored download.
3. Confirm qBittorrent receives it with category `movies`.
4. Confirm its download path is below `/data/downloads/movies`.
5. Confirm Radarr imports it below `/data/media/movies`.
6. Confirm the movie appears in Plex.

The download and imported files must be hardlinks, not duplicate copies. The
shared-filesystem proof and prior acceptance evidence are in
[`phase-11-media.md`](phase-11-media.md).

### Seerr request test

1. Request a TV series in Seerr and confirm it appears in Sonarr.
2. Request a movie in Seerr and confirm it appears in Radarr.
3. Confirm both requests progress through qBittorrent.
4. Confirm the imported media becomes available in Plex and then in Seerr.

Phase 13 is not complete until both direct *arr flows pass. Phase 14 is not
complete until the Seerr request flow passes.

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
- [qBittorrent 5.x WebUI API and authentication](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-%28qBittorrent-5.0%29)
- [qBittorrent WebUI password recovery](https://github.com/qbittorrent/qBittorrent/wiki/Web-UI-password-locked-on-qBittorrent-NO-X-%28qbittorrent-nox%29)
- [Seerr media-server settings](https://docs.seerr.dev/using-seerr/settings/mediaserver/)
- [Seerr Sonarr/Radarr service settings](https://docs.seerr.dev/using-seerr/settings/services/)
- [Seerr backups](https://docs.seerr.dev/using-seerr/backups/)
