# Lidarr Music Stack

## Purpose

Add music automation to the media platform without creating a separate storage,
networking, or operational model. Lidarr is a peer of Sonarr and Radarr: it discovers
releases through Prowlarr, sends downloads to qBittorrent, imports them into the shared
library, and notifies Plex when the library changes.

The music library began as a greenfield service, so the design did not need to preserve
an earlier Lidarr database or directory convention.

Lidarr deliberately followed the established Radarr shape rather than introducing a
fourth media-application pattern. The common Deployment, storage, route, and validation
structure made differences visible as music-specific policy instead of accidental
manifest drift. The shared `*arr` validator was converted from repeated branches to a
table of application contracts for the same reason: adding a peer should add data, not
another copy of validation logic.

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

Because the library was greenfield, the design deliberately adopted Plex's documented
music organization instead of inheriting an earlier convention or accepting Lidarr's
defaults. The library therefore follows the Plex-compatible structure
`Artist/Album/DiscTrack - Title.ext`. Album folders omit the release year, multi-disc
tracks use a leading disc number in one album directory, and compilations use the
`Various Artists` album-artist convention.

Lidarr must not rewrite metadata inside imported audio files while the torrent remains
active. The download and library paths refer to the same inode, so an in-place tag write
would also change the seeded file and could make qBittorrent's piece check fail.

qbit_manage owns successful torrent seeding and cleanup. Its dedicated `music` group
exists because music intentionally seeds longer than movies and TV. Hardlinked imports
mean that longer retention primarily costs qBittorrent lifecycle state, not another bulk
copy of the audio. The group excludes private-tracker tags, has higher precedence than
the general public group, seeds for at least seven days, stops at ratio `2.0` after that
floor or at 30 days, and moves eligible download-side names through the recycle bin.
Set-wide validation keeps the private-tracker group at highest precedence, requires
cleanup-enabled groups to exclude private tags, and requires unique priorities. These
invariants replaced pairwise checks that stopped being sufficient when music became the
third share-limit group.

The precedence and exclusion rules protect different failure classes. A future
finite-stop group with higher precedence than the private group could stop a private
torrent early even when it does not clean up files; the strict-minimum rule catches that
case. A cleanup-enabled group can instead match a generically private torrent that has no
tracker-specific tag; the exclusion rule catches that case even when priorities are
correct. Neither check is a substitute for the other.

## Validation evidence and corrected assumptions

The validator restructure was accepted through a differential method. The existing
three-application result was captured first, the table-driven refactor had to preserve
that result before Lidarr was added, and the Lidarr row then had to add exactly one peer
contract. qbit_manage used the same sequence: first prove the generalized checks were
inert for the existing groups, then add the music policy. This separated confidence in
the refactor from confidence in the new application and policy.

Offline checks cannot prove the storage behavior that matters most. Functional
acceptance used the filesystem and qBittorrent as independent oracles: the download and
library names reported link count two, and a force recheck completed without a hash
error. The target library layout and the required hardlink and metadata-write states
were fixed design requirements. Exact Lidarr UI labels and naming-token spelling were
implementation-time facts and could change without weakening those requirements.

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

The original Lidarr rollout intentionally left Plex Music creation and Plexamp/Sonos
integration to later work. The current
[media automation guide](../guides/media-automation-setup.md) owns Plex Music creation
and the Lidarr-to-Plex refresh connection. Plexamp and Sonos operations belong in the
[Plex remote-access guide](../guides/plex-remote-access-operations.md), with failure
recovery in the [Plex/Sonos recovery runbook](../runbooks/plex-sonos-recovery.md). Those
integrations were not evidence for accepting the Lidarr workload itself. Automated
Chainsaw coverage also remains a deliberate all-`*arr` decision rather than one-off
Lidarr coverage. A synthetic metadata transaction is still deferred because it would
monitor a different external dependency than `/ping` or the authenticated native-health
API.

Revisit the inherited 1 GiB memory limit when observed metadata refreshes approach it,
and add an external-metadata monitor only when its failure signal and operating cost are
defined. Neither change requires a different storage, VPN, or torrent-lifecycle model.

Current first-run, credential, naming, and recovery procedure belongs in
`docs/guides/media-automation-setup.md`.
