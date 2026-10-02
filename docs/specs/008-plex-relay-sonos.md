# Plex Relay and Sonos Integration

## Relay fallback and identity

Plex Relay remains an outbound-only fallback to [direct remote access](013-plex-direct-remote-access.md).
Its limited bitrate, unsupported downloads, and incomplete client compatibility prevent
it from satisfying the full remote/Sonos objective. Successful transport does not prove
account linking or speaker reachability. [Plex source](../../kubernetes/apps/media/plex/)
owns workload, identity repair, and policy configuration.

Plex's numeric runtime UID was absent from the image's passwd file. The server tolerated
this, but its Relay child could not resolve its own user. An unprivileged init container
copies the image passwd file, adds the missing runtime identity, verifies it, and mounts
only that generated file read-only. Preserve the established storage/GPU UID rather than
changing privileges or replacing the image identity model. Plex owns its writable native
Relay key cache under `/config`; an injected raw Relay key is not a compatible repair.

Plex keeps retained exclusive-writer configuration, read-only media, local transcode
scratch, non-root execution, dropped capabilities, runtime seccomp, and no service-account
token. Read-only media preserves the media managers' removal authority and limits file
impact after compromise. A fully read-only root filesystem is not claimed.

## Containment rationale

Ingress admits only the declared consumers and the separately accepted direct listener.
Public HTTPS supports account, metadata, and Relay traffic; public TCP `32400` permits
Plex's native publication self-check. The source's excluded ranges keep these allowances
from becoming private-network access. Node CSI owns SMB, so Plex needs no SMB egress.

SSDP/UPnP multicast remains blocked to prevent Plex creating its own WAN mapping if
router UPnP is accidentally enabled. Losing DLNA discovery is accepted; the supported
Sonos path does not depend on SSDP. Observed flows supplement declared consumer contracts:
an idle import-triggered integration is not grounds to remove its allowance. Conversely,
an unseen Sonos flow is not grounds for speculative policy widening. Relay terminates
on pod loopback, so native Sonos playback can succeed with no Cilium ingress observation.

Private tailnet clients cannot substitute for Plex/Sonos cloud-service reachability.
Public tunnels still need compatible client authentication, names, and certificates;
additional hosts/proxies introduce distinct ownership and compromise boundaries.

## Recover Relay access

First require authenticated local browsing/playback and healthy `plex-verify`. Keep Relay
and Remote Access enabled, library authorization valid, and the approved secure-connection
setting. During an off-site client attempt run `mise exec -- just kube plex-relay-status`.
Interpret failure in order: no process suggests account/discovery/settings; authentication
failure suggests runtime identity or retained config; no allocated port suggests outbound
HTTPS or Relay service; allocated port without browse suggests client/discovery/authorization.
Playback failure can then reflect bitrate, transcoding, media, or client limits.

Require actual off-site browse/playback and activity showing Relay/indirect use; port
allocation alone is not acceptance. A deliberate Relay-only test requires operator removal
of the direct DNAT using [the direct-access rollback](013-plex-direct-remote-access.md#disable-exposure),
then later restoration and normal client acceptance. Preserve native key cache and
containment; do not add listeners or widen policy to repair Relay.

## Recover Sonos/Plexamp linking

Native Sonos library access and Plexamp player control are separate claims. First require
normal authenticated local Plex playback. Native Sonos must be authorized to the intended
library and reach the private Plex LoadBalancer on TCP `32400`, using the private
`plex.direct` discovery URL rather than the internal Gateway hostname. Pi-hole must
permit that private DNS answer.

Plexamp player control requires Plex Pass, a full Plex account, and the intended Sonos
account authorization. Initial linking needs a supported Plex client on the Sonos local
network; routed VLAN access does not replace that prerequisite. Temporarily place the
client there, complete authorization through its player menu, confirm the player appears,
then return the client and confirm continued Plexamp control. Remove any temporary SSID.

If linking works locally but cross-VLAN control fails, inspect exact missing flows with
an authorized bounded private diagnostic before a reviewed policy change. Do not add
broad VLAN rules, multicast reflection, or an unauthenticated Plex network. Finish by
requiring native Sonos browse/playback and Plexamp control without AirPlay when that is
the objective. [Plex's linking contract](https://support.plex.tv/articles/control-sonos-playback-with-a-plex-app/)
owns current supported client details.
