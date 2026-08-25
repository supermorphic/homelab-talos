# Media Integration Health Collector

## Historical boundary

This specification records the first complete design for continuous media-integration
health. It was not implemented and does not describe the current deployment. The
[active-probe revision](019-media-integration-health-active-probes.md) replaced two
passive mechanisms, and the [Gatus design](020-media-integration-health-gatus.md) later
replaced the collector as a whole.

The durable idea was an assurance model: service availability, source access, API
compatibility, expected configuration, a source-owned integration probe, and collector
correctness are different signals. A green source and target do not prove the directed
connection between them. A Cilium policy omission had already produced that exact
failure while ordinary endpoint checks remained green.

## Problem and directed inventory

Existing Gatus `/ping` and status checks proved that applications served HTTP through
their normal route. They did not prove that Prowlarr, Sonarr, Radarr, Lidarr, Seerr,
qBittorrent, and Plex could perform their configured interactions.

The design fixed the inventory at fifteen directed edges:

| Integration type | Source | Targets | Count |
| --- | --- | --- | ---: |
| Application configuration sync | Prowlarr | Sonarr, Radarr, Lidarr | 3 |
| Prowlarr-backed indexer query | Sonarr, Radarr, Lidarr | Prowlarr | 3 |
| Download client | Sonarr, Radarr, Lidarr | qBittorrent | 3 |
| Library notification | Sonarr, Radarr, Lidarr | Plex | 3 |
| Request and library service | Seerr | Sonarr, Radarr, Plex | 3 |

The two Prowlarr directions were intentionally distinct. Prowlarr can fail to sync an
application while an already configured indexer still works. Conversely, sync can work
while an application cannot query Prowlarr. The design excluded Prowlarr-to-external-
indexer and FlareSolverr paths, Tautulli-to-Plex, and qbit_manage-to-qBittorrent.

## Proposed architecture and alternatives

The design selected one stateless `media-integration-health` collector in the `media`
namespace. It would poll the public APIs of five source applications every five minutes
with jitter, publish one atomic cached snapshot, and expose that snapshot to Prometheus
on a one-minute scrape interval. Scraping would never trigger application traffic.

The collector would contact only Prowlarr, Sonarr, Radarr, Lidarr, and Seerr. Each source
would use its own stored downstream configuration and credential to evaluate
qBittorrent, Plex, or another application. This avoided giving the collector downstream
credentials and avoided testing a synthetic network path different from the source-owned
path. An exact static inventory supplied expected internal targets, so a wrong but
internally consistent application configuration could not validate itself.

One collector was plausible because it could expose one bounded metric contract and one
scrape target while correlating structured provider identifiers with source-owned test
results. The alternatives lost important boundaries:

- Exportarr supported general health for the four Servarr applications, but not Seerr or
  the complete edge-specific configuration and probe model. Sidecars also multiplied
  credentials and scrape targets without completing the design.
- Gatus could prove an HTTP response but could not interpret dynamic configured providers
  or safely run the native tests assumed by this design.
- Direct synthetic probes would duplicate downstream credentials and application logic
  while exercising a new path owned by the monitor rather than the source.
- Continuous end-to-end transactions would create requests, downloads, imports, library
  changes, or cleanup work. That stateful behavior did not meet the continuous-monitoring
  safety boundary.

## Original signal model

Each adapter would first compare application state with independent expected
configuration. It would probe only an enabled matching provider.

| Edge | `configured` evidence | Original `probe_success` evidence | Probe boundary |
| --- | --- | --- | --- |
| Prowlarr to Sonarr, Radarr, or Lidarr | Expected enabled application, `FullSync`, and exact internal target | No application-provider failure for that target | Passive and delayed; no `testall` |
| Sonarr, Radarr, or Lidarr to Prowlarr | Expected enabled Torznab or Newznab provider and exact internal target | No native structured failure for matched Prowlarr-backed providers | Passive recent-use negative evidence, not a search |
| Sonarr, Radarr, or Lidarr to qBittorrent | Expected enabled client, host, port, and category | Targeted download-client test succeeded | Active, non-persisting source-owned test |
| Sonarr, Radarr, or Lidarr to Plex | Expected enabled notification, host, port, and events | Targeted notification test succeeded | Active, non-persisting; no library refresh |
| Seerr to Sonarr or Radarr | Expected selected and enabled service, including intended default | Profiles, roots, and tags returned through Seerr's stored settings | Authenticated read-only GET; no request |
| Seerr to Plex | Expected selected Plex server | Configured server appeared reachable through discovery | Authenticated read-only GET; no library sync |

Human health messages were diagnostic text, not identifiers. Provider IDs and structured
fields were required. An adapter unable to map a structured response had to report API
incompatibility instead of guessing from human text. The later discovery that structured
identity was absent for the six Prowlarr-direction signals invalidated those two passive
mechanisms; it did not invalidate the overall assurance model.

## API and failure contract

Adapters would declare a supported API major and minimum endpoint and response schema.
They would accept additive fields and compatible patch or minor releases. Exact version
allow-lists were rejected because the main drift risk was semantic change inside generic
provider `fields` arrays and provider-status representations, not an obvious API-major
change. Seerr response contracts were judged less mature because its public schema did
not validate responses or track an application release as tightly.

Each source poll classified its result before interpreting an edge:

