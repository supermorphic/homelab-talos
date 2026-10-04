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
publisher='homelab-report-publisher'
coordinator='homelab-campaign-coordinator'
talos_node='192.168.90.10'
talos_endpoints='192.168.90.10,192.168.90.11,192.168.90.12'
runner='homelab-test-runner'
audit_configs=()
declare -A profile_configs
kc=(kubectl)
cleanup_profiles() {
  local status="$?" config
  trap - EXIT
  for config in "${audit_configs[@]}"; do
    uv run --locked python -m scripts.test.access remove "$config" || status=1
  done
  exit "$status"
}
trap cleanup_profiles EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
binding="$(uv run --locked python -m scripts.test.access validate "$kubeconfig")"
jq -e '.suite_id == "verification.agent-access" and (.profile_check | not) and (.purpose | not)'   <<<"$binding" >/dev/null
for profile in observer debugger test-runner report-publisher campaign-coordinator; do
  config="$(uv run --locked python -m scripts.test.access profile-check "$kubeconfig" "$profile")"
  audit_configs=("${audit_configs[@]}" "$config")
  case "$profile" in
    observer) account="$observer" ;;
    debugger) account="$diagnostic" ;;
    test-runner) account="$runner" ;;
    report-publisher) account="$publisher" ;;
    campaign-coordinator) account="$coordinator" ;;
  esac
  profile_configs["$account"]="$config"
  actual="$(kubectl --kubeconfig "$config" auth whoami -o json | jq -er '.status.userInfo.username')"
  [[ "$actual" == "system:serviceaccount:kube-system:$account" ]] || {
    echo "Agent access verification failed the $profile identity check." >&2
    exit 1
  }
done

