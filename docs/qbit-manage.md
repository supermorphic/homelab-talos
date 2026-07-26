# qbit_manage — seeding lifecycle policy

`qbit_manage` (StuffAnThings) is a UI-less scheduler in the `media` namespace that applies a
declarative seeding lifecycle to the movie/TV torrents in qBittorrent, so completed public
torrents stop seeding forever instead of accumulating. It talks to qBittorrent's Web API over
the internal Service only — it does **not** join Gluetun's VPN, has no web UI, HTTPRoute, or
Service. It mounts only the shared `/data/downloads` subpath and can never reach
`/data/media`.

- App: `kubernetes/apps/media/qbit-manage/`
- Policy (plaintext, reviewable): `kubernetes/apps/media/qbit-manage/app/config.yml`
- Credential: SOPS Secret `qbit-manage-secret` (keys `QBT_USER`/`QBT_PASS`)
- Full design + staged rollout: `plans/qbit-manage-public-tracker-policy-agent-plan.md`

## Classification model: category-based (read this first)

The policy manages **every torrent in the `tv`/`movies` categories** (the categories
Sonarr/Radarr assign) and **excludes anything tagged `tracker-private`**. Two independent layers
apply that tag: a generic `settings.private_tag` net that auto-tags **every** private torrent,
plus optional per-host mappings under `tracker:`. The generic net means a private torrent is
excluded even from a tracker you have not mapped yet — basic safety no longer depends on the
per-host list being complete.

