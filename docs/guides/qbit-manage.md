# Configure qbit_manage deployment

Use this guide to create or replace the qbit_manage credential and to start the
application on a fresh cluster or after an intentional rebuild. The current seeding and
cleanup contract is in the [qbit_manage policy reference](../reference/qbit-manage.md).

qbit_manage has no UI or Service. It reads the permanent qBittorrent WebUI credential
from the SOPS-encrypted `qbit-manage-secret`, talks to qBittorrent over the internal
Service, and runs the current policy every 15 minutes. The current policy is active:
`commands.dry_run` is `false`, share limits and classification are enabled, and eligible
public download-side data can move to `.RecycleBin`.

## Execution contexts and authority

This workflow has two separate execution contexts. Do not carry credentials or commands
from one context into the other.

### Assigned feature worktree: author Git state

Create the SOPS ciphertext and edit the suspended source only in the assigned feature
worktree. The credential writer replaces a tracked file in the current worktree. Start
at that worktree's repository root:

```bash
test "$(git rev-parse --show-toplevel)" = "$PWD"
git status --short --branch
```

Keep the qBittorrent credential in the password manager. Never print it, paste it into
chat or a ticket, or commit plaintext. Only the resulting SOPS ciphertext belongs in
Git. Secret creation is operator-run because the operator retains the age identity; an
agent must not request or handle it.

Commit the ciphertext and suspended source on the feature branch, open a pull request,
and merge through the normal operator review boundary. A linked worktree has only
observer or diagnostic cluster credentials. It must not resume Flux, reconcile the
application, or scale the workload.

### Authorized main clone: perform live operations

After the required Git state is merged, the operator updates the authorized main clone
to that exact `origin/main` commit. The main clone owns the administrator Kubernetes
kubeconfig described in [Repository and worktree setup](repository-worktree-setup.md); do not
copy it into the feature worktree. Run the guarded bootstrap and any emergency workload
stop only from the clean main-clone repository root with `.kube/config` as the authorized
administrator credential.

The bootstrap recipe independently requires the local source to match deployed
`origin/main` and the Flux artifact revision. Worktree-scoped credentials cannot satisfy
its write boundary.

## Author the encrypted credential

Use the same permanent qBittorrent WebUI username and password that the media
integrations use. Enter both through hidden or non-echoing prompts and run the guarded
writer:

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

The writer validates the repository's SOPS setup, writes only
`kubernetes/apps/media/qbit-manage/app/qbit-manage-secret.sops.yaml`, and checks that
the plaintext inputs do not appear in the resulting file. Inspect the path and commit
only the ciphertext through the normal reviewed Git workflow. Do not continue to the
live bootstrap from this linked worktree.

## Bootstrap a fresh or rebuilt deployment

The bootstrap recipe requires the deployed source to be current `origin/main` and the
qbit_manage Flux Kustomization to have `spec.suspend: true` in both Git and the live
cluster. For a fresh deployment or deliberate rebuild, first prepare Git from the
assigned feature worktree:

1. Create the encrypted qbit_manage Secret above.
2. Set `spec.suspend: true` in
   `kubernetes/apps/media/qbit-manage/ks.yaml`.
3. Run the source check, then commit, push the feature branch, and complete the pull
   request and merge:

   ```bash
   mise exec -- just kube qbit-manage-validate
   ```

Stop in the feature worktree. After the merged source is deployed with the Flux
Kustomization suspended, continue from the authorized main clone:

4. Update the clean main clone to the exact merged `origin/main` commit. Confirm
   qBittorrent uses its permanent WebUI credential and passes:

   ```bash
   mise exec -- just kube qbittorrent-verify
   ```

5. Start the attended guarded bootstrap with the main clone's administrator kubeconfig:

   ```bash
   export QBIT_MANAGE_BOOTSTRAP_CONFIRM='bootstrap:media:qbit-manage'
   mise exec -- just bootstrap qbit-manage
   unset QBIT_MANAGE_BOOTSTRAP_CONFIRM
   ```

The recipe confirms the Git origin and deployed-source boundary, requires the suspended
state, resumes and reconciles qbit_manage, waits for readiness, and runs
`qbit-manage-verify`. If a resumed deployment fails, its exit trap re-suspends the
Kustomization while preserving resources. Suspension alone is not workload containment:
the preserved `media/deployment/qbit-manage` can continue its 15-minute loop.

This bootstrap applies the current active policy. Do not interpret any obsolete recipe
message about an inert dry run as the current contract. Attend the first run, inspect
only sanitized local logs, and stop the running workload if classification or cleanup is
unexpected. The approved stop requires the operator to suspend both the Flux
top-level owner `flux-system` and its `cluster-apps` child before suspending the
qbit_manage Kustomization and HelmRelease, then scale
`media/deployment/qbit-manage` to zero and verify that no matching Pod remains. The
procedure waits for each controller to observe its suspended generation before moving
down the ownership chain. Suspending the two owners freezes the top-level GitOps apply
path and reconciliation of every application child definition, so this broad-impact
window must last only until the reviewed Git change makes the qbit_manage child
suspension persistent. Follow
[Recover a qbit_manage mistaken clean](../runbooks/recovery.md#recover-a-qbit_manage-mistaken-clean)
for the exact pinned commands.

6. After the guarded verification succeeds, return to the assigned feature worktree and
   set `spec.suspend: false` through a separate reviewed Git change. After that change
   merges and Flux reconciles it, use the authorized main clone to run:

   ```bash
   mise exec -- just kube qbit-manage-verify
   ```

Do not publish qbit_manage logs. They can contain torrent names, tracker URLs, and other
private activity. Do not replace the guarded bootstrap with raw `flux` or `kubectl`
commands. The emergency stop commands in the recovery runbook are a separate,
operator-authorized containment procedure.

## Failure and credential repair

An authentication failure normally means the encrypted Secret does not match the
permanent qBittorrent WebUI credential. The bootstrap trap re-suspends reconciliation,
but it does not stop a preserved Deployment. If policy execution must be contained,
complete the operator-run workload-stop procedure in the recovery runbook. That
procedure temporarily suspends the top-level `flux-system` Kustomization and then
`cluster-apps` before stopping the child reconcilers and workload. It records the
qbit_manage child suspension through Git, safely resumes the ownership chain, and
verifies that qbit_manage remains at zero active Pods. If the reviewed suspension cannot
merge, the operator must keep the broad GitOps freeze in place and escalate instead of
resuming either owner.

Recreate the ciphertext in the assigned feature worktree, publish the correction through
Git, and keep the Git Kustomization suspended. Resume and reconcile only by running the
guarded bootstrap from the authorized main clone after the corrected state is merged and
deployed. Do not use a direct `flux resume` or scale-up command.

If the policy cleaned a torrent by mistake, keep qBittorrent running and follow
[Recover a qbit_manage mistaken clean](../runbooks/recovery.md#recover-a-qbit_manage-mistaken-clean)
before the seven-day recycle window expires.
