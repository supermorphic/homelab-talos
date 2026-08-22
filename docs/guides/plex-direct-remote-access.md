# Configure Plex direct remote access

Use this guide to restore, change, validate, or remove the external router path to Plex.
The design and accepted historical evidence are in
[specification 019](../specs/019-plex-direct-remote-access.md). This procedure changes
what the Internet can reach and requires an attended operator window.

## Current path

```text
Plex-managed <wan-address>.<certificate-uuid>.plex.direct:32400
  -> residential WAN IPv4
  -> UniFi DNAT: WAN TCP 32400 -> 192.168.90.31:32400
  -> Plex LoadBalancer Service
  -> Plex Media Server
```

Git owns the LoadBalancer Service, internal HTTPRoute, Plex workload, and Cilium policy.
The UniFi rule, Plex application settings, Pi-hole rebind handling, Sonos VLAN rule, and
public IPv6 filtering are operator-owned state outside Git.

## Preconditions

Before changing exposure:

1. Confirm the Plex application, LoadBalancer, and policy are healthy:

   ```bash
   mise exec -- just kube plex-verify
   ```

2. Confirm all Plex remote-access alerts are loaded and inactive. Follow the
   [detection response runbook](../runbooks/plex-remote-access-detection.md) when a rule
   is firing or its telemetry is missing.
3. Confirm UPnP and NAT-PMP are disabled in UniFi. Plex must not be able to create an
   independent mapping.
4. Inventory existing WAN forwards. There must be no second Plex or TCP `32400` rule.
5. Record the current Plex settings privately. Do not put a WAN address, Plex token,
   account identity, or client address in the repository.

The required Plex settings are:

| Setting | Required value |
| --- | --- |
| Remote Access | Enabled |
| Manually specify public port | `32400` |
| Relay | Enabled as fallback |
| Allowed without authentication | Empty |
| Remote streams per user | `2` |
| Custom server access URLs | Only the private LoadBalancer-derived `plex.direct` URL, with port `32400` |
| LAN Networks | Trusted client VLANs and the pod network; never the cluster VLAN |

The custom URL has this form:

```text
https://<load-balancer-address-with-dashes>.<certificate-uuid>.plex.direct:32400
```

Do not advertise `plex.lab.supermorphic.com` as a custom server access URL. That hostname
uses the internal Envoy path and is not the direct Sonos media path. Pi-hole must allow
the private answer embedded in `plex.direct` instead of stripping it as DNS rebinding.

## Create or restore the router path

1. Set the custom server access URL to the LoadBalancer-derived `plex.direct` value
   above. Include port `32400` explicitly.
2. Create exactly one UniFi forward:

   | Field | Value |
   | --- | --- |
   | Protocol | TCP |
   | External port | `32400` |
   | Forward address | `192.168.90.31` |
   | Internal port | `32400` |
   | Logging | Enabled when available |

3. In Plex Remote Access, enable manual public-port selection and set `32400`.
4. Keep Secure Connections at its existing approved value. Keep unauthenticated
   networks empty. Do not add another public hostname, IPv6 route, WAN port, UPnP rule,
   reverse proxy, or tunnel.
5. Confirm Plex publishes a WAN-derived `*.plex.direct:32400` connection. Plex's
   reachability indicator is useful context but is not a routing oracle; verify the
   published connection and actual client path.

## Validate the path

Force client rediscovery before each test. Require these behaviors:

- Plexamp switches to Sonos and plays without AirPlay;
- native Sonos plays the Plex library;
- Apple TV, Plexamp, and Plex iOS local playback continue through the internal path;
- Tautulli continues recording sessions;
- Homepage and Gatus remain healthy; and
- an off-site cellular client reaches the direct path rather than Relay.

The Sonos VLAN needs a router rule to `192.168.90.31:32400`. Do not point it at the
internal Gateway or a retired Plex host.

Run external negative checks from a genuinely off-network client:

1. Only TCP `32400` answers among the reviewed scan set.
2. No AAAA record or public IPv6 path exists for the published Plex names.
3. UniFi shows no automatic UPnP or NAT-PMP mapping.

A scan from the LAN is not evidence about the WAN boundary. Verify the alert and source
path during the window with:

```bash
mise exec -- just kube plex-network-observe 600
```

The command is read-only and bounded. Keep raw source addresses out of repository
artifacts.

## Stop or roll back exposure

1. Remove the single UniFi DNAT. This blocks new remote connections.
2. Clear Plex's manually specified public port if the direct path will remain disabled.
3. Confirm no off-network client can open a new connection to TCP `32400`.
4. Confirm local playback, Tautulli, Homepage, and Gatus still work.

Removing the DNAT does not guarantee eviction of established conntrack sessions. If an
active attack or suspected compromise requires session eviction, restart Plex through an
approved operator workflow. This interrupts every client because Plex is single-active
with a `Recreate` Deployment and a `ReadWriteOncePod` claim.

Do not remove the workload hardening, read-only media mount, bounded egress, detection,
or Relay fallback when disabling the router path. A permanent change to the Git-managed
LoadBalancer or policy goes through a separate reviewed Git change.

## Escalation

Remove exposure immediately when any of these conditions occurs:

- an internal consumer regresses;
- Plexamp-to-Sonos or native Sonos playback stops because of the changed path;
- any unapproved WAN port or public IPv6 path is reachable;
- Plex creates an automatic router mapping;
- the Cilium policy no longer admits only the intended Plex ingress port; or
- remote-access detection is unavailable during the change window.

For a suspected security incident, preserve private evidence, remove the DNAT, decide
whether session eviction is required, and escalate to the operator. Do not publish
client addresses, tokens, or an actionable unresolved exploit path.
