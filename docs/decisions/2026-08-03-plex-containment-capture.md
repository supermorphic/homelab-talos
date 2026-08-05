# Plex containment capture — evidentiary basis and multicast block

## Status

- **Status: Accepted.** Both decisions below were made by the operator on 2026-08-03
  during review of the phase-1 Hubble capture, and the operator approved this record
  on 2026-08-04.
- Date: 2026-08-03
- Branch: `investigate-plex-remote-access`

This record revises no accepted text. It records two operator decisions that the
phase-1 capture for the Plex CiliumNetworkPolicy made necessary, both deviations
from — or clarifications of — what
[Plex public Envoy and split-horizon remote access — amendment](2026-08-03-plex-public-envoy-amendment.md)
§7 anticipates. The amendment remains in force unchanged.

## 1. Context

Amendment §7.1 makes the Plex network policy's allow-list underivable from Git and
requires that it come from a Hubble capture containing an Apple TV session, a
Plexamp session, a **native Sonos session**, a Tautulli poll, a Homepage widget
refresh, a Gatus probe, and kubelet probes — "and from nothing else."

The operator ran the capture while exercising the consumer set. Reviewing it
against the planned policy surfaced two findings the amendment and the
implementation plan did not anticipate. Each needed an operator decision before the
policy could be written.

## 2. Finding one: a native Sonos session is unobtainable

Native Sonos playback produced **zero** ingress flows to `plex:32400` across the
capture. That is consistent with the fault under investigation: native Sonos cannot
currently reach Plex, so no capture can contain a native Sonos session until the
experiment this design enables has succeeded. The §7.1 prerequisite as written is
unobtainable.

Every observed ingress source mapped to a stable, designed selector; nothing
required a CIDR guess:

| Observed source identity | Maps to |
|---|---|
| `envoy-gateway-system` pod owned by Gateway `internal` | namespace plus owning-gateway labels |
| `media` pod `app.kubernetes.io/name=tautulli` | namespace plus application labels |
| node host | `fromEntities: [host]` |

No LAN client, Sonos included, arrived directly at the pod.

**Operator decision: proceed, and record the deviation.** The allow-list is derived
from the observed capture plus the two designed identities that observation cannot
supply:

- Homepage — the one consumer §7.1 derives from Git (its widget annotation is the
  only manifest reference to `plex:32400`), and a hard row in the client
  acceptance matrix.
- The Envoy owner label `public` — unobservable because the public Gateway does not
  exist yet; required by the approved architecture the policy must not later
  contradict.

Gatus and LAN clients arrive through the internal Envoy owner label by design.

**Risk accepted.** If restored native Sonos playback arrives by a path the policy
does not admit, it fails closed and surfaces immediately as acceptance-matrix row
3 — never silently. The policy cannot regress native Sonos below its current
state, because that state is zero observed flows. The merge gate for the
containment change re-observes the full consumer set, native Sonos included,
before the policy is relied on.

## 3. Finding two: Plex emits SSDP/UPnP discovery, and the policy blocks it

The capture showed the Plex pod sending UDP `1900` to the SSDP multicast address
`239.255.255.250` — Plex hunting for a UPnP Internet Gateway Device, that is,
trying to create its own WAN port forward. The planned egress admits only cluster
DNS and TCP `443` to public IPv4 with multicast (`224.0.0.0/4`) excluded, so this
flow is denied on both address class and protocol. Neither the amendment nor the
plan named it.

**Operator decision: keep the block.** The experiment's phase 0 requires
UPnP/NAT-PMP disabled on the router, and a Plex-created UPnP mapping is an
immediate-rollback trigger. Denying the pod's SSDP egress is defence in depth:
even if router UPnP were re-enabled by accident, Plex could not reach a gateway
device to request a mapping.

**Consequence accepted.** Anything that would discover Plex via SSDP on the LAN —
notably Plex's DLNA server, if it were enabled — cannot function while the policy
is enforced. The Plex-for-Sonos path in the approved design is cloud-mediated and
does not depend on SSDP.

## 4. What the capture otherwise confirmed

- The only off-cluster egress observed was Plex-cloud HTTPS on TCP `443`, which the
  planned rule admits. No SMB, no NTP, and no unexpected-port egress appeared.
- No pod-level SMB egress exists: the media share is mounted by the CSI driver on
  the node, confirming §7.2's assumption rather than leaving it to be checked
  after enforcement.

## 5. Binding scope

Both decisions bind the containment implementation (PR 2 of the plan) and its
merge gate. If the permanence decision later retains public remote access, the
SSDP block stands unless a new accepted decision lifts it; the capture-basis
deviation is spent once the merge gate re-observes the full consumer set with the
policy in place.
