# Plex Remote-Access Detection

## Purpose

Detect sustained off-cluster connection abuse and half-open scanning against Plex's
direct TCP `32400` path. The design uses aggregate Hubble metrics in Prometheus and the
existing Alertmanager-to-ntfy route. It deliberately keeps source-address attribution
out of Prometheus.

## Signal architecture

Cilium exports the `flow`, `tcp`, and `drop` Hubble metric sets with
`sourceContext=identity` and `destinationContext=workload`. Identity avoids a Prometheus
series for every public source address. Workload context remains stable across Plex pod
rollouts, unlike a pod-name label. Validators require these exact contexts and reject
fallback lists containing `ip` or a rollout-dependent destination.

Enabling the metrics creates the headless `hubble-metrics` Service on port `9965`. A
hand-written ServiceMonitor scrapes its `hubble-metrics` port every 30 seconds and adds
the Kubernetes node name. It is reconciled separately after kube-prometheus-stack so
Cilium's bootstrap values do not contain a Prometheus CRD that would be unavailable on
a bare cluster.

The metrics endpoint is unauthenticated on the LAN and exposes aggregate cluster flow
labels, not only Plex data. This matches the existing Cilium host-port posture but
remains a real information boundary. Adding TLS would require certificate management and
matching ServiceMonitor configuration.

## Alert semantics

The `plex-remote-access` Prometheus rule group contains five alerts:

| Alert | Severity | Condition |
| --- | --- | --- |
| `PlexRemoteConnectionFlood` | Critical | More than 5 inbound SYNs per second for 5 minutes, measured over a 5-minute rate window |
| `PlexRemoteConnectionRateElevated` | Warning | More than 1 inbound SYN per second for 10 minutes, measured over a 10-minute rate window |
| `PlexRemoteProbeSurge` | Warning | Fewer than 3 flows per inbound SYN while SYN rate exceeds 0.1 per second, held for 10 minutes over a 10-minute window |
| `PlexRemoteFlowMetricsMissing` | Critical | No Plex flow series for 15 minutes |
| `PlexRemoteTcpMetricsMissing` | Critical | No Plex TCP-flag series for 15 minutes |

Every rate expression selects `destination="media/plex"`, a source identity containing
`reserved:world`, and TCP `flag="SYN"`. The source uses a substring regular expression
because Cilium can combine `reserved:world` with a matching CIDR policy identity. Exact
equality would miss those bounded compound identities.

The `SYN` filter distinguishes a client opening a connection to Plex from traffic
returning from Plex's own outbound connections. Without it, normal Plex-cloud activity
arriving as SYN-ACK, FIN, or RST would look like remote connection demand.

Hubble metrics do not carry a destination-port label. The stable Plex workload name
stands in for port `32400` only because the Cilium policy admits no other Plex ingress
port. If another ingress port is added, these expressions no longer describe `32400`
alone and must be redesigned.

## Probe and threshold rationale

Hubble observes flows arriving at Plex but cannot see Plex's replies as source-side
events in the same metric. The probe rule therefore cannot directly count established
sessions. It divides incoming flow rate by incoming SYN rate: a real streaming session
carries many flows on one connection, while a half-open scanner sends a SYN and moves
on.

The `> 0.1` SYN-per-second floor prevents division by an almost-zero denominator during
idle periods. The flow numerator also includes return traffic from Plex's own external
connections because the flow metric has no TCP-flag label. That biases the ratio upward
and can hide probing; it does not create a false-positive probe alert.

The thresholds began as provisional values because direct remote traffic did not exist
when detection was required. The measured internal peak was about 0.51 connections per
second. The flood threshold is roughly ten times that peak, the elevated-rate threshold
roughly twice it, and three flows is one below the minimum seen for a completed
handshake. These remain household-scale operational boundaries, not a learned Internet
baseline.

## Missing-signal coverage

Flow and TCP metrics can fail independently. The two `absent()` companions prevent a
healthy flow series from hiding loss of the TCP metric used by every rate rule. They
match Plex across all sources rather than only `reserved:world`, because having no
off-cluster series can be a legitimate idle state.

Absence remains ambiguous. Hubble creates a destination series only after traffic, so a
missing Plex series can mean either detector failure or no Plex traffic. The alert is a
prompt to check the Cilium DaemonSet, metrics configuration, ServiceMonitor, Prometheus
target, and known live traffic; it is not proof that collection failed. The 15-minute
hold exceeds an ordinary three-node Cilium roll to reduce planned-change flapping.

## Attribution boundary

Prometheus answers when traffic changed and how much aggregate activity occurred. It
does not retain public client addresses. Source attribution uses the bounded, read-only
`plex-network-observe` diagnostic against live Hubble data. That separation avoids an
unbounded source-IP label surface and avoids retaining client addresses in this public
repository's monitoring history.

For the same reason, the alerts cannot identify a specific attacker, user, account, or
Plex session. Any response begins with live observation and comparison with Plex's own
activity data before firewall action.

## Proof

Promtool tests extract the expressions from the same PrometheusRule that Flux applies.
They prove pending and firing timing, resolution, internal-source exclusions, compound
`reserved:world` identities, idle probe behavior, real-session silence, the full-
handshake rate corridor, and independent loss of the flow and TCP metrics. This is
stronger than syntax checking because the test data independently exercises each
semantic branch.

A live half-open exercise from a LAN host outside the cluster produced about 16.5 SYNs
per second. The flood, elevated-rate, and probe-surge alerts fired and reached their ntfy
routes. An in-cluster generator would not prove the source matcher because it would have
a cluster identity rather than `world`.

## Limits

The detector does not cover repeated Plex authentication failures, account abuse,
bandwidth saturation, successful low-rate probing, or application-layer request shape.
Those require Plex session data or logs, and the cluster has no general log collector.
It also does not provide rate limiting; that would require a compatible proxy or another
control in front of Plex.

The probe ratio can miss scanning because its numerator includes unrelated Plex return
traffic. The thresholds can produce household-specific false positives and need evidence
before tuning. Alert delivery still depends on the existing Alertmanager and ntfy path.
These boundaries are explicit so absence of an alert is not treated as proof that the
public listener is safe.
