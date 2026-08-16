# Media integration health active probes — successor decision

- **Status: Accepted.**

Date: 2026-08-16.
Branch: `dispatch-media-integration-health-decision`.

Supersedes
[Media integration health — decision](2026-08-16-media-integration-health.md).
All decisions in that record remain in force except the two passive probe mechanisms
replaced here.

## 1. Decision

Use targeted, non-persisting native application tests for the Prowlarr-to-`*arr` and
`*arr`-to-Prowlarr probes. The collector supplies the exact existing provider resource
returned by the source API and sets `forceTest=true`. It does not call `testall`, run a
search, or write application configuration.

The two replacement probes are:

| Edge | Source endpoint | Request body | Success boundary |
|---|---|---|---|
| Prowlarr -> Sonarr, Radarr, Lidarr | `POST /api/v1/applications/test?forceTest=true` | The one matched `ApplicationResource` from `GET /api/v1/applications` | Prowlarr reaches the configured application and asks it to validate a temporary Prowlarr-backed indexer definition. No application or indexer is persisted. |
| Sonarr and Radarr -> Prowlarr | `POST /api/v3/indexer/test?forceTest=true` | One deterministic matched `IndexerResource` from `GET /api/v3/indexer` | The source reaches Prowlarr and validates the selected Prowlarr-backed Torznab/Newznab capabilities. No search or provider update runs. |
| Lidarr -> Prowlarr | `POST /api/v1/indexer/test?forceTest=true` | One deterministic matched `IndexerResource` from `GET /api/v1/indexer` | Same boundary as Sonarr and Radarr. |

For an `*arr` source with multiple matching Prowlarr-backed providers, select the enabled
provider with the lowest numeric provider ID. Configuration validation still evaluates
every expected provider. The probe proves the shared source-to-Prowlarr query path; it
does not claim that each external indexer works. External indexer health remains outside
Stage 5.

Keep every other part of the superseded decision unchanged: the fifteen-edge inventory,
configured/probe split, API compatibility classification, metrics, five-minute cached
polling, RollingUpdate, credentials, network policy, alerts, validation, rollout, and
three-project delivery split.

## 2. Why the passive design cannot be implemented safely

Planning against the release-specific public contracts found no structured
application-status endpoint in Prowlarr and no structured indexer-status endpoint in
Sonarr, Radarr, or Lidarr.

Their public health resources contain a check source, result type, localized message, and
documentation URL. The application or indexer names exist only inside the localized
human message produced by the health-check implementation. Parsing that text would
contradict the original decision's API-drift boundary and could turn a translation or
message change into a false integration failure.

The public APIs do expose targeted provider-test endpoints. The upstream implementations
test the supplied resource without saving it. These endpoints therefore preserve the
approved non-mutating boundary while producing a result attributable to one selected
edge.

## 3. Request-body and credential handling

Provider resources can contain masked or source-held downstream credential fields. The
collector must treat each selected resource as an opaque, short-lived request body:

- select it from the source response and send it back only to that same source;
- do not write it to disk, cache it beyond the current source poll, or include it in an
  error value;
- do not log the body, headers, query values, response body, or configured URL;
- project only the small non-secret field set needed for configuration comparison;
- discard the full decoded response before publishing the atomic metric snapshot.

This does not give the collector a separately mounted qBittorrent, Plex, Sonarr, Radarr,
Lidarr, or Prowlarr downstream credential. The source application remains responsible for
interpreting and using its stored provider configuration.

## 4. Result classification

The original failure classification remains authoritative, with these endpoint-specific
rules:

- documented success from a compatible targeted test is `probe_success=1`;
- a documented provider-validation response with the expected schema is
  `probe_compatible=1, probe_success=0`;
- an absent test endpoint, unsupported API major, or unrecognized validation schema is
  `probe_compatible=0` and cannot produce a probe failure;
- failure to reach, authenticate to, or obtain a usable generic response from the source
  remains a source-access failure;
- an unexpected collector exception or failure to select exactly one deterministic
  resource is a collector error;
- absent or invalid expected configuration remains a configuration failure and skips the
  targeted test.

No generic `UNKNOWN` integration state is added.

## 5. Safety and validation changes

Adapter fixtures and independent HTTP-server tests must assert the exact method, path,
`forceTest=true` query, authentication header, and body round trip for every source API
major. They must also prove that:

- no adapter requests a `testall`, search, command, sync, create, update, or delete path;
- source-returned secret-like fields never enter logs, exceptions, or metrics;
- additive response fields remain compatible;
- missing or wrong-typed required fields produce API incompatibility;
- a documented validation response produces an integration failure;
- an unrecognized response produces API incompatibility;
- selection among multiple matched indexers is deterministic and does not claim
  per-indexer health;
- two concurrent instances can run each selected test without persistent state or a
  different result classification.

Live verification compares the collector result with the same targeted Test action in
the Prowlarr, Sonarr, Radarr, and Lidarr UIs. It does not run a search or change a
provider. The three implementation projects and their rollout order remain those in §12
of the superseded decision.

## 6. Consequences

The replacement removes dependence on localized health messages and gives each of the
six Prowlarr-direction edges an attributable, current result. It increases safe API
traffic: one targeted application test for each Prowlarr edge and one targeted indexer
test for each `*arr` edge per five-minute poll. The selected calls are safe during the
bounded overlap of a RollingUpdate.

The probes prove current native validation, not a completed sync or search. A source can
still contain stale provider configuration that passes a connectivity test; the separate
configuration checks and operator-run end-to-end verification retain that residual
boundary.
