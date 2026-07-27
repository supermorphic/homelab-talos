# ntfy for `homelab-talos` — Agent Implementation Plan and Startup Guide

## Purpose

Implement a private, self-hosted ntfy notification service in the Talos + Flux
cluster and establish it as the common delivery layer for homelab alerts and
media events.

The implementation must remain GitOps-first:

- Kubernetes resources, ntfy server settings, users, ACLs, and publisher tokens
  are declared in the repository.
- Secret material is committed only in SOPS-encrypted files.
- Alert routing and templates are declared in the repository wherever the
  source application supports provisioning.
- Manual UI or device configuration is limited to settings that cannot
  reasonably be managed as code, and every such step is documented in the
  startup guide.

This plan assumes the repository is `homelab-talos`, uses Flux, Talos,
`bjw-s/app-template`, SOPS, Longhorn, Gateway API, cert-manager, external-dns,
Prometheus/Alertmanager, Grafana, Gatus, and the existing repository validation
and verification conventions. The implementation agent must confirm the actual
repository patterns before editing.

## Desired outcome

The initial notification model is intentionally small:

| Topic | Purpose | Phone behavior |
|---|---|---|
| `critical` | Failures requiring prompt operator attention | High or urgent |
| `homelab` | Warnings, degraded state, GitOps failures, and operator events | Default |
| `media` | Seerr availability, request failures, and reported issues | Default or quiet |

The intended routing is:

```text
PrometheusRules
       |
       v
Prometheus Alertmanager
       |
       v
Alertmanager-to-ntfy formatting
       |
       +---- critical severity ----> ntfy topic: critical
       |
       `---- warning severity -----> ntfy topic: homelab

Seerr -----------------------------> ntfy topic: media

ntfy ------------------------------> iPhone app and optional web/CLI clients
```

Alertmanager remains responsible for alert grouping, deduplication, silences,
inhibition, and resolved notifications. ntfy is the delivery and mobile-inbox
layer, not the alert-management engine.

## Non-goals for the first release

Do not:

- Send every successful Flux reconciliation, download event, or application
  status change to ntfy.
- Configure every `*arr` application independently when Seerr and
  PrometheusRules already provide the useful signal.
- Treat topic names as secrets.
- Allow anonymous topic reads or writes.
- Enable user self-signup.
- Enable attachments, incoming email, outgoing email, phone calls, or payments.
- Deploy PostgreSQL solely for ntfy.
- Run multiple ntfy replicas against SQLite.
- Add a third-party Helm chart when the repository already standardizes on
  `bjw-s/app-template`.
- Put publisher credentials in plaintext ConfigMaps, Helm values, scripts,
  documentation, or command history.
- Put Cloudflare Access, another interactive SSO layer, or a browser-only login
  in front of the native iOS client without first proving client compatibility.
- Claim end-to-end mobile delivery from an in-cluster HTTP test.

## Decisions

### 1. Deploy ntfy as a single stateful application

Use the official image:

```text
docker.io/binwiederhier/ntfy:v2.26.3
```

`v2.26.3` is current as of 2026-07-25. At implementation time, verify the tag
still exists, pin it according to repository policy, include a digest if that is
the established convention, and let Renovate manage future updates.

Run one replica with `strategy: Recreate`. SQLite is the simplest and correct
choice at this scale, but it is single-writer storage and must not be presented
as horizontally available.

### 2. Use one Longhorn RWO PVC

Mount a 2 Gi Longhorn PVC at `/var/lib/ntfy` and place these files on it:

```text
/var/lib/ntfy/cache.db
/var/lib/ntfy/auth.db
```

If browser Web Push is enabled later, also place
`/var/lib/ntfy/webpush.db` there.

Use a seven-day message cache unless repository constraints suggest otherwise.
The data is useful but not irreplaceable. Declarative users, ACLs, and tokens
must be sufficient to reconstruct access after loss of the auth database.

Do not enable attachment storage initially.

### 3. Keep server behavior in a checked-in `server.yml`

The non-secret configuration should include the equivalent of:

```yaml
base-url: "https://ntfy.lab.supermorphic.com"
listen-http: ":80"
behind-proxy: true

cache-file: "/var/lib/ntfy/cache.db"
cache-duration: "168h"
auth-file: "/var/lib/ntfy/auth.db"
auth-default-access: "deny-all"

enable-login: true
require-login: true
enable-signup: false

