# Plex direct remote access — permanence decision

- **Status: Accepted.** Approved by the operator on 2026-08-22.

Date: 2026-08-22.
Branch: `plex-exposure-permanence`.

Supersedes [Plex direct remote access — decision](2026-08-11-plex-direct-remote-access.md).
That record remains the historical design and experiment record. This decision resolves
its temporary status and the Plex custom-access-URL question. The companion
[detection decision](2026-08-12-plex-remote-access-detection.md) and later alert
amendments remain in force.

## 1. Decision

Retain direct Plex remote access as a permanent, IPv4-only service. The external path
remains one operator-managed TCP mapping to Plex's dedicated Kubernetes LoadBalancer
Service and its native application listener. Do not publish Plex over public IPv6, add a
second listener, or permit automatic gateway mappings.

Retain Plex Relay as fallback. Retain the internal browser route, but advertise only the
single measured Plex-managed custom access URL required by the working client path. Do
not advertise the internal Envoy hostname to Plex clients.

This decision changes no public DNS record, gateway rule, account, or live workload by
itself. External settings remain operator-managed. Cluster changes remain Git-managed.

## 2. Required boundaries

The following properties define the accepted exposure:

- The Plex Service has one TCP application port, one explicit LoadBalancer address,
  `externalTrafficPolicy: Local`, and `allocateLoadBalancerNodePorts: false`.
- The Plex Cilium policy admits `world` only to that application port. Its existing
  workload-consumer ingress and bounded egress remain unchanged.
- The gateway has one manual TCP mapping to the LoadBalancer destination. Duplicate,
  wildcard, range, UDP, and automatically created mappings remain prohibited.
- Public DNS publishes no IPv6 answer for the Plex path. Plex's client network setting
  remains IPv4-only, and relevant LANs do not receive a Plex IPv6 path.
- Plex authentication remains required. The authentication-bypass network list stays
  empty, account multi-factor authentication stays enabled, remote streams remain
  bounded per user, and Relay remains enabled.
- The custom access URL list contains exactly the one measured Plex-managed URL. The
  internal Envoy route remains available for direct browser access but is not advertised
  through that Plex setting.

Disabling LoadBalancer NodePort allocation removes a second Kubernetes listener form
that this design does not use. Source validation must reject omission or re-enablement of
that field, both before and after Helm rendering.

## 3. Detection and response

Retain the Hubble-derived Plex alerts, missing-metric alerts, workload-policy-denial
alert, Prometheus evaluation, Alertmanager route, and synchronous ntfy adapter. The
2026-08-22 verification confirmed healthy live rules and targets and observed both a
firing and resolved notification through the production route.

The guarded Flux delivery exercise uses Alertmanager's webhook integration counters.
Before using that aggregate as its oracle, it must prove that ntfy is the only loaded
webhook receiver and that both success and failure metric series exist. This keeps the
test compatible with the deployed Alertmanager metric labels without allowing unrelated
webhook traffic to satisfy it.

Detection remains aggregate. It does not identify a remote client, detect every Plex
authentication failure, or provide durable request logs. Plex session review and the
incident procedure in the detection runbook remain operator responsibilities. These are
accepted limits of placing Plex's native listener directly on the Internet.

## 4. Plex, media deletion, and recovery

Plex keeps a read-only media mount, and its media-deletion control remains disabled.
Radarr and Sonarr are the removal authorities for their managed libraries: an intentional
removal deletes the organized media and prevents automatic re-import. Download cleanup
continues under the existing qBittorrent and qbit_manage policy.

Plex configuration and database backups remain required, together with a rehearsed
configuration restore. The NAS media account remains limited to the media share and the
write access required by media automation.

Bulk media has no independent backup or restore path by operator decision. Total media
loss therefore requires reacquisition and may be slow or incomplete. This accepted
consequence does not apply to Plex configuration, identity, database, or watch history.

## 5. Verification and change control

Before merge, run:

```bash
mise exec -- just kube plex-validate
mise exec -- just kube monitoring-validate
mise exec -- just kube alertmanager-ntfy-validate
mise exec -- just ci
```

After reconciliation, use the established read-only verifier to confirm that the live
Service has one IPv4 application listener and no allocated NodePort. Recheck the external
path from an off-network source and record only a sanitized result. Source validation
does not prove gateway filtering or live packet enforcement.

Review this decision after a change to the gateway mapping, public DNS, address-family
configuration, Plex network or account settings, Service listener shape, Cilium policy,
notification route, or recovery design. A calendar-based review is not required.

## 6. Rollback

The operator removes the single gateway mapping to block new Internet connections.
Established sessions can survive mapping removal, so restart Plex only when session
eviction is the intended response. Do not remove network containment, monitoring,
backups, Relay, or the internal access path as part of ordinary rollback.

Abandoning the design also requires a reviewed Git change that removes the direct
LoadBalancer exposure and `world` ingress. Live edits to Flux-managed resources remain
prohibited.

## 7. Consequences

The retained design gives supported Plex clients a direct path and preserves the client
behavior that passed the experiment, without maintaining a second public reverse-proxy
plane. It also leaves Plex's native listener Internet-facing, with Plex itself responsible
for application authentication and protocol handling.

The permanent controls are intentionally layered: one IPv4 edge path, no automatic or
IPv6 publication, one Kubernetes application listener, Cilium containment, account
controls, aggregate detection, operator rollback, and recoverable Plex state. None of
these controls alone is treated as proof of the others.
