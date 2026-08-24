# Operate qbit_manage

qbit_manage applies the repository's seeding and cleanup policy to qBittorrent. This
guide covers normal operation, credential rotation, fresh-deployment bootstrap, first-run
acceptance, containment, and recovery.

The exact active policy is documented in the
[qbit_manage policy reference](../reference/qbit-manage.md). Repository authority is
defined in [`AGENTS.md`](../../AGENTS.md).

## Active-policy mental model

qbit_manage has no web interface or Service. It is a long-running scheduler that calls
the internal qBittorrent Web API every 15 minutes.

```text
qbit_manage
    ↓ every 15 minutes
qBittorrent Web API
    ↓
classify torrents
apply share and seeding limits
identify cleanup candidates
    ↓
eligible download-side data may move to .RecycleBin
```

The policy is active: `commands.dry_run` is `false`. Classification, share limits, and
cleanup can make real changes to torrent state and download-side files. A healthy
Deployment proves that the scheduler is running; it does not prove that every semantic
decision about a particular torrent is correct.

Current high-level behavior is:

- qbit_manage adds public/private and tracker-specific classification tags but never
  changes the application-owned `tv`, `movies`, or `music` categories.
- Public TV and movie torrents stop after the configured ratio/time conditions or the
  seven-day maximum. Cleanup is enabled.
- Public music torrents use a longer seven-day minimum and 30-day maximum. Cleanup is
  enabled.
- Private torrents receive `tracker-private`, which excludes them from the public
  cleanup groups. CZTeam uses its own non-cleaning seeding policy.
- Eligible cleaned data moves to `/data/downloads/.RecycleBin` for seven days.
- The Pod mounts `/data/downloads` but not `/data/media`; it cannot remove the organized
  media-library path.

Use the policy reference for exact ratios, times, selection rules, and private-tracker
safeguards.

## Ownership

- qBittorrent owns downloads, torrent runtime state, and seeding execution.
- Sonarr, Radarr, and Lidarr own categories, imports, naming, and organized library
  files.
- qbit_manage owns the configured torrent classification, share-limit, stop, and
  cleanup policy.
- Git owns the qbit_manage configuration and SOPS-encrypted qBittorrent credential.
- Flux deploys that desired state and remains the durable Kubernetes authority.
- `.RecycleBin` provides a short recovery opportunity for eligible download-side data.
  It is not a substitute for safe policy design or attended acceptance.

qbit_manage uses the same permanent qBittorrent WebUI username and password as the media
integrations. The operator's password manager remains the human source for that
credential.

## When operator action is needed

| Situation | Action |
| --- | --- |
| Normal operation | None. qbit_manage applies the active policy automatically every 15 minutes. |
| Policy or deployment source changes | Validate, publish through Git, let Flux reconcile, then run live verification and inspect affected behavior. |
| qBittorrent WebUI credential changes | Regenerate the encrypted qbit_manage Secret through Git. The writer also updates the Pod rollout stamp. |
| Fresh, empty, or deliberately rebuilt deployment | Stage the source suspended and use the guarded bootstrap workflow. |
| First active run after bootstrap | Attend the run and inspect sanitized policy behavior in qBittorrent and local logs. |
| Unexpected classification or cleanup | Use the recovery runbook to stop qbit_manage through the complete Flux ownership chain. |
| Mistaken clean | Keep qBittorrent running and recover the exact item before the seven-day recycle window expires. |

Credential rotation is normal maintenance. It does not require the exceptional
bootstrap when qbit_manage is already active.

## Commands and authority

| Command or workflow | What it does | Effect and authority |
| --- | --- | --- |
| `mise exec -- just repo qbit-manage-secrets` | Writes the encrypted qBittorrent credential and its Pod rollout stamp. | Mutates tracked credential source; operator-run because it needs plaintext credential input and the operator-held age identity. |
| `mise exec -- just kube qbit-manage-validate` | Checks source shape, Secret and rollout wiring, active policy invariants, storage boundary, and rendered manifests. | Local and read-only; agent-owned during normal implementation. |
| `mise exec -- just kube qbit-manage-verify` | Observes live Flux, Helm, Deployment, restart, and sanitized scheduler/authentication state. | Read-oriented observer-tier verification; agents may run it autonomously for approved scoped work. |
| `mise exec -- just bootstrap qbit-manage` | Temporarily resumes and reconciles source that was deliberately deployed suspended. | Privileged live mutation with administrator credentials; operator-run. |
| qbit_manage containment and mistaken-clean recovery | Freezes the Flux ownership chain, stops the Deployment, preserves qBittorrent, and establishes durable Git suspension. | Exceptional, broad-impact administrator mutation; operator-run from the recovery runbook. |

