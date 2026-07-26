# CZTeam Private-Tracker Policy — Implementation Agent Plan

## Context

This plan is a narrow extension of the qbit_manage public-torrent lifecycle that is
already deployed. It replaces the older pre-deployment plan, whose application,
secret, storage, networking, architecture-selection, and public-policy phases have
all been completed.

Current repository state on 2026-07-26:

- qbit_manage `v4.10.0` runs as a single UI-less Deployment every 15 minutes;
- it uses the internal qBittorrent Service and the existing SOPS-managed WebUI
  credential;
- qBittorrent `5.2.3` runs behind Gluetun/Proton with port forwarding and a
  fail-closed network path;
- Sonarr/Radarr own the `tv`/`movies` categories;
- qbit_manage classifies unmatched trackers as `tracker-public`;
- the public share-limit group manages `tv`/`movies`, excluding
  `tracker-private`;
- public torrents stop at ratio 1.5 after at least one day, or after seven days;
- public cleanup is active and uses a seven-day download-side recycle bin; and
- `/data/media` is not mounted into qbit_manage.

The deployed design, operating notes, and validation live in:

- `kubernetes/apps/media/qbit-manage/app/config.yml`
- `kubernetes/apps/media/qbit-manage/app/values.yaml`
- `scripts/validate/qbit-manage.sh`
- `scripts/verify/qbit-manage.sh`
- `docs/qbit-manage.md`
- `plans/qbit-manage-public-tracker-policy-agent-plan.md`

Do not redeploy qbit_manage, introduce another policy service, redesign the public
policy, replace the credential, add a Service/HTTPRoute, or change the VPN path as
part of this work.

## Outcome

Add a CZTeam-specific policy that:

1. positively identifies CZTeam by a verified announce hostname;
2. marks its torrents with both `tracker-private` and `tracker-czteam`;
3. excludes CZTeam from the destructive public cleanup path with defense in depth;
4. seeds every CZTeam torrent for at least seven days;
5. stops, but never removes, a torrent after seven days only when ratio 2.0 has
   also been reached;
6. keeps seeding indefinitely when ratio 2.0 has not been reached;
7. leaves Sonarr/Radarr categories unchanged; and
8. provides offline invariants, a dry-run gate, live acceptance, and a
   non-destructive rollback.

TorrentLeech, FileList, cross-seed automation, account-stat scraping, and policy
for any other private tracker are out of scope. They require separate rule reviews
and separate tracker-specific policies.

## Why the sequencing is safety-critical

The old plan assumed unmatched torrents were unmanaged. That is no longer true:
an unmatched torrent in `tv` or `movies` inherits the live public policy, including
cleanup. A CZTeam torrent must therefore be protected before it can download.

```text
verified CZTeam announce host
        |
        +-- tracker-private -----> excluded from public policy
        |
        +-- tracker-czteam ------> selected by CZTeam policy
```

Use both tags:

- `tracker-private` is the generic safety boundary already consumed by the public
  group's exclusion;
- `tracker-czteam` selects the dedicated higher-priority CZTeam share-limit group.

Also add `tracker-czteam` directly to the public group's exclusions. This is
intentional defense in depth: either private tag independently prevents CZTeam
from entering public cleanup.

Do not rely on the public policy's one-day minimum as an onboarding window. It is
only a limited recovery margin, and cleanup is already enabled.

## Current CZTeam rules to re-verify

The public CZTeam rules and FAQ were checked on 2026-07-26 and state:

- overall account ratio must remain at least 0.5;
- every completed torrent must seed for at least 72 hours;
- downloading more than 50% starts a ten-day H&R window;
- the H&R condition is cleared by personal ratio 1.0 or 72 hours of seed time;
- five active H&Rs cause a warning and ten can disable the account;
- 144 total seed hours can clear an H&R without spending bonus points;
- announces normally update statistics every 30–45 minutes;
- connectability/port forwarding is encouraged; and
- stock qBittorrent is allowed.

The current client allow-list includes qBittorrent `5.2.3`, which matches the
repository. Re-check that exact version before implementation and before any later
qBittorrent upgrade.

Authoritative sources:

- <https://czteam.me/rules.php>
- <https://czteam.me/faq.php>
- <https://czteam.me/clients.php>

The implementation policy deliberately exceeds the 72-hour rule:

```text
minimum seed time: 7d
ratio goal: 2.0
maximum seed time: unlimited
limit action: Stop
cleanup: false
```

Seven days gives margin for cluster/VPN downtime and delayed tracker announces.
Local qBittorrent seed time is not proof that CZTeam credited every announce, so
the operator must still check the tracker's H&R/account pages.

## Non-negotiable safety invariants

1. No CZTeam torrent may download until its real announce hostname is known and
   it is protected from the public group.
2. Never commit or print a passkey, full announce URL, torrent name, tracker
   credential, cookie, API key, or unsanitized log.
