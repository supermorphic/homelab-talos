# Media Stack Architecture

## Purpose

Define one GitOps-native architecture for media serving, acquisition, automation,
requests, analytics, and operational visibility. The design keeps download traffic
behind a fail-closed VPN, uses hardlinks instead of duplicate bulk data, and gives each
stateful application a recoverable single-writer configuration volume.

## Effective application set

The `media` namespace and its parent Kustomization contain these active units:

| Unit | Role | Persistent storage | User-facing route |
| --- | --- | --- | --- |
| `media-storage` | Static shared SMB PV and `media-data` claim | NAS-backed RWX | None |
| `plex` | Media server | Retained Longhorn config, read-only SMB library | Internal Gateway; separate direct-access exception |
| `qbittorrent` | VPN download client with Gluetun sidecar | Retained Longhorn config and shared SMB downloads | Internal Gateway |
| `qbit-manage` | Torrent classification, seeding, and cleanup policy | Generated config plus download-only SMB view | None |
| `prowlarr` | Indexer manager | Retained Longhorn config | Internal Gateway |
| `sonarr` | Television automation | Retained Longhorn config and shared SMB data | Internal Gateway |
| `radarr` | Movie automation | Retained Longhorn config and shared SMB data | Internal Gateway |
| `lidarr` | Music automation | Retained Longhorn config and shared SMB data | Internal Gateway |
| `seerr` | Household request interface | Retained Longhorn config | Internal Gateway |
| `tautulli` | Plex history and analytics | Retained Longhorn config | Internal Gateway |
| `flaresolverr` | Optional per-indexer Cloudflare solver | Stateless | ClusterIP only |
| `media-alerts` | Media Prometheus rules | None | None |
| `encode-benchmark` | Run-owned encoding evaluation Jobs | Shared media and test artifacts as defined by each Job | None |

The namespace is labeled for privileged Pod Security because Gluetun requires
`NET_ADMIN` and `/dev/net/tun`, and Plex consumes the Intel GPU device. This namespace
setting does not grant those privileges to every workload; each container still has an
explicit security context.

## Storage model and hardlink contract

Bulk downloads and libraries use one static `ReadWriteMany` SMB volume named
`media-data`. The `downloads/` and `media/` trees are siblings on that one server
filesystem. qBittorrent writes below `/data/downloads`; Sonarr, Radarr, and Lidarr import
to `/data/media/{tv,movies,music}`. Matching mount paths let the applications create
hardlinks rather than copies. Acceptance established shared inode identity and link
count two across the two names.

Plex mounts the same SMB share read-only at `/Volumes/Prometheus` because its migrated
database retains those historical paths. It uses node-local `emptyDir` for transcode
scratch. qbit_manage sees only the downloads subtree, so cleanup authority cannot write
the organized library directly.

Application databases and settings use retained Longhorn single-writer claims. Stateful
Deployments use `Recreate`; Plex uses the stronger `ReadWriteOncePod` mode for its
database, while the other application claims use `ReadWriteOnce`. Bulk media does not
use Longhorn or node-local host paths. This separation gives configuration state
replication and backup without forcing large shared files through block storage.

## qBittorrent and Gluetun network namespace

qBittorrent and Gluetun share one Pod and therefore one network namespace. Gluetun is a
native sidecar with `restartPolicy: Always`; its startup probe gates the main container
until the WireGuard tunnel and firewall are ready. Gluetun owns `NET_ADMIN`, mounts
`/dev/net/tun`, manages ProtonVPN port forwarding, and denies non-tunnel Internet egress.
qBittorrent runs as UID/GID `568`, drops all capabilities, and cannot alter routes.

The Web UI is available through the internal Gateway. Gluetun's control Service is
ClusterIP-only. Its unauthenticated health route supports Gatus, while mutating control
routes require the per-consumer API key. The control API has no HTTPRoute or
LoadBalancer.

Startup gating and the ongoing firewall are separate safety layers. Live resilience
acceptance interrupts the VPN and uses the observed public route as an independent
oracle: traffic must fail closed and must never fall back to the residential path. The
test also covers recovery and forwarded-port reacquisition.

## Application communication and routing

Service-to-service calls use cluster DNS. Internal applications do not hairpin through
the Gateway:

```text
Prowlarr -> Sonarr / Radarr / Lidarr
Seerr -> Plex / Sonarr / Radarr
Tautulli -> Plex
Sonarr / Radarr / Lidarr -> qBittorrent
qBittorrent -> shared download tree
Sonarr / Radarr / Lidarr -> shared library tree -> Plex
```

