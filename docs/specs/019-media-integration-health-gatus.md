# Media Integration Health with Gatus

## Historical boundary and outcome

This specification records the complete implemented Gatus lineage: the redesign that
replaced the custom collector and the API-reachability correction made after deployment
invalidated the initial Servarr body condition. The six authenticated GET probes and
their credential, route, cadence, metric, hidden-error, and Seerr condition architecture
remained unchanged through that correction.

The original four Servarr conditions required an empty native-health array. They were
implemented, but their intended `*NativeHealthIssue` alerts were not. Current source
uses status-only Servarr checks and four `*NativeHealthApiUnavailable` alerts. The two
Seerr read alerts and the missing-series alert were implemented without changing their
bounded evidence. Current source and operating documentation, not this historical
specification, remain authoritative for exact behavior.

## Problem and design choice

The [collector lineage](018-media-integration-health-collector.md) offered strong
classification and edge attribution, including a correction to attributable active
POST probes, but required a custom image, adapters for five uneven APIs, a new workload
and scrape target, policy, five credentials, fixtures, metrics, and recurring
authenticated tests. The reliable signals did not justify operating that integration
product.

The redesign chose the existing Gatus workload as the only continuous execution and
metrics surface. It added six authenticated, non-mutating GETs in group
`Media Integration`:

| Endpoint | Request | Initial condition | Final reconciled condition |
| --- | --- | --- | --- |
| `prowlarr-native-health` | Prowlarr `GET /api/v1/health` | HTTP 200 and `len([BODY]) == 0` | HTTP 200 only |
| `sonarr-native-health` | Sonarr `GET /api/v3/health` | HTTP 200 and `len([BODY]) == 0` | HTTP 200 only |
| `radarr-native-health` | Radarr `GET /api/v3/health` | HTTP 200 and `len([BODY]) == 0` | HTTP 200 only |
| `lidarr-native-health` | Lidarr `GET /api/v1/health` | HTTP 200 and `len([BODY]) == 0` | HTTP 200 only |
| `seerr-sonarr-service-read` | Seerr `GET /api/v1/service/sonarr/0` | HTTP 200, selected `server.id`, and `profiles` and `rootFolders` present | Unchanged |
| `seerr-radarr-service-read` | Seerr `GET /api/v1/service/radarr/0` | HTTP 200, selected `server.id`, and `profiles` and `rootFolders` present | Unchanged |

All six ran every minute, sent the application-specific key in `X-Api-Key`, and hid
detailed UI errors. Prometheus continued to scrape the existing Gatus ServiceMonitor and
consume `gatus_results_endpoint_success` through stable `group` and `name` labels. The
redesign added no collector, exporter, adapter package, custom image, Deployment,
Service, ServiceMonitor, metrics contract, or network policy.

This was an 80/20 choice: four shared application signals and two selected direct reads
using an operated workload, route, metric, and alert path. The cost was six reads per
minute and a purpose-specific encrypted credential copy. The accepted loss was detailed
failure classification and most edge attribution.

For the final four Servarr checks, any body has the same Gatus outcome when the response
status is 200: an empty array, informational or operational entries, a mixed array,
invalid JSON, or another response shape. Transport, DNS, TLS, route, authentication, or
non-200 application failures make the probe unsuccessful. The signal therefore proves
only that the authenticated health API path returned HTTP 200; it does not prove valid
JSON, clean native health, or a downstream integration.

## Assurance model and corrected evidence boundary

The design separated four levels:

| Level | Evidence | Final interpretation |
| --- | --- | --- |
| 1 — availability | Existing unauthenticated Prowlarr, Sonarr, Radarr, and Lidarr `/ping` checks and the Seerr status check | The application responded through its trusted route |
| 2 — authenticated API reachability | Four authenticated Servarr health GETs | The credentialed health API path returned HTTP 200; response contents are ignored |
| 3 — selected integration read | Two Seerr service-detail GETs | Seerr used its stored settings to read the selected Sonarr or Radarr service |
| 4 — deep workflow verification | Native Test actions, searches, requests, downloads, imports, and Plex refreshes | Stronger, potentially state-changing evidence outside continuous monitoring |

Level 1 remained an independent diagnostic signal. Level 2 was application-wide rather
than target-attributed and became narrower than originally intended. Level 3 was
stronger but covered only two selected services. Continuous monitoring would not call a
POST test, command, search, request, sync, create, update, or delete endpoint.

The fifteen-edge collector inventory remained a gap map, not a promise of fifteen
independent Gatus probes:

