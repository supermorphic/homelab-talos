#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: storage.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='longhorn-system'

for n in longhorn longhorn-config; do
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$n" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
    echo "Storage Kustomization $n is not Ready." >&2
    exit 1
  }
done

kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status daemonset/longhorn-manager --timeout=5m

nodes_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get nodes.longhorn.io --output json)"
[[ "$(yq -r '.items | length' - <<<"$nodes_json")" == '3' ]] || { echo 'Expected three Longhorn nodes.' >&2; exit 1; }
ready="$(yq -r '[.items[] | [.status.conditions[] | select(.type == "Ready") | .status][0]] | unique | join(" ")' - <<<"$nodes_json")"
[[ "$ready" == 'True' ]] || { echo "Longhorn nodes are not all Ready ($ready)." >&2; exit 1; }
disk_paths="$(yq -r '[.items[].spec.disks[].path] | unique | join(" ")' - <<<"$nodes_json")"
[[ "$disk_paths" == '/var/mnt/longhorn' ]] || { echo "Longhorn disk path(s) '$disk_paths', expected /var/mnt/longhorn." >&2; exit 1; }

sc="$(kubectl --kubeconfig "$kubeconfig" get storageclass longhorn --output json)"
[[ "$(yq -r '.metadata.annotations."storageclass.kubernetes.io/is-default-class"' - <<<"$sc")" == 'true' ]] || { echo 'longhorn is not the default StorageClass.' >&2; exit 1; }
[[ "$(yq -r '.parameters.numberOfReplicas' - <<<"$sc")" == '2' ]] || { echo 'longhorn StorageClass is not 2 replicas.' >&2; exit 1; }

# The CIFS mount + first poll are eventually consistent, so retry (~4 min).
bt_available=false
for _ in {1..24}; do
  if [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get backuptargets.longhorn.io default --output jsonpath='{.status.available}' 2>/dev/null)" == 'true' ]]; then
    bt_available=true
    break
  fi
  sleep 10
done
[[ "$bt_available" == 'true' ]] || {
  bt_msg="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get backuptargets.longhorn.io default --output jsonpath='{.status.conditions[?(@.type=="Unavailable")].message}' 2>/dev/null)"
  echo "Longhorn backup target is not available after retries: ${bt_msg:-unknown}." >&2
  echo 'Check the CIFS share, the nas-credentials Secret, and whether the Talos nodes can mount CIFS (cifs kernel module).' >&2
  exit 1
}
for j in daily-snapshot daily-backup; do
  kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get recurringjobs.longhorn.io "$j" >/dev/null
done

just kube foundation-verify
echo 'Phase 9 read-only storage verification passed: Longhorn is healthy on three nodes (disks at /var/mnt/longhorn), the default StorageClass has two replicas, the backup target is available, and recurring jobs are present.'
