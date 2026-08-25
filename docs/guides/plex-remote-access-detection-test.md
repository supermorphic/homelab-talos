# Test Plex remote-access detection

Use this attended exercise to prove one controlled Plex security-detection path from
off-cluster traffic through Hubble, Prometheus, Alertmanager, and ntfy.

This test deliberately sends half-open TCP traffic to the production Plex listener. It
does not configure Plex remote access and is not part of routine production acceptance.
First establish and accept the normal path with
[Operate Plex direct remote access](plex-remote-access-operations.md).

[Specification 014](../specs/014-plex-remote-access-detection.md) records the detector's
signal design, thresholds, evidence, and limits.

## Detection-test model

```text
approved off-cluster generator
        ↓
bounded SYN-only traffic to Plex TCP 32400
        ↓
Cilium and Hubble metrics
        ↓
Prometheus rules
        ↓
Alertmanager
        ↓
alertmanager-ntfy
        ↓
ntfy critical and homelab topics
        ↓
operator confirms firing and resolved notifications
```

This is an operator-attended, disruptive security test. It proves one aggregate traffic
shape. It does not prove Plex authentication, normal playback, or every possible attack
pattern.

## Command effects and authority

| Operation | What it does | Effect and authority |
| --- | --- | --- |
| `plex-validate`, `cilium-validate`, and alert validators | Check local source, rendered policy, metrics, and Prometheus fixtures | Local, read-only, shared validation |
| `plex-verify`, `cilium-verify`, `monitoring-verify`, and `alertmanager-ntfy-verify` | Observe live readiness and implemented wiring assertions | Approved scoped verification; no synthetic notification |
| `plex-network-observe` | Opens a bounded Hubble port-forward and prints live Plex flows | Operator-only read diagnostic because it exposes private runtime source data |
| `hping3` or an approved equivalent | Sends deliberate half-open SYN traffic to the production Plex port | Operator-attended disruptive external activity |
| `flux-alert-delivery-test` | Creates and removes a temporary failing Flux object to prove firing and resolved delivery | Separate operator-run state-changing test |

The external traffic generator requires suitable authority on a host outside Kubernetes.
Scoped cluster credentials do not authorize an agent to run it. A confirmation guard on
another command also does not transfer authority to this manual exercise.

## Test-specific prerequisites

Do not repeat this test merely to validate normal remote access. Use it only when the
detection pipeline itself needs acceptance or revalidation.

### 1. Validate source

Run the current cluster-independent checks:

```bash
mise exec -- just kube plex-validate
mise exec -- just kube cilium-validate
mise exec -- just kube alerts-validate media
mise exec -- just kube alerts-validate networking
mise exec -- just kube alerts-coverage-validate
```

These checks validate the source and promtool fixtures. They do not prove that the live
cluster is scraping metrics or that a notification reaches the phone.

### 2. Verify live readiness and wiring

Run the approved live verifiers:

```bash
mise exec -- just kube plex-verify
mise exec -- just kube cilium-verify
mise exec -- just kube monitoring-verify
mise exec -- just kube alertmanager-ntfy-verify
```

Require the Hubble metrics targets to be up. Inspect the live `plex-remote-access` rule
group and require all five rules to load without evaluation errors. Both missing-metric
alerts must be inactive before the connection-rate alerts are used as evidence.