3. Match only the announce hostname observed from a real CZTeam torrent. Do not
   assume the website, Torznab, and announce hosts are identical.
4. The CZTeam tracker mapping must add both `tracker-private` and
   `tracker-czteam`.
5. The public group must exclude both `tracker-private` and `tracker-czteam`.
6. The CZTeam group must have a higher priority than public. qbit_manage uses the
   lowest number as the highest priority, and a torrent can match only one group.
7. The CZTeam group must always use `cleanup: false`.
8. The CZTeam group must use `share_limit_action: Stop`, never `Remove` or
   `RemoveWithContent`.
9. `max_seeding_time` must remain unlimited. A low-demand torrent below ratio 2.0
   must continue seeding.
10. `commands.rem_unregistered`, `rem_orphaned`, `tag_nohardlinks`,
    `tag_tracker_error`, `cat_update`, and `recheck` remain false.
11. The existing public-policy numbers, cleanup behavior, recycle-bin retention,
    categories, and storage mounts remain unchanged.
12. Do not bypass qbit_manage's qBittorrent compatibility check.
13. Live rollout and cluster health checks use guarded `just` recipes. Agents
    stage and validate source; the operator performs rollout gates.
14. Rolling back the CZTeam policy must retain CZTeam's private classification
    and public exclusions.

Stop and ask the operator if any invariant cannot be preserved.

## Required operator inputs

Before editing policy, obtain:

1. whether any CZTeam torrent is already present in qBittorrent;
2. the sanitized announce hostname from a real CZTeam torrent; and
3. confirmation that qBittorrent `5.2.3` still appears on CZTeam's current
   allow-list.

Never ask the operator to paste a complete announce URL. The implementation needs
only a hostname such as `announce.example.invalid`.

### If a CZTeam torrent already exists

Treat it as an immediate safety gate before normal rollout:

1. Do not download more data from CZTeam.
2. In the qBittorrent UI, add `tracker-private` and `tracker-czteam` manually.
3. Inspect that torrent's per-torrent ratio, seeding-time, and limit action. Clear
   any inherited public limits deliberately and resume seeding if it was stopped.
4. Confirm the tracker reports it as seeding and wait through at least one
   announce interval.
5. Continue to Phase 1 only after recording a sanitized result.

Manual tags are temporary protection, not the declarative end state.

### If no CZTeam torrent exists

Keep it that way until Phase 1 is merged and live acceptance proves that the
classification protects a paused fixture. Obtain the hostname by adding a legally
obtained torrent paused, inspecting only the hostname, and preventing data
transfer until the protection is active.

## qbit_manage semantics to validate

Use the pinned `v4.10.0` source/sample configuration as the implementation
contract, not examples copied from another release:

- a tracker mapping's `tag` may be a list;
- `settings.private_tag` can generically tag torrents whose metadata is private;
- lower numeric `priority` wins;
- each torrent receives only one share-limit group;
- `min_seeding_time` requires a positive `max_ratio`;
- before the minimum is met, qbit_manage must remove the effective stop limit and
  resume the torrent;
- `cleanup: false` prevents qbit_manage removal but does not by itself prevent
  qBittorrent from performing the configured share-limit action;
- `share_limit_action: Stop` is explicit and reversible for qBittorrent 5.2.x; and
- omitting `max_seeding_time`, or using the pinned version's validated `-1`
  representation, means unlimited.

Sources:

- <https://github.com/StuffAnThings/qbit_manage/tree/v4.10.0>
- <https://github.com/StuffAnThings/qbit_manage/blob/v4.10.0/config/config.yml.sample>
- <https://github.com/StuffAnThings/qbit_manage/wiki/Config-Setup>
- <https://github.com/StuffAnThings/qbit_manage/wiki/Commands>

If the pinned implementation does not resume a ratio-satisfied torrent until the
seven-day minimum is met, stop. Do not activate a weaker policy.

## Expected files

Keep the implementation scoped to:

- `kubernetes/apps/media/qbit-manage/app/config.yml`
- `kubernetes/apps/media/qbit-manage/app/values.yaml` for the required
  `config-hash` update only
- `scripts/validate/qbit-manage.sh`
- `scripts/verify/qbit-manage.sh`, only if its existing sanitized checks can be
  extended safely
- `kubernetes/mod.just`, only if a new guarded read-only verification recipe is
  required
- `docs/qbit-manage.md`

Do not change the Deployment image, schedule, resources, storage, Secret,
HelmRelease, Flux dependencies, qBittorrent, Gluetun, Sonarr, Radarr, or Prowlarr
manifests.

## Phase 0 — Baseline and rule gate

