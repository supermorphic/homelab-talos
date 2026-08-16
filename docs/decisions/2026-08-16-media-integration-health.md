# Media integration health — decision

- **Status: Superseded by 2026-08-16-media-integration-health-active-probes.md.**

Date: 2026-08-16.
Branch: `dispatch-media-integration-health-decision`.

Completes the design deferred by §8, “Stage 5 — integration health for the media
stack,” in
[Alerting architecture — decision](2026-08-13-alerting-architecture.md).

## 1. Decision

Build one purpose-specific, stateless integration-health collector in the `media`
namespace. It polls the public APIs of Prowlarr, Sonarr, Radarr, Lidarr, and Seerr in the
background, caches a bounded set of results, and exposes those results to the existing
Prometheus. The source application performs each downstream test; the collector does not
contact qBittorrent, Plex, or the Internet.

Monitor fifteen directed integration edges in the core request and import workflow. For
each edge, report expected configuration separately from a safe probe. Also report API
compatibility separately from both results. An API contract change must produce an
`api_incompatible` alert, never a false integration-failure alert.

Continuous probes are read-only or use an application's documented, non-persisting native
test action. They must not create a Seerr request, download, import, library change, Plex
refresh, or other durable application state. End-to-end workflow tests remain guarded,
operator-run verification.

Do not deploy Exportarr sidecars for this stage. Exportarr exposes useful general
application health, but it neither supports the complete application set nor supplies the
specific configuration and probe signals this decision requires.

## 2. Scope and assurance boundary

The inventory contains these fifteen expected edges:

| Integration type | Source | Targets | Count |
|---|---|---|---:|
| Indexer configuration sync | Prowlarr | Sonarr, Radarr, Lidarr | 3 |
| Prowlarr-backed indexer query | Sonarr, Radarr, Lidarr | Prowlarr | 3 |
| Download client | Sonarr, Radarr, Lidarr | qBittorrent | 3 |
| Library notification | Sonarr, Radarr, Lidarr | Plex | 3 |
| Request and library service | Seerr | Sonarr, Radarr, Plex | 3 |

The two Prowlarr directions are different integrations. Prowlarr can fail to sync
configuration to an `*arr` application while an already configured indexer still works.
Conversely, sync can succeed while an `*arr` application cannot query Prowlarr.

The continuous signal proves only the boundary named by its probe. It does not prove that
a real request completed from Seerr through download, import, and Plex availability. The
following integrations remain outside this stage:

- Prowlarr to external indexers and FlareSolverr;
- Tautulli to Plex;
- qbit_manage to qBittorrent.

Existing Gatus checks continue to prove HTTP availability. They are not integration
signals and are not changed by this decision.

## 3. Why one dedicated collector

One collector gives the fifteen edges one stable metric contract and one scrape target.
It can correlate configured provider identifiers with structured native test results
without exporting provider names, URLs, validation messages, or other unbounded data as
Prometheus labels.

The rejected alternatives are:

- **Exportarr sidecars.** Exportarr supports the four Servarr applications but not Seerr,
  qBittorrent, or Plex. Its general health metric is useful for application health, but it
  does not distinguish expected configuration, safe targeted probes, source access, API
  compatibility, and collector defects for every edge. Sidecars would also create four or
  five scrape targets and duplicate credentials without completing this design.
- **Gatus probes.** Gatus can prove an HTTP response but cannot safely interpret the
  source application's configured providers or run its authenticated native tests.
- **Direct synthetic probes.** A collector that contacts every target would duplicate
  downstream credentials and application-specific behavior. It would test a new network
  path rather than the path owned by the source application.
- **Continuous end-to-end transactions.** Synthetic requests and imports give stronger
  assurance but create durable work and cleanup obligations. They do not meet the
  non-mutating continuous-monitoring constraint.

## 4. Signal for each integration

Each adapter first confirms the expected source configuration. It runs the probe only
when that configuration is present and enabled.

