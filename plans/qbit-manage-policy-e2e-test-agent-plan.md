# qbit_manage Real-Download Policy E2E — Agent Plan

## Context

`qbit_manage` is active as qBittorrent's lifecycle policy engine. The production
policy:

- classifies unmatched trackers as `tracker-public`;
- reserves `tracker-private` as the safety exclusion;
- manages torrents only in the `movies` and `tv` categories;
- stops eligible torrents at ratio `1.5` after at least one day, or at seven
  days regardless of ratio;
- moves cleaned download-side data into `/data/downloads/.RecycleBin`; and
- cannot access `/data/media`, where imported hardlinks live.

Static validation, live readiness verification, and a generated-file hardlink
test exist. They do not prove the real chain:

```text
public torrent download
  -> deployed tracker classification
  -> accelerated isolated share limits
  -> private-tag exclusion
  -> stop and cleanup
  -> recycle-bin move
  -> media hardlink survives
```

This plan adds that proof without changing the production policy or waiting for
its one-day/seven-day thresholds.

## Outcome

The final operator-only acceptance command is:

```bash
CLUSTER_E2E_CONFIRM=e2e:qbit-manage-policy \
  mise exec -- just test e2e qbit-manage-policy
```

It downloads WebTorrent's legal public Sintel fixture through the live
qBittorrent instance, observes the deployed `qbit_manage` scheduler
classification, and runs isolated one-shot Jobs using accelerated limits.

Passing proves the qBittorrent API, VPN-backed download, shared storage,
deployed tracker classification, `qbit_manage` limit application, private
exclusion, cleanup, recycle-bin behavior, and hardlink safety worked together.

The boundary is policy plus a representative hardlink. It does not claim that
Sonarr or Radarr performed an import.

## Delivery model

Deliver three sequential PRs. Each starts from fresh `origin/main`, passes
`mise exec -- just ci`, and waits for operator merge before the next branch.

### PR-A — validation baseline

Branch: `fix/qbit-manage-validation-baseline`

- Replace the vacuous named-tracker assertion.
- Exempt `tracker.other`, which must remain exactly `tracker-public`.
- Require every other tracker mapping to include `tracker-private` and exclude
  `tracker-public`; normalize scalar/list tag values.
- Require the managed category list to contain exactly `movies` and `tv`,
  order-insensitively.
- Add positive and negative offline fixtures for these rules.
- Correct stale rollout comments and live-verifier wording.

### PR-B — smoke and result semantics

Branch: `test/qbit-manage-smoke-results`

- Add `mise exec -- just test smoke media qbit-manage`.
- Assert Flux Kustomization, HelmRelease, Deployment, pod readiness, and zero
  application-container restarts.
- Surface `recovery.json` for both E2E and resilience tiers.
- Preserve primary assertion and cleanup/recovery as independent statuses.
- Make cleanup failure produce an overall non-zero result without overwriting
  the primary outcome.
- Correct the existing `media-hardlink` cleanup classification.

### PR-C — real-download E2E

Branch: `test/qbit-manage-policy-e2e`

- Add the exact confirmation guard and explicit Chainsaw registry entry.
- Add the real-download orchestrator, isolated policy Job generation, evidence,
  diagnostics, and safe teardown.
- Add offline unit/negative tests and operator documentation.

## Current assurance layers

| Layer | Claim | Cluster mutation | CI |
|---|---|---:|---:|
| validator unit tests | unsafe policy variants fail | no | yes |
| `qbit-manage-validate` | source/rendered production invariants | no | yes |
| `qbit-manage-verify` | live readiness, auth, scheduled run | no | no |
| qbit_manage smoke | live Kubernetes health | no | no |
| `media-hardlink` E2E | shared filesystem preserves hardlinks | test files | no |
| policy E2E | real download and policy lifecycle | isolated fixture | no |

Smoke and E2E remain outside `just ci`.

## E2E fixture

Use:

```text
torrent URL: https://webtorrent.io/torrents/sintel.torrent
info hash:   08ada5a7a6183aae1e09d831df6748d566095a10
```

The public internet is an explicit dependency. A download timeout or unavailable
peer/web seed is recorded as an external-dependency failure, cleanup still
runs, and the test remains non-zero because the workflow was not proven.