1. Follow `AGENTS.md` worktree/branch rules and start from fresh `origin/main`.
2. Confirm the current files still match the baseline in this plan.
3. Re-read CZTeam rules, FAQ, and allowed-client list.
4. Confirm qbit_manage remains `v4.10.0` and qBittorrent remains `5.2.3`.
5. Run the existing offline qbit_manage validation.
6. Record whether live CZTeam torrents exist without exposing their names or URLs.
7. Obtain and locally retain only the sanitized announce hostname.

Stop if:

- the CZTeam rules or allowed-client status changed;
- public cleanup or its exclusion model changed;
- qbit_manage/qBittorrent compatibility is failing;
- a torrent cannot be protected before download; or
- the hostname cannot be positively identified without exposing a secret.

## Phase 1 — Land classification protection first

The first implementation PR establishes protection but does not add the CZTeam
share-limit group. An excluded CZTeam torrent therefore seeds indefinitely.

### Configuration

Add generic private-torrent detection:

```yaml
settings:
  private_tag: tracker-private
```

Add the verified hostname above `other`. This is conceptual; substitute only the
operator-confirmed hostname:

```yaml
tracker:
  "<verified-czteam-announce-host>":
    tag:
      - tracker-private
      - tracker-czteam
  other:
    tag: tracker-public
```

Retain the generic public exclusion and add the CZTeam-specific exclusion:

```yaml
share_limits:
  public:
    exclude_any_tags:
      - tracker-private
      - tracker-czteam
```

Do not add a passkey, scheme, port, or path to the tracker key.

### Offline validation

Extend `scripts/validate/qbit-manage.sh` to assert:

- `settings.private_tag == tracker-private`;
- at least one non-`other` mapping has both CZTeam tags;
- no private mapping contains `://`, a URL path, query parameters, or a suspicious
  passkey-like value in the mapped key;
- the public group excludes both private tags;
- the public group retains priority 100, categories `tv`/`movies`, ratio 1.5,
  minimum one day, maximum seven days, `Stop`, and cleanup enabled;
- no `czteam` share-limit group exists in this phase;
- destructive/unrelated commands retain their existing values; and
- the config hash in `values.yaml` matches `git hash-object config.yml`.

The word `announce` may legitimately occur in a hostname, so secret validation
must reject URL syntax and paths rather than rejecting a normal hostname label.
Implement the check accordingly.

Update `docs/qbit-manage.md` to describe the two-tag model, generic
`private_tag` safety net, the staged rollout, and the rule that the mapping must
land before downloading.

### Merge and live gate

After `just ci` passes, open the PR. The operator merges and lets Flux reconcile.
Then the operator:

1. runs the guarded qbit_manage live verification;
2. confirms a paused CZTeam fixture has both private tags;
3. confirms it does not have the public share-limit group;
4. confirms `tv`/`movies` category ownership is unchanged;
5. confirms no torrent or data was removed; and
6. observes at least two scheduler cycles.

If no existing guarded recipe can prove the required state without leaking torrent
or tracker details, add a narrowly scoped read-only recipe that emits only
sanitized counts/booleans. Do not put raw `kubectl`/qBittorrent API commands in the
runbook.

Do not continue until classification is live and correct.

## Phase 2 — Add the CZTeam policy in global dry-run

Use a separate PR. Temporarily set `commands.dry_run: true` while adding the
CZTeam group. This pauses new qbit_manage mutations, including public cleanup,
during the review window; it does not alter the existing qBittorrent, Arr, or VPN
configuration.

Conceptual pinned-version configuration:

```yaml
commands:
  dry_run: true

share_limits:
  czteam:
    priority: 10
    include_all_tags:
      - tracker-czteam
    max_ratio: 2.0
    min_seeding_time: 7d
    share_limit_action: Stop
    cleanup: false

  public:
    priority: 100
    # existing public policy remains otherwise unchanged
```

Do not add `max_seeding_time` unless the pinned schema requires the explicit
unlimited value. Never use a finite maximum.

Extend offline validation to assert:

- CZTeam priority is numerically lower than public priority;
- CZTeam matches only `tracker-czteam`;
- ratio is 2.0 and minimum seed time is seven days;
- maximum seed time is absent or the validated unlimited sentinel;
- action is `Stop`;
- cleanup is false;
- the public group still excludes both private tags;
- global dry-run is true for this phase; and
- all Phase 1 and existing public-policy invariants still hold.

### Dry-run acceptance

After operator merge/reconcile, observe at least two scheduled runs and prove,
without exposing names or URLs:

1. a CZTeam torrent selects only the `czteam` group;
2. a public torrent still selects only the public group;
3. no torrent selects multiple groups;
4. a CZTeam torrent under seven days would be unlimited/resumed even if its ratio
   is already at least 2.0;
5. a CZTeam torrent at least seven days old and ratio at least 2.0 would be
   stopped, not removed;