| Edge | `configured` proves | `probe_success` proves | Probe character |
|---|---|---|---|
| Prowlarr -> Sonarr, Radarr, Lidarr | The expected enabled application has `FullSync` and the expected internal target. | Prowlarr reports no application-provider failure for that target. | Passive and delayed. Do not schedule `testall`; it can cause downstream indexer tests and include external provider health. |
| Sonarr, Radarr, Lidarr -> Prowlarr | The expected enabled Torznab/Newznab providers point to the internal Prowlarr service. | Native structured indexer status has no failure for the matched Prowlarr-backed providers. | Passive, recent-use negative evidence. It is not a synthetic search. |
| Sonarr, Radarr, Lidarr -> qBittorrent | The expected enabled qBittorrent client has the intended internal host, port, and category. | The source application's targeted download-client test succeeds. | Active but non-persisting. The source authenticates, reads qBittorrent state, and validates its own client settings. |
| Sonarr, Radarr, Lidarr -> Plex | The expected enabled Plex notification has the intended host, port, and event settings. | The source application's targeted notification test succeeds. | Active but non-persisting. It authenticates to Plex and can include Plex account-service availability; it does not refresh a library. |
| Seerr -> Sonarr, Radarr | The expected service is enabled and the correct server is selected, including the intended default. | Seerr's documented service read-through returns downstream profiles, roots, and tags by using Seerr's stored credential. | Authenticated read-only GET. It does not create a request. |
| Seerr -> Plex | Plex settings select the expected server. | Seerr's documented Plex server-discovery read reports that configured server as reachable. | Authenticated read-only GET. It includes Plex account-service availability and does not run a library sync. |

“Expected internal target” means an exact, non-secret value held in collector configuration,
not a value learned from a source response. This gives validation an independent expected
inventory and prevents a wrong but internally consistent configuration from passing.

Human health messages are diagnostic data, not identifiers. The collector must prefer
provider IDs and structured status fields. It must not parse a human message to decide an
edge result. If an adapter cannot map a required structured response, it reports API
incompatibility.

## 5. API contract and failure classification

Adapters declare a supported API major and the minimum endpoint and response schema they
need. At runtime they accept additive fields and compatible patch or minor releases. The
observed application version is diagnostic information, not an exact-version allowlist.

Every completed source poll publishes one atomic snapshot. A previous integration result
can remain cached for diagnosis, but alert expressions ignore it unless the same snapshot
has successful source access, a compatible adapter, no collector error, and a recent poll.

Classify outcomes in this order:

| Condition | Classification | Integration result allowed? |
|---|---|---|
| DNS, connection, timeout, TLS, `401`, `403`, or generic server failure prevents evaluation | `source_access` failure | No |
| Required public endpoint is absent, API major is unsupported, or a required response field has a missing or incompatible type | `api_incompatible` | No |
| Collector exception, violated internal invariant, incomplete expected inventory, or other adapter defect | `collector_error` | No |
| Contract is compatible and the expected configuration is absent or wrong | Configuration failure | Configuration result only |
| Contract is compatible and the native test returns its documented application-level failure | Integration probe failure | Yes |
| Contract is compatible and the native test succeeds | Healthy integration probe | Yes |

A structured native test failure can use an HTTP error status or a response such as
`isValid=false`; its documented response shape makes it an integration result. An
unrecognized error body is API incompatibility, not an integration failure.

The design deliberately does not add compatibility manifests, exact application-version
certification, or candidate-image boot tests. Lightweight fixture tests cover the adapter
contract. Candidate-image testing can be reconsidered if upstream churn or false
compatibility incidents show that runtime capability detection is insufficient.

## 6. API maturity and adapter risk

These are public application APIs, but their contract quality is not uniform:

| Source | Current API basis | Assessment |
|---|---|---|
| Sonarr and Radarr | Established, versioned `/api/v3` with release-specific upstream OpenAPI documents and upstream API integration tests. | Well established. Low-to-medium adapter risk because provider `fields` remain dynamically typed. |
| Prowlarr | Established, versioned `/api/v1` with an upstream OpenAPI document. | Established but less strongly typed for applications and provider status. Medium adapter risk. |
| Lidarr | Established Servarr `/api/v1` with an upstream OpenAPI document and shared Servarr conventions. | Established. Medium adapter risk because provider fields remain dynamic. |
| Seerr | Official `/api/v1` OpenAPI document and Swagger UI. Requests are schema-validated, but responses are not, and the API document version is not tied to the application release. | Public but less mature as a response contract. Medium-to-high adapter risk. |
| qBittorrent | Mature, documented WebUI API v2 with an API-version endpoint and changelog, but no upstream OpenAPI document. | Well established. The collector does not parse it directly; the `*arr` application owns this adapter. |
| Plex | Official versioned API documentation now exists, but this formal contract is newer than the long-lived server API. | Established product with newer contract discipline. The collector does not parse it directly. |

The main risk is not a silent API major change. It is semantic drift inside Servarr's
generic provider `fields` arrays or provider-status representations. Minimum-schema
checks, structured-ID matching, fixtures, and the separate compatibility metric contain
that risk without pretending to eliminate it.

## 7. Metrics contract

The collector exposes these bounded metrics:

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

`source`, `target`, and `integration` come from the static fifteen-edge inventory.
`phase` is a bounded enum such as `inventory`, `configuration`, `probe`, or `poll`.
Application versions and adapter versions have bounded cardinality and exist only on
information metrics.

The collector does not emit a generic `UNKNOWN` integration state. Compatibility and
probe success are independent:

```text
media_integration_probe_compatible{source="sonarr",target="qbittorrent",integration="download_client",check="probe"} 1
media_integration_probe_success{source="sonarr",target="qbittorrent",integration="download_client"} 0
```

This pair is an actual integration failure. A compatibility value of `0` suppresses that
interpretation and identifies adapter work instead.

Raw URLs, provider names, IDs learned from APIs, health messages, validation messages,
exception text, and secret data must not appear in metric labels. Detailed errors go to
bounded, redacted logs.

## 8. Placement, scrape topology, and operation

Run one `media-integration-health` Deployment in `media` with these properties:

- one steady-state replica and a normal `RollingUpdate`;
- a five-minute background poll with jitter, bounded per-request timeouts, and no
  overlapping poll cycle within a replica;
- cached metric responses, so a Prometheus scrape never triggers application API calls;
- one internal Service and one ServiceMonitor, with a stable
  `job="media-integration-health"` label and a one-minute scrape interval;
- no PVC, HTTPRoute, Gatus endpoint, or service-account token;
- a read-only root filesystem and the repository's normal restricted workload settings.

The bounded overlap during a rollout is accepted because every selected probe is
non-persisting and safe to run concurrently. If implementation research disproves that
for a probe, that probe must leave continuous monitoring or this decision must be
superseded. Do not switch the Deployment to `Recreate` merely to avoid duplicate reads.

Liveness and readiness report collector health only: configuration loaded, poll worker
operational, and metrics endpoint serviceable. Source outages, API incompatibility, and
integration failures do not make the pod unready and do not trigger restart loops.

## 9. Credentials and network policy

The collector needs one source API key for each of Prowlarr, Sonarr, Radarr, Lidarr, and
Seerr. The source application owns the key; the operator retains credential custody.

Create purpose-specific SOPS-encrypted Secret artifacts in `media` through the
repository's existing confirmation-guarded, operator-managed SOPS workflow. Existing
Homepage Secrets cannot be mounted across namespaces and their ciphertext must not be
copied as a substitute for operator-managed secret creation. Do not create a collector
credential framework, identity registry, rotation controller, or plaintext migration.

Mount keys as read-only projected files. Do not place them in environment variables,
arguments, metrics, events, or logs. Reread the projected files between poll cycles so a
normal Secret update can take effect without a bespoke restart or rotation mechanism.
The collector accepts the broad scope of the applications' current API keys as residual
risk; it receives no qBittorrent or Plex credential.

