# Plex Direct Remote Access

## Intent and choice

Plex's own IPv4 TLS listener supplies remote access and native Sonos/Plexamp behavior
without regressing local playback. Relay remains limited fallback. A dedicated public
Envoy experiment failed the Sonos playback gate despite infrastructure and local checks;
Plex-managed names/certificates and publication behavior are a compatibility boundary.
The later native self-check discovery prevents attributing that failure exclusively to
the proxy hostname. Reintroducing a public proxy needs new client-compatibility evidence.

Direct publication accepts continuous Internet access to Plex's parser/API in exchange
for a smaller configuration and ownership surface. It exposes no operator TLS key and
requires no operator public DNS/DDNS service. Host networking was rejected because it
would bypass pod containment. [Plex source](../../kubernetes/apps/media/plex/) owns exact
listener, post-rendering, route, workload, and policy configuration.

## Public and private paths

The public path is one operator-controlled TCP DNAT from WAN IPv4 to Plex's stable LAN
LoadBalancer on `32400`. Plex publishes the WAN-derived `*.plex.direct:32400` connection
and owns that name and certificate. Its outbound self-check on public TCP `32400` is
necessary for publication. The dynamic WAN address prevents a fixed self-address allowlist;
source permits otherwise eligible public IPv4 destinations on that port, a broader
capability than a Plex-only destination grant.

`externalTrafficPolicy: Local` preserves off-cluster source identity. No NodePort listener
is permitted: `allocateLoadBalancerNodePorts: false` prevents new allocations but does not
clear old ones, so the Helm post-render also submits `nodePort: null`. Rendered and live
checks must independently require absence of the additional listener. The LoadBalancer
itself supplies LAN access; only the external router mapping creates Internet exposure.

The internal browser/application Gateway route remains available, with no request
deadline to interrupt long Direct Play responses. Plex's **Custom server access URLs**
instead contains exactly one private LoadBalancer-derived TLS name:

```text
https://<load-balancer-address-with-dashes>.<certificate-id>.plex.direct:32400
```

Do not advertise the internal Envoy hostname there: Plex cloud discovery can hand it to
a Sonos speaker that cannot reach the Gateway. The private address-derived connection
coexists with Plex's separately published WAN connection. Pi-hole must permit the private
`plex.direct` answer, and the Sonos VLAN needs operator-managed TCP access to the Plex
LoadBalancer. Cached discovery entries can create false passes, so force client rediscovery.

Plex's **LAN Networks** includes trusted client VLANs and the current Pod CIDR, because
local Envoy sessions appear with Pod source addresses. Exclude the cluster VLAN: future
node SNAT could otherwise exempt an Internet session from remote limits. Require a local
Gateway playback session to appear as **LAN** in Tautulli before relying on those limits.
The Remote Access status indicator is context; published resources and actual client
connection URLs are routing evidence.

## Exposure controls and authority

The router exposes exactly the accepted IPv4 TCP listener, with UPnP/NAT-PMP disabled.
Public IPv6 is outside the design. Lack of a public AAAA record does not prove inbound
IPv6 is closed; review delegated prefixes, node global addresses, unsolicited-inbound
router policy, and an actual off-network connection attempt independently.

Authentication stays enabled, the unauthenticated-network list stays empty, account MFA
stays enabled, and per-user remote streams remain bounded. Preserve the approved Secure
Connections setting. Read-only media, non-root execution, dropped capabilities, no API
token, bounded Cilium policy, scheduled patching, and
[aggregate detection](014-plex-remote-access-detection.md) are compensating controls.
The listener does not provide a hardened edge parser or rate limiter.

Git owns Kubernetes desired state. UniFi DNAT/filtering, Plex account/network settings,
Pi-hole rebinding exceptions, and Sonos routing are operator-owned external state;
repository validation cannot prove them. Public-Envoy source removal also does not prove
old external DNS/updater credentials were removed; any remaining external cleanup needs
operator inspection rather than a claim inferred from Git.

## Restore and accept the direct path

1. Require ready listener/policy, healthy detection, and recoverable Plex configuration.
   Do not establish durable exposure while telemetry is known blind.
2. Set the private discovery URL and accepted LAN classification. Inventory router rules
   and disable automatic mappings; require the intended Servers intrusion prevention
   setting without unintended exclusions.
3. Create only the accepted TCP mapping to the Plex LoadBalancer. Set Plex's manual public
   port to match, then require publication of the WAN-derived `plex.direct` connection.
4. Force rediscovery and require healthy Apple TV, Plex iOS, local Plexamp, native Sonos,
   Plexamp-to-Sonos without AirPlay, Tautulli, Homepage, Gatus, and internal browsing.
5. From genuinely off-network, prove the intended direct connection, bounded exposed
   port set, and independent absence of an IPv6 path. A LAN scan cannot prove WAN safety.

A client quality cap limits what playback acceptance proves: the retained off-site result
proved a direct route but did not prove bitrate above Relay's ceiling. Relay fallback
needs its own [client exercise](008-plex-relay-sonos.md#recover-relay-access).
Normal acceptance does not generate detector test traffic.

## Disable exposure

Remove the single DNAT, clear the manual public port if direct access will stay disabled,
and require a new off-site TCP connection to fail while local playback and integrations
remain healthy. Keep Relay, containment, detection, and read-only media intact.

Existing conntrack entries and Plex sessions can survive DNAT removal. If material risk
requires session eviction, an authorized operator restarts Plex; that interrupts every
local client because the server is a single writer. No surgical conntrack operation is
selected. DNAT removal is proof about new connections only.

## Recovery and change boundary

Disable **Empty trash automatically after every scan** so temporary NAS/SMB loss does
not discard library entries. Media managers own organized-library changes; qbit_manage
owns download cleanup. Bulk media has no independent backup by operator decision, so
complete loss requires potentially slow/incomplete reacquisition.

Plex database, identity, and watch history need application and off-cluster Longhorn
backups. Before consequential exposure changes, require a configuration restore rehearsal
into a throwaway claim with isolated validation before production replacement.
[Platform recovery](010-talos-flux-platform.md) owns storage prerequisites; ordinary
replication is not restore evidence.

Review after material router/DNS/address-family, Plex settings, listener, Cilium,
notification, or recovery changes. Another ingress port invalidates the current detector's
workload-to-port assumption. New proxy/client naming behavior, edge filtering, or stronger
application detection needs an explicit redesign and fresh acceptance.