| Integration edge | Final continuous evidence | What it supports | Residual boundary |
| --- | --- | --- | --- |
| Prowlarr to Sonarr | Prowlarr authenticated health API | Credentialed API reachability only | No native-health or Sonarr attribution |
| Prowlarr to Radarr | Prowlarr authenticated health API | Same shared reachability evidence | No native-health or Radarr attribution |
| Prowlarr to Lidarr | Prowlarr authenticated health API | Same shared reachability evidence | No native-health or Lidarr attribution |
| Sonarr to Prowlarr | Sonarr authenticated health API | Credentialed API reachability only | No Prowlarr or indexer attribution |
| Radarr to Prowlarr | Radarr authenticated health API | Same shared reachability evidence | Same attribution limit |
| Lidarr to Prowlarr | Lidarr authenticated health API | Same shared reachability evidence | Same attribution limit |
| Sonarr to qBittorrent | Sonarr authenticated health API | Credentialed API reachability only | No qBittorrent or download proof |
| Radarr to qBittorrent | Radarr authenticated health API | Same shared reachability evidence | Same attribution limit |
| Lidarr to qBittorrent | Lidarr authenticated health API | Same shared reachability evidence | Same attribution limit |
| Sonarr to Plex | Sonarr authenticated health API | Credentialed API reachability only | No continuous Plex-notification proof |
| Radarr to Plex | Radarr authenticated health API | Same shared reachability evidence | Same event-driven limit |
| Lidarr to Plex | Lidarr authenticated health API | Same shared reachability evidence | Same event-driven limit |
| Seerr to Sonarr | Selected Seerr service read | Seerr read the selected Sonarr service with stored settings | No request or later workflow proof |
| Seerr to Radarr | Selected Seerr service read | Seerr read the selected Radarr service with stored settings | No request or later workflow proof |
| Seerr to Plex | None | No suitable off-the-shelf continuous signal | Operator-authorized deeper verification only |

The repeated Servarr rows are one shared signal mapped to relevant risks. Four checks do
not become twelve independent edge probes, and current Prometheus does not infer native
health or downstream connectivity from them.

## Why other endpoints and products were rejected

The redesign deliberately avoided recreating an adapter in YAML:

- Exportarr remained incomplete for Seerr and edge attribution. It could be reconsidered
  only after an observed failure showed a useful signal absent from these checks.
- Servarr `/system/status` added version and process facts, not a materially different
  operational result.
- Dynamic provider configuration and status APIs required provider interpretation and
  would turn Gatus conditions into application adapters.
- Unselected Seerr service-list routes showed stored configuration without performing
  the selected downstream read.
- Seerr Plex settings and scanner status did not prove the configured Plex path. Plex
  discovery alternatives added dynamic fan-out, external dependencies, unsafe response
  data, or version-specific mutation behavior.
- Native test POSTs could be non-persisting, as the collector lineage established, but
  keeping them would retain the custom selection and adapter lifecycle. Searches,
  commands, syncs, and transactions were state-changing by design.

The existing Gatus client timeout was retained. No response-time service-level objective
was added because the design selected correctness of a bounded read, not latency
monitoring.

## Credentials and route boundary

One purpose-specific SOPS-encrypted Secret in namespace `gatus` contained exactly five
keys for Prowlarr, Sonarr, Radarr, Lidarr, and Seerr. Only the Gatus container received
it. Each key entered the container through an explicit `secretKeyRef` environment
variable and appeared in configuration only as the matching `X-Api-Key` placeholder.
No `envFrom` reference granted implicit access to the whole Secret.

The source keys were broad application credentials. The narrower guarantee was only the
Secret's storage and consumer boundary; it did not make the upstream keys read-only.
Operator custody and the repository SOPS workflow remained authoritative. Keys and
ciphertext from another consumer were not to be copied as a substitute for a newly
managed artifact. Values were forbidden from URLs, names, conditions, labels, fixtures,
events, logs, and documentation.

Environment-backed values require Gatus process replacement after rotation; no secret
reloader or rollout stamp was added. This current limitation differs from the collector's
unimplemented file-reread proposal in specification 018.

The probes reused the established path:

```text
Gatus -> internal DNS -> trusted HTTPS Gateway -> existing HTTPRoute -> media Service
```

They added headers and authenticated paths, not destinations. Gatus had no Cilium policy,
and the existing Gateway path already served Level 1 probes, so no new policy was
justified. Live evidence still had to prove `X-Api-Key` forwarding and all six routes.
Failure of that gate required design reassessment, not silent fallback to direct Service
DNS, a new policy, or a second workload.

## Implementation discovery and semantic correction

Servarr includes informational update notices in the same native-health array as
operational entries. The implemented `len([BODY]) == 0` condition therefore made routine
update availability fail Level 2. The deployed Gatus condition language could not safely
express the required rule for an arbitrary array: ignore every entry whose `source` is
`UpdateCheck`, but fail on any other entry.

Fixed-index checks depended on ordering and length. Whole-body patterns depended on JSON
serialization and could incorrectly accept a mixed informational and operational result.
Changing an application's release branch merely to keep monitoring green would have
coupled update policy to the alert contract. A custom parser, transformer, or adapter
could recover the distinction, but adding another software component and lifecycle only
to interpret four small health arrays defeated the reason for choosing Gatus.

