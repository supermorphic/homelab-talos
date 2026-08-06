# ntfy notification architecture

## Status

- **Status: Accepted.**
- Date: 2026-08-02

## Context

The cluster needed one private delivery layer for platform alerts and selected media
events without making every producer responsible for mobile-notification semantics.
Prompt iOS delivery also had to work without publishing the ntfy application directly to
the Internet.

## Decision

- Run one stateful ntfy instance with SQLite on a retained Longhorn ReadWriteOnce PVC.
  The workload uses `Recreate`; it is intentionally single-writer rather than presented
  as horizontally available.
- Keep non-secret server behavior in a checked-in `server.yml`. Require authentication,
  deny anonymous access by default, disable signup, and terminate TLS at the existing
  gateway.
- Provision users, topic ACLs, and tokens declaratively from an SOPS-encrypted Secret.
  The human `subscriber` is read-only on `critical`, `homelab`, and `media`;
  `alertmanager` and `seerr` receive distinct write-only tokens; Homepage receives a
  distinct read-only `critical` token. Each credential can be rotated or retired without
  widening another consumer.
- Keep ntfy private at the application layer. LAN clients use the internal Envoy path;
  off-site clients use the Tailscale-operated private path. No public Gateway is part of
  this decision.
- Enable ntfy's upstream wake-up path for the official iOS client. The self-hosted server
  retains message bodies; the upstream service carries only the wake-up material needed
  for the client to fetch them.
- Route Prometheus Alertmanager through the pinned `alertmanager-ntfy` transformer with
  synchronous forwarding. Raw Alertmanager webhook JSON is not a user notification, and
  delivery failure must remain visible to Alertmanager.
- Keep Alertmanager responsible for grouping, deduplication, inhibition, repeat timing,
  and resolved notifications. Critical alerts publish to `critical`; warnings publish to
  `homelab`.
- Keep Seerr as the only direct media producer. It publishes only media availability,
  request-processing failure, and issue reports to `media`. Direct `*arr`, qBittorrent,
  Plex, and Tautulli integrations are excluded so the notification surface does not
  fragment.
- Route Flux and platform health through Prometheus rules, not routine Flux event
  notifications.

## Consequences

Git plus the operator-held age identity is the recovery source for access control. The
ntfy database may retain useful cache state, but identity and authorization do not depend
on hand-recreating it. Producers have least-privilege credentials and one common mobile
delivery path.

Current credential lifecycle, client setup, verification, and rotation procedure lives
in [`docs/ntfy-startup-guide.md`](../ntfy-startup-guide.md). Flux-specific alerting is
recorded separately in
[`2026-08-02-flux-reconciliation-alerting.md`](2026-08-02-flux-reconciliation-alerting.md).
