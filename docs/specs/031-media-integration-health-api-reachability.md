# Media Integration Health API Reachability

## Purpose

Define the current self-contained Level 2 contract for authenticated Servarr health API
checks and the alerts derived from them. The essential boundary is exact: HTTP 200 is
success, and the response body does not affect Gatus success.

## Exact Servarr probe contract

The existing Gatus workload runs these four endpoints in group `Media Integration` once
per minute:

| Endpoint name | Request | Credential | Only success condition |
| --- | --- | --- | --- |
| `prowlarr-native-health` | `GET https://prowlarr.lab.supermorphic.com/api/v1/health` | `GATUS_PROWLARR_API_KEY` in `X-Api-Key` | `[STATUS] == 200` |
| `sonarr-native-health` | `GET https://sonarr.lab.supermorphic.com/api/v3/health` | `GATUS_SONARR_API_KEY` in `X-Api-Key` | `[STATUS] == 200` |
| `radarr-native-health` | `GET https://radarr.lab.supermorphic.com/api/v3/health` | `GATUS_RADARR_API_KEY` in `X-Api-Key` | `[STATUS] == 200` |
| `lidarr-native-health` | `GET https://lidarr.lab.supermorphic.com/api/v1/health` | `GATUS_LIDARR_API_KEY` in `X-Api-Key` | `[STATUS] == 200` |

Each endpoint uses `ui.hide-errors: true`. Each environment variable comes from its
matching key in the SOPS-encrypted `gatus-media-integration-api-keys` Secret. The
requests follow the established internal DNS, trusted HTTPS Gateway, HTTPRoute, and
application Service path.

An empty array, one or more `UpdateCheck` entries, an operational health entry, a mixed
array, invalid JSON, or any other body has the same Gatus outcome when the response status
is 200. A non-200 response or transport, DNS, TLS, route, or authentication failure makes
the probe unsuccessful. The probe does not prove that the response is valid JSON, that
native health is clean, or that a downstream integration works.

No `[BODY] == []`, `len([BODY]) == 0`, message match, fixed-index source check, source
allow-list, or serialized-response pattern belongs in these four endpoints.

## Why body assertions were removed

Servarr reports routine update availability in the same native health array as
operational entries. Treating every non-empty array as failure made release-channel state
look like an operational incident.

The deployed Gatus condition engine cannot express the required safe structured rule:
ignore every entry whose `source` is `UpdateCheck`, but fail on any other entry in an
arbitrary array. Fixed-index checks fail when ordering or length changes. Whole-body
patterns depend on JSON serialization and can incorrectly accept a mixed informational
and operational result. Changing an application's release branch only to make monitoring
green would couple update policy to the alert contract.

The selected tradeoff is explicit. Status-only success removes false failures from
routine update notices and preserves proof of the authenticated API path, but it stops
Gatus from evaluating every Servarr native health entry. A future structured body rule
would need a safe array-filter capability and independent mixed-array evidence.

## Current alert effect

The media alerts application derives four warning alerts directly from the four Gatus
success series:

| Alert | Series name | Hold | Effect |
| --- | --- | --- | --- |
| `ProwlarrNativeHealthApiUnavailable` | `prowlarr-native-health` | 15 minutes | Reports that the authenticated Prowlarr health API has not returned HTTP 200 |
| `SonarrNativeHealthApiUnavailable` | `sonarr-native-health` | 15 minutes | Reports the same boundary for Sonarr |
| `RadarrNativeHealthApiUnavailable` | `radarr-native-health` | 15 minutes | Reports the same boundary for Radarr |
| `LidarrNativeHealthApiUnavailable` | `lidarr-native-health` | 15 minutes | Reports the same boundary for Lidarr |

All four use `severity: warning`. Their annotations direct investigation toward Gatus
access, routing, authentication, and the application. They state that the alert does not
evaluate native health entries or identify an integration target.

The former `*NativeHealthIssue` names were removed from the design because they
overstated a status-only metric. A value of zero cannot distinguish a route failure,
rejected credential, application error, or another non-200 response, so the alerts do
not name Prowlarr, qBittorrent, Plex, an indexer, or another provider as the cause.

`MediaIntegrationProbeMissing` is a separate warning after five minutes of absence for
any expected `Media Integration` success series. It reports missing telemetry and does
not substitute absence for a failed probe.

## Seerr boundary retained alongside Level 2

The same Gatus group also contains two stronger selected-service reads:

| Endpoint | Success conditions |
| --- | --- |
| `seerr-sonarr-service-read` | HTTP 200, `server.id == 0`, and `profiles` and `rootFolders` fields present |
| `seerr-radarr-service-read` | HTTP 200, `server.id == 0`, and `profiles` and `rootFolders` fields present |

These GETs use the Seerr API key and Seerr's stored downstream configuration. Their body
assertions remain because the response has one bounded selected-service shape rather than
an arbitrary health-entry array. They provide direct read-through evidence for the
selected Sonarr and Radarr services, but do not prove that a Seerr request, download,
import, or later workflow step succeeded.

`SeerrSonarrServiceReadFailed` and `SeerrRadarrServiceReadFailed` warn after 15 minutes of
failure. They are unaffected by the Servarr status-only refinement.

## Coverage after refinement

The four authenticated probes provide a signal beyond unauthenticated `/ping`: the
trusted route, health endpoint, and supplied credential produced HTTP 200. They no longer
provide continuously evaluated evidence for the twelve inventory edges previously
associated with Prowlarr, Sonarr, Radarr, and Lidarr native health. Operators can inspect
those applications' native health state separately, but Prometheus does not infer it
from these four success series.

Seerr-to-Sonarr and Seerr-to-Radarr retain direct read evidence. Seerr-to-Plex remains a
continuous-monitoring gap. Searches, native Test actions, requests, downloads, imports,
Plex refreshes, and end-to-end transactions remain outside continuous monitoring.

## Validation contract

The Gatus validator requires exactly one `[STATUS] == 200` condition and no body-dependent
condition on each Servarr endpoint. Its focused test proves that HTTP 200 passes for empty,
informational, operational, and mixed synthetic bodies while a non-200 status fails. A
mutation that adds a body-length condition must fail validation.

The same validation pins endpoint names, GET methods, paths, intervals, key placeholders,
hidden-error behavior, Secret metadata, and rendered `secretKeyRef` mappings. Separate
promtool fixtures prove each alert's 15-minute hold, recovery, series isolation, exact
labels and annotations, and the five-minute missing-series signal.

These checks establish source and rule semantics. They do not claim current live API
responses, credentials, Gateway forwarding, or application integration state.

## Consequences

Routine Servarr update notices cannot make the four endpoints red. Operational entries
also cannot make them red while the API still returns HTTP 200. This is a deliberate
reduction in assurance, not an implicit health claim.

The design retains a credentialed path signal, the two stronger Seerr reads, stable Gatus
metrics, and accurate alert wording without adding a parser, adapter, or new workload.
Detection of native Servarr issues now depends on application inspection, other existing
telemetry, or authorized deeper verification.
