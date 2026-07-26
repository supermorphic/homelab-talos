# qbit_manage Public Tracker Policy — Implementation Agent Plan

## Context

The media stack currently leaves qBittorrent's global seeding limits disabled.
Completed torrents therefore remain loaded and seed indefinitely unless an
operator removes them.

This is safe for future private trackers because no generic qBittorrent rule can
prematurely stop a torrent and create a hit-and-run violation. It is not a
sustainable lifecycle policy for the public movie and TV torrents already being
downloaded.

This plan introduces `qbit_manage` to the framework for the first time. Its
initial scope is deliberately narrow:

- positively identify known public trackers;
- preserve the categories used by Sonarr and Radarr;
- apply a conservative public seeding policy;
- prove imports and hardlinks are safe before deletion;
- remove eligible public torrents and their download-side files; and
- leave private or unknown trackers untouched.

This plan is separate from
`qbit-manage-private-tracker-policy-agent-plan.md`. Do not implement CZTeam or
any other private-tracker policy here.

## Outcome

Known public torrents converge to:

```text
minimum seeding time: 24 hours
target ratio:         1.5
maximum seeding time: 7 days
cleanup:              enabled only after a validated rollout
```

The intended lifecycle is:

```text
qBittorrent completes the download
        |
        v
Sonarr/Radarr imports it as a hardlink into /data/media
        |
        v
qBittorrent continues seeding from /data/downloads
        |
        +-- ratio >= 1.5 and seed time >= 24h --> cleanup eligible
        |
        `-- ratio still below 1.5 at 7d --------> cleanup eligible
                                                      |
                                                      v
                                      torrent/download link removed
                                      media hardlink remains for Plex
```

The agent must validate the exact `qbit_manage` share-limit behavior and syntax
against the pinned release. Do not assume the conceptual fields below form an
arbitrary Boolean expression.

## Non-negotiable safety invariants

1. A torrent is eligible for the public policy only after it positively matches
   an explicitly configured known-public tracker.
2. An unrecognized tracker is **unknown**, not public.
3. Unknown and future private trackers receive no automated cleanup from this
   plan.
4. Sonarr and Radarr categories remain unchanged.
5. qBittorrent's global seeding limits remain disabled.
6. Cleanup remains disabled until tracker classification, completed-download
   imports, and hardlinks have all been validated.
7. A cleanup test must prove the media-side file survives before cleanup becomes
   normal behavior.
8. Destructive features unrelated to this policy remain disabled.
9. Secrets never appear in rendered manifests, logs, command output, or test
   artifacts.
10. All images and tools are pinned according to repository policy; do not use
    mutable tags.

## Scope

### In scope

- Deploy one `qbit_manage` instance in the `media` namespace.
- Connect it to the existing qBittorrent Web API over the internal service.
- Store qBittorrent credentials in the repository's existing SOPS workflow.
- Keep policy configuration declarative and reviewable in Git.
- Classify the public trackers currently configured through Prowlarr.
- Add a public-tracker tag without changing torrent categories.
- Apply ratio and seeding-time limits only to known public torrents in the
  Sonarr/Radarr movie and TV categories.
- Start with dry-run and no-cleanup operation.
- Validate the current in-flight movie and TV downloads.
- Enable automated cleanup only through an explicit final rollout gate.
- Add static validation, live verification, and operator documentation.

### Out of scope

- CZTeam, TorrentLeech, FileList, or any private-tracker policy.
- Treating every unmatched tracker as public.
- Unregistered-torrent removal.
- Orphaned-data removal.
- Tracker-error-based deletion.
- Category creation, replacement, or migration.
- Cross-seed integration.
- Per-tracker or per-torrent upload throttling.
- Changing qBittorrent's global seeding limits.
- Changing Sonarr/Radarr completed-download handling.
- Changing download or media paths.
- Moving qBittorrent behind a different network path.
- Adding a public HTTP route or UI unless the installed version proves one is
  required for operation.

## Existing architecture that must remain intact

```text
Seerr / Prowlarr
        |
        v
