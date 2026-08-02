# Plex Relay and Sonos operator runbook

Use this runbook after the reviewed Plex Relay values change has reconciled. It
implements the approved [Plex Relay and Sonos design](../decisions/2026-08-02-plex-relay-sonos-design.md);
that decision remains the source for the trust-boundary diagrams and security
rationale. Do not duplicate or move those diagrams here.

Plex Relay is an outbound, Plex-operated path. It is not public Plex ingress:
do not add a UniFi WAN DNAT, public Service, Tailscale Funnel, Cloudflare Tunnel,
or a VPS for this rollout.

## Preconditions and scope

- The reviewed manifest uses `ghcr.io/home-operations/plex:1.43.3.10828` at
  tested index digest
  `sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7`.
- Its unprivileged init container generates an `/etc/passwd` file with the
  UID/GID `568` Plex identity and mounts only that generated file read-only in
  the app container. Plex owns and writes its native Relay-key cache under
  `/config`; do not replace it with a mounted or Git-managed raw Relay key.
- Media is read-only to Plex. The pod has no service-account token and uses the
  reviewed non-root, dropped-capabilities, and RuntimeDefault seccomp controls.
- These are operator-only, guarded cluster commands. Do not use raw `kubectl`,
  `flux`, `helm`, or `talosctl`.

## Plex server settings

Set or retain these settings in Plex:

| Setting | Required value |
|---|---|
| Remote Access | enabled |
| Manually specify public port | disabled |
| Enable Relay | enabled |
| Secure connections | `Required` if the Sonos gate passes; otherwise `Preferred` |
| Strict TLS configuration | enable only after Plexamp and Sonos acceptance |
| Allowed without auth | empty |
| Remote streams allowed per user | `2` |
| Custom server access URL | `https://plex.lab.supermorphic.com` |

`LAN Networks` and **Treat WAN IP as LAN Bandwidth** are bandwidth
classification settings. They are not firewall, authentication, or cross-VLAN
discovery controls. In particular, neither setting authorizes a CIDR without
authentication.

## Acceptance gates

Record the outcome of each gate independently. Passing Relay acceptance does
not prove Sonos account linking or local discovery.

### Gate 1 — Remote library through Relay

1. Run `mise exec -- just kube plex-verify`.
2. While initiating a remote client request, run
   `mise exec -- just kube plex-relay-status` and retain only its sanitized
   output. Confirm the UID/key preflight and Relay lifecycle evidence.
3. Disable iPhone Wi-Fi and Tailscale, force-quit Plexamp, reopen it, browse
   Music, and play one track.

Gate 1 proves remote library playback over cellular through Relay.

### Gate 2 — Plex inside the native Sonos app

1. In the Sonos app, open Plex, select the Music library under **Other
   Libraries** if needed, browse, and play to a Sonos Port.

Gate 2 proves the Plex-for-Sonos service can reach and use the library.

### Gate 3 — Sonos players inside Plexamp

Gate 3 requires Plex Pass. Failure before the same-subnet OAuth step is not
evidence that Relay failed.

1. Connect the iPhone temporarily to an SSID mapped to VLAN 20. In the regular
   supported Plex iOS app, open Players, select the Sonos link entry, and
   complete Sonos OAuth with the full Plex account.
2. Return the iPhone to Main Wi-Fi. In Plexamp, verify the intended Sonos
   players appear and play one track without AirPlay.
3. Remove the temporary VLAN-20 SSID if one was created.

Gate 3 is the separate Sonos account-linking and local discovery/control
acceptance. Do not expand VLAN access or add a multicast reflector as a
troubleshooting shortcut.

## Observe flows before policy work

Network-policy enforcement is deferred to a separate, later gate. Capture the
normal flows first, including library scanning, Relay playback, native Sonos
playback, Plexamp-to-Sonos playback, and metadata activity. Run this bounded,
read-only observation while reproducing those actions:

```bash
mise exec -- just kube plex-network-observe 300
```

The duration is an integer from `1` through `600` seconds; use the shortest
period that captures the action. The command uses a local Hubble port-forward
and prints L3/L4 compact flow data only—no packet payloads—and ends at the
specified duration. Preserve the needed flow evidence without credentials,
tokens, account identifiers, or unrelated request paths. A flow-observer
failure is diagnostic evidence, not permission to widen network access.

## Failure interpretation

Use sanitized `plex-relay-status` output and the functional result to classify
the problem before changing anything:

| Evidence | Boundary |
|---|---|
| no `startRelay` event | Plex account/cloud/discovery |
| child exits before authentication | local identity/key/process |
| authenticated, no allocated port | Plex Relay service/path |
| allocated port, client cannot browse | client/account/library authorization |
| native Sonos can browse, Plexamp has no Sonos entry | Sonos account linking/local discovery |

Do not print or retain Plex tokens, account identifiers, email addresses, or
unrelated request paths in the acceptance record.

## Rollback and prohibitions

Rollback is a Git revert of the Plex values commit through a reviewed PR. Do
not patch the Deployment, suspend Flux, mount a raw Relay key, enable an
unauthenticated CIDR, or open TCP `32400` as troubleshooting. A public-ingress
fallback requires a new operator-approved design and reviewed change; it is not
part of this runbook.

## Static validation before handoff

Run only the cluster-independent checks for this documentation change:

```bash
mise exec -- just repo links-validate
mise exec -- just repo lint
mise exec -- just ci
```

All three must pass. These commands do not perform a live cluster operation;
the acceptance gates above remain deferred for an operator to run after the
reviewed rollout.
