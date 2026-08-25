# Media Integration Health Active Probes

## Historical boundary

This specification records a focused revision to the
[unimplemented collector](018-media-integration-health-collector.md). It was also never
implemented. The [Gatus design](020-media-integration-health-gatus.md) later replaced the
collector and these active POST probes with six non-mutating GET checks in the existing
Gatus workload.

The revision retained the collector's fifteen-edge inventory, source and configuration
classification, metrics, file-mounted source keys, network policy, five-minute cached
poll, one-minute scrape, alert gates, validation boundary, and residual limits. It
changed only the unsafe assumption that localized native-health messages could provide
structured evidence for the six Prowlarr-direction edges.

## Failed passive assumption

Release-specific public API research found no structured application-status resource in
Prowlarr and no structured indexer-status resource in Sonarr, Radarr, or Lidarr that
could attribute the relevant provider. Public health responses supplied a check source,
result type, localized message, and documentation URL, but the application or indexer
name existed only inside human text.

Message parsing would have violated the collector's API-compatibility boundary. A
translation or wording change could become a false edge failure without any schema or
integration change. The earlier passive mechanism was therefore not safe to implement.

The same APIs did expose targeted native tests that accepted an existing provider
resource without saving it. That contract was plausible because the source retained the
downstream settings and credentials, the supplied resource bounded attribution to one
provider, and the operation did not create or modify provider configuration.

## Revised probe design

The historical design selected these operations:

| Edge | Source operation | Supplied resource | Evidence boundary |
| --- | --- | --- | --- |
| Prowlarr to Sonarr, Radarr, or Lidarr | `POST /api/v1/applications/test?forceTest=true` | The matched existing `ApplicationResource` | Prowlarr reached the configured application and validated a temporary Prowlarr-backed indexer definition |
| Sonarr or Radarr to Prowlarr | `POST /api/v3/indexer/test?forceTest=true` | One matched existing `IndexerResource` | The source reached Prowlarr and validated the selected provider capabilities |
| Lidarr to Prowlarr | `POST /api/v1/indexer/test?forceTest=true` | One matched existing `IndexerResource` | The same source-to-Prowlarr boundary through Lidarr's API version |

The collector would return a source-provided object only to that same source with
`forceTest=true`. It would not call `testall`, run a search or sync, issue a command, or
create, update, or delete configuration. With multiple matching Prowlarr-backed
indexers, it selected the enabled provider with the lowest numeric ID. Configuration
validation still covered every expected provider; the single deterministic active test
represented the shared path and did not claim every external indexer was healthy.

The revision added six targeted tests per five-minute collector poll. The calls were
judged non-persisting and safe during the bounded overlap of `RollingUpdate`. If fixture
or live evidence had disproved overlap safety, the affected probe had to leave continuous
monitoring or the collector design had to be replaced. POST itself was not the defect;
these particular POST contracts were designed as safe source-owned native tests.

## Request-body and credential safety

Provider resources can contain masked or source-held downstream credential fields. The
collector would treat each selected resource as opaque and short-lived:

- return it only to the source application that supplied it;
- keep it only for the current source poll and never write it to disk;
- exclude the body, headers, query values, response body, configured URL, and secret-like
  fields from logs, error values, metrics, and snapshots; and
- project only the small non-secret field set needed for the separate configuration
  comparison.

This round trip did not add a mounted downstream credential. The source application
remained responsible for interpreting and using its stored provider settings. The
collector still held only the five source API keys described in specification 018.

## Result and assurance boundary

A documented compatible success would have produced `probe_success=1`. A documented
provider-validation failure with the expected schema would have produced
`probe_compatible=1, probe_success=0`. A missing test endpoint, unsupported API major, or
unrecognized validation shape would have produced incompatibility, not a false edge
failure.

Source transport or authentication failures remained source-access failures. Failure to
select exactly one deterministic resource remained a collector error. Absent or invalid
expected configuration remained a configuration failure and skipped the active test.
The inherited freshness, compatibility, configuration, and collector-error alert gates
still controlled whether a probe result was usable.

A passed test proved current native connectivity validation for one selected provider.
It did not prove that the provider configuration was complete or current, that sync or a
search had completed, or that every external indexer worked. Independent configuration
checks and authorized end-to-end verification remained necessary.

## Independent validation model

The proposed adapter needed independent HTTP-server fixtures for each source API major.
The fixture oracle had to verify the exact method, path, `forceTest=true` query,
authentication header, and opaque body round trip. It also had to prove:

- no `testall`, search, command, sync, create, update, or delete path was requested;
- additive response fields remained compatible;
- missing or wrong-typed required fields became API incompatibility;
- a documented validation response became a compatible probe failure;
- an unrecognized result became API incompatibility;
- multi-provider selection was deterministic and did not claim per-indexer health;
- source-returned secret-like fields never entered logs, exceptions, metrics, or disk;
  and
- two concurrent collector instances produced no persistent state and no different
  classification.

Read-only live comparison would have used the same targeted Test actions in the source
UIs. It would not have run a search or changed a provider. The collector's artifact,
silent-observation, and alert-activation gates remained unchanged; these are historical
acceptance requirements, not evidence that the proposal was deployed.

## Outcome and reconsideration

This revision removed dependence on localized messages and gave the six Prowlarr-
direction edges an attributable current test. It also increased recurring authenticated
traffic and retained the complete custom collector lifecycle: adapters, image,
Deployment, scrape target, five keys, policy, compatibility fixtures, metrics, and alert
classification.

Specification 020 judged that cost disproportionate to reliable continuous coverage. It
chose an existing Gatus surface and a stricter no-POST/no-transaction boundary. That
later choice does not mean these targeted tests were shown to persist state or were
intrinsically unsafe; it means their value did not justify the collector product needed
to operate them continuously.

The final four Servarr Gatus signals now have no provider attribution and do not prove a
Prowlarr, qBittorrent, Plex, or indexer path. Reintroducing the POST tests, collector, or
their proposed alerts requires a new design and fresh contract evidence. Searches,
transactions, full external-indexer checks, candidate-image testing, and other deep
workflow verification remain outside this historical revision.
