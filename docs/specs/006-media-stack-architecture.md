# Media Stack Architecture

## Intent and ownership

Media acquisition, automation, serving, requests, and analytics share one GitOps
architecture. [Media source](../../kubernetes/apps/media/) owns exact workloads, images,
paths, routes, dependencies, and policy values. Git owns deployment shape and encrypted
integration Secrets; supported application UIs/APIs own runtime settings on retained
claims. Editing application SQLite databases from Git would race the writer and couple
reconciliation to private schemas.

Only qBittorrent shares Gluetun's VPN namespace. Media managers use internal Service
DNS; optional FlareSolverr follows Prowlarr's direct egress because challenge sessions
need the same effective source address. It is a per-indexer helper, not a global proxy.
Ordinary media routes remain internal; [Plex direct access](013-plex-direct-remote-access.md)
is the separately controlled exception. The namespace's privileged Pod Security label
does not grant every container privileges: only Gluetun receives route-changing
capability, while Plex receives its scheduled GPU resource.

## Storage and hardlinks

Downloads and organized libraries are sibling trees on one NAS-backed RWX SMB filesystem.
qBittorrent and the media managers see the same `/data` paths. Imports must hardlink
rather than copy: independent filesystem acceptance requires shared inode identity and
link count two. Separate shares cannot satisfy this contract. qbit_manage sees only
`/data/downloads`, so cleanup cannot directly write organized library names.

Plex mounts media read-only at `/Volumes/Prometheus` to preserve its migrated database
paths, and uses node-local transcode scratch. Application databases remain on retained
Longhorn single-writer claims with `Recreate` Deployments. Plex's `ReadWriteOncePod`
claim supplies a stronger exclusive-writer boundary. Replication permits rescheduling
with an outage; it is not a backup or an active-active application model. Hard node
failure can leave attachment blocked until node-down pod deletion completes; reducing
failover time requires a fresh hard-node test rather than an assumed timing guarantee.

The `media-data` PV's `nolease` option is a candidate mitigation for Plex open failures
while qBittorrent holds the hardlinked name open. Its cause and post-remount result
remain unverified. Changing PV options does not change existing node mounts: an
operator must coordinate a mount cycle on every consuming node, then test both
concurrent-open orders and representative playback/NAS throughput. Removing leases
reduces client caching; inode-only evidence cannot establish this mitigation.

## Torrent lifecycle

qBittorrent downloads and seeds. Sonarr, Radarr, and Lidarr own their categories, imports,
renaming, and organized libraries. qbit_manage owns successful-torrent classification,
seed limits, stopping, and download-side cleanup. Media-manager **Remove Completed**
stays disabled and **Post-Import Category** stays blank. Global qBittorrent seed limits
must not stop private torrents earlier than the selected policy.

[The policy configuration](../../kubernetes/apps/media/qbit-manage/app/config.yml)
owns exact groups, ratios, times, and priorities. Generic private tagging protects even
unmapped trackers; tracker-specific tags select dedicated policy. Highest precedence for
private groups and private-tag exclusions in every cleanup group protect independent
failure cases. Categories never change, priorities are unique, private cleanup and
finite private time cutoffs remain disabled, and stop actions remain reversible.
Orphan, unregistered, and tracker-error deletion are outside the policy.

CZTeam's dedicated group must retain both generic and tracker-specific protection.
Local seed time and per-torrent ratio do not prove tracker credit or account-wide
compliance. Before policy or qBittorrent compatibility changes, the operator checks the
tracker's current rules, account/H&R status, and accepted client list privately. Prowlarr
indexer priority is unrelated to qbit_manage group priority and is no H&R safeguard.

Accept the first real private torrent only after its tags, selected group, unchanged
category, minimum seed floor, absence of finite cutoff, absence of cleanup, and tracker
credit after an announce interval agree. On rollback, preserve private tags/exclusions,
return only that group's policy to no-limit/no-cleanup, deliberately clear any persisted
limits on affected torrents, resume them, and check credited seeding. Never fall back to
public cleanup or mass-reset unrelated limits. New private trackers need independently
reviewed rules and generalized validation before another dedicated group is introduced.
Use only bare announce hostnames; full URLs may contain passkeys.

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

## VPN contract and recovery

Gluetun owns the shared Pod's routes, firewall, resolver, WireGuard tunnel, and dynamic
forwarded port. Startup gating and the ongoing kill switch are separate requirements.
VPN failure must block Internet egress without falling back to the home WAN; DNS failure
alone is not proof. The registered resilience test measures qBittorrent's own namespace
using DNS-independent reachability and an independent home-WAN never-leak oracle.

Use Proton's port-forward-capable native provider selection. Retain only the generated
private key through the operator SOPS writer. Do not mount `wg0.conf`: its precedence
would override native endpoint selection and failover. Moderate NAT is incompatible
with this port-forwarding setup. The temporary forwarded port is owned by Gluetun's
hooks, not a fixed qBittorrent preference. Those localhost hooks require narrowly scoped
localhost authentication bypass; broader private-network bypass would defeat WebUI login.

WebUI verification does not prove VPN health, exit identity, resolver confinement, or
port parity. The stronger registered qBittorrent probe uses exec and a temporary
non-VPN Pod; it remains a separately authorized mutation workflow.

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

## Encoding decision boundary

The removed encoding benchmark did not establish a production encoder. LA-ICQ was
rejected because eligible nodes selected ICQ rather than the required look-ahead mode;
that was a capability no-go, not a measured quality verdict. The distinct corrected
`qsv-hevc-icq-v1` evaluation produced no qualifying AVC, VC-1, or HDR10 setting under its
predeclared quality gates. Independent failures ruled out every setting despite separate
unresolved measurement anomalies. Neither result authorizes FileFlows, media replacement,
threshold relaxation, or another run of the closed strategy.

A future encoder needs a new strategy decision, independent measurement oracles, and
predeclared quality/throughput gates before execution. Preserve torrent hashes and
hardlink economics: active payloads cannot be rewritten, retained private downloads can
make an encode increase storage, and public cleanup delays realized savings. Production
library replacement requires a separate accepted implementation and operator authority.
