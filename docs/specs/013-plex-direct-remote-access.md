# Plex Direct Remote Access

## Purpose

Retain as permanent the IPv4-only remote path that satisfied the Plexamp and Sonos
objective without regressing local playback. The design publishes Plex's own TLS
listener through one router rule. It does not recreate the retired public Envoy plane,
expose another media application, or add a public IPv6 path.

This lineage began as the replacement experiment after the dedicated public Envoy
design failed. It became permanent only after direct publication, local-client
discovery, Sonos behavior, containment, detection, rollback, and recovery boundaries
were reconciled. The [Envoy experiment](012-plex-public-envoy-experiment.md) remains a
separate failed design; the [remote detector](014-plex-remote-access-detection.md) is a
separate companion control.

## Decision context and alternatives

The choice was not between a risk-free direct path and a complex proxy. The available
paths traded different failure modes:

| Approach | Principal benefit | Why it was not selected as the permanent primary path |
| --- | --- | --- |
| Relay | No inbound listener and the smallest public attack surface | Its 2 Mbps ceiling and incomplete client support could not satisfy local and Sonos behavior together. It remains fallback. |
| Dedicated public Envoy | Hardened public parser, isolated hostname and key, and an independent public data plane | It failed the required Sonos playback gate and had the largest configuration surface. The initial exclusive explanation for its failure was later weakened by the publish self-check discovery. |
| Direct Plex listener | Plex-managed name and certificate, supported client behavior, and much less infrastructure | Selected with explicit acceptance that Plex's own parser and API face the Internet and have no rate limiter or edge proxy. |
| Zero Internet exposure with `hostNetwork` | No public listener | Rejected because moving Plex onto the host network would bypass the existing pod policy. Safe use required a separately designed host firewall around sensitive node services. |

Direct exposure accepted the larger Plex parser risk in exchange for materially reducing
the configuration and ownership surface that had already proved failure-prone during the
public Envoy experiment.

`externalTrafficPolicy: Local` was chosen over `Cluster` to preserve real off-cluster
source identity for Plex, Hubble, and LAN/remote classification. `Cluster` would have
hidden clients behind a node source address and made attribution weaker. This choice
required the policy to admit `world` on TCP `32400`.

The Service uses an explicit address from the existing non-auto-assigned MetalLB pool.
A new dedicated pool would not improve target stability and would repeat the earlier
pool-admission failure mode. The default public port stayed in the experiment because a
non-standard port was only obscurity and another variable; stronger edge control or a
different public port remained deferred.

## Experiment method and acceptance gates

The experiment started with an unproved hypothesis: a retained local custom connection
and a new Plex-published direct connection might serve different clients without the
custom URL taking precedence for Sonos. Vendor documentation did not establish that
connection ordering, so measured client behavior was the decision oracle.

The sequence first created the cluster listener without a WAN mapping, then required the
companion detector to fire and reach the existing notification path. Only after those
gates did it add the router mapping and run the full client matrix. The retired public
Envoy plane remained available until the replacement passed; teardown was not allowed
to remove the fallback before the direct path was proven.

Attended operation was not a substitute for detection: the listener could not become
durable merely because an operator watched the experiment; real alerts first had to fire
through the production ntfy path.

The acceptance contract required:

- forced rediscovery before each client row because cached connection entries had twice
  produced false passes;
- Plex's published resource name and the actual client connection URL as routing
  evidence rather than the Remote Access status indicator;
- Plexamp-to-Sonos playback without AirPlay and no regression for Apple TV, local
  Plexamp, Plex iOS, native Sonos, Tautulli, Homepage, Gatus, or the internal route;
- an off-network scan showing only the intended IPv4 TCP listener and no automatic
  UPnP/NAT-PMP mapping; and
- rollback evidence that distinguished blocking new connections from evicting an
  established session.

The off-site client had its own 2 Mbps quality cap. Its result proved the direct route
from the reported connection, not throughput above the Relay ceiling. Relay fallback
was not re-exercised during that acceptance window because doing so would interrupt the
working household path.

