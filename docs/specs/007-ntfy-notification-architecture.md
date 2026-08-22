# ntfy Notification Architecture

## Purpose

Provide one private mobile-notification layer for platform alerts and selected media
events. Producers remain responsible for domain signals, Alertmanager remains
responsible for alert lifecycle, and ntfy handles authenticated message storage and
delivery.

## Stateful service design

ntfy runs as one `Recreate` Deployment in its own namespace. The pinned
`docker.io/binwiederhier/ntfy:v2.26.3` image runs as non-root UID/GID `1000`, cannot
elevate privileges, drops all capabilities, and stores its cache and authentication
databases on a retained 2 Gi Longhorn `ReadWriteOnce` claim at `/var/lib/ntfy`.

Non-secret behavior is checked in as `server.yml`. The server requires login, denies
anonymous access by default, disables signup, serves application traffic on port `80`,
and exposes metrics only on the separate cluster-internal port `9090`. HTTP probes and
Gatus use `/v1/health`, which remains unauthenticated and must return both HTTP `200` and
`healthy: true`.

## Identity and authorization model

The identity registry is the declarative source for users, topic ACLs, consumer types,
and retirement tombstones. A SOPS-encrypted Secret supplies the resulting users, ACLs,
tokens, and the alert bridge authentication fragment.

The active roles are deliberately separate:

| Identity | Authority |
| --- | --- |
| `subscriber` | Read `critical`, `homelab`, and `media` |
| `alertmanager` | Write `critical` and `homelab` |
| `seerr` | Write `media` |
| `homepage` | Read `critical` |

Credentials can rotate or retire independently without widening another consumer. ntfy
receives only its explicit authentication environment keys. The alert bridge mounts
only `auth.yml`, and Homepage receives only its own read token.

Git plus the operator-held age identity is the recovery authority for access control.
The ntfy database retains cache and runtime state, but the authorization model does not
depend on manually recreating users after loss.

## Private exposure and wake-up path

LAN clients use the internal Envoy Gateway at `ntfy.lab.supermorphic.com`. Off-site
clients use a Tailscale Ingress backed by the shared ingress ProxyGroup. The tailnet
hostname is the canonical `base-url` used by the iOS client. No public Gateway,
LoadBalancer, or Internet-facing ntfy listener is part of this design.

The official iOS client needs ntfy's upstream wake-up service. The self-hosted server
sends the upstream service the message identifier and hashed topic needed for APNs to
wake the client; message bodies remain on the self-hosted instance. Network policy
therefore allows world HTTPS egress for this wake-up path while restricting inbound
application traffic to the internal Gateway, Tailscale proxies, approved producers,
Homepage, Gatus, and node probes.

## Alertmanager delivery path

Prometheus alerts flow through one notification spine:

```text
Prometheus -> Alertmanager -> alertmanager-ntfy -> ntfy -> client
```

The stateless `alertmanager-ntfy` bridge converts Alertmanager webhook documents into
ntfy messages. It publishes synchronously to the in-cluster ntfy Service, so an ntfy
failure returns an error to Alertmanager and remains visible in notification metrics.
Network policy permits webhook ingress only from the monitoring namespace.

Alertmanager owns grouping, deduplication, inhibition, repeat intervals, and resolved
notifications. The bridge maps firing critical alerts to urgent messages on `critical`,
maps warnings to `homelab`, and publishes resolved messages at default priority. Watchdog
and alerts outside the critical/warning route remain on the null receiver.

Seerr is the only direct media producer and writes bounded request and issue events to
`media`. Direct integrations from Plex, qBittorrent, the `*arr` applications, and
Tautulli were rejected because each would create another notification policy surface
without shared silences. Flux and platform health use Prometheus rules instead of
routine Flux event notifications.

## Observability and validation

A ServiceMonitor scrapes the unexposed metrics port once per minute. Gatus checks the
in-cluster health response. Prometheus alerts independently cover service failure,
missing Gatus telemetry, and loss of the retained claim. Homepage uses its dedicated
read-only token to show the latest critical notification.

Offline validation checks storage, security, checked-in configuration, Secret
projection boundaries, ACL registry invariants, routes, network policies, monitoring,
and Alertmanager receiver configuration. Read-only live verification checks workload
and claim readiness, health, authentication and ACL behavior, scrape health, the
Alertmanager connection, and receiver state. Producer-specific synchronization remains
separate because it changes application-owned runtime configuration.

## Rejected alternatives

- A public ntfy endpoint was unnecessary once Tailscale supplied a private off-site
  path.
- Raw Alertmanager webhook delivery was rejected because the payload is not a useful
  user notification and failures would be harder to surface.
- An asynchronous bridge was rejected because it could acknowledge delivery before ntfy
  accepted the message.
- Multiple direct producer integrations were rejected because they bypass Alertmanager
  lifecycle controls and fragment credential and notification policy.

## Consequences

The service has one recoverable writer and is not horizontally available. Failure of
ntfy interrupts mobile delivery but does not stop Prometheus or Alertmanager from
evaluating alerts. Least-privilege identities limit a compromised producer to its own
topics, and private exposure avoids making the message service an Internet application.

Current credential, client, producer, verification, and rotation procedure belongs in
`docs/guides/ntfy-startup.md`.
