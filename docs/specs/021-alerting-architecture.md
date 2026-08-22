# Alerting Architecture

## Purpose

Provide one predictable source, validation, and delivery model for custom Prometheus
alerts. The design consolidates rules by the domain of the component being monitored,
keeps every alert expression under promtool coverage, and adds focused signals for the
monitoring gaps that produced real incidents.

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
described in specification 026. Media integration signals are described in
specifications 030 and 031.

This gap closure does not add native Longhorn volume-health rules or Trivy finding
alerts. Some workloads have PVC-specific alerts and Longhorn UI reachability coverage,
but those are not a general Longhorn health signal.

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
general integration health.

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
