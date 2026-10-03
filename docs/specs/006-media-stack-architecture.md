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
| `mylar3` | Comic acquisition (live acceptance pending) | Retained Longhorn config and shared SMB data | Internal Gateway |
| `komga` | Comic reading (live acceptance pending) | Retained Longhorn state and read-only SMB comics | Internal Gateway |
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

The SMB CSI driver runs one controller Deployment and a Linux node DaemonSet.
Its Helm values disable the chart's default Windows DaemonSet because all cluster
nodes run Talos Linux. The source validator checks the rendered workloads to retain
the controller and Linux plugin while excluding the unused Windows component.

Bulk downloads and libraries use one static `ReadWriteMany` SMB volume named
`media-data`. The `downloads/` and `media/` trees are siblings on that one server
filesystem. qBittorrent writes below `/data/downloads`; Sonarr, Radarr, and Lidarr import
to `/data/media/{tv,movies,music}`. Matching mount paths let the applications create
hardlinks rather than copies. Acceptance established shared inode identity and link
count two across the two names.

The media-data PV requests `nolease` in addition to its established mount options.
The change is a candidate for intermittent Plex `Invalid argument` failures when
qBittorrent keeps a download file open and Plex opens the hardlinked library name.
The registered media-hardlink test now checks both concurrent-open orders using the
actual application containers. The original inode-only result did not test this case.
The live baseline and post-remount result remain unverified; the SMB protocol response
was not captured. `nolease` removes client lease requests and related caching, so
representative playback and NAS throughput must be checked during rollout. The
PV edits do not change existing mounts: an operator must coordinate a mount cycle on
every consuming node before evaluating the mitigation.

Plex mounts the same SMB share read-only at `/Volumes/Prometheus` because its migrated
database retains those historical paths. It uses node-local `emptyDir` for transcode
scratch. qbit_manage sees only the downloads subtree, so cleanup authority cannot write
the organized library directly.

Application databases and settings use retained Longhorn single-writer claims. Stateful
Deployments use `Recreate`; Plex uses the stronger `ReadWriteOncePod` mode for its
database, while the other application claims use `ReadWriteOnce`. Bulk media does not
use Longhorn or node-local host paths. This separation gives configuration state
replication and backup without forcing large shared files through block storage.

The alternatives fail different requirements. Separate download and library shares
would make hardlinks impossible and double data during import. Longhorn would turn the
large shared library into replicated block storage, while node-local host paths would
bind the library to one worker. Multiple active replicas were rejected because these
applications use single-writer databases and do not supply an active-active state model.
The static SMB volume accepts NAS availability as an external dependency in exchange for
one shared, hardlink-capable filesystem.

The hardlink contract was proven rather than inferred from matching paths: a guarded
test created download and library names that reported the same inode with link count
two. Plex recovery supplied a separate result. A planned replacement could close the
database cleanly, while a hard node failure required Longhorn's node-down pod-deletion
policy before the old `ReadWriteOncePod` attachment stopped blocking replacement. The
observed hard-node recovery time was approximately eight minutes, fully automatic. The
default 300-second unreachable toleration dominated that result; Longhorn force-deleted
the stuck pod after approximately 235 seconds before the replacement attached the
surviving replica. If faster recovery becomes necessary, lowering the Plex pod's
unreachable toleration and repeating the hard-node gate is the evidence-based lever.
That result did not prove a Longhorn restore, a complete NAS outage, or service through
loss of one volume replica.

## qBittorrent and Gluetun network namespace

qBittorrent and Gluetun share one Pod and therefore one network namespace. Gluetun is a
native sidecar with `restartPolicy: Always`; its startup probe gates the main container
until the WireGuard tunnel and firewall are ready. Gluetun owns `NET_ADMIN`, mounts
`/dev/net/tun`, manages ProtonVPN port forwarding, and denies non-tunnel Internet egress.
qBittorrent runs as UID/GID `568`, drops all capabilities, and cannot alter routes.

