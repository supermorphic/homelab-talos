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
service_account_groups=(
  --as-group=system:authenticated
  --as-group=system:serviceaccounts
  --as-group=system:serviceaccounts:kube-system
)

observer_context=false
diagnostic_context=false
"${kc[@]}" config get-contexts "$observer" --no-headers >/dev/null 2>&1 && observer_context=true
"${kc[@]}" config get-contexts "$diagnostic" --no-headers >/dev/null 2>&1 && diagnostic_context=true
if [[ "$observer_context" == true && "$diagnostic_context" == true ]]; then
  credential_layout='named-contexts'
elif [[ "$observer_context" == false && "$diagnostic_context" == false ]]; then
  credential_layout='admin-impersonation'
else
  echo 'Agent access verification requires both scoped contexts or neither.' >&2
  exit 1
fi

assert_can_i() {
  local context="$1"
  local expected="$2"
  local verb="$3"
  local resource="$4"
  local namespace="${5:-default}"
  local -a identity_args
  local actual
  if [[ "$credential_layout" == 'named-contexts' ]]; then
    identity_args=(--context "$context")
  else
    identity_args=(
      --as="system:serviceaccount:kube-system:$context"
      "${service_account_groups[@]}"
    )
  fi
  actual="$("${kc[@]}" "${identity_args[@]}" auth can-i "$verb" "$resource" \
    --namespace "$namespace")"
  [[ "$actual" == "$expected" ]] || {
    echo "$context: expected '$verb $resource' in $namespace to be $expected, got $actual." >&2
    exit 1
  }
}

# Both scoped identities must have Kubernetes view, pod logs, and every explicit read
# required by the scoped verifier campaign. Repeating get/list/watch for every resource
# proves the declared RBAC rule semantics, including all Flux source/notification kinds.
read_resources=(
  customresourcedefinitions.apiextensions.k8s.io
  apiservices.apiregistration.k8s.io
  vulnerabilityreports.aquasecurity.github.io
  certificates.cert-manager.io
  clusterissuers.cert-manager.io
  ciliumclusterwidenetworkpolicies.cilium.io
  ciliumendpoints.cilium.io
  ciliumendpointslices.cilium.io
  ciliumidentities.cilium.io
  ciliumnetworkpolicies.cilium.io
  ciliumnodes.cilium.io
  gatewayclasses.gateway.networking.k8s.io
  gateways.gateway.networking.k8s.io
  httproutes.gateway.networking.k8s.io
  endpoints.gatus.io
  helmreleases.helm.toolkit.fluxcd.io
  kustomizations.kustomize.toolkit.fluxcd.io
  backuptargets.longhorn.io
  nodes.longhorn.io
  recurringjobs.longhorn.io
  volumes.longhorn.io
  ipaddresspools.metallb.io
  nodes.metrics.k8s.io
  pods.metrics.k8s.io
  prometheusrules.monitoring.coreos.com
  servicemonitors.monitoring.coreos.com
  alerts.notification.toolkit.fluxcd.io
  providers.notification.toolkit.fluxcd.io
  receivers.notification.toolkit.fluxcd.io
  clusterrolebindings.rbac.authorization.k8s.io
  clusterroles.rbac.authorization.k8s.io
  rolebindings.rbac.authorization.k8s.io
  roles.rbac.authorization.k8s.io
  buckets.source.toolkit.fluxcd.io
  gitrepositories.source.toolkit.fluxcd.io
  helmcharts.source.toolkit.fluxcd.io
  helmrepositories.source.toolkit.fluxcd.io
  ocirepositories.source.toolkit.fluxcd.io
  csidrivers.storage.k8s.io
  storageclasses.storage.k8s.io
  connectors.tailscale.com
  dnsconfigs.tailscale.com
  proxyclasses.tailscale.com
  proxygroups.tailscale.com
)
assert_declared_reads() {
  local context="$1"
  assert_can_i "$context" yes get pods kube-system
  assert_can_i "$context" yes list deployments.apps flux-system
  assert_can_i "$context" yes watch statefulsets.apps monitoring
  assert_can_i "$context" yes get pods/log kube-system
  local resource verb
  for resource in "${read_resources[@]}"; do
    for verb in get list watch; do
      assert_can_i "$context" yes "$verb" "$resource" kube-system
    done
  done
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
for context in "$observer" "$diagnostic"; do
  assert_can_i "$context" no create rolebindings.rbac.authorization.k8s.io kube-system
  assert_can_i "$context" no bind clusterroles.rbac.authorization.k8s.io kube-system
  assert_can_i "$context" no escalate clusterroles.rbac.authorization.k8s.io kube-system
  assert_can_i "$context" no impersonate users kube-system
done

[[ -f "$talosconfig" ]] || {
  echo "Agent access verification requires Talos reader config $talosconfig." >&2
  exit 1
}
talosctl version --nodes "$talos_node" --endpoints "$talos_endpoints" \
  --talosconfig "$talosconfig" >/dev/null
talosctl services --nodes "$talos_node" --endpoints "$talos_endpoints" \
  --talosconfig "$talosconfig" >/dev/null

echo "Agent access verification passed using $credential_layout: observer and diagnostic Kubernetes boundaries match, and Talos reader inspection succeeds."
