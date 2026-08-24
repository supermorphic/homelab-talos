# Tautulli Plex Analytics

## Purpose

Provide durable Plex watch history and session analytics inside the media platform.
Tautulli records who watched an item, when it played, which client was used, and whether
Plex direct-played or transcoded it. This fills a functional gap that HTTP probes and
Kubernetes workload metrics cannot observe.

The database began empty. No historical Tautulli data was imported.

## Application design

Tautulli runs as one `Recreate` Deployment in the `media` namespace. It uses the pinned
`ghcr.io/home-operations/tautulli:2.17.2` image, listens on port `8181`, and stores its
SQLite database and settings on a retained 5 Gi Longhorn `ReadWriteOnce` claim mounted
at `/config`.

The application is config-only. It mounts neither the shared media claim nor Plex's
configuration claim. Tautulli reads Plex through
`http://plex.media.svc.cluster.local:32400` and reaches `plex.tv` for account and token
validation. The absence of a Plex config mount deliberately makes Tautulli's Plex Logs
viewer unavailable; mounting Plex's `ReadWriteOncePod` claim into a second workload
would violate the stronger single-writer boundary around the Plex database.

Flux depends on `media` and `internal-gateway`, not `media-storage` or the Plex
Kustomization. Those dependencies establish the namespace, chart source, and route
attachment point without treating runtime API availability as deployment ordering.

## Security and runtime configuration

The pod and container run as UID and GID `568`. Privilege escalation is disabled and all
Linux capabilities are dropped. The workload requests `25m` CPU and 256 MiB memory,
limits memory to 1 GiB, and has no CPU limit.

The internal Gateway publishes `tautulli.lab.supermorphic.com`. Web authentication is
required because watch history contains user, device, client-address, and viewing data.
The implemented Plex OAuth administrator mode preserves exact HTTP `200` responses from
`/status`, with redirects disabled, through both the Service and the Gateway.

The Plex token, web credential, and Tautulli API key are application-managed runtime
state on the config claim. Homepage receives a separate SOPS-encrypted API-key Secret;
the Kubernetes source does not contain those plaintext values.

## Health and observability

Readiness, liveness, and startup probes use `/status` on port `8181`. Kubernetes accepts
HTTP 3xx responses as probe success, so a green pod alone cannot prove that
authentication has not redirected the health path. The read-only verifier therefore
requires exact HTTP `200` responses with redirects disabled. This independent check is
the authority for the route's liveness contract.

Gatus checks the internal user path once per minute, and Homepage displays live session
data through its dedicated API key. Media alerting provides:

- sustained availability coverage for active Media-group Gatus endpoints;
- a dedicated missing-series alert for Tautulli; and
- a warning when the retained `media/tautulli` claim is absent or not Bound.

Media alert rules live in the separate `media-alerts` Flux Kustomization, which depends
on `kube-prometheus-stack`. This prevents a missing Prometheus Operator CRD from
blocking reconciliation of Tautulli or the rest of the media applications.

Tautulli does not publish directly to ntfy. Direct delivery would bypass Alertmanager's
grouping, deduplication, inhibition, and silences and would create a second notification
control plane. This choice can be reconsidered if remote-access reliability or
account-sharing events justify event-specific notifications that the metrics path
cannot represent.

## Validation model

Offline validation checks the image, resources, security context, retained config-only
storage, probes, internal route, activation-aware Homepage and Gatus integrations, and
rendered chart output. The media policy rejects any later shared-media or Plex-volume
mount. Prometheus rule tests exercise alert timing and label matchers from the same rule
source used by the cluster.

Read-only live verification checks Flux and Helm readiness, rollout, route acceptance,
DNS, exact Service and Gateway status responses, Gatus series, and loaded rule health.
Functional acceptance remains separate: authentication must work, a Plex library must
be connected, and a real playback session must appear in history.

## Consequences

The retained config claim preserves watch history across pod replacement and node
rescheduling. The service gains session awareness without access to media files or the
Plex database. Losing the config claim loses the greenfield history, while losing
Tautulli itself does not affect Plex playback.

Current setup, authentication, API-key, and acceptance procedure belongs in
`docs/guides/media-automation-setup.md`.
