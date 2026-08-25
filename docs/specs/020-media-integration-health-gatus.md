# Media Integration Health with Gatus

## Historical boundary and outcome

This specification records the implemented Gatus redesign before the
[API-reachability correction](021-media-integration-health-api-reachability.md). The six
authenticated GET probes and their credential, route, metric, and Seerr condition
architecture were implemented. The original four Servarr conditions required an empty
native-health array. Those body conditions are historical and are not current source.

The four intended alerts named `ProwlarrNativeHealthIssue`, `SonarrNativeHealthIssue`,
`RadarrNativeHealthIssue`, and `LidarrNativeHealthIssue` were never implemented. Current
source instead implements the successor's four `*NativeHealthApiUnavailable` alerts.
The two Seerr read alerts and the missing-series alert were later implemented without
changing their bounded evidence. Specification 021 is authoritative for the current
Servarr conditions, coverage claims, validation rule, and alert effect.

## Problem and design choice

The [collector](018-media-integration-health-collector.md) and its
[active-probe revision](019-media-integration-health-active-probes.md) offered strong
classification and edge attribution, but required a custom image, adapters for five
uneven APIs, a new workload and scrape target, policy, five credentials, fixtures,
metrics, and recurring authenticated POST tests. The reliable signals did not justify
operating that integration product.

The redesign chose the existing Gatus workload as the only continuous execution and
metrics surface. It added six authenticated, non-mutating GETs in group
`Media Integration`:

| Endpoint | Request | Historical initial success conditions |
| --- | --- | --- |
| `prowlarr-native-health` | Prowlarr `GET /api/v1/health` | HTTP 200 and `len([BODY]) == 0` |
| `sonarr-native-health` | Sonarr `GET /api/v3/health` | HTTP 200 and `len([BODY]) == 0` |
| `radarr-native-health` | Radarr `GET /api/v3/health` | HTTP 200 and `len([BODY]) == 0` |
| `lidarr-native-health` | Lidarr `GET /api/v1/health` | HTTP 200 and `len([BODY]) == 0` |
| `seerr-sonarr-service-read` | Seerr `GET /api/v1/service/sonarr/0` | HTTP 200, selected `server.id`, and `profiles` and `rootFolders` present |
| `seerr-radarr-service-read` | Seerr `GET /api/v1/service/radarr/0` | HTTP 200, selected `server.id`, and `profiles` and `rootFolders` present |

All six ran every minute, sent the application-specific key in `X-Api-Key`, and hid
detailed UI errors. Prometheus continued to scrape the existing Gatus ServiceMonitor and
consume `gatus_results_endpoint_success` through stable `group` and `name` labels. The
redesign added no collector, exporter, adapter package, custom image, Deployment,
Service, ServiceMonitor, metrics contract, or network policy.

This was an 80/20 choice: four shared application signals and two selected direct reads
using an operated workload, route, metric, and alert path. The cost was six reads per
minute and a purpose-specific encrypted credential copy. The accepted loss was detailed
failure classification and most edge attribution.

## Original assurance model

The design separated four levels:

| Level | Evidence | Historical initial interpretation |
| --- | --- | --- |
| 1 — availability | Existing unauthenticated Prowlarr, Sonarr, Radarr, and Lidarr `/ping` checks and the Seerr status check | The application responded through its trusted route |
| 2 — native application health | Four authenticated Servarr health GETs with empty-array conditions | The application returned HTTP 200 and no native health entries |
| 3 — selected integration read | Two Seerr service-detail GETs | Seerr used its stored settings to read the selected Sonarr or Radarr service |
| 4 — deep workflow verification | Native Test actions, searches, requests, downloads, imports, and Plex refreshes | Stronger, potentially state-changing evidence outside continuous monitoring |

Level 1 remained an independent diagnostic signal. Level 2 was application-wide rather
than target-attributed. Level 3 was stronger but covered only two selected services.
Continuous monitoring would not call a POST test, command, search, request, sync, create,
update, or delete endpoint.

The fifteen-edge collector inventory remained a gap map, not a promise of fifteen
independent Gatus probes:

| Integration edge | Historical continuous evidence | What it could support | Residual boundary |
| --- | --- | --- | --- |
| Prowlarr to Sonarr | Prowlarr native health | No native health entry at poll time | No attribution to Sonarr |
| Prowlarr to Radarr | Prowlarr native health | Same shared application evidence | No attribution to Radarr |
| Prowlarr to Lidarr | Prowlarr native health | Same shared application evidence | No attribution to Lidarr |
| Sonarr to Prowlarr | Sonarr native health | No Sonarr native health entry at poll time | No attribution to Prowlarr or one indexer |
| Radarr to Prowlarr | Radarr native health | No Radarr native health entry at poll time | Same attribution limit |
| Lidarr to Prowlarr | Lidarr native health | No Lidarr native health entry at poll time | Same attribution limit |
| Sonarr to qBittorrent | Sonarr native health | Application-level client problems could appear | No proof of a qBittorrent or download failure |
| Radarr to qBittorrent | Radarr native health | Same shared application evidence | Same attribution limit |
| Lidarr to qBittorrent | Lidarr native health | Same shared application evidence | Same attribution limit |
| Sonarr to Plex | Sonarr native health | Notification problems could appear | Event-driven; no continuous Plex proof |
| Radarr to Plex | Radarr native health | Same shared application evidence | Same event-driven limit |
| Lidarr to Plex | Lidarr native health | Same shared application evidence | Same event-driven limit |
| Seerr to Sonarr | Selected Seerr service read | Seerr read the selected Sonarr service with stored settings | No request or later workflow proof |
| Seerr to Radarr | Selected Seerr service read | Seerr read the selected Radarr service with stored settings | No request or later workflow proof |
| Seerr to Plex | None | No suitable off-the-shelf continuous signal | Operator-authorized deeper verification only |

The repeated native-health rows were one shared signal mapped to relevant risks. Four
checks did not become twelve independent edge probes.

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
- Native test POSTs could be non-persisting, as specification 019 argued, but keeping
  them would retain the custom selection and adapter lifecycle. Searches, commands,
  syncs, and transactions were state-changing by design.

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

## Historical alert and metric semantics

The original Level 2 design specified four 15-minute warning alerts named
`ProwlarrNativeHealthIssue`, `SonarrNativeHealthIssue`, `RadarrNativeHealthIssue`, and
`LidarrNativeHealthIssue`. Their intended evidence combined HTTP 200 with an empty native
array. Their wording could direct an operator to Gatus and native application details but
could not name a downstream target.

Two other 15-minute warnings described selected Seerr read-through failures, and
`MediaIntegrationProbeMissing` distinguished five minutes of missing telemetry from a
failed probe. None authorized automatic remediation. Gatus in-memory history could be
lost on restart, while Prometheus retained scraped success series for alerts. Neither
surface exported response bodies or credentials as metric labels.

The six probes initially shipped without the media-integration alert rules. Before those
rules were implemented, specification 021 removed the four Servarr body assertions and
replaced the unimplemented `*NativeHealthIssue` contract. Current
`*NativeHealthApiUnavailable` alerts must not be read as renamed versions with the old
native-health semantics.

## Original validation and acceptance gates

Source validation pinned the exact six names, group, GET methods, paths, one-minute
interval, key placeholders, conditions, hidden-error behavior, Secret metadata and keys,
and rendered `secretKeyRef` mappings. An independent synthetic oracle accepted an empty
array, rejected a non-empty array, and mutation-tested weakening of the body condition.
That was the historical Level 2 contract, not the current validator behavior.

Live acceptance required three consecutive successful one-minute cycles for all six
probes, six Prometheus series, and silent rules. Application health pages and selected
Seerr settings were the independent comparison. Repository rendering could not prove
live credentials, Gateway header forwarding, application responses, or downstream Seerr
access. If live routing failed, the design stopped rather than expanding its network
surface.

Specification 021 replaced only the four Servarr conditions, their native-health
coverage claims, the corresponding synthetic oracle, and four alert definitions. The
six-name, credential, route, hidden-error, metric, Seerr, and live-acceptance boundaries
remained. The current Gatus verifier proves broader workload, route, dashboard, and
foundation facts; it intentionally does not inspect these six histories or credentials.

## Discovery, consequence, and reconsideration

Servarr includes informational update notices in the same native-health array as
operational entries. The historical `len([BODY]) == 0` condition therefore made routine
update availability fail Level 2. The deployed Gatus condition language could not safely
ignore every `UpdateCheck` entry while rejecting every other entry in an arbitrary
array. Fixed indexes depended on ordering and length. Serialized-body matching depended
on JSON formatting and could accept a mixed informational and operational result.
Changing release policy merely to keep monitoring green was also rejected.

Specification 021 retained the authenticated route and credential signal but narrowed
the four Servarr checks to HTTP 200. That is a deliberate assurance reduction from this
native-health design, not its original intent. The two bounded Seerr body assertions did
not share the arbitrary-array defect and remain stronger current signals.

The Gatus architecture avoided a custom software lifecycle, but it retained broad keys,
one execution surface, in-memory dashboard history, runtime discovery of response drift,
no Seerr-to-Plex signal, passive or event-driven provider evidence, no stable target
attribution, and no end-to-end workflow proof. Additional continuous endpoints and a
response-time objective remained deferred.

Exportarr could be reconsidered after a concrete observed gap. A future stronger Servarr
condition requires safe structured filtering and an independent mixed-array oracle.
Neither criterion authorizes restoring the old empty-array rule or the unimplemented
`*NativeHealthIssue` alerts.