A dedicated `CiliumNetworkPolicy` applies only to the collector:

- ingress permits the metrics port from Prometheus workloads in `monitoring`;
- ingress from `host` and `remote-node` is added only if the selected kubelet liveness or
  readiness probe uses the network; an exec probe does not justify it;
- egress permits cluster DNS and only the Prowlarr, Sonarr, Radarr, Lidarr, and Seerr
  workload identities on their named service ports;
- egress does not permit qBittorrent, Plex, the Internet, or a broad namespace CIDR.

No existing Plex or other media application policy changes are required. The downstream
call still originates from the source application, which owns that network path.

## 10. Alerts and response boundaries

All six alerts have `severity: warning`. A failed media integration needs operator
attention but is not evidence of immediate data loss or a reason for automatic
remediation. Metric labels supply only the bounded `source`, `target`, `integration`,
`check`, and `phase` context that exists on the selected series.

The expressions below are the required behavior. Implementation can add repository
namespace selectors without weakening the stated gates.

### `MediaIntegrationCollectorUnavailable`

```promql
absent(up{job="media-integration-health"} == 1)
```

`for: 10m`. The collector cannot be scraped. Check its Deployment, ServiceMonitor, and
metrics ingress. Do not diagnose an application integration from this alert.

### `MediaIntegrationCollectorError`

```promql
(media_integration_collector_error == 1)
or
(time() - media_integration_source_last_poll_timestamp_seconds > 900)
```

`for: 10m`. The adapter violated an invariant or a source snapshot has not completed for
fifteen minutes. Fix or roll back the collector. Do not change an application integration
based on this alert.

### `MediaIntegrationSourceAccessFailed`

```promql
(media_integration_source_access_success == 0)
and on (source)
(time() - media_integration_source_last_poll_timestamp_seconds < 900)
```

`for: 15m`. Investigate the named source application's availability, API credential,
DNS, and allowed collector-to-source path. This alert does not identify a downstream
integration failure.

### `MediaIntegrationAPIIncompatible`

```promql
(
  (media_integration_config_compatible == 0)
  or
  (media_integration_probe_compatible == 0)
)
and on (source)
(media_integration_source_access_success == 1)
and on (source)
(time() - media_integration_source_last_poll_timestamp_seconds < 900)
unless on (source)
(max by (source) (media_integration_collector_error) == 1)
```

`for: 15m`. Update or roll back the named adapter or application version. Do not report
the underlying integration as broken while this alert is active.

### `MediaIntegrationConfigurationInvalid`

```promql
(media_integration_configured == 0)
and on (source, target, integration)
(media_integration_config_compatible == 1)
and on (source)
(media_integration_source_access_success == 1)
and on (source)
(time() - media_integration_source_last_poll_timestamp_seconds < 900)
unless on (source)
(max by (source) (media_integration_collector_error) == 1)
```

`for: 15m`. Correct the named source's expected provider configuration through the
application's normal operator workflow. The alert does not authorize the collector to
write configuration.

### `MediaIntegrationProbeFailed`

```promql
(media_integration_probe_success == 0)
and on (source, target, integration)
(media_integration_probe_compatible == 1)
and on (source, target, integration)
(media_integration_configured == 1)
and on (source)
(media_integration_source_access_success == 1)
and on (source)
(time() - media_integration_source_last_poll_timestamp_seconds < 900)
unless on (source)
(max by (source) (media_integration_collector_error) == 1)
```

`for: 15m`. Investigate the source application's native test and the named target. Do not
rotate a key, change network policy, restart an application, or run a mutating transaction
automatically.

Annotations must describe these same boundaries. They must not include raw upstream
responses, configured URLs, or secret-bearing diagnostic text.

## 11. Validation and independent oracles

`mise exec -- just ci` remains the cluster-independent gate. Stage 5 implementation must
extend it with these independent checks:

1. **Source invariants.** Validate the exact fifteen-edge inventory, one collector and
   scrape target, source-only egress, metrics-only ingress, no public route, no PVC, no
   service-account token, file-mounted Secret references, and alert placement under the
   media alerts application. Mutation tests must prove each important assertion can fail.