| Condition | Classification | Integration result usable |
| --- | --- | --- |
| DNS, connection, timeout, TLS, authentication, or generic server failure | Source access failure | No |
| Unsupported API major, absent endpoint, or missing or incompatible required field | API incompatibility | No |
| Collector exception, invariant failure, or incomplete inventory | Collector error | No |
| Compatible API with absent or wrong expected provider | Configuration failure | Configuration only |
| Compatible documented native test failure | Probe failure | Yes |
| Compatible documented native test success | Healthy probe | Yes |

A documented validation response could be an integration failure. An unrecognized error
shape was API incompatibility. This ordering prevented application upgrades, stale
snapshots, and adapter defects from becoming false edge failures.

## Proposed metric and alert contract

The bounded metrics were:

```text
media_integration_expected_info{source,target,integration} 1
media_integration_source_access_success{source} 0|1
media_integration_source_last_poll_timestamp_seconds{source} <unix-seconds>
media_integration_config_compatible{source,target,integration,check="configuration"} 0|1
media_integration_configured{source,target,integration} 0|1
media_integration_probe_compatible{source,target,integration,check="probe"} 0|1
media_integration_probe_success{source,target,integration} 0|1
media_integration_collector_error{source,phase} 0|1
media_integration_source_info{source,application_version,api_major,adapter_version} 1
media_integration_collector_build_info{version} 1
```

`source`, `target`, and `integration` came only from the fixed inventory. `phase` was a
bounded enum. Provider names, learned IDs, URLs, health or validation messages, response
fragments, exceptions, and secrets were forbidden as labels. The model had no generic
`UNKNOWN` edge state; compatibility and success remained independent.

Six proposed warning alerts separated collector absence, collector or stale-poll error,
source access, API incompatibility, expected-configuration failure, and compatible probe
failure. Collector absence and error held for 10 minutes. Source, compatibility,
configuration, and probe failures held for 15 minutes, and a source snapshot older than
15 minutes was unusable. Fresh source access, compatibility, configured state, and lack
of collector error gated downstream alerts. The collector design's metrics and alert
names were never implemented and are not current alert contracts.

## Workload, credentials, and network safety

The proposed Deployment had one steady-state replica, no PVC, public route, or service-
account token, a read-only filesystem, bounded request timeouts, and no overlapping poll
inside one replica. `RollingUpdate` was acceptable only because every operation was
required to be non-persisting and safe during bounded two-instance overlap. A probe found
unsafe under overlap had to leave continuous monitoring or force a successor design.

Readiness and liveness represented collector operation only: loaded configuration,
working poll loop, and serviceable metrics. Upstream or integration failures could not
make the pod unready and create a restart loop.

Five purpose-specific source API keys would be created through the operator-managed SOPS
workflow and mounted as read-only files. The collector would reread files between polls
so a normal Secret update could take effect without a custom reload mechanism. Keys were
forbidden from environment variables, arguments, metrics, events, and logs. The
collector accepted the broad source-key scope as residual risk but would never receive a
qBittorrent or Plex credential.

A dedicated Cilium policy would admit only Prometheus to the metrics port and permit
egress only to DNS and the five source workloads on their service ports. Direct
qBittorrent, Plex, Internet, and broad namespace egress were outside the design.

## Validation and activation gates

Independent validation was required before the proposed alerts could carry operational
meaning:

- Source invariants had to prove one collector and scrape target, the exact fifteen-edge
  inventory, source-only egress, metrics-only ingress, no public route or PVC, file-
  mounted Secret references, and correct alert placement. Mutation tests had to show
  that the important assertions could fail.
- Sanitized adapter fixtures with hand-written expected metrics had to cover success,
  documented test failure, absent configuration, unsupported API, absent endpoint,
  missing or wrong-typed fields, additive fields, source failure, and collector error.
- Promtool fixtures had to prove silence for a healthy snapshot and isolation of every
  failure class, hold, freshness gate, and suppression rule.
- Render validation could inspect Secret metadata and references but not plaintext.
- Read-only live comparison had to observe the expected inventory and source series,
  compare selected results with application UIs and native Test actions, and confirm the
  narrow flow policy. Repository rendering could not prove credentials, application
  configuration, native test behavior, or live Cilium enforcement.

The design required the artifact contract to validate before cluster introduction, then
at least three successful five-minute cycles with rules silent before alert activation.
Rollback removed inaccurate alerts first and could remove the scrape target and workload
without changing source configuration. Rotation was required only if credential exposure
was suspected. These were safety and evidence gates, not proof that deployment occurred.

## Outcome, residual risk, and reconsideration

Implementation research found that the assumed passive structured provider evidence did
not exist. Relevant identity appeared only in localized health text, which this design
correctly prohibited as an API contract. Specification 019 replaced only those passive
mechanisms with attributable, non-persisting POST tests.

Specification 020 then replaced the complete collector before implementation. The
custom image, adapters, compatibility surface, workload, scrape target, policy, five
credentials, and alert family cost more to maintain than the reliable coverage justified.
That architecture change accepted less attribution; it did not prove the collector's
failure taxonomy or source-owned-probe principle unsound.

Even if implemented, the collector would not have proved a full Seerr-to-Plex workflow,
fresh provider behavior between source events, every external dependency, or end-to-end
request completion. It would also have retained broad source keys, one non-HA replica,
uneven upstream API maturity, and runtime discovery of some schema drift.

Candidate-image contract testing was deliberately deferred. It could have been
reconsidered after upstream churn or false compatibility incidents. High availability
and the explicitly excluded integrations required separate justification. Reintroducing
the collector or any of its resources now would be a new design, not execution of this
historical specification.
