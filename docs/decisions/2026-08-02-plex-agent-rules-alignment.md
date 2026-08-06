# Plex agent-rules alignment

## Status

- **Status: Accepted.**
- Date: 2026-08-02

## Context

The accepted
[`Plex Relay and Sonos design`](2026-08-02-plex-relay-sonos-design.md) predates scoped
verification and the uncommitted-plan lifecycle. Its Relay repair, workload hardening,
and containment work were implemented; its Relay-first remote-path choice was later
partially superseded by the accepted
[`public Envoy amendment`](2026-08-03-plex-public-envoy-amendment.md).

## Decision

The original Plex record remains accepted for every decision not explicitly superseded
by the public Envoy amendment or clarified here.

### Retained Plex decisions

- Keep the init-generated passwd identity for numeric UID/GID `568`; Plex's native Relay
  key cache remains Plex-owned and is never seeded, replaced, or used as a rollout
  control.
- Keep non-root execution, RuntimeDefault seccomp, no service-account token, dropped
  capabilities, read-only shared media, an ephemeral transcode surface, and a retained
  single-writer config claim with `Recreate`.
- Keep Plex Relay enabled as a fallback and retain the Sonos integration goals. Relay is
  no longer the primary remote path, and any acceptance claim depending on Relay
  sufficiency remains superseded by the public Envoy amendment.
- Keep the rejection of Cloudflare Tunnel and Tailscale Funnel for media delivery.
- Keep the observed, source-declared Cilium containment model, including approved Envoy,
  Tautulli, Homepage, host-probe, DNS, and Plex-cloud paths and the deliberate SSDP/UPnP
  block recorded in
  [`Plex containment capture`](2026-08-03-plex-containment-capture.md).
- Keep Relay, native Sonos-to-Plex, Plexamp-to-Sonos, local-client behavior, and network
  containment as distinct acceptance concerns. Passing one does not imply another.

### Verification and acceptance

`verification.plex` is a diagnostic-tier, read-only suite in the canonical test catalog.
It uses diagnostic access for runtime identity and filesystem assertions; this does not
make it a rollout or a state-changing test.

Kubernetes and gateway `/identity` checks establish Plex process and routing liveness.
They do not prove a Relay session, native Sonos library playback, Plexamp control of a
Sonos player, client path selection, or the positive and negative containment scenario.
Those behaviors require their own independent acceptance evidence.

### Documentation lifecycle

The implementation plan is removed from Git only after preserving an exact local
execution copy under ignored `/plans/`. Its Relay identity and hardening work landed in
PR #177, and subsequent network containment landed in the accepted containment series.
Those source changes do not establish the plan's retained functional completion gates:
successful Relay allocation, cellular Plexamp playback, native Sonos library playback,
and Plexamp-to-Sonos playback without AirPlay. The public Envoy amendment supersedes the
Relay-first remote-path choice, but it does not silently complete or discard the retained
Sonos goals.

The ignored copy remains operationally useful and unstaged until those gates have durable
completion evidence or a later accepted decision explicitly supersedes them. Current
operator procedure remains in
[`docs/runbooks/plex-relay-sonos.md`](../runbooks/plex-relay-sonos.md).

No separate external review package was retained for the legacy Plex record. This
successor does not manufacture review files after the fact.

## Consequences

The legacy record stays byte-identical apart from its status line. Durable Plex design
remains distributed only where genuine supersession occurred: the original design, the
public Envoy amendment, the containment capture, and this lifecycle alignment record.
Unresolved retained completion gates remain in the exact ignored execution copy rather
than being misreported as executed.