upstream-base-url: "https://ntfy.sh"
metrics-listen-http: ":9090"
```

The exact hostname and exposure mode are a decision gate described below.

Mount `server.yml` read-only at `/etc/ntfy/server.yml`. Pass `serve` as the
container argument. Do not encode ordinary settings as a long list of
environment variables if a reviewed YAML file is clearer.

### 4. Provision authentication declaratively

Use ntfy's declarative `auth-users`, `auth-access`, and `auth-tokens` support.
Put their environment-variable equivalents in a SOPS-encrypted Secret so the
checked-in plaintext `server.yml` contains no password hashes or access tokens.

Provision these identities:

| Identity | Role | Access | Credential use |
|---|---|---|---|
| `keith` | `user` | Read-only on `critical`, `homelab`, and `media` | iPhone, web, optional CLI |
| `alertmanager` | `user` | Write-only on `critical` and `homelab` | Alert delivery |
| `seerr` | `user` | Write-only on `media` | Seerr native ntfy integration |
| `automation` | `user` | Write-only on `homelab` | Optional scripts and future events |

Do not make a publisher an admin. Do not reuse Keith's password or token in an
application. Give every producer a distinct token so it can be rotated and
revoked independently.

Expected declarative access semantics:

```text
keith:critical:ro
keith:homelab:ro
keith:media:ro
alertmanager:critical:wo
alertmanager:homelab:wo
seerr:media:wo
automation:homelab:wo
```

The implementation must verify the exact ntfy environment syntax against the
pinned release. It must also account for the documented behavior that removing
a provisioned user, ACL, or token from configuration removes it from the
database on the next restart.

### 5. Keep the endpoint private at the application layer

Set `auth-default-access: deny-all`, require login in the web application, and
disable signup. Anonymous publish and subscribe requests must fail.

TLS terminates at the existing gateway. Do not configure TLS inside the ntfy
container.

### 6. Enable the upstream wake-up path required by iOS

Set:

```yaml
upstream-base-url: "https://ntfy.sh"
```

This is required for prompt notifications in the official iOS application.
The self-hosted server sends ntfy.sh a poll request containing the message ID
and a hash of the topic URL; the alert body remains on the self-hosted server.
Apple Push Notification service wakes the application, which then retrieves the
message from the self-hosted endpoint.

The cluster's egress policy must permit DNS and HTTPS to `ntfy.sh`.

### 7. Do not add an Alertmanager adapter unless the existing alert path needs it

First identify the authoritative alert manager:

- If alerts are Grafana-managed and the deployed Grafana supports provisioned
  webhook contact points with a custom payload, publish directly to ntfy using
  an ntfy-compatible JSON body, token authentication, and provisioned
  notification policies.
- If `PrometheusRule` alerts flow through Prometheus Alertmanager, its generic
  webhook payload is not an ntfy message. Deploy a small, pinned
  `alertmanager-ntfy` adapter or an equivalently maintained transformer.

For Prometheus Alertmanager, prefer
`alexbakker/alertmanager-ntfy` after verifying its current release, image
provenance, architecture support, maintenance status, and configuration against
the pinned version. Keep adapter configuration in plaintext and credentials in
a separate SOPS Secret. Configure synchronous forwarding so delivery failures
produce a non-2xx result and are visible to Alertmanager.

Do not send raw Alertmanager JSON as the phone notification body.

### 8. Keep Seerr as the only direct media producer initially

Configure Seerr's native ntfy agent to publish to `media`. Start with only:

- Media available
- Request processing failed
- Issue reported

Do not enable request-created, auto-approved, approval, download-progress, or
other intermediate notifications until real use demonstrates value.

Seerr stores notification settings in its application database and currently
documents configuration through its web UI. Treat this as an explicitly manual
startup step; do not patch Seerr's database.

### 9. Route Flux and platform health through Prometheus

Use existing or new `PrometheusRule` alerts for:

- Flux Kustomization not Ready beyond the chosen duration
- HelmRelease failure or stalled reconciliation
- Source unavailable
- Node, etcd, Cilium, Longhorn, DNS, certificate, storage, backup, and VPN
  failures

Do not send routine Flux events directly to ntfy. Direct Flux notifications may
be added later only for deliberate event-style messages that are not health
alerts.

## Exposure decision gate

Before creating the `HTTPRoute`, inspect how existing `*.lab.supermorphic.com`
routes are resolved and reached from outside the home network.

### Decision (recorded): Mode A security model, implemented with Tailscale

The operator selected **Mode A's private security model** — ntfy is never directly
reachable from the public internet — implemented with the **Tailscale Kubernetes
Operator** as reusable cluster infrastructure rather than a generic VPN. Repository
inspection confirmed the driver: only an `internal` Envoy gateway exists
(`*.lab.supermorphic.com`, wildcard TLS); there is no public GatewayClass, public DNS,
or internet ingress path in Git, so a public endpoint would be a separate
infrastructure project.

Access paths:

- **LAN:** the existing internal gateway / internal DNS, host
  `ntfy.lab.supermorphic.com`, for browser and CLI. Unchanged.
- **Off-site:** the iPhone runs the Tailscale client with **VPN On Demand**; ntfy is
  exposed **privately to the tailnet** via a Tailscale Kubernetes **Ingress (HTTPS)**
  backed by a shared, HA ingress **ProxyGroup**. `iPhone → Tailscale → ProxyGroup →
  ntfy Service`. Apple wakes the app via the `ntfy.sh` upstream poll; the app then
  retrieves the body over the tailnet.

Constraints (do not violate):

- No public GatewayClass or public Envoy listener; no router port-forward / NAT
  exposure; no Cloudflare Tunnel.
- **Tailscale Funnel is not enabled initially.** It is documented as a possible future
  alternative if VPN-independent public access is later desired.
- ntfy keeps full authentication regardless of tailnet restriction:
  `auth-default-access: deny-all`, require-login, per-producer publisher tokens and
  ACLs. The metrics port `9090` stays cluster-internal only.
- Internal producers (Seerr, the Alertmanager adapter) publish to the in-cluster
  Kubernetes Service directly — **not** through Tailscale.
- `upstream-base-url: https://ntfy.sh` is preserved for iOS wake-up.

