# Operate ntfy notifications

This guide explains how to start, connect, verify, and maintain the private **ntfy**
notification service. ntfy runs in the `ntfy` namespace from
`kubernetes/apps/monitoring/ntfy/`.

The Tailscale foundation must already be complete. See
[Tailscale initial setup](tailscale-initial-setup.md) and
[Tailscale Operator operations](tailscale-operator-operations.md).

## How notifications flow

ntfy is the final delivery service for platform alerts and selected media events:

```text
Prometheus / Alertmanager
        ↓
  alertmanager-ntfy
        ↓
 critical / homelab ───┐
                       │
Seerr → media ─────────┤→ ntfy → iPhone / web
                       │
Homepage ← critical ───┘
```

Alertmanager still owns alert grouping, silences, inhibition, repeat intervals, and
resolved notifications. The `alertmanager-ntfy` adapter converts Alertmanager webhooks
into ntfy messages. Seerr publishes selected media events directly. Homepage is a
read-only view of the latest cached critical message.

Three topics separate the notification purposes:

| Topic | Purpose | Publisher |
| --- | --- | --- |
| `critical` | Failures needing prompt attention | Alertmanager |
| `homelab` | Warnings, degraded state, and operator events | Alertmanager |
| `media` | Selected Seerr availability, request, and issue events | Seerr |

Each client has a separate identity with only the access it needs:

| Identity | Human meaning | Access |
| --- | --- | --- |
| `subscriber` | The human account used by the iPhone and web UI | Read `critical`, `homelab`, and `media` |
| `alertmanager` | The alert bridge publisher | Write `critical` and `homelab` |
| `seerr` | The Seerr publisher | Write `media` |
| `homepage` | The Homepage widget | Read `critical` |

Network reachability does not grant topic access. ntfy requires authentication and
denies anonymous access. Do not disable authentication or open anonymous topics as a
troubleshooting shortcut.

## What Git owns and what applications own

Git and SOPS own the ntfy server configuration, identity registry, encrypted users,
ACLs, tokens, workload configuration, routes, and network policy. Flux continuously
reconciles that state after it reaches `main`.

The retained ntfy PVC stores the message cache and ntfy's runtime authentication
database. ntfy rebuilds its authorization state from the encrypted declarative Secret
when it starts. Seerr is different: its ntfy notification settings live in Seerr's own
PVC-backed database and must be synchronized through the Seerr API. The iPhone's server,
login, topic subscriptions, and notification permissions are also client-managed state.

A green ntfy Pod therefore does not prove phone delivery, Alertmanager delivery, or
Seerr delivery. Those paths have separate checks and acceptance steps below.

## Authorize the private Tailscale Service

ntfy owns the tailnet policy relationships for its private Tailscale Service. The policy
is external operator-managed state in the Tailscale Admin Console; it is not an
executable repository file.

In **Access controls**, merge these fragments into the current policy:

```jsonc
"tagOwners": {
  "tag:ntfy": ["tag:k8s-operator"]
},
"autoApprovers": {
  "services": {
    "tag:ntfy": ["tag:k8s"]
  }
},
"grants": [
  {
    "src": ["autogroup:member"],
    "dst": ["tag:ntfy"],
    "ip": ["tcp:443"]
  }
]
```

These are fragments, not a complete replacement policy. Preserve unrelated entries and
review the Admin Console diff before saving. `tag:k8s-operator` owns the application
tag, the shared `tag:k8s` ProxyGroup may advertise the Service, and the current human
member may reach it only on HTTPS.

`autogroup:member` is acceptable only for the current single-user tailnet. Replace it
with a reviewed group before adding another human user. In **Services**, confirm the ntfy
Service is approved and both shared ingress proxies are healthy. The repository cannot
verify this external policy or a real client's access; the phone acceptance below is the
end-to-end proof.

## Command effects and authority

The confirmation variable on a command is an execution guard. It makes the target and
intent explicit, but it does not by itself decide whether an operator or an agent owns
the action.

