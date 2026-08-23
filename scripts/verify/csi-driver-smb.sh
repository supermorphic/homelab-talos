#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: csi-driver-smb.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='csi-driver-smb'

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization csi-driver-smb --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'csi-driver-smb Kustomization is not Ready.' >&2
  exit 1
}
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/csi-smb-controller --timeout=3m
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status daemonset/csi-smb-node --timeout=3m
kubectl --kubeconfig "$kubeconfig" get csidriver smb.csi.k8s.io >/dev/null || {
  echo 'CSIDriver smb.csi.k8s.io is not registered.' >&2
  exit 1
}
echo 'SMB CSI driver acceptance passed: Kustomization Ready, controller + node plugin rolled out, CSIDriver registered.'
