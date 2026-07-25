#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: metrics-server.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization metrics-server --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'metrics-server Kustomization is not Ready.' >&2
  exit 1
}
kubectl --kubeconfig "$kubeconfig" --namespace kube-system rollout status deployment/metrics-server --timeout=5m

avail=false
for _ in {1..24}; do
  if [[ "$(kubectl --kubeconfig "$kubeconfig" get apiservice v1beta1.metrics.k8s.io --output jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" == 'True' ]]; then
    avail=true
    break
  fi
  sleep 5
done
[[ "$avail" == 'true' ]] || {
  echo 'The metrics.k8s.io APIService is not Available.' >&2
  exit 1
}
kubectl --kubeconfig "$kubeconfig" top nodes >/dev/null 2>&1 || {
  echo 'kubectl top nodes did not return metrics.' >&2
  exit 1
}

echo 'metrics-server acceptance passed: deployment ready, metrics.k8s.io Available, and kubectl top nodes returns data.'
