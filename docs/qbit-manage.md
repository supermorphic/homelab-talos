# qbit_manage — seeding lifecycle policy

`qbit_manage` (StuffAnThings) is a UI-less scheduler in the `media` namespace that applies a
declarative seeding lifecycle to the movie/TV torrents in qBittorrent, so completed public
torrents stop seeding forever instead of accumulating. It talks to qBittorrent's Web API over
the internal Service only — it does **not** join Gluetun's VPN, has no web UI, HTTPRoute, or
Service, and mounts no persistent storage.

- App: `kubernetes/apps/media/qbit-manage/`
- Policy (plaintext, reviewable): `kubernetes/apps/media/qbit-manage/app/config.yml`
- Credential: SOPS Secret `qbit-manage-secret` (keys `QBT_USER`/`QBT_PASS`)
- Full design + staged rollout: `plans/qbit-manage-public-tracker-policy-agent-plan.md`

## Classification model: category-based (read this first)

The policy manages **every torrent in the `tv`/`movies` categories** (the categories
Sonarr/Radarr assign) and **excludes anything tagged `tracker-private`**. Safety therefore
depends on the `tracker-private` list being **complete** — not on withholding a public tag.

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

**Before you download anything from a newly joined private tracker, add its announce hostname
to the `tracker-private` list.** If you don't, its torrents are treated as public and could be
stopped or (once PR4 lands) deleted — a hit-and-run violation on a private tracker.

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

**Two built-in safety nets** make a brief delay non-fatal (but don't rely on them):
- **24h grace:** the policy's `min_seeding_time: 24h` means a freshly downloaded torrent can't
  be ratio-cleaned for its first 24 hours — you have a day to register the host.
- **Reversible until PR4:** through PR3 the limit action is **Stop (pause)**, not delete, and
  cleanup is off. Nothing is irreversible until PR4 (which is itself gated by the hardlink
  proof). A paused torrent is un-paused the moment you add the exclusion.

## Rollout stages

Cleanup is gated behind several reviewed PRs. **Nothing is deleted until PR4.**

| Stage | `config.yml` change | Effect |
|---|---|---|
| PR1 ✅ | `dry_run: true`, all commands off | Inert. Only proves it authenticates. |
| PR2 | `tag_update: true`; `tracker:` (`other → tracker-public`, private → `tracker-private`) | Tags torrents. Dry-run first for a report, then a follow-up applies. No limits. |
| PR3 | `share_limits.public` by category, `exclude_any_tags: [tracker-private]`, `share_limit_action: Stop`, `cleanup: false` | Over-limit tv/movies torrents **pause** (reversible). Private excluded. |
| PR4 | group `cleanup: true`, `skip_cleanup: false`, recyclebin on | Removes eligible torrents + download-side file; `/data/media` hardlink survives. Gated by the hardlink proof. |

Policy target: **min seed 24h, ratio 1.5, max seed 7d.** `tracker-private` torrents are never
touched.

## First-time deployment (operator)

qbit_manage ships **suspended** with an inert **placeholder** credential. Activate it:

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
reconciles and the pod restarts with the safe policy. A download-side file already deleted
cannot be restored, which is why PR4 uses a recycle-bin window and a controlled first cleanup.

## Safety invariants (enforced by `scripts/validate/qbit-manage.sh` in `just ci`)

- Categories `tv`/`movies` are owned by Sonarr/Radarr and never changed (`cat_update: false`).
- qBittorrent's global seeding limits stay disabled.
- The public `share_limits` group must exclude `tracker-private` (the safety gate; enforced
  from PR3). Known-private hosts map to `tracker-private`, never `tracker-public`.
- Destructive features off: unregistered removal, orphaned removal, no-hardlink handling,
  tracker-error deletion.
- Credentials come only from the SOPS Secret via `!ENV`; never inline, never in logs.
- Media-side hardlinks in `/data/media` must be proven to survive cleanup before PR4.