Inside that shared namespace, qBittorrent intentionally resolves through Gluetun's
resolver rather than node or ISP DNS. The resilience evidence combined that structural
resolver boundary with DNS-independent IP reachability probes and the observed home-WAN
address as a hard never-leak oracle. This separation matters because DNS failure alone
does not prove that Internet egress failed closed.

The Web UI is available through the internal Gateway. Gluetun's control Service is
ClusterIP-only. Its unauthenticated health route supports Gatus, while mutating control
routes require the per-consumer API key. The control API has no HTTPRoute or
LoadBalancer.

Startup gating and the ongoing firewall are separate safety layers. Live resilience
acceptance interrupts the VPN and uses the observed public route as an independent
oracle: traffic must fail closed and must never fall back to the residential path. The
test also covers recovery and forwarded-port reacquisition.

The live test measured from qBittorrent's own network namespace, not from Gluetun, and
used both name-independent IP reachability and the observed exit path. It established
that a stopped or interrupted tunnel produced no fallback egress and that a newly
created Pod reacquired the tunnel and forwarded port. It also found a bounded recovery
gap: Gluetun could restore data-plane egress while its DNS health loop and port-forward
state remained unhealthy. Pod recreation was the known clean recovery. The current slow
container liveness fallback detects that partial state, but whether a same-namespace
container restart always clears it remains unproven.

## Application communication and routing

Service-to-service calls use cluster DNS. Internal applications do not hairpin through
the Gateway:

```text
Prowlarr -> Sonarr / Radarr / Lidarr
Prowlarr -> Mylar3 -> qBittorrent -> shared comic downloads
Mylar3 -> shared comic library -> Komga -> native private HTTPS reader
Seerr -> Plex / Sonarr / Radarr
Tautulli -> Plex
Sonarr / Radarr / Lidarr -> qBittorrent
qBittorrent -> shared download tree
Sonarr / Radarr / Lidarr -> shared library tree -> Plex
```

Prowlarr, Sonarr, Radarr, Lidarr, Mylar3, Komga, qBittorrent, Plex, Seerr, and Tautulli
each have an HTTPS route on the internal Gateway. FlareSolverr remains in-cluster only because it is
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
│   ├── lidarr [media-storage, internal-gateway]
│   ├── mylar3 [media-storage, internal-gateway]
│   └── komga [media-storage, internal-gateway]
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

Patching SQLite databases or other application internals from Git was not treated as
configuration management: it would couple reconciliation to private schemas and could
race the application's writer. Supported application APIs and attended first-run state
therefore remain the integration boundary. Seerr was selected as the maintained
successor to the older request interfaces, and the optional FlareSolverr unit remains a
direct-egress, per-indexer helper rather than a namespace-wide proxy or VPN consumer.
It follows Prowlarr's direct egress because a Cloudflare-protected indexer session depends
on the solver and Prowlarr presenting the same effective egress identity; routing the
solver independently through the VPN can invalidate that session.

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
behavior, and recovery. Functional acceptance was deliberately split into two levels: a
direct Sonarr/Radarr to qBittorrent, hardlink-import, and Plex gate was defined to prove
the acquisition path without Seerr; the household request gate then added Seerr ahead of
the same pipeline. Keeping those gates separate prevents a request-layer integration
failure from obscuring whether acquisition and import work. The source and live verifiers
establish component paths but do not submit media requests. The current operator
acceptance gate remains one authorized TV request and one movie request through Seerr,
their expected Sonarr or Radarr service and qBittorrent category, import into Plex, and
accepted media naming. No durable record yet proves that both request-to-library paths
completed.

## Mylar3 comic acquisition

Mylar3 extends the existing Prowlarr/qBittorrent acquisition path. It owns comic
organization and post-processing beneath `/data/media/comics`; Komga owns reading.
The [application source](../../kubernetes/apps/media/mylar3/app/values.yaml)
owns the pinned LinuxServer image, resources, retained Longhorn config and shared
`/data` mount. A single `Recreate` writer preserves the config database. Resource
values start from comparable managers and require idle/import measurements after
rollout. Longhorn config backup and NAS library backup remain separate.

