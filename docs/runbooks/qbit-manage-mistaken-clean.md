# Recover a qbit_manage mistaken clean

## Trigger

Use this runbook when qbit_manage selected the wrong torrent for cleanup or moved the
wrong download-side data into `/data/downloads/.RecycleBin`. Begin containment
immediately. The recycle bin retains an entry for seven days; after that, do not assume
the download-side name still exists.

The active policy and normal credential/bootstrap workflows are documented in
[Operate qbit_manage](../guides/qbit-manage-operations.md). The exact policy contract is
in the [qbit_manage reference](../reference/qbit-manage.md).

## Immediate safety

- Keep qBittorrent and Gluetun running so unrelated torrents continue to seed.
- Do not rely on Flux suspension alone; it does not stop an existing Deployment.
- Do not widen cleanup exclusions globally or change live policy ad hoc.
- Keep torrent names, tracker URLs, passkeys, download history, and raw logs private.
- Run the administrative containment commands only from the authorized primary checkout.
  Linked-worktree observer or diagnostic credentials do not authorize them.

## Contain qbit_manage and make the stop durable

Use this procedure when qbit_manage removed the wrong torrent and moved its
download-side data into `/data/downloads/.RecycleBin`. The recycle bin keeps that name
for seven days. The organized file below `/data/media` is a separate hardlink name and
remains available to Plex even after the download-side name is removed.

1. From the authorized main clone with its administrator `.kube/config`, stop the full
   ownership chain from the top down. `flux-system/flux-system` applies
   `flux-system/cluster-apps`; `cluster-apps` applies `flux-system/qbit-manage`; and the
   qbit_manage Kustomization applies `media/HelmRelease/qbit-manage`. Suspending only
   `cluster-apps` is unsafe because the active top-level Kustomization can apply its Git
   declaration and remove that manual suspension.

   First suspend `flux-system/flux-system`, which is the top-level Kustomization and owns
   its own Git declaration. This freezes the top-level GitOps apply path. Then suspend
   `cluster-apps`, which freezes reconciliation of every application child definition.
   Existing child Kustomizations and workloads are not stopped by those two suspensions;
   the GitRepository also remains able to fetch a reviewed recovery commit. This is a
   broad cluster-wide GitOps freeze. Keep it as short as the reviewed merge permits, and
   notify the operator responsible for other concurrent reconciliation work.

   A Flux suspension affects subsequent executions, not an execution that already
   started. After each suspension, require `.spec.suspend: true` and wait until the
   controller reports the current `.metadata.generation` in
   `.status.observedGeneration`. Do not continue if a wait fails:

   ```bash
   mise exec -- flux suspend kustomization flux-system \
     --namespace flux-system --kubeconfig .kube/config
   test "$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace flux-system get kustomization flux-system \
     --output jsonpath='{.spec.suspend}')" = true
   flux_system_generation="$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace flux-system get kustomization flux-system \
     --output jsonpath='{.metadata.generation}')"
   mise exec -- kubectl --kubeconfig .kube/config --namespace flux-system \
     wait kustomization/flux-system \
     --for="jsonpath={.status.observedGeneration}=${flux_system_generation}" \
     --timeout=2m

   mise exec -- flux suspend kustomization cluster-apps \
     --namespace flux-system --kubeconfig .kube/config
   test "$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace flux-system get kustomization cluster-apps \
     --output jsonpath='{.spec.suspend}')" = true
   cluster_apps_generation="$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace flux-system get kustomization cluster-apps \
     --output jsonpath='{.metadata.generation}')"
   mise exec -- kubectl --kubeconfig .kube/config --namespace flux-system \
     wait kustomization/cluster-apps \
     --for="jsonpath={.status.observedGeneration}=${cluster_apps_generation}" \
     --timeout=2m

   mise exec -- flux suspend kustomization qbit-manage \
     --namespace flux-system --kubeconfig .kube/config
   test "$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace flux-system get kustomization qbit-manage \
     --output jsonpath='{.spec.suspend}')" = true
   qbit_manage_generation="$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace flux-system get kustomization qbit-manage \
     --output jsonpath='{.metadata.generation}')"
   mise exec -- kubectl --kubeconfig .kube/config --namespace flux-system \
     wait kustomization/qbit-manage \
     --for="jsonpath={.status.observedGeneration}=${qbit_manage_generation}" \
     --timeout=2m

   mise exec -- flux suspend helmrelease qbit-manage \
     --namespace media --kubeconfig .kube/config
   test "$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace media get helmrelease qbit-manage \
     --output jsonpath='{.spec.suspend}')" = true
   qbit_manage_hr_generation="$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace media get helmrelease qbit-manage \
     --output jsonpath='{.metadata.generation}')"
   mise exec -- kubectl --kubeconfig .kube/config --namespace media \
     wait helmrelease/qbit-manage \
     --for="jsonpath={.status.observedGeneration}=${qbit_manage_hr_generation}" \
     --timeout=2m

   mise exec -- kubectl --kubeconfig .kube/config --namespace media \
     scale deployment/qbit-manage --replicas=0

   qbit_manage_pods="$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace media get pod --selector app.kubernetes.io/name=qbit-manage \
     --output name)"
   if test -n "$qbit_manage_pods"; then
     mise exec -- kubectl --kubeconfig .kube/config --namespace media \
       wait --for=delete pod --selector app.kubernetes.io/name=qbit-manage --timeout=2m
   fi

   test "$(mise exec -- kubectl --kubeconfig .kube/config --namespace media \
     get deployment/qbit-manage --output jsonpath='{.spec.replicas}')" = 0
   test -z "$(mise exec -- kubectl --kubeconfig .kube/config --namespace media \
     get pod --selector app.kubernetes.io/name=qbit-manage --output name)"
   ```

   The zero-replica and empty-Pod checks prove that the workload is stopped at that
   point. They do not make containment durable. Keep both owning Kustomizations, the
   qbit_manage child, and its HelmRelease suspended until steps 2 and 3 complete. Keep
   qBittorrent and Gluetun running so unrelated torrents continue to seed. These are
   operator-run administrative actions; never run them with a linked-worktree observer
   or diagnostic credential.