Prowlarr, Sonarr, Radarr, Lidarr, qBittorrent, Plex, Seerr, and Tautulli each have an
HTTPS route on the internal Gateway. FlareSolverr remains in-cluster only because it is
an implementation detail of selected Prowlarr indexers. Plex also has a separately
specified direct remote-access path on port `32400`; that exception does not turn the
other media routes public.

The effective Flux dependency graph is:

```text
media [cilium]
├── media-storage [media, csi-driver-smb]
│   ├── plex [media-storage, internal-gateway]
│   ├── qbittorrent [media-storage, internal-gateway]
│   ├── sonarr [media-storage, internal-gateway]
│   ├── radarr [media-storage, internal-gateway]
│   └── lidarr [media-storage, internal-gateway]
├── prowlarr [media, internal-gateway]
├── seerr [media, internal-gateway]
├── tautulli [media, internal-gateway]
├── flaresolverr [media]
├── qbit-manage [media-storage, qbittorrent]
├── encode-benchmark [media-storage, intel-gpu-plugin, qbit-manage]
└── media-alerts [kube-prometheus-stack]
```

Runtime API relationships are not encoded as Flux dependencies. A request application
can reconcile before a downstream API becomes available and report that integration
failure through health monitoring.

## Plex and Seerr choices

Plex runs as one active instance and requests `gpu.intel.com/i915: 1`. The Intel device
plugin injects `/dev/dri` and schedules Plex only on a GPU-capable node. The container
runs non-root as UID/GID `568`, drops all capabilities, and uses a 120-second termination
grace period to close its SQLite database during planned replacement. GPU scheduling
does not make Plex active-active; Longhorn reattachment and Kubernetes rescheduling
provide recovery with an expected outage.

Seerr is the request interface because it is the maintained successor to Overseerr and
Jellyseerr. The source pins `ghcr.io/seerr-team/seerr:v3.0.1`, and media policy prevents
a compatible legacy image from silently replacing it. Seerr is config-only and stores
its request database and runtime API links under `/app/config`.

Declarative automation of every application's internal database was rejected. Plex,
the `*arr` applications, Seerr, and Tautulli own runtime configuration formats and API
keys that change independently of Kubernetes manifests. Git remains authoritative for
workload shape, security, storage, routes, and encrypted integration Secrets; the
applications retain their own supported runtime settings on Longhorn.

## Security and secrets

Only Gluetun receives route-changing capability. Plex receives one GPU device resource.
The other application containers run non-root where supported, disable privilege
escalation, and drop all capabilities. No media workload uses host networking, a host
port, a container-runtime socket, or a public Gateway.

SMB, VPN, widget, and integration credentials use SOPS-encrypted per-consumer Secrets.
Sharing an upstream credential does not imply sharing one Kubernetes Secret across
unrelated consumers. Plex's Cilium policy restricts ingress and egress around its
implemented client and direct-access paths; specialized Plex exposure and detection
decisions remain separate specifications.

## Observability and validation

Homepage discovers the user-facing applications and injects independently rotatable
widget credentials. Gatus checks every active user-facing media service, the
cluster-internal FlareSolverr service, and the Gluetun VPN state. Authenticated Gatus
checks also cover native `*arr` health and Seerr's reads of Sonarr and Radarr.

Prometheus rules cover sustained Media endpoint failure, missing probe series, important
PVCs, integration-health failures, qBittorrent VPN loss and Gluetun restart loops, and
the separately designed Plex direct-access signals. The isolated `media-alerts`
Kustomization keeps Prometheus Operator CRD ordering out of application reconciliation.

Offline checks validate source, rendered charts, storage and security invariants, route
wiring, dependency order, network-policy shape, and Prometheus rule behavior. Read-only
verifiers check the deployed resources and endpoints. Controlled integration and
resilience tests supply independent evidence for hardlinks, GPU use, VPN fail-closed
behavior, recovery, and full request-to-library workflows.

## Consequences

The design localizes VPN privilege, keeps bulk data on one hardlink-capable filesystem,
and makes configuration recovery independent of the NAS media path. Each stateful
application remains single-active, so failover includes an outage while its Longhorn
claim reattaches. External metadata providers, trackers, the NAS, and the VPN provider
remain real dependencies that a healthy Kubernetes Deployment cannot eliminate.

Current application configuration belongs in `docs/guides/media-automation-setup.md`.
VPN credential and operating procedure belongs in
`docs/guides/qbittorrent-vpn-operations.md`.
