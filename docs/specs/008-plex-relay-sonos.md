# Plex Relay and Sonos Integration

## Purpose

Retain Plex Relay as a limited fallback path and define the workload controls needed
whether remote traffic arrives through Relay or through direct remote access. Relay is
not the primary remote path: its 2 Mbps ceiling and incomplete client support could not
satisfy the full Sonos objective. The direct path is specified separately.

## Relay fallback

Plex Media Server initiates the Relay connection over outbound TCP `443`. Two encrypted
connections meet at Plex's relay service, and the local relay process forwards traffic
to Plex on pod loopback port `32401`. This requires no router mapping and leaves the
Plex-owned relay key cache writable under `/config`.

Relay remains enabled because it can preserve limited access when the direct path is
unavailable. It has important limits:

- streams are capped at 2 Mbps and high-bitrate content may be transcoded;
- downloads do not work through Relay;
- some Plex clients and integrations do not support it completely; and
- successful Relay transport does not prove Sonos account linking, player discovery,
  or local speaker reachability.

Relay is therefore a fallback, not an alternative source of high-bitrate remote access.

## Runtime identity repair

Plex runs as numeric UID and GID `568`, but the container image's original
`/etc/passwd` did not define that UID. The main server tolerated the missing identity;
the bundled Relay child exited because it could not resolve its current user.

An unprivileged init container based on the same pinned Plex image now:

1. copies the image's `/etc/passwd` to a dedicated `emptyDir`;
2. appends `plex:x:568:568:Plex Media Server:/config:/usr/sbin/nologin` only when UID
   `568` is absent;
3. verifies that the resulting file resolves UID `568`; and
4. sets mode `0644`.

The application mounts that one generated file read-only at `/etc/passwd` with a
`subPath`. The design does not replace `/etc/group`, mutate the image, mount a raw Relay
host key, change storage ownership, or grant extra privilege. The native Relay cache
remains under `/config` because Plex owns its format and rotation.

The repair was validated by Relay authentication and remote-port allocation, followed
by Plexamp music playback over cellular. Keeping UID/GID `568` also preserves the
validated config-volume, SMB, Longhorn, and Intel GPU ownership model.

## Sonos boundaries

Three separate paths must not be treated as one result:

- off-site Plex library access tests server reachability;
- the Plex service inside the native Sonos app is cloud-mediated and needs a usable
  route from the Sonos service to Plex; and
- controlling Sonos from Plexamp requires Plex Pass, a full Plex account, Sonos account
  authorization, and initial linking from a supported Plex client on the Sonos local
  network.

Routed connectivity between the Main and Sonos VLANs does not replace the same-network
linking requirement. A missing player does not justify broad multicast reflection or an
any-to-any VLAN rule. First complete supported account linking, then capture the exact
flows if normal cross-VLAN control still fails.

Plex emits SSDP/UPnP discovery to `239.255.255.250:1900`. The network policy
deliberately blocks it. This prevents Plex from discovering a router and creating its
own WAN mapping if router-side UPnP is accidentally enabled. Plex DLNA discovery cannot
work through this block; the supported Plex-for-Sonos path does not depend on SSDP.

## Workload and storage hardening

The Plex pod keeps these controls:

- one `Recreate` Deployment with a retained `ReadWriteOncePod` config claim;
- `runAsNonRoot: true`, UID/GID `568`, and `RuntimeDefault` seccomp;
- no privilege escalation and all Linux capabilities dropped in every container;
- no service-account token automount;
- a pinned image tag and digest;
- `/config` as the persistent writable application surface;
- `/transcode` and the generated passwd file on separate `emptyDir` volumes; and
- the shared media library mounted read-only at `/Volumes/Prometheus`.

Read-only media leaves Lidarr, Sonarr, and Radarr as the file-management authorities and
reduces both accidental deletion and ransomware impact after a Plex compromise. A
read-only root filesystem remains unclaimed because the image's complete runtime write
set has not been established.

## Network containment

The Plex `CiliumNetworkPolicy` selects only the Plex workload. Ingress on TCP `32400`
is admitted from the internal Envoy Gateway, Homepage, Tautulli, Seerr, Sonarr, Radarr,
Lidarr, and host or remote-node identities used by probes. The current direct-access
design adds `world` on the same port and no other ingress port.

The application may reach cluster DNS over TCP and UDP `53`. Its other egress is limited
to public IPv4 TCP `443` and `32400`, with private, shared, loopback, link-local,
documentation, multicast, and reserved ranges excluded. TCP `443` supports Plex account,
metadata, pubsub, and Relay traffic. TCP `32400` is required for Plex's self-check of its
own published `plex.direct` address. The CSI driver mounts SMB on the node, so the pod
does not need SMB egress.

Observed traffic established the internal Gateway, Tautulli, and host paths. Exact
application contracts supply the event-driven consumers that can be silent during a
capture: Homepage, Seerr, Sonarr, Radarr, and Lidarr. A capture that sees no import event
must not remove those declared consumers. Policy verification covers required positive
paths and denied cluster, LAN, multicast, and Kubernetes API paths.

## Public-port trust boundary

![Plex public-port trust boundaries](images/plex-remote-access-trust-boundaries.png)

Editable source:
[plex-remote-access-trust-boundaries.svg](images/plex-remote-access-trust-boundaries.svg).

A single DNAT does not expose every VLAN or the Kubernetes API by itself. It does expose
Plex's parser and API continuously. Code execution in Plex inherits process memory, the
writable config claim, read-only media, the GPU device, and every route that policy
permits. Broader node or VLAN impact requires another policy failure, credential, or
container, kernel, runtime, or GPU escape. The workload controls reduce that path but do
not make public Plex risk-free.

## Rejected tunnel alternatives

Private Tailscale access is useful for operator-owned clients but cannot serve Plex's or
Sonos's cloud service because those services are not tailnet members. Tailscale Funnel
would be public, was bandwidth-limited, constrained names and ports, and did not remove
the client-compatibility question.

Cloudflare Tunnel avoids inbound router DNAT and hides the origin address, but the
published hostname remains Internet-reachable. Cloudflare Access requires client
headers or cookies that Plexamp, Plex's Sonos integration, and Sonos speakers cannot
supply. Proxying a mixed-media Plex server also requires a current Cloudflare service
and policy review. A VPS reverse tunnel was rejected because it adds another public
host, credential, patching, bandwidth, and compromise boundary.

## Consequences

The identity repair and workload hardening remain useful under every remote-access
mechanism. Relay supplies a low-capability recovery path without another ingress rule,
but direct access remains necessary for the validated Sonos and high-bitrate behavior.
The direct path and its detection design are recorded in
[specification 013](013-plex-direct-remote-access.md) and
[specification 014](014-plex-remote-access-detection.md).
