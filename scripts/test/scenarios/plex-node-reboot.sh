#!/usr/bin/env bash
# Plex node-reboot resilience scenario (follow-up item 7b). OPERATOR-RUN, DOUBLE-GATED.
# Reboots the Talos node hosting Plex (via the authoritative `just bootstrap reboot`
# recipe — the node/cluster/etcd/TPM recovery primitive is NOT reimplemented here) and
# proves the WORKLOAD recovers: Plex returns Ready with its Longhorn RWOP config volume
# re-attached (same volumeName, attached) and the SMB media share re-mounted, and a /config
# marker survives.
#
# Responsibility boundary (per review): `just bootstrap reboot` owns the node lifecycle +
# quorum/TPM/etcd/foundation recovery; this scenario owns only the workload-level contract
# + evidence. Two tokens, different purposes: CLUSTER_CHAOS_CONFIRM authorizes THIS
# scenario (checked by the catalog coordinator + re-checked below); TALOS_REBOOT_CONFIRM authorizes
# the reboot primitive and must name the exact node Plex is on.
#
# Unlike 7a there is no cordon to undo — the reboot recipe self-recovers the node.
set -euo pipefail

[[ "$#" -eq 1 ]] || { echo 'Usage: plex-node-reboot.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
ns='media'
selector='app.kubernetes.io/name=plex'
target='plex-node-reboot'
recover_timeout_s="${PLEX_NODE_REBOOT_RECOVER_TIMEOUT_S:-600}"
smb_known_path='/Volumes/Prometheus/media'

# Guard step 2: re-invoke the chaos guard before any mutation.
scripts/test/safety/require-chaos-confirmation.sh "$target"

run_dir="${HOMELAB_TEST_RUN_DIR:-}"
if [[ -z "$run_dir" ]]; then
  mkdir -p "$repo_root/.test-results"
  run_dir="$(mktemp -d "$repo_root/.test-results/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=12 HEAD)-plex-node-reboot.XXXXXX")"
fi
run_id="$(basename "$run_dir" | tr -cd 'A-Za-z0-9')"
marker="/config/.node-reboot-probe-${run_id}"
token="reboot-${run_id}-$$"
write_recovery() { printf '{"status":"%s","reason":"%s"}\n' "$1" "$2" >"$run_dir/recovery.json"; }
write_recovery 'not-attempted' 'orchestrator started'

k() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" "$@"; }
kc() { kubectl --kubeconfig "$kubeconfig" "$@"; }
find_pod() { k get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
app_exec() { k exec "$1" -c app -- "${@:2}"; }
pod_ready() { k get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
lh_field() { kc -n longhorn-system get volumes.longhorn.io "$1" -o jsonpath="{$2}" 2>/dev/null || true; }

fail_precondition() { echo "PRECONDITION FAILED: $1" >&2; write_recovery 'not-required' 'aborted at precondition; nothing rebooted'; exit 3; }

# --- node derivation + reboot-token check (per review: reboot the node Plex is ON) -------
pod="$(find_pod)"
[[ -n "$pod" ]] || fail_precondition 'no Plex pod found (is Phase 11 bootstrapped?)'
[[ "$(pod_ready "$pod")" == 'True' ]] || fail_precondition "Plex pod $pod is not Ready before the test"
orig_node="$(k get pod "$pod" -o jsonpath='{.spec.nodeName}')"
case "$orig_node" in
  nuc1) node_ip='192.168.90.10' ;;
  nuc2) node_ip='192.168.90.11' ;;
  nuc3) node_ip='192.168.90.12' ;;
  *) fail_precondition "Plex is on unexpected node '$orig_node' (expected nuc1/nuc2/nuc3)" ;;
esac
expected_token="reboot:${orig_node}:${node_ip}"
[[ "${TALOS_REBOOT_CONFIRM:-}" == "$expected_token" ]] || fail_precondition \
  "Plex is on ${orig_node}; set TALOS_REBOOT_CONFIRM='${expected_token}' to authorize rebooting that node (review it first)"

# --- preconditions (abort BEFORE reboot; precondition/infra classification) --------------
pre_volume="$(k get pvc plex -o jsonpath='{.spec.volumeName}')"
[[ -n "$pre_volume" && "$(k get pvc plex -o jsonpath='{.status.phase}')" == 'Bound' ]] || fail_precondition 'config PVC plex is not Bound'
[[ "$(lh_field "$pre_volume" .status.state)" == 'attached' && "$(lh_field "$pre_volume" .status.robustness)" == 'healthy' ]] || fail_precondition "Longhorn volume $pre_volume not attached+healthy before the test"
app_exec "$pod" sh -c "test -d '$smb_known_path'" || fail_precondition "SMB known path $smb_known_path not present before the test"
app_exec "$pod" sh -c "printf '%s' '$token' > '$marker' && sync" >/dev/null || fail_precondition 'could not write the persistence marker'
[[ "$(app_exec "$pod" sh -c "cat '$marker' 2>/dev/null" | tr -d '\r\n')" == "$token" ]] || fail_precondition 'marker read-back mismatch before the test'

old_uid="$(k get pod "$pod" -o jsonpath='{.metadata.uid}')"
pre_current="$(lh_field "$pre_volume" .status.currentNodeID)"
echo "Preconditions OK: Plex $pod Ready on $orig_node; PVC plex=$pre_volume attached on $pre_current; SMB + marker OK. Rebooting $orig_node via the authoritative recipe."