| Operation | What it does | Authority boundary |
| --- | --- | --- |
| `ntfy-subscriber-password` | Prompts for the human password and writes its bcrypt hash into encrypted repository state | Operator-run: requires plaintext password input and the operator-held age identity |
| `ntfy-identity` | Creates, reconciles, rotates, or finalizes encrypted repository credentials and rollout stamps | Operator-run: requires the operator-held age identity |
| `ntfy-verify` | Uses the approved diagnostic verifier to inspect live readiness, health, and ACL boundaries | Agent-autonomous when an approved task needs scoped verification; always observational and sends no notification |
| `ntfy-publish-test` | Runs `ntfy-verify`, then publishes three real positive ACL test messages | Operator-run mutating test; exact confirmation acknowledges that clients will receive messages |
| `alertmanager-ntfy-verify` | Uses observer access to check the adapter and Alertmanager's loaded receiver/route | Agent-autonomous when an approved task needs scoped verification; sends no notification |
| `ntfy-consumer-sync seerr` | Decrypts repository credentials, sends a Seerr test notification, then changes Seerr's stored ntfy settings | Operator-run: requires the age identity and changes application-owned state |
| `flux-alert-delivery-test` | Creates and removes a temporary failing Flux object to prove firing and resolved delivery | Operator-run unless an agent is explicitly authorized for that invocation and its required elevated credential |
| `bootstrap ntfy` | Resumes and verifies an intentionally suspended Flux deployment | Operator-run live mutation using the administrator path |

Repository validation such as `mise exec -- just ci` is agent-owned and does not need
cluster credentials.

## First-time setup

Use this path for a new installation or when the canonical ntfy credential state does
not exist. Run the SOPS-writing steps from an operator-authorized checkout with the
repository age identity available.

### 1. Set the subscriber password

This command prompts twice without echo, requires at least 12 characters, generates a
bcrypt hash, and writes only the subscriber user and ACL entries. It preserves any
existing service credentials and never prints the password or hash.

```bash
NTFY_SUBSCRIBER_PASSWORD_CONFIRM='write:monitoring:ntfy-subscriber:sops' \
  mise exec -- just repo ntfy-subscriber-password
```

Store the plaintext password in the operator's password manager. Git stores the
encrypted hash, not a recoverable copy of the password.

### 2. Reconcile all declared identities

The identity registry is
[`kubernetes/apps/monitoring/ntfy/config/identities.yaml`](../../kubernetes/apps/monitoring/ntfy/config/identities.yaml).
Reconciliation creates missing service credentials, applies the exact ACLs, builds the
Alertmanager adapter credential, and creates the Homepage credential mirror. It preserves
existing active credentials and does not change the subscriber password.

```bash
NTFY_IDENTITY_CONFIRM='reconcile:monitoring:ntfy:all:sops' \
  mise exec -- just repo ntfy-identity reconcile all
```

Reconciliation fails without changing files when the subscriber hash is missing. It also
fails if the Secret contains an undeclared identity; retire that identity explicitly in
the registry before authorizing removal.

### 3. Validate and publish the Git state

```bash
mise exec -- just ci
```

Review the encrypted Secret, consumer mirrors, and rollout-stamp changes. Commit them to
a feature branch, open a pull request, and merge only through the normal protected-`main`
workflow. Do not copy plaintext credentials into Git, logs, or pull-request text.

