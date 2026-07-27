#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
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
created=false
cleanup() {
  if [[ "$created" == 'true' ]]; then
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete pvc "$pvc" \
      --ignore-not-found --wait=true --timeout=2m >/dev/null 2>&1 || true
  fi
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
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

kubectl --kubeconfig "$kubeconfig" create --filename "$temp_dir/pvc.yaml" >/dev/null
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

kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete pvc "$pvc" --wait=true >/dev/null
created=false
echo 'Storage provisioning test passed: a temporary Longhorn PVC bound and its replicas landed on two distinct nodes.'