The fixture may arrive entirely through a web seed, so the deterministic
maximum-seeding-time branch drives cleanup. The E2E does not claim to prove
actual BitTorrent upload demand or the ratio branch.

## Shared-instance isolation

1. Require:

   ```text
   CLUSTER_E2E_CONFIRM=e2e:qbit-manage-policy
   ```

2. Use the existing state-changing test lock.
3. Refuse to start if the fixed Sintel info hash already exists. Never adopt or
   delete a pre-existing torrent.
4. Derive a unique category, tag, Kubernetes name, and filesystem paths from
   the run ID.
5. Use category `e2e-qbm-<run-id>`. The production group matches only
   `movies`/`tv`, so the production worker cannot limit or clean the fixture.
6. The production worker may add `tracker-public`. Pinned v4.10.0 tag updates
   are additive except for the worker-managed stalled tag, so a manual
   `tracker-private` remains present.
7. Fresh test recycle data cannot be purged by the production seven-day
   retention pass.
8. Temporary Jobs set `skip_cleanup: true`; they never run an extra global
   recycle-bin purge.
9. Temporary Jobs mount only `/data/downloads`, never `/data/media`.
10. Temporary settings disable global preference mutation and use run-specific
    share-limit/minimum-condition tag namespaces.
11. Temporary groups require both the run category and run tag, and exclude
    `tracker-private`.
12. Credentials are referenced from the existing Secret and never printed or
    persisted.
13. Teardown deletes only the fixed hash if this run created it, exact
    run-labeled Kubernetes resources, and safe-validated run paths.
14. Cleanup failure fails the command even if primary assertions passed.

## Accelerated policy

Derive the temporary config from the deployed ConfigMap so it uses the live
schema and qBittorrent connection. Replace command authority, settings relevant
to isolation, and share-limit groups.

Only `share_limits` is enabled:

```yaml
commands:
  dry_run: false
  recheck: false
  cat_update: false
  tag_update: false
  rem_unregistered: false
  tag_tracker_error: false
  rem_orphaned: false
  tag_nohardlinks: false
  share_limits: true
  skip_cleanup: true
```

Set:

```yaml
settings:
  disable_qbt_default_share_limits: false
  share_limits_filter_completed: true
  share_limits_tag: "~e2e_qbm_<run-id>"
  share_limits_min_seeding_time_tag: "e2e_qbm_min_seed_<run-id>"
  share_limits_min_num_seeds_tag: "e2e_qbm_min_seeds_<run-id>"
  share_limits_last_active_tag: "e2e_qbm_last_active_<run-id>"
```

Use one group:

```yaml
share_limits:
  e2e_qbm_<run-id>:
    priority: 1
    categories:
      - e2e-qbm-<run-id>
    include_all_tags:
      - e2e-qbm-<run-id>
    exclude_any_tags:
      - tracker-private
    custom_tag: e2e-qbm-limit-<run-id>
    add_group_to_tag: true
    max_ratio: 0.01
    min_seeding_time: 1m
    max_seeding_time: 2m
    share_limit_action: Stop
    cleanup: <false-or-true>
```

Validate the generated YAML before creating a Job. Use the exact deployed image
and security context. Invoke the pinned v4.10.0 `--run` one-shot interface.

## E2E workflow

### 1. Preflight

- Run qBittorrent and qbit_manage guarded live verification.
- Confirm the live qBittorrent and hardlink-probe pods are Ready.
- Read the deployed qbit_manage image and ConfigMap.
- Refuse a pre-existing fixture hash or run-owned resource/path collision.
- Initialize independent assertion, cleanup, and external-dependency results.

### 2. Real download

- Create an ephemeral API helper referencing `qbit-manage-secret`.
- Authenticate to qBittorrent without echoing credentials or cookies.
- Add the Sintel URL with the run category and exact save path.
- Do not add the run tag yet.
- Require the expected hash, `progress == 1`, all files complete, exact save
  path, and at least one non-empty payload file.

### 3. Production classification

- Let the deployed scheduler run normally; do not restart or force it.
- Wait for `tracker-public` and require `tracker-private` to be absent.
- Record classification time and sanitized tags.
- Add the run tag only after classification is proven.