2. In the assigned feature worktree, set `spec.suspend: true` in
   `kubernetes/apps/media/qbit-manage/ks.yaml`. Commit, review, and merge this persistent
   child suspension promptly. Do not run live commands or put the administrator
   kubeconfig in the worktree. Do not resume either owner before the merged source is
   available to Flux; the previous Git state can otherwise reactivate the child.

   If review or merge is blocked, stop here. Keep `flux-system`, `cluster-apps`, the
   qbit_manage child, and its HelmRelease suspended, and keep the Deployment at zero
   replicas. Escalate that broad GitOps reconciliation remains frozen. Do not resume an
   owner as a fallback; restoration requires the reviewed child suspension in the Flux
   source artifact or an explicit operator-directed incident plan.
3. Update the authorized main clone to the exact merged `origin/main` commit. Reconcile
   the Flux source while both owners remain suspended, prove that its artifact contains
   that commit, and recheck every containment oracle before restoring ownership:

   ```bash
   test -z "$(git status --porcelain)"
   test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
   test "$(mise exec -- yq -r '.spec.suspend' \
     kubernetes/apps/media/qbit-manage/ks.yaml)" = true
   expected_revision="$(git rev-parse HEAD)"

   mise exec -- flux reconcile source git flux-system \
     --namespace flux-system --kubeconfig .kube/config
   artifact_revision="$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace flux-system get gitrepository flux-system \
     --output jsonpath='{.status.artifact.revision}')"
   case "$artifact_revision" in
     *"$expected_revision"*) ;;
     *) printf 'Flux artifact does not contain %s\n' "$expected_revision" >&2; false ;;
   esac

   for kustomization in flux-system cluster-apps qbit-manage; do
     test "$(mise exec -- kubectl --kubeconfig .kube/config \
       --namespace flux-system get kustomization "$kustomization" \
       --output jsonpath='{.spec.suspend}')" = true
   done
   test "$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace media get helmrelease qbit-manage \
     --output jsonpath='{.spec.suspend}')" = true
   test "$(mise exec -- kubectl --kubeconfig .kube/config --namespace media \
     get deployment/qbit-manage --output jsonpath='{.spec.replicas}')" = 0
   test -z "$(mise exec -- kubectl --kubeconfig .kube/config --namespace media \
     get pod --selector app.kubernetes.io/name=qbit-manage --output name)"
   ```

   Resume only the top-level `flux-system` Kustomization. For one named resource, the
   pinned Flux CLI waits for the resumed Kustomization to finish applying its current
   source revision. That apply restores the `cluster-apps` declaration from the fetched
   Git artifact. Prove the top-level apply used the expected revision, then explicitly
   resume and reconcile `cluster-apps` so it applies the merged qbit_manage child
   declaration. The qbit_manage child and its HelmRelease remain suspended throughout;
   do not resume either one:

   ```bash
   mise exec -- flux resume kustomization flux-system \
     --namespace flux-system --kubeconfig .kube/config
   top_level_revision="$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace flux-system get kustomization flux-system \
     --output jsonpath='{.status.lastAppliedRevision}')"
   case "$top_level_revision" in
     *"$expected_revision"*) ;;
     *) printf 'flux-system did not apply %s\n' "$expected_revision" >&2; false ;;
   esac

   mise exec -- flux resume kustomization cluster-apps \
     --namespace flux-system --kubeconfig .kube/config
   mise exec -- flux reconcile kustomization cluster-apps \
     --namespace flux-system --kubeconfig .kube/config --timeout 10m
   ```

   If any command fails, repeat step 1 from the top-level suspension and all of its
   oracles. Do not try to recover by suspending only `cluster-apps`.

   After the restoration commands succeed, verify that broad reconciliation recovered
   at the exact fetched revision and that the Git-managed child suspension did not
   restart qbit_manage:

   ```bash
   mise exec -- kubectl --kubeconfig .kube/config --namespace flux-system \
     wait --for=condition=Ready kustomization/flux-system \
     kustomization/cluster-apps --timeout=10m
   for kustomization in flux-system cluster-apps; do
     test "$(mise exec -- kubectl --kubeconfig .kube/config \
       --namespace flux-system get kustomization "$kustomization" \
       --output jsonpath='{.spec.suspend}')" = false
     applied_revision="$(mise exec -- kubectl --kubeconfig .kube/config \
       --namespace flux-system get kustomization "$kustomization" \
       --output jsonpath='{.status.lastAppliedRevision}')"
     case "$applied_revision" in
       *"$expected_revision"*) ;;
       *) printf '%s did not apply %s\n' \
            "$kustomization" "$expected_revision" >&2; false ;;
     esac
   done
   test "$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace flux-system get kustomization qbit-manage \
     --output jsonpath='{.spec.suspend}')" = true
   test "$(mise exec -- kubectl --kubeconfig .kube/config \
     --namespace media get helmrelease qbit-manage \
     --output jsonpath='{.spec.suspend}')" = true
   test "$(mise exec -- kubectl --kubeconfig .kube/config --namespace media \
     get deployment/qbit-manage --output jsonpath='{.spec.replicas}')" = 0
   test -z "$(mise exec -- kubectl --kubeconfig .kube/config --namespace media \
     get pod --selector app.kubernetes.io/name=qbit-manage --output name)"
   ```

   Both owners can now remain active: Git keeps the child suspended, the child cannot
   reconcile the HelmRelease, and the still-suspended HelmRelease cannot restore the
   Deployment. If any check fails, repeat step 1 from the top-level suspension and do
   not claim durable containment.
