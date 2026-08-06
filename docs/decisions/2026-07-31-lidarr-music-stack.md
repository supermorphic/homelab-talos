# Lidarr music automation

## Status

- **Status: Accepted.**
- Date: 2026-07-31

## Context

The media platform needed greenfield music automation consistent with the existing
Prowlarr, Radarr, Sonarr, qBittorrent, qbit_manage, Homepage, and Gatus architecture.
There was no prior music library or configuration database to migrate.

## Decision

- Deploy Lidarr as a first-class `*arr` application and structural peer of Radarr. It
  runs in the `media` namespace as a single `Recreate` Deployment with a retained
  Longhorn ReadWriteOnce config claim.
- Mount the shared `media-data` SMB claim at `/data`. Downloads use
  `/data/downloads/music`; the library uses `/data/media/music`; imports remain on one
  filesystem and use hardlinks rather than copies.
- Keep Lidarr outside the Gluetun network namespace. It reaches Prowlarr and qBittorrent
  through cluster DNS; only qBittorrent traffic uses the VPN.
- Pin the application image and enforce the repository's non-root, drop-all-capabilities,
  internal-Gateway, config-retention, resource, probe, and Flux-dependency conventions.
- Prefer FLAC/lossless releases while allowing lossy fallback. A lossless-only policy is
  rejected because it would create avoidable library gaps.
- Use Plex-compatible music naming without a release year in album directories.
- Create a dedicated qbit_manage `music` share-limit group because music seeding policy
  differs materially from movies and television.
- Validate share limits in two layers: structural validation for every group plus
  cross-group priority and overlap invariants. Pairwise assertions are insufficient once
  a third group exists.
- Use a table-driven shared `*arr` validator and verifier instead of a Lidarr-specific
  copy.
- Add the Homepage widget and Gatus endpoint only after first-run setup produces the API
  key. Keep the key SOPS-encrypted and isolated to its consumer.
- Do not add a Lidarr-specific Chainsaw smoke test. The shared verifier covers the same
  readiness and routing contract as the other `*arr` applications.

## Operational invariants

- Lidarr writes metadata only to its configuration database; writing metadata into audio
  files is disabled because hardlinked seeded content must remain byte-identical.
- The qBittorrent music category saves to `/data/downloads/music`, and Lidarr imports to
  `/data/media/music` with completed-download handling and hardlinks enabled.
- One accepted import must demonstrate matching inode identity between download and
  library paths and a successful qBittorrent recheck. This is functional acceptance,
  distinct from HTTP liveness.

## Consequences

Lidarr follows the established media application model without widening VPN privilege or
copying data during import. qbit_manage treats music deliberately rather than inheriting
movie/TV assumptions. The architecture was implemented by PRs #172 and #174; current
first-run and recovery procedure lives in
[`docs/arr-stack-startup.md`](../arr-stack-startup.md).