Sonarr / Radarr
        |
        | category: tv or movies
        v
qBittorrent ----> /data/downloads/{tv,movies}/...
        |                           |
        | seeds                     | hardlink import
        |                           v
        |                    /data/media/{tv,movies}/...
        |                           |
        |                           v
        |                          Plex
        |
        `---- qbit_manage controls torrent lifecycle through the Web API
```

qBittorrent does not move completed files into `/data/media`. Sonarr and Radarr
import them. With hardlinks working, the download path and library path are two
names for the same underlying file data.

Removing the torrent and its download-side path after policy satisfaction must
not remove the library-side hardlink.

## Required discovery before implementation

Inspect the repository rather than inventing paths or conventions. Record the
relevant findings in the implementation summary.

1. Read all applicable `AGENTS.md` files.
2. Locate the existing media namespace, Flux Kustomizations, app layout, and
   `bjw-s/app-template` conventions.
3. Inspect the qBittorrent deployment, service name/port, credentials source,
   categories, storage mounts, probes, resource policy, and network policy.
4. Inspect Sonarr and Radarr for:
   - download categories;
   - completed-download handling;
   - `/data` mount layout;
   - hardlink setting; and
   - root folders.
5. Inspect repository patterns for:
   - SOPS secrets;
   - app validation;
   - live verification;
   - Chainsaw smoke tests;
   - Gatus or Prometheus coverage;
   - documentation;
   - Renovate image annotations; and
   - `just` recipes.
6. Resolve the current public tracker hostnames from the actual Prowlarr
   configuration or operator-provided inventory. Do not guess tracker URL
   keywords.
7. Verify the current maintained `qbit_manage` image, supported configuration
   schema, scheduler behavior, dry-run command, health behavior, and
   share-limit semantics from primary project documentation.
8. Pin a specific release and image digest if that is the repository standard.
9. Confirm whether the selected release runs safely as a long-lived scheduled
   workload or whether the repository should use a CronJob. Prefer the project's
   supported scheduler unless repository conventions or operational evidence
   favor a CronJob.
10. Verify whether `min_seeding_time` and `max_seeding_time` units are seconds,
    minutes, or duration strings in the selected version.
11. Verify precisely what `cleanup: true` deletes and how it handles hardlinks
    and files shared by multiple torrents.

Stop and report a blocker if the public trackers cannot be positively and
unambiguously identified.

## Policy design

### Classification

Use tracker-specific matching to add a public classification tag:

```text
known public tracker  -> tracker-public
unknown tracker       -> no public tag and no cleanup
future private tracker -> dedicated private tag/policy in a separate plan
```

Do not configure a catch-all such as `other: public`.

The initial known-public inventory should be derived from the indexers actually
enabled in Prowlarr. Expected candidates may include 1337x, EZTV, YTS,
BitSearch, LimeTorrents, Nyaa, or showRSS, but only trackers confirmed by their
real announce URLs may be included.

Indexer names and announce tracker hostnames are not always identical. Match
the announce URL observed on torrents, not merely the Prowlarr display name.

### Categories and tags

Preserve the category assigned by the download client integration:

```text
Radarr torrent
  category: movies
  tag:      tracker-public

Sonarr torrent
  category: tv
  tag:      tracker-public
```

Do not use qbit_manage category-changing features in this rollout. The
implementation must confirm the repository's real category values before
configuring filters.

### Share limits

Express this policy using the exact syntax supported by the pinned release:

```yaml
share_limits:
  public:
    # Exact keys and units must be verified before implementation.
    priority: 100
    include_all_tags:
      - tracker-public
    categories:
      - movies
      - tv
    max_ratio: 1.5
    min_seeding_time: 1d
    max_seeding_time: 7d
    cleanup: false
```

The intended behavior is:

- never clean up before 24 hours merely because ratio 1.5 was reached;
- clean up after both the ratio target and minimum seed time are satisfied;
- clean up at seven days even if demand was too low to reach ratio 1.5; and
- never apply the policy to an unknown tracker.