## Architecture

The public remote path uses the connection Plex derives from the observed WAN address:

```text
<wan-address-with-dashes>.<hash>.plex.direct:32400
  -> residential WAN IPv4 resolved from that name
  -> one UniFi DNAT: WAN TCP 32400 -> <plex-load-balancer-address>:32400
  -> Plex LoadBalancer Service
  -> Plex Media Server
```

Plex publishes this connection after it learns the WAN address and the manual public
port. It also checks its own WAN-derived `plex.direct` address on TCP `32400`, which is
why the network policy admits that public egress port. Plex owns the `plex.direct` DNS
name and certificate. The remote path needs no operator-managed public DNS record, DDNS
updater, public Gateway, or Internet-facing operator certificate.

The Plex Service requests one explicit LAN address from MetalLB's non-auto-assigned
`internal` pool. It exposes only TCP `32400` and uses
`externalTrafficPolicy: Local` so Plex and Hubble retain the real off-cluster source
identity instead of a node SNAT address. It sets `allocateLoadBalancerNodePorts: false`
to prevent future NodePort allocation for a listener form that the design does not use.
Kubernetes does not deallocate an existing NodePort when that field changes to `false`,
so the HelmRelease post-render also submits `nodePort: null` for the application port to
clear any retained API allocation. Source validation enforces the Boolean in
`values.yaml` and separately requires the final Helm-plus-post-render output to contain
both `allocateLoadBalancerNodePorts: false` and the explicit null port field. The live
verifier then requires the applied Service to contain no allocated NodePort. The
LoadBalancer makes Plex reachable on the LAN; only the external UniFi DNAT creates
Internet exposure.

## Local and client-discovery paths

`https://plex.lab.supermorphic.com` remains the internal browser and application route:
Pi-hole resolves it to the shared internal Envoy Gateway, which forwards to
`plex:32400`. The internal HTTPRoute uses `timeouts.request: 0s`, because Envoy's
default 15-second request deadline interrupts long Direct Play responses.

The validated Plex **Custom server access URLs** list is different. It contains exactly
one entry: the TLS-valid name derived from the private Plex LoadBalancer address:

```text
https://<load-balancer-address-with-dashes>.<certificate-uuid>.plex.direct:32400
```

This private address-derived name resolves directly to the LAN LoadBalancer. It is a
local client-discovery path and never routes through the WAN DNAT. It coexists with the
separate WAN address-derived remote connection that Plex publishes.

The internal Envoy hostname must not be advertised through the custom URL setting.
During the accepted experiment, Plex's cloud service preferred that Envoy URL and
handed it to the Sonos speaker. The Sonos VLAN could not route to the internal Gateway
address, so the cast failed. Replacing it with the LoadBalancer-derived `plex.direct`
URL restored Plexamp-to-Sonos playback and did not regress full local Direct Play.

Plex's **LAN Networks** setting includes the trusted client VLANs and the current Pod
CIDR, but excludes the cluster VLAN. Local application
sessions use the internal Envoy route, so Plex sees an Envoy Pod address rather than the
original client address. Without the Pod CIDR, Plex classifies those local sessions as
remote. They can then consume the per-user remote stream allowance and receive remote
quality treatment, which can throttle normal household playback. Tautulli's current
activity view is the independent check that a local session is classified as **LAN**.

The cluster VLAN is deliberately excluded. The current LoadBalancer uses
`externalTrafficPolicy: Local`, which preserves an off-site client's public source
address. If that policy changed to `Cluster`, a remote connection could instead reach
Plex with a node source address from the cluster VLAN. Treating that whole VLAN as LAN
would then exempt the Internet session from remote limits. The Pod CIDR has no
equivalent off-cluster source risk because external clients cannot originate with a
routable Pod address.

Pi-hole must allow the private answer embedded in `plex.direct`; DNS rebind protection
must not strip it. The Sonos VLAN also needs a router rule to the Plex LoadBalancer on
TCP `32400`. These are operator-owned runtime settings, not Git-managed cluster state.

