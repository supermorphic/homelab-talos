#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: portainer-persistence.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
namespace='portainer'
expected_confirmation='recreate:portainer:pod:preserve-pvc'
host='portainer.lab.supermorphic.com'
gateway_ip="$HOMELAB_GATEWAY_VIP"

[[ "${PORTAINER_PERSISTENCE_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo 'Refusing to recreate the Portainer pod.' >&2
  echo "Set PORTAINER_PERSISTENCE_CONFIRM='$expected_confirmation' after reviewing the target." >&2
  exit 1
}

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get deployment portainer --output jsonpath='{.spec.replicas}')" == '1' ]]
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get persistentvolumeclaim portainer --output jsonpath='{.status.phase}')" == 'Bound' ]]
pvc_uid="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get persistentvolumeclaim portainer --output jsonpath='{.metadata.uid}')"
old_pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pod -l app.kubernetes.io/name=portainer --output jsonpath='{.items[0].metadata.name}')"
old_pod_uid="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pod "$old_pod" --output jsonpath='{.metadata.uid}')"
[[ -n "$pvc_uid" && -n "$old_pod" && -n "$old_pod_uid" ]]

kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete pod "$old_pod" --wait=false
kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" rollout status deployment/portainer --timeout=10m

new_pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pod -l app.kubernetes.io/name=portainer --field-selector=status.phase=Running --output jsonpath='{.items[0].metadata.name}')"
new_pod_uid="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get pod "$new_pod" --output jsonpath='{.metadata.uid}')"
[[ -n "$new_pod_uid" && "$new_pod_uid" != "$old_pod_uid" ]] || {
  echo 'Portainer did not recreate onto a new pod UID.' >&2
  exit 1
}
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get persistentvolumeclaim portainer --output jsonpath='{.metadata.uid}')" == "$pvc_uid" ]] || {
  echo 'Portainer PVC UID changed during pod recreation.' >&2
  exit 1
}

curl --silent --show-error --fail --location \
  --resolve "$host:443:$gateway_ip" "https://$host/" >/dev/null || {
  echo 'Portainer did not recover through the internal Gateway after pod recreation.' >&2
  exit 1
}

echo 'Portainer persistence test passed: a new pod became Ready with the original PVC and the UI recovered.'