If the pinned release cannot implement that behavior exactly, stop and document
the actual semantics and safest alternative. Do not silently approximate it.

### Bandwidth ownership

This plan controls how long torrents remain eligible to seed. It does not set
the household upload budget.

Keep global upload bandwidth management in qBittorrent. Do not add qbit_manage
per-torrent or per-group upload limits in this first deployment.

## Configuration and secret design

Use the repository's established patterns. The conceptual configuration is:

```yaml
qbt:
  host: http://qbittorrent.media.svc.cluster.local:<verified-port>
  user: !ENV QBT_USER
  pass: !ENV QBT_PASS
```

Requirements:

- policy YAML is plaintext and reviewable in Git;
- credentials come from a SOPS-encrypted Secret;
- the live Pod receives credentials through secret-backed environment
  variables or the repository's established equivalent;
- the internal qBittorrent service is used;
- qbit_manage does not join the Gluetun network namespace;
- no ingress or HTTPRoute is created by default;
- one replica runs at a time;
- scheduling is approximately every 15 minutes;
- a failed qBittorrent connection is visible through workload state or logs;
- resource requests and limits follow existing media-app conventions; and
- configuration persistence is limited to what the pinned application actually
  requires.

Do not duplicate credentials if an existing secret can be safely and
declaratively shared under repository conventions. Do not weaken secret
ownership merely to avoid duplication.

## Destructive features to keep disabled

Use the exact option names from the pinned release, but preserve these outcomes:

```text
remove unregistered torrents: off
remove orphaned data:          off
remove unlinked/no-hardlink:   off
category update/change:        off
directory cleanup:             off
tracker-error deletion:        off
unknown-tracker cleanup:       impossible
```

Only tracker classification and share limits are enabled.

## Delivery sequence

Ship the work as small, reviewable stages. Each stage must pass repository CI
and its own validation before the next stage begins.

### PR 1 — Application foundation

Deploy `qbit_manage` inertly:

- pinned workload and image;
- internal qBittorrent API connection;
- SOPS-managed credentials;
- declarative configuration;
- one replica;
- scheduler or CronJob as proven appropriate;
- resource configuration;
- no public route;
- no category changes;
- all deletion/cleanup behavior disabled; and
- Flux wiring and dependency ordering consistent with the media namespace.

Acceptance:

- manifests render and validate;
- the workload becomes Ready or scheduled runs succeed;
- it authenticates to qBittorrent;
- no torrent fields or files change;
- no secret value is exposed; and
- disabling or removing qbit_manage leaves qBittorrent functioning normally.

### PR 2 — Known-public classification

Add explicit mappings for the public tracker announce URLs confirmed during
discovery.

First run in the pinned release's supported dry-run mode. Capture a sanitized
classification report containing:

```text
torrent name or safe identifier
existing category
tracker hostname
proposed public tag
matched rule
```

Review every currently loaded torrent. No unmatched torrent may receive the
public tag.

Then allow normal tagging while cleanup remains disabled.

Acceptance:

- every expected public torrent receives `tracker-public`;
- no unknown torrent receives it;
- `tv` and `movies` categories are unchanged;
- Sonarr/Radarr still recognize their downloads; and
- repeated runs are idempotent.

### PR 3 — Public share limits with cleanup disabled

Add the validated equivalent of:

```text
ratio target:         1.5
minimum seeding time: 24h
maximum seeding time: 7d
cleanup:              false
```

Use current public movie and TV torrents as real observations.

Acceptance:

- only `tracker-public` torrents in the expected categories match;
- qBittorrent shows the intended limits or qbit_manage reports the intended
  evaluation;
- unknown torrents retain unlimited/no-cleanup behavior;
- downloads, seeding, and completed-download imports continue normally; and
- no torrent or file is removed.

Allow this phase to operate long enough to observe multiple completed downloads
and at least one restart/reconciliation cycle.

### PR 4 — Controlled cleanup activation

