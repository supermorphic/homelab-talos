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

These boundaries were deliberate choices among broader alternatives. Tautulli reused
the config-only media-application pattern because it consumes Plex through its API, not
through media or Plex storage. Alert rules were isolated in `media-alerts` because
placing Prometheus rules beside each application, or adding monitoring dependencies to
every media application, would enlarge the monitoring failure domain. One generic
`MediaEndpointDown` rule avoided hand-maintained per-application down rules, while Plex
and Tautulli received explicit missing-series coverage because their retained state made
silent telemetry loss more consequential. Direct ntfy delivery was rejected as a second
notification-control plane outside Alertmanager lifecycle policy.

## Security and runtime configuration

The pod and container run as UID and GID `568`. Privilege escalation is disabled and all
Linux capabilities are dropped. The workload requests `25m` CPU and 256 MiB memory,
limits memory to 1 GiB, and has no CPU limit.

That allocation was inherited from Seerr rather than measured for Tautulli. Revisit the
memory limit when watch-history growth or observed memory pressure supplies evidence.

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

This placement is a failure-domain boundary, not a directory preference. Flux dry-runs
the objects in one Kustomization together. Putting a `PrometheusRule` beside an
application could therefore make an unavailable Prometheus CRD block that application's
entire reconciliation. Adding `kube-prometheus-stack` as a dependency of every media
application would avoid the CRD error but couple serving and automation workloads to the
monitoring release. Isolating the rules lets monitoring fail without preventing the
media applications from reconciling.

The alert model distinguishes a failed series from a missing series. The generic
application `MediaEndpointDown` expression produces one alert for each reporting Media
endpoint whose value is zero, except `qbittorrent-vpn`. That endpoint has dedicated
critical down and warning missing-series rules. A group-wide `absent()` expression is
only a canary for loss of every Media series; it cannot detect one silently removed
endpoint while another still reports. Within the original application-availability rule
set, Plex and Tautulli therefore have explicit missing-series rules because their
retained claims hold the state this design is intended to protect. Other ordinary media
application endpoints have generic down detection but no implied per-endpoint
disappearance coverage. Later Media Integration monitoring has a separate rule that
enumerates every expected integration series for missing telemetry.

Ordinary media availability is a `warning`: an outage is operational degradation, not
by itself a data-loss or privacy event. `critical` remains reserved for materially
different failure classes involving data or privacy risk, so ordinary Tautulli and media
availability follows the normal homelab warning path.

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

The 15-minute availability window was selected from a plausible normal Plex replacement:
up to two minutes for clean shutdown plus image and startup time made five to eight
minutes of healthy rollout downtime realistic. A shorter alert would train operators to
ignore expected deploy noise. Rule tests extract PromQL from the deployed manifest
instead of copying it into a second rules file, then prove the pre-threshold, firing, and
recovered states. Exact-status verification and Prometheus rule evaluation are separate
oracles: kubelet's 200–399 probe success cannot establish either one.

The first rollout also disproved the Kubernetes API server's Service proxy as an
application oracle. It returned HTTP `503` while the Deployment, backend, HTTPRoute, and
Gateway path were healthy because it measured the unrelated API-server-to-ClusterIP path
on this kube-proxy-free Cilium cluster. The corrected verifier measures the in-cluster
Service-DNS path from the running Tautulli workload and checks the Gateway path
separately.

Read-only live verification checks Flux and Helm readiness, rollout, route acceptance,
DNS, those separate exact Service and Gateway status responses, Gatus series, and loaded
rule health.
Functional acceptance remains separate: authentication must work, a Plex library must
be connected, and a real playback session must appear in history.

## Consequences

The retained config claim preserves watch history across pod replacement and node
rescheduling. The service gains session awareness without access to media files or the
Plex database. Losing the config claim loses the greenfield history, while losing
Tautulli itself does not affect Plex playback. Tautulli is therefore non-critical to
media serving, but its accumulated database becomes irreplaceable historical state after
deployment. That distinction is why the retained claim receives persistence monitoring
even though a Tautulli workload outage is only an availability warning.

The lineage intentionally excludes watch-history import, newsletters, a stream metrics
exporter, and broad smoke, resilience, or automated playback tests. Another generic
smoke test would substantially duplicate the application verifier, while generic
resilience coverage would mostly retest the existing Longhorn plus `Recreate` behavior
owned elsewhere. Meaningful Plex/Tautulli end-to-end acceptance requires an actual
playback session and observation of the resulting history, so real authentication, Plex
library visibility, and one recorded playback remain a human functional oracle that
source validation cannot prove.

Reconsider direct ntfy publication only for valuable event-shaped signals that the
metrics path cannot represent, especially remote-access reliability or account-sharing
events. The value must justify losing Alertmanager's shared grouping, inhibition,
silences, and resolved lifecycle. Buffering or transcode tuning and informational
recently-added events do not meet that boundary on their own. Tautulli remains outside
direct notification delivery unless a later design accepts that second policy surface.

Current setup, authentication, API-key, and acceptance procedure belongs in
`docs/guides/media-automation-setup.md`.
