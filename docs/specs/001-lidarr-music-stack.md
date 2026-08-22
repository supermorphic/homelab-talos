# Lidarr Music Stack

## Purpose

Add music automation to the media platform without creating a separate storage,
networking, or operational model. Lidarr is a peer of Sonarr and Radarr: it discovers
releases through Prowlarr, sends downloads to qBittorrent, imports them into the shared
library, and notifies Plex when the library changes.

The music library began as a greenfield service, so the design did not need to preserve
an earlier Lidarr database or directory convention.

## Workload and storage

Lidarr runs as one `Recreate` Deployment in the `media` namespace. The pinned
`ghcr.io/home-operations/lidarr:3.1.2.4902` container listens on port `8686` and uses
three HTTP probes against `/ping`.

Two storage roles remain separate:

- a retained 5 Gi Longhorn `ReadWriteOnce` claim mounted at `/config` holds the Lidarr
  database and application settings; and
- the shared `media-data` SMB claim is mounted at `/data` for downloads and library
  content.

The qBittorrent `music` category writes below `/data/downloads/music`, and Lidarr imports
to `/data/media/music`. Both paths are on the same SMB filesystem, so an import creates
a hardlink instead of a second copy. Removing the download-side name later leaves the
library inode intact.

## Network and trust boundaries

Lidarr is not in the Gluetun network namespace. It uses normal cluster networking to
reach Prowlarr and `qbittorrent.media.svc.cluster.local:8080`; only qBittorrent's
Internet traffic is tunneled through the VPN. This keeps VPN route authority and
`NET_ADMIN` out of the Lidarr workload.

The container runs as UID and GID `568`, cannot elevate privileges, and drops all Linux
capabilities. Its internal HTTPS route attaches to the shared `internal` Gateway at
`lidarr.lab.supermorphic.com`. Flux waits for `media-storage` and `internal-gateway`
before reconciling the application.

API keys and application login credentials are runtime configuration. Lidarr persists
them in its config claim. Homepage receives only its own SOPS-encrypted copy of the API
key; credentials are not embedded in the Helm values or route.

## Quality, naming, and torrent lifecycle

The quality policy prefers FLAC or another lossless release while allowing a lossy
fallback. A lossless-only profile was rejected because it would create unnecessary
library gaps.

The library follows the Plex-compatible structure
`Artist/Album/DiscTrack - Title.ext`. Album folders omit the release year, multi-disc
tracks use a leading disc number in one album directory, and compilations use the
`Various Artists` album-artist convention.

Lidarr must not rewrite metadata inside imported audio files while the torrent remains
active. The download and library paths refer to the same inode, so an in-place tag write
would also change the seeded file and could make qBittorrent's piece check fail.

qbit_manage owns successful torrent seeding and cleanup. Its dedicated `music` group
excludes private-tracker tags, has higher precedence than the general public group, seeds
for at least seven days, stops at ratio `2.0` after that floor or at 30 days, and moves
eligible download-side names through the recycle bin. Set-wide validation keeps the
private-tracker group at highest precedence, requires cleanup-enabled groups to exclude
private tags, and requires unique priorities. These invariants replaced pairwise checks
that stopped being sufficient when music became the third share-limit group.

## Observability and implemented state

The application is active in Git with `spec.suspend: false`. Homepage discovers its
service tile and uses the dedicated API-key Secret for the widget. Gatus checks both the
external `/ping` path and the authenticated native health API. The media alert rules
raise a warning when the authenticated health check fails or its success series
disappears.

Offline validation checks the common `*arr` workload, route, storage, dependency,
security, widget, and monitoring invariants. Read-only live verification checks Flux and
Helm readiness, rollout state, route acceptance, DNS, and `/ping`. Functional acceptance
is stronger: an authorized import demonstrated link count two on both names and a clean
qBittorrent force recheck.

## Consequences

Lidarr reuses the established media architecture, adds no VPN privilege, and does not
double bulk storage during import. The longer music seeding window costs torrent-client
state rather than another copy of the audio data. A healthy `/ping` or native-health
response does not prove that Lidarr's external metadata service is available, so artist
and album discovery can still fail while the workload remains healthy.

Current first-run, credential, naming, and recovery procedure belongs in
`docs/guides/arr-stack-startup.md`.
