# Media integration health with Gatus — successor decision

- **Status: Accepted.** Approved by the operator on 2026-08-16.

Date: 2026-08-16.
Branch: `dispatch-media-integration-health-decision`.

Supersedes
[Media integration health active probes — successor decision](2026-08-16-media-integration-health-active-probes.md)
and replaces the combined effective specification formed by that record and
[Media integration health — decision](2026-08-16-media-integration-health.md).

This record completes the redesign of Stage 5 deferred by §8 of
[Alerting architecture — decision](2026-08-13-alerting-architecture.md).

## 1. Decision

Use the existing Gatus workload as the only continuous Stage 5 execution and metrics
surface. Add six authenticated, non-mutating `GET` checks:

1. Prowlarr `GET /api/v1/health`.
2. Sonarr `GET /api/v3/health`.
3. Radarr `GET /api/v3/health`.
4. Lidarr `GET /api/v1/health`.
5. Seerr `GET /api/v1/service/sonarr/{selectedId}`.
6. Seerr `GET /api/v1/service/radarr/{selectedId}`.

Continue to use the existing Gatus ServiceMonitor and
`gatus_results_endpoint_success` metric. Prometheus rules interpret only the stable
Gatus `group` and `name` labels. They do not parse native provider names, health
messages, URLs, response fragments, or dynamic application configuration.

Do not add a collector, exporter, application adapter, custom source package, custom
image, image registry workflow, Deployment, Service, ServiceMonitor, or metrics
contract. Exportarr is not part of this design. It can be reconsidered only if a future
observed failure needs a concrete signal that the selected Gatus checks cannot provide.

The fifteen-edge inventory remains a coverage and residual-risk map. It is not a promise
of fifteen continuous or attributable integration probes.

## 2. Four assurance levels

### Level 1 — service availability

Keep the existing unauthenticated Gatus checks unchanged:

- Prowlarr, Sonarr, Radarr, and Lidarr use `/ping`;
- Seerr uses `/api/v1/status`.

These checks answer: **Is the application reachable and responding through the trusted
HTTPS route?** They do not expose application health or downstream integration state.

### Level 2 — native application health

The four authenticated Servarr health checks answer: **Is the application currently
reporting one or more native operational health problems?**

These are application-level signals. Native health can include application sync,
indexer, download-client, notification, storage, configuration, or other application
checks. Gatus does not attribute a non-empty result to a specific provider or target.
Alerts direct the operator to the application's native health details.

### Level 3 — selected direct integration evidence

The two Seerr service-detail checks answer: **Can Seerr use its stored downstream URL and
credential to read the selected Sonarr or Radarr service?**

They are stronger than application health because Seerr performs downstream reads. They
do not create or approve a request and do not prove download, import, library update, or
the complete media workflow.

### Level 4 — deep verification

Keep native Test actions, synthetic searches, Seerr requests, downloads, imports, Plex
refreshes, and end-to-end workflow transactions operator-run. Continuous monitoring must
not call a POST test, command, search, request, sync, create, update, or delete endpoint.

## 3. Signal and coverage matrix

| Integration edge | Continuous evidence | What the evidence can support | Residual boundary |
|---|---|---|---|
| Prowlarr -> Sonarr | Prowlarr native health | Prowlarr reports no current native health issue | A failure is not attributable to Sonarr without inspecting native details |
| Prowlarr -> Radarr | Prowlarr native health | Same application-level evidence | Same attribution limit |
| Prowlarr -> Lidarr | Prowlarr native health | Same application-level evidence | Same attribution limit |
| Sonarr -> Prowlarr | Sonarr native health | Sonarr reports no current native health issue | A failure does not identify Prowlarr or one indexer |
| Radarr -> Prowlarr | Radarr native health | Radarr reports no current native health issue | Same attribution limit |
| Lidarr -> Prowlarr | Lidarr native health | Lidarr reports no current native health issue | Same attribution limit |
| Sonarr -> qBittorrent | Sonarr native health | Application-level download-client problems can become visible | A failure does not identify qBittorrent or prove a download failed |
| Radarr -> qBittorrent | Radarr native health | Same application-level evidence | Same attribution limit |
| Lidarr -> qBittorrent | Lidarr native health | Same application-level evidence | Same attribution limit |
| Sonarr -> Plex | Sonarr native health | Application-level notification problems can become visible | Evidence is event-driven and does not continuously prove Plex access |
| Radarr -> Plex | Radarr native health | Same application-level evidence | Same event-driven limit |
| Lidarr -> Plex | Lidarr native health | Same application-level evidence | Same event-driven limit |
| Seerr -> Sonarr | Seerr selected-service read-through | Seerr can read its selected Sonarr service with stored integration settings | Does not prove a request or later workflow stages |
| Seerr -> Radarr | Seerr selected-service read-through | Seerr can read its selected Radarr service with stored integration settings | Does not prove a request or later workflow stages |
| Seerr -> Plex | None | No clean continuous OTS signal is selected | Explicit residual gap; operator-run verification only |