4. Use the qBittorrent UI and locally inspected qbit_manage logs to identify the exact
   torrent, original download path, and recycle entry. Do not put a torrent name,
   passkey, complete tracker URL, or unsanitized log in Git, chat, or a ticket.
5. Confirm the intended original path does not contain replacement data. Do not
   overwrite or merge directory trees.
6. Within the seven-day window, use an approved guarded operator workflow to move only
   the identified entry from `.RecycleBin` back to its original download path on the
   same SMB filesystem. If no suitable workflow exists, add and review one; do not use
   an ad hoc raw Pod shell.
7. Re-add the authorized torrent to qBittorrent when continued seeding is required.
   Select the original category and restored content path, then force a recheck before
   starting it. Do not download over the recovered data.
8. Correct the classification or cleanup policy through Git before resuming
   qbit_manage. For private content, require `tracker-private` and any dedicated tracker
   tag before another policy run.
9. Verify the torrent checks cleanly, the tracker receives an announce when applicable,
   the organized library file still plays, and unrelated torrents were unchanged.
10. Prepare the recovery source in the assigned feature worktree: keep the Flux
   Kustomization at `spec.suspend: true`, set the HelmRelease to `spec.suspend: false`,
   and include the corrected policy or ciphertext. Merge that state before any live
   resume.
11. Update the authorized main clone to the exact merged commit. Confirm that
    both `flux-system` and `cluster-apps` are active and the qbit_manage child remains
    suspended, then run the guarded bootstrap in
    [Operate qbit_manage](../guides/qbit-manage-operations.md). That workflow
    reconciles the active parent, verifies the child suspension, resumes the child only
    after the corrected merged source is ready, applies the HelmRelease state, recreates
    the Deployment, and runs live verification. Do not directly resume the HelmRelease
    or scale the Deployment up.

If the guarded bootstrap fails, its Kustomization suspension still does not stop a
preserved Deployment. Repeat the complete operator workload-stop sequence above,
starting with temporary top-level `flux-system` suspension. Require the merged child
suspension, safe ownership-chain restoration, and zero active Pods before continuing
recovery.

After seven days, do not assume the recycle entry exists. The organized library
hardlink still survives, but reconstructing a seedable download path becomes a
case-specific operator action. Do not weaken global cleanup safety or copy the entire
library tree back into downloads.

## Verify recovery

Recovery is complete only when:

- `flux-system` and `cluster-apps` are active at the expected merged revision;
- the corrected qbit_manage source is durable in Git;
- the guarded bootstrap and `qbit-manage-verify` succeed;
- the restored torrent passes a forced recheck and can announce when applicable;
- the organized library file still plays;
- unrelated torrents remain unchanged; and
- the first corrected policy run has been attended and selects no unexpected cleanup.

Keep evidence sanitized. A green verifier proves deployment and scheduler health, not
that every torrent decision is semantically correct.

## Escalate

Stop rather than shorten the containment chain when:

- any suspension generation or zero-Pod oracle fails;
- the reviewed durable child suspension cannot be merged;
- the Flux artifact or applied revision does not match the expected commit;
- the recycle entry or original path cannot be identified without ambiguity;
- the original path contains replacement data;
- recovery would require an ad hoc raw Pod shell or broad filesystem move;
- the restored content fails its qBittorrent recheck; or
- the guarded qbit_manage bootstrap fails.

If bootstrap fails after a Deployment was preserved, repeat the complete top-down stop
procedure. Do not assume the child suspension stopped the running workload.