# --- reboot (authoritative primitive; node/cluster/etcd/TPM recovery is its job) ---------
passed=false
cleanup() {
  local cleanup_ok=true recovery_ok=true cur
  cur="$(find_pod || true)"
  [[ -n "$cur" ]] && app_exec "$cur" sh -c "rm -f '$marker'" >/dev/null 2>&1 || true
  kc -n "$ns" rollout status deployment/plex --timeout="${recover_timeout_s}s" >/dev/null 2>&1 || recovery_ok=false
  if [[ "$passed" == true ]]; then
    if [[ "$cleanup_ok" == true && "$recovery_ok" == true ]]; then write_recovery 'passed' 'node rebooted+recovered by the recipe; marker removed; Plex healthy'
    else write_recovery 'failed' "cleanup_ok=$cleanup_ok recovery_ok=$recovery_ok"; fi
  fi
}
trap cleanup EXIT

# The recipe re-runs its own pre-reboot health gate + TALOS_REBOOT_CONFIRM check, reboots,
# and blocks until node Ready + Secure Boot/TPM unlock + 3 etcd members + foundation-verify.
mise exec -- just bootstrap reboot "$orig_node"

# --- wait for Plex to recover (its node just returned; the pod restarts) -----------------
newpod=''; new_node=''
deadline=$(( $(date +%s) + recover_timeout_s ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  cur="$(find_pod)"
  if [[ -n "$cur" ]]; then
    [[ "$(pod_ready "$cur")" == 'True' ]] && { newpod="$cur"; new_node="$(k get pod "$cur" -o jsonpath='{.spec.nodeName}')"; break; }
  fi
  sleep 5
done
[[ -n "$newpod" && "$(pod_ready "$newpod")" == 'True' ]] || { echo "Plex did not return to Ready within ${recover_timeout_s}s after the node reboot." >&2; exit 1; }

# --- PRIMARY assertions (workload recovery — NOT a different-node requirement) -----------
new_uid="$(k get pod "$newpod" -o jsonpath='{.metadata.uid}')"
post_volume="$(k get pvc plex -o jsonpath='{.spec.volumeName}')"
[[ "$post_volume" == "$pre_volume" && "$(k get pvc plex -o jsonpath='{.status.phase}')" == 'Bound' ]] || { echo "Config PVC changed volume or not Bound after reboot ($pre_volume -> $post_volume)." >&2; exit 1; }
post_current="$(lh_field "$pre_volume" .status.currentNodeID)"
post_state="$(lh_field "$pre_volume" .status.state)"
post_robust="$(lh_field "$pre_volume" .status.robustness)"
[[ "$post_current" == "$new_node" && "$post_state" == 'attached' ]] || { echo "Longhorn volume not attached on Plex's node after reboot (currentNodeID=$post_current state=$post_state, Plex on $new_node)." >&2; exit 1; }
[[ "$post_robust" == 'healthy' ]] || echo "Warning: Longhorn robustness is '$post_robust' (rebuilding after the node reboot); attachment on $post_current confirmed." >&2
marker_after="$(app_exec "$newpod" sh -c "cat '$marker' 2>/dev/null" | tr -d '\r\n' || true)"
[[ "$marker_after" == "$token" ]] || { echo "Persistence marker missing/changed after reboot (got '$marker_after')." >&2; exit 1; }
app_exec "$newpod" sh -c "test -d '$smb_known_path'" || { echo "SMB known path $smb_known_path not present after reboot (share did not re-mount)." >&2; exit 1; }

same_node=true; [[ "$new_node" != "$orig_node" ]] && same_node=false
echo "PRIMARY OK: Plex recovered Ready on $new_node ($([[ "$same_node" == true ]] && echo 'same node — resumed after reboot' || echo 'rescheduled')); PVC $pre_volume Bound + Longhorn attached on $new_node; marker survived; SMB re-mounted."

# --- evidence ---------------------------------------------------------------------------
RUN_TARGET="$target" REBOOTED_NODE="$orig_node" OLD_POD="$pod" NEW_POD="$newpod" OLD_UID="$old_uid" NEW_UID="$new_uid" \
NEW_NODE="$new_node" SAME_NODE="$same_node" PRE_VOL="$pre_volume" POST_VOL="$post_volume" \
PRE_CUR="$pre_current" POST_CUR="$post_current" POST_STATE="$post_state" POST_ROBUST="$post_robust" \
  yq --null-input --output-format json '{
    "target": strenv(RUN_TARGET),
    "rebootedNode": strenv(REBOOTED_NODE),
    "plex": {"oldPod": strenv(OLD_POD), "newPod": strenv(NEW_POD), "podRestarted": (strenv(OLD_UID) != strenv(NEW_UID)), "landedNode": strenv(NEW_NODE), "sameNode": (strenv(SAME_NODE) == "true")},
    "persistence": {"preVolume": strenv(PRE_VOL), "postVolume": strenv(POST_VOL), "sameVolume": (strenv(PRE_VOL) == strenv(POST_VOL))},
    "longhorn": {"preNodeID": strenv(PRE_CUR), "postNodeID": strenv(POST_CUR), "attachedToPlexNode": (strenv(POST_CUR) == strenv(NEW_NODE)), "state": strenv(POST_STATE), "robustness": strenv(POST_ROBUST)}
  }' >"$run_dir/evidence.json"

passed=true
echo "PASS: $orig_node rebooted (node/cluster recovery by the recipe) and Plex recovered — config volume re-attached, data + SMB intact. Evidence: $run_dir"