The ntfy `base-url` and the iOS app's Default Server are the canonical Tailscale
MagicDNS HTTPS FQDN (`https://ntfy.<tailnet>.ts.net`). Tailscale is deployed as shared
infrastructure in `kubernetes/apps/networking/tailscale-operator/`; see
`docs/tailscale-operator.md`.

> The original Mode A (generic VPN) / Mode B (public HTTPS) framing is retained below
> for historical context; **Mode B is not implemented** and Mode A is realized via
> Tailscale as described above.

### Mode A — LAN or VPN only (historical framing)

Use the existing internal gateway and internal DNS.

Properties:

- The ntfy endpoint is not reachable directly from the public internet.
- The iPhone can retrieve notifications while on home Wi-Fi or while a remote
  VPN (here, Tailscale) is connected.
- Apple may wake the app when away from home, but the app cannot retrieve the
  alert body until it can reach the server.
- Reliable off-site delivery requires an always-on/on-demand VPN arrangement
  (here, Tailscale VPN On Demand) that permits the iPhone to reach ntfy.

### Mode B — Publicly reachable HTTPS endpoint (NOT implemented)

Not chosen. Recorded only for context: exposing ntfy through a trusted public ingress
path would require a public GatewayClass, public DNS, an internet ingress path, and
hardening that do not exist in this repository. If VPN-independent public access is
ever wanted, evaluate Tailscale Funnel first before building a public gateway.

## Repository discovery required before editing

The implementation agent must first inspect:

1. Root and nested `AGENTS.md` files.
2. `.justfile`, `kubernetes/mod.just`, and any repository command conventions.
3. Existing Flux app layout and category/namespace conventions.
4. At least two current `bjw-s/app-template` applications with:
   - a Longhorn RWO PVC,
   - an `HTTPRoute`,
   - SOPS environment secrets,
   - a `ServiceMonitor`,
   - NetworkPolicy or CiliumNetworkPolicy,
   - Gatus monitoring.
5. Monitoring stack values and determine whether Prometheus Alertmanager,
   Grafana-managed Alerting, or both are active.
6. Existing alert labels, severity names, grouping, inhibition, and receiver
   provisioning.
7. Existing internal/public GatewayClasses, listeners, certificates, and DNS
   behavior.
8. Existing validation, verification, smoke-test, and documentation patterns.
9. Renovate image annotation and digest-pinning conventions.
10. Whether a reloader/controller already restarts workloads after Secret or
    ConfigMap changes.

Reuse discovered patterns. Do not introduce a second structure merely because
the example paths below differ from the repository.

## Proposed repository layout

Adjust names to match discovered conventions. A likely layout is:

```text
kubernetes/apps/monitoring/ntfy/
├── app/
│   ├── helmrelease.yaml
│   ├── httproute.yaml
│   ├── kustomization.yaml
│   ├── networkpolicy.yaml
│   ├── secret.sops.yaml
│   └── servicemonitor.yaml
└── ks.yaml

docs/
└── ntfy-startup-guide.md

scripts/validate/
└── ntfy.sh

scripts/verify/
└── ntfy.sh
```

If the repository uses one manifest per resource inside `app-template` values,
follow that instead. Do not create a new namespace unless the existing
repository categorization clearly calls for one. Prefer the existing monitoring
or observability namespace because ntfy is notification infrastructure.

