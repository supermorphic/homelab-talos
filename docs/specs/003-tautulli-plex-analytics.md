# Tautulli Plex Analytics

## Intent and boundary

Tautulli records durable Plex session and watch history: user, item, time, client, and
Direct Play or transcode behavior. HTTP availability and Kubernetes metrics cannot
supply that history. [Application source](../../kubernetes/apps/media/tautulli/)
owns the workload, internal route, retained config claim, and integration wiring.

Tautulli is config-only. It reads Plex through its internal API and uses Plex account
services for authentication; it mounts neither media nor Plex configuration. The Plex
Logs viewer is deliberately unavailable because sharing Plex's `ReadWriteOncePod`
claim would weaken its single-writer database boundary. Losing Tautulli does not stop
Plex playback; losing its database loses accumulated history.

Web authentication is required because history contains private viewing and device data.
Plex tokens, login state, and Tautulli's API key live in application-managed retained
state. Homepage receives an independently managed encrypted credential copy.

## Health and acceptance

Require exact HTTP `200` from `/status` with redirects disabled through both Service
DNS and the internal Gateway. Kubernetes probes accept redirects, so pod readiness is
not an authentication-safe health oracle. The API-server Service proxy measures a
separate control-plane path and is unsuitable for this application check.

Media alerts distinguish an endpoint reporting failure from a vanished series and
monitor the retained Tautulli claim. Their separate Flux application prevents missing
Prometheus CRDs from blocking the media workload, as required by
[specification 015](015-alerting-architecture.md).

For an empty database, use [the suspended bootstrap lifecycle](006-media-stack-architecture.md#application-state-recovery),
complete supported first-run Plex authentication, connect the internal Plex hostname,
and require a visible library plus a real playback session recorded in history.
Keep source suspended until authentication, exact-status verification, and that functional
result pass; then activate through Git and rerun the verifier. Ordinary pod replacement
reuses the retained claim. For state loss, prefer a trusted isolated restore before
reinitialization.

Tautulli remains outside direct ntfy publishing. New event-specific delivery would need
value sufficient to justify a second notification policy outside Alertmanager silences,
grouping, inhibition, and resolution. Routine availability does not meet that boundary.
