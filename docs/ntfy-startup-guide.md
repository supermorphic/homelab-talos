# ntfy startup guide

Operator runbook for the self-hosted **ntfy** notification service
(`kubernetes/apps/monitoring/ntfy/`, namespace `ntfy`). Notifications reach your iPhone
on the LAN (`https://ntfy.lab.supermorphic.com`) and off-site privately over Tailscale
(`https://ntfy.tail163214.ts.net`). The Tailscale foundation
(`docs/tailscale-single-user-setup.md`) must already be rolled out.

Topics:

| Topic | Purpose | Who writes |
|---|---|---|
| `critical` | Failures needing prompt attention | Alertmanager (PR3) |
| `homelab` | Warnings, degraded state, operator events | Alertmanager (PR3), automation |
| `media` | Seerr availability / request / issue events | Seerr (PR4) |

`subscriber` reads all three (iPhone/web password); each producer is write-only on its topic
with its own rotatable token.

## A. Generate credentials (local, never commit or paste)

Four bcrypt password hashes and three publisher tokens. The service-account passwords are
throwaway (only their hashes are stored); the personal `subscriber` password you keep (entered
on the iPhone).

Bcrypt hash (repeat for subscriber / alertmanager / seerr / automation, using a distinct
password each; the service ones can be random):

```sh
# password -> bcrypt hash
htpasswd -nbBC 10 x 'YOUR-PASSWORD' | cut -d: -f2
```

Publisher token (`tk_` + 29 lowercase alphanumerics = 32 chars; repeat 3x):

```sh
echo "tk_$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 29)"
```

## B. Write the SOPS Secret and validate

```sh
NTFY_SUBSCRIBER_PASSWORD_HASH='$2a$...' \
NTFY_ALERTMANAGER_PASSWORD_HASH='$2a$...' \
NTFY_SEERR_PASSWORD_HASH='$2a$...' \
NTFY_AUTOMATION_PASSWORD_HASH='$2a$...' \
NTFY_ALERTMANAGER_TOKEN='tk_...' \
NTFY_SEERR_TOKEN='tk_...' \
NTFY_AUTOMATION_TOKEN='tk_...' \
NTFY_SECRETS_CONFIRM='write:monitoring:ntfy:sops' \
mise exec -- just repo ntfy-secrets

mise exec -- just ci
```

This writes only the encrypted `kubernetes/apps/monitoring/ntfy/app/secret.sops.yaml`
(`Secret/ntfy-secret`) and stamps its hash into `values.yaml` (`sops-hash`) so a
future rotation rolls the pod. CI stays red until the Secret exists.

## C. Roll out

The app is committed `suspend: true`. After the PR merges:

```sh
NTFY_BOOTSTRAP_CONFIRM='bootstrap:monitoring:ntfy' \
mise exec -- just bootstrap ntfy

mise exec -- just kube ntfy-verify
```

Then flip the ntfy Git source to `suspend: false` (and add the Gatus `/v1/health`
endpoint), commit, push, and re-run `mise exec -- just kube ntfy-verify`.

`ntfy-verify` proves: Flux/HelmRelease Ready, rollout, PVC Bound, gateway `/v1/health`
healthy, anonymous access denied, and least-privilege token ACLs. To also send positive
test notifications, re-run with `NTFY_VERIFY_PUBLISH_CONFIRM=publish:ntfy-verify`.

## D. Configure the iPhone

1. Install **ntfy** from the App Store; allow notifications.
2. Add the self-hosted server — **exactly** the canonical Tailscale URL (it must match
   ntfy's `base-url` for iOS APNs wake-up):

   ```text
   https://ntfy.tail163214.ts.net
   ```

3. Add username `subscriber` and its password to that server entry.
4. Subscribe to `critical`, `homelab`, `media` (name them Homelab Critical / Homelab /
   Media if you like).
5. Keep Tailscale connected (VPN On Demand); ntfy is only reachable over the tailnet or
   LAN, never the public internet.

Test order: phone unlocked on Wi-Fi → locked on Wi-Fi → locked on cellular with Tailscale
connected. Tapping a notification opens ntfy and shows the full message.

## E. Web / CLI (optional)

- Web: open `https://ntfy.lab.supermorphic.com` (LAN) or the Tailscale URL, log in as
  `subscriber`, subscribe to the three topics.
- CLI: a checked-in `client.yml` template with `default-host` + the three topics; put
  `default-user: subscriber` / `default-password` in a local, git-ignored file. Never reuse a
  publisher token in a subscriber client.

## F. Producers (later PRs)

- **Alertmanager (PR3):** `severity=critical` → `critical`, `severity=warning` →
  `homelab`, via the `alertmanager` token.
- **Seerr (PR4):** its ntfy agent → `media` via the `seerr` token (in-cluster Service URL
  `http://ntfy.ntfy.svc.cluster.local`), enabling only Media Available / Request
  Processing Failed / Issue Reported.

Do not add direct `*arr`/qBittorrent/Plex ntfy integrations; use Seerr + Alertmanager.

## G. Troubleshooting and rotation

Missing iPhone notification, in order: can Safari reach the ntfy URL on the current
network (Tailscale up)? Does `/v1/health` return healthy? Correct server + subscribed
topic? Did the producer get HTTP 2xx? Does its token have write access to that topic? Can
ntfy reach `ntfy.sh:443`? iOS notification permissions on?

Rotate one producer token: generate a new `tk_...`, re-run `just repo ntfy-secrets` with
the new value (this re-stamps `sops-hash`), commit, reconcile (ntfy pod recreates),
update the producer, and confirm the old token now returns 403. Rotate subscriber's password
the same way (new bcrypt hash), then update the iPhone/web/CLI clients.

Never disable authentication or open anonymous topics as a troubleshooting shortcut.
