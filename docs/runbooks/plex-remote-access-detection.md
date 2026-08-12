# Plex remote-access detection response runbook

This runbook is the stage-B deliverable named in
[Plex remote access detection — decision](../decisions/2026-08-12-plex-remote-access-detection.md)
§11. It covers the five alerts in the `plex-remote-access` group of
`kubernetes/apps/media/alerts/app/prometheusrule.yaml`, and the stage-C exercise
that closes the companion decision's
[§7.1 gate](../decisions/2026-08-11-plex-direct-remote-access.md) before any DNAT
to Plex is created.

Today there is no DNAT to Plex. `192.168.90.31:32400` is reachable from the LAN
only, because Cilium's `world` entity includes LAN addresses. No off-cluster
client has ever connected. Every alert here has so far only been exercised
synthetically.

## Reading these alerts

Prometheus records only aggregate counts, never source addresses. The Hubble
metrics use `sourceContext=identity`, a bounded-cardinality label, so Prometheus
can say *when* and *how much*, but not *who*. Attribution lives in Hubble itself,
not in Prometheus.

Bounded does not mean single-valued. §4 of the decision says identity context
collapses every off-cluster address to `reserved:world`; measuring the real series
after stage A merged showed otherwise. A CIDR-based policy contributes its own
label to the set, so off-cluster traffic appears as `reserved:world` **and** as
`cidr:192.168.0.0/16,reserved:world`, alongside `reserved:remote-node` and
`reserved:kube-apiserver,reserved:remote-node`. The count stays bounded by the
number of policies rather than the number of hosts, so the cardinality argument
still holds — but every rule matches `source` with the regex
`=~".*reserved:world.*"` rather than equality. Equality would silently miss
everything classified under the CIDR identity.

The first response step for every alert below is therefore always observation,
never action:

```bash
mise exec -- just kube plex-network-observe 600
```

This is read-only and bounded; it shows real source addresses through a local
port-forward without retaining them in the repository or in Prometheus. Run it
before deciding whether an alert reflects legitimate use, a scan, or a false
positive.

### PlexRemoteConnectionFlood (critical)

Off-cluster clients opened more than 5 connections per second to Plex, sustained
for 5 minutes. This is the volumetric case: many complete or attempted
connections in a short window.

Run `plex-network-observe` immediately to see whether the sources are few and
sustained (consistent with a directed flood) or many and scattered (consistent
with broad Internet scanning). Confirm the Plex CiliumNetworkPolicy is intact
and still admits only `world` on `32400`. There is no rate limiting in front of
Plex — see the decision's §8 — so the available response is UniFi-side: block the
observed source at the firewall, or remove the DNAT if the exposure is not
currently required.

### PlexRemoteConnectionRateElevated (warning)

Off-cluster clients opened more than 1 connection per second to Plex, sustained
for 10 minutes. This sits between the flood rule and the probe rule: it catches
full-handshake abuse — real connections, not half-open scans — at a rate too low
to trip the flood threshold and too "complete" (enough flows per connection) to
trip the probe rule.

Observe as above. A sustained elevated rate of genuine connections, none of them
half-open, is more consistent with credential stuffing, API abuse, or a
misbehaving client than with scanning. Check Plex's own dashboard and activity
log for the same window.

### PlexRemoteProbeSurge (warning)

Off-cluster connections to Plex carried fewer than 3 flows each, sustained for 10
minutes, while the connection rate stayed above the noise floor. This is the
scanning signature: a scanner completes a SYN and moves on, so its connections
never accumulate the flow count a real Plex session does.

This rule detects half-open scans only. A completed TCP handshake — even a very
short one, such as a single Plex API call — delivers at least 3 arriving flows,
so it will not trip this rule; that is deliberate, not a gap, because the
alternative (raising the threshold) would trade this false-negative class for a
false-positive class on ordinary short API traffic.

Observe as above. Confirm with Plex's own logs whether any session was
established during the window; if none was, this is consistent with reconnaissance
against the open port and no further action is required beyond continued
observation, since Cilium already denies everything but `32400`.

### PlexRemoteFlowMetricsMissing (critical)

No Hubble flow series for Plex has been present for 15 minutes. Detection may be
blind, but absence of the series can also mean Plex received no traffic at all —
off-cluster or otherwise — during the window, since the underlying metric only
emits a series when a flow occurs. This alert does not by itself distinguish
those two cases.

