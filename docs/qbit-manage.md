# qbit_manage — public-tracker seeding policy

`qbit_manage` (StuffAnThings) is a UI-less scheduler in the `media` namespace that applies a
declarative seeding lifecycle to **known public** torrents in qBittorrent, so completed
public movie/TV torrents stop seeding forever. It talks to qBittorrent's Web API over the
internal Service only — it does **not** join Gluetun's VPN, has no web UI, HTTPRoute, or
Service, and mounts no persistent storage.

- App: `kubernetes/apps/media/qbit-manage/`
- Policy (plaintext, reviewable): `kubernetes/apps/media/qbit-manage/app/config.yml`
- Credential: SOPS Secret `qbit-manage-secret` (keys `QBT_USER`/`QBT_PASS`)
- Full design + staged rollout: `plans/qbit-manage-public-tracker-policy-agent-plan.md`

## Rollout stages

Cleanup is deliberately gated behind several reviewed PRs. **Nothing is deleted until PR4.**

| Stage | `config.yml` change | Effect |
|---|---|---|
| PR1 (this) | `dry_run: true`, all commands off, `skip_cleanup: true` | Inert. Only proves it authenticates. |
| PR2 | add `tracker:` (confirmed public hosts), `tag_update: true` | Tags known-public torrents `tracker-public`. |
| PR3 | add `share_limits.public`, `share_limits: true` | Applies ratio 1.5 / 24h min / 7d max. `cleanup: false`. |
| PR4 | group `cleanup: true`, `skip_cleanup: false`, recyclebin on | Removes eligible public torrents + download-side file. |

The policy target for known public torrents: **min seed 24h, ratio 1.5, max seed 7d**, then
cleanup. Unknown and (future) private trackers get **no** automated cleanup.

## First-time deployment (operator)

qbit_manage ships **suspended** with an inert **placeholder** credential. Activate it:

1. **Create the real credential** (the same permanent qBittorrent WebUI username/password
   Sonarr/Radarr use; source of truth is the password manager). This overwrites the
   committed placeholder Secret without printing either value:

   ```bash
   printf 'qBittorrent WebUI username: '
   IFS= read -r QBITTORRENT_USERNAME
   printf 'qBittorrent WebUI password: '
   IFS= read -r -s QBITTORRENT_PASSWORD
   printf '\n'
   export QBITTORRENT_USERNAME QBITTORRENT_PASSWORD
   export QBIT_MANAGE_SECRETS_CONFIRM='write:media:qbit-manage-secret:sops'
   mise exec -- just repo qbit-manage-secrets
   unset QBITTORRENT_USERNAME QBITTORRENT_PASSWORD QBIT_MANAGE_SECRETS_CONFIRM
   ```

   Commit the updated `qbit-manage-secret.sops.yaml`.

2. **Bootstrap** (guarded; resumes, reconciles, verifies, then re-suspends on failure):

   ```bash
   export QBIT_MANAGE_BOOTSTRAP_CONFIRM='bootstrap:media:qbit-manage'
   mise exec -- just bootstrap qbit-manage
   unset QBIT_MANAGE_BOOTSTRAP_CONFIRM
   ```

3. When it reports success, set `suspend: false` in `kubernetes/apps/media/qbit-manage/ks.yaml`,
   commit, push, and re-run `mise exec -- just kube qbit-manage-verify`.

## Operating

**Run a dry-run / inspect classifications.** In PR1–PR2 `config.yml` has `dry_run: true`, so
every scheduled run is already a no-op report. Read the last run:

```bash
mise exec -- kubectl -n media logs deployment/qbit-manage --tail=200
```

Do not paste log lines containing tracker URLs or torrent names into chat/tickets.

**Verify (read-only live acceptance):**

```bash
mise exec -- just kube qbit-manage-verify
```

**Pause qbit_manage without touching qBittorrent.** Suspending the Flux Kustomization stops
qbit_manage from running; qBittorrent, Sonarr, and Radarr keep working:

```bash
mise exec -- flux suspend kustomization qbit-manage -n flux-system
```

Durable pause: set `suspend: true` in `ks.yaml`, commit, push.

**Disable cleanup quickly through GitOps.** The primary control is the per-group
`share_limits.public.cleanup` flag (and the global `commands.skip_cleanup`). Set
`cleanup: false` (and/or `skip_cleanup: true`) in `config.yml`, commit, push — Flux reconciles
and the pod restarts with the safe policy. This is the rollback path (see the plan's Rollback
section). A download-side file already hard-deleted cannot be restored — that is why PR4 uses
a recycle-bin safety window and a controlled first cleanup.

**Add a newly confirmed public tracker (PR2+).** Add its **announce hostname** (confirmed
from a real torrent's tracker URL, not just the Prowlarr display name) to the `tracker:`
mapping in `config.yml`, under the existing `tracker-public` tag key (pipe-delimited). Never
add an `other:` catch-all, and never add a private tracker's hostname. Commit and push; Flux
reconciles.

## Why unknown trackers seed indefinitely (by design)

A torrent becomes eligible for the public policy **only** when its announce hostname
positively matches an explicitly configured known-public tracker. An unrecognized tracker is
**unknown**, not public: `tag_update` may give it an automatic per-domain tag, but it never
receives `tracker-public` and never enters any share-limit or cleanup group. This protects
current downloads and any future private tracker from a premature stop/delete (which on a
private tracker would be a hit-and-run violation). Private-tracker policy is a **separate**
plan and must not inherit the public 24h/1.5/7d rule.

## Safety invariants (must always hold)

- Categories `tv`/`movies` are owned by Sonarr/Radarr and never changed (`cat_update: false`).
- qBittorrent's global seeding limits stay disabled.
- No unknown-tracker catch-all (`tracker.other` is never defined).
- Destructive features off: unregistered removal, orphaned removal, no-hardlink handling,
  tracker-error deletion.
- Credentials come only from the SOPS Secret via `!ENV`; never inline, never in logs.
- Media-side hardlinks in `/data/media` must be proven to survive cleanup before PR4.

The offline validator `scripts/validate/qbit-manage.sh` (in `just ci`) enforces these.