A confirmation variable prevents accidental execution. It does not decide authority.
Secret creation is operator-owned because it needs the private age identity and plaintext
credential. Bootstrap and containment are operator-owned because they mutate live state
with administrator credentials.

Generic worktree and credential procedures are in
[Set up the operator repository and worktrees](repository-worktree-setup.md) and
[Use scoped agent cluster access](agent-cluster-access.md). A linked worktree's observer
or diagnostic credential does not authorize bootstrap or containment.

## Normal operation and verification

During normal operation, the Flux Kustomization has `spec.suspend: false`, the Deployment
has one active scheduler, and no operator action is required.

Validate a source change before publication:

```bash
mise exec -- just kube qbit-manage-validate
```

After the change merges and Flux reconciles, run:

```bash
mise exec -- just kube qbit-manage-verify
```

### What `qbit-manage-verify` proves

The live verifier confirms:

- the Flux Kustomization and HelmRelease are Ready;
- the Deployment rollout completed;
- the application container has not restarted;
- a recent scheduled run produced a known run or connection marker; and
- sanitized log inspection found no configured parse, connection, or qBittorrent
  authentication failure.

The verifier reads logs internally but prints only a sanitized outcome.

### What it does not prove

The verifier does not prove:

- that every torrent received the correct classification;
- that a particular ratio, stop, or cleanup decision was appropriate;
- that a private tracker's rules were interpreted correctly;
- that a mistakenly cleaned item remains recoverable; or
- that the operator attended the first active policy run.

Use qBittorrent's UI and locally inspected qbit_manage logs when human semantic judgment
is required. Never publish those logs.

## Create or rotate the qBittorrent credential

Perform the tracked change in the assigned feature worktree. Load the repository SOPS
identity as described in
[Operate repository SOPS secrets](sops-secret-operations.md), then enter the permanent
qBittorrent WebUI credential without echoing the password:

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

The writer:

1. verifies that the loaded age identity matches `.sops.yaml`;
2. creates `QBT_USER` and `QBT_PASS` in an owner-readable temporary file;
3. encrypts the candidate for
   `kubernetes/apps/media/qbit-manage/app/qbit-manage-secret.sops.yaml`;
4. rejects a candidate containing either plaintext input;
5. writes only the encrypted Secret; and
6. stamps that encrypted Secret's Git blob revision into the qbit_manage Pod template.

The stamp is required because `envFrom` credentials are read only when the process
starts. After merge, changing the stamp changes the Pod template, and the `Recreate`
Deployment starts a replacement Pod with the new credential.

Then:

1. run `mise exec -- just kube qbit-manage-validate`;
2. review the ciphertext and rollout-stamp changes;
3. publish through a pull request;
4. let Flux reconcile the replacement Pod; and
5. run `mise exec -- just kube qbit-manage-verify`.

The writer cannot prove that qBittorrent accepts the credential. The post-reconcile live
verifier supplies that authentication check. Do not patch the live Secret or restart the
Deployment by hand.

## Bootstrap a fresh or rebuilt deployment

Bootstrap is for a deliberately suspended fresh or rebuilt deployment. It is not a
routine restart or credential-rotation command.

### Prepare suspended source

In the assigned feature worktree:

1. Create the encrypted credential as described above.
2. Set `spec.suspend: true` in
   `kubernetes/apps/media/qbit-manage/ks.yaml`.
3. Run:

   ```bash
   mise exec -- just kube qbit-manage-validate
   ```

4. Commit, open a pull request, merge, and wait for Flux to observe the suspended
   source.

Stop there in the feature worktree. The scoped observer and diagnostic credentials do
not authorize the next step.

### Run the guarded bootstrap

From the authorized operator checkout with administrator Kubernetes credentials:

1. Update the checkout to the exact deployed `origin/main` revision.
2. Confirm qBittorrent itself is ready:

   ```bash
   mise exec -- just kube qbittorrent-verify
   ```

3. Run the guarded bootstrap:

   ```bash
   export QBIT_MANAGE_BOOTSTRAP_CONFIRM='bootstrap:media:qbit-manage'
   mise exec -- just bootstrap qbit-manage
   unset QBIT_MANAGE_BOOTSTRAP_CONFIRM
   ```

The recipe verifies the expected repository origin, requires its guarded source paths to
match deployed `origin/main`, checks the Flux source and active parent, and requires the
qbit_manage Kustomization to be suspended in both Git and the live cluster. Only then
does it resume and reconcile qbit_manage, wait for readiness, and run
`qbit-manage-verify`.

If readiness or verification fails after the resume, the exit trap re-suspends the
qbit_manage Kustomization while preserving resources. That protection stops further
child reconciliation; it does not guarantee that an existing Deployment stopped.

The deployed policy is active immediately. Continue with attended acceptance before
making the live state durable.

## Attend the first active policy run

The first active run is a human acceptance gate. Inspect qBittorrent and sanitized local
qbit_manage logs. Confirm that:

- qBittorrent authentication succeeds;
- expected public/private and tracker-specific tags appear;
- Sonarr, Radarr, and Lidarr categories remain unchanged;
- private torrents remain excluded from public share-limit and cleanup groups;
- observed share limits and stop behavior match the policy reference;
- no unexpected torrent is selected for cleanup;
- eligible cleanup moves only download-side data into `.RecycleBin`; and
- no unexpected policy or filesystem error appears.

Do not publish torrent names, tracker URLs, passkeys, private tracker information,
download history, or raw qbit_manage logs. Keep acceptance evidence sanitized.

If acceptance passes, set `spec.suspend: false` through a separate reviewed Git change.
After merge and Flux reconciliation, rerun:

```bash
mise exec -- just kube qbit-manage-verify
```

If classification or cleanup is unexpected, do not continue with ordinary activation.
Use the containment procedure below.

## Failure and containment

### Authentication failure

An authentication failure usually means `qbit-manage-secret` does not match the
permanent qBittorrent WebUI credential. Regenerate the encrypted Secret in the feature
worktree, validate it, and publish the correction through Git. The rollout stamp ensures
the corrected credential reaches a replacement Pod after reconciliation.

Do not patch the live Secret, copy plaintext into Kubernetes, or use an ad hoc rollout.
If the active process must be stopped while the correction is reviewed, use the full
containment procedure.

### Bootstrap failure

The bootstrap trap re-suspends the qbit_manage Kustomization after a failed resumed run.
Flux suspension preserves existing resources, so a Deployment that already exists can
continue its 15-minute policy loop. Check whether the workload is still active. If it
must stop, use the containment runbook.

### Unexpected classification or cleanup

Changing only the qbit_manage Kustomization to `spec.suspend: true` stops reconciliation;
it does not stop the running scheduler. Use
[Recover a qbit_manage mistaken clean](../runbooks/recovery.md#recover-a-qbit_manage-mistaken-clean)
for the exact containment procedure.

Containment temporarily freezes the ownership chain from the top-level `flux-system`
Kustomization through `cluster-apps`, the qbit_manage Kustomization, and its HelmRelease
before scaling qbit_manage to zero. The higher-level freeze prevents an active owner
from immediately recreating the child state. It affects broader GitOps reconciliation,
so keep it only as long as required to merge and verify the durable child suspension.

Do not duplicate or improvise those commands from this guide. Use the pinned runbook and
its generation, source-revision, zero-replica, empty-Pod, and safe-resume checks.

## Recover a mistaken clean

Keep qBittorrent and Gluetun running so unrelated torrents continue to seed. Follow the
[mistaken-clean recovery procedure](../runbooks/recovery.md#recover-a-qbit_manage-mistaken-clean)
before the seven-day `.RecycleBin` retention expires.

The recovery procedure establishes durable containment through Git, identifies the
exact recycle entry without publishing private activity, restores only that entry to an
empty original path through an approved guarded workflow, and re-adds or rechecks the
torrent when needed. Correct the classification or cleanup policy in Git before running
qbit_manage again.

After seven days, do not assume the recycle entry remains. The organized library
hardlink may still exist, but reconstructing a seedable download path becomes a separate
operator recovery problem.

## Implementation reference

| Source | Role |
| --- | --- |
| [`docs/reference/qbit-manage.md`](../reference/qbit-manage.md) | Defines the current seeding, classification, cleanup, and recovery-window policy. |
| [`kubernetes/apps/media/qbit-manage/app/config.yml`](../../kubernetes/apps/media/qbit-manage/app/config.yml) | Supplies the active qbit_manage policy. |
| [`kubernetes/apps/media/qbit-manage/app/values.yaml`](../../kubernetes/apps/media/qbit-manage/app/values.yaml) | Defines the scheduler, security context, mounts, credentials, and rollout stamps. |
| [`kubernetes/apps/media/qbit-manage/ks.yaml`](../../kubernetes/apps/media/qbit-manage/ks.yaml) | Defines Flux dependencies, SOPS decryption, and suspension state. |
| [`.just/repository.just`](../../.just/repository.just) | Implements the encrypted credential writer. |
| [`.just/bootstrap.just`](../../.just/bootstrap.just) | Implements guarded suspended-source bootstrap. |
| [`scripts/validate/qbit-manage.sh`](../../scripts/validate/qbit-manage.sh) | Validates source, policy wiring, rollout stamps, and rendered resources. |
| [`scripts/verify/qbit-manage.sh`](../../scripts/verify/qbit-manage.sh) | Performs sanitized live readiness and authentication verification. |
| [`docs/runbooks/recovery.md`](../runbooks/recovery.md#recover-a-qbit_manage-mistaken-clean) | Owns the containment and mistaken-clean recovery commands. |