Check that the `cilium-monitoring` ServiceMonitor and the Cilium DaemonSet are
healthy across all three nodes, and that `hubble.metrics` still lists `flow` in
`kubernetes/apps/kube-system/cilium/app/values.yaml`. If those are healthy and
traffic is known to be flowing (e.g. from `plex-network-observe`), treat this as
a genuine detection failure and stop relying on the other rules until it clears.

### PlexRemoteTcpMetricsMissing (critical)

No Hubble TCP flag series for Plex has been present for 15 minutes. Both
`PlexRemoteConnectionFlood`/`PlexRemoteConnectionRateElevated` and
`PlexRemoteProbeSurge` depend on `hubble_tcp_flags_total`, so this alert, not
`PlexRemoteFlowMetricsMissing`, is the one that actually guards the two
detection rules — the flow metric can be healthy while the tcp metric is
independently broken by a bad `hubble.metrics` edit or a Cilium upgrade renaming
the metric or its `flag` values.

This alert is deliberately not qualified by `source`: absence of the
`reserved:world` series specifically is the normal state today, since no
off-cluster client has ever connected, so only total absence of the metric
(covering every source) is alertable. Same triage as
`PlexRemoteFlowMetricsMissing`: check `hubble.metrics` lists `tcp`, and check the
DaemonSet and ServiceMonitor are healthy.

## Why the rules are shaped the way they are

The rule file itself carries only a pointer here. This section is the record of
why each expression looks the way it does, so that a future edit does not undo a
deliberate choice by mistake.

### Every rate rule filters on `flag="SYN"`

Traffic from `reserved:world` to `media/plex` is dominated by Plex's **own**
outbound connections to plex.tv coming back. Before any DNAT existed, 852 such
flows were recorded and not one of them was an inbound connection.

Hubble records only flows arriving at an endpoint, so the two directions cannot be
separated by source or destination — they carry identical labels. They separate by
TCP flag: an arriving `SYN` means someone opened a connection to Plex, while the
return path of Plex's own egress arrives as `SYN-ACK`, `FIN`, or `RST`. Remove the
`flag="SYN"` filter from any rate rule and it will fire on Plex's ordinary
outbound activity.

### `destination="media/plex"` stands in for port 32400

No Hubble metric carries a port label. The substitution holds only because the
Plex CiliumNetworkPolicy admits no other ingress port. It is an inference from
that policy, not a measurement, and it stops being true the moment the policy
widens to a second port.

### The probe rule measures flows per connection

The decision defines this alert as attempts "that do not become established
sessions". That is not measurable here: establishing a session is something Plex
confirms by replying, and Hubble never observes Plex as a source, so those replies
cannot be counted.

Dividing the off-cluster flow rate by the off-cluster connection rate reaches the
same intent by another route. A streaming session moves many flows down one
connection; a scanner opens one and leaves.

Its second clause — the `> 0.1/sec` floor on the connection rate — is
load-bearing, not decorative. Without it the ratio divides by a near-zero
denominator and fires on noise whenever nobody is connected, which is this
cluster's normal state. The value is low deliberately: the floor exists only to
keep the ratio from dividing by noise, and the `source` regex already does the
work of excluding internal traffic. A higher floor such as `0.5/sec` would demand
300 connections per ten minutes before anything became visible. `0.1` is chosen
for margin and is **not** a measured background rate — no off-cluster traffic to
this port has ever been observed, so there is nothing to measure one against.

Its numerator is imperfect, and biased in the safe direction. It counts all flows
from `reserved:world`, including Plex's plex.tv traffic returning, because the
flow metric carries no `flag` label to filter on the way the TCP metric does. That
inflates the numerator, so the ratio reads higher than reality and the rule errs
toward staying quiet. It never produces a false positive from this.

### There are two `absent()` companions, not one

The detection rules read two metrics. `hubble_flows_processed_total` and
`hubble_tcp_flags_total` can fail independently — a values edit dropping the
`tcp:` entry, or a Cilium upgrade renaming the metric or its `flag` values, would
take out both rate rules while the flow series kept reporting normally. A single
companion on the flow metric left exactly that failure invisible.

Both are unqualified by `source`, on purpose. Absence of the `reserved:world`
series is the normal state today, and alerting on it would page continuously.

The `15m` window on both exceeds a three-node Cilium roll. A shorter window would
flap on every future Cilium change and teach the operator to ignore the alert,
which defeats it more thoroughly than not having it at all.

### Thresholds are provisional