6. a CZTeam torrent below ratio 2.0 has no finite time cutoff;
7. categories remain unchanged; and
8. dry-run performs no tag, limit, cleanup, or filesystem mutation.

If the available torrents do not exercise the minimum-time edge case, validate
the exact behavior against the pinned source or a legal, isolated fixture. Do not
infer it from configuration parsing alone.

## Phase 3 — Activate only the reviewed policy

Use a final, minimal PR that changes only:

```yaml
commands:
  dry_run: false
```

and the corresponding config hash. Do not combine activation with an image
upgrade, policy-number change, new tracker, or cleanup change.

Before opening or updating the PR:

1. fetch `origin`;
2. rebase onto `origin/main` if required by `AGENTS.md`;
3. confirm Phase 1 is live and the CZTeam torrent is already tagged/protected;
4. confirm the dry-run evidence is clean; and
5. run `mise exec -- just ci`.

After the operator merges and Flux reconciles, observe at least two scheduler
cycles and verify:

- both CZTeam tags remain present;
- CZTeam is excluded from public cleanup;
- the CZTeam group is applied;
- a torrent below seven days is not stopped by the ratio goal;
- a torrent below ratio 2.0 is not stopped by age;
- no CZTeam torrent is removed or moved to the recycle bin;
- public behavior is unchanged;
- Sonarr/Radarr categories and imports still work; and
- qBittorrent remains connectable through the existing Proton forwarded port.

Allow at least one normal CZTeam announce interval before treating tracker-side
statistics as current. Manually confirm the account/H&R page shows expected
credit.

## Documentation

Revise `docs/qbit-manage.md` so the final state is unambiguous:

- generic private torrents are excluded from public cleanup;
- CZTeam gets a dedicated tag and group;
- the effective CZTeam policy is 7d minimum + ratio 2.0 + unlimited maximum +
  Stop + no cleanup;
- local enforcement does not replace account/H&R monitoring;
- the announce hostname is safe to commit, but passkeys/full URLs are not;
- how to inspect sanitized status through guarded recipes;
- how to disable only the CZTeam policy while retaining classification;
- how to clear an incorrectly inherited per-torrent limit deliberately;
- current CZTeam rule and allowed-client links; and
- other private trackers require their own plan.

Do not preserve obsolete instructions saying all `tracker-private` torrents are
unmanaged once CZTeam has a managed private policy.

## Rollback

Rollback the policy, never the protection:

1. Keep the verified hostname mapping and both public exclusions.
2. Return the CZTeam group to a no-limit/no-cleanup state or remove only that
   group through GitOps.
3. Inspect CZTeam torrents for persisted per-torrent limits and clear them
   deliberately in qBittorrent; resume any stopped torrent.
4. Verify the tracker reports seeding after an announce interval.
5. Revert the failed policy PR through the normal branch/PR workflow.

Do not:

- remove `tracker-private` or `tracker-czteam` while CZTeam torrents exist;
- enable public handling as a fallback;
- delete torrents/data;
- mass-reset unrelated public limits; or
- stop qBittorrent/Gluetun as part of policy rollback.

If qbit_manage itself must be paused, make the durable `spec.suspend` change via
GitOps or use an existing guarded operator recipe. qBittorrent must continue
seeding.

## Validation contract

For every implementation PR:

```text
mise exec -- just ci
```

is mandatory before push/PR update. It must cover the extended static
qbit_manage invariants.

Operator-only live gates use repository recipes, including:

```text
mise exec -- just kube qbit-manage-verify
```

Add a guarded, sanitized CZTeam-specific verification recipe if the existing
recipe cannot prove classification/group state. Do not add cluster-dependent
checks to `just ci`.

Report:

- validation commands and results;
- live checks performed by the operator;
- checks skipped and why;
- sanitized classification/group counts;
- current dry-run/cleanup state;
- CZTeam rule-review date;
- allowed-client result; and
- remaining account-level/manual risks.

## Definition of done

The implementation is complete when:

- the announce hostname was verified without exposing its passkey;
- qBittorrent `5.2.3` is still allowed by CZTeam;
- CZTeam torrents receive both private tags;
- automatic private detection applies `tracker-private` as a safety net;
- public cleanup excludes both tags;
- the CZTeam group outranks public and is the only selected group;
- CZTeam seeds for at least seven days;
- ratio 2.0 cannot stop a torrent before seven days;
- a torrent below ratio 2.0 seeds indefinitely;
- CZTeam cleanup is false and action is `Stop`;
- existing public behavior is unchanged;
- categories remain under Sonarr/Radarr ownership;
- no secret or torrent-identifying data is committed or reported;
- offline CI passes for every PR;
- dry-run and active behavior are observed through guarded checks;
- account/H&R credit is manually confirmed after an announce; and
- documentation and rollback instructions match the final implementation.

The agent opens or updates the required PRs but does not merge them. The operator
owns every merge and live rollout gate.