If Prometheus Alertmanager requires a transformer, place it beside ntfy as a
separate application or controller with its own Service and narrowly scoped
credentials. Do not hide two independently versioned containers in one Pod
unless the repository has an explicit sidecar convention and shared lifecycle
is justified.

## Kubernetes workload requirements

### HelmRelease

Use the repository's pinned `bjw-s/app-template` chart.

Configure:

- One controller and one replica.
- `Recreate` rollout strategy.
- Official ntfy image pinned by immutable version and repository-standard
  digest handling.
- Arguments: `serve`.
- Main HTTP port 80.
- Dedicated metrics port 9090.
- ConfigMap-mounted `/etc/ntfy/server.yml`.
- Longhorn PVC mounted at `/var/lib/ntfy`.
- Secret environment variables for provisioned identities, ACLs, and tokens.
- Time zone `America/Denver` only if the repository normally configures it;
  store timestamps in UTC where ntfy does so by default.
- Explicit requests and limits derived from existing app conventions. Begin
  around 25m CPU / 64 MiB memory requests and 500m CPU / 256 MiB memory limits
  only if those values fit repository policy.
- Readiness and liveness probes against `/v1/health`.
- Startup probe if repository policy requires it for PVC-backed applications.
- Pod and container security contexts consistent with the official image and
  repository policy.
- A fixed non-root UID/GID only after verifying the mounted volume and image
  operate correctly with it.
- `runAsNonRoot`, dropped capabilities, no privilege escalation, read-only root
  filesystem, and `seccompProfile: RuntimeDefault` where compatible.
- Writable temporary storage only where runtime testing proves it necessary.
- Standard topology/spread and node scheduling conventions, without pretending
  a single replica is highly available.
- Config and Secret checksum/reloader behavior so declarative authentication
  changes cause a controlled restart.

### Storage

Use:

```text
access mode: ReadWriteOnce
capacity:    2Gi
mount:       /var/lib/ntfy
```

Do not put the SQLite databases on the SMB media share.

Configure a retention policy consistent with other application-config PVCs.
Document that a restore or reschedule may briefly interrupt delivery, but cached
messages survive a normal Pod recreation and cross-node Longhorn reattachment.

### Service and HTTPRoute

Expose:

| Port | Purpose | Exposure |
|---:|---|---|
| 80 | Web UI, publish/subscribe API, `/v1/health` | Gateway and approved in-cluster producers |
| 9090 | Prometheus metrics | Monitoring namespace only |

The `HTTPRoute` must:

- Use the selected internal or public listener.
- Request or reference the correct TLS certificate.
- Preserve streaming/WebSocket behavior.
- Avoid response buffering where the gateway supports an explicit setting.
- Set timeouts appropriate for long-lived subscriptions.
- Route only the ntfy hostname to the ntfy Service.

### Network policy

Start from the repository's normal default-deny posture.

Allow ingress:

- Existing gateway namespace/controller to port 80.
- Seerr Pod/namespace to port 80.
- Alertmanager or the Alertmanager adapter to port 80.
- Prometheus to port 9090.
- Gatus to port 80 if Gatus checks the in-cluster Service directly.

Allow egress:

- DNS to the cluster DNS service.
- HTTPS to `ntfy.sh` for iOS upstream poll requests.
- Any other destination required by the selected gateway/sidecar pattern.

If Cilium FQDN policies are used, constrain the upstream egress to
`ntfy.sh:443`. If the repository cannot safely implement FQDN egress because of
DNS-proxy behavior, document the broader rule rather than adding a brittle
policy.

### Metrics and health

Create a `ServiceMonitor` for the dedicated metrics port. The metrics endpoint
must not be exposed through the public `HTTPRoute`.

Add or confirm alerts for:

- ntfy Deployment unavailable.
- ntfy health endpoint failing.
- ntfy Pod crash looping or restarting repeatedly.
- PVC unavailable or Longhorn volume faulted/degraded.
- Alert delivery failures from Alertmanager/adapter.

Add a Gatus check for the HTTPS `/v1/health` endpoint and require:

```json
{"healthy":true}
```

Avoid a circular blind spot: an in-cluster Gatus instance cannot report a total
cluster or internet outage through ntfy running in the same cluster. Document
that independent external/dead-man monitoring remains future work.

## Secret bootstrap

Add a guarded repository recipe or script that follows the existing SOPS
bootstrap model. The operator supplies values through hidden prompts or
environment variables; the script validates them and writes only the encrypted
Secret.

Required secret inputs:

```text
NTFY_KEITH_PASSWORD_HASH
NTFY_ALERTMANAGER_PASSWORD_HASH
NTFY_SEERR_PASSWORD_HASH
NTFY_AUTOMATION_PASSWORD_HASH

NTFY_ALERTMANAGER_TOKEN
NTFY_SEERR_TOKEN
NTFY_AUTOMATION_TOKEN
```

