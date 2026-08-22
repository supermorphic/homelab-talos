# Configure qbit_manage deployment

Use this guide to create or replace the qbit_manage credential and to start the
application on a fresh cluster or after an intentional rebuild. The current seeding and
cleanup contract is in the [qbit_manage policy reference](../reference/qbit-manage.md).

qbit_manage has no UI or Service. It reads the permanent qBittorrent WebUI credential
from the SOPS-encrypted `qbit-manage-secret`, talks to qBittorrent over the internal
Service, and runs the current policy every 15 minutes. The current policy is active:
`commands.dry_run` is `false`, share limits and classification are enabled, and eligible
public download-side data can move to `.RecycleBin`.

## Authority and worktree boundary

Secret creation and a bootstrap that writes live cluster state are operator-run. Use the
assigned feature worktree, not the primary checkout, because the credential writer
replaces tracked ciphertext in the current worktree. Start at that worktree's repository
root and confirm it is clean before the guarded bootstrap:

```bash
test "$(git rev-parse --show-toplevel)" = "$PWD"
git status --short --branch
```

Keep the qBittorrent credential in the password manager. Never print it, paste it into
chat or a ticket, or commit plaintext. Only the resulting SOPS ciphertext belongs in
Git. The operator retains the age identity; an agent must not request or handle it.

## Create the encrypted credential

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
only the ciphertext through the normal reviewed Git workflow.

## Bootstrap a fresh or rebuilt deployment

The bootstrap recipe requires the deployed source to be current `origin/main` and the
qbit_manage Flux Kustomization to have `spec.suspend: true` in both Git and the live
cluster. For a fresh deployment or deliberate rebuild:

1. Confirm qBittorrent is configured with its permanent WebUI credential and passes
   `mise exec -- just kube qbittorrent-verify`.
2. Create and publish the encrypted qbit_manage Secret above.
3. Set `spec.suspend: true` in
   `kubernetes/apps/media/qbit-manage/ks.yaml` through a reviewed Git change. Wait for
   Flux to reconcile that state.
4. From a clean checkout of the exact deployed source, run the source checks:

   ```bash
   mise exec -- just kube qbit-manage-validate
   mise exec -- just kube qbittorrent-verify
   ```

5. Start the attended guarded bootstrap:

   ```bash
   export QBIT_MANAGE_BOOTSTRAP_CONFIRM='bootstrap:media:qbit-manage'
   mise exec -- just bootstrap qbit-manage
   unset QBIT_MANAGE_BOOTSTRAP_CONFIRM
   ```

The recipe confirms the Git origin and deployed-source boundary, requires the suspended
state, resumes and reconciles qbit_manage, waits for readiness, and runs
`qbit-manage-verify`. If a resumed deployment fails, its exit trap re-suspends the
Kustomization while preserving resources.

This bootstrap applies the current active policy. Do not interpret any obsolete recipe
message about an inert dry run as the current contract. Attend the first run, inspect
only sanitized local logs, and be prepared to pause the application if classification
or cleanup is unexpected.

6. After the guarded verification succeeds, set `spec.suspend: false` through a separate
   reviewed Git change. After Flux reconciles it, run:

   ```bash
   mise exec -- just kube qbit-manage-verify
   ```

Do not publish qbit_manage logs. They can contain torrent names, tracker URLs, and other
private activity. Do not replace the guarded recipe with raw `flux` or `kubectl`
commands.

## Failure and credential repair

An authentication failure normally means the encrypted Secret does not match the
permanent qBittorrent WebUI credential. Keep qbit_manage suspended, recreate the
ciphertext through the guarded writer, publish it through Git, and repeat the guarded
bootstrap from clean deployed source.

If the policy cleaned a torrent by mistake, keep qBittorrent running and follow
[Recover a qbit_manage mistaken clean](../runbooks/recovery.md#recover-a-qbit_manage-mistaken-clean)
before the seven-day recycle window expires.