The final correction therefore retained all six endpoints and narrowed only the four
Servarr conditions to HTTP 200. It intentionally preserved the endpoint names,
authenticated headers, purpose-specific Secret, trusted Gateway path, one-minute cadence,
hidden-error behavior, ServiceMonitor, and stable metric labels. Keeping that working
collection path means a future off-the-shelf structured array filter can tighten the
body contract in place instead of forcing another monitoring-path redesign.

This is a deliberate assurance reduction. Routine update notices cannot make the four
checks red, but neither can operational health entries while the API still returns HTTP
200. The two bounded Seerr body assertions did not share the arbitrary-array defect and
remain stronger signals.

## Alert and metric semantics

The original design proposed four 15-minute warnings named
`ProwlarrNativeHealthIssue`, `SonarrNativeHealthIssue`, `RadarrNativeHealthIssue`, and
`LidarrNativeHealthIssue`. Those alerts were never implemented because their intended
evidence depended on the invalid empty-array condition.

Current media rules instead derive four warnings from the final status-only series:

| Alert | Series name | Hold | Effect |
| --- | --- | --- | --- |
| `ProwlarrNativeHealthApiUnavailable` | `prowlarr-native-health` | 15 minutes | The authenticated Prowlarr health API did not return HTTP 200 |
| `SonarrNativeHealthApiUnavailable` | `sonarr-native-health` | 15 minutes | The authenticated Sonarr health API did not return HTTP 200 |
| `RadarrNativeHealthApiUnavailable` | `radarr-native-health` | 15 minutes | The authenticated Radarr health API did not return HTTP 200 |
| `LidarrNativeHealthApiUnavailable` | `lidarr-native-health` | 15 minutes | The authenticated Lidarr health API did not return HTTP 200 |

The names and annotations deliberately avoid `NativeHealthIssue`: a zero result cannot
distinguish a route failure, rejected credential, application error, or another non-200
response and cannot identify Prowlarr, qBittorrent, Plex, an indexer, or another provider
as the cause.

`SeerrSonarrServiceReadFailed` and `SeerrRadarrServiceReadFailed` warn after 15 minutes
when their bounded selected-service reads fail. `MediaIntegrationProbeMissing` separately
warns after five minutes when any expected `Media Integration` success series is absent;
missing telemetry is not treated as a failed probe. None of these alerts authorizes
automatic remediation.

Gatus in-memory history can be lost on restart, while Prometheus retains scraped success
series for alert evaluation. Neither surface exports response bodies or credentials as
metric labels.

## Seerr evidence retained

The Seerr probes still require HTTP 200, `server.id == 0`, and the presence of `profiles`
and `rootFolders`. Their response is one bounded selected-service object rather than an
arbitrary array, so the body assertions remain safe and useful. They prove that Seerr
used its stored settings to read the selected Sonarr or Radarr service. They do not prove
that a request, download, import, or later workflow step succeeded. Seerr-to-Plex remains
a continuous-monitoring gap.

## Validation and acceptance boundary

The current validator pins the six endpoint names, group, GET methods, paths, one-minute
interval, key placeholders, hidden-error behavior, Secret metadata and keys, and rendered
`secretKeyRef` mappings. For each Servarr endpoint it requires exactly one
`[STATUS] == 200` condition and forbids body-dependent conditions. Its independent
synthetic oracle proves that HTTP 200 passes for empty, informational, operational, and
mixed bodies while a non-200 status fails. A mutation that restores a body-length
condition must fail validation.

Separate rule fixtures prove the alert holds, recovery, series isolation, exact labels
and annotations, and the missing-series signal. The historical synthetic oracle that
accepted an empty array and rejected a non-empty one was intentionally replaced rather
than retained as contradictory evidence.

Live acceptance required three consecutive successful cycles for all six probes, their
Prometheus series, and silent rules, with application health pages and selected Seerr
settings as independent comparisons. Repository rendering cannot prove live credentials,
Gateway header forwarding, application responses, or downstream Seerr access. If live
routing fails, the design stops rather than silently falling back to direct Service DNS,
a new policy, or another workload. The broader Gatus verifier intentionally does not
inspect these six histories or credentials.

## Consequences and reconsideration

The Gatus architecture avoids a custom software lifecycle while retaining broad source
keys, one execution surface, in-memory dashboard history, runtime discovery of response
drift, no Seerr-to-Plex signal, passive or event-driven provider evidence, no stable
target attribution, and no end-to-end workflow proof. Searches, native Test actions,
requests, downloads, imports, and Plex refreshes remain outside continuous monitoring.

Exportarr can be reconsidered after a concrete observed gap. Stronger Servarr continuous
assurance requires an existing or off-the-shelf monitoring layer with safe structured
array filtering plus an independent mixed-array oracle. Neither condition authorizes
restoring the old empty-array rule or the unimplemented `*NativeHealthIssue` alerts.
Additional endpoints and a response-time objective also remain deferred.
