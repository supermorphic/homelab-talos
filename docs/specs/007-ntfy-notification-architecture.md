# ntfy Notification Architecture

## Intent and delivery

ntfy provides private authenticated message storage and mobile delivery. Domain producers
own signals, Prometheus/Alertmanager own alert evaluation and lifecycle, and the
synchronous `alertmanager-ntfy` bridge formats webhook messages. ntfy publish failure
returns an error to Alertmanager rather than being acknowledged early.

[Server source](../../kubernetes/apps/monitoring/ntfy/) and
[bridge source](../../kubernetes/apps/monitoring/alertmanager-ntfy/) own exact configuration,
ACLs, topics, and routing. Critical and warning alerts follow severity-based topics;
resolved messages retain their topic at normal priority. Grouping, deduplication,
inhibition, silences, and repeat timing remain in Alertmanager. Seerr publishes selected
household media events, and n8n's shared failure handler publishes bounded workflow
metadata. Routine media/Flux health does not add direct producer integrations or topics.

## State and authorization

One retained single-writer config claim preserves cache and runtime databases. Git plus
the operator-held age identity reconstruct users, ACLs, tokens, and subscriber password
hash after claim loss. Message history can be lost even when access policy is recoverable;
retained storage is not high availability.

The identity registry owns least-privilege roles, consumer types, and retirement
`tombstones`. Each producer/subscriber has independent credentials; network reachability
does not grant topic access. Anonymous access and signup remain disabled. Secret
projection supplies only explicit per-consumer material: ntfy's authentication keys,
the bridge's auth fragment, and Homepage's mirrored read token. Publisher credentials
are never reused for human subscription.

## Private path and client acceptance

LAN access uses the internal Gateway; off-site retrieval uses the shared Tailscale
Ingress ProxyGroup. The configured tailnet `base-url` is canonical for iOS. No public
ntfy listener is required. ntfy sends a message identifier and hashed topic upstream
for APNs wake-up; bodies remain self-hosted and the client fetch requires Tailscale.
World HTTPS egress supports this need but is not a destination-specific ntfy.sh allowlist.

External tailnet policy is operator-managed and cannot be reconstructed from cluster
source alone. Preserve unrelated rules while establishing these relationships:

- `tagOwners["tag:ntfy"]` permits `tag:k8s-operator`.
- `autoApprovers.services["tag:ntfy"]` permits the shared `tag:k8s` proxies.
- The reviewed human grant admits HTTPS (`tcp:443`) to `tag:ntfy`.

`autogroup:member` is acceptable only for the current single-user tailnet; review an
explicit group before adding users. Require the Service approved and both proxies healthy.

On a phone, select the canonical server, authenticate as `subscriber`, and subscribe to
its declared topics. Require positive test delivery with the phone locked on Wi-Fi and
then cellular with Tailscale or VPN On Demand active. HTTP health, ACL checks, and cache
acceptance cannot prove handset wake-up/retrieval.

## Credential lifecycle and reconstruction

The guarded `mise exec -- just repo ntfy-identity` workflow owns registry reconciliation
and encrypted updates; help and [its implementation](../../scripts/secrets/ntfy-identity.sh)
own syntax/guards. Under operator SOPS custody, establish the subscriber password, then
reconcile all active identities before bootstrap. Reconciliation preserves active
credentials and rejects undeclared Secret state. Retire via a registry tombstone before
reconciliation; deleting the registry entry first leaves unauthorized unknown state.

Git-managed consumers rotate with their encrypted mirrors and rollout stamps. API-managed
Seerr and n8n consumers require this ordering:

1. Stage one pending token and deploy the encrypted change so ntfy accepts old and new.
2. Run guarded `mise exec -- just kube ntfy-consumer-sync <consumer>` from the authorized
   deployed-source checkout. Synchronization prefers the pending token. Seerr tests before
   saving managed fields; n8n updates its exact named private API credential while preserving
   its ID. This is application mutation and does not import or publish workflows.
3. Require real delivery acceptance before finalizing the token, then deploy finalization
   to revoke the old token. An accepted credential API write alone is insufficient.

On failure preserve the old token, repair sync/delivery, and reuse the existing pending
rotation. Do not stage a second token or print credentials for manual copying. n8n's
handler contract belongs to [specification 023](023-n8n-workflow-automation-platform.md).
Subscriber password updates preserve service tokens and require client login updates.

For lost ntfy state, restore/reconcile canonical ciphertext before using the existing
guarded suspended-main bootstrap. Tailscale dependencies must already be ready. Start
ntfy before a separately suspended bridge; successful verification then permits durable
activation through Git. Ordinary rotation/restarts do not use exceptional bootstrap.
A failed bootstrap preserves claims/Secrets and re-suspends reconciliation.

## Failure interpretation

Isolate failures from client toward producer: private URL/Tailscale reachability, server
health, subscriber ACL, deployed ntfy verification, then bridge or application sync.
Direct publish success with integration failure points upstream of ntfy. For iOS-only
failure inspect upstream HTTPS, notification permissions, canonical server/subscriptions,
and Tailscale availability; do not open anonymous topics or public access as a shortcut.

The registered Flux delivery test requires attributable firing and resolved cache messages;
handset receipt remains separate. Homepage shows the latest cached critical message,
including resolved messages, rather than active-alert state. Monitoring and delivery share
cluster fate, so these controls cannot provide independent dead-man monitoring.
