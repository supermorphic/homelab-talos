# Media Integration Health Collector

## Historical boundary

This specification records the first complete design for continuous media-integration
health. It was not implemented and does not describe the current deployment. The
targeted-probe revision in specification 029 replaced two passive mechanisms, and the
Gatus design in specification 030 later replaced the custom collector as a whole.

The value retained here is the assurance model: service availability, source access,
API compatibility, expected configuration, and an integration probe are different
signals and must not be collapsed into one healthy result.

## Problem and inventory

The existing Gatus `/ping` and status checks proved that applications served HTTP. They
did not prove that Prowlarr, Sonarr, Radarr, Lidarr, Seerr, qBittorrent, and Plex could
perform their configured interactions. A Cilium policy omission had already shown that
a green source and target could coexist with a broken integration.

The design mapped fifteen directed edges:

| Integration type | Source | Targets | Count |
| --- | --- | --- | ---: |
| Application configuration sync | Prowlarr | Sonarr, Radarr, Lidarr | 3 |
| Prowlarr-backed indexer query | Sonarr, Radarr, Lidarr | Prowlarr | 3 |
| Download client | Sonarr, Radarr, Lidarr | qBittorrent | 3 |
| Library notification | Sonarr, Radarr, Lidarr | Plex | 3 |
| Request and library service | Seerr | Sonarr, Radarr, Plex | 3 |

The two Prowlarr directions were intentionally distinct. Successful Prowlarr
configuration sync would not prove that an application could later query a configured
indexer, and a working query path would not prove that later syncs were healthy.

## Proposed collector design

The design selected one stateless `media-integration-health` collector in the `media`
namespace. It would poll the public APIs of Prowlarr, Sonarr, Radarr, Lidarr, and Seerr,
cache one atomic snapshot, and expose bounded metrics to Prometheus. A scrape would read
the cache rather than trigger application API traffic.

The collector would contact only the five source applications. Each source application
would use its own stored downstream configuration and credential to evaluate
qBittorrent, Plex, or another application. This kept qBittorrent and Plex credentials
out of the collector and avoided testing a synthetic network path different from the
one used by the source.

Every edge had separate expected-configuration and probe results. An exact static
inventory supplied expected internal targets, so a wrong but internally consistent
configuration could not pass by comparing the application only with itself.

## Failure classification

The design classified a source poll before interpreting an integration result:

| Condition | Classification | Integration result usable |
| --- | --- | --- |
| Connection, timeout, TLS, authentication, or generic server failure | Source access failure | No |
| Unsupported API major, missing endpoint, or incompatible required field | API incompatibility | No |
| Collector exception, invariant failure, or incomplete inventory | Collector error | No |
| Compatible API with absent or wrong expected provider | Configuration failure | Configuration only |
| Compatible documented native test failure | Probe failure | Yes |
| Compatible documented native test success | Healthy probe | Yes |

This ordering prevented an application upgrade or adapter defect from being reported as
a broken integration. Human health messages, upstream URLs, provider names, response
fragments, and secret values were excluded from metric labels. Detailed errors would
have remained bounded and redacted in logs.

The proposed metrics separated source access and freshness, configuration compatibility,
configured state, probe compatibility, probe success, and collector error. The bounded
`source`, `target`, `integration`, `check`, and `phase` labels came from the fixed
inventory. No generic `UNKNOWN` integration state was proposed.

## Probe model

The original design mixed active and passive source-owned evidence:

- targeted, non-persisting native tests covered Servarr download-client and Plex
  notification integrations;
- Seerr selected-service reads covered Sonarr and Radarr, while Plex discovery supplied
  a bounded Seerr-to-Plex signal;
- Prowlarr application status and Servarr indexer status were expected to provide
  structured passive evidence for the six Prowlarr-direction edges.

Continuous end-to-end requests, searches, downloads, imports, library refreshes, and
configuration writes remained outside the design because they create durable state and
cleanup obligations. Exportarr sidecars were rejected because they did not cover Seerr
or the edge-specific configuration and probe distinctions.

## Workload and credential safety model

The collector would have had one replica, no PVC, no public route, no service-account
token, a read-only filesystem, and a narrow ServiceMonitor. Purpose-specific
SOPS-encrypted source API keys would have been mounted as read-only projected files and
reread between poll cycles. They would not have appeared in environment variables,
arguments, metrics, events, or logs.

A dedicated Cilium policy would have admitted Prometheus only to the metrics port and
allowed egress only to DNS and the five source application Services. It would not have
allowed direct qBittorrent, Plex, or Internet access.

Six warning alerts were designed to distinguish collector unavailability, collector or
stale-poll errors, source access, API incompatibility, invalid expected configuration,
and a compatible native probe failure. Compatibility, source freshness, and collector
health gated integration alerts so stale or uninterpretable values could not fire as
edge failures.

## Why the design changed

Implementation research found that the assumed passive structured endpoints did not
exist for the six Prowlarr-direction edges. Relevant names appeared only in localized
human health messages, which the design itself prohibited as an API contract. That
finding produced the active-test revision in specification 029.

The larger collector design was then replaced before implementation. Its custom image,
adapter surface, compatibility contract, five source credentials, new workload, scrape
target, network policy, and alert family were disproportionate to the reliable
off-the-shelf signals available. The later Gatus design accepted less coverage in return
for a smaller and already-operated execution and metrics surface.

## Historical consequences

The collector would have provided a strong distinction between source, compatibility,
configuration, probe, and collector failures, plus bounded attribution across all
fifteen edges. Its cost was a custom integration product whose adapters had to track
several APIs with uneven contract quality. No current Kubernetes resource, metric, alert,
credential, or operating procedure should be inferred from this design.
