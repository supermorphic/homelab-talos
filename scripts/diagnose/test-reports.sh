#!/usr/bin/env bash
set -u

[[ "$#" -eq 1 ]] || {
  echo 'Usage: test-reports.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
namespace='test-reports'
selector='app.kubernetes.io/name=test-reports'
status=0

run() {
  "$@" || status=1
}

echo '=== Flux Kustomization ==='
run kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
  get kustomization test-reports --output yaml

echo '=== Workload and storage ==='
run kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get deployment,pods,persistentvolumeclaim --output wide

echo '=== Deployment ==='
run kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  describe deployment test-reports

echo '=== PersistentVolumeClaim ==='
run kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  describe persistentvolumeclaim test-reports

echo '=== Namespace events ==='
run kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get events --sort-by=.lastTimestamp

pods="$(
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get pods --selector "$selector" --output name 2>/dev/null
)" || status=1
if [[ -z "$pods" ]]; then
  echo 'No test-reports pods found.'
else
  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    echo "=== Pod: $pod ==="
    run kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" describe "$pod"
    for container in bootstrap-storage caddy; do
      echo "=== Logs: $pod/$container ==="
      kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
        logs "$pod" --container "$container" --tail=200 2>&1 || true
      echo "=== Previous logs: $pod/$container ==="
      kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
        logs "$pod" --container "$container" --previous --tail=200 2>&1 || true
    done
  done <<<"$pods"
fi

exit "$status"
