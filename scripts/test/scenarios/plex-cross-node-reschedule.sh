#!/usr/bin/env bash
# Plex controlled CROSS-NODE RESCHEDULE resilience scenario (follow-up item 7a).
# DESTRUCTIVE: cordons the node hosting Plex and deletes the Plex pod so it reschedules
# onto another node, proving stateful recovery across the move:
#
#   - the Longhorn RWOP config volume detaches from node A and ATTACHES on node B
#     (proven directly via the Longhorn volume .status.currentNodeID, not just PVC Bound),
#   - a run-specific marker written to /config survives the move (data round-trip),
#   - the SMB media-data share re-mounts on node B (a known path is present),
#   - Plex returns Ready on a DIFFERENT node.
#
# This is a controlled cross-node reschedule under node cordon, NOT `kubectl drain`
# (the true node-away/lifecycle case is item 7b). It cordons ONLY the node it targets and
# restores exactly that node's prior schedulable state — it never uncordon-alls, so an
# operator's pre-existing cordon on another node is left untouched.
#
# An orchestrator (an experiment), so it lives under scripts/test/scenarios/. Invoked by
# the thin Chainsaw resilience scenario; also runnable directly. Recovery/cleanup outcomes
# are recorded separately from the primary assertion (recovery.json).
set -euo pipefail

[[ "$#" -eq 1 ]] || { echo 'Usage: plex-cross-node-reschedule.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
repo_root="$(git rev-parse --show-toplevel)"
ns='media'
selector='app.kubernetes.io/name=plex'
target='plex-cross-node-reschedule'
ready_timeout_s="${PLEX_RESCHEDULE_TIMEOUT_S:-300}"
smb_known_path='/Volumes/Prometheus/media'

# Guard step 2: re-invoke the chaos guard before any mutation.
"$repo_root/scripts/test/safety/require-chaos-confirmation.sh" "$target"

run_dir="${HOMELAB_TEST_RUN_DIR:-}"
if [[ -z "$run_dir" ]]; then
  mkdir -p "$repo_root/.test-results"
  run_dir="$(mktemp -d "$repo_root/.test-results/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=12 HEAD)-plex-reschedule.XXXXXX")"
fi
run_id="$(basename "$run_dir" | tr -cd 'A-Za-z0-9')"
marker="/config/.cross-node-reschedule-probe-${run_id}"
token="reschedule-${run_id}-$$"
# recovery.json carries cleanup + recovery outcomes, SEPARATE from the primary assertion.
write_recovery() { printf '{"status":"%s","reason":"%s"}\n' "$1" "$2" >"$run_dir/recovery.json"; }
write_recovery 'not-attempted' 'orchestrator started'

k() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" "$@"; }
kc() { kubectl --kubeconfig "$kubeconfig" "$@"; }
find_pod() { k get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
app_exec() { k exec "$1" -c app -- "${@:2}"; }
pod_ready() { k get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
node_schedulable() { [[ "$(kc get node "$1" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)" != 'true' ]]; }
node_ready() { [[ "$(kc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]]; }

fail_precondition() { echo "PRECONDITION FAILED: $1" >&2; write_recovery 'not-required' 'aborted at precondition; nothing mutated'; exit 3; }

# --- preconditions (abort BEFORE cordoning; classify as precondition/infra, exit 3) ------
pod="$(find_pod)"
[[ -n "$pod" ]] || fail_precondition 'no Plex pod found (is Phase 11 bootstrapped?)'
[[ "$(pod_ready "$pod")" == 'True' ]] || fail_precondition "Plex pod $pod is not Ready before the test"
orig_node="$(k get pod "$pod" -o jsonpath='{.spec.nodeName}')"
[[ -n "$orig_node" ]] || fail_precondition 'could not determine Plex node'
node_schedulable "$orig_node" || fail_precondition "Plex node $orig_node is already cordoned; refusing to touch operator-managed cordon state"

pre_volume="$(k get pvc plex -o jsonpath='{.spec.volumeName}')"
[[ -n "$pre_volume" && "$(k get pvc plex -o jsonpath='{.status.phase}')" == 'Bound' ]] || fail_precondition 'config PVC plex is not Bound'
lh_state="$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.state}' 2>/dev/null || true)"
lh_robust="$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.robustness}' 2>/dev/null || true)"
[[ "$lh_state" == 'attached' && "$lh_robust" == 'healthy' ]] || fail_precondition "Longhorn volume $pre_volume not attached+healthy ($lh_state/$lh_robust)"

app_exec "$pod" sh -c "test -d '$smb_known_path'" || fail_precondition "SMB known path $smb_known_path not present before the test"
app_exec "$pod" sh -c "printf '%s' '$token' > '$marker' && sync" >/dev/null || fail_precondition 'could not write the persistence marker'
[[ "$(app_exec "$pod" sh -c "cat '$marker' 2>/dev/null" | tr -d '\r\n')" == "$token" ]] || fail_precondition 'marker read-back mismatch before the test'

# A genuinely eligible landing node: some OTHER node Ready AND schedulable (Plex has no
# nodeSelector/affinity/tolerations, so Ready+schedulable is sufficient eligibility).
eligible=false
while IFS= read -r n; do
  [[ -n "$n" && "$n" != "$orig_node" ]] || continue
  if node_ready "$n" && node_schedulable "$n"; then eligible=true; break; fi
done < <(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ "$eligible" == true ]] || fail_precondition 'no other Ready+schedulable node to reschedule Plex onto'

old_uid="$(k get pod "$pod" -o jsonpath='{.metadata.uid}')"
echo "Preconditions OK: Plex $pod Ready on $orig_node; PVC plex=$pre_volume attached on $(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.currentNodeID}'); SMB + marker OK; eligible landing node exists."

# --- disrupt: cordon ONLY our node + delete the pod --------------------------------------
cordoned_by_us=false
cleanup() {
  # cleanup (marker) + recovery (uncordon only our node, wait healthy) — recorded separately.
  local cleanup_ok=true recovery_ok=true cur
  cur="$(find_pod || true)"
  [[ -n "$cur" ]] && app_exec "$cur" sh -c "rm -f '$marker'" >/dev/null 2>&1 || true
  if [[ "$cordoned_by_us" == true ]]; then
    kc uncordon "$orig_node" >/dev/null 2>&1 && rm -f "$run_dir/cordoned-node" || cleanup_ok=false
  fi
  if kc -n "$ns" rollout status deployment/plex --timeout="${ready_timeout_s}s" >/dev/null 2>&1; then :; else recovery_ok=false; fi
  if [[ "$passed" == true ]]; then
    if [[ "$cleanup_ok" == true && "$recovery_ok" == true ]]; then write_recovery 'passed' 'marker removed, test node uncordoned, Plex healthy'
    else write_recovery 'failed' "cleanup_ok=$cleanup_ok recovery_ok=$recovery_ok"; fi
  fi
}
passed=false
trap cleanup EXIT

echo "Cordoning ONLY $orig_node and deleting Plex pod $pod to force a cross-node move."
kc cordon "$orig_node" >/dev/null
cordoned_by_us=true
# Record exactly which node we cordoned so the Chainsaw finally can restore ONLY it, even
# if this orchestrator is SIGKILLed (timeout) before its EXIT trap runs. Never uncordon-all.
printf '%s\n' "$orig_node" >"$run_dir/cordoned-node"
k delete pod "$pod" --wait=false >/dev/null 2>&1 || true

# --- wait for the replacement on a DIFFERENT node ---------------------------------------
newpod=''; new_node=''
deadline=$(( $(date +%s) + ready_timeout_s ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  cur="$(find_pod)"
  if [[ -n "$cur" && "$cur" != "$pod" ]]; then
    cur_uid="$(k get pod "$cur" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    if [[ -n "$cur_uid" && "$cur_uid" != "$old_uid" ]]; then
      newpod="$cur"
      [[ "$(pod_ready "$newpod")" == 'True' ]] && { new_node="$(k get pod "$newpod" -o jsonpath='{.spec.nodeName}')"; break; }
    fi
  fi
  sleep 5
done
[[ -n "$newpod" && "$(pod_ready "$newpod")" == 'True' ]] || { echo "Plex did not become Ready on a replacement pod within ${ready_timeout_s}s." >&2; exit 1; }

# --- PRIMARY assertions -----------------------------------------------------------------
[[ "$new_node" != "$orig_node" ]] || { echo "Plex rescheduled onto the SAME node $orig_node; expected a different node." >&2; exit 1; }
post_volume="$(k get pvc plex -o jsonpath='{.spec.volumeName}')"
[[ "$post_volume" == "$pre_volume" && "$(k get pvc plex -o jsonpath='{.status.phase}')" == 'Bound' ]] || { echo "Config PVC changed volume or not Bound ($pre_volume -> $post_volume)." >&2; exit 1; }
lh_current="$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.currentNodeID}' 2>/dev/null || true)"
lh_state="$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.state}' 2>/dev/null || true)"
lh_robust="$(kc -n longhorn-system get volumes.longhorn.io "$pre_volume" -o jsonpath='{.status.robustness}' 2>/dev/null || true)"
[[ "$lh_current" == "$new_node" && "$lh_state" == 'attached' ]] || { echo "Longhorn volume did not attach on the landing node (currentNodeID=$lh_current state=$lh_state, expected $new_node/attached)." >&2; exit 1; }
[[ "$lh_robust" == 'healthy' ]] || echo "Warning: Longhorn robustness is '$lh_robust' (may be rebuilding); attachment on $lh_current confirmed." >&2
marker_after="$(app_exec "$newpod" sh -c "cat '$marker' 2>/dev/null" | tr -d '\r\n' || true)"
[[ "$marker_after" == "$token" ]] || { echo "Persistence marker missing/changed after the move (got '$marker_after')." >&2; exit 1; }
app_exec "$newpod" sh -c "test -d '$smb_known_path'" || { echo "SMB known path $smb_known_path not present after the move (share did not re-mount)." >&2; exit 1; }
echo "PRIMARY OK: Plex moved $orig_node -> $new_node; PVC $pre_volume Bound + Longhorn attached on $new_node; marker survived; SMB re-mounted."

# --- advisory (not a gate): replica distribution -----------------------------------------
replica_nodes="$(kc -n longhorn-system get replicas.longhorn.io --selector "longhornvolume=$pre_volume" -o json 2>/dev/null | yq -r '[.items[].spec.nodeID] | unique | length' 2>/dev/null || echo unknown)"
echo "Advisory: config volume replicas currently span ${replica_nodes} node(s) (redistribution may lag; not gated)."

# --- evidence (primary observations) -----------------------------------------------------
RUN_TARGET="$target" OLD_POD="$pod" NEW_POD="$newpod" ORIG_NODE="$orig_node" NEW_NODE="$new_node" \
PRE_VOL="$pre_volume" POST_VOL="$post_volume" LH_CURRENT="$lh_current" LH_STATE="$lh_state" LH_ROBUST="$lh_robust" \
REPLICA_NODES="$replica_nodes" \
  yq --null-input --output-format json '{
    "target": strenv(RUN_TARGET),
    "movedToDifferentNode": (strenv(ORIG_NODE) != strenv(NEW_NODE)),
    "origNode": strenv(ORIG_NODE), "newNode": strenv(NEW_NODE),
    "oldPod": strenv(OLD_POD), "newPod": strenv(NEW_POD),
    "persistence": {"preVolume": strenv(PRE_VOL), "postVolume": strenv(POST_VOL), "sameVolume": (strenv(PRE_VOL) == strenv(POST_VOL))},
    "longhorn": {"currentNodeID": strenv(LH_CURRENT), "attachedToLandingNode": (strenv(LH_CURRENT) == strenv(NEW_NODE)), "state": strenv(LH_STATE), "robustness": strenv(LH_ROBUST)},
    "replicaNodeSpread": strenv(REPLICA_NODES)
  }' >"$run_dir/evidence.json"

passed=true
echo "PASS: Plex survived a cross-node reschedule ($orig_node -> $new_node) — config volume re-attached on the landing node, data + SMB intact. Evidence: $run_dir"
