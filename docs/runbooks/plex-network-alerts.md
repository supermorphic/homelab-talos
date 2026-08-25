# Respond to Plex network alerts

## Trigger

Use this runbook when one of these alerts fires unexpectedly during normal operation:

- external traffic: `PlexRemoteConnectionFlood`,
  `PlexRemoteConnectionRateElevated`, or `PlexRemoteProbeSurge`;
- detection telemetry: `PlexRemoteFlowMetricsMissing` or
  `PlexRemoteTcpMetricsMissing`; or
- workload policy: `PlexWorkloadPolicyDenied`.

If controlled traffic from the attended
[Plex remote-access detection test](../guides/plex-remote-access-detection-test.md)
caused the alerts, follow that guide's firing, resolution, and abort procedure instead.
Normal production exposure and DNAT rollback belong in
[Operate Plex direct remote access](../guides/plex-remote-access-operations.md).

[Specification 014](../specs/014-plex-remote-access-detection.md) owns the external
detector's signal design, thresholds, and limitations. This runbook owns operational
response.

```text
Plex network alert fires
        ↓
preserve bounded evidence when safe
        ↓
classify the failure
  ├─ external traffic anomaly
  ├─ detector blind
  └─ workload policy denial
        ↓
active material risk?
  ├─ no  → diagnose the narrow boundary
  └─ yes → remove the direct DNAT
             ↓
        restart Plex only if established
        sessions must also be evicted
        ↓
verify recovery or escalate
```

Observation normally precedes mutation. Active abuse or unsafe attribution can justify
immediate containment before further observation.

## Authority and evidence safety

| Operation | What it does | Effect and authority |
| --- | --- | --- |
| `mise exec -- just kube plex-network-observe 600` | Opens a bounded Hubble port-forward and prints live Plex L3/L4 flows | Operator-only read diagnostic because output can contain private source addresses |
| `mise exec -- just kube plex-verify` | Checks deployed Plex workload, Service, route, DNS, TLS, and runtime controls | Approved scoped verification; it does not inspect the live Cilium policy or WAN boundary |
| Plex Dashboard or Tautulli activity review | Correlates an alert with legitimate sessions | Read-only operator observation |
| Exact UniFi source block | Blocks one attributed source | Operator-managed router mutation |
| UniFi DNAT removal | Stops new direct Internet connections | Operator containment through the direct-access operations procedure |
| Plex restart | Evicts established sessions and interrupts all clients | Exceptional operator live mutation |
| Cilium or alert correction | Changes durable desired state | Reviewed Git change |

A confirmation variable does not determine authority. Read-only diagnostics do not
authorize a router block, DNAT change, Plex restart, or policy mutation.

Prometheus retains aggregate counters labeled with Cilium identities such as
`reserved:world`; it does not retain individual public source addresses. Live source
attribution uses:

```bash
mise exec -- just kube plex-network-observe 600
```

The command observes for at most 600 seconds and does not capture packet payloads. Keep
raw output private. Do not publish public or client addresses, raw Hubble output, Plex
tokens, account identities, email addresses, unrelated request paths, or packet
captures. Repository artifacts may contain only sanitized conclusions.

## Immediate response for any alert

1. If no active material risk is apparent, start bounded Hubble observation before
   changing the path. If risk is active or attribution is unsafe, remove the direct DNAT
   first.
2. Compare the alert window with Plex Dashboard, Tautulli activity, and known household
   use.