## Exposure and containment

The router boundary is exactly one TCP forward to the Plex LAN address and internal port
`32400`. UPnP and NAT-PMP remain disabled so Plex cannot create another mapping. No
public IPv6 or AAAA path is part of this design.

The Plex Cilium policy admits `world` only on TCP `32400`. This allows the WAN-forwarded
traffic and, because Cilium classifies addresses outside the cluster as `world`, also
admits LAN clients to the LoadBalancer address. Other ingress ports remain closed. The
policy retains the exact in-cluster consumers and public-IPv4 egress on TCP `443` and
`32400`, with private, shared, loopback, link-local, documentation, multicast, and other
reserved ranges excluded.

TCP `32400` egress is load-bearing. Plex checks its own WAN-derived
`plex.direct:32400` endpoint before publishing the connection. The first rollout allowed
public TCP `443` only, so Cilium denied that check and Plex published no direct resource.
Because the WAN address is dynamic, policy cannot grant only the current self-address;
the implemented rule permits any otherwise eligible public IPv4 destination on TCP
`32400`. This is a broader capability than the early design intended and is an accepted
containment cost, not a claim that the destination is Plex-only.

Plex Remote Access and authentication remain enabled, the manually specified public port
matches `32400`, Relay remains enabled as a fallback, and unauthenticated-network
settings remain empty. Account multi-factor authentication remains enabled, remote
streams stay bounded per user, and the client network remains IPv4-only. Changing Secure
Connections is outside this design.

The direct listener has no rate limiter or hardened edge proxy before Plex. A public
Plex parser or API vulnerability therefore has greater consequence than it did behind
Envoy. The compensating controls are the non-root and capability-free workload, pinned
image, read-only media, absent Kubernetes API token, restricted Cilium policy, detection,
prompt patching, and the ability to remove one DNAT quickly.

![Plex public-port trust boundaries](images/plex-remote-access-trust-boundaries.png)

## Detection and response

Detection had to be deployable before exposure without requiring a legitimate remote-
traffic baseline that could exist only after the gated DNAT was created; the companion
design therefore owns provisional evidence and later tuning without making exposure its
own prerequisite.

The permanent design retains the Hubble-derived remote-connection alerts, missing-metric
alerts, workload-policy-denial alert, Prometheus evaluation, Alertmanager route, and
synchronous ntfy adapter. A 2026-08-22 verification observed healthy live rules and
targets and both a firing and resolved notification through the production route. That
dated result does not prove continuous detector health.

The guarded Flux delivery exercise uses Alertmanager's aggregate webhook counters only
after it proves that ntfy is the sole loaded webhook receiver and that both success and
failure series exist. This prevents unrelated webhook traffic from satisfying the
delivery oracle. Detection remains aggregate: it does not identify a remote client,
detect every Plex authentication failure, or retain application requests. Source
attribution and session review remain bounded operator actions.

## Validated result

The dated acceptance exercise established all required behavior:

- Plexamp switched to Sonos and played without AirPlay;
- native Sonos playback worked after its router rule was corrected to the Plex
  LoadBalancer address;
- Apple TV, Plexamp local playback, Plex iOS 4K playback, Tautulli, Homepage, and Gatus
  matched or exceeded baseline behavior;
- Plex Web-to-Sonos playback also began working;
- off-site cellular reached Plex through the DNAT rather than Relay; and
- an off-network scan found TCP `32400` open, the other scanned ports filtered, no AAAA
  record, and no automatic UPnP or NAT-PMP mapping.

The off-site client retained a 2 Mbps client-side quality cap, so that exercise proved
the direct route but not remote bitrate above 2 Mbps. Relay fallback was not re-tested
because doing so required interrupting the household direct path.

The result also corrected two earlier inferences. Zero Cilium ingress on `32400` during
native Sonos playback can represent a working Relay session on pod loopback, not a
broken Sonos path. Plex's reported Remote Access reachability state is also not a routing
oracle: Sonos had played while that state reported not reachable. The published
connection name and actual client URL are the useful evidence.

