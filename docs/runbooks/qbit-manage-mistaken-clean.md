# Recover a qbit_manage mistaken clean

## Trigger and immediate response

Use this runbook when qbit_manage selects the wrong torrent for cleanup or moves the
wrong download-side data into `/data/downloads/.RecycleBin`. **Act within seven days:**
the recycle entry expires after that window.

Stop qbit_manage from making further cleanup decisions. Keep qBittorrent and its
Gluetun sidecar running so unrelated torrents continue to seed. Keep torrent names,
tracker URLs, passkeys, download history, and raw logs private.

1. Have the operator run the guarded
   [`qbit-manage-contain stop` workflow](../guides/qbit-manage-operations.md#contain-and-resume-qbit_manage).
   It freezes the Flux ownership chain and stops the qbit_manage workload. If it fails,
   treat containment as incomplete and escalate. Do not assume a Flux suspension alone
   stopped the running scheduler.
2. Put `spec.suspend: true` in `kubernetes/apps/media/qbit-manage/ks.yaml` through a
   reviewed Git change. After it merges, have the operator run
   [`qbit-manage-contain finalize`](../guides/qbit-manage-operations.md#contain-and-resume-qbit_manage)
   from the updated clean primary checkout. It checks the exact Flux source revision
   before restoring broad reconciliation. Until it succeeds, the broad Flux freeze
   remains an active incident condition.
3. Privately identify the exact torrent, original download path, and matching recycle
   entry using qBittorrent and local qbit_manage evidence. Confirm the original path
   contains no replacement data.
4. Authorize restoration of **only that entry** to its original path through a reviewed,
   guarded operator workflow. If no suitable workflow exists, add and review one before
   restoring. Do not use a broad filesystem move or an ad hoc Pod shell.
5. If continued seeding is needed, re-add the authorized torrent at its original path
   and category, force a recheck, then start it. Confirm the organized library hardlink
   still plays, the restored torrent can announce when applicable, and unrelated
   torrents were not changed.
6. Identify and correct the classification or cleanup error through Git. Keep the
   qbit_manage Flux child suspended while the corrected policy and intended HelmRelease
   state merge. Use the guarded
   [`bootstrap qbit-manage` workflow](../guides/qbit-manage-operations.md#contain-and-resume-qbit_manage)
   to resume it, then attend the first corrected run. Confirm it selects no unexpected
   cleanup. If bootstrap leaves a running scheduler after failure, invoke containment
   again.

The [operations guide](../guides/qbit-manage-operations.md) owns command usage and
deployment steps. The [policy reference](../reference/qbit-manage.md) owns exact
classification, seeding, cleanup, exclusion, and recycle-retention rules.

## Stop and escalate

Do not restore or resume when:

- the affected torrent and recycle entry cannot be identified unambiguously;
- the original download path already contains replacement data;
- the recycle entry has expired or is missing;
- restoration would require a broad filesystem move;
- a safe correction to the classification or cleanup policy cannot be established; or
- the guarded containment or resume workflow cannot prove its required live state.

An organized library hardlink may survive after the recycle entry expires, but a
seedable download path then needs a separately reviewed recovery decision.
