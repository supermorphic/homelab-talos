# Media integration health API reachability — successor decision

- **Status: Accepted.** Approved by the operator on 2026-08-17.

Date: 2026-08-17.
Branch: `dispatch-media-integration-health-decision`.

Supersedes only the Level 2 success semantics, related coverage claims, validation
requirements, and four future alert definitions in
[Media integration health with Gatus — successor decision](2026-08-16-media-integration-health-gatus.md).
All other decisions in that record remain in force.

## 1. Decision

Keep the four authenticated Servarr `GET /health` probes in the existing Gatus
workload, but require only HTTP 200. Do not inspect the response body when Gatus
determines probe success.

The four probes now answer:

> Is the authenticated native-health API reachable and responding successfully?

They do not answer:

> Is the application currently reporting no native operational health issues?

Servarr includes informational update-availability entries in its native health
array. The deployed Gatus condition engine cannot safely ignore entries whose
structured `source` is `UpdateCheck` while rejecting every other entry. It supports
whole-array length and fixed-index checks, but not an array filter, predicate, or
conditional expression suitable for this rule. Raw-response pattern matching would
depend on JSON serialization and could accept a mixed informational and operational
result. Do not add that brittle parsing.

Release-channel and update policy remain separate from operational monitoring. Do
not change an application's update branch merely to make a Gatus result successful.

## 2. Exact probe semantics

Keep the existing Gatus group, endpoint names, methods, URLs, intervals, headers,
Secret references, and hidden-error behavior:

| Endpoint name | Request | Success condition | Evidence boundary |
|---|---|---|---|
| `prowlarr-native-health` | `GET https://prowlarr.lab.supermorphic.com/api/v1/health` with `X-Api-Key` | `[STATUS] == 200` | The trusted HTTPS route, API endpoint, and supplied credential produced HTTP 200 |
| `sonarr-native-health` | `GET https://sonarr.lab.supermorphic.com/api/v3/health` with `X-Api-Key` | `[STATUS] == 200` | Same authenticated API-reachability evidence |
| `radarr-native-health` | `GET https://radarr.lab.supermorphic.com/api/v3/health` with `X-Api-Key` | `[STATUS] == 200` | Same authenticated API-reachability evidence |
| `lidarr-native-health` | `GET https://lidarr.lab.supermorphic.com/api/v1/health` with `X-Api-Key` | `[STATUS] == 200` | Same authenticated API-reachability evidence |

An empty array, one or more `UpdateCheck` entries, any other native health entries,
a mixed array, or any other response body all have the same Gatus outcome when the
HTTP status is 200. Gatus must fail the probe for a non-200 response or transport
failure. The probe does not claim that the response is valid JSON or that the native
health state is clean.

Do not add `[BODY] == []`, `len([BODY]) == 0`, message matching, fixed-index source
checks, a source whitelist, or serialized-body patterns.

The two selected Seerr read-through probes remain unchanged. They continue to check
HTTP 200, the selected service ID, and the presence of `profiles` and `rootFolders`.
They remain the stronger direct integration signals.

## 3. Coverage and operator interpretation

The four authenticated Servarr probes provide a credentialed API-path signal beyond
the existing unauthenticated `/ping` availability checks. They do not continuously
evaluate the native health entries returned by that API and do not provide an
integration-edge failure signal.

For the fifteen-edge inventory:

- Seerr to Sonarr and Seerr to Radarr retain their selected-service read-through
  evidence.
- The twelve edges previously associated with Prowlarr, Sonarr, Radarr, and Lidarr
  native-health results no longer have a continuously evaluated integration-health
  signal from these four probes. Their API responses remain available for operator
  inspection.
- Seerr to Plex remains an explicit residual gap.

Operator-run native Test actions, searches, requests, downloads, imports, Plex
refreshes, and end-to-end workflow transactions remain unchanged and unscheduled.

## 4. Credentials, workload, and network boundary

Keep the existing purpose-specific SOPS Secret and its five keys unchanged. Keep the
five `secretKeyRef` environment variables and use the values only in `X-Api-Key`
request headers. Do not decrypt, rewrite, duplicate, or broaden access to the Secret.

Keep the established trusted HTTPS Gateway paths. This successor adds no destination,
route, NetworkPolicy, workload, image, exporter, transformer, adapter, or custom
logic. It does not change the Gatus ServiceMonitor or metrics contract.

Retaining the endpoints and credential plumbing permits a future successor to tighten
the body condition if a deployed Gatus version gains a safe structured array filter.
Such a change must prove the required mixed-array behavior and must not introduce
message matching or a growing source whitelist.

## 5. Future alert contract

Replace the four unimplemented native-health alert definitions with authenticated
API-availability alerts. Use a fifteen-minute sustained failure and `severity:
warning`:

| Alert | Summary | Required description boundary |
|---|---|---|
| `ProwlarrNativeHealthApiUnavailable` | Prowlarr authenticated health API is unavailable | The authenticated Prowlarr health API has not returned HTTP 200 for 15 minutes. Inspect Gatus access, routing, authentication, and the application. The alert does not evaluate native health entries or identify an integration target. |
| `SonarrNativeHealthApiUnavailable` | Sonarr authenticated health API is unavailable | Same boundary for Sonarr. |
| `RadarrNativeHealthApiUnavailable` | Radarr authenticated health API is unavailable | Same boundary for Radarr. |
| `LidarrNativeHealthApiUnavailable` | Lidarr authenticated health API is unavailable | Same boundary for Lidarr. |

Do not implement or retain alerts named `ProwlarrNativeHealthIssue`,
`SonarrNativeHealthIssue`, `RadarrNativeHealthIssue`, or
`LidarrNativeHealthIssue`. Those names overstate what the status-only probes prove.

The two Seerr read-through alert definitions and `MediaIntegrationProbeMissing`
remain unchanged.

## 6. Validation and rollout gates

Independent source validation must prove that each of the four Servarr endpoints has
exactly `[STATUS] == 200` and no body-dependent condition. A focused behavioral test
must establish this truth table for the Gatus contract:

```text
HTTP 200 + []                                  -> healthy
HTTP 200 + [UpdateCheck]                       -> healthy
HTTP 200 + [UpdateCheck, UpdateCheck]          -> healthy
HTTP 200 + [DownloadClientCheck]               -> healthy
HTTP 200 + [IndexerStatusCheck]                -> healthy
HTTP 200 + [UpdateCheck, DownloadClientCheck]  -> healthy
non-200 + any body                             -> unhealthy
```

The cases containing operational entries pass because Gatus is no longer evaluating
native health content. Tests must describe that evidence boundary rather than imply
that those application states are operationally healthy.

Keep the existing validation of endpoint names, methods, authenticated paths,
one-minute intervals, API-key placeholders, Secret references, hidden errors, and the
two Seerr response conditions. Run `mise exec -- just ci` before the implementation
pull request.

After rollout, observe at least three consecutive Gatus cycles for all six endpoints
and confirm the six Prometheus series. The four Servarr probes should succeed when the
API returns HTTP 200 even if update notices remain. Keep Stage 5 alerts absent until
the operator separately approves alert enablement.

## 7. Consequences

This change removes false failures caused by routine update notices and keeps release
policy independent from monitoring. It preserves authenticated route and credential
evidence with no new software lifecycle.

The accepted cost is reduced continuous assurance: Gatus no longer turns any Servarr
native health entry into a failed metric. Operators must inspect the native health UI
or API, use existing telemetry, or run authorized deeper checks to discover those
problems until a safe off-the-shelf structured filter becomes available.