## Material implementation discoveries

The final architecture differs from the first direct-access proposal in several
load-bearing ways:

- The early experiment retained the internal Envoy hostname as the custom URL with an
  explicit TCP `443` port. Measured Sonos routing showed that Plex's cloud service could
  prefer that value and hand the speaker an unreachable internal Gateway address. The
  permanent list therefore contains exactly one private LoadBalancer-derived
  `plex.direct:32400` URL. The internal Envoy hostname remains a browser route but is not
  advertised through Plex discovery.
- Plex's `LAN Networks` needed the Pod CIDR because local reverse-proxied sessions arrive
  from Envoy pods. It deliberately excluded the cluster VLAN so a future node-SNAT path
  cannot misclassify an Internet client as local. Tautulli's LAN/WAN view became the
  independent classification check.
- Direct publication required both a Plex-managed connection name and a successful
  outbound self-check on TCP `32400`. Naming alone did not make the path work. This
  finding also means the earlier Envoy failure cannot be attributed exclusively to the
  operator hostname and certificate.
- Setting `allocateLoadBalancerNodePorts: false` did not remove an already allocated
  NodePort. The final Helm post-render submits an explicit null port field, and source
  and live validation treat absence of the second listener form as a separate invariant.
- Remote Access status remained context only. Published resources, actual client URLs,
  off-network reachability, and human-visible playback were the useful oracles.

These are design corrections, not operator procedure. Current application and router
steps remain in the operations guide.

## Authority and recovery boundary

Git proves the Service, HTTPRoute, workload, and Cilium policy desired state. It cannot
prove that the UniFi DNAT, Plex settings, Pi-hole rebind exception, Sonos VLAN rule,
public IPv6 filtering, or account settings still match this design. Current operation
requires separate, sanitized checks of those systems and an actually off-network scan.

Plex retains a read-only media mount and cannot delete library media. Its application
setting **Empty trash automatically after every scan** also remains disabled so a
temporary SMB or NAS outage does not remove library entries when media disappears from a
scan. Radarr and Sonarr remain the removal authorities for their managed libraries,
while download cleanup stays under the qBittorrent and qbit_manage policy. The NAS
account remains limited to the media share and the write access that media automation
requires.

Plex configuration, database, identity, and watch history require recoverable backups.
The control includes scheduled Plex database backups, the established off-cluster
Longhorn backup, and a rehearsed configuration restore into a throwaway claim with an
isolated Plex validation before any production replacement. Bulk media has no independent
backup by operator decision; total loss requires reacquisition and can be slow or
incomplete.

Removing the DNAT blocks new remote connections but existing router conntrack entries
can survive. Restarting Plex evicts established sessions but also interrupts every local
client because Plex is a single `Recreate` Deployment on a `ReadWriteOncePod` claim. A
restart is therefore an incident action when eviction is required, not a routine part
of removing exposure.

Review this design after a change to the gateway mapping, public DNS, address-family
configuration, Plex network or account settings, Service listener shape, Cilium policy,
notification route, or recovery design. A calendar-based review is not required.

## Deferred and reconsideration boundaries

This design does not provide application-request logging, authentication-failure
detection, bandwidth-abuse detection, public rate limiting, or a hardened edge parser.
It also does not select a surgical router conntrack operation. DNAT removal blocks new
connections; restarting Plex is the available session-eviction action and interrupts all
local clients.

Reconsider the architecture after a material change in Plex client naming or discovery,
support for a compatible authenticated proxy, public address-family handling, edge
filtering, the Service listener shape, the Cilium egress requirement, or detector and
recovery evidence. A different external port or proxy is a new trade study, not an
automatic hardening step.

## Consequences

This permanent path is smaller and more compatible than the public Envoy design and
exposes no operator-controlled TLS key. Its cost is continuous Internet reachability to
Plex's own listener. The [remote-access detection specification](014-plex-remote-access-detection.md)
defines the available aggregate signals and their limits.
