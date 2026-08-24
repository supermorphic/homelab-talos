# Recover Plex Relay or Sonos playback

Use this runbook when the direct Plex path is unavailable and Relay should provide
limited fallback, or when Plexamp/native Sonos linking or playback fails. Relay and
Sonos are separate boundaries. A successful Relay connection does not prove Sonos
account linking, player discovery, or speaker reachability.

Plex Relay is limited to 2 Mbps, can require transcoding, does not support downloads,
and is not supported equally by every client. Direct remote access remains the normal
path; see [Operate Plex direct remote access](../guides/plex-remote-access-operations.md).

## Authority and safety

The Plex verifiers and sanitized Relay diagnostic are read-only. Router, VLAN, account,
Plex-setting, or Git-managed workload changes require the applicable operator authority.

Do not troubleshoot by mounting a raw Relay key, enabling an unauthenticated CIDR,
opening another WAN port, enabling UPnP or NAT-PMP, adding broad multicast reflection,
or creating an any-to-any VLAN rule. Do not retain Plex tokens, account identifiers,
email addresses, client addresses, or unrelated request paths.

## Direct-path failure with Relay fallback

Trigger: direct off-site access is unavailable or intentionally disabled, and an
authorized client should use Relay.

1. Confirm the cluster-side Plex workload and route are healthy:

   ```bash
   mise exec -- just kube plex-verify
   ```

2. Confirm Relay remains enabled in Plex and the client is signed into the correct Plex
   account with library access.
3. While initiating a remote client request, read sanitized Relay state:

   ```bash
   mise exec -- just kube plex-relay-status
   ```

4. To isolate Relay from the direct path, first remove or disable the direct DNAT through
   the approved router procedure. On the test client, disable Wi-Fi and Tailscale,
   force-quit the Plex client, reopen it, browse the library, and play one item.
5. Confirm the connection uses Relay and respects its capability limits. Do not classify
   a 2 Mbps transcode as a direct-path failure when Relay is the selected path.

Interpret the sanitized evidence before changing anything:

| Evidence | Investigate |
| --- | --- |
| No `startRelay` event | Plex account, cloud discovery, client sign-in, or Relay setting |
| Child exits before authentication | Local runtime identity, Relay cache, or Plex process |
| Authenticated but no allocated port | Plex Relay service or outbound path |
| Port allocated but client cannot browse | Client, account, or library authorization |
| Client browses but playback fails | Client support, bitrate/transcode capacity, or media compatibility |

The Relay process uses outbound TCP `443` and forwards locally on pod loopback port
`32401`. Do not add inbound router or Kubernetes policy rules for Relay.

Verification: `plex-relay-status` reports authentication and port allocation, an
authorized off-site client plays through Relay, and local Plex playback remains healthy.

Escalate when the process repeatedly exits, outbound connectivity is unavailable,
Plex verification fails, or recovery would require changing workload identity,
credentials, network policy, or storage. Those changes require a reviewed Git or
operator recovery action.

## Native Sonos playback failure

Trigger: the Plex service inside the Sonos app cannot browse or play the library.

1. Confirm Plex is healthy and the library is available locally.
2. In the Sonos app, open Plex and select Music under **Other Libraries** when needed.
3. Verify the Sonos account remains authorized to the intended full Plex account.
4. Confirm the router permits the Sonos VLAN to reach the Plex LoadBalancer on TCP
   `32400`. The destination is the current LoadBalancer, not the internal Gateway or a
   retired Plex host.
5. Confirm Pi-hole permits private `plex.direct` answers; DNS rebind protection must not
   strip the LoadBalancer-derived name.
6. Retry browse and playback. Native Sonos success proves the cloud service and speaker
   can use the library; it does not prove Plexamp can discover the player.

Verification: browse succeeds, audio plays on the intended speaker, Plex records the
session, and no broad VLAN or multicast exception was added.

Escalate when the exact TCP path is denied, the speaker receives an internal Envoy URL,
or account authorization cannot be restored without changing shared household state.

## Plexamp player missing or playback failure

Trigger: Plexamp cannot list a Sonos player, or switching to it fails while native Sonos
playback works.

Initial linking requires Plex Pass, a full Plex account, Sonos authorization, and a
supported Plex application on the same local network as the Sonos player.

1. Temporarily connect the iPhone to an SSID mapped to the Sonos VLAN.
2. In the supported Plex iOS app, open **Players**, choose the Sonos linking entry, and
   complete Sonos OAuth with the intended full Plex account.
3. Return the phone to the normal Wi-Fi network.
4. In Plexamp, confirm the intended player appears and play a track without AirPlay.
5. Remove the temporary Sonos-VLAN SSID if one was created for linking.

If same-VLAN linking succeeds but cross-VLAN control fails, capture the exact current
flows before proposing a policy change:

```bash
mise exec -- just kube plex-network-observe 600
```

Propose only the required protocol, direction, player group, and destination ports
through review. Plex SSDP traffic to `239.255.255.250:1900` is deliberately blocked to
prevent automatic WAN mapping; the supported Plex-for-Sonos path does not require
opening that multicast path.

Verification: Plexamp lists the player and completes native Sonos playback without
AirPlay; local direct playback, Tautulli, Homepage, and Gatus remain healthy.

Escalate when supported same-network linking fails, account roles are unclear, or the
only apparent workaround would widen multicast or inter-VLAN access.
