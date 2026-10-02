# Plex Remote-Access Detection

## Intent and signal

Detect sustained off-cluster connection abuse and half-open scanning against the
[direct Plex listener](013-plex-direct-remote-access.md). Detection is required before
durable exposure; operator attendance cannot replace ongoing evaluation.

Hubble network metrics feed Prometheus and the existing Alertmanager/ntfy path. Source
identity and stable destination-workload contexts avoid unbounded public-address labels
and rollout-dependent Pod names. [Cilium configuration](../../kubernetes/apps/kube-system/cilium/)
and [media rules](../../kubernetes/apps/media/alerts/) own exact metric sets, selectors,
thresholds, holds, and severity. The separately reconciled ServiceMonitor keeps
Prometheus CRDs out of bare-cluster Cilium bootstrap.

The endpoint is unauthenticated on the LAN and exposes aggregate cluster flow metadata;
this accepted information boundary is not Plex-only data. Changing host ingress or adding
metrics TLS needs a broader platform decision. Raw client attribution stays outside
Prometheus, in bounded authorized Hubble diagnostics.

## Interpretation and limits

Incoming SYNs distinguish new client demand from replies to Plex's outbound connections.
Cilium can emit a compound identity containing `reserved:world`; exact equality would
miss it. Workload context stands in for TCP `32400` only while policy admits no other Plex
ingress port. Adding another port requires redesign.

The probe ratio compares incoming flows with SYNs; it does not count completed sessions.
Streaming normally has many flows per connection, while half-open scanning has fewer.
The flow numerator includes unrelated return traffic because it lacks TCP flags, biasing
the ratio upward and potentially hiding probing. Its nonzero rate floor prevents idle
division from becoming a signal. Thresholds are provisional household boundaries,
not a learned Internet baseline; tune only with measured neighboring-case evidence.

Flow and TCP metrics can disappear independently, so both need absence companions.
They select Plex across all sources because no off-cluster traffic is a legitimate idle
state. Hubble creates series after traffic: absence can mean idle Plex or failed collection.
Check Cilium, configuration, scrape targets, and known traffic before classifying it.

This detector does not identify clients/users, prove handshakes, detect every authentication
failure, account abuse, bandwidth saturation, or low-rate probing, or enforce rate limits.
Centralized logs in [specification 022](022-grafana-alloy-loki.md) do not automatically
supply those application signals. No alert is not proof that public exposure is safe.

## Assurance and attended test

Source/render checks validate contexts and bootstrap-safe wiring; promtool fixtures
validate exact applied rules and adjacent exclusions; deployed verification establishes
loaded target/rule health. Live traffic acceptance is a separate operator-attended,
disruptive exercise and proves only its controlled source/shape.

Before testing, accept the normal Plex path, require all targets/rules healthy with no
missing-metric or preexisting traffic alert, arrange a household-idle window, and approve
one off-cluster generator bound to the exact Plex destination/port. Scoped Kubernetes
credentials do not authorize external traffic generation or private runtime capture.

1. Start `mise exec -- just kube plex-network-observe 600` under operator diagnostic
   authority and sample the generator. Require an identity containing `reserved:world`;
   an in-cluster Pod cannot prove this matcher.
2. From that approved host send bounded half-open SYN traffic, for example
   `sudo hping3 -S -p 32400 -i u100000 <plex-load-balancer-address>`, for the attended
   15-minute window. Ordinary HTTP or connect loops produce a different flow/SYN shape.
3. Require flood, elevated-rate, and probe-surge alerts plus matching severity-topic
   notifications. Watch Plex health, telemetry, and exact generator attribution throughout.
4. Stop the generator and confirm exit, falling rates, all three alerts resolved, matching
   resolved notifications, and healthy `plex-verify`.

Abort on household use, performance regression, unexpected pressure/source, failed identity
or destination confinement, unhealthy telemetry, or inability to stop. Do not raise load
or lower thresholds to compensate. If firing fails, inspect identity, incoming SYNs,
matching flows, scrape health, and rule evaluation in that order. If resolution fails,
check surviving traffic/generator and stale data before editing rules. Keep runtime
addresses, accounts, tokens, and raw observation private.

## Response and stop conditions

For active or uncertain material risk, remove the direct DNAT first using
[specification 013](013-plex-direct-remote-access.md#disable-exposure); restart only if
established sessions must be evicted. Otherwise observe briefly and compare Hubble time/
source with Plex Dashboard, Tautulli, and known household activity.

Detector absence requires inspection of the complete collection path and known live
traffic. Remove exposure if blind detection makes it untrustworthy; fix durable source
through Git. Workload policy denial is [a separate warning](015-alerting-architecture.md#plex-policy-denial):
identify the consumer and ingress/egress boundary before changing the minimal intended
policy. Unintended consumers remain denied. Never widen policy from an aggregate alert.

Require new off-site connections blocked after containment, inspect old sessions separately,
and retain local playback/verification. For repaired telemetry require known traffic and
cleared alerts; for a policy fix require the real integration without new denials.
Escalate on uncertain attribution, continuing material traffic, unsafe session eviction,
blind telemetry, unclear integration ownership, or any need for broader authority.
