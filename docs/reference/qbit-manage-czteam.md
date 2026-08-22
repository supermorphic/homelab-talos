# qbit_manage — CZTeam private-tracker policy

CZTeam is the first private tracker with a dedicated qbit_manage share-limit
policy. This document owns the tracker-specific rule snapshot, policy semantics,
first-real-torrent acceptance, and rollback. The shared classification,
deployment, public policy, and operating workflow remain in
[`qbit-manage.md`](qbit-manage.md).

## Tracker rules

The CZTeam rules were last reviewed on 2026-07-26:

- maintain an overall account ratio of at least 0.5;
- seed every completed torrent for at least 72 hours;
- downloading more than 50% starts a ten-day H&R window, cleared by personal
  ratio 1.0 or 72 hours of seed time;
- five active H&Rs cause a warning and ten can disable the account;
- 144 total seed hours can clear an H&R without spending bonus points;
- statistics normally update every 30–45 minutes;
- connectability and port forwarding are encouraged; and
- stock qBittorrent is allowed. The allow-list included the deployed
  qBittorrent `5.2.3` when reviewed.

Re-check the current rules and exact client version before changing this policy
or upgrading qBittorrent:

- <https://czteam.me/rules.php>
- <https://czteam.me/faq.php>
- <https://czteam.me/clients.php>

## Classification and effective policy

The verified bare announce hostname maps to both `tracker-private` and
`tracker-czteam`. The generic tag excludes it from public cleanup, while the
specific tag selects the higher-priority `czteam` group.

Never commit or report a full announce URL, passkey, torrent name, tracker
credential, cookie, or unsanitized log.

| Setting | Value | Purpose |
|---|---:|---|
| Tag selector | `tracker-czteam` | Select only positively identified CZTeam torrents |
| Priority | `10` | Wins over public priority `100` |
| Minimum seed time | `7d` | Exceeds the tracker's 72-hour requirement |
| Maximum ratio | `2.0` | Stops only after minimum time and ratio are both satisfied |
| Maximum seed time | `-1` | No time cutoff while ratio remains below 2.0 |
| Limit action | `Stop` | Reversible pause; never removes the torrent |
| Cleanup | `false` | Never moves or deletes CZTeam data |

`max_ratio: 2.0` is a **per-torrent qBittorrent goal**, not CZTeam's overall
account ratio. qbit_manage's `min_seeding_time` requires a positive
`max_ratio`; before seven days it clears the effective ratio stop and resumes
the torrent. Local seed time is not proof that CZTeam credited every announce,
so continue checking the account and H&R pages.

qBittorrent's own global ratio/seed-time limits must remain disabled or looser
than this policy. An independent global limit could stop a torrent before the
CZTeam obligation is met.

### Priority domains are independent

The CZTeam indexer's priority in Prowlarr is unrelated to the `priority: 10`
above. Prowlarr syncs its indexer priority into Sonarr/Radarr, where it is used
to prefer one indexer in release tie-breaker situations. qbit_manage runs only
after a torrent has reached qBittorrent; its group priority chooses one matching
seeding policy for that torrent.

Both systems use lower numbers as higher priority, but the numbers are never
compared or copied between them. Moving CZTeam below public indexers in
Prowlarr may reduce how often it wins an otherwise-equal release choice; it
does not weaken the CZTeam seeding policy when a CZTeam torrent is selected.
Do not rely on Prowlarr priority as an H&R safety control.

## First real torrent acceptance

Complete these checks with the first current CZTeam torrent after a policy or
tracker configuration change:

1. Confirm it receives both `tracker-private` and `tracker-czteam` after the
   next qbit_manage run.
2. Confirm it selects the `czteam` share-limit group and never `public`.
3. Confirm its Sonarr/Radarr category remains unchanged.
4. Confirm it cannot stop at ratio 2.0 before seven days.
5. Confirm a torrent below ratio 2.0 has no finite time cutoff.
6. Confirm no CZTeam torrent enters cleanup or `.RecycleBin`.
7. After at least one announce interval, confirm CZTeam credits seeding and
   reports no H&R.

Run the guarded workload checks:

```bash
mise exec -- just kube qbit-manage-verify
mise exec -- just test smoke media qbit-manage
```

Use the qBittorrent UI and locally inspected qbit_manage logs for
torrent-specific checks. Never paste torrent names, complete tracker URLs, or
passkeys into chat, tickets, commits, or test evidence.

## Rollback

Rollback the policy, never its protection:

1. Keep the verified hostname mapping and both `tracker-private` /
   `tracker-czteam` public exclusions.
2. Return only the `czteam` group to no-limit/no-cleanup behavior, or remove
   that group through GitOps.
3. Inspect CZTeam torrents for persisted per-torrent limits, clear those limits
   deliberately, and resume any stopped torrent.
4. Verify the tracker reports seeding after an announce interval.

Never:

- fall back to the public policy;
- remove either private tag while CZTeam torrents exist;
- enable `cleanup`, `Remove`, or `RemoveWithContent`;
- add a finite maximum seed time;
- mass-reset unrelated public limits; or
- stop qBittorrent/Gluetun as part of policy rollback.

Changing the qbit_manage Kustomization's `spec.suspend` stops reconciliation, not the
running policy Deployment. If policy execution must stop, use the
[recovery runbook's workload-stop procedure](../runbooks/recovery.md#recover-a-qbit_manage-mistaken-clean).
That procedure keeps qBittorrent running so it can continue seeding.
