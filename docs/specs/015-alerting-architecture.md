# Alerting Architecture

## Purpose

Provide one predictable source, validation, and delivery model for custom Prometheus
alerts. The design consolidates rules by the domain of the component being monitored,
keeps every alert expression under promtool coverage, and adds focused signals for the
monitoring gaps that produced real incidents.

## Problem evidence and scope

This was a slight-to-moderate refactor of an alert estate that had grown one application
at a time, not a replacement monitoring system. A Plex allow-list omission silently
broke Seerr integration for weeks. Lidarr later showed the same event-driven failure
mechanism. The alerts themselves also followed three incompatible placement patterns,
and qBittorrent shipped a `PrometheusRule` without the bootstrap dependency its
Kustomization needed.

The pre-refactor audit found 37 alert definitions, 20 names asserted by promtool, and 17
without a matching assertion. These are historical baseline counts, not a current
inventory. Current source has four domain alert applications and 47 alert names, with
all 47 asserted by name.

The design kept the existing Prometheus, Alertmanager, Gatus, ntfy bridge, severity
routing, and working media-alert pattern. It changed rule ownership, common validation,
coverage, and specific missing signals. Flux reconciliation semantics and ntfy delivery
remain the separate lineages in specifications 005 and 007.

## Rule ownership and placement

Each domain owns one Flux alerts application under
`kubernetes/apps/<domain>/alerts/`. Subject-specific `PrometheusRule` files remain small
inside that application, but all use the `monitoring` namespace. The current domains are:

| Domain | Rule subjects |
| --- | --- |
| `media` | Media availability and persistence, media integration probes, Plex remote access, qBittorrent, and encode benchmark |
| `monitoring` | Flux reconciliation, Gatus, ntfy, Portainer, and test reports |
| `networking` | Tailscale and Plex workload policy denial |
| `security` | Production certificate expiry |

The media, monitoring, and networking alerts applications depend on
`kube-prometheus-stack`. The security alerts application also depends on the separate
`cert-manager-monitoring` layer that supplies its metric. Moving rules out of the
application Kustomizations they watch prevents ordinary workload reconciliation from
depending on a `PrometheusRule` CRD only because it carries an alert.

Rules do not live outside these domain alert applications. The common validator checks
that each rule is wired into its domain Kustomization and that every rule uses the
`monitoring` namespace. Prometheus already discovers rules cluster-wide, so the common
namespace is an organization boundary rather than a discovery requirement.

Current source retains `EncodeBenchmarkJobCompleted` in the media alerts application.
The earlier proposal to delete or reroute that successful-job notification did not
become the implemented architecture.

## Architecture alternatives and rationale

| Placement model | Decision |
| --- | --- |
| Keep every rule beside the application it watches | Rejected. It coupled ordinary workload bootstrap to Prometheus CRDs, repeated validators, and had already left one dependency incorrect. |
| One large rule file per domain | Rejected. It reduced Flux objects but mixed unrelated subjects and made rule review harder. |
| One global alerts application | Rejected. It centralized CRD ownership but erased domain ownership and made every alert change share one reconciliation unit. |
| One alerts application per monitored domain, with small subject files | Selected. It preserves local subject readability, gives each domain one dependency and validator path, and keeps Prometheus CRDs out of ordinary workload applications. |

The common `monitoring` namespace is organizational, not required for discovery;
Prometheus selects rules cluster-wide. Domains are defined by the component being
monitored, which is why certificate rules live in `security/alerts` while Gatus-derived
rules live in `monitoring/alerts`.

The refactor accepted two constraints. An application that still owns a ServiceMonitor
keeps its Prometheus dependency even after its rule moves, so dependency decoupling is
partial. Also, moving a rule between Flux Kustomizations is delete-plus-create, not an
atomic edit. Ownership moves were therefore kept separate from expression changes so a
brief rule-absence window did not also carry changed alert semantics.

## Validation contract

The domain validator extracts `.spec` from the exact `PrometheusRule` files that Flux
applies, checks Prometheus syntax, and runs the matching fixture at
`tests/prometheus/<domain>-alerts_test.yaml`. It also rejects unwired files and rules
placed outside a domain alerts application.

Coverage is tracked by alert name, not by file. The repository-wide coverage check
extracts every `.spec.groups[].rules[].alert` value and requires a matching promtool
assertion. File-level coverage was rejected because adding an untested alert to an
already-tested file would otherwise pass.