### 4. Representative import

- From the Sonarr application container, select the largest completed payload.
- Hardlink it into `/data/media/.e2e-qbit-manage-<run-id>/`.
- Record source/destination inode, link count, size, and SHA-256.
- Require the initial inode to match and link count to be at least two.
- Create a non-torrent sentinel adjacent to the test download.

### 5. Private exclusion

- Add `tracker-private` while retaining public/run tags.
- Re-query immediately before the Job and abort if the premise is absent.
- Run the cleanup-enabled fast policy.
- Require torrent, category, download, hardlink, and sentinel to remain.
- Require the temporary group tag to be absent.
- Remove only `tracker-private`.

### 6. Apply limits without cleanup

- Run with `cleanup: false`.
- Require the custom group tag, ratio limit `0.01`, two-minute seed limit,
  stopped/paused state, unchanged category, and retained files.
- Seeding age is continuous from completion; do not introduce a second
  two-minute window.

### 7. Cleanup and idempotency

- Run with `cleanup: true`.
- Require the hash to disappear, original payload to disappear, and run-owned
  recycle data to appear.
- Require media inode, size, and digest to match the pre-cleanup evidence.
- Record post-cleanup link count but do not constrain it: rename and copy/delete
  implementations are both acceptable.
- Require the unrelated sentinel to survive.
- Run cleanup again; require exit zero, no torrent, and no duplicate recycle
  entry.

### 8. Teardown

- Remove the fixture only if ownership was recorded.
- Remove exact run category/tag and run-labeled resources.
- Remove exact run download, media, sentinel, and recycle paths after rejecting
  empty, broad, traversal, or wrong-run paths.
- Verify no run-owned state remains.
- Record cleanup independently and retain sanitized evidence.

## Timeout budget

Use one 60-minute overall deadline:

| Phase | Maximum |
|---|---:|
| preflight | 5m |
| real download | 20m |
| production classification | 20m |
| policy Jobs/assertions | 10m |
| teardown | 5m |

The deployed schedule is 15 minutes; the classification allowance includes
polling slack. Failures exit their phase and proceed directly to teardown.

## Result contract

Write:

```text
assertion.json
cleanup.json
external-dependency.json
evidence.json
environment.json
summary.json
logs/
manifests/
diagnostics/
```

Allow fixed hash, run-owned paths, sanitized state/category/tags/limits,
timestamps, Job status, and hardlink evidence. Forbid credentials, cookies,
Secret YAML, raw environment dumps, unrelated torrent inventory, and unrelated
media logs.

Summary statuses:

| Status | Meaning |
|---|---|
| assertion failed | policy or hardlink behavior was wrong |
| external dependency failed | fixture was unavailable within its bound |
| diagnostics failed | safe evidence collection failed |
| cleanup failed | exact test-owned state may remain |
| passed | assertions and teardown succeeded |

## Offline tests

Cover:

- exact confirmation acceptance/rejection;
- explicit dispatch registration;
- state lock;
- run-ID and safe-path validation;
- pre-existing fixture refusal;
- API redaction;
- generated config has only the intended command/group;
- global preference mutation is disabled;
- run-specific tag namespaces are enforced;
- both category and run tag are required;
- private exclusion cannot be omitted;
- dependency failure is distinct from assertion failure;
- teardown runs after failure;
- cleanup failure remains visible and non-zero;
- primary failure is not masked;
- no-match second cleanup succeeds; and
- existing media-hardlink cleanup reporting remains correct.

## Acceptance

Every PR passes:

```bash
mise exec -- just test validate
mise exec -- just kube qbit-manage-validate
mise exec -- just ci
```

After PR-C is merged and Flux reconciles it, the operator runs:

```bash
mise exec -- just kube qbittorrent-verify
mise exec -- just kube qbit-manage-verify
mise exec -- just test smoke media qbittorrent
mise exec -- just test smoke media qbit-manage
CLUSTER_E2E_CONFIRM=e2e:qbit-manage-policy \
  mise exec -- just test e2e qbit-manage-policy
```

The E2E passes only if the real fixture completes the full classification,
private exclusion, limit, stop, cleanup, recycle, hardlink, idempotency, and
teardown chain.
