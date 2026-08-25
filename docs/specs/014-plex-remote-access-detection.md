# Plex Remote-Access Detection

## Purpose

Detect sustained off-cluster connection abuse and half-open scanning against Plex's
direct TCP `32400` path. The design uses aggregate Hubble metrics in Prometheus and the
existing Alertmanager-to-ntfy route. It deliberately keeps source-address attribution
out of Prometheus.

Detection was a hard gate before durable Internet exposure. At the start, the cluster
had Hubble Relay but did not export or scrape Hubble metrics, collect Plex request logs,
or retain any durable signal for the public listener. Operator attendance was not
accepted as a substitute for a detector that could continue to evaluate after the
change window closed.

## Signal alternatives

| Signal | Decision |
| --- | --- |
| Hubble metrics with identity/workload context | Selected. They existed at the network-policy boundary, could be enabled before exposure, bounded label cardinality, and supported synthetic Prometheus tests. |
| Per-source-address Prometheus labels | Rejected because an Internet-facing port could create an unbounded series per probing address. Live Hubble remains the bounded attribution tool. |
| Plex logs or API data | Deferred. They could cover authentication and sessions, but the cluster had no log collector or pre-exposure application exporter. |
| Tautulli export | Deferred because it observes application sessions rather than all connection attempts and required another authenticated collection path. |
| Router syslog | Not selected as the durable repository signal. Its schema and retention were external to the cluster, and it did not establish the Hubble policy identity contract. |
| Chart-generated ServiceMonitor | Rejected because the same Cilium values bootstrap a bare cluster before Prometheus CRDs exist. |
| In-cluster traffic generator | Rejected for live source-matcher proof because it carries a cluster identity rather than `world`. |

The detector is a companion control for [direct exposure](013-plex-direct-remote-access.md),
not evidence that the listener is safe by itself. The separate
`PlexWorkloadPolicyDenied` rule in
[specification 015](015-alerting-architecture.md) detects an in-cluster allow-list
regression and is not part of this public-traffic detector.

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

## Staged evidence method

The metric contract was observed before alert expressions were written. First, Cilium
enabled `flow`, `tcp`, and `drop`, and Prometheus scraped the hand-written monitor. The
emitted metric names and label values then became evidence for the rule selectors. This
ordering prevented a predicted label schema from being mistaken for an implemented
signal.

Synthetic promtool fixtures next proved firing, hold, missing-signal, recovery, and
adjacent exclusion behavior from the exact applied rule expressions. The final live
exercise used a host outside Kubernetes so Cilium supplied an off-cluster identity. It
required both firing and resolved notification evidence through the established route;
source details remained private.

The method separated four oracles:

- source and rendered validation proved metric contexts, bootstrap-safe monitor wiring,
  and rule syntax;
- fixtures proved selected PromQL behavior on controlled counter series;
- deployed checks proved the rules and scrape targets were loaded and healthy at a
  point in time; and
- controlled off-cluster traffic proved one live traffic shape reached Alertmanager and
  ntfy.

None of these alone proves continuous detector health, every Internet source, a
completed handshake, authentication behavior, normal playback, or phone display.

## Alert semantics

The `plex-remote-access` Prometheus rule group contains five alerts:

| Alert | Severity | Condition |
| --- | --- | --- |
| `PlexRemoteConnectionFlood` | Critical | More than 5 inbound SYNs per second for 5 minutes, measured over a 5-minute rate window |
| `PlexRemoteConnectionRateElevated` | Warning | More than 1 inbound SYN per second for 10 minutes, measured over a 10-minute rate window |
| `PlexRemoteProbeSurge` | Warning | Fewer than 3 flows per inbound SYN while SYN rate exceeds 0.1 per second, held for 10 minutes over a 10-minute window |
| `PlexRemoteFlowMetricsMissing` | Critical | No Plex flow series for 15 minutes |
| `PlexRemoteTcpMetricsMissing` | Critical | No Plex TCP-flag series for 15 minutes |

Every TCP connection-rate expression selects `destination="media/plex"`, a source
identity containing `reserved:world`, and `flag="SYN"`. The probe rule's flow-rate
numerator selects the same destination and source but cannot select a TCP flag because
`hubble_flows_processed_total` has no flag label. Its denominator and rate floor use the
SYN-filtered TCP metric. The source uses a substring regular expression because Cilium
can combine `reserved:world` with a matching CIDR policy identity. Exact equality would
miss those bounded compound identities.

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

The `0.1` SYN-per-second probe floor is a low margin choice. It was not derived from a
measured Internet-noise rate. An earlier unsupported background-noise claim was removed
rather than used to justify a higher `0.5` floor that would hide slower scanners.

## Implementation corrections

The accepted design initially described three alerts: flood, probe surge, and missing
flow metrics. Review and fixture work exposed three gaps:

1. TCP metrics could disappear while flow metrics remained present, making all
   connection-rate expressions blind without triggering the flow-missing alert.
2. Completed-connection abuse between one and five SYNs per second sat below the flood
   threshold and above the low-flow-per-SYN probe classifier.
3. The original `0.5` SYN-per-second probe floor hid slower scanning without evidence
   that such traffic was normal background noise.

The implemented design therefore has five rules: it adds
`PlexRemoteTcpMetricsMissing`, adds `PlexRemoteConnectionRateElevated`, and lowers the
probe floor to `0.1`. These changes close the known blind spots without claiming full
application-layer coverage.

One label assumption also changed. Identity context does not always emit exact
`reserved:world`; a CIDR policy can produce a compound identity containing that value.
The current substring matcher is authoritative. Cardinality remains bounded by policy
identities rather than public hosts, and the fixtures include the compound case so exact
equality cannot return silently.

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

The alert validator extracts each rule file's `.spec` from the PrometheusRule that Flux
applies, then runs promtool against those extracted rules. The Plex fixtures assert:

- the probe alert is non-firing at an earlier evaluation and firing later for a low
  flow-per-SYN counter series;
- a higher flow-per-SYN series and an idle series keep the probe alert silent;
- each missing-metric alert fires after its hold, including independent TCP-metric loss
  while the flow metric remains present;
- an elevated SYN-rate series below the flood threshold fires the elevated-rate alert;
- busy internal-source series do not fire the elevated-rate or flood alerts; and
- a compound CIDR plus `reserved:world` identity fires the flood alert.

These fixtures use synthetic Hubble counters. They do not prove completed TCP handshakes
or alert recovery and resolution after firing. Their value beyond syntax checking is the
independent firing and exclusion behavior they actually assert.

A live half-open exercise from a LAN host outside the cluster produced about 16.5 SYNs
per second. The flood, elevated-rate, and probe-surge alerts fired and reached their ntfy
routes. An in-cluster generator would not prove the source matcher because it would have
a cluster identity rather than `world`.

That live result proved the chosen half-open traffic shape and the notification route at
that time. It did not prove TCP handshakes, authentication, every off-cluster identity,
alert recovery under every rule, or normal remote playback. Current acceptance requires
resolved notification evidence separately rather than projecting it backward into this
exercise.

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

## Reconsideration boundary

Adding any second Plex ingress port invalidates the workload-name proxy for TCP `32400`
and requires new metric or policy discrimination. Changing Hubble contexts, scrape
architecture, source-identity format, public address families, or the front-door proxy
also requires revalidation of the signal contract.

Threshold tuning requires measured household and remote evidence. A false positive or
miss is not permission to adjust one constant without rechecking the neighboring flood,
connection-rate, probe-ratio, and missing-signal cases. Authentication abuse, bandwidth,
request shape, durable client history, and rate limiting remain separate future designs.
