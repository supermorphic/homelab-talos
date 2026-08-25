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

Topics describe notification semantics rather than applications: `critical` is for
rare infrastructure failures that require prompt attention, `homelab` is for warnings
and degraded platform state, and `media` is for selected household media events. This
keeps severity routing meaningful, lets Seerr publish the few selected media events
directly, and avoids creating a separate notification path for Plex, qBittorrent, each
`*arr` application, or Tautulli. A new topic should represent a new notification class,
not merely mirror another application name.

Credentials can rotate or retire independently without widening another consumer. ntfy
receives only its explicit authentication environment keys. The alert bridge mounts
only `auth.yml`, and Homepage receives only its own read token.

Git plus the operator-held age identity is the recovery authority for access control.
The ntfy database retains cache and runtime state, but the authorization model does not
depend on manually recreating users after loss.

The seven-day cache and authentication database normally survive Pod recreation on the
retained claim. They do not make the service highly available. Loss of the claim can
discard cached messages, while the declarative users, ACLs, and tokens reconstruct the
authorization model on a replacement database. Recovery of access control is therefore
stronger than recovery of message history.

## Private exposure and wake-up path

LAN clients use the internal Envoy Gateway at `ntfy.lab.supermorphic.com`. Off-site
clients use a Tailscale Ingress backed by the shared ingress ProxyGroup. The tailnet
hostname is the canonical `base-url` used by the iOS client. No public Gateway,
LoadBalancer, or Internet-facing ntfy listener is part of this design.

The platform already had only an internal Gateway and internal DNS path. Publishing
ntfy directly would therefore have required a new public Gateway, public DNS, and
Internet trust boundary rather than simply exposing one more application. Tailscale
met the actual off-site retrieval requirement while keeping ntfy outside the public
Internet exposure model.

The official iOS client needs ntfy's upstream wake-up service. The self-hosted server
sends the upstream service the message identifier and hashed topic needed for APNs to
wake the client; message bodies remain on the self-hosted instance. Network policy
therefore allows world HTTPS egress for this wake-up path. On inbound port `80`, it
permits the internal Gateway, Tailscale proxies, Gatus, every endpoint in the `media`
namespace, Homepage, the alert bridge, and node probes. This grants network reachability,
not topic-write authority. Required authentication and the token ACLs make Seerr the
only media workload authorized to write the `media` topic.

The `world:443` rule is a known policy limit. The cluster has no established
FQDN-egress baseline that can prove a stable ntfy.sh-only rule, so the design prefers a
clear broad HTTPS allowance to a brittle DNS-proxy policy. It must not be described as
destination-specific containment.

## Alertmanager delivery path

Prometheus alerts flow through one notification spine:

```text
Prometheus -> Alertmanager -> alertmanager-ntfy -> ntfy -> client
```

The stateless `alertmanager-ntfy` bridge converts Alertmanager webhook documents into
ntfy messages. It publishes synchronously to the in-cluster ntfy Service, so an ntfy
failure returns an error to Alertmanager and remains visible in notification metrics.
Network policy permits webhook ingress only from the monitoring namespace.

The platform alerting design had already made Prometheus Alertmanager authoritative and
left Grafana unified alerting unused. That eliminated the earlier conditional option of
sending a custom Grafana webhook directly to ntfy. Alertmanager's generic webhook body
is not itself a useful ntfy message, so a transformer became the necessary formatting
boundary.

Alertmanager owns grouping, deduplication, inhibition, repeat intervals, and resolved
notifications. The bridge maps firing critical alerts to urgent messages on `critical`,
maps warnings to `homelab`, and publishes resolved messages at default priority. Watchdog
and alerts outside the critical/warning route remain on the null receiver.

Seerr is the only direct media producer. Its managed notification mask writes exactly
the **Media Available**, **Request Processing Failed**, and **Issue Reported** event
classes to `media`. Direct integrations from Plex, qBittorrent, the `*arr` applications,
and Tautulli were rejected because each would create another notification policy
surface without shared silences. Flux and platform health use Prometheus rules instead
of routine Flux event notifications.

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

These checks establish service health and authorization, not mobile delivery. Positive
and negative ACL tests prove who can read or publish, and a retained-cache check can
prove normal persistence. Only a real client test can prove APNs wake-up and retrieval
while off-site over the private path; an in-cluster HTTP request cannot satisfy that
acceptance gate. Because monitoring and delivery share the same cluster failure domain,
independent external or dead-man monitoring also remains outside this design.

## Rejected alternatives

- A public ntfy endpoint was unnecessary once Tailscale supplied a private off-site
  path.
- Raw Alertmanager webhook delivery was rejected because the payload is not a useful
  user notification and failures would be harder to surface.
- An asynchronous bridge was rejected because it could acknowledge delivery before ntfy
  accepted the message.
- Multiple direct producer integrations were rejected because they bypass Alertmanager
  lifecycle controls and fragment credential and notification policy.

Attachments, email or phone delivery, payments, PostgreSQL, multiple replicas, browser
push, and an interactive SSO layer that native clients cannot use are intentionally
outside the current service. Optional direct producers and new topics are also deferred
until the existing path is quiet and reliable. A new producer must add a signal with
clear value, preserve credential separation, and account for duplicate delivery,
silences, and Alertmanager ownership before it is admitted.

## Consequences

The service has one recoverable writer and is not horizontally available. Failure of
ntfy interrupts mobile delivery but does not stop Prometheus or Alertmanager from
evaluating alerts. Least-privilege identities limit a compromised producer to its own
topics, and private exposure avoids making the message service an Internet application.

Reconsider public access only when private Tailscale retrieval cannot meet an actual
client requirement and a separately designed Internet trust boundary is justified.
Reconsider direct application publishing only for event-shaped information whose value
outweighs the loss of the single Alertmanager lifecycle. Routine health, Flux events,
and application-status changes remain on the existing Prometheus path.

Current credential, client, producer, verification, and rotation procedure belongs in
`docs/guides/ntfy-operations.md`.
