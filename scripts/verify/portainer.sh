#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: portainer.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
namespace='portainer'
host='portainer.lab.supermorphic.com'
gateway_ip='192.168.90.30'
subject='system:serviceaccount:portainer:portainer-readonly'

fail() {
  echo "Portainer verification failed: $*" >&2
  exit 1
}

assert_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '${actual:-<empty>}'."
}

assert_empty() {
  local label="$1"
  local actual="$2"
  [[ -z "$actual" ]] || fail "$label: expected no value, got '$actual'."
}

assert_present() {
  local label="$1"
  local actual="$2"
  [[ -n "$actual" ]] || fail "$label: expected the object to exist."
}

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization portainer --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'Portainer Kustomization is not Ready.' >&2
  exit 1
}
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get helmrelease portainer --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
  echo 'Portainer HelmRelease is not Ready.' >&2
  exit 1
}

kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" rollout status deployment/portainer --timeout=5m
assert_equal 'Deployment strategy' 'Recreate' \
  "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get deployment portainer --output jsonpath='{.spec.strategy.type}')"
assert_equal 'Deployment ServiceAccount' 'portainer-readonly' \
  "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get deployment portainer --output jsonpath='{.spec.template.spec.serviceAccountName}')"
assert_empty 'Phase 1 AGENT_SECRET environment variable' \
  "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get deployment portainer --output jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AGENT_SECRET")].name}')"

assert_equal 'Service type' 'ClusterIP' \
  "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get service portainer --output jsonpath='{.spec.type}')"
service_ports="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get service portainer --output jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' | sort -n | paste -sd, -)"
[[ "$service_ports" == '9000' ]] || {
  echo "Portainer Service exposes unexpected ports: $service_ports" >&2
  exit 1
}

assert_equal 'PVC phase' 'Bound' \
  "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get persistentvolumeclaim portainer --output jsonpath='{.status.phase}')"
assert_equal 'PVC StorageClass' 'longhorn' \
  "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get persistentvolumeclaim portainer --output jsonpath='{.spec.storageClassName}')"
assert_equal 'PVC Helm retention annotation' 'keep' \
  "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get persistentvolumeclaim portainer --output jsonpath='{.metadata.annotations.helm\.sh/resource-policy}')"
assert_present 'administrator bootstrap Secret' \
  "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get secret portainer-admin-password --output name)"

assert_equal 'read-only ClusterRoleBinding roleRef' 'portainer-readonly' \
  "$(kubectl --kubeconfig "$kubeconfig" get clusterrolebinding portainer-readonly --output jsonpath='{.roleRef.name}')"
if kubectl --kubeconfig "$kubeconfig" get clusterrolebinding portainer >/dev/null 2>&1; then
  echo 'Unexpected chart cluster-admin binding clusterrolebinding/portainer exists.' >&2
  exit 1
fi
assert_present 'CiliumNetworkPolicy' \
  "$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get ciliumnetworkpolicy portainer --output name)"

accepted=false
resolved=false
for _ in {1..24}; do
  accepted_status="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get httproute portainer --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  resolved_status="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get httproute portainer --output jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}' 2>/dev/null || true)"
  [[ "$accepted_status" == 'True' ]] && accepted=true
  [[ "$resolved_status" == 'True' ]] && resolved=true
  [[ "$accepted" == 'true' && "$resolved" == 'true' ]] && break
  sleep 5
done
[[ "$accepted" == 'true' && "$resolved" == 'true' ]] || {
  echo 'Portainer HTTPRoute is not Accepted with ResolvedRefs.' >&2
  exit 1
}

[[ "$(dig +short @192.168.90.2 "$host" A | sort -u)" == "$gateway_ip" ]] || {
  echo "DNS for $host does not resolve to $gateway_ip." >&2
  exit 1
}
curl --silent --show-error --fail --location \
  --resolve "$host:443:$gateway_ip" "https://$host/" >/dev/null || {
  echo 'Portainer UI is not reachable through the internal HTTPS Gateway.' >&2
  exit 1
}

assert_can() {
  local verb="$1"
  local resource="$2"
  local target_namespace="${3:-default}"
  [[ "$(kubectl --kubeconfig "$kubeconfig" auth can-i "$verb" "$resource" \
    --namespace "$target_namespace" --as="$subject")" == 'yes' ]] || {
    echo "Expected $subject to be allowed: $verb $resource in $target_namespace." >&2
    exit 1
  }
}

assert_cannot() {
  local verb="$1"
  local resource="$2"
  local target_namespace="${3:-default}"
  [[ "$(kubectl --kubeconfig "$kubeconfig" auth can-i "$verb" "$resource" \
    --namespace "$target_namespace" --as="$subject")" == 'no' ]] || {
    echo "Expected $subject to be denied: $verb $resource in $target_namespace." >&2
    exit 1
  }
}

assert_can get pods
assert_can list deployments.apps
assert_can get pods/log portainer
assert_cannot get secrets portainer
assert_cannot create configmaps portainer
assert_cannot patch deployments.apps portainer
assert_cannot delete pods portainer
assert_cannot create pods/exec portainer
assert_cannot create pods/attach portainer
assert_cannot create pods/portforward portainer

echo 'Portainer Phase 1 acceptance passed: Ready, retained PVC, internal HTTPS, isolated network paths, and effective read-only Kubernetes authorization.'
