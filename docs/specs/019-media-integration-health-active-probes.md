# Media Integration Health Active Probes

## Historical boundary

This specification records a revision to the unimplemented collector in specification
028. It did not become the current deployment. Specification 030 replaced the collector
and these active POST probes with six non-mutating GET checks in the existing Gatus
workload.

The revision retained the fifteen-edge inventory, collector workload, metrics,
credentials, network policy, failure classification, and alert model from specification
028. It changed only the unsafe assumption that localized native-health messages could
provide structured Prowlarr-direction evidence.

## Contract finding

Release-specific API research found no structured application-status endpoint in
Prowlarr and no structured indexer-status endpoint in Sonarr, Radarr, or Lidarr that
could attribute the relevant provider. Their public health resources exposed the check
source, result type, localized message, and documentation URL, but the application or
indexer name existed only inside human text.

Parsing those messages would have violated the collector's compatibility boundary. A
translation or wording change could become a false integration failure while the API
schema remained compatible.

The public APIs did expose targeted provider-test operations. The source application
could test an existing resource without saving it, which preserved source-owned
credentials and gave the result a specific provider boundary.

## Revised probe design

The historical design selected these non-persisting calls:

| Edge | Source operation | Supplied resource | Evidence boundary |
| --- | --- | --- | --- |
| Prowlarr to Sonarr, Radarr, or Lidarr | `POST /api/v1/applications/test?forceTest=true` | The matched existing `ApplicationResource` | Prowlarr reached the configured application and validated a temporary Prowlarr-backed indexer definition |
| Sonarr or Radarr to Prowlarr | `POST /api/v3/indexer/test?forceTest=true` | One matched existing `IndexerResource` | The source reached Prowlarr and validated the selected provider's capabilities |
| Lidarr to Prowlarr | `POST /api/v1/indexer/test?forceTest=true` | One matched existing `IndexerResource` | The same source-to-Prowlarr boundary through Lidarr's API version |

The calls used one source-returned provider object and `forceTest=true`. They would not
have called `testall`, run a search or sync, or create, update, or delete provider
configuration. For multiple matching Prowlarr-backed indexers, the design selected the
enabled provider with the lowest numeric ID so repeated polls were deterministic. That
single test represented the shared path and did not claim that every external indexer
worked.

## Request-body safety

Provider resources can include masked or source-held downstream credential fields. The
collector would have treated the selected resource as opaque and short-lived:

- return it only to the same source application that supplied it;
- keep it only for the current poll;
- omit the body, headers, query values, response body, URL, and secret-like fields from
  logs, exceptions, metrics, and disk; and
- project only a small non-secret field set for the independent configuration check.

This round trip did not give the collector a separately mounted downstream credential.
The source application remained responsible for interpreting and using its stored
provider settings.

## Result boundary

A documented compatible success would have produced `probe_success=1`. A documented
provider-validation failure with the expected schema would have produced a compatible
probe failure. A missing test endpoint, unsupported API major, or unrecognized response
shape would have produced API incompatibility instead of an integration failure.

Source transport or authentication failures remained source-access failures. Failure to
choose exactly one deterministic resource remained a collector error. Absent or invalid
expected configuration remained a configuration failure and would have skipped the
active test.

The proposed validation model required independent HTTP-server fixtures for the exact
method, path, query, header, and opaque body round trip. It also distinguished documented
validation errors from incompatible responses and checked that secret-like source fields
never entered output. These were safeguards for a proposed adapter, not claims about the
current Gatus configuration.

## Why the design was replaced

The revision solved the localized-message defect but increased recurring authenticated
POST traffic and kept the full custom collector lifecycle. It still required application
adapters, an image and deployment, a new scrape target, five credentials, a network
policy, compatibility fixtures, and fifteen-edge classification.

The later Gatus redesign chose a smaller assurance boundary: four authenticated Servarr
native-health GETs and two selected Seerr service reads. Its initial Servarr contract
required both HTTP 200 and an empty response array; specification 031 records the later
reachability-only correction. The Gatus design intentionally gave up continuous
Prowlarr-direction native tests and most edge attribution to avoid a custom adapter
product and continuous POST operations.

No current endpoint, alert, workload, or operator action should be derived from this
historical active-probe design.