The service-account passwords may be randomly generated and never used after
their bcrypt hashes are produced. Producer integrations should use tokens.

Token requirements for the pinned ntfy release:

- Begin with `tk_`.
- Contain 32 total characters.
- Be generated with a cryptographically secure source.
- Never be printed after creation.

The personal `keith` password is entered manually on the iPhone and optional
web clients. Store only its bcrypt hash in the ntfy provisioning Secret.

The bootstrap flow must:

1. Refuse to operate without an explicit confirmation token matching repository
   conventions.
2. Validate that SOPS/age is available.
3. Validate bcrypt-hash and ntfy-token formats without echoing values.
4. Assemble the exact `NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS`, and
   `NTFY_AUTH_TOKENS` values required by the pinned release.
5. Produce `secret.sops.yaml`.
6. Verify the expected secret fields exist after decryption without printing
   their values.
7. Leave Git add/commit/push to the operator unless repository policy explicitly
   says otherwise.

Do not generate credentials inside an init container on every startup. Stable,
rotatable credentials belong in SOPS.

## Implementation sequence

### Phase 1 — Discovery and design confirmation

1. Inspect repository conventions listed above.
2. Determine the actual application path and namespace.
3. Determine the authoritative alert path.
4. Determine the exposure mode and record the operator decision.
5. Verify ntfy image tag, architecture, command, ports, configuration syntax,
   health endpoint, metrics endpoint, and non-root behavior.
6. Produce a concise pre-edit summary of discovered patterns and any deviation
   from this plan.

Stop and ask before editing if the public/private exposure decision has not
been made.

### Phase 2 — ntfy application

1. Add the Flux Kustomization and dependency wiring.
2. Add the `bjw-s/app-template` HelmRelease.
3. Add plaintext `server.yml` configuration.
4. Add the Longhorn PVC.
5. Add the SOPS Secret skeleton and guarded bootstrap recipe.
6. Add Service, HTTPRoute, certificate/DNS wiring as needed.
7. Add NetworkPolicy/CiliumNetworkPolicy.
8. Add ServiceMonitor and Gatus health check.
9. Add offline validation and live verification scripts.
10. Add the startup guide described below.

### Phase 3 — Alertmanager integration

1. Trace one existing `PrometheusRule` alert to its current receiver.
2. Reuse existing severity labels; do not invent a parallel scheme.
3. Route `severity=critical` to `critical`.
4. Route `severity=warning` to `homelab`.
5. Keep grouping, repeat intervals, resolved messages, and inhibition in
   Alertmanager.
6. Use a direct Grafana custom webhook payload only if Grafana-managed Alerting
   is truly authoritative and provisionable in the deployed version.
7. Otherwise deploy and configure the verified Alertmanager-to-ntfy adapter.
8. Protect both the Alertmanager-to-adapter hop and adapter-to-ntfy hop with
   separate credentials where supported.
9. Add a test alert or a guarded synthetic notification that proves firing and
   resolved formatting.

Recommended notification behavior:

| Status | Topic | Priority | Content |
|---|---|---|---|
| Critical firing | `critical` | `urgent` or `high` | Summary, affected service, duration/start time, Grafana/runbook link |
| Critical resolved | `critical` | `default` | Clear resolved title and recovery duration |
| Warning firing | `homelab` | `default` | Summary, affected service, useful link |
| Warning resolved | `homelab` | `low` or `default` | Clear recovery message |

Do not allow a missing optional annotation to produce an empty notification.

### Phase 4 — Seerr integration

Keep the Kubernetes portion limited to provisioning the `seerr` publisher and
its write-only token. Add exact manual Seerr UI steps to the startup guide.

Do not store the Seerr token in a second plaintext location. The operator may
decrypt/copy it transiently during configuration. If the repository already has
a safe secret-display helper, reuse it; otherwise document a command that
extracts only the requested token with an explicit confirmation and does not
write it to disk.

### Phase 5 — Optional producers

Only after the initial system is quiet and reliable, evaluate:

- Gatus direct `critical` publishing as an independent path only if Gatus is
  hosted outside the monitored failure domain.
- Backup jobs publishing failures to `critical` and successes only to
  `homelab`, if success notifications prove useful.
- Guarded maintenance and resilience-test completion messages through the
  `automation` token.
- GitHub/Renovate events through `homelab` only if they add value beyond the
  existing GitHub mobile/email workflow.
- A separate `security` topic only after actual security-event volume justifies
  it.

Do not add more topics merely to mirror application names.

## Offline validation

Add the ntfy app to existing repository validation rather than creating an
isolated validation framework.

