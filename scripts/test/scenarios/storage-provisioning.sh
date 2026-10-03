#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/owned-resources.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: storage-provisioning.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
expected_confirmation='test:storage-provisioning'
namespace='longhorn-system'
pvc="storage-provisioning-${EPOCHSECONDS}-$$"
temp_dir="$(mktemp -d /tmp/homelab-talos-storage-provisioning.XXXXXX)"
ledger="$temp_dir/owned.jsonl"
run_dir="${HOMELAB_TEST_RUN_DIR:-}"
created=false
creation_attempted=false
kc=(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace")

write_phase() {
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 0
  jq -n --arg status "$2" --arg reason "$3" '{status:$status,reason:$reason}' \
    >"$run_dir/$1.json"
}

cleanup() {
  local original_exit="$?" cleanup_ok=true cleanup_status=passed
  trap - EXIT INT TERM
  set +e
  if [[ "$created" == 'true' ]]; then
    test_delete_owned "$ledger" PersistentVolumeClaim "$namespace" "$pvc" \
      "${kc[@]}" || cleanup_ok=false
  elif [[ "$creation_attempted" == true && ! -s "$ledger" ]]; then
    cleanup_ok=false
  fi
  if [[ -s "$ledger" && -n "$run_dir" && -d "$run_dir/diagnostics" ]]; then
    cp "$ledger" "$run_dir/diagnostics/storage-owned.jsonl" || cleanup_ok=false
  fi
  rm -rf -- "$temp_dir" || cleanup_ok=false
  [[ "$cleanup_ok" == true ]] || cleanup_status=failed
  write_phase cleanup "$cleanup_status" 'creation-owned temporary Longhorn claim cleanup' || cleanup_ok=false
  if [[ "$cleanup_ok" != true ]]; then
    echo 'Storage provisioning cleanup failed; no unowned claim was adopted.' >&2
    [[ "$original_exit" != 0 ]] || original_exit=1
  fi
  exit "$original_exit"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f "$kubeconfig" ]] || {
  echo 'Storage provisioning requires the selected invocation config.' >&2
  exit 1
}
[[ "${STORAGE_PROVISIONING_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing state-changing storage provisioning test; set STORAGE_PROVISIONING_CONFIRM='$expected_confirmation' after reviewing its temporary PVC lifecycle." >&2
  exit 1
}

export pvc namespace
yq -n \
  '.apiVersion = "v1" |
   .kind = "PersistentVolumeClaim" |
   .metadata.name = strenv(pvc) |
   .metadata.namespace = strenv(namespace) |
   .metadata.labels."homelab-talos/test" = "storage-provisioning" |
   .spec.accessModes = ["ReadWriteOnce"] |
   .spec.storageClassName = "longhorn" |
   .spec.resources.requests.storage = "1Gi"' >"$temp_dir/pvc.yaml"

creation_attempted=true
test_create_owned "$ledger" "$temp_dir/pvc.yaml" "${kc[@]}"
created=true
kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" wait \
  --for=jsonpath='{.status.phase}'=Bound "pvc/$pvc" --timeout=3m

volume="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pvc "$pvc" --output jsonpath='{.spec.volumeName}')"
replica_nodes=0
for _ in {1..24}; do
  replica_nodes="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get replicas.longhorn.io \
    --selector "longhornvolume=$volume" --output json 2>/dev/null |
    yq -r '[.items[].spec.nodeID] | unique | length')"
  [[ "$replica_nodes" == '2' ]] && break
  sleep 5
done
[[ "$replica_nodes" == '2' ]] || {
  echo "Test volume replicas span $replica_nodes nodes; expected 2 (hard anti-affinity)." >&2
  exit 1
}

write_phase assertion passed 'fresh claim bound with replicas on two distinct nodes'
test_delete_owned "$ledger" PersistentVolumeClaim "$namespace" "$pvc" "${kc[@]}"
created=false
echo 'Storage provisioning test passed: a temporary Longhorn PVC bound and its replicas landed on two distinct nodes.'