The only measured anchor is internal client traffic: envoy, the host, and Tautulli
together peak at 0.51 connections/sec against a steady 0.30. There is no remote
traffic to calibrate against, because none exists until a DNAT does, and the DNAT
is gated on this work.

| Value | Rule | Reasoning |
|---|---|---|
| `> 5/sec` | Flood | About ten times the measured internal peak |
| `> 1/sec` | Rate elevated | About twice the internal peak, above any plausible household remote load |
| `< 3 flows/conn` | Probe surge | One below the minimum a completed handshake delivers |
| `> 0.1/sec` | Probe surge floor | Low value chosen for margin, as above |

Tune them once real remote traffic exists. The first genuine remote session will
teach more than any reasoning available beforehand.

## Stage C: the synthetic exercise

This is the procedure that closes §7.1 of the companion decision — proving
detection works before any DNAT is created. It requires the operator, a LAN
host, and an attended 15-minute window.

### Why it has to run from a LAN host

Hubble's `world` identity is what every rule above filters on. A pod inside the
cluster carries a cluster identity, not `world`, so an in-cluster test would not
exercise the `source=~".*reserved:world.*"` matcher at all — it would prove
nothing about detection. The traffic has to originate off-cluster, and because no
DNAT exists yet, "off-cluster" here means a LAN host outside the Kubernetes
cluster network, reaching `192.168.90.31:32400` directly.

### Why it has to be a half-open scan

`PlexRemoteProbeSurge` is the rule this exercise most needs to prove, because it
is the one with a subtle failure mode: a normal TCP client delivers at least 3
arriving flows per connection, which is enough to keep the ratio above the `< 3`
threshold and never trip the rule. A `curl` or `nc` loop against port 32400 will
not trigger it — it will look like ordinary (rejected) connections. The exercise
traffic has to be genuinely half-open, i.e. SYN packets with no completed
handshake:

```bash
sudo hping3 -S -p 32400 -i u100000 192.168.90.31
```

This sends roughly 10 SYN/s with no ACK. `nmap -sS` with an explicit rate flag
against the same host and port is an equivalent alternative.

### Timing

Run the generator for the full 15 minutes; do not stop early even after the
first alert fires. Measured in promtool against these rules:

- `PlexRemoteConnectionFlood` fires 7-8 minutes in.
- `PlexRemoteProbeSurge` fires 11-12 minutes in.
- Alertmanager's `group_wait` adds roughly 30 seconds before either reaches ntfy.

Expect notifications on ntfy topics `critical` (from the flood alert) and
`homelab` (from the probe alert). After stopping the generator, confirm both
alerts resolve — Prometheus should stop reporting them firing within a few
evaluation cycles once the SYN rate drops.

### Cautions

A sustained SYN flood at this rate leaves thousands of half-open connections in
Plex's accept backlog. Run the exercise in a quiet window, and never while
anyone is using Plex — this is exactly the resource-exhaustion shape the flood
rule exists to catch, aimed at the real server.

If nothing fires after the full 15 minutes, do not start by adjusting
thresholds. Check first whether the LAN client's traffic actually resolved to
the `reserved:world` identity at all: run `plex-network-observe` during a repeat
of the generator and look at the identity Hubble assigns the source. No
off-cluster client has ever been observed reaching Plex before this exercise, so
stage C is the first real test of that link, not only of the alert thresholds
built on top of it. A LAN CIDR that Cilium classifies as something other than
`world` — for instance because it falls inside a range claimed by an existing
CIDR policy — would silently defeat every rule in this group before the
thresholds are even reached.

## Coverage, stated factually

These rules detect two shapes of off-cluster abuse of Plex's `32400`: sustained
high-rate connection floods, and half-open scanning where connections never
complete a handshake. A rate corridor between those two shapes is covered
separately. Detection depends on aggregate Hubble flow and TCP-flag counts, not
on session data, so it cannot attribute an alert to a specific address —
`plex-network-observe` is the only source of that information, and it is
bounded and read-only rather than continuously retained.

The two `absent()` companions exist because a detector that silently stops
running is worse than no detector: they turn "no alerts" back into evidence
instead of an unverified assumption whenever both underlying Hubble metrics are
healthy.

Detection scope stops at what §2 of the decision names. Repeated authentication
failures and bandwidth saturation are explicitly out of scope and remain
unobserved; both would need infrastructure (a log path, or session-level data)
this design does not add. This is a public repository, so this section states
that boundary as fact and does not further characterize how any specific
detection band could be approached without tripping it.