3. Run `mise exec -- just kube plex-verify` and use the live-object checks in the
   [operations guide](../guides/plex-remote-access-operations.md#validate-the-kubernetes-listener-and-policy)
   to confirm the listener and Cilium boundary have not widened beyond public TCP
   `32400`.
4. Classify the event as legitimate use, unauthorized or scanning traffic, missing
   telemetry, an intended workload denied by policy, or unintended workload behavior.
5. Apply the narrowest matching response below.

Removing the single UniFi DNAT stops new direct inbound connections. It does not prove
that established conntrack entries or Plex sessions ended. Restart Plex only when an
active or suspected session must be evicted; the single `Recreate` workload means that
restart interrupts local and remote clients.

## External traffic alerts

### `PlexRemoteConnectionFlood` — critical

**Meaning.** Off-cluster SYN rate to Plex exceeded 5 per second over a five-minute rate
window and remained above that threshold for five minutes.

**Diagnose.** Start bounded observation unless immediate containment is safer. Compare
the traffic with active Plex and Tautulli sessions. Determine whether one stable source,
a small source set, or broad/changing traffic is responsible. Confirm the UniFi mapping
and Plex ingress policy still expose exactly one TCP `32400` path.

**Contain.** If one exact source is known and a narrow router block is safe, block only
that source. If the source is broad, changing, uncertain, or unsafe to block narrowly,
remove the direct DNAT. For suspected compromise, remove the DNAT first and then decide
whether established-session eviction requires a Plex restart.

**Verify.** Confirm the SYN rate falls, the alert resolves, new off-network direct
connections fail when exposure was removed, and local Plex playback and
`plex-verify` remain healthy.

**Escalate.** Stop for sustained resource impact, suspected compromise, unexpected
public exposure, inability to restore the intended boundary, or any response that needs
a broader security design.

### `PlexRemoteConnectionRateElevated` — warning

**Meaning.** Off-cluster SYN rate exceeded 1 per second over a ten-minute rate window
and remained above that threshold for ten minutes.

**Diagnose.** Compare source activity with the same Plex and Tautulli window. Distinguish
legitimate repeated client behavior, a broken client or API retry loop, and unauthorized
traffic.

**Mitigate.** Stop, reauthenticate, or repair a known legitimate-but-broken client. Use
an exact router block for a known unauthorized source when safe. Remove the DNAT if
activity is unknown, continues increasing, or cannot be bounded.

**Verify.** Require the rate to return to normal household behavior, the alert to
resolve, and legitimate clients to remain usable if direct exposure stays enabled.

**Escalate.** Stop when attribution is unclear, the rate continues increasing, or Plex
activity shows suspicious authentication or session behavior.

### `PlexRemoteProbeSurge` — warning

**Meaning.** For ten minutes, off-cluster traffic carried fewer than three processed
flows per incoming SYN while the SYN rate remained above 0.1 per second; the condition
then held for ten minutes. This is consistent with half-open scanning or another
low-flow-per-SYN pattern. It does not prove authentication, session establishment, or
attacker identity.

**Diagnose.** Observe live sources and compare the period with Plex sessions. Confirm
the workload still admits no second public Plex port. Hubble's retained metrics have no
destination-port label; this workload-level signal represents public TCP `32400` only
because Cilium permits no other public Plex listener.

**Mitigate.** Continued observation can be acceptable for a low-impact scan while Plex
and the cluster remain healthy. For sustained or material activity, block an exact
source when safe; otherwise remove the DNAT.

**Verify.** Confirm SYN and flow behavior return to normal, the alert resolves, and Plex
remains healthy.

**Escalate.** Stop when sources change rapidly, resource impact appears, application
errors coincide, or containment would require broader exposure or policy changes.

## Detection telemetry alerts

The two missing-metric alerts protect different halves of the detector:

```text
detector metric missing
        ↓
Cilium and Hubble healthy?
        ↓
metric enabled and Prometheus target healthy?
        ↓
known Plex traffic occurs
        ↓
expected series appears?
  ├─ yes → detector restored
  └─ no  → detector remains blind
             ↓
        remove exposure when unattended
        detection cannot be trusted
```

A missing series can mean inactivity or detector failure. Absence alone does not prove
detector health. Do not lower, delete, or silence the missing-metric alert as a repair.
If direct exposure cannot safely remain active while detection is blind, remove the
DNAT through the operations guide.

For either alert, diagnose the shared path first:

1. Confirm the Cilium DaemonSet and Hubble Relay are healthy.
2. Confirm the expected Hubble metric remains enabled in Cilium source.
3. Confirm the Cilium monitoring Service, ServiceMonitor, and Prometheus target are
   healthy.
4. Generate or observe known legitimate Plex traffic.
5. Confirm the expected Plex metric series appears and its dependent rules evaluate
   without error.

Repair source drift or telemetry wiring through the owning reviewed Git workflow.

### `PlexRemoteFlowMetricsMissing` — critical

**Meaning.** No `hubble_flows_processed_total{destination="media/plex"}` series has
existed for 15 minutes.

**Diagnose and recover.** Confirm Cilium still enables the `flow` metric with identity
source context and workload destination context. Follow the shared diagnostic path and
require known Plex traffic to produce the flow series.

**Verify.** The flow series appears, the missing-metric alert resolves, and the probe-
surge expression can evaluate with its flow input.

**Escalate.** Stop when Cilium or Prometheus is unhealthy, source drift is unexplained,
or known traffic remains invisible.

### `PlexRemoteTcpMetricsMissing` — critical

**Meaning.** No `hubble_tcp_flags_total{destination="media/plex"}` series has existed
for 15 minutes. A healthy flow metric does not compensate for this missing signal. All
three external traffic rules require the TCP SYN series; the probe rule also requires
the flow series.

**Diagnose and recover.** Confirm Cilium still enables the `tcp` metric with identity
source context and workload destination context. Require known Plex traffic to produce
`hubble_tcp_flags_total` with `flag="SYN"`.

**Verify.** The TCP/SYN series appears, all dependent traffic rules evaluate normally,
and the alert resolves.

**Escalate.** Remove exposure or stop for operator review when the TCP signal cannot be
restored safely.

## `PlexWorkloadPolicyDenied` — warning

**Meaning.** At least three `POLICY_DENIED` events from Kubernetes workloads to
`media/plex` occurred in the six-hour lookback and the condition remained true for 30
minutes. Either Plex ingress or an egress policy selecting the source can enforce the
denial.

### Diagnose

No repository-owned command supplies historical source grouping. Use this read-only
PromQL query against the existing Prometheus interface to group the same bounded
increase by complete Cilium source identity:

```promql
sum by (source) (
  increase(
    hubble_drop_total{
      destination="media/plex",
      reason="POLICY_DENIED",
      source=~".*k8s:io.kubernetes.pod.namespace=.*"
    }[6h]
  )
)
```

Then:

1. Identify the workload from the complete source identity.
2. If traffic continues, run `plex-network-observe 600` for live attribution.
3. Inspect both the Plex ingress policy and any egress policy selecting the source.
4. Determine whether the attempted Plex integration is intended.

### Recover

```text
intended integration?
  ├─ no  → correct the source application; do not widen Plex
  └─ yes
       ↓
  which boundary denied it?
       ├─ Plex ingress → change Plex policy and its validator/tests
       └─ source egress → change only the source policy
```

Make durable policy corrections through reviewed Git. Do not solve source-egress denial
by widening Plex ingress, and do not authorize unintended traffic merely because the
source is identifiable.

### Verify

For an intended integration, confirm the actual operation succeeds and produces no new
denied event. Confirm both policies remain limited to the intended source, destination,
and TCP `32400`. The alert can remain firing after the live fault is fixed because its
expression looks back six hours; require it to resolve after the qualifying history ages
out.

### Escalate

Stop when the source cannot be identified, intended ownership is unclear, multiple
unexpected workloads target Plex, or correction would widen access beyond the intended
integration. A wrong policy design needs a new reviewed change, not an improvised live
allowance.
