# Media Integration Health with Gatus

## Purpose

Add bounded continuous evidence beyond media service availability without creating a
custom collector or exporter. The implemented redesign uses the existing Gatus workload,
ServiceMonitor, metric, trusted HTTPS routes, and alert delivery path.

This design replaced the custom collector and active-probe designs recorded in
specifications 028 and 029. The later API-reachability refinement in specification 031
defines the current exact Servarr success and alert semantics.

## Design choice

Gatus performs six authenticated, non-mutating GET checks in group
`Media Integration`:

| Endpoint | Request |
| --- | --- |
| `prowlarr-native-health` | Prowlarr `GET /api/v1/health` |
| `sonarr-native-health` | Sonarr `GET /api/v3/health` |
| `radarr-native-health` | Radarr `GET /api/v3/health` |
| `lidarr-native-health` | Lidarr `GET /api/v1/health` |
| `seerr-sonarr-service-read` | Seerr `GET /api/v1/service/sonarr/0` |
| `seerr-radarr-service-read` | Seerr `GET /api/v1/service/radarr/0` |

All six run once per minute, send an application-specific `X-Api-Key`, and hide detailed
errors in the Gatus UI. The current Servarr probes require only HTTP 200. The two Seerr
reads require HTTP 200, selected server ID `0`, and the presence of `profiles` and
`rootFolders`.

No collector, exporter, adapter package, custom image, Deployment, Service,
ServiceMonitor, metrics contract, or network policy was added. Prometheus continues to
scrape Gatus and consumes `gatus_results_endpoint_success` with only the stable `group`
and `name` labels.

## Assurance levels

The design separates four levels that must not be presented as equivalent:

| Level | Continuous or manual evidence | Boundary |
| --- | --- | --- |
| 1 — availability | Existing unauthenticated Prowlarr, Sonarr, Radarr, and Lidarr `/ping` checks and Seerr status check | The application responds through its trusted route |
| 2 — authenticated API reachability | Four Servarr health-API GETs | The route, endpoint, and supplied credential returned HTTP 200; response health entries are not evaluated |
| 3 — selected integration read | Two Seerr service-detail GETs | Seerr can use its stored downstream settings to read the selected Sonarr or Radarr service |
| 4 — deep workflow verification | Native Test actions, searches, requests, downloads, imports, and Plex refreshes | Stronger but potentially state-changing evidence kept outside continuous monitoring |

The fifteen-edge inventory from the earlier collector design remains useful as a gap
map. It is not a claim that six Gatus checks provide fifteen independent integration
signals. In particular, the four Servarr endpoints do not identify Prowlarr,
qBittorrent, Plex, an indexer, or another provider as a failing target.

## Servarr interpretation change

The first Gatus implementation paired HTTP 200 with `len([BODY]) == 0` for the four
Servarr health responses. That treated any native health entry as a failed probe. In
practice, Servarr includes informational update-availability entries in the same array.
The deployed Gatus condition language could not safely filter `UpdateCheck` entries while
rejecting every operational entry.

The repository removed the four body-length assertions. This preserved credentialed
API-path evidence and avoided coupling release-channel policy to operational monitoring.
Specification 031 records the current truth table, alert names, and reduced coverage.
The Seerr body assertions were not removed because they check a bounded selected-service
response rather than a generic health-entry array.

## Credential boundary

One purpose-specific SOPS-encrypted Secret in namespace `gatus` contains exactly these
keys:

```text
prowlarr_api_key
sonarr_api_key
radarr_api_key
lidarr_api_key
seerr_api_key
```

Only the Gatus container receives the Secret. Each key is projected through an explicit
`secretKeyRef` environment variable and appears in configuration only as the matching
environment placeholder in an `X-Api-Key` header. No `envFrom` reference grants the
container the complete Secret implicitly.

The application API keys are broad upstream credentials. The purpose-specific Secret
limits their consumer and storage boundary; it does not make the underlying keys
read-only. Values must not appear in URLs, endpoint names, conditions, labels, events,
fixtures, logs, or documentation.

## Network and metrics path

The probes reuse the same application hostnames and route as Level 1:

```text
Gatus -> internal DNS -> internal HTTPS Gateway -> existing HTTPRoute -> media Service
```

They add authenticated paths and headers, not destinations. Gatus has no
`CiliumNetworkPolicy`, and the selected media paths already traverse the internal
Gateway. The design does not add direct Service-DNS probe paths or a second probe
workload.

Gatus uses in-memory history, so restarts can discard dashboard history. Prometheus
retains the continuously scraped success series used for alerts. Neither history surface
stores response bodies or credentials as metric labels.

## Alert architecture

The media alerts application consumes the six Gatus series. Four warning alerts cover a
15-minute Servarr authenticated-API failure, two warning alerts cover a 15-minute Seerr
selected-service read failure, and `MediaIntegrationProbeMissing` covers five minutes of
missing telemetry for any expected series.

These rules authorize no remediation. A Servarr alert reports authenticated API
unavailability, not a native-health or integration issue. A Seerr alert reports failure
of the selected read-through, not failure of a request, download, import, or full media
workflow. The missing-series alert reports telemetry loss rather than application or
integration failure.

## Validation model

Source validation fixes the exact six endpoint names, group, GET methods, URLs,
one-minute interval, API-key placeholders, conditions, hidden-error behavior, Secret
metadata, Secret keys, and rendered `secretKeyRef` mappings. Mutation tests reject a
missing or extra endpoint, a mutating method, a body-dependent Servarr condition, a wrong
key placeholder, and a wrong rendered Secret reference.

Promtool fixtures use the exact rule source and independently cover each alert's hold,
recovery, isolation from the other five series, annotations, and missing-series behavior.
These source tests cannot prove live credentials, Gateway header forwarding,
application-owned configuration, or downstream Seerr access.

## Rejected alternatives and consequences

The custom collector was rejected because its adapter, image, workload, scrape target,
network policy, API compatibility, and credential lifecycle cost exceeded the bounded
signals selected here. Exportarr did not cover the same application set or selected
Seerr reads. Continuous POST tests and end-to-end transactions were rejected because
they add API behavior or durable work to continuous monitoring.

The current design accepts no continuous Seerr-to-Plex evidence, no generic target
attribution from Servarr, no evaluation of Servarr native health entries, and no proof
of searches, requests, downloads, imports, or Plex refreshes. In return, it adds six
authenticated reads and one encrypted credential boundary to software and metrics paths
the cluster already operates.
