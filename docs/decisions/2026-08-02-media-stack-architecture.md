# Media stack architecture

## Status

- **Status: Accepted.**
- Date: 2026-08-02

## Context

The media platform needed one GitOps-native architecture for Plex, acquisition,
automation, requests, and observability while preserving a hard VPN boundary for
downloads and efficient hardlink imports on shared storage.

## Decision

- Deploy each application as a separate single-replica workload, except that qBittorrent
  and Gluetun share one Pod and network namespace. Only qBittorrent is tunneled; Plex,
  the `*arr` applications, Seerr, Lidarr, and Tautulli use ordinary cluster networking.
- Use the repository's `kubernetes/apps/<domain>/<app>/` Flux shape and the shared pinned
  `bjw-s/app-template` source for this application family. Image tags are pinned, Flux
  dependencies are explicit, and application routes attach only to the internal Gateway.
- Use **Seerr**, the maintained successor distribution, as the household request UI. Do
  not deploy legacy Overseerr. The media/app-template domain policy enforces the
  maintained `ghcr.io/seerr-team/seerr` image so a compatible legacy image cannot
  silently replace it.
- Store application configuration on retained Longhorn single-writer claims and use
  `Recreate`. Store bulk media and downloads on one SMB-backed `media-data` claim mounted
  at `/data`; do not place bulk media on Longhorn or node-local host paths.
- Keep consistent download and library paths below `/data` so Sonarr, Radarr, and Lidarr
  import by hardlink instead of copying. Plex mounts only the library portion read-only.
- Use cluster DNS for service-to-service calls. Do not hairpin internal application
  traffic through the Gateway.
- Permit `NET_ADMIN` and `/dev/net/tun` only in the Gluetun sidecar. qBittorrent cannot
  alter routes. Other media applications run non-root with all Linux capabilities
  dropped; no workload uses host networking, host ports, or a runtime socket.
- Enforce the VPN kill switch in two layers: Gluetun readiness gates qBittorrent startup,
  and Gluetun's firewall denies non-tunnel egress during operation. Activation requires
  an independent live failure-and-recovery test that proves traffic never falls back to
  the residential path.
- Keep Gluetun's control API cluster-internal and keep all credentials SOPS-encrypted in
  per-consumer Secrets.

## Consequences

The architecture isolates VPN privilege to one Pod, supports zero-copy imports, and
keeps Git and Flux authoritative. Current first-run application configuration belongs in
[`docs/arr-stack-startup.md`](../arr-stack-startup.md); dated rollout evidence remains in
[`docs/phases/`](../phases/).