The Alertmanager verifier proves the configured ntfy receiver and route. It does not send
a notification. When the notification route needs independent firing-and-resolved proof,
use the guarded [Alertmanager delivery procedure](ntfy-operations.md#prove-end-to-end-delivery)
in a separate approved window.

### 3. Prepare the attended window

Before generating traffic:

- confirm the production remote-access path already passed the operations guide;
- confirm Plex is not in household use;
- confirm the three traffic alerts are not already firing;
- choose one approved generator outside Kubernetes;
- bind the generator to the exact Plex destination and TCP `32400` only;
- confirm no unrelated source is already raising the same aggregate metrics; and
- arrange to watch Plex health, Prometheus alerts, Alertmanager, and ntfy throughout.

### 4. Confirm the source identity

Start a bounded observation window:

```bash
mise exec -- just kube plex-network-observe 600
```

Generate a small initial sample from the selected host and require Hubble to show a source
identity containing `reserved:world`. Stop if it does not.

An in-cluster Pod has a Kubernetes cluster identity. It cannot prove the detector's
off-cluster `reserved:world` matcher, even if it can reach the same Service.

The observation output can contain source addresses. Keep it local and private; do not
paste it into a public issue, pull request, test artifact, or repository file.

## Generate the controlled traffic

From the approved off-cluster host, send SYN packets without completing the TCP
handshake:

```bash
sudo hping3 -S -p 32400 -i u100000 <plex-load-balancer-address>
```

`-i u100000` requests one SYN every 100,000 microseconds, or about 10 per second. That is
above the five-per-second flood threshold while remaining bounded to one host and port.
An `nmap -sS` command with an explicitly equivalent bounded rate is acceptable.

Do not use `curl` or an ordinary `nc` loop. Those tools complete more of the TCP exchange
and produce a different flow-to-SYN shape, so they are not an equivalent probe-surge
oracle.

Run the generator for the full 15-minute exercise window. The Prometheus rate windows,
`for` durations, 30-second scrape interval, and Alertmanager grouping can delay firing.
Do not stop at the first notification; all three traffic rules need enough time to
qualify.

## Abort immediately if

Stop the generator and follow the
[Plex network-alert runbook](../runbooks/plex-network-alerts.md) if:

- Plex health, playback, or responsiveness regresses;
- unexpected CPU, memory, connection, or network pressure appears;
- a household user begins active Plex use;
- the source does not appear as the intended `reserved:world` identity;
- the generator is not bounded to the exact Plex address and TCP `32400`;
- another unexpected source begins affecting the aggregate metrics;
- Hubble, Prometheus, Alertmanager, or ntfy becomes unhealthy; or
- the generator cannot be stopped promptly.

Do not lower alert thresholds or increase the traffic rate to compensate for unhealthy
telemetry.

## Expected firing behavior

The deployed rules are:

| Alert | Severity | Condition |
| --- | --- | --- |
| `PlexRemoteConnectionFlood` | Critical | More than 5 inbound SYNs per second over 5 minutes, held for 5 minutes |
| `PlexRemoteConnectionRateElevated` | Warning | More than 1 inbound SYN per second over 10 minutes, held for 10 minutes |
| `PlexRemoteProbeSurge` | Warning | Fewer than 3 flows per SYN while SYN rate is above 0.1 per second over 10 minutes, held for 10 minutes |

During the window require:

- all three alerts to fire;
- the critical alert to route to the ntfy `critical` topic;
- both warning alerts to route to the ntfy `homelab` topic;
- the operator's subscribed client to receive the firing notifications;
- bounded Hubble observation to show only the intended test source for the generated
  traffic; and
- Plex health to remain stable.

Prometheus does not retain the source address. The topic and notification priority are
chosen from severity by the synchronous alertmanager-ntfy adapter.

## Stop the test and verify resolution

After the full window:

1. Stop the generator and confirm its process has exited.
2. Confirm the SYN and flow rates fall.
3. Wait for the rate windows, rule evaluations, and Alertmanager grouping to clear.
4. Require all three traffic alerts to resolve.
5. Require the normal Alertmanager route to send matching resolved notifications.
6. Run the Plex verifier again:

   ```bash
   mise exec -- just kube plex-verify
   ```

If an alert does not resolve, inspect for a still-running generator, another source,
stale Prometheus data, or current Plex traffic before changing a rule.

## What this test proves

For this controlled source and traffic shape, the exercise proves:

- an off-cluster source matches an identity containing `reserved:world`;
- Hubble emits the selected flow and TCP SYN metrics for `media/plex`;
- the three configured Prometheus expressions and hold durations fire;
- critical and warning alerts enter the intended Alertmanager route;
- the synchronous adapter publishes to the intended ntfy topics;
- firing and resolved notifications reach the attended client; and
- bounded live Hubble observation can attribute the source without retaining it in
  Prometheus.

## What this test does not prove

The exercise does not prove:

- that every Internet source receives the same Cilium identity;
- that a TCP handshake or Plex session completed;
- Plex authentication failures, account abuse, or application request behavior;
- rate limiting or automatic blocking;
- source attribution from Prometheus;
- the identity of an attacker or user;
- bandwidth-saturation detection;
- successful low-rate probe detection;
- every possible SYN or application traffic shape; or
- normal local, Sonos, Relay, or off-site playback.

Normal production-path acceptance belongs in
[Operate Plex direct remote access](plex-remote-access-operations.md).

## If expected alerts do not fire

Stop the generator after the approved window. Verify, in order:

1. Hubble assigned the source an identity containing `reserved:world`.
2. `hubble_tcp_flags_total` has incoming `flag="SYN"` data for
   `destination="media/plex"`.
3. `hubble_flows_processed_total` has the matching workload/source series.
4. Prometheus is scraping all Cilium `hubble-metrics` targets.
5. The exact five-rule group loaded without errors.
6. No unrelated traffic distorted the aggregate flow-to-SYN ratio.

Do not tune thresholds from one failed exercise. First establish whether the generator,
identity, metrics, rule evaluation, or notification path failed.

## Public-repository evidence boundary

Keep raw evidence local. Do not publish WAN or client addresses, LAN generator addresses,
Plex tokens, account identities, packet captures with private identifiers, or raw Hubble
output. Repository fixtures use synthetic counters and identities; they are the public
regression evidence for rule behavior.
