# Lidarr Music Stack

## Intent

Lidarr adds music automation to the shared media platform: Prowlarr supplies releases,
qBittorrent downloads, Lidarr imports, and Plex serves the organized library. It follows
[the media architecture](006-media-stack-architecture.md) rather than introducing a
separate storage or VPN model. Workload and monitoring details belong to
[its source](../../kubernetes/apps/media/lidarr/).

## Music and torrent contract

Downloads and imports share the SMB filesystem, so imports must create hardlinks.
Lidarr must never rewrite audio metadata while the torrent remains active: both names
refer to the same inode, and in-place tag writes can invalidate seeded pieces. Keep
**Tag Audio Files with Metadata** at `Never` and tag scrubbing disabled.

The quality policy prefers lossless releases with a high-quality lossy fallback; a
lossless-only policy would create unnecessary library gaps. Naming must remain
Plex-compatible: `Artist/Album/DiscTrack - Title.ext`, no year in album folders, and one
album directory for multiple discs. Compilations use `Various Artists` as album artist
and the performer as track artist. Confirm naming previews before saving runtime settings.
Monitor only deliberately selected albums rather than an artist's full discography.

qbit_manage owns successful-torrent seeding and cleanup. Music seeds longer than public
TV and movies; this costs torrent state rather than a second bulk copy after hardlink
import. Private-group precedence and cleanup exclusions are independent safeguards,
as described in [specification 006](006-media-stack-architecture.md#torrent-lifecycle).
Lidarr retains ordinary cluster networking and receives no Gluetun route authority.

## Empty-state acceptance

Use the guarded suspended-source bootstrap lifecycle in
[specification 006](006-media-stack-architecture.md#application-state-recovery).
Before durably activating an empty Lidarr configuration claim:

1. Require authenticated login, a writable music root on the NAS, conservative album
   monitoring, accepted naming previews, hardlinks enabled, and metadata writes disabled.
2. Connect Prowlarr and qBittorrent through their internal Services; create Lidarr's
   independently managed Homepage credential through the existing operator SOPS writer.
3. Search for a real artist and load album metadata. `/ping` and the authenticated health
   API do not exercise the external metadata service.
4. Import one authorized album through qBittorrent's music category. Using a trusted
   NAS-side interface, require the download and library track to have the same inode
   and link count two. The synthetic media-hardlink test alone cannot prove this import.
5. Force recheck the torrent in qBittorrent and require no hash error. Stop if any gate
   fails; leave the source suspended until correction and acceptance.

After those gates, activate through Git and rerun `mise exec -- just kube arr-verify lidarr`.
Only then create Plex Music at `/Volumes/Prometheus/media/music` and perform its initial
scan. Add the native Lidarr-to-Plex connection, test it, then require a second authorized
import or rename to refresh Music without another manual scan. Connector path-map fields
remain blank; metadata writing stays disabled. Plexamp/Sonos account linking belongs to
[specification 008](008-plex-relay-sonos.md).