2. **Adapter fixture tests.** Use small sanitized fixtures derived from the public API
   contract, with hand-written expected metrics. Cover success, documented integration
   failure, absent configuration, unsupported API major, missing endpoint, missing or
   wrong-typed required field, source-access failure, unexpected exception, and additive
   unknown fields. The expected result must not be generated by the adapter under test.
3. **Promtool rule tests.** Prove a fully healthy snapshot is silent and that source
   outage, API incompatibility, invalid configuration, probe failure, collector error,
   stale polling, and absent scrape each fire only their intended alert. Prove the
   fifteen-minute gates, compatibility suppression of integration alerts, and collector
   error suppression of stale integration results.
4. **Secret-safe rendering.** Validate Secret names, keys, mounts, and SOPS metadata
   without decrypting, copying, or inspecting plaintext values.
5. **Live read-only verification.** After rollout, the operator verifies Flux readiness,
   pod readiness, the Prometheus target, all fifteen expected inventory series, five
   successful source-access series, compatibility values, and configured/probe results.
   Application UIs and their native Test actions are the independent oracle for selected
   collector results. Prometheus queries confirm that healthy rules are silent. Cilium
   flow observation confirms that the collector reaches only its five source services.

Repository rendering cannot prove live credentials, application configuration, native
test behavior, or Cilium enforcement. Live verification is therefore required before
alerts are enabled, but it remains operator-run and outside `just ci`.

## 12. Delivery split and rollout

This work must be split into three smaller implementation projects. The split is a
review and rollback boundary, not an implementation plan:

1. **Collector artifact.** Implement the adapters, metric contract, redaction, fixtures,
   and pinned container image without deploying it to the cluster.
2. **Silent cluster integration.** Add the operator-created encrypted Secrets, collector
   workload, CiliumNetworkPolicy, Service, ServiceMonitor, and source validators. Deploy
   with no alert rules and observe at least three successful five-minute cycles.
3. **Alerts and operating checks.** Add the six rules, promtool cases, live verification
   procedure, and response guidance only after the silent metrics match application-native
   results.

The operator performs the platform rollout. A normal Deployment rollout temporarily
runs at most the bounded rolling overlap; cached scraping prevents Prometheus from
increasing application API traffic. Do not enable alerts until every expected edge is
accounted for as healthy, intentionally invalid, or a documented residual condition.

For rollback, remove or suspend alerts first if their classification is wrong. Roll back
the pinned collector image for an adapter regression. If necessary, remove the
ServiceMonitor and collector workload through Git; this changes no source application
configuration. Encrypted Secrets can remain for a retry or be removed later through the
normal operator workflow. Rollback alone does not require key rotation unless there is
evidence of credential exposure.

## 13. Residual gaps and consequences

After this stage:

- no continuous signal proves a complete Seerr-to-Plex transaction;
- Prowlarr application-sync health remains passive and can lag its scheduled sync cycle;
- passive `*arr` indexer status proves no known recent failure, not a successful synthetic
  search at every poll;
- Plex notification and Seerr Plex discovery can fail because of the external Plex
  account service, so their response boundary is wider than the in-cluster connection;
- provider semantics can drift while a minimum schema still parses; the diagnostic
  application version and separate compatibility path reduce diagnosis time but cannot
  prevent every semantic error;
- broad source API keys remain a larger credential boundary than ideal;
- the collector has one steady-state replica and is not highly available, although
  RollingUpdate avoids a planned scrape gap;
- candidate application images are not contract-tested before deployment;
- the explicitly excluded integrations in §2 remain unmonitored.

The benefit is a stable and testable distinction between five conditions that were
previously collapsed into “the endpoint is up”: source access, API compatibility,
expected configuration, integration probe result, and collector correctness. The cost is
one custom component, five purpose-specific source credentials, one narrow network
policy, and an adapter surface that must follow the applications' public APIs.