The upstream image initializes as root, then runs Mylar as the shared media UID.
Its ownership and UID/GID capabilities support initialization; `KILL` lets the root
supervisor stop its unprivileged child. The pod has no Kubernetes API token or
VPN/network-administration capability. Using the upstream entrypoint avoids a
custom image or replacement startup script. Container startup under these reduced
capabilities remains a live acceptance gate.

### Attended setup and completion handoff

Flux deploys Mylar through Git after storage and the internal Gateway are ready.
This service uses direct Git activation; the existing `arr` bootstrap recipe does
not support Mylar. Before enabling acquisition, open its private route from the
[HTTPRoute source](../../kubernetes/apps/media/mylar3/app/httproute.yaml), set unique
credentials and select **Forms** authentication. Keep the base URL empty and
in-application updates disabled. The login endpoint must return HTTP 200 without
credentials. Basic authentication blocks the declared probes. Homepage discovers
the application link and its native `mylar` widget, displaying all supported fields:
`series`, `issues` and `wanted`. Gatus and `MediaEndpointDown` measure login
availability, not acquisition health.

Enter the operator's ComicVine API key privately and verify a series lookup.
Enable Mylar's API and use its generated key in Prowlarr's native **Mylar**
application. These supported runtime settings persist beneath `/config/mylar`,
including qBittorrent credentials. Homepage uses the Mylar API key through its
own `homepage-mylar3` SOPS Secret in the `homepage` namespace. Keep the key out of
discovery annotations, plaintext Git and OpenBao. Do not reconcile the live
config/database from an init script or ConfigMap.

