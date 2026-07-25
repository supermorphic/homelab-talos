#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: plex-reschedule.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='media'
selector='app.kubernetes.io/name=plex'
cordoned=''
cleanup() {
  if [[ -n "$cordoned" ]]; then
    kubectl --kubeconfig "$kubeconfig" uncordon "$cordoned" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

orig_pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l "$selector" --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$orig_pod" ]] || { echo 'No running Plex pod found.' >&2; exit 1; }
orig_node="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod "$orig_pod" --output jsonpath='{.spec.nodeName}')"
echo "Plex pod $orig_pod is on node $orig_node; cordoning it and deleting the pod to force a reschedule."

kubectl --kubeconfig "$kubeconfig" cordon "$orig_node"
cordoned="$orig_node"
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" delete pod "$orig_pod" --wait=false

ready='False'; new_pod=''; new_node=''
for _ in {1..90}; do
  new_pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l "$selector" --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$new_pod" && "$new_pod" != "$orig_pod" ]]; then
    ready="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod "$new_pod" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)"
    new_node="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod "$new_pod" --output jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    [[ "$ready" == 'True' ]] && break
  fi
  sleep 10
done

kubectl --kubeconfig "$kubeconfig" uncordon "$orig_node"
cordoned=''

[[ "$ready" == 'True' ]] || { echo "Plex did not become Ready on another node after reschedule (pod=$new_pod node=$new_node)." >&2; exit 1; }
[[ "$new_node" != "$orig_node" ]] || { echo "Plex rescheduled onto the same node $orig_node; expected a different NUC." >&2; exit 1; }
echo "Phase 11 Plex reschedule gate passed: pod moved $orig_node -> $new_node, RWOP config re-attached and SMB media re-mounted, Plex Ready."