Offline checks must confirm:

- Helm and Kustomize render successfully.
- kubeconform passes.
- Repository Conftest/Rego policies pass.
- Image tag is immutable and digest policy is satisfied.
- Exactly one ntfy replica is configured with an RWO PVC-compatible strategy.
- The PVC is present, uses the expected storage class, and mounts at
  `/var/lib/ntfy`.
- `server.yml` parses as YAML and contains:
  - HTTPS `base-url`,
  - `behind-proxy: true`,
  - persistent cache and auth files,
  - `auth-default-access: deny-all`,
  - login required,
  - signup disabled,
  - iOS upstream enabled,
  - dedicated metrics listener.
- Attachment storage and email/phone features are absent.
- SOPS-encrypted files contain no plaintext secret values.
- HTTPRoute uses the selected listener and hostname.
- Metrics are not exposed by the HTTPRoute.
- Required NetworkPolicy ingress and egress intent is represented.
- ServiceMonitor targets the named metrics port.
- Gatus targets `/v1/health`.
- ShellCheck passes for new scripts.

The validator must never contact the live cluster or decrypt and print secrets.

## Live verification

Expose one public operator command following repository conventions, such as:

```text
mise exec -- just kube ntfy-verify
```

The live verification must be read-only except for publishing a uniquely
identified test message to a dedicated, documented test topic or to the real
topics under an explicit confirmation guard.

Verify:

1. Flux Kustomization Ready.
2. HelmRelease Ready.
3. Deployment rollout complete.
4. Pod Ready.
5. PVC Bound.
6. HTTPRoute Accepted and ResolvedRefs true.
7. Internal Service `/v1/health` returns HTTP 200 and `healthy=true`.
8. Gateway HTTPS `/v1/health` returns HTTP 200 and `healthy=true`.
9. Prometheus discovers the ServiceMonitor target.
10. Anonymous publish to `critical` is denied.
11. Anonymous subscribe/poll from `critical` is denied.
12. `seerr` token can publish to `media`.
13. `seerr` token cannot publish to `critical`.
14. `alertmanager` token can publish to `critical` and `homelab`.
15. `alertmanager` token cannot read either topic.
16. `keith` credentials can read all three topics.
17. `keith` credentials cannot publish to the three topics.
18. A unique marker survives a Pod recreation through the persistent cache.
19. ntfy can reach its upstream wake service without exposing credentials.

Do not print credentials, Authorization headers, Secret YAML, or message-cache
contents. Redact URLs if they embed credentials or tokens.

Mobile push is a separate human acceptance test; Kubernetes health cannot prove
APNs wake-up and off-site retrieval.

## Completion criteria

Implementation is complete only when:

- All repository CI/offline validation passes.
- The SOPS bootstrap flow has been operator-run successfully.
- Flux reconciles the app.
- Live verification passes.
- Anonymous access is denied.
- Least-privilege positive and negative ACL tests pass.
- Prometheus can scrape ntfy metrics.
- Gatus reports the health endpoint healthy.
- A critical firing and resolved alert reach the iPhone with correct priority
  and readable formatting.
- A Seerr test notification reaches `media`.
- A real or test "media available" event reaches `media`.
- The iPhone receives a notification once on Wi-Fi and once in the selected
  off-site connectivity mode.
- The startup guide has been followed from a clean client installation and
  corrected for any UI differences.
- All manual state is explicitly documented.

## Rollback

Rollback must be recoverable and must not delete the PVC.

1. Disable or remove Alertmanager and Seerr routes to ntfy first.
2. Reconcile the previous ntfy HelmRelease revision.
3. Preserve the PVC and SOPS Secret during application rollback.
4. If credentials are suspected compromised, rotate the affected publisher
   token in SOPS, reconcile, then update only that producer.
5. Delete the ntfy PVC only through a separate, explicit destructive operation
   after confirming cached history and auth-database loss are acceptable.

## User startup guide

The implementation must create `docs/ntfy-startup-guide.md` with the following
content, updated to match the final repository paths and UI.

### A. Before deployment

Record:

```text
ntfy URL:        https://ntfy.lab.supermorphic.com
exposure mode:   LAN/VPN-only or public authenticated HTTPS
topics:          critical, homelab, media
subscriber:      keith
```

Generate and SOPS-encrypt:

- Keith's bcrypt password hash.
- One distinct publisher token for Alertmanager.
- One distinct publisher token for Seerr.
- One distinct publisher token for automation.

Run the repository's ntfy secret bootstrap command, validate the encrypted file,
commit, push, and wait for Flux reconciliation.

Never paste the plaintext password or publisher tokens into Git, an issue, a PR,
or an agent conversation.

