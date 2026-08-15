# Plex workload policy denial alert — amendment

- **Status: Accepted.** Approved by the operator on 2026-08-14.

Date: 2026-08-14.
Branch: `dispatch-policy-denied-alert`.

Amends [Alerting architecture — decision](2026-08-13-alerting-architecture.md).

This document is additive. It supersedes only the Stage 3 design in §6 and §6.1 of
the 2026-08-13 decision: two general network-policy alerts become one warning alert
for the demonstrated Plex allow-list failure. Stages 1 and 2 remain complete and
unchanged. The Stage 4 audit work and Stage 5 integration-health commitment also
remain in force.

## 1. Decision

Add one `PlexWorkloadPolicyDenied` warning alert to
`kubernetes/apps/networking/alerts/app/network-policy.yaml`:

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

Set `for: 30m` and `severity: warning`.

The alert answers one question: has a Kubernetes workload repeatedly tried and
failed to reach Plex because Cilium policy denied it? It does not classify the
failure as degraded or completely blocked. The response procedure uses the existing
Hubble and Prometheus diagnostics to identify the source.

Do not change the Cilium Hubble metric contexts. Do not add recording rules, stable
label projections, traffic-direction labels, a forwarded-flow join, or a critical
companion alert in this stage.

## 2. Why the scope is narrow

Every demonstrated allow-list omission had the same shape: Seerr, Lidarr, or Radarr
was a Kubernetes workload attempting to reach `media/plex`, and Cilium reported
`POLICY_DENIED`. The broad Stage 3 design tried to generalise that mechanism across
all five policy-owning applications and distinguish sustained degradation from a
total block.

Review and live measurement showed that the general form needs several additional
choices:

- all five policies enforce egress, so a non-empty destination does not establish
  that ingress policy caused the drop;
- the serialised Cilium source identity changes when namespace labels change;
- cumulative forwarded-series presence cannot detect a previously working pair that
  later becomes blocked;
- thresholds and lookback windows determine whether retained pre-fix counters cause
  an alert immediately after deployment.

Those problems are real only because the proposed alert was broader than the
demonstrated need. The 2026-08-13 decision already bounds Stage 3 as a regression
guard on the Plex allow-list, not general integration monitoring. This amendment
implements that bound directly.

## 3. Existing foundation from Stages 1 and 2

Stage 1 placed all Prometheus rules in one alerts application per domain. The
networking application and its generic validator already provide the placement for
this rule:

```text
kubernetes/apps/networking/alerts/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    └── tailscale.yaml
```

`scripts/validate/alerts.sh networking` verifies the Flux dependency, rule namespace,
Kustomize wiring, Prometheus syntax, and the domain promtool fixture. Stage 2 requires
every alert name to appear in a promtool assertion through
`scripts/validate/alerts-coverage.sh`. At this decision's baseline, all 33 existing
alerts are asserted and all three domain validators pass.

The Hubble metrics required by the new alert already exist. Cilium exports `drop`,
`flow`, and `tcp` with `sourceContext=identity` and
`destinationContext=workload`. The Cilium validator pins those contexts and rejects
IP or pod fallbacks that would create unbounded or rollout-dependent labels.

## 4. Expression rationale

### 4.1 Exact destination instead of a general policy inventory

`destination="media/plex"` is stable because the repository pins
`destinationContext=workload`. It excludes the deliberate Plex SSDP and UPnP multicast
drops, whose destination is absent. It also excludes Plex egress denied to some other
in-cluster workload, because that event carries the other workload as its destination.

An egress-enforced drop from another workload whose destination is Plex can still
match. That is accepted: the observable outcome is still that an in-cluster workload
cannot reach Plex, which is the failure this alert reports. The alert does not claim
which endpoint's policy enforced the denial.

### 4.2 Workload selector without workload attribution

`source=~".*k8s:io.kubernetes.pod.namespace=.*"` selects a Kubernetes workload identity
and excludes `reserved:world`, host, remote-node, CIDR, and other non-workload sources.
It is a substring regular expression because `sourceContext=identity` serialises the
complete identity label set and does not guarantee where the namespace label appears.

The alert deliberately uses `sum(...)` without grouping by the raw source. Namespace
relabeling can mint a new identity for the same workload, but both identities still
contribute to one alert. Source attribution remains a diagnostic action rather than an
alert label.

### 4.3 Six-hour increase and threshold