With Mylar's API enabled, the operator privately exports `MYLAR3_API_KEY` and
loads their existing age identity. Set
`HOMEPAGE_MYLAR3_SECRETS_CONFIRM=write:monitoring:homepage-mylar3:sops`, then run
`mise exec -- just repo homepage-mylar3-secrets`. The recipe creates the encrypted
Secret, registers it in Homepage's Kustomization and stamps its encrypted revision
in the Homepage pod template. Commit those three files together through a PR.
The same recipe rotates the key and refreshes Homepage's environment through Flux.
The Secret reference is optional and its resource is absent until the operator
creates it, so Homepage can start during setup. Widget values require that Secret
and successful calls to Mylar's private Service on port 8090. Source validation
does not establish authenticated widget data. The widget settings follow the
[Homepage Mylar documentation](https://gethomepage.dev/widgets/services/mylar/).

Create the comic download and library directories through the existing NAS
management path if absent; require write access as UID/GID 568 without recursive
ownership changes to the existing library. Set the following cross-system values:

| Setting | Value |
| --- | --- |
| Mylar Comic Location | `/data/media/comics` |
| qBittorrent category and Mylar label | `comics` |
| Category save path and Mylar qBittorrent folder | `/data/downloads/comics` |
| Mylar qBittorrent host | `http://qbittorrent.media.svc.cluster.local:8080` |
| Mylar download client credential | Existing qBittorrent application credential |
| When Post-Processing | `hardlink` |
| Enforce Permissions | Disabled for SMB |
| Embedded metadata tagging/archive conversion | Disabled for seeded files |
| Enable Folder Monitoring | Enabled |
| Folder location to monitor | `/data/downloads/comics` |
| Folder Monitor Scan Interval | Five minutes |
| Prowlarr Server in the Mylar application | `http://prowlarr.media.svc.cluster.local:9696` |
| Application Server in Prowlarr | `http://mylar3.media.svc.cluster.local:8090` |
| Prowlarr sync | Full Sync, approved torrent indexers and their comic categories |

Enable torrents, torrent searching, post-processing and the qBittorrent client.
Test the client, then test/save/synchronize Prowlarr's Mylar application. Restrict
indexers using existing Prowlarr tags when needed and confirm enabled Torznab
providers appear in Mylar. Use supported comic categories (normally 7030). No remote
path mappings or duplicate provider registry are needed.

The reviewed Mylar client submits torrents to qBittorrent but does not poll its
completion API. [Upstream supports scheduled folder monitoring](https://github.com/mylar3/mylar3/wiki/Torrents%2C-Newsgroups-and-DDL)
for completed torrents. Before enabling it, require qBittorrent's **Keep incomplete
torrents in** setting at `/data/downloads/incomplete`, outside the monitored tree.
Both directories are on the same filesystem; qBittorrent must move completed files
into the comics directory. No incomplete archive may appear there. Stop if this
precondition fails; a longer scan delay is not a substitute. Monitor only the
completed-comics directory, never the download root, incomplete tree or library.

Enable renaming and inspect its preview for series/year/issue organization.
Preserve native CBZ/CBR files and optionally Mylar's `series.json` metadata for
reader interoperability. Upstream disables embedded tagging in hardlink mode;
conversion or metadata rewriting of a seeded inode would invalidate torrent
hashes. Mylar can fall back to copying on `EXDEV`, so matching mount paths alone
do not prove hardlinks. The `comics` category remains outside qbit_manage's public
cleanup groups; generic tracker tagging and existing private-tracker rules still
apply. Automatic comic cleanup needs separate import-survival acceptance.

### Acceptance and recovery

After deployment, run `mise exec -- just kube mylar3-verify` with task-scoped observer
credentials obtained through `mise exec -- just kube kubeconfig`. It checks resource
readiness, claims, the source image, private route/DNS and login availability.
Retain this deployment evidence with `mise exec -- just test record verification.mylar3`
from the clean deployed commit. Neither that result nor the generic media-hardlink
test proves the acquisition gates below.

Live acceptance remains pending and separately authorized. Privately identify a
public-domain or otherwise operator-authorized fixture available through an
approved indexer and agree its cleanup scope before downloading:

1. Record existing Sonarr/Radarr/Lidarr/qBittorrent health. Find the fixture through
   the synchronized provider, put the matching issue on Mylar's wanted list and
   request the approved release in Mylar.
2. Observe category `comics` and the existing VPN path. While incomplete, require
   its data to remain in the separate incomplete tree with no Mylar import.
3. Wait for completion, the move into the comics directory, and scheduled import
   without a manual post-processing trigger. Require downloaded status and accepted
   library naming. A second scan must not duplicate/corrupt the issue or its source.
4. Through separately authorized inspection, require equal download/library inode
   identity and link count at least two. Force Recheck only the fixture torrent and
   require 100% success after import; open the archive in a comic reader.
5. Under authorized recovery testing, replace/reschedule the Mylar pod and require
   preserved database, login, integrations and paths. Confirm config/NAS backup
   coverage; pod replacement is not evidence of backup restoration.
6. Measure idle/import resource use and adjust Git requests/limit if warranted.
   Recheck other media health, categories and seeding behavior. Clean up only
   authorized fixture resources; verify library survival before removing its
   download-side name when that removal is authorized.

The registered `test.mylar3-acceptance` suite checks an already imported fixture's
hardlink identity, archive integrity and Downloaded database record, then replaces
the Mylar pod and repeats those checks against the retained config volume. It does
not acquire a release or prove scheduled import, client recheck, reader rendering,
login/integration preservation, or backup restoration; those gates remain attended.

Supply `MYLAR_ACCEPTANCE_FIXTURE` as the path to a private JSON object containing
`download_path`, `library_path` and a string `issue_id`. Both paths must identify the
same imported comic under the comics download and library roots. For an independent
integrity check without pod replacement, bootstrap scoped credentials with
`mise exec -- just kube kubeconfig`, then run
`mise exec -- just test record test.mylar3-integrity`. Keep the observer current
context required by recording; the suite selects diagnostic access explicitly.
It checks both files and the database read-only, retaining only
sanitized results. The fixture is supplied explicitly and is not part of the
general verification campaign.

Use the registered replacement suite through
`mise exec -- just test record test.mylar3-acceptance` with
`MYLAR_ACCEPTANCE_CONFIRM=test:mylar3-acceptance` and an explicitly authorized
`KUBECONFIG`. Recording passes that credential to the suite as `TEST_KUBECONFIG`.
This attended mutation requires pod exec/delete, the test Lease,
and deployment, storage and Node inspection; observer credentials are insufficient.
Run it from an execution context permitted by the recording workflow. The suite
preserves the fixture and claims and retains only sanitized integrity outcomes.
Do not publish comic payloads, titles, hashes, tracker URLs, credentials or runtime
config exports. Issue 526 remains open until its live gates and canonical evidence
requirements pass.

Preserve the retained config claim during replacement. For lost state, restore a
trusted Longhorn backup through the operator-run storage recovery procedure in
[the platform spec](010-talos-flux-platform.md), and restore comics through NAS
recovery. An empty config needs the attended setup above again. Keep the source
image pinned during recovery and verify login/resources before retrying acquisition.

Upstream implementation references:
[container startup](https://github.com/linuxserver/docker-mylar3/tree/v0.11.0-ls274/root/etc/s6-overlay/s6-rc.d),
[hardlink operations](https://github.com/MylarComics/mylar3/blob/v0.11.0/mylar/helpers.py),
[metadata behavior](https://github.com/MylarComics/mylar3/blob/v0.11.0/mylar/config.py),
[authentication routes](https://github.com/MylarComics/mylar3/blob/v0.11.0/mylar/webstart.py),
and [Prowlarr integration](https://github.com/Prowlarr/Prowlarr/tree/develop/src/NzbDrone.Core/Applications/Mylar).

## Komga comic reading

Komga serves the Mylar library to private clients. The
[application source](../../kubernetes/apps/media/komga/app/values.yaml) pins the
upstream image and owns resources, probes and storage. One non-root `Recreate`
writer keeps databases, accounts, collections, progress and thumbnails under
`/config` on a retained Longhorn claim. Its filesystem satisfies the upstream
[local database requirement](https://komga.org/docs/installation/configuration/).
Only the `media/comics` subtree of `media-data` is mounted, read-only, at
`/data/media/comics`. Mylar retains acquisition and file-organization ownership.
Writable library access, a second storage root and a custom conversion image are
unnecessary for indexing and reading. Temporary extraction uses disposable `/tmp`.

The internal Gateway terminates trusted HTTPS at the
[declared route](../../kubernetes/apps/media/komga/app/httproute.yaml). Clients use
the approved LAN or Tailscale subnet path and private DNS with normal certificate
verification. Komga has no public Gateway attachment or public DNS registration.
Homepage discovers its link and native Komga library counters. Gatus checks the
upstream unauthenticated `/actuator/health` response and the existing `MediaEndpointDown` rule covers
availability. These checks do not establish indexing or reading progress.

### Attended setup and native clients

After the reviewed deployment reaches main, confirm Mylar's comic directory exists
through the established NAS management path and is readable by the shared media
UID. Do not create another share or recursively change ownership. Open private
HTTPS and create the initial administrator using Komga's first-run interface.
Create a separate reading account with access to the comic library and the
stream/download permissions needed by the chosen client. Accounts and generated
API keys stay in the durable application database. Homepage's integration key is
stored separately in its SOPS-managed `homepage-komga` Secret, never OpenBao or
plaintext annotations. The [native widget](https://gethomepage.dev/widgets/services/komga/)
uses an API key from an account allowed to view the comic library; a dedicated
non-administrator account is sufficient. Its counts reflect that account's access.
The current list endpoints are selected by the widget version in the route source.

Generate the Homepage key in Komga account settings. With the existing operator-held
age identity loaded, privately export `KOMGA_API_KEY`, set
`HOMEPAGE_KOMGA_SECRETS_CONFIRM=write:monitoring:homepage-komga:sops`, and run
`mise exec -- just repo homepage-komga-secrets`. The command writes the encrypted
Secret, registers it in Homepage's Kustomization and stamps its pod revision.
Commit those three outputs together through a PR for setup or key rotation.
Flux then reloads the credential through a Homepage rollout. Validate actual
widget counts after deployment; source checks do not prove authenticated access.

Add one library rooted at `/data/media/comics`. In
[library options](https://komga.org/docs/guides/libraries/), enable scanning on
startup and an hourly scan. Disable automatic extension repair and CBR-to-CBZ
conversion; do not use imports, file deletion or other file-management actions.
Leave automatic trash emptying disabled so a temporarily unavailable NAS does
not immediately discard server metadata. Enable available
[ComicInfo.xml and Mylar series.json metadata imports](https://komga.org/docs/guides/scan-analysis-refresh/).
Native CBZ/CBR content and embedded metadata are consumed as supplied. Do not
rewrite seeded archives to improve metadata; coordinate acquisition-side changes
with Mylar's contract above.

Prefer [Kasane's native Komga connection](https://komga.org/docs/guides/kasane/)
for server reading-progress integration. Use the private HTTPS base URL and a
reading-account API key or its credentials. For
[Panels](https://komga.org/docs/guides/panels/), use its OPDS service with the same
HTTPS host and reading-account credentials; OPDS support may require an attended
purchase. The explicit OPDS v1 catalog is `/opds/v1.2/catalog`; Komga also offers
`/opds/v2/catalog`. Leave a reverse-proxy port field empty rather than using the
backend port. Generic OPDS connectivity does not prove progress synchronization:
[Panels' guide](https://guides.panels.app/opds/connecting-a-server) distinguishes
streaming and imports and reports a streaming continue-reading limitation.
Record the installed client version, connection type and observed progress
behavior during acceptance. Device installation and subscriptions stay attended.

### Acceptance and recovery

Run `mise exec -- just kube kubeconfig` in the assigned linked worktree, then
`mise exec -- just kube komga-verify` for observational readiness, claims,
read-only mount, image and private DNS/TLS checks. Retain deployment evidence
from the clean deployed commit with
`mise exec -- just test record verification.komga`. A passing result does not
complete issue 527; native and integrated acceptance remain pending:

1. Using operator-authorized content from Mylar's library, scan representative
   CBZ and CBR archives. Require readable pages, expected counts and supplied
   ComicInfo.xml or series.json metadata. A repeat scan must preserve book identity
   and progress without modifying the archives. Inspect analysis errors privately.
2. From the iPad's intended private network, browse, open and read a comic in
   Kasane or Panels without manual transfer or a TLS exception. Verify streaming
   and/or offline download according to the selected workflow, then close and
   reopen the client. Compare progress with the Komga web reader where the client
   supports server synchronization; distinguish local resume from server progress.
3. Under separately authorized recovery testing, record a reading-account login,
   collection and progress marker, replace/reschedule the pod while preserving its
   claim, and require those states to survive. Do not infer durability from a
   healthy empty installation. Measure idle and scanning CPU/memory and adjust
   the provisional resource settings in Git before accepting capacity.
4. Confirm the config volume participates in Longhorn's existing default snapshot
   and backup group and has a successful backup. Bulk comics remain under NAS
   protection. Pod replacement is not backup-restore evidence.
5. Complete the Mylar-to-library-to-client flow after issue 526's acquisition
   acceptance. Record only sanitized outcomes; no titles, comic payloads, account
   data, tokens or private library paths beyond the shared contract belong in
   public evidence.

There is no registered automated comic/client or Komga rescheduling test yet.
Keep attended outcomes private until a scoped fixture and execution contract can
be registered in the existing test catalog and retained through `just test record`.
Offline validation and this observational verifier cannot substitute for those
gates.

For recovery, retain the healthy config claim. If it is lost, use the
[platform storage recovery procedure](010-talos-flux-platform.md) to restore a
trusted Longhorn backup to a new claim and validate it in isolation before Git
cutover. Restore the NAS comic directory separately at the same path. Keep the
image pinned during recovery and verify accounts, collections, progress and
library access before resuming client use. Do not delete/recreate the library or
empty its trash during a NAS outage. An empty config requires the attended setup
again and cannot recover previous user state by scanning comics alone.

## Deferred work and reconsideration

The original acceptance did not complete a throwaway Longhorn restore, a full NAS-outage
exercise, or the one-replica-loss case for Plex. Those remain evidence gaps, not claims
that recovery would fail. Resource values for the media managers and request service are
inherited starting points; change them when measured scans, history growth, or request
load justify it. Revisit runtime configuration automation only when an application
offers a supported, idempotent interface with safe credential and rollback behavior.

Optional dashboards and deeper continuous transactions do not change the architecture.
The notification delivery spine belongs to the ntfy design, integration-health depth to
specifications 018–019, and Plex direct exposure and detection to specifications 013 and
014. Those later lineages must not be inferred from this common storage and application
design.

## Consequences

The design localizes VPN privilege, keeps bulk data on one hardlink-capable filesystem,
and makes configuration recovery independent of the NAS media path. Each stateful
application remains single-active, so failover includes an outage while its Longhorn
claim reattaches. External metadata providers, trackers, the NAS, and the VPN provider
remain real dependencies that a healthy Kubernetes Deployment cannot eliminate.

Source and supported application settings own current configuration; independent recovery
is described below.
VPN credential and operating procedure belongs in
`docs/specs/006-media-stack-architecture.md`.

## qbit_manage containment and mistaken-clean recovery

Flux suspension alone stops reconciliation, not the active scheduler. Containment is
operator-run from the clean authorized primary checkout with administrative credentials:

1. Run `QBIT_MANAGE_CONTAIN_CONFIRM='contain:qbit-manage:stop' mise exec -- just kube qbit-manage-contain stop`.
   It freezes the Flux ownership chain and stops only qbit_manage. Notify operators that
   broad reconciliation is frozen; leave qBittorrent/Gluetun seeding. Failed containment
   is incomplete and requires investigation.
2. Merge reviewed `spec.suspend: true` for the qbit_manage child. Update the clean
   operator checkout to that exact deployed main commit, then run
   `QBIT_MANAGE_CONTAIN_CONFIRM='contain:qbit-manage:finalize' mise exec -- just kube qbit-manage-contain finalize`.
   Its source-revision check restores broad owners while keeping the child and workload
   stopped. If it fails, retain the freeze; do not manually resume owners.
3. Recover a mistaken clean before `/data/downloads/.RecycleBin` expires. The current
   window is seven days; confirm the configured window when policy changes. Privately
   identify the exact torrent, original path, and matching recycle entry. Require that
   the original path contains no replacement data.
4. Restore only that entry through an approved guarded operator workflow. If none
   exists, add and review it before restoration. Do not use a broad move or ad hoc pod
   shell. If seeding is needed, re-add the authorized torrent at its original path and
   category, force recheck, then start. Require library playback, applicable tracker
   credit, and unchanged unrelated torrents.
5. Correct the policy through Git with the child suspended and intended HelmRelease
   unsuspended. Use `mise exec -- just bootstrap qbit-manage` with its printed guard
   from the updated operator checkout, and attend the first corrected run. Only after
   semantic acceptance make activation durable through Git and rerun the verifier.

Stop on ambiguous or expired recycle data, replacement files, unsafe policy correction,
or failed guarded state checks. A library hardlink can survive recycle expiry, but a
seedable download path then needs a separately reviewed recovery decision. Bootstrap
failure re-suspends reconciliation while preserving resources; a running scheduler can
survive, so contain it again when necessary. Keep torrent activity and raw logs private.

## Application-state recovery

Preserve a healthy retained claim on restart or upgrade. For lost state, prefer a trusted
backup restored to a new claim and validated in isolation; broader storage recovery
belongs to [the platform spec](010-talos-flux-platform.md). Never commit live databases
or plaintext configuration exports. An empty replacement claim is a new installation.

For deliberate empty-state bootstrap, stage encrypted dependencies and source suspension
through reviewed Git, wait for deployed main to match, then use the existing guarded
`mise exec -- just bootstrap` workflow from the clean authorized operator checkout.
Scoped linked-worktree observer credentials do not authorize bootstrap. The recipe
requires Git/live suspension and deployed-source agreement; on failure it preserves
resources and re-suspends reconciliation. Help and [.just/bootstrap.just](../../.just/bootstrap.just)
own exact application syntax and guards.

Restore supported runtime configuration in this order: qBittorrent credentials/paths/
categories, media-manager roots/authentication, Prowlarr indexers and app sync, direct
imports, Plex libraries and refresh connectors, then Seerr and auxiliary consumers.
Use internal Service names from source. Do not invent Remote Path Mappings when all
managers share `/data`, or independently edit Prowlarr-synchronized indexers. Native
Plex connector path maps stay blank; require a controlled import/rename to trigger the
matching Plex library without a manual scan. Only library-changing events require scans.
Television naming includes the series year, zero-padded season directories, and `S01E01`
notation; movie naming includes title and release year. Confirm application naming previews
rather than preserving version-specific token strings.

Fresh qBittorrent activation requires the blocking VPN-disconnect resilience gate;
[Lidarr](001-lidarr-music-stack.md) and [Tautulli](003-tautulli-plex-analytics.md) remain
source-suspended through their stronger functional gates. Required runtime settings
must be accepted before treating bootstrap readiness as completed recovery. Make durable
activation through Git and rerun the relevant verifier.

Before accepting Seerr, prove direct Sonarr and Radarr imports independently. Review
Seerr household permissions, approval, and quotas; select intended downstream defaults.
Then require one authorized TV request and one movie request to traverse the expected
manager/category, hardlink import, Plex library refresh, and Seerr availability with
accepted naming. Component readiness and Gatus selected-service reads cannot prove this
workflow. No retained evidence yet establishes both request-to-library acceptance paths.

Homepage media-widget keys are environment-backed and currently lack a media Secret
rollout stamp: after a reviewed rotation, arrange authorized process replacement and
require actual widget data. [Gatus integration credentials](019-media-integration-health-gatus.md)
have the same process-replacement boundary. Supported UI/API settings and human gates
remain necessary; they are not inferred from YAML renders.

## VPN credential rotation and failure recovery

For private-key rotation, keep the previous Proton credential valid, record the old
qBittorrent Pod UID, and use `mise exec -- just repo protonvpn-secrets` under operator
custody. Review both encrypted Secret and rollout-stamp changes through Git. After
reconciliation, an operator must compare the new Pod UID, its `sops-hash` annotation
against `git hash-object` of the encrypted Proton Secret, and a private SHA-256 digest
of the running Gluetun `WIREGUARD_PRIVATE_KEY` against the intended new key. Perform
that comparison with tracing off, non-echoing input, no printed key/digests, and immediate
input cleanup. There is no guarded command for this complete uptake check; ad hoc exec
requires explicit operator authority. Run the registered VPN probe before retiring the
previous credential. A Secret change without startup replacement is insufficient.

On failure retain the kill switch; revert through reviewed Git while the old credential
is valid, or obtain and publish another valid key. Never bypass the VPN. Gluetun can
restore traffic while DNS health or forwarded-port state remains unhealthy. Pod
recreation is the known clean recovery; a same-namespace container restart is not proven
to clear every partial state. If slow liveness recovery/restart alerts persist, escalate
for an attended operator Pod replacement; no dedicated guarded recovery recipe exists.
Proactive expiry reminders belong outside the cluster because no Proton expiry metric
is available. Extending an unchanged valid key needs no Secret or rollout change.