The native-health rows deliberately repeat shared evidence. Four native-health checks do
not become twelve independent integration checks merely because their results are
relevant to twelve inventory edges.

## 4. Exact probe semantics

Use Gatus group `Media Integration` and these stable endpoint names:

| Endpoint name | Request | Success conditions | Detection and interpretation limits |
|---|---|---|---|
| `prowlarr-native-health` | `GET https://prowlarr.lab.supermorphic.com/api/v1/health` with `X-Api-Key` | HTTP 200 and a decoded top-level JSON array with zero entries | The GET reads cached native state; time to the source application's next relevant action is not bounded |
| `sonarr-native-health` | `GET https://sonarr.lab.supermorphic.com/api/v3/health` with `X-Api-Key` | HTTP 200 and an empty native health array | Same passive-state boundary |
| `radarr-native-health` | `GET https://radarr.lab.supermorphic.com/api/v3/health` with `X-Api-Key` | HTTP 200 and an empty native health array | Same passive-state boundary |
| `lidarr-native-health` | `GET https://lidarr.lab.supermorphic.com/api/v1/health` with `X-Api-Key` | HTTP 200 and an empty native health array | Same passive-state boundary |
| `seerr-sonarr-service-read` | `GET https://seerr.lab.supermorphic.com/api/v1/service/sonarr/{selectedId}` with `X-Api-Key` | HTTP 200, returned `server.id` equals the configured selected ID, and `profiles` and `rootFolders` fields exist | Proves selected read access only; avoid content, count, path, tag, and version assertions |
| `seerr-radarr-service-read` | `GET https://seerr.lab.supermorphic.com/api/v1/service/radarr/{selectedId}` with `X-Api-Key` | Same bounded conditions for Radarr | Same workflow boundary |

Run all six at the established one-minute Gatus interval. Use the existing Gatus client
timeout unless live read-only verification shows that the documented downstream reads
need a larger bounded timeout. Do not add a response-time service-level objective as part
of this stage.

Any non-empty native health array makes that endpoint unsuccessful. Gatus does not parse
the entries. A transport, TLS, authentication, route, status, or response-shape failure
also makes the endpoint unsuccessful. The operator uses the Level 1 probe and native
application health page to distinguish these causes. Set the authenticated endpoints to
hide detailed errors in the Gatus UI; response bodies must not become alert annotations
or Prometheus labels.

## 5. Credentials and SOPS boundary

Create one purpose-specific SOPS-encrypted Kubernetes Secret in namespace `gatus`. It
contains exactly these data keys:

```text
prowlarr_api_key
sonarr_api_key
radarr_api_key
lidarr_api_key
seerr_api_key
```

The operator creates and encrypts the values through the repository's established SOPS
workflow. Do not read, print, copy, decrypt, re-encrypt, or reuse Homepage ciphertext.
The source applications remain authoritative for their broad API keys; the narrower
purpose is the new Secret and its only consumer, not a claim that the application keys
themselves are read-only.

Inject the five keys only into the existing Gatus container through Kubernetes
`secretKeyRef` environment variables. Gatus configuration contains environment
placeholders and sends each value only as an `X-Api-Key` request header. Do not place a
key in a URL, ConfigMap value, condition, endpoint name, metric label, event, test
fixture, or log.

No other workload receives the Secret. Normal API-key rotation requires the operator to
update the SOPS artifact, allow Flux to apply it, and restart or roll the Gatus Pod so
environment-based values are reloaded. Do not add a secret-reload controller or custom
rotation mechanism for this stage.

## 6. Existing network path

Use the same trusted HTTPS hostnames and internal Gateway path that the current Level 1
Gatus checks already use:

```text
Gatus -> internal DNS -> trusted HTTPS Gateway -> existing HTTPRoute -> media Service
```

The six checks add authenticated paths and headers, not new network destinations. Gatus
has no current CiliumNetworkPolicy, and the media applications except Plex have no policy
that blocks this established Gateway path. No new NetworkPolicy is justified by the
current source or live-cluster evidence.

Live rollout verification must prove that the Gateway forwards `X-Api-Key` and that all
six paths work without changing routing or policy. If that evidence fails, stop and
reassess the design. Do not silently add direct Service-DNS access, a custom policy, or a
second probe workload.