**Classified today:** `tracker.czteam.me` → `tracker-private` + `tracker-czteam` (a private
tracker), excluded from the public policy via both tags. It has a dedicated `czteam` share-limit
group (priority 10, above public's 100): seed **at least 7 days**, then stop only once ratio
**2.0** is also reached; below 2.0 it seeds indefinitely (`max_seeding_time: -1`).
`share_limit_action: Stop` pauses (reversible); `cleanup: false` never deletes. **Currently in
global dry-run** (Phase 2) — qbit_manage *reports* these actions but mutates nothing (this also
pauses public cleanup for the window) until Phase 3 flips `dry_run: false`. Local seed time is
not proof CZTeam credited the seed — still check the account/H&R pages. The mapping key is the
bare announce host only, never a passkey or full announce URL.

Why this instead of an allow-list of public trackers? Public torrents announce to a shifting,
flaky set of open trackers that changes with every batch of downloads — an allow-list of those
would need constant upkeep, and any host you missed would silently seed forever. Private
trackers, by contrast, are **few and stable**: you maintain that small list instead. The trade
is that the private list is **safety-critical** (see below).

```text
torrent in tv/movies category
        │
        ├─ tagged tracker-private ─────────► EXCLUDED (no limits, no cleanup, seeds per your rules)
        │
        └─ not tracker-private ────────────► public policy: 24h min seed, ratio 1.5, 7d max
```

## ⚠️ SAFETY-CRITICAL: adding a private tracker

**A private torrent is auto-excluded from the public policy by the `settings.private_tag` net
as soon as qbit_manage next runs** — you no longer have to register the announce host first just
to avoid a hit-and-run (public cleanup is now active, so this generic protection matters). You
still add a tracker's announce hostname when it needs a **tracker-specific tag or its own
share-limit group** (e.g. the CZTeam policy); land that mapping before relying on those bespoke
rules.

**Is this a file edit or a command?** A **file edit that goes through a PR** — there is no
`just` recipe for it, on purpose: this is the one safety-critical change in the system, so the
PR review is a deliberate checkpoint. In this repo's workflow you hand the announce host to the
maintainer (or edit it yourself) and it lands as a reviewed one-line PR.

**Steps:**

1. Find the tracker's **announce hostname** in qBittorrent: click a torrent from that tracker →
   **Trackers** tab → copy just the **host** of the tracker that carries your passkey (e.g.
   `tracker.your-private-site.org`). Do **not** copy the full URL — it contains your passkey.
2. Add it to `kubernetes/apps/media/qbit-manage/app/config.yml` under the `tracker:` section,
   above the `other:` catch-all, mapped to `tracker-private` (pipe-delimit multiple hosts):

   ```yaml
   tracker:
     "tracker.your-private-site.org|announce.another-private.org":
       tag: tracker-private
     other:
       tag: tracker-public
   ```
3. Open a PR, let `just ci` pass, and merge. Flux reconciles and qbit_manage re-tags on its
   next run; the public `share_limits` group excludes `tracker-private`.

**Layered safety nets** make a brief delay before registering a host non-fatal:
- **Generic `private_tag` (primary):** qbit_manage tags every private torrent `tracker-private`
  on its next run and the public group excludes that tag, so a private torrent is kept out of
  the public ratio/stop/cleanup path automatically — no host registration required.
- **24h grace:** the public policy's `min_seeding_time: 1d` means a freshly downloaded torrent
  cannot be ratio-cleaned for its first 24 hours.
- **7-day recycle window:** cleanup moves download-side data into `.RecycleBin` before its name
  is unlinked, and the `/data/media` Plex hardlink survives regardless.

## Rollout stages (all shipped)

The lifecycle was rolled out across reviewed PRs; the full policy is now live.

| Stage | `config.yml` change | Effect |
|---|---|---|
| PR1 ✅ | `dry_run: true`, all commands off | Inert. Only proves it authenticates. |
| PR2 ✅ | `tag_update: true`; `tracker:` (`other → tracker-public`, private → `tracker-private`) | Tags torrents. |
| PR3 ✅ | `share_limits.public` by category, `exclude_any_tags: [tracker-private]`, `share_limit_action: Stop`, `cleanup: false` | Over-limit tv/movies torrents **pause** (reversible). Private excluded. |
| PR4 ✅ | group `cleanup: true`, `skip_cleanup: false`, recyclebin on (7d) | Removes eligible torrents; download-side data → `/data/downloads/.RecycleBin` (recoverable 7d); `/data/media` hardlink survives. |

Hardlink-survival proof (the PR4 gate) was passed on real imports: a Radarr movie
(inode 934) and a Sonarr episode (inode 952), each with `links=2` and identical
download/library inodes — so removing the download-side name provably leaves the Plex
library file intact.

Policy target: **min seed 24h, ratio 1.5, max seed 7d.** `tracker-private` torrents are never
touched.

## First-time deployment (operator)

The current cluster is already active. For a fresh-cluster deployment or credential rebuild,
activate it with the guarded workflow:

1. **Create the real credential** (the same permanent qBittorrent WebUI username/password
   Sonarr/Radarr use; source of truth is the password manager). Overwrites the placeholder
   Secret without printing either value:

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

   Then commit the updated `qbit-manage-secret.sops.yaml` (via PR).

2. **Bootstrap** (guarded; resumes, reconciles, verifies, re-suspends on failure):

   ```bash
   export QBIT_MANAGE_BOOTSTRAP_CONFIRM='bootstrap:media:qbit-manage'
   mise exec -- just bootstrap qbit-manage
   unset QBIT_MANAGE_BOOTSTRAP_CONFIRM
   ```

3. On success, set `suspend: false` in `kubernetes/apps/media/qbit-manage/ks.yaml` (via PR) and
   re-run `mise exec -- just kube qbit-manage-verify`.

## Operating

**Inspect the last run / classification report:**

```bash
mise exec -- kubectl --kubeconfig .kube/config -n media logs deployment/qbit-manage --tail=200
```

Do not paste log lines containing tracker URLs or torrent names into chat/tickets.

**Verify (read-only live acceptance):**

```bash
mise exec -- just kube qbit-manage-verify
```

**Pause qbit_manage without touching qBittorrent** (qBittorrent/Sonarr/Radarr keep working):

```bash
mise exec -- flux suspend kustomization qbit-manage -n flux-system
```

Durable pause: set `suspend: true` in `ks.yaml` via PR.

**Disable limits/cleanup quickly through GitOps.** The controls, in `config.yml`: the per-group
`share_limits.public.cleanup` flag (deletion), the global `commands.skip_cleanup` (recyclebin
pass), and `commands.share_limits` (limits entirely). Set the safe value, open a PR — Flux
reconciles and the pod rolls with the safe policy (the `config-hash` annotation auto-rolls it).

**Recover a mistakenly-cleaned torrent (within 7 days).** Cleanup *moves* download-side data to
`/data/downloads/.RecycleBin`; it is only unlinked after `recyclebin.empty_after_x_days` (7).
The `/data/media` Plex file is a hardlink and is unaffected regardless. To recover the
download-side within the window, move it back out of `.RecycleBin` (from a pod that mounts
`/data`, e.g. Radarr/Sonarr) and re-add the torrent if you want to resume seeding:

```bash
mise exec -- kubectl --kubeconfig .kube/config -n media exec deploy/radarr -- \
  ls -la /data/downloads/.RecycleBin
```

To make cleanup even safer, raise `recyclebin.empty_after_x_days`. To stop deletion entirely,
set `share_limits.public.cleanup: false` (via PR).

## Safety invariants (enforced by `scripts/validate/qbit-manage.sh` in `just ci`)

- Categories `tv`/`movies` are owned by Sonarr/Radarr and never changed (`cat_update: false`).
- qBittorrent's global seeding limits stay disabled.
- The public `share_limits` group must exclude `tracker-private` (the safety gate).
  Known-private hosts map to `tracker-private`, never `tracker-public`.
- `settings.private_tag` must be `tracker-private` — the generic net that auto-tags every
  private torrent so an unmapped private tracker is still excluded from the public policy.
- Destructive features off: unregistered removal, orphaned removal, no-hardlink handling,
  tracker-error deletion.
- Credentials come only from the SOPS Secret via `!ENV`; never inline, never in logs.
- qbit_manage never mounts `/data/media`; the completed rollout's hardlink proof established
  that cleanup leaves media-side files intact.