### B. Initial server verification

Run the repository's ntfy live verification command.

Then open:

```text
https://ntfy.lab.supermorphic.com
```

Confirm:

- HTTPS is trusted.
- A login is required.
- Keith can log in.
- Anonymous access cannot subscribe or publish.
- The health check is green in Gatus.
- Prometheus shows the ntfy target Up.

### C. Configure the ntfy iPhone app

This portion is necessarily manual because iOS application settings are
device-local.

1. Install the official **ntfy** app from Apple's App Store.
2. Allow notifications when iOS prompts.
3. Add the self-hosted server:

   ```text
   https://ntfy.lab.supermorphic.com
   ```

4. Add the `keith` username and its plaintext password to that server entry.
5. Subscribe to:

   ```text
   critical
   homelab
   media
   ```

6. Give each topic a clear display name if the application supports it:

   ```text
   Homelab Critical
   Homelab
   Media
   ```

7. Leave publishing from the phone unused; the `keith` account is read-only.
8. In iOS Settings, allow ntfy notifications.
9. Keep Time Sensitive notifications enabled if urgent `critical` messages
   should be prominent.
10. Choose whether `media` should make a sound. Start with normal delivery and
    mute it later if it becomes noisy.

Test in this order:

1. Phone unlocked on home Wi-Fi.
2. Phone locked on home Wi-Fi.
3. Phone locked with Wi-Fi disabled and cellular active.
4. If using LAN/VPN-only mode, repeat step 3 with the VPN connected.
5. Send a firing and then resolved alert to confirm both formatting paths.

Expected behavior:

- `critical` arrives promptly and prominently.
- `homelab` arrives normally.
- `media` arrives normally or quietly.
- Tapping an alert opens ntfy and displays the complete message.
- Off-site delivery works only when the phone can reach the self-hosted URL.

If the phone wakes but shows no message while off-site, first test the ntfy URL
in Safari. That usually indicates a reachability/VPN problem, not an APNs
problem.

### D. Configure the web client

The web client is optional and its subscriptions are browser-local unless the
current ntfy version synchronizes them for the logged-in user.

1. Open the ntfy URL.
2. Log in as `keith`.
3. Subscribe to `critical`, `homelab`, and `media`.
4. Allow browser notifications only on trusted personal devices.
5. Do not enable Web Push server configuration unless background browser
   notifications are actually wanted; the native iOS app does not require
   self-hosted Web Push/VAPID configuration.

### E. Configure the ntfy CLI on macOS or Linux

The CLI is optional. Prefer a checked-in template without credentials and a
local credential file that is excluded from Git.

Tracked template:

```yaml
default-host: https://ntfy.lab.supermorphic.com

subscribe:
  - topic: critical
  - topic: homelab
  - topic: media
```

Local-only addition:

```yaml
default-user: keith
default-password: REPLACE_LOCALLY
```

Supported client locations include:

```text
macOS: ~/Library/Application Support/ntfy/client.yml
Linux: ~/.config/ntfy/client.yml
root:  /etc/ntfy/client.yml
```

Use `default-token` instead of username/password only if a dedicated read-only
subscriber token is provisioned. Never reuse a publisher token in a subscriber
client.

### F. Configure Seerr

Seerr's ntfy agent configuration is stored in Seerr and must be entered in the
web UI.

1. Retrieve the `seerr` publisher token using the repository's guarded secret
   helper.
2. In Seerr, open:

   ```text
   Settings -> Notifications -> ntfy.sh
   ```

3. Configure:

   ```text
   Enable Agent:     On
   Server Root URL:  http://ntfy.<namespace>.svc.cluster.local
   Topic:            media
   Token:            the dedicated Seerr token
   Priority:         Default (3)
   Language:         English
   ```

   Prefer the in-cluster Service URL over the public URL so Seerr does not
   hairpin through the gateway. Replace the namespace and service DNS name with
   the final manifest values.

4. Do not enter username/password when token authentication is configured.
5. Click Test and confirm the message arrives under `media`.
6. Save.
7. Enable only:

   ```text
   Media Available
   Request Processing Failed
   Issue Reported
   ```

8. Review individual Seerr user notification preferences. Avoid sending the
   same availability notification through both ntfy and Seerr Web Push.

If Seerr's current UI uses different event names, document the exact names and
choose their closest equivalents.

### G. Configure Alertmanager/Grafana

This should be repository-provisioned, not configured manually in Grafana,
unless the existing monitoring deployment is intentionally UI-managed.

The startup guide must state which path was implemented:

```text
Prometheus Alertmanager -> adapter -> ntfy
```

or:

```text
Grafana-managed Alerting -> custom webhook payload -> ntfy
```

