# Plex workload policy denial Stage 3 closure — amendment

- **Status: Accepted.** Approved by the operator on 2026-08-14.

Date: 2026-08-14.
Branch: `dispatch-policy-denied-alert`.

Amends:

- [Alerting architecture — decision](2026-08-13-alerting-architecture.md)
- [Plex workload policy denial alert — amendment](2026-08-14-plex-workload-policy-denial-alert.md)

This record supersedes only the unresolved Stage 3 decisions in §11 items 1, 4, 5,
6, 7, and 9 of the 2026-08-13 decision. It does not supersede the remaining stages
or unrelated open decisions.

## 1. Decision

Stage 3 is no longer blocked.

Add one `PlexWorkloadPolicyDenied` warning using the expression, duration, and
severity accepted in the 2026-08-14 Plex workload policy denial amendment.

The following Stage 3 decisions are final:

- Sonarr, Radarr, and Lidarr were admitted to Plex ingress on TCP `32400` on
  2026-08-14. The pinned consumer set and validator mutation cases were updated
  with that admission. The consumer prerequisite is complete.
- The alert uses `destination="media/plex"` instead of a general policy inventory.
  This excludes empty-destination multicast and denials to other workloads.
- A source workload's egress policy can still enforce a matching denial. This is
  accepted because the observable outcome remains that a Kubernetes workload
  cannot reach Plex. The response procedure inspects both policy boundaries.
- The workload selector is
  `source=~".*k8s:io.kubernetes.pod.namespace=.*"`. It matches the Kubernetes
  namespace label anywhere in the complete Cilium identity.
- The condition is an aggregate six-hour `increase(...) >= 3`, held with
  `for: 30m`.
- The alert uses `sum(...)` without source grouping and does not join against
  forwarded-flow metrics. Namespace label changes can create new source
  identities, but all matching identities contribute to the same alert.
- Forwarded-flow classification is deliberately omitted. The alert does not
  distinguish a previously working integration from one that never worked.
  General integration health remains separate work.

## 2. Response boundary

A matching alert does not prove which endpoint enforced the denial.

The operator first groups the bounded increase by `source`, identifies the
workload, and inspects both:

- Plex ingress policy; and
- any egress policy selecting the source workload.

The Plex ingress allow-list and its pinned validation files change only when Plex
ingress admission is missing. A source egress policy changes only when that policy
is the enforcing boundary and the traffic is intended. Otherwise, the operator
inspects the source application's configuration instead of widening policy.

## 3. Validation

Promtool coverage must prove:

- two matching events remain silent;
- exactly three matching events fire after `for: 30m`;
- changing the threshold to `>= 4` makes the exact-three case fail;
- changing the threshold to `>= 2` makes the two-event case fail;
- destination, reason, and workload-source exclusions each have an independent
  silent-case oracle;
- changing source identities aggregate into one alert;
- the alert resolves after the denial burst leaves the six-hour window.

The existing Cilium metric-context validator remains authoritative. Stage 3 makes
no Cilium, ServiceMonitor, recording-rule, or forwarded-flow change.

## 4. Closed items

| 2026-08-13 §11 item | Outcome |
| --- | --- |
| 1 — consumer prerequisite | Complete |
| 4 — second exclusion | Replaced by the narrow Plex destination scope |
| 5 — source matcher | Namespace-label substring matcher |
| 6 — threshold and window | Three events in six hours, held for 30 minutes |
| 7 — forwarded-flow blind spot | Accepted and deliberately omitted |
| 9 — unstable identity join | No join; aggregate all matching identities |

The unrelated `EncodeBenchmarkJobCompleted` decision in §11 item 3 remains outside
this amendment.
