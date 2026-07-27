#!/usr/bin/env bash
# Phase helper for the Chainsaw Plex cross-node reschedule resilience test.
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo 'Usage: plex-cross-node-reschedule.sh <prepare|disrupt|observe|assert|recover> <kubeconfig>' >&2
  exit 2
}
phase="$1"
kubeconfig="$2"
repo_root="$(git rev-parse --show-toplevel)"
ns='media'
selector='app.kubernetes.io/name=plex'
target='plex-cross-node-reschedule'
timeout_s="${PLEX_RESCHEDULE_TIMEOUT_S:-300}"
smb_path='/Volumes/Prometheus/media'
run_dir="${HOMELAB_TEST_RUN_DIR:?HOMELAB_TEST_RUN_DIR is required}"
state="$run_dir/diagnostics/plex-cross-node-reschedule-state.json"

k() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" "$@"; }
kc() { kubectl --kubeconfig "$kubeconfig" "$@"; }
find_pod() { k get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
app_exec() { k exec "$1" -c app -- "${@:2}"; }
node_ready() {
  [[ "$(kc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]]
}
node_schedulable() {
  [[ "$(kc get node "$1" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)" != 'true' ]]
}
write_recovery() {
  STATUS="$1" REASON="$2" yq --null-input --output-format json \
    '{"status": strenv(STATUS), "reason": strenv(REASON)}' >"$run_dir/recovery.json"
}
read_state() { yq -r "$1" "$state"; }

case "$phase" in
  prepare)
    "$repo_root/scripts/test/safety/require-chaos-confirmation.sh" "$target"
    write_recovery not-attempted 'scenario prepared; recovery not yet attempted'
    pod="$(find_pod)"
    [[ -n "$pod" ]] || { echo 'No Plex pod found.' >&2; exit 3; }
    [[ "$(k get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == 'True' ]] ||
      { echo 'Plex is not Ready.' >&2; exit 3; }
    orig_node="$(k get pod "$pod" -o jsonpath='{.spec.nodeName}')"
    node_schedulable "$orig_node" || {
      echo "Plex node $orig_node is already cordoned; refusing to alter it." >&2
      exit 3
    }
    pre_volume="$(k get pvc plex -o jsonpath='{.spec.volumeName}')"
    [[ -n "$pre_volume" && "$(k get pvc plex -o jsonpath='{.status.phase}')" == 'Bound' ]]
    [[ "$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.state}')" == 'attached' ]]
    [[ "$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.robustness}')" == 'healthy' ]]
    app_exec "$pod" sh -c "test -d '$smb_path'"
    eligible=false
    while IFS= read -r node; do
      [[ -n "$node" && "$node" != "$orig_node" ]] || continue
      if node_ready "$node" && node_schedulable "$node"; then eligible=true; break; fi
    done < <(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    [[ "$eligible" == 'true' ]] || { echo 'No eligible landing node.' >&2; exit 3; }
    run_id="$(basename "$run_dir" | tr -cd 'A-Za-z0-9')"
    marker="/config/.cross-node-reschedule-probe-${run_id}"
    token="reschedule-${run_id}-$$"
    app_exec "$pod" sh -c "printf '%s' '$token' > '$marker' && sync"
    [[ "$(app_exec "$pod" sh -c "cat '$marker'" | tr -d '\r\n')" == "$token" ]]
    old_uid="$(k get pod "$pod" -o jsonpath='{.metadata.uid}')"
    POD="$pod" OLD_UID="$old_uid" ORIG_NODE="$orig_node" PRE_VOLUME="$pre_volume" \
    MARKER="$marker" TOKEN="$token" yq --null-input --output-format json '{
      "oldPod": strenv(POD),
      "oldUid": strenv(OLD_UID),
      "origNode": strenv(ORIG_NODE),
      "preVolume": strenv(PRE_VOLUME),
      "marker": strenv(MARKER),
      "token": strenv(TOKEN)
    }' >"$state"
    ;;
  disrupt)
    "$repo_root/scripts/test/safety/require-chaos-confirmation.sh" "$target"
    orig_node="$(read_state '.origNode')"
    old_pod="$(read_state '.oldPod')"
    kc cordon "$orig_node"
    printf '%s\n' "$orig_node" >"$run_dir/cordoned-node"
    k delete pod "$old_pod" --wait=false
    ;;
  observe)
    old_uid="$(read_state '.oldUid')"
    orig_node="$(read_state '.origNode')"
    new_pod=''
    new_node=''
    deadline=$((EPOCHSECONDS + timeout_s))
    while [[ "$EPOCHSECONDS" -lt "$deadline" ]]; do
      current="$(find_pod)"
      if [[ -n "$current" ]]; then
        current_uid="$(k get pod "$current" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
        current_ready="$(k get pod "$current" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        if [[ -n "$current_uid" && "$current_uid" != "$old_uid" && "$current_ready" == 'True' ]]; then
          new_pod="$current"
          new_node="$(k get pod "$current" -o jsonpath='{.spec.nodeName}')"
          break
        fi
      fi
      sleep 5
    done
    [[ -n "$new_pod" ]] || { echo 'No Ready replacement Plex pod appeared.' >&2; exit 1; }
    [[ "$new_node" != "$orig_node" ]] || {
      echo "Plex returned to the cordoned node $orig_node." >&2
      exit 1
    }
    NEW_POD="$new_pod" NEW_NODE="$new_node" yq -i '
      .newPod = strenv(NEW_POD) |
      .newNode = strenv(NEW_NODE)
    ' "$state"
    ;;
  assert)
    orig_node="$(read_state '.origNode')"
    pre_volume="$(read_state '.preVolume')"
    marker="$(read_state '.marker')"
    token="$(read_state '.token')"
    new_pod="$(read_state '.newPod')"
    new_node="$(read_state '.newNode')"
    [[ "$new_node" != "$orig_node" ]] || {
      echo "Plex returned to the cordoned node $orig_node." >&2
      exit 1
    }
    post_volume="$(k get pvc plex -o jsonpath='{.spec.volumeName}')"
    [[ "$post_volume" == "$pre_volume" && "$(k get pvc plex -o jsonpath='{.status.phase}')" == 'Bound' ]]
    lh_node="$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.currentNodeID}')"
    lh_state="$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.state}')"
    lh_robustness="$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.robustness}')"
    [[ "$lh_node" == "$new_node" && "$lh_state" == 'attached' ]] || {
      echo "Longhorn attachment is $lh_state on $lh_node, expected attached on $new_node." >&2
      exit 1
    }
    [[ "$(app_exec "$new_pod" sh -c "cat '$marker' 2>/dev/null" | tr -d '\r\n')" == "$token" ]]
    app_exec "$new_pod" sh -c "test -d '$smb_path'"
    POST_VOLUME="$post_volume" \
    LH_NODE="$lh_node" LH_STATE="$lh_state" LH_ROBUSTNESS="$lh_robustness" yq -i '
      .postVolume = strenv(POST_VOLUME) |
      .longhorn = {
        "currentNodeID": strenv(LH_NODE),
        "state": strenv(LH_STATE),
        "robustness": strenv(LH_ROBUSTNESS)
      }
    ' "$state"
    cp "$state" "$run_dir/evidence.json"
    ;;
  recover)
    cleanup_ok=true
    if [[ -f "$run_dir/cordoned-node" ]]; then
      orig_node="$(head -n 1 "$run_dir/cordoned-node")"
      if [[ -n "$orig_node" ]]; then
        kc uncordon "$orig_node" >/dev/null 2>&1 || cleanup_ok=false
      fi
      [[ "$cleanup_ok" != 'true' ]] || rm -f "$run_dir/cordoned-node"
    fi
    k rollout status deployment/plex --timeout="${timeout_s}s" >/dev/null 2>&1 ||
      cleanup_ok=false
    pod="$(find_pod || true)"
    if [[ -f "$state" ]]; then
      marker="$(read_state '.marker')"
      if [[ -n "$pod" ]]; then
        app_exec "$pod" sh -c "rm -f '$marker'" >/dev/null 2>&1 || cleanup_ok=false
      else
        cleanup_ok=false
      fi
    fi
    if [[ "$cleanup_ok" == 'true' ]]; then
      write_recovery passed 'marker removed, test node uncordoned, and Plex healthy'
    else
      write_recovery failed 'marker cleanup, node uncordon, or Plex recovery failed'
      exit 1
    fi
    ;;
  *)
    echo "Unknown phase: $phase" >&2
    exit 2
    ;;
esac