Do not begin until the hardlink gate below has passed.

Change only the cleanup activation necessary for the known-public share-limit
group. Use one imported public torrent as the controlled first cleanup case.

Before activation, record:

- qBittorrent torrent and category;
- matched tracker hostname;
- ratio and seeding time;
- download-side path;
- Sonarr/Radarr import event;
- library-side path; and
- hardlink evidence.

After cleanup, verify:

- the torrent is removed from qBittorrent;
- the download-side entry is removed as intended;
- the library-side file still exists;
- Sonarr/Radarr still record the imported media;
- Plex can still see/play or analyze the item;
- no sibling files or unrelated torrents were removed; and
- a subsequent qbit_manage run is idempotent.

Only after this controlled proof may cleanup remain enabled for all positively
classified public torrents.

## Hardlink safety gate

Automated cleanup is blocked until a completed Radarr movie and a completed
Sonarr episode prove the storage design.

Expected paths:

```text
/data/downloads/movies/<release>/<source-file>
/data/media/movies/<Movie Title> (<Year>)/<library-file>

/data/downloads/tv/<release>/<source-file>
/data/media/tv/<Series Title> (<Year>)/Season <NN>/<library-file>
```

From a Pod that sees the same mounted `/data` filesystem, compare a
filesystem-appropriate file identity and link count. On a normal Unix
filesystem this may use device/inode and link count. On SMB, inode reporting can
depend on the server and mount options, so supplement identity checks with
allocated-space or NAS-side evidence if needed.

Required conclusion:

> The import is a hardlink on the same backing filesystem, not a second full
> copy and not a move.

If this cannot be proven, leave `cleanup: false`. Do not proceed based only on
the Sonarr/Radarr checkbox being enabled.

## Baseline inventory

Before the first mutating run, capture the current qBittorrent population:

| Field | Purpose |
|---|---|
| Torrent name or safe identifier | Correlate before/after state |
| Category | Prove Sonarr/Radarr ownership is preserved |
| Tracker hostname | Validate positive classification |
| State | Distinguish downloading, completed, paused, and seeding |
| Ratio | Determine policy position |
| Seeding time | Determine policy position |
| Download path | Verify cleanup scope |
| Import status | Ensure Sonarr/Radarr completed handling occurred |
| Library path | Verify surviving media |
| Classification | Known public or unknown |

Do not store tracker passkeys, complete announce URLs containing secrets, API
credentials, or other secret-bearing query parameters in artifacts.

## Validation and testing

Follow the repository's established testing framework and naming conventions.
Do not invent a parallel framework.

### Offline validation

Add or extend policy checks that prove:

- the image is pinned;
- credentials come from a Secret;
- no public HTTPRoute exists;
- the workload has one active replica;
- the public group requires the `tracker-public` tag;
- no catch-all/`other` rule maps unknown trackers to public;
- expected Sonarr/Radarr category filters are present;
- destructive non-share-limit features are disabled;
- cleanup is false during rollout stages;
- no private tracker hostname appears in the public mapping; and
- Flux dependencies and media tags follow repository policy.

Add positive and negative tests for the high-value semantic invariants rather
than relying only on snapshots.

### Live smoke coverage

Add read-only live assertions for:

- Flux Kustomization Ready;
- workload Ready or most recent scheduled run succeeded;
- configuration mounted;
- qBittorrent service reachable from qbit_manage;
- authentication succeeds without printing credentials;
- scheduler/interval is active; and
- recent logs contain no configuration parse or authentication failures.

### Policy verification

Provide an operator-run verification command through the repository's guarded
`just` interface. It should:

1. inventory loaded torrents without secret-bearing tracker URLs;
2. report public versus unknown classification;
3. prove categories are unchanged;
4. show the matching share-limit group;
5. show whether cleanup is enabled;
6. fail if any unknown torrent is cleanup-eligible; and
7. save sanitized evidence according to the testing framework.

### End-to-end cleanup proof

