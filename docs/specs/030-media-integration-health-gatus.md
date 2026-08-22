# Media Integration Health with Gatus

## Historical boundary

This specification records the implemented Gatus redesign before the API-reachability
correction in specification 031. The six authenticated GET probes and their credential,
route, and metric architecture were implemented. The original four Servarr body
conditions were later removed, so their success semantics here do not describe current
source.

The intended `*NativeHealthIssue` alerts in this design were not implemented before the
successor changed their evidence boundary and names. Specification 031 is self-contained
for the current Servarr probes and implemented alerts.

## Design choice

The redesign replaced the custom collector and active POST probes in specifications 028
and 029 with six authenticated, non-mutating Gatus GET checks in group
`Media Integration`:

| Endpoint | Request | Original success conditions |
| --- | --- | --- |
| `prowlarr-native-health` | Prowlarr `GET /api/v1/health` | HTTP 200 and `len([BODY]) == 0` |
| `sonarr-native-health` | Sonarr `GET /api/v3/health` | HTTP 200 and `len([BODY]) == 0` |
| `radarr-native-health` | Radarr `GET /api/v3/health` | HTTP 200 and `len([BODY]) == 0` |
| `lidarr-native-health` | Lidarr `GET /api/v1/health` | HTTP 200 and `len([BODY]) == 0` |
| `seerr-sonarr-service-read` | Seerr `GET /api/v1/service/sonarr/0` | HTTP 200, `server.id == 0`, and `profiles` and `rootFolders` present |
| `seerr-radarr-service-read` | Seerr `GET /api/v1/service/radarr/0` | HTTP 200, `server.id == 0`, and `profiles` and `rootFolders` present |

All six ran once per minute, sent an application-specific `X-Api-Key`, and hid detailed
errors in the Gatus UI. The initial implementation used this exact endpoint and condition
set. The two Seerr body assertions remain part of current source; only the four Servarr
body-length assertions were replaced.

No collector, exporter, adapter package, custom image, Deployment, Service,
ServiceMonitor, metrics contract, or network policy was added. Prometheus continued to
scrape the existing Gatus ServiceMonitor and consume
`gatus_results_endpoint_success` through the stable `group` and `name` labels.

## Original assurance levels

The redesign separated four levels:

| Level | Evidence | Original interpretation |
| --- | --- | --- |
| 1 — availability | Existing unauthenticated Prowlarr, Sonarr, Radarr, and Lidarr `/ping` checks and Seerr status check | The application responded through its trusted route |
| 2 — native application health | Four authenticated Servarr health GETs with empty-array conditions | The application returned HTTP 200 and no native health entries |
| 3 — selected integration read | Two Seerr service-detail GETs | Seerr used its stored settings to read the selected Sonarr or Radarr service |
| 4 — deep workflow verification | Native Test actions, searches, requests, downloads, imports, and Plex refreshes | Stronger but potentially state-changing evidence remained outside continuous monitoring |

The fifteen-edge inventory from the collector design remained a gap map, not a promise
of fifteen independent probes. Under the original Level 2 interpretation, one Servarr
health result could be relevant to several edges but could not attribute a failure to a
specific Prowlarr, qBittorrent, Plex, indexer, or other provider.

## Credential boundary

One purpose-specific SOPS-encrypted Secret in namespace `gatus` contained exactly these
keys:

```text
prowlarr_api_key
sonarr_api_key
radarr_api_key
lidarr_api_key
seerr_api_key
```

Only the Gatus container received the Secret. Each key was projected through an explicit
`secretKeyRef` environment variable and appeared in configuration only as the matching
environment placeholder in an `X-Api-Key` header. No `envFrom` reference granted the
container the complete Secret implicitly.

The application API keys were broad upstream credentials. The purpose-specific Secret
limited their consumer and storage boundary; it did not make the underlying keys
read-only. Values were excluded from URLs, endpoint names, conditions, labels, events,
fixtures, logs, and documentation.

## Network and metrics path

The probes reused the Level 1 application hostnames and path:

```text
Gatus -> internal DNS -> internal HTTPS Gateway -> existing HTTPRoute -> media Service
```

They added authenticated paths and headers, not destinations. Gatus had no
`CiliumNetworkPolicy`, and the selected media paths already traversed the internal
Gateway. The design added neither direct Service-DNS probe paths nor a second probe
workload.

Gatus used in-memory history, so restarts could discard dashboard history. Prometheus
retained the continuously scraped success series intended for alerts. Neither history
surface exported response bodies or credentials as metric labels.

## Intended alert contract

The original design specified four 15-minute warning alerts named
`ProwlarrNativeHealthIssue`, `SonarrNativeHealthIssue`, `RadarrNativeHealthIssue`, and
`LidarrNativeHealthIssue`. Their intended evidence was a failed authenticated check that
required HTTP 200 and an empty native-health array. The annotations were to direct the
operator to application-native health details without naming an integration target.

It also specified `SeerrSonarrServiceReadFailed` and
`SeerrRadarrServiceReadFailed` after 15 minutes, plus
`MediaIntegrationProbeMissing` after five minutes of missing telemetry. The Seerr alerts
were bounded to selected read-through failure and did not prove that a request, download,
import, or later workflow step failed.

None of these media-integration alerts shipped with the initial six-probe implementation.
Before alert implementation, specification 031 replaced the four Servarr semantics and
the `*NativeHealthIssue` names. The later alert change implemented that successor
contract, the two unchanged Seerr alerts, and the missing-telemetry alert. Those
implemented effects belong to specification 031 rather than this historical contract.

## Original validation model

The implementation validator pinned the exact six endpoint names, group, GET methods,
URLs, one-minute interval, API-key placeholders, conditions, hidden-error behavior,
Secret metadata, Secret keys, and rendered `secretKeyRef` mappings. The initial mutation
test used empty and non-empty synthetic arrays as the independent oracle and rejected a
weakened Servarr body-length condition.

Those checks established the pre-successor source contract. The successor removed the
four body-length conditions and replaced the independent oracle with the status-only
truth table now described in specification 031. The stable endpoint, credential, route,
and Seerr validation remained.

## Why the Servarr semantics changed

Servarr includes informational update-availability entries in the same native health
array as operational entries. The original `len([BODY]) == 0` condition therefore made
routine update notices fail Level 2.

The deployed Gatus condition language could not safely filter every `UpdateCheck` entry
while rejecting every other entry in an arbitrary array. Fixed-index checks would depend
on order and length. Serialized-body matching would depend on JSON formatting and could
accept a mixed informational and operational result. Changing an application's release
branch only to make the probe green would also couple update policy to monitoring.

The successor retained the authenticated GETs but narrowed them to exact HTTP-200 API
reachability. It deliberately gave up continuous evaluation of Servarr health entries.
The Seerr conditions did not have this arbitrary-array problem and were retained.

## Historical consequences

The Gatus redesign avoided the proposed custom collector, adapter, workload, scrape
target, network policy, and continuous POST-test lifecycle while adding six authenticated
signals to an existing execution surface. Its first Servarr body contract proved too
broad for routine native health responses and was replaced before its intended alert
names were implemented.

No current Servarr condition or alert effect should be derived from this specification.
Specification 031 defines those exact current boundaries.