The fixtures use synthetic metrics as independent firing and exclusion oracles. They
cover hold times, adjacent healthy conditions, missing-series behavior, and important
selector boundaries. They do not substitute for live target, rule-loading, or delivery
verification.

Alert-name coverage was selected over file coverage because file association cannot
detect a new untested alert added to an already-tested `PrometheusRule`. Each synthetic
fixture must include the intended firing case and adjacent exclusions or missing-series
conditions that would expose a selector regression. A fixture that merely repeats the
expression or asserts only a happy path is not an independent oracle.

## Delivery boundary

Prometheus and Alertmanager retain alert evaluation and lifecycle ownership. The
existing synchronous bridge maps `severity=critical` alerts to urgent messages on the
ntfy `critical` topic and maps `severity=warning` alerts to the `homelab` topic. This
architecture changes rule ownership and signals; it does not create another delivery
path, topic hierarchy, or application-specific notification lifecycle.

## Gatus gap coverage

Gatus remains the black-box probe and metric source. The monitoring alerts application
interprets its stable `group` and `name` labels:

- `GatusEndpointDown` warns after 15 minutes for failed endpoints in the
  `Observability`, `Storage`, or `External` groups.
- `GatewayDataPathDown` is critical after five minutes of failure for
  `Platform/echo`. That probe covers internal DNS, the production Gateway, wildcard
  TLS, routing, and the echo backend as one shared data-path signal.
- `GatusProbeMissing` warns after five minutes when any expected Observability probe,
  `Platform/echo`, `Storage/longhorn-ui`, or `External/letsencrypt-acme` series is
  absent. Missing telemetry is distinct from an endpoint reporting failure.

Application-specific Platform and Media alerts remain in their subject files. The
current production-certificate signal and retirement of permanent staging issuance are
described in [specification 016](016-cert-manager-staging-retirement.md). Media
integration signals are described in the consolidated
[Gatus design](019-media-integration-health-gatus.md).

This gap closure does not add native Longhorn volume-health rules or Trivy finding
alerts. Some workloads have PVC-specific alerts and Longhorn UI reachability coverage,
but those are not a general Longhorn health signal.

The gap audit originally found seven Gatus endpoints that were scraped but had no custom
alert, including the shared Gateway `echo` probe. It also found no certificate-expiry
signal, no native Longhorn volume-health rules, no Trivy finding alerts, and no durable
media-integration health signal beyond process or endpoint reachability. Gatus and
production-certificate coverage were accepted and implemented. Longhorn and Trivy
remained deferred because each needed its own metric survey. Media integration became
the collector and Gatus lineages in specifications 018–019; an early estimate involving
exporter sidecars was not the architecture that ultimately shipped.

## From broad policy-denial proposal to narrow warning

The first policy-denial design proposed two general rules:
`PolicyDeniedSustained` and `PolicyDeniedTotalBlock`. The intent was to distinguish
degraded policy enforcement from an integration that had never forwarded a flow. Live
Prometheus investigation and review invalidated the general classifier.

The evidence had strict limits. Hubble metrics had existed for only about thirty hours,
even when queries used longer selectors. That window proved observed bursts and
missing-series behavior only for the data actually retained; it could not establish a
long-term traffic baseline or prove that a silent consumer was unconfigured.

The general design failed for several independent reasons:

- both ingress and egress policies can produce `POLICY_DENIED`, so a non-empty
  destination does not prove an unintended ingress failure;
- raw Cilium source identities change when namespace labels change, which makes a join
  on the serialized identity unstable;
- a never-created forwarded series is absent rather than equal to zero;
- cumulative forwarded-series presence has the wrong recovery semantics for a
  previously working integration that later becomes blocked;
- import-triggered denials occur as short bursts, so a short rate combined with a
  30-minute hold can miss the whole incident; and
- a silent event-driven consumer produces no denial evidence at all.

The later narrow amendment and current source win. They retain one Plex-specific
warning rather than the two broad rules, and they deliberately omit a forwarded-flow
join. This is distinct from the off-cluster traffic detector in
[specification 014](014-plex-remote-access-detection.md).

## Plex workload policy denial signal

The implemented policy-denial design is deliberately narrower than the original
cluster-wide proposal. One warning detects the demonstrated Plex allow-list failure:

```promql
sum(
  increase(
    hubble_drop_total{
      destination="media/plex",
      reason="POLICY_DENIED",
      source=~".*k8s:io.kubernetes.pod.namespace=.*"
    }[6h]
  )
) >= 3
```

`PlexWorkloadPolicyDenied` holds this condition for 30 minutes. It answers whether
Kubernetes workloads repeatedly tried to reach Plex and Cilium denied the traffic. It
does not name a source, identify which endpoint enforced the policy, or classify the
integration as degraded or completely blocked.

The exact destination excludes Plex's deliberate SSDP and UPnP multicast containment,
which has no workload destination, and excludes denials to other workloads. The source
regular expression matches the Kubernetes namespace label anywhere in Cilium's complete
identity string. This tolerates label ordering and identities that change after a
namespace relabel. Aggregation without source grouping combines those identity variants
into one stable warning; attribution remains a bounded live diagnostic.

The six-hour range preserves short import-triggered denial bursts long enough to satisfy
the 30-minute hold. The threshold of three catches the measured low-volume failure while
leaving one or two isolated packets below the noise boundary. A burst can therefore keep
the alert active until it leaves the range; the hold does not mean denials continued for
30 minutes.

The selected expression was compared with the measured incident shape and a quiet
post-fix baseline. The threshold was low enough to catch the observed four-event
six-hour signature while leaving one or two packets silent. Fixtures then encoded the
exact-three boundary, identity aggregation, deliberate multicast exclusion,
other-destination exclusion, non-workload exclusion, and eventual resolution. This is a
bounded regression warning, not general integration-health proof.

## Policy-denial limits

The Plex warning intentionally omits the broad mechanisms considered in the first
design:

- it does not detect policy denials to destinations other than Plex;
- it does not detect integration failures that produce no `POLICY_DENIED` event;
- it cannot detect a silent consumer that never attempts a connection;
- it does not join forwarded-flow history or distinguish a previously working
  integration from one that never worked;
- it does not determine whether Plex ingress or source-workload egress enforced the
  denial; and
- it does not change Cilium metric contexts or add a recording rule.

A general rule was rejected because policies can enforce both ingress and egress, raw
Cilium source identities are not stable, cumulative forwarded-flow presence has the
wrong recovery semantics, and deliberate containment is not identified by a non-empty
destination alone. Narrowing the query to the demonstrated Plex failure gives each
selector an independent exclusion case and avoids presenting mechanism coverage as
general integration health. Broader classification therefore requires new evidence or
a stronger signal model; a more elaborate query over the same metrics would preserve
the unstable joins and incorrect recovery semantics rather than make the proposed
`Sustained` and `TotalBlock` states truthful.

Sonarr, Radarr, and Lidarr are current admitted Plex consumers on TCP `32400`, alongside
the other validated consumers. The alert guards that allow-list but does not authorize
automatic policy widening. A response must first identify the source and inspect both
policy boundaries and the application's intended configuration.

## Consequences

The repository has one placement rule and one validation path for custom alerts.
Adding a rule without promtool coverage fails the source gate, and moving an alert no
longer requires retaining a subject-specific validator. Domain alert applications add
Flux units, but isolate Prometheus CRD ownership from ordinary workloads.

The additional Gatus, certificate, and Plex-denial signals close demonstrated blind
spots without claiming complete platform or integration monitoring. Alert delivery
still depends on Prometheus, Alertmanager, the bridge, ntfy, and their existing
availability signals.

## Reconsideration and deferred boundaries

Reconsider per-domain ownership if Prometheus CRD bootstrap ordering changes, domains no
longer represent useful ownership units, or one application's rules need an independent
failure or delivery boundary. Reconsider alert-name coverage only if a stronger
independent oracle can detect every untested rule; file-level association remains
insufficient.

Broaden policy-denial detection only with evidence that separates intended egress
containment, unstable identities, missing series, silent consumers, and recovery
semantics. Do not infer general integration health from one Plex warning. Changing the
delivery architecture, topic mapping, or Alertmanager lifecycle also belongs to the
notification lineage rather than this rule-placement design.

Native Longhorn volume health and Trivy finding alerts remain deferred. The implemented
media-integration probes belong to their later specifications and should not be folded
back into this architecture merely because their rules live in the media alerts
application.
