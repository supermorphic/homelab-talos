# Configure Plex direct remote access

Use this guide to restore, change, validate, or remove the external router path to Plex.
The design and accepted historical evidence are in
[specification 013](../specs/013-plex-direct-remote-access.md). This procedure changes
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

1. Confirm the Git-managed listener shape and rendered Service, then run the established
   live verifier:

   ```bash
   mise exec -- just kube plex-validate
   mise exec -- just kube plex-verify
   ```

   Source validation requires one TCP application port, the explicit LoadBalancer
   address, `externalTrafficPolicy: Local`, `allocateLoadBalancerNodePorts: false`, and
   the post-rendered null NodePort field. The live verifier checks workload readiness,
   runtime hardening, the LoadBalancer type and address, `externalTrafficPolicy: Local`,
   disabled NodePort allocation, absence of an allocated NodePort, route acceptance,
   DNS, and the internal TLS identity endpoint. It does not read the ready EndpointSlice,
   the live application-port value, or the applied CiliumNetworkPolicy. Inspect all three
   objects:

   ```bash
   mise exec -- kubectl --kubeconfig .kube/config --context homelab-diagnostic \
     --namespace media get service plex --output yaml
   mise exec -- kubectl --kubeconfig .kube/config --context homelab-diagnostic \
     --namespace media get endpointslice \
     --selector kubernetes.io/service-name=plex --output yaml
   mise exec -- kubectl --kubeconfig .kube/config --context homelab-diagnostic \
     --namespace media get ciliumnetworkpolicy plex --output yaml
   ```

   Require the Service to expose exactly one application port, TCP `32400`, with no
   allocated `nodePort`. Require at least one EndpointSlice endpoint with
   `conditions.ready: true` and TCP port `32400`. Require the applied policy to select
   Plex and contain exactly one `world` ingress rule with only TCP `32400`; no second
   `world` rule or port is permitted.

   These reads prove API object state, not packet enforcement. The established
   enforcement proof is the operator-attended, state-changing test below. It creates and
   removes run-scoped probe Pods. Run it only in an approved window after reviewing the
   test catalog entry:

   ```bash
   PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' \
     mise exec -- just kube plex-network-policy-test
   ```

   Do not treat source validation or the read-only object inspection as deployed packet
   containment without that guarded proof.

2. Confirm all Plex remote-access alerts are loaded and inactive. Follow the
   [detection response runbook](../runbooks/plex-remote-access-detection.md) when a rule
   is firing or its telemetry is missing.
3. Confirm UPnP and NAT-PMP are disabled in UniFi. Plex must not be able to create an
   independent mapping.
4. Inventory existing WAN forwards. There must be no second Plex or TCP `32400` rule.
5. Confirm UniFi Intrusion Prevention remains in **Notify and Block** mode, protects the
   Servers network, uses the intended Standard categories, and has no unintended
   exclusion. Confirm the detection engine and normal UniFi update channels are current.
6. Record the current Plex settings privately. Do not put a WAN address, Plex token,
   account identity, or client address in the repository.
7. Start a local playback session through `plex.lab.supermorphic.com`. In Tautulli's
   current activity view, require the session to show **LAN**, not **WAN**. Complete this
   check before setting or relying on the per-user remote-stream limit.
8. Confirm Plex scheduled database backups and the Longhorn off-cluster configuration
   backup are healthy. Require current evidence that the configuration restore has been
   rehearsed with a throwaway claim and isolated Plex validation as described in
   [Recover Longhorn and application state](../runbooks/recovery.md#recover-longhorn-and-application-state).
   Bulk media has no independent backup; recovery after total media loss depends on
   reacquisition.

If the local session shows **WAN**, stop. The internal Envoy route hides the client behind
an Envoy Pod address. Set **LAN Networks** to the trusted client VLANs plus the current Pod
CIDR (`10.244.0.0/16`), then repeat the Tautulli check. Do not include the cluster VLAN
`192.168.90.0/24`. Otherwise local sessions can consume the remote stream allowance and
receive remote quality treatment, while a future source-NAT path through a node could
incorrectly exempt an Internet session from remote limits.

The required Plex settings are:

| Setting | Required value |
| --- | --- |
| Remote Access | Enabled |
| Authentication | Required |
| Manually specify public port | `32400` |
| Relay | Enabled as fallback |
| Allowed without authentication | Empty |
| Account multi-factor authentication | Enabled |
| Remote streams per user | `2` |
| Client network | IPv4 only |
| Custom server access URLs | Only the private LoadBalancer-derived `plex.direct` URL, with port `32400` |
| LAN Networks | Trusted client VLANs and `10.244.0.0/16`; never `192.168.90.0/24` |
| Empty trash automatically after every scan | Disabled |

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

- a local session displays **LAN** in Tautulli before remote-stream limits are treated as
  an effective control;
- Plexamp switches to Sonos and plays without AirPlay;
- native Sonos plays the Plex library;
- Apple TV, Plexamp, and Plex iOS local playback continue through the internal path;
- Tautulli continues recording sessions;
- Homepage and Gatus remain healthy; and
- an off-site cellular client reaches the direct path rather than Relay.

The Sonos VLAN needs a router rule to `192.168.90.31:32400`. Do not point it at the
internal Gateway or a retired Plex host.

Run external negative checks from a genuinely off-network client:

1. UniFi has exactly one Plex mapping: one public TCP port to the LoadBalancer and
   internal TCP `32400`. No duplicate, wildcard, range, or UDP mapping exists.
2. Only TCP `32400` answers among the reviewed scan set.
3. Verify IPv6 independently. Inspect delegated prefixes, global addresses on cluster
   nodes, public DNS answers, and UniFi unsolicited-inbound IPv6 policy. From an actually
   off-network IPv6 source, confirm no Plex connection succeeds. An absent AAAA answer
   or the IPv4 DNAT state does not prove the other IPv6 boundaries.
4. UniFi shows no automatic UPnP or NAT-PMP mapping.

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

Review the complete design when the gateway mapping, public DNS, address family, Plex
network or account settings, Service listener shape, Cilium policy, notification route,
or recovery design changes.

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
