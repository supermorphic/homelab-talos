#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: sonobuoy.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
[[ -f "$kubeconfig" ]] || {
  echo "Missing kubeconfig: $kubeconfig" >&2
  exit 1
}

echo '=== Sonobuoy plugin status ==='
sonobuoy status --kubeconfig "$kubeconfig" || true

echo
echo '=== Sonobuoy workloads ==='
kubectl --kubeconfig "$kubeconfig" --namespace sonobuoy \
  get pods --output wide

echo
echo '=== Recent Sonobuoy events ==='
kubectl --kubeconfig "$kubeconfig" --namespace sonobuoy \
  get events --sort-by=.metadata.creationTimestamp | tail -n 80

echo
echo '=== Sonobuoy pod log tails ==='
while IFS= read -r pod; do
  [[ -n "$pod" ]] || continue
  while IFS= read -r container; do
    [[ -n "$container" ]] || continue
    echo
    echo "--- $pod/$container ---"
    kubectl --kubeconfig "$kubeconfig" --namespace sonobuoy \
      logs "$pod" --container "$container" --tail=120 2>&1 |
      awk 'length($0) > 500 {print substr($0, 1, 500) "...[truncated]"; next} {print}' ||
      true
  done < <(
    kubectl --kubeconfig "$kubeconfig" --namespace sonobuoy \
      get pod "$pod" \
      --output jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}'
  )
done < <(
  kubectl --kubeconfig "$kubeconfig" --namespace sonobuoy \
    get pods --output jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)
