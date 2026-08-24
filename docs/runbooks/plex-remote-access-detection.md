# Respond to Plex remote-access alerts

Use this runbook when one of the five `plex-remote-access` alerts or
`PlexWorkloadPolicyDenied` fires. The rule source is under
`kubernetes/apps/media/alerts/` and `kubernetes/apps/networking/alerts/`.
[Specification 014](../specs/014-plex-remote-access-detection.md) records the signal
design and limits.

Prometheus stores aggregate flow counts, not public source addresses. Diagnose source
activity with the bounded, read-only Hubble workflow:

```bash
mise exec -- just kube plex-network-observe 600
```

Do not retain public client addresses, raw Hubble captures, Plex tokens, account
identities, or unrelated request paths in repository artifacts.

## Authority and immediate safety

Observation, Plex activity review, and scoped live verification are read-only. A router
block, DNAT removal, Plex restart, or policy change requires the corresponding operator
authority.

For any remote-traffic alert:

1. Start bounded observation before changing the path.
2. Compare the alert window with Plex Dashboard, Tautulli, and known household activity.
3. Confirm the Plex Cilium policy still admits `world` only on TCP `32400`.
4. If abuse is active or attribution is unclear and impact is material, remove the
   UniFi DNAT to stop new connections.
5. Restart Plex only when established-session eviction is required. A restart interrupts
   all local clients because the workload is single-active.

Follow [Operate Plex direct remote access](../guides/plex-remote-access-operations.md) for
the exposure and rollback procedure.

## `PlexRemoteConnectionFlood` — critical

Meaning: inbound off-cluster SYN rate exceeded 5 per second for five minutes, measured
over a five-minute window.

Diagnosis:

- Run `plex-network-observe` immediately.
- Determine whether activity is one sustained source, a small source set, or broad
  scanning.
- Compare with Plex sessions and Tautulli for legitimate playback.
- Confirm the Cilium policy and UniFi forward have not widened.

Mitigation:

- Block an attributed source at UniFi only when the exact source and intended rule scope
  are known.
- Remove the Plex DNAT when a bounded source block is unsafe or insufficient.
- For suspected compromise, remove the DNAT first and decide whether Plex must restart to
  evict existing sessions.

Verification: the SYN rate falls below threshold, the alert resolves, new off-network
connections fail when exposure was removed, and local Plex consumers remain healthy.

Escalate immediately for sustained impact, suspected compromise, unexpected public
ports, or inability to restore the policy boundary.

## `PlexRemoteConnectionRateElevated` — warning

Meaning: inbound off-cluster SYN rate exceeded 1 per second for ten minutes, measured
over a ten-minute window.

Diagnosis:

- Observe sources and compare the same window with Plex sessions and logs.
- Check for a misbehaving client, repeated API activity, or traffic inconsistent with
  known use.

Mitigation: stop or reauthenticate the known client when safe. Use a bounded UniFi block
or remove the DNAT when activity is unauthorized and continues.

Verification: the rate returns to the household baseline, the alert resolves, and known
clients can still connect when exposure remains enabled.

Escalate when the source cannot be attributed, the rate continues to increase, or Plex
shows suspicious authentication or session activity.

## `PlexRemoteProbeSurge` — warning

Meaning: off-cluster traffic averaged fewer than three incoming flows per SYN while the
SYN rate remained above 0.1 per second for ten minutes. This is consistent with
half-open scanning; it does not prove that a Plex session was established.

Diagnosis:

- Observe source addresses and check Plex for sessions in the same window.
- Confirm no other Plex ingress port was added. Hubble metrics do not include a port
  label, so the workload identity represents TCP `32400` only while policy admits no
  second port.

Mitigation: continued observation is acceptable for low-impact scanning when Plex and
the cluster remain healthy. Block the exact source or remove the DNAT if traffic is
sustained, resource impact appears, or another alert also fires.

Verification: the SYN rate and flow ratio return to normal and the alert resolves.

Escalate when scanning causes resource impact, changes source rapidly, coincides with
application errors, or cannot be contained with the existing router boundary.

## `PlexRemoteFlowMetricsMissing` — critical

Meaning: no Plex Hubble flow series has existed for 15 minutes. This can be detector
failure or an idle period; absence alone does not distinguish them.

Diagnosis:

1. Check Cilium DaemonSet readiness.
2. Confirm `hubble.metrics` still enables `flow`.
3. Check the `cilium-monitoring` ServiceMonitor and Prometheus target.
4. Generate or observe known legitimate Plex traffic and determine whether the series
   appears.

Mitigation: repair the metrics path through Git. Do not tune the alert or assume an idle
series proves the detector healthy. Remove the DNAT when remote exposure cannot remain
attended while detection is blind.

Verification: a known flow produces the Plex series, the alert resolves, and the other
remote-access rules evaluate normally.

Escalate when Cilium or Prometheus is unhealthy, the source contract drifted, or known
traffic remains invisible.

## `PlexRemoteTcpMetricsMissing` — critical

Meaning: no Plex TCP-flag series has existed for 15 minutes. The flood, elevated-rate,
and probe rules depend on this metric.

Diagnosis and mitigation match the flow-metric alert, but confirm `hubble.metrics`
enables `tcp` and that `hubble_tcp_flags_total` with `flag="SYN"` exists for known
traffic. A healthy flow series does not compensate for a missing TCP series.

Verification: known traffic produces the TCP-flag series, all dependent rules evaluate,
and the alert resolves. Remove exposure or escalate if the signal cannot be restored.

## `PlexWorkloadPolicyDenied` — warning

Meaning: at least three `POLICY_DENIED` events from Kubernetes workloads to
`media/plex` occurred in six hours and remained observable for 30 minutes. Either Plex
ingress or the source workload's egress policy can enforce the denial.

Group the same bounded increase by source:

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

1. Identify the workload from the complete Cilium source identity.
2. If traffic continues, run `plex-network-observe` for live attribution.
3. Inspect both the Plex ingress policy and any egress policy selecting the source.
4. Confirm whether the attempted Plex integration is intended.

If Plex ingress is missing an intended consumer, update the policy, Plex validator, and
mutation tests together through Git. If source egress is the enforcing boundary, change
only that application's policy. For unintended traffic, correct the application instead
of widening network access.

Verification: the intended integration succeeds, no new denied event occurs, and the
alert resolves after the six-hour lookback ages out. Escalate when the source cannot be
identified or a policy change would widen authority beyond the intended integration.