When the ntfy and alertmanager-ntfy Kustomizations are already active, Flux rolls the
affected workloads after the merged Secret hashes change. If a genuine greenfield build
was deliberately committed with either Kustomization suspended, follow
[Exceptional suspended-deployment bootstrap](#exceptional-suspended-deployment-bootstrap)
instead of manually resuming it.

### 4. Verify the deployed service

After Flux has applied the merged revision, run:

```bash
mise exec -- just kube ntfy-verify
mise exec -- just kube alertmanager-ntfy-verify
```

Then configure the iPhone and synchronize Seerr as described below.

## Verify ntfy itself

The verifier is always observational. It deliberately selects the worktree-local
`homelab-diagnostic` context because its approved implementation needs named `exec`
access to inspect ntfy's runtime ACLs and the already-provisioned process environments.
It does not read Kubernetes Secret bodies or print credential values.

```bash
mise exec -- just kube ntfy-verify
```

### What it proves

- The ntfy Flux Kustomization and HelmRelease are Ready.
- The ntfy Deployment has rolled out and its retained PVC is Bound.
- The LAN gateway, TLS, Service, and `/v1/health` path return a healthy response.
- Anonymous publishing and subscription are denied.
- The live `subscriber` account has exactly read-only access to `critical`, `homelab`,
  and `media`.
- The Seerr token cannot publish to `critical`.
- The Alertmanager token cannot subscribe to `critical`.
- Homepage uses the registered Homepage token; it can read only `critical` and cannot
  publish.
- The repository's internal foundation verification also passes.

The denied publish requests are side-effect free. A normal run does not send a
notification.

### What it does not prove

- The iPhone receives an APNs wake-up or can fetch a message over Tailscale.
- iOS notification permission and per-topic subscriptions are correct.
- Alertmanager can deliver a firing and resolved alert through the adapter.
- Seerr's persisted notification settings are correct or an actual Seerr event publishes.
- A cached message survives Pod recreation.

### Send positive ACL test messages

Use the separate exact-confirmed test when the task requires real positive publishing:

```bash
NTFY_PUBLISH_TEST_CONFIRM='test:ntfy:publish:media-critical-homelab' \
  mise exec -- just kube ntfy-publish-test
```

This operator-run command first requires the observational verifier to pass. It then sends
one test message to each topic: Seerr's token to `media`, and Alertmanager's token to
`critical` and `homelab`. It proves those tokens can publish to their intended topics. It
does not exercise the Seerr API or Alertmanager adapter. The cataloged `test.ntfy-publish`
suite is part of the integration campaign, so the weekly and full campaigns also send
these three explicit test notifications.

## Configure the iPhone

The repository pins the ntfy server, not the iOS application version. ntfy's iOS labels
may change, so use the app's current controls for adding a self-hosted server and topic
rather than relying on a historical button name.

1. Install **ntfy** from the App Store and allow iOS notifications.
2. Connect Tailscale. ntfy is private and has no Internet-facing listener.
3. Add the canonical self-hosted server exactly as configured by ntfy's `base-url`:

   ```text
   https://ntfy.<tailnet>.ts.net
   ```

4. Authenticate that server as `subscriber` with the password created during first-time
   setup.
5. Subscribe to `critical`, `homelab`, and `media`. Optional display names are
   **Homelab Critical**, **Homelab**, and **Media**.
6. Run the positive ACL test above and confirm all three messages appear.
7. Repeat acceptance with the phone locked on Wi-Fi, then locked on cellular with
   Tailscale connected or VPN On Demand active.

The self-hosted server sends ntfy's upstream service a poll request containing a message
identifier and hashed topic. Apple Push Notification service wakes the app, and the app
then fetches the message from this private ntfy server. The message body remains on the
self-hosted instance. Tailscale must therefore be available when the phone fetches it.

## Connect notification producers

### Alertmanager and alertmanager-ntfy

Alertmanager uses the stateless `alertmanager-ntfy` bridge in the `ntfy` namespace:

```text
Prometheus → Alertmanager → alertmanager-ntfy → ntfy
```

The bridge publishes synchronously to ntfy's in-cluster Service. A failed ntfy publish
returns an error to Alertmanager instead of being acknowledged early. The deployed
mapping is:

- firing `severity=critical` → `critical`, urgent priority;
- firing `severity=warning` → `homelab`, default priority; and
- resolved critical or warning → the same topic, default priority, with a `Resolved:`
  title.

The `alertmanager` token is part of the canonical ntfy Secret as `auth.yml`; there is no
separate adapter credential-generation step. First-time identity reconciliation creates
it. After Flux reconciles, run:

```bash
mise exec -- just kube alertmanager-ntfy-verify
```

This proves that the adapter Kustomization and HelmRelease are Ready, the Deployment has
rolled out, and Alertmanager's loaded runtime configuration contains the ntfy receiver
and route. It does not send a webhook or notification. Use the end-to-end test below to
prove actual firing and resolved delivery.

### Seerr

Seerr stores notification settings in its own database. The repository therefore uses a
guarded API synchronization workflow after the `seerr` token and the Seerr API key are
deployed from `main`:

```bash
NTFY_CONSUMER_SYNC_CONFIRM='sync:media:seerr:ntfy' \
  mise exec -- just kube ntfy-consumer-sync seerr
```

This is a real application-state mutation, not verification. Before it makes an API
request, the recipe requires:

- the expected repository origin;
- local source matching the deployed source contract;
- `origin/main` matching Flux's current Git artifact; and
- the ntfy, Homepage, and Seerr Kustomizations Ready, active, and applied at that same
  revision.

The workflow decrypts the Seerr API key and ntfy token without printing them. It reads
the current Seerr ntfy settings and owns only these fields:

| Managed field | Required value |
| --- | --- |
| Enabled | `true` |
| Notification types | `280`: Media Available, Request Processing Failed, Issue Reported |
| Server URL | `http://ntfy.ntfy.svc.cluster.local` |
| Topic | `media` |
| Priority | `3` (default) |
| Authentication | Token enabled; username/password disabled |
| Token | Current token, or the pending token during staged rotation |

It preserves other Seerr-owned or operator-owned fields, including poster embedding and
any locale field returned by the API. It first calls Seerr's ntfy test endpoint, which
sends a real test message. Only after that succeeds does it save the candidate settings.
A failed test does not change Seerr.

In the deployed Seerr UI, review **Settings → Notifications → ntfy.sh** after the sync.
Confirm the agent is enabled and that its visible non-secret fields match the table. The
deployed Seerr `v3.0.1` UI does not expose a priority control; the repository API contract
and that version's ntfy agent both use priority `3`. The token may be masked; do not
replace it manually. Review user notification preferences separately so Seerr web push
and ntfy do not duplicate the same availability event.

Do not add direct Plex, qBittorrent, `*arr`, or Tautulli ntfy integrations. Selected media
events belong to Seerr; platform health belongs to Prometheus and Alertmanager.

## Prove end-to-end delivery

Use progressively stronger checks:

```text
ntfy-verify
  → observes ntfy readiness, health, authentication, and ACL boundaries

alertmanager-ntfy-verify
  → observes adapter readiness and Alertmanager's loaded ntfy route

ntfy-publish-test
  → sends direct token-authenticated test messages to all three topics

ntfy-consumer-sync seerr
  → sends a Seerr test message, then persists managed Seerr settings

flux-alert-delivery-test
  → creates temporary failing Flux state
  → waits for the production alert interval
  → proves firing and resolved webhook delivery
  → removes its exact temporary resource
```

The full Alertmanager delivery test is intentionally state-changing and takes about 25
minutes:

```bash
FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved' \
  mise exec -- just kube flux-alert-delivery-test
```

The test creates one uniquely named Flux Kustomization that references a deliberately
nonexistent source. It waits for the real 15-minute `FluxReconciliationFailure` rule,
proves the alert entered Alertmanager's ntfy route and the synchronous webhook succeeded,
deletes only its run-owned Kustomization, then proves the resolved webhook succeeded.
Its cleanup trap also attempts removal on failure.

The metric and API oracles prove webhook delivery to ntfy, not the phone display. Human
acceptance is still required: confirm the iPhone receives the warning and matching
`Resolved:` messages on `homelab` with the generated resource name.

For Seerr, also perform a real application acceptance event after synchronization. Use
one of the three enabled event classes and confirm the resulting `media` notification on
the phone. Do not broaden the mask merely to make testing convenient.

## Homepage and optional clients

Homepage discovers ntfy from its HTTPRoute and polls the in-cluster Service with the
dedicated read-only `homepage` token. The card shows the latest cached `critical`
notification with `title`, `priority`, and `lastReceived`. It is not active-alert state:
after an alert resolves, the newest card value is normally the default-priority
`Resolved:` message.

The card intentionally excludes `homelab` and `media`. `ntfy-verify` proves the Homepage
token mirror and its exact read-only ACL. The ordinary Homepage verifier checks the
dashboard Deployment, route, and page reachability; it does not prove ntfy widget
authorization or the card's displayed message.

For browser access, open `https://ntfy.lab.supermorphic.com` on the LAN or the canonical
Tailscale URL, sign in as `subscriber`, and subscribe to the three topics. A CLI client
may use the same subscriber account from a local, ignored configuration file. This
repository does not provide a checked-in ntfy client configuration. Never reuse a
publisher token in a human subscriber client.

## Credential rotation and maintenance

All SOPS-writing lifecycle commands require the operator-held age identity, write only
encrypted credential state to Git, and avoid printing secrets. Validate the result,
publish it through a pull request, and let Flux reconcile it before testing the new
credential.

### Ensure a missing identity

Use `ensure` when one active identity is absent and the rest of the credential state is
already valid. It preserves every other identity:

```bash
NTFY_IDENTITY_CONFIRM='ensure:monitoring:ntfy:<identity>:sops' \
  mise exec -- just repo ntfy-identity ensure <identity>
```

### Reconcile the complete registry

Use `reconcile all` for first-time setup, after registry changes, or to remove an
explicitly retired identity. It creates missing credentials, preserves active ones, and
fails closed on undeclared Secret state:

```bash
NTFY_IDENTITY_CONFIRM='reconcile:monitoring:ntfy:all:sops' \
  mise exec -- just repo ntfy-identity reconcile all
```

### Rotate Alertmanager or Homepage

These are Git-managed consumers, so one transaction updates the canonical state, any
required credential mirror, and workload rollout stamps:

```bash
NTFY_IDENTITY_CONFIRM='rotate:monitoring:ntfy:<identity>:sops' \
  mise exec -- just repo ntfy-identity rotate <identity>
```

Use `alertmanager` or `homepage` as `<identity>`. After merge and Flux reconciliation,
the affected Pods restart with the new material and the old token is no longer
provisioned. Run `ntfy-verify`; also run `alertmanager-ntfy-verify` for an Alertmanager
rotation.

### Rotate Seerr without an outage

Seerr is an API-managed consumer, so rotation is staged. ntfy must accept both tokens
while Seerr moves from the old token to the new one:

```text
stage new token
  → deploy old and new tokens
  → test and save the pending token in Seerr
  → finalize the repository state
  → deploy only the new token
```

1. Stage the pending token:

   ```bash
   NTFY_IDENTITY_CONFIRM='rotate:monitoring:ntfy:seerr:sops' \
     mise exec -- just repo ntfy-identity rotate seerr
   ```

2. Validate, commit, merge, and wait for Flux to deploy both tokens.
3. Synchronize Seerr. The pending token wins while a rotation is staged:

   ```bash
   NTFY_CONSUMER_SYNC_CONFIRM='sync:media:seerr:ntfy' \
     mise exec -- just kube ntfy-consumer-sync seerr
   ```

4. After the test notification and save succeed, finalize the token:

   ```bash
   NTFY_IDENTITY_CONFIRM='finalize:monitoring:ntfy:seerr:sops' \
     mise exec -- just repo ntfy-identity finalize seerr
   ```

5. Validate, commit, merge, and wait for Flux to remove the previous token. Run
   `ntfy-verify` again.

Only one pending Seerr rotation may exist. If rotation reports an existing pending token,
do not create another. Let Flux deploy that state, rerun the consumer sync, and finalize
the existing rotation.

### Change the subscriber password

Run the same guarded password workflow used during first-time setup. It preserves service
tokens and updates the ntfy and adapter rollout stamps:

```bash
NTFY_SUBSCRIBER_PASSWORD_CONFIRM='write:monitoring:ntfy-subscriber:sops' \
  mise exec -- just repo ntfy-subscriber-password
```

After merge and Flux reconciliation, update the iPhone, web, and any CLI clients. Identity
reconciliation never changes this password.

### Add or retire an identity

Adding an identity is a repository design change. Declare its exact credential type,
ACLs, consumer, and active status in `identities.yaml`; add a reviewed Git- or API-managed
consumer path; extend validation; then run `ensure`. There is intentionally no command
that prints a generated service token for manual copying.

To retire an identity, keep it in the registry with `status: retired`, then run
`reconcile all`. The tombstone authorizes deletion from the declarative state and blocks
accidental recreation. Do not delete the registry entry first; reconciliation rejects an
unknown credential left in the Secret.

## Exceptional suspended-deployment bootstrap

The current ntfy and alertmanager-ntfy Kustomizations are active and reconcile
continuously. Normal credential rotation, an ordinary Pod restart, or routine Flux
reconciliation does not use bootstrap.

Use the ntfy bootstrap only when a rebuild has deliberately staged and merged the ntfy
Kustomization with `spec.suspend: true`. The canonical Secret must already be committed,
and the Tailscale operator and other declared dependencies must be ready.

```bash
NTFY_BOOTSTRAP_CONFIRM='bootstrap:monitoring:ntfy' \
  mise exec -- just bootstrap ntfy
```

The recipe validates source, proves the local and deployed `main` revision contract,
reconciles the Flux source and parent application Kustomization, verifies that ntfy is
still suspended, resumes only ntfy, waits for readiness, and runs `ntfy-verify`. If
verification fails after resume, cleanup re-suspends ntfy while preserving its resources,
including the retained PVC and Secret. After success, make `suspend: false` durable in
Git and rerun the verifier.

If the adapter was separately staged suspended, use its equivalent guarded bootstrap
only after ntfy is ready:

```bash
ALERTMANAGER_NTFY_BOOTSTRAP_CONFIRM='bootstrap:monitoring:alertmanager-ntfy' \
  mise exec -- just bootstrap alertmanager-ntfy
```

It applies the same source, suspension, resume, verification, and failure re-suspension
model to the adapter.

## Troubleshooting

Work from the client toward the producer so each step isolates one boundary:

1. **Reachability:** Open the configured ntfy URL from the current network. When off-LAN,
   confirm Tailscale is connected and the tailnet hostname resolves.
2. **Server health:** Open `<configured-server>/v1/health`. The response must report
   `healthy: true`.
3. **Subscriber authentication:** Sign in as `subscriber` and confirm the intended topic
   can be read. Do not test with a producer token.
4. **Deployed ntfy contract:** Run `mise exec -- just kube ntfy-verify`. Resolve readiness,
   health, identity, mirror, or ACL failures before investigating a producer.
5. **Producer path:**
   - Alertmanager: run `mise exec -- just kube alertmanager-ntfy-verify`, then use the
     guarded delivery test when actual firing/resolved proof is needed.
   - Seerr: review the managed fields and rerun the guarded consumer sync. A failed test
     leaves the stored settings unchanged.
6. **Positive publish:** Run the guarded `ntfy-publish-test`. If direct publishing
   succeeds but an integration fails, the fault is before ntfy in that producer path.
7. **iOS wake-up:** Confirm ntfy can reach `ntfy.sh` over HTTPS. The Cilium policy permits
   this specific architectural need through world TCP port 443.
8. **iPhone state:** Confirm iOS notifications are allowed, all three topics are
   subscribed, the canonical server is selected, and Tailscale or VPN On Demand is active.

## Implementation reference

The main maintained artifacts are:

- `kubernetes/apps/monitoring/ntfy/config/identities.yaml` — identity, ACL, consumer, and
  retirement registry; tooling input only, not deployed by Flux.
- `kubernetes/apps/monitoring/ntfy/app/secret.sops.yaml` — canonical encrypted
  `Secret/ntfy-secret` in namespace `ntfy`.
- `kubernetes/apps/monitoring/ntfy/app/server.yml` — private server behavior, canonical
  Tailscale `base-url`, deny-all default access, cache/auth database paths, and ntfy.sh
  iOS upstream.
- `kubernetes/apps/monitoring/ntfy/app/values.yaml` — ntfy Deployment, retained PVC,
  explicit Secret key projection, and rollout stamps.
- `kubernetes/apps/monitoring/homepage/app/homepage-ntfy.sops.yaml` — encrypted Homepage
  token mirror because Kubernetes Secrets cannot cross namespaces.
- `kubernetes/apps/monitoring/alertmanager-ntfy/` — stateless webhook adapter, routing
  templates, and network policy.
- `scripts/secrets/ntfy-identity.sh` — registry lifecycle and transactional encrypted
  file/stamp updates.
- `scripts/secrets/ntfy-subscriber-password.sh` — human password hashing and encrypted
  update.
- `scripts/secrets/ntfy-consumer-sync.sh` — Seerr test-before-save synchronization.
- `scripts/verify/ntfy.sh` and `scripts/verify/alertmanager-ntfy.sh` — scoped live
  verification.

The canonical Secret supplies only three explicit environment keys to ntfy:
`NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS`, and `NTFY_AUTH_TOKENS`. The adapter mounts only its
generated `auth.yml` key. Homepage receives only its mirrored token. Secret blob hashes
are stamped into the consuming Pod templates so Flux recreates the Pods when encrypted
credential material changes.

Git is the recovery authority for the authorization model: restoring and reconciling the
encrypted files restores the users, ACLs, service tokens, and subscriber password hash.
The retained PVC preserves cached messages and runtime databases but is not the sole copy
of access policy.
