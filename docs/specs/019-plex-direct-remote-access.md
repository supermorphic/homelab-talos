# Plex Direct Remote Access

## Purpose

Provide the current remote path that satisfied the Plexamp and Sonos objective without
regressing local playback. The design publishes Plex's own TLS listener through one
router rule. It does not recreate the retired public Envoy plane or expose another media
application.

## Architecture

The remote path is:

```text
<load-balancer-address-with-dashes>.<certificate-uuid>.plex.direct:32400
  -> residential WAN IPv4
  -> one UniFi DNAT: WAN TCP 32400 -> 192.168.90.31:32400
  -> Plex LoadBalancer Service
  -> Plex Media Server
```

Plex owns the `plex.direct` DNS name and certificate. The remote path needs no
operator-managed public DNS record, DDNS updater, public Gateway, or Internet-facing
operator certificate.

The Plex Service requests the explicit LAN address `192.168.90.31` from MetalLB's
non-auto-assigned `internal` pool. It exposes only TCP `32400` and uses
`externalTrafficPolicy: Local` so Plex and Hubble retain the real off-cluster source
identity instead of a node SNAT address. The LoadBalancer makes Plex reachable on the
LAN; only the external UniFi DNAT creates Internet exposure.

## Local and client-discovery paths

`https://plex.lab.supermorphic.com` remains the internal browser and application route:
Pi-hole resolves it to the shared internal Envoy Gateway, which forwards to
`plex:32400`. The internal HTTPRoute uses `timeouts.request: 0s`, because Envoy's
default 15-second request deadline interrupts long Direct Play responses.

The validated Plex **Custom server access URLs** value is different. It contains only
the TLS-valid name for the Plex LoadBalancer address:

```text
https://<load-balancer-address-with-dashes>.<certificate-uuid>.plex.direct:32400
```

The internal Envoy hostname must not be advertised through that Plex setting. During
the accepted experiment, Plex's cloud service preferred the custom Envoy URL and handed
it to the Sonos speaker. The Sonos VLAN could not route to the internal Gateway address,
so the cast failed. Removing that URL left the `plex.direct` connection, restored
Plexamp-to-Sonos playback, and did not regress full local Direct Play.

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
policy retains the exact in-cluster consumers and the bounded egress described by the
Relay and hardening specification.

Plex Remote Access remains enabled, the manually specified public port matches `32400`,
Relay remains enabled as a fallback, and unauthenticated-network settings remain empty.
Changing Secure Connections is outside this design.

The direct listener has no rate limiter or hardened edge proxy before Plex. A public
Plex parser or API vulnerability therefore has greater consequence than it did behind
Envoy. The compensating controls are the non-root and capability-free workload, pinned
image, read-only media, absent Kubernetes API token, restricted Cilium policy, detection,
prompt patching, and the ability to remove one DNAT quickly.

![Plex public-port trust boundaries](images/2026-08-02-plex-remote-access-trust-boundaries.png)

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

## Authority and recovery boundary

Git proves the Service, HTTPRoute, workload, and Cilium policy desired state. It cannot
prove that the UniFi DNAT, Plex settings, Pi-hole rebind exception, Sonos VLAN rule,
public IPv6 filtering, or account settings still match this design. Current operation
requires separate, sanitized checks of those systems and an actually off-network scan.

Removing the DNAT blocks new remote connections but existing router conntrack entries
can survive. Restarting Plex evicts established sessions but also interrupts every local
client because Plex is a single `Recreate` Deployment on a `ReadWriteOncePod` claim. A
restart is therefore an incident action when eviction is required, not a routine part
of removing exposure.

## Consequences

This path is smaller and more compatible than the public Envoy design and exposes no
operator-controlled TLS key. Its cost is continuous Internet reachability to Plex's own
listener. The remote-access detection specification defines the available aggregate
signals and their limits.
