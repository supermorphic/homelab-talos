# Recover Plex and Plexamp Sonos playback

## Trigger

Use this runbook when either:

- the Plex service inside the Sonos app cannot browse or play the intended library; or
- native Sonos playback works, but Plexamp cannot discover or control the Sonos player.

These are different paths:

```text
Sonos playback problem
        ↓
does the Plex service in the Sonos app browse and play?
        ├─ no  → Plex/account/library/DNS/VLAN path
        └─ yes
             ↓
        does Plexamp list and control the player?
        ├─ yes → problem is outside these Plex/Sonos boundaries
        └─ no  → account linking, discovery, or cross-VLAN control
```

Normal Plex, library, and direct remote-access setup belongs in
[Set up media automation](../guides/media-automation-setup.md) and
[Operate Plex direct remote access](../guides/plex-remote-access-operations.md).

## Immediate safety

The accepted native Sonos path reaches the Plex LoadBalancer on TCP `32400`. Keep that
boundary exact.

Do not:

- add broad any-to-any access between VLANs;
- add broad multicast reflection;
- expose SSDP toward the WAN;
- point Sonos at the internal Envoy Gateway;
- add an unauthenticated Plex network; or
- publish account details, client addresses, or raw Hubble output.

Plex SSDP/UPnP traffic to `239.255.255.250:1900` is deliberately blocked. This prevents
Plex from discovering a router and attempting automatic WAN mapping if router-side UPnP
is enabled accidentally. The supported Plex-for-Sonos paths do not require opening that
multicast flow.

## Authority

| Operation | Effect and authority |
| --- | --- |
| `mise exec -- just kube plex-verify` | Approved scoped verification of Plex workload, Service, route, DNS, TLS, and runtime controls; it does not test Sonos |
| `mise exec -- just kube plex-network-observe 600` | Operator-only bounded Hubble diagnostic; it prints private L3/L4 addresses and does not mutate the cluster |
| Plex or Sonos account relinking | Operator-managed external account mutation |
| Pi-hole, UniFi, VLAN, or SSID change | Operator-managed external network mutation |
| Plex Service or Cilium-policy change | Reviewed Git change |

## Diagnose

### 1. Establish the common Plex baseline

Run:

```bash
mise exec -- just kube plex-verify
```

Confirm an authenticated local client can browse the intended Music library and play a
track. If either check fails, repair Plex or the library before diagnosing Sonos.

### 2. Test the native Sonos path first

In the Sonos app, open the Plex service, select the intended Music library, and try one
browse and playback operation. If native Sonos succeeds, continue with
[Diagnose Plexamp control](#diagnose-plexamp-control).

If native Sonos fails, inspect these dependencies in order:

1. Confirm the Plex service in Sonos is still authorized to the intended Plex account
   and that account can access the Music library.
2. Confirm the Sonos network can reach the current Plex LoadBalancer on TCP `32400`.
   The destination must not be the internal Envoy Gateway or a retired Plex host.
3. Confirm the Sonos-side Plex discovery name is the current private LoadBalancer-derived
   `plex.direct` name.
4. Confirm Pi-hole permits that private `plex.direct` answer instead of removing it as
   DNS rebinding.
5. Retry browse before testing playback so account/library failure remains distinct from
   media compatibility.

The native Sonos service is cloud-mediated and requires a usable route back to Plex.
Native playback success proves that path and the speaker can use the library; it does
not prove Plexamp discovery or control.

### Diagnose Plexamp control

Use this path only after native Sonos playback works or the failure has otherwise been
isolated to Plexamp/player control.

Confirm:

- the controlling account has an active Plex Pass;
- it is a full Plex account, not a managed user;
- the Sonos account remains linked to that Plex account; and
- Plexamp is signed into the same intended account.

Plex currently requires the supported controlling Plex app to be on the same local
network as the Sonos player for initial account linking. After linking, Plexamp can
control Sonos as a receiver. See
[Control Sonos playback with a Plex app](https://support.plex.tv/articles/control-sonos-playback-with-a-plex-app/).

#### Restore or repeat Sonos account linking

This is a recovery action for a missing or stale link, not general first-time Plex
setup:

1. Temporarily connect the iPhone running a supported Plex app to an SSID mapped to the
   Sonos VLAN.
2. In that Plex app, open player selection and choose the Sonos linking action. UI labels
   can vary by app release.
3. Complete Sonos authorization with the intended full Plex account.
4. Confirm the Sonos player appears while the phone is still on the Sonos network.
5. Return the phone to its normal Wi-Fi network and confirm Plexamp still lists the
   player.
6. Remove the temporary Sonos-VLAN SSID if it existed only for this recovery.

If same-network linking succeeds but cross-VLAN control fails, observe the exact flows
before proposing any policy change:

```bash
mise exec -- just kube plex-network-observe 600
```

The command observes Plex L3/L4 flows for at most 600 seconds through a local Hubble
port-forward. Keep its output local. Use it to identify only the required protocol,
direction, player group, and destination ports. Do not widen policy speculatively when
the required flow cannot be established.

## Recover or mitigate

For a native Sonos failure:

- restore the intended Plex account/library authorization in the Sonos service;
- correct only the external route from the Sonos network to the Plex LoadBalancer on
  TCP `32400`;
- correct the private `plex.direct` answer or Pi-hole rebind handling; and
- retry browse, then playback.

For a Plexamp control failure:

- restore the supported full-account link on the Sonos network;
- force Plexamp to rediscover players after returning the phone to its normal network;
  and
- propose a reviewed, exact network change only when bounded observation proves a
  missing required flow.

Do not use AirPlay success as proof that native Plex-to-Sonos control was restored.

## Verify recovery

For native Sonos recovery, require:

- the Sonos Plex service can browse the intended library;
- the intended speaker plays a selected item;
- Plex or Tautulli records the session;
- local Plex playback remains healthy; and
- no broad VLAN, unauthenticated-network, or multicast exception was added.

For Plexamp recovery, also require:

- Plexamp lists and controls the intended Sonos player;
- playback uses native Sonos rather than AirPlay; and
- relevant Plex, Tautulli, Homepage, and Gatus views remain healthy.

`plex-verify`, Homepage, and Gatus provide supporting platform evidence. None of them
alone proves the repaired Sonos account, discovery, or playback boundary.

## Escalate

Stop rather than widen access when:

- supported same-network linking fails;
- account ownership or household roles are unclear;
- the exact required network flow cannot be established;
- DNS returns the wrong Plex path;
- the only apparent workaround requires broad multicast reflection or materially wider
  inter-VLAN access; or
- recovery would require risky changes to shared household account state.

Escalate to reviewed account, network, or application design work. Do not improvise a
new trust boundary inside this runbook.
