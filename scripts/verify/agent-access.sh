#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo 'Usage: agent-access.sh <kubeconfig> <talosconfig>' >&2
  exit 2
}

kubeconfig="$1"
talosconfig="$2"
observer='homelab-observer'
diagnostic='homelab-diagnostic'
talos_node='192.168.90.10'
talos_endpoints='192.168.90.10,192.168.90.11,192.168.90.12'
kc=(kubectl --kubeconfig "$kubeconfig")

for context in "$observer" "$diagnostic"; do
  "${kc[@]}" config get-contexts "$context" --no-headers >/dev/null 2>&1 || {
    echo "Agent access verification requires kubeconfig context $context." >&2
    exit 1
  }
done

assert_can_i() {
  local context="$1"
  local expected="$2"
  local verb="$3"
  local resource="$4"
  local namespace="${5:-default}"
  local actual
  actual="$("${kc[@]}" --context "$context" auth can-i "$verb" "$resource" \
    --namespace "$namespace")"
  [[ "$actual" == "$expected" ]] || {
    echo "$context: expected '$verb $resource' in $namespace to be $expected, got $actual." >&2
    exit 1
  }
}

# Both scoped contexts must have Kubernetes view, pod logs, and explicit reads for this
# cluster's CRDs. Repeating the complete matrix proves the diagnostic inheritance.
assert_declared_reads() {
  local context="$1"
  assert_can_i "$context" yes get pods kube-system
  assert_can_i "$context" yes list deployments.apps flux-system
  assert_can_i "$context" yes watch statefulsets.apps monitoring
  assert_can_i "$context" yes get pods/log kube-system
  assert_can_i "$context" yes get kustomizations.kustomize.toolkit.fluxcd.io flux-system
  assert_can_i "$context" yes list helmreleases.helm.toolkit.fluxcd.io kube-system
  assert_can_i "$context" yes watch ciliumnetworkpolicies.cilium.io kube-system
  assert_can_i "$context" yes get endpoints.gatus.io monitoring
  assert_can_i "$context" yes list connectors.tailscale.com tailscale
  assert_can_i "$context" yes watch volumes.longhorn.io longhorn-system
  assert_can_i "$context" yes get vulnerabilityreports.aquasecurity.github.io default
  assert_can_i "$context" yes list pods.metrics.k8s.io kube-system
}
assert_declared_reads "$observer"
assert_declared_reads "$diagnostic"

# Observer: Secret bodies, interactive subresources, and mutations stay denied.
assert_can_i "$observer" no get secrets kube-system
assert_can_i "$observer" no create pods/exec kube-system
assert_can_i "$observer" no create pods/portforward kube-system
assert_can_i "$observer" no create configmaps kube-system
assert_can_i "$observer" no patch deployments.apps kube-system
assert_can_i "$observer" no delete deployments.apps kube-system
assert_can_i "$observer" no delete pods kube-system

# Diagnostic adds only exec and port-forward.
assert_can_i "$diagnostic" yes create pods/exec kube-system
assert_can_i "$diagnostic" yes create pods/portforward kube-system
assert_can_i "$diagnostic" no get secrets kube-system
assert_can_i "$diagnostic" no create kustomizations.kustomize.toolkit.fluxcd.io flux-system
assert_can_i "$diagnostic" no patch kustomizations.kustomize.toolkit.fluxcd.io flux-system
assert_can_i "$diagnostic" no delete kustomizations.kustomize.toolkit.fluxcd.io flux-system

[[ -f "$talosconfig" ]] || {
  echo "Agent access verification requires Talos reader config $talosconfig." >&2
  exit 1
}
talosctl version --nodes "$talos_node" --endpoints "$talos_endpoints" \
  --talosconfig "$talosconfig" >/dev/null
talosctl services --nodes "$talos_node" --endpoints "$talos_endpoints" \
  --talosconfig "$talosconfig" >/dev/null

echo 'Agent access verification passed: observer and diagnostic Kubernetes boundaries match, and Talos reader inspection succeeds.'
