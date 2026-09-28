# Respond to Plex network alerts

## Alert fired

Use this runbook for unexpected Plex external-traffic alerts
`PlexRemoteConnectionFlood`, `PlexRemoteConnectionRateElevated`, or
`PlexRemoteProbeSurge`; detector alerts `PlexRemoteFlowMetricsMissing` or
`PlexRemoteTcpMetricsMissing`; or workload denial alert
`PlexWorkloadPolicyDenied`. A controlled detection test follows its
[own procedure](../guides/plex-remote-access-detection-test.md).

[Specification 014](../specs/014-plex-remote-access-detection.md) and the live
Prometheus rules own alert thresholds and detector behavior.

## Decide on containment

- **No immediate material risk:** Observe for a bounded window and correlate with
  known Plex sessions before changing access.
- **Active or uncertain material risk:** Remove the UniFi direct-access DNAT first
  using the [Plex operations guide](../guides/plex-remote-access-operations.md#disable-or-roll-back-exposure).
  Then investigate from the private network.

Removing DNAT stops new direct connections. It may leave established connections
and Plex sessions active. Restart Plex only if those sessions must be evicted; a
restart interrupts all clients.

## Observe privately

```bash
mise exec -- just kube plex-network-observe 600
```

Use the bounded live flow result to attribute traffic where possible. Compare its
time and source with Plex Dashboard, Tautulli, and known household activity. Use
`mise exec -- just kube plex-verify` to check the deployed Plex path. If the live
denial has stopped, inspect the alert's historical source information in the
private Prometheus interface; do not infer its source from the aggregate alert.

Keep raw source addresses, Hubble output, account details, tokens, and session
identities private. Record only sanitized conclusions in repository artifacts.

## Classify and act

| Classification | Operator action |
| --- | --- |
| Suspicious external traffic | Correlate with Plex/Tautulli. Use a UniFi block only for an attributed exact source when safe; otherwise remove direct DNAT. Restart Plex only to evict established sessions. |
| Detector or telemetry failure | Check Cilium/Hubble and Prometheus health and whether known Plex traffic appears in the expected observation path. If direct exposure cannot be trusted while detection is blind, remove DNAT. Correct durable telemetry source through reviewed Git. |
| Intended workload denied by policy | Identify the workload and the denying ingress or egress boundary. Confirm the integration owner, then change only the required policy through reviewed Git. |
| Unintended workload denied by policy | Keep the denial, correct the source workload, and investigate unexpected attempted access. Do not widen Plex policy. |

Normal direct-access configuration and router procedures remain in the
[Plex operations guide](../guides/plex-remote-access-operations.md).

## Verify and stop

After containment, check live traffic and Plex/Tautulli sessions again. Require
local playback and `plex-verify` to remain healthy. If DNAT was removed, verify
new off-site direct connections fail; inspect existing sessions separately. For
an intended policy correction, require the real integration to succeed without
new denials. For telemetry repair, require known traffic to appear and the
detector alert to clear after its observation window.

Stop and escalate when attribution is uncertain, material traffic continues,
an established session cannot be contained safely, telemetry remains blind,
the denying policy or integration owner is unclear, or a proposed fix needs
broader access. Preserve private evidence and use a reviewed operator plan.