assert_can_i() {
  local context="$1"
  local expected="$2"
  local verb="$3"
  local resource="$4"
  local namespace="${5:-}"
  local subresource="${6:-}"
  local resource_name="${7:-}"
  local -a identity_args namespace_args
  local action actual scope status resource_arg
  identity_args=(--kubeconfig "${profile_configs[$context]}")
  resource_arg="$resource"
  if [[ -n "$resource_name" ]]; then
    resource_arg="$resource/$resource_name"
  fi
  action="$resource_arg"
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
    actual="$("${kc[@]}" "${identity_args[@]}" auth can-i "$verb" "$resource_arg" \
      --subresource "$subresource" "${namespace_args[@]}")"
  else
    actual="$("${kc[@]}" "${identity_args[@]}" auth can-i "$verb" "$resource_arg" \
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
  persistentvolumes
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
  leases.coordination.k8s.io
  dnsendpoints.externaldns.k8s.io
  gateways.gateway.networking.k8s.io
  httproutes.gateway.networking.k8s.io
  helmreleases.helm.toolkit.fluxcd.io
  kustomizations.kustomize.toolkit.fluxcd.io
  backuptargets.longhorn.io
  nodes.longhorn.io
  recurringjobs.longhorn.io
  replicas.longhorn.io
  settings.longhorn.io
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

# Publisher: only the named report Deployment rollout, report Pods and exec, the
# named Flux source, and the pre-created publication Lease are available.
for verb in get list watch; do
  assert_can_i "$publisher" yes "$verb" deployments.apps test-reports '' test-reports
done
assert_can_i "$publisher" yes get pods test-reports
assert_can_i "$publisher" yes list pods test-reports
assert_can_i "$publisher" yes create pods test-reports exec
assert_can_i "$publisher" yes get gitrepositories.source.toolkit.fluxcd.io \
  flux-system '' flux-system
assert_can_i "$publisher" yes get leases.coordination.k8s.io \
  flux-system '' homelab-test-report-publish-lock
assert_can_i "$publisher" yes update leases.coordination.k8s.io \
  flux-system '' homelab-test-report-publish-lock

assert_can_i "$publisher" no get secrets test-reports
assert_can_i "$publisher" no create pods test-reports portforward
assert_can_i "$publisher" no create pods kube-system exec
assert_can_i "$publisher" no create configmaps test-reports
assert_can_i "$publisher" no patch deployments.apps test-reports '' test-reports
assert_can_i "$publisher" no delete pods test-reports
assert_can_i "$publisher" no list gitrepositories.source.toolkit.fluxcd.io flux-system
assert_can_i "$publisher" no get gitrepositories.source.toolkit.fluxcd.io \
  flux-system '' another-source
assert_can_i "$publisher" no create leases.coordination.k8s.io \
  flux-system '' homelab-test-report-publish-lock
assert_can_i "$publisher" no patch leases.coordination.k8s.io \
  flux-system '' homelab-test-report-publish-lock
assert_can_i "$publisher" no update leases.coordination.k8s.io \
  flux-system '' another-lock
assert_can_i "$publisher" no update leases.coordination.k8s.io flux-system
assert_can_i "$publisher" no bind clusterroles.rbac.authorization.k8s.io ''
assert_can_i "$publisher" no escalate clusterroles.rbac.authorization.k8s.io ''
assert_can_i "$publisher" no impersonate users ''

# Coordinator may only read and renew the pre-created campaign Lease.
for verb in get update; do
  assert_can_i "$coordinator" yes "$verb" leases.coordination.k8s.io flux-system '' homelab-test-run-lock
done
for verb in create patch delete; do
  assert_can_i "$coordinator" no "$verb" leases.coordination.k8s.io flux-system '' homelab-test-run-lock
done
assert_can_i "$coordinator" no update leases.coordination.k8s.io flux-system '' another-lock
assert_can_i "$coordinator" no list leases.coordination.k8s.io flux-system
assert_can_i "$coordinator" no get secrets kube-system
assert_can_i "$coordinator" no get pods kube-system
assert_can_i "$coordinator" no create pods kube-system exec
assert_can_i "$coordinator" no create pods kube-system portforward
assert_can_i "$coordinator" no impersonate users ''
assert_can_i "$coordinator" no bind clusterroles.rbac.authorization.k8s.io ''
assert_can_i "$coordinator" no escalate clusterroles.rbac.authorization.k8s.io ''

# Observer: Secret bodies, interactive subresources, and mutations stay denied.
assert_can_i "$observer" no get secrets kube-system
assert_can_i "$observer" no create pods kube-system exec
assert_can_i "$observer" no create pods kube-system portforward
assert_can_i "$observer" no create configmaps kube-system
assert_can_i "$observer" no patch deployments.apps kube-system
assert_can_i "$observer" no delete deployments.apps kube-system
assert_can_i "$observer" no delete pods kube-system

# Diagnostic interactive access follows the reviewed current caller inventory.
for ns in kube-system media homepage ntfy automation; do
  assert_can_i "$diagnostic" yes create pods "$ns" exec
done
for ns in kube-system media monitoring; do
  assert_can_i "$diagnostic" yes create pods "$ns" portforward
done
for ns in openbao flux-system automation-data longhorn-system; do
  assert_can_i "$diagnostic" no create pods "$ns" exec
  assert_can_i "$diagnostic" no create pods "$ns" portforward
done
assert_can_i "$diagnostic" no create pods monitoring exec
for ns in homepage ntfy automation; do
  assert_can_i "$diagnostic" no create pods "$ns" portforward
done
assert_can_i "$diagnostic" yes create pods automation-data portforward automation-data-postgresql-0
assert_can_i "$diagnostic" no create pods automation-data portforward another-pod
assert_can_i "$observer" no create pods automation-data portforward automation-data-postgresql-0
assert_can_i "$publisher" no create pods automation-data portforward automation-data-postgresql-0
assert_can_i "$diagnostic" no get secrets automation-data
assert_can_i "$diagnostic" no patch statefulsets.apps automation-data
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
  assert_can_i "$context" no patch leases.coordination.k8s.io flux-system
  assert_can_i "$context" no patch replicas.longhorn.io longhorn-system
  assert_can_i "$context" no patch settings.longhorn.io longhorn-system
done

# The generalized runner can allocate its declared fixtures and disrupt Pods,
# but cannot change coordination authority, RBAC, namespaces or read secrets.
assert_can_i "$runner" yes create jobs.batch automation
assert_can_i "$runner" yes get pods automation
assert_can_i "$runner" yes delete pods automation
assert_can_i "$runner" no create namespaces ''
assert_can_i "$runner" no get secrets openbao
assert_can_i "$runner" no update leases.coordination.k8s.io flux-system '' homelab-test-run-lock
assert_can_i "$runner" no create rolebindings.rbac.authorization.k8s.io automation
assert_can_i "$runner" no impersonate users ''

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

echo "Agent access verification passed: observer, debugger, test-runner, report-publisher and coordinator boundaries match, and Talos reader inspection succeeds."