For either path, confirm:

- `critical` and `warning` severities use separate topic routing.
- Resolved notifications are enabled.
- Repeated notifications are not excessively frequent.
- Token authentication uses the dedicated Alertmanager publisher.
- Messages include a useful title, summary/description, status, and link.

Use the provisioned test mechanism to send one warning and one critical alert,
then resolve both.

### H. Configure Gatus

The normal Gatus health check should be Git-managed and require no UI work.

If Gatus is in the same cluster, use it only to observe ntfy health. Do not claim
it provides an independent outage notification path.

If an external Gatus instance is added later, give it its own write-only
`critical` publisher token and configure that token outside the monitored
cluster.

### I. Configure Radarr, Sonarr, Prowlarr, qBittorrent, and Plex

Do not configure direct ntfy notifications initially.

Use:

- Seerr for request/availability/issue events.
- Prometheus/Alertmanager for application health, restart, storage, VPN, import,
  and operational failures.

This avoids duplicate events such as:

```text
download completed
import completed
Seerr detected available
Plex detected new media
```

Add direct integrations only after identifying a specific missing event that
cannot be expressed through Seerr or monitoring.

### J. Normal operation and tuning

After two weeks, review:

- Notifications per topic per day.
- Duplicate alerts.
- Alerts without actionable text.
- Alerts that fired and resolved too quickly.
- Alerts that should have been inhibited by a root-cause event.
- Whether `media` should be muted.
- Whether any warning truly belongs in `critical`.

Target behavior:

```text
critical: rare and immediately meaningful
homelab: actionable warnings, not routine success logs
media: availability and failure signal, not every workflow transition
```

### K. Credential rotation

For one compromised producer:

1. Generate a replacement token.
2. Replace only that token in the SOPS Secret.
3. Reconcile/restart ntfy.
4. Update the producer.
5. Verify positive and negative ACL tests.
6. Confirm the old token is rejected.

For Keith's password:

1. Generate a new bcrypt hash locally.
2. Replace the provisioned hash in SOPS.
3. Reconcile/restart ntfy.
4. Update the iPhone, web, and CLI clients.
5. Verify the old password is rejected.

Do not rotate every producer because one unrelated token changed.

### L. Troubleshooting order

For a missing iPhone notification:

1. Can Safari reach the ntfy URL from the phone's current network?
2. Does `/v1/health` return healthy?
3. Is the phone logged into the correct self-hosted server?
4. Is the exact topic subscribed?
5. Can an authenticated poll retrieve the test message?
6. Did the producer receive HTTP success?
7. Does the producer token have write-only access to the intended topic?
8. Can ntfy reach `ntfy.sh:443` for the iOS wake-up request?
9. Are iOS notification permissions enabled?
10. Does delivery work with the app open but fail when locked?

Classify failures:

```text
producer -> ntfy failure
authorization failure
ntfy storage/server failure
gateway/DNS/TLS reachability failure
iOS upstream wake failure
device notification-permission failure
```

Do not disable authentication or expose anonymous topics as a troubleshooting
shortcut.

## Agent handoff requirements

At completion, report:

1. Files added and changed.
2. Exposure mode implemented.
3. Final URL and namespace.
4. Image/chart versions and digests.
5. Storage and security decisions.
6. Which settings are Git-managed.
7. Which settings remain manual and why.
8. Offline validation results.
9. Live checks run versus explicitly left for the operator.
10. Exact operator commands for secret bootstrap, Flux reconciliation, live
    verification, and test notifications.
11. Any deferred integration or risk.

Do not claim mobile push is complete until the operator performs the locked
phone and off-site tests.

## Authoritative references

- ntfy configuration and access control:
  <https://docs.ntfy.sh/config/>
- ntfy iOS instant notifications:
  <https://docs.ntfy.sh/config/#ios-instant-notifications>
- ntfy Kubernetes and container installation:
  <https://docs.ntfy.sh/install/>
- ntfy phone clients:
  <https://docs.ntfy.sh/subscribe/phone/>
- ntfy CLI client configuration:
  <https://docs.ntfy.sh/subscribe/cli/>
- ntfy publishing API:
  <https://docs.ntfy.sh/publish/>
- Seerr ntfy notification agent:
  <https://docs.seerr.dev/using-seerr/notifications/ntfy/>
- Prometheus Alertmanager:
  <https://prometheus.io/docs/alerting/latest/alertmanager/>
- Grafana webhook contact points:
  <https://grafana.com/docs/grafana/latest/alerting/configure-notifications/manage-contact-points/integrations/webhook-notifier/>
- Alertmanager-to-ntfy adapter candidate:
  <https://github.com/alexbakker/alertmanager-ntfy>

