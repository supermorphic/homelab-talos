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
  local namespace="${5:-}"
  local subresource="${6:-}"
  local -a identity_args namespace_args
  local action actual scope status
  if [[ "$credential_layout" == 'named-contexts' ]]; then
    identity_args=(--context "$context")
  else
    identity_args=(
      --as="system:serviceaccount:kube-system:$context"
      "${service_account_groups[@]}"
    )
  fi
  action="$resource"
  if [[ -n "$subresource" ]]; then
    action="$resource/$subresource"
  fi
  namespace_args=(--all-namespaces)
  scope='cluster scope'
  if [[ -n "$namespace" ]]; then
    namespace_args=(--namespace "$namespace")
    scope="namespace $namespace"
  fi
  set +e
  if [[ -n "$subresource" ]]; then
    actual="$("${kc[@]}" "${identity_args[@]}" auth can-i "$verb" "$resource" \
      --subresource "$subresource" "${namespace_args[@]}")"
  else
    actual="$("${kc[@]}" "${identity_args[@]}" auth can-i "$verb" "$resource" \
      "${namespace_args[@]}")"
  fi
  status="$?"
  set -e
  case "$expected:$actual:$status" in
    yes:yes:0|no:no:1) ;;
    *)
      echo "$context: expected '$verb $action' in $scope to be $expected, got ${actual:-no response} (exit $status)." >&2
      exit 1
      ;;
  esac
}

# Both scoped identities must have Kubernetes view, pod logs, and every explicit read
# required by the scoped verifier campaign. Repeating get/list/watch for every resource
# proves the declared RBAC rule semantics, including all Flux source/notification kinds.
cluster_read_resources=(
  nodes
  customresourcedefinitions.apiextensions.k8s.io
  apiservices.apiregistration.k8s.io
  clusterissuers.cert-manager.io
  ciliumclusterwidenetworkpolicies.cilium.io
  ciliumidentities.cilium.io
  ciliumnodes.cilium.io
  gatewayclasses.gateway.networking.k8s.io
  nodes.metrics.k8s.io
  clusterrolebindings.rbac.authorization.k8s.io
  clusterroles.rbac.authorization.k8s.io
  priorityclasses.scheduling.k8s.io
  csidrivers.storage.k8s.io
  storageclasses.storage.k8s.io
  connectors.tailscale.com
  dnsconfigs.tailscale.com
  proxyclasses.tailscale.com
  proxygroups.tailscale.com
)
namespaced_read_resources=(
  vulnerabilityreports.aquasecurity.github.io
  certificates.cert-manager.io
  ciliumendpoints.cilium.io
  ciliumnetworkpolicies.cilium.io
  dnsendpoints.externaldns.k8s.io
  gateways.gateway.networking.k8s.io
  httproutes.gateway.networking.k8s.io
  helmreleases.helm.toolkit.fluxcd.io
  kustomizations.kustomize.toolkit.fluxcd.io
  backuptargets.longhorn.io
  nodes.longhorn.io
  recurringjobs.longhorn.io
  volumes.longhorn.io
  ipaddresspools.metallb.io
  pods.metrics.k8s.io
  prometheusrules.monitoring.coreos.com
  servicemonitors.monitoring.coreos.com
  alerts.notification.toolkit.fluxcd.io
  providers.notification.toolkit.fluxcd.io
  receivers.notification.toolkit.fluxcd.io
  rolebindings.rbac.authorization.k8s.io
  roles.rbac.authorization.k8s.io
  buckets.source.toolkit.fluxcd.io
  gitrepositories.source.toolkit.fluxcd.io
  helmcharts.source.toolkit.fluxcd.io
  helmrepositories.source.toolkit.fluxcd.io
  ocirepositories.source.toolkit.fluxcd.io
)
assert_declared_reads() {
  local context="$1"
  assert_can_i "$context" yes get pods kube-system
  assert_can_i "$context" yes list deployments.apps flux-system
  assert_can_i "$context" yes watch statefulsets.apps monitoring
  assert_can_i "$context" yes get pods kube-system log
  local resource verb
  for resource in "${cluster_read_resources[@]}"; do
    for verb in get list watch; do
      assert_can_i "$context" yes "$verb" "$resource" ''
    done
  done
  for resource in "${namespaced_read_resources[@]}"; do
    for verb in get list watch; do
      assert_can_i "$context" yes "$verb" "$resource" kube-system
    done
  done
}
assert_declared_reads "$observer"
assert_declared_reads "$diagnostic"
for context in "$observer" "$diagnostic"; do
  assert_can_i "$context" yes list dnsendpoints.externaldns.k8s.io ''
  for verb in get list watch; do
    assert_can_i "$context" yes "$verb" referencegrants.gateway.networking.k8s.io automation
  done
done

# Observer: Secret bodies, interactive subresources, and mutations stay denied.
assert_can_i "$observer" no get secrets kube-system
assert_can_i "$observer" no create pods kube-system exec
assert_can_i "$observer" no create pods kube-system portforward
assert_can_i "$observer" no create configmaps kube-system
assert_can_i "$observer" no patch deployments.apps kube-system
assert_can_i "$observer" no delete deployments.apps kube-system
assert_can_i "$observer" no delete pods kube-system

# Diagnostic adds only exec and port-forward.
assert_can_i "$diagnostic" yes create pods kube-system exec
assert_can_i "$diagnostic" yes create pods kube-system portforward
assert_can_i "$diagnostic" no get secrets kube-system
assert_can_i "$diagnostic" no create kustomizations.kustomize.toolkit.fluxcd.io flux-system
assert_can_i "$diagnostic" no patch kustomizations.kustomize.toolkit.fluxcd.io flux-system
assert_can_i "$diagnostic" no delete kustomizations.kustomize.toolkit.fluxcd.io flux-system
for context in "$observer" "$diagnostic"; do
  assert_can_i "$context" no create rolebindings.rbac.authorization.k8s.io kube-system
  assert_can_i "$context" no bind clusterroles.rbac.authorization.k8s.io ''
  assert_can_i "$context" no escalate clusterroles.rbac.authorization.k8s.io ''
  assert_can_i "$context" no impersonate users ''
done

[[ -f "$talosconfig" ]] || {
  echo "Agent access verification requires Talos reader config $talosconfig." >&2
  exit 1
}
talosctl version --nodes "$talos_node" --endpoints "$talos_endpoints" \
  --talosconfig "$talosconfig" >/dev/null || {
  echo 'Talos reader version inspection failed.' >&2
  exit 1
}
talosctl services --nodes "$talos_node" --endpoints "$talos_endpoints" \
  --talosconfig "$talosconfig" >/dev/null || {
  echo 'Talos reader services inspection failed.' >&2
  exit 1
}

echo "Agent access verification passed using $credential_layout: observer and diagnostic Kubernetes boundaries match, and Talos reader inspection succeeds."