Use legal, controlled content or an already authorized public torrent. Do not
wait seven days in an automated test. If the application supports a safe test
policy, use a temporary narrowly matched fixture and restore production policy
afterward. Otherwise perform the cleanup as an explicit operator-run acceptance
step.

The test must prove:

```text
public classification
  -> completed download
  -> Sonarr/Radarr import
  -> hardlink proof
  -> cleanup eligibility
  -> torrent/download-side removal
  -> library-side survival
  -> Plex and *arr health
```

Cleanup traps must restore any temporary policy even when the test fails or is
interrupted.

## Observability and operations

At minimum, make these conditions visible:

- qbit_manage cannot reach or authenticate to qBittorrent;
- configuration parsing fails;
- a run fails;
- a loaded torrent remains unknown;
- a torrent matches more than one policy unexpectedly; and
- cleanup removes a torrent.

Avoid high-cardinality metrics containing torrent names or full tracker URLs.
Logs must redact credentials, passkeys, and secret query parameters.

Document:

- how to run a dry-run;
- how to inspect classifications;
- how to pause qbit_manage without stopping qBittorrent;
- how to disable cleanup quickly through GitOps;
- how to run the verification command;
- how to inspect the last run;
- how to add a newly confirmed public tracker; and
- why unknown trackers intentionally seed indefinitely.

Do not add noisy notifications in this phase. Integrate with the future
homelab-wide ntfy strategy when that framework exists.

## Rollback

Rollback must be simple and non-destructive:

1. set public share-limit cleanup to false;
2. suspend or scale down qbit_manage using the repository's supported GitOps
   method;
3. leave qBittorrent, Sonarr, Radarr, and their categories unchanged; and
4. preserve logs and sanitized evidence from the failed run.

Rollback cannot restore a download-side path already deleted. That is why the
controlled cleanup and hardlink gates are mandatory.

## Future private-tracker compatibility

This plan must leave a clean extension point:

```text
known private tracker
  -> dedicated tracker-private-<name> tag
  -> higher-priority tracker-specific share-limit group

known public tracker
  -> tracker-public tag
  -> public share-limit group

unknown tracker
  -> no cleanup group
```

Private tracker work must verify tracker rules independently and must never
inherit the public 24-hour/1.5/7-day policy.

Do not implement private policy as part of this plan merely because the
configuration supports it.

## Definition of done

This plan is complete only when:

- `qbit_manage` is deployed and managed through Flux;
- its image and required tooling are pinned;
- qBittorrent credentials are SOPS-managed;
- it connects only through the internal qBittorrent service;
- no public route is created;
- currently enabled public trackers are explicitly mapped from verified announce
  hostnames;
- known public torrents receive `tracker-public`;
- unknown torrents cannot match the public policy;
- Sonarr and Radarr categories remain unchanged;
- qBittorrent global seeding limits remain disabled;
- the effective public policy is 24-hour minimum, ratio 1.5 target, and
  seven-day maximum;
- unrelated destructive features remain disabled;
- movie and TV hardlinks are proven before cleanup;
- a controlled cleanup removes only the torrent/download-side entry;
- the media hardlink survives and Plex remains healthy;
- offline validation and live smoke coverage pass;
- the operator guide documents dry-run, verification, activation, rollback, and
  adding known public trackers;
- the final implementation report identifies any live tests the operator still
  must run; and
- the separate private-tracker plan remains unmodified.

## Agent execution rules

- Work on a feature branch/worktree and do not switch to `main`.
- Inspect before editing and preserve unrelated user changes.
- Use the repository's existing file layout, tooling, and public `just`
  interfaces.
- Keep commits and PRs aligned with the staged delivery sequence.
- Do not combine initial deployment and cleanup activation into one unreviewed
  change.
- Run all relevant offline validation after each stage.
- Treat live-cluster commands and cleanup as explicit operator-run gates unless
  the user has separately authorized execution.
- Never decrypt or print secrets during validation.
- Report exact commands run, results, skipped live checks, remaining risks, and
  the cleanup activation state in the final handoff.