## 7. Alerts and wording

Place the rules in the existing media alerts application and use the existing Gatus
metric. All are `severity: warning`; none authorizes automatic remediation.

The four native-health alerts use a fifteen-minute sustained failure:

| Alert | Summary | Required description boundary |
|---|---|---|
| `ProwlarrNativeHealthIssue` | Prowlarr native health is not clean | The authenticated Prowlarr health check has not returned HTTP 200 with an empty native health result for 15 minutes. Inspect Gatus access and Prowlarr's native health details. This alert does not identify an integration target. |
| `SonarrNativeHealthIssue` | Sonarr native health is not clean | Same boundary for Sonarr; do not name Prowlarr, qBittorrent, Plex, or another provider. |
| `RadarrNativeHealthIssue` | Radarr native health is not clean | Same boundary for Radarr. |
| `LidarrNativeHealthIssue` | Lidarr native health is not clean | Same boundary for Lidarr. |

The two direct read-through alerts also use a fifteen-minute sustained failure:

| Alert | Summary | Required description boundary |
|---|---|---|
| `SeerrSonarrServiceReadFailed` | Seerr cannot read its selected Sonarr service | The authenticated Gatus read-through through Seerr has failed for 15 minutes. It does not prove that a Seerr request, download, or import failed. |
| `SeerrRadarrServiceReadFailed` | Seerr cannot read its selected Radarr service | Same boundary for the selected Radarr service. |

Add `MediaIntegrationProbeMissing` with a five-minute hold. It reports the exact missing
`Media Integration` Gatus endpoint name for any of the six expected success series. It
does not report an application or integration failure.

Existing Level 1 availability alerts remain unchanged. Promtool tests must prove each
new alert's hold time, recovery, exact labels and annotations, isolation from the other
five probes, and missing-series behavior.

## 8. Additional GET endpoints

Add no other endpoints by default.

- Servarr `/system/status` provides version, start-time, and platform information but no
  materially different operational result from the existing availability and native
  health checks.
- Provider configuration or provider-status APIs require dynamic interpretation and
  target attribution. They would turn Gatus YAML into an application adapter.
- Seerr's unselected service-list routes return stored configuration without performing
  the downstream read and are weaker than the selected service-detail routes.
- Seerr Plex settings and scanner-status GETs expose local state, not the configured Plex
  path. The reviewed Plex discovery alternatives have dynamic fan-out, external
  dependencies, unsafe response data, or version-specific mutation behavior.

POST test endpoints, searches, commands, syncs, and settings changes are outside the
continuous design even when an upstream application describes them as tests.

## 9. Implementation footprint and validation boundary

The intended source change is limited to:

- six Gatus endpoint definitions;
- one SOPS Secret manifest with the five named encrypted keys;
- five Secret-backed environment variables on the existing Gatus workload;
- media Prometheus rules over existing Gatus metrics;
- promtool and focused source-validation coverage;
- residual-risk and operator-verification documentation.

Source validation must prove the exact six endpoint names, GET methods, paths, one-minute
intervals, header placeholders, stable conditions, and absence of extra Stage 5 endpoints
or mutating methods. It must validate Secret metadata and references without inspecting
plaintext. A focused independent assertion must accept an empty native health result and
reject a non-empty result; do not build an application-response fixture matrix.

Before alerts are enabled, operator-run live verification must observe at least three
consecutive successful cycles for all six probes, confirm all six Prometheus series, and
confirm the new rules are silent. It must compare native-health results with the four
application health pages and selected Seerr service settings without creating a request
or running a native Test action.

`mise exec -- just ci` remains the cluster-independent gate. Live credentials,
application-owned health state, Gateway header forwarding, and downstream Seerr access
cannot be proven by repository rendering and remain operator-run rollout gates.

## 10. Residual gaps and consequences

This design accepts:

- no continuous Seerr-to-Plex evidence;
- passive and event-driven latency before Servarr native health records a provider
  problem;
- no stable target attribution from generic native health results;
- no continuous proof of searches, requests, downloads, imports, Plex refreshes, or the
  full workflow;
- five broad application API keys in the existing Gatus workload;
- a single Gatus workload as the execution and metrics surface;
- upstream route or response changes discovered at runtime rather than through a custom
  compatibility framework.

The benefit is an 80/20 operational layer with four application-native health signals
and two selected integration reads, using software, metrics, alert delivery, validation
patterns, and network paths already present in the cluster. The cost is one encrypted
credential boundary and six authenticated GETs per minute, not a new software product or
image lifecycle.