The import integrations are event-driven. A failed import produces a short denial
burst and then becomes quiet, so a short rate combined with `for: 30m` can miss the
entire failure. `increase(...[6h])` keeps a burst observable long enough for the alert
to reach firing state and ignores retained counters that did not increase in the
current window.

The threshold is three events. The smallest measured broken signature was four Lidarr
denials in six hours, so three catches the demonstrated low-volume case while accepting
that one or two isolated packets may remain silent. Prometheus can extrapolate counter
increases to fractional values; the threshold is an operational noise boundary, not an
exact packet-count assertion.

`for: 30m` delays notification. It does not mean denials continued for thirty minutes:
the six-hour range keeps a completed burst in the expression. The alert can remain
active until that burst leaves the range.

## 5. Deliberate omissions

This stage does not detect:

- policy denials whose destination is not Plex;
- Plex integration failures that do not produce `POLICY_DENIED`;
- a silent or absent consumer that never attempts a connection;
- whether a denied consumer has forwarded traffic in the same or an earlier window;
- whether the enforcing policy was ingress or egress;
- one or two isolated denied packets in six hours.

It also does not change Cilium metric labels or roll the Cilium DaemonSet. General media
integration health remains Stage 5 work. Broader policy-denial coverage requires new
evidence that its value justifies the extra metric and query contract; it is not an
implicit follow-up to this amendment.

## 6. Evidence

The exact selected expression was queried read-only against live Prometheus on
2026-08-14:

| Window | Increase |
| --- | ---: |
| 6 hours | 0 |
| 24 hours | approximately 28 |
| 7 days | approximately 7,399 |

The 24-hour events were the pre-fix Radarr denials. The longer window also includes the
known Seerr and Lidarr incidents. The six-hour zero proves the rule would be inactive at
the decision baseline while the historical values show that the same expression sees
the incidents it is intended to catch.

Sonarr, Radarr, and Lidarr still have no measured forwarded series to Plex after their
allow-list admission. That positive verification remains useful for their application
configuration but does not block this alert, because the expression does not depend on
forwarded-flow history.

## 7. Validation and response

Implementation adds the rule file to the existing networking alerts Kustomization and
adds promtool cases to `tests/prometheus/networking-alerts_test.yaml` that prove:

- fewer than three matching denials stay silent;
- three matching denials become pending and then firing after thirty minutes;
- a high-volume drop with no destination stays silent;
- a high-volume denial to a destination other than Plex stays silent;
- a `reserved:world` or other non-workload source stays silent;
- a compound workload identity matches regardless of label position;
- the alert resolves after the denial burst leaves the six-hour range.

Mutation checks must prove that removing the destination, reason, or workload-source
filter makes at least one silent case fail. The alert coverage validator must discover
the new alert name. The full offline gate is `mise exec -- just ci`.

After the operator merges the implementation, read-only live verification confirms
that Prometheus loaded the rule, reports it healthy, and leaves it inactive. The Plex
remote-access runbook gains the alert response: inspect the grouped drop query first,
then use `mise exec -- just kube plex-network-observe` when source attribution is needed.

## 8. Risks

- **Partial coverage is intentional.** The alert catches the demonstrated Plex
  allow-list failure, not most possible network-policy failures.
- **Identity formatting remains an upstream contract.** The rule depends only on the
  standard Kubernetes namespace label appearing somewhere in an identity, not on label
  ordering or equality. The pinned Cilium context validator and compound-identity
  promtool case guard the repository side of that contract.
- **Aggregation trades attribution for stability.** One alert does not name the source.
  The response needs a Prometheus grouping query or Hubble observation.
- **The alert lingers.** A burst can keep the expression true for up to six hours. That
  is accepted so low-frequency import integrations remain detectable.
- **Threshold misses are accepted.** One or two events can be real. The threshold favors
  a durable warning signal over complete packet-level coverage.

## 9. Decision record

| Decision | Outcome |
| --- | --- |
| Stage 3 scope | Kubernetes workload denied while reaching Plex |
| Alerts | One: `PlexWorkloadPolicyDenied` |
| Severity | Warning |
| Condition | At least three matching denials in six hours, held for thirty minutes |
| Attribution | Out of band through Prometheus grouping or Hubble observation |
| Forwarded-flow join | Rejected for this stage |
| Cilium metric changes | None |
| General policy-denial coverage | Deferred unless new evidence justifies it |
| Stage 5 integration health | Unchanged |
