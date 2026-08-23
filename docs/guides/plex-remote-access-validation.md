# Validate Plex remote-access detection

Use this attended exercise to prove that off-cluster half-open traffic reaches the
Hubble metrics, Prometheus rules, Alertmanager route, and ntfy receiver. It generates a
real SYN load against Plex and is operator-run, disruptive test activity.

This exercise validates aggregate detection. It does not test Plex authentication
failures, bandwidth saturation, successful low-rate probes, application request shape,
or source-address retention. See [specification 020](../specs/020-plex-remote-access-detection.md)
for the signal design and limits.

## Authority and preconditions

Run only in a quiet, attended window. The generator needs administrator authority on a
LAN host outside Kubernetes. Observation and alert review can use approved read-only
cluster credentials.

Before starting:

1. Run the cluster-independent source checks:

   ```bash
   mise exec -- just kube plex-validate
   mise exec -- just kube cilium-validate
   mise exec -- just kube alerts-validate media
   mise exec -- just kube alerts-validate networking
   mise exec -- just kube alerts-coverage-validate
   ```

2. With approved read-only cluster credentials, verify the live Plex, Cilium,
   monitoring, and notification-route wiring:

   ```bash
   mise exec -- just kube plex-verify
   mise exec -- just kube cilium-verify
   mise exec -- just kube monitoring-verify
   mise exec -- just kube alertmanager-ntfy-verify
   ```

   These commands do not prove Plex rule health or notification delivery. Inspect the
   live Prometheus targets for `hubble-metrics` and require them to be up. Inspect the
   five `PlexRemote*` rules and `PlexWorkloadPolicyDenied`; require healthy evaluation
   with no last error. Require both missing-metric alerts to be inactive before using
   the connection-rate alerts as evidence.
3. When an independent firing-and-resolved test of the production notification route is
   required, use the guarded [Alertmanager producer procedure](ntfy-startup.md#alertmanager)
   in its own approved window. The read-only verifier proves wiring, not delivery.
4. Confirm Plex is not in active household use.
5. Confirm the five `plex-remote-access` alerts are loaded and not firing.
6. Start a bounded observation window:

   ```bash
   mise exec -- just kube plex-network-observe 600
   ```

7. Confirm the chosen LAN source appears with an identity containing
   `reserved:world`. Stop if it does not. An in-cluster pod has a cluster identity and
   cannot validate the rules' source matcher.

## Generate the half-open traffic

From the approved LAN host, send SYN packets without completing the handshake:

```bash
sudo hping3 -S -p 32400 -i u100000 192.168.90.31
```

An `nmap -sS` command with an explicit equivalent rate against only this host and port
is acceptable. Do not use `curl` or an ordinary `nc` loop: a completed handshake carries
enough flows to miss the probe-surge condition.

Run the generator for the full 15 minutes. The rate windows need time to fill before the
Prometheus `for` durations complete. As a practical expectation:

- `PlexRemoteConnectionFlood` becomes eligible several minutes into the run and routes
  as critical;
- `PlexRemoteConnectionRateElevated` also becomes eligible during the run and routes as
  warning; and
- `PlexRemoteProbeSurge` becomes eligible later because of its ten-minute rate window
  and hold, and routes as warning.

Alertmanager grouping adds delivery delay. Do not stop the exercise at the first
notification.

## Cautions

This traffic can leave thousands of half-open connections in Plex's accept backlog.
Never run it while someone is using Plex, against another destination, from the public
Internet, or at a higher rate without a separate approved design.

If nothing fires after 15 minutes, stop the generator. Do not lower thresholds first.
Verify:

- Hubble assigned the source an identity containing `reserved:world`;
- `hubble_tcp_flags_total` contains incoming `flag="SYN"` data for
  `destination="media/plex"`;
- `hubble_flows_processed_total` contains the matching workload/source series;
- Prometheus is scraping all Cilium metrics targets; and
- the exact rules loaded without errors.

Follow the [detection response runbook](../runbooks/plex-remote-access-detection.md) if
the test causes unexpected resource impact or another alert.

## Verify firing and recovery

During the run, require all of these results:

- `PlexRemoteConnectionFlood` fires;
- `PlexRemoteConnectionRateElevated` fires;
- `PlexRemoteProbeSurge` fires;
- ntfy receives the critical and warning notifications through the production route;
- `plex-network-observe` shows the approved LAN source without persisting it; and
- local Plex health does not regress.

Stop the generator after the full window. Confirm the connection rate falls, all three
alerts resolve after their windows and evaluations clear, resolved notifications follow
the normal Alertmanager route, and `mise exec -- just kube plex-verify` passes.

If an alert does not resolve, inspect for a still-running generator, another source,
stale Prometheus data, or current Plex traffic before changing any rule.

## Coverage boundary

The exercise proves the source matcher, Hubble flow and TCP metrics, three aggregate
rate/ratio expressions, alert holds, Alertmanager routing, and ntfy delivery for one
controlled half-open traffic shape.

It does not prove that every Internet source receives the same identity, that a TCP
handshake or Plex session completed, that rate limiting exists, or that the detector can
identify a user or attacker. Source attribution remains a bounded live Hubble action;
Prometheus intentionally does not retain client addresses.
