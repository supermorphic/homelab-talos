#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: intel-gpu-plugin.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='kube-system'

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization intel-gpu-plugin --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'intel-gpu-plugin Kustomization is not Ready.' >&2
  exit 1
}
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status daemonset/intel-gpu-plugin --timeout=3m

advertised="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json | yq -r '[.items[] | select(.status.allocatable["gpu.intel.com/i915"] != null)] | length')"
[[ "$advertised" -ge 1 ]] || {
  echo 'No node advertises gpu.intel.com/i915 — check /dev/dri on the NUCs (the siderolabs/i915 extension) and the plugin logs.' >&2
  exit 1
}
echo "Intel GPU plugin acceptance passed: Kustomization Ready, DaemonSet rolled out, $advertised node(s) advertise gpu.intel.com/i915."
