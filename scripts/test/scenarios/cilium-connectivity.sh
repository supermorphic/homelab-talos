#!/usr/bin/env bash
set -euo pipefail
source scripts/lib/common.sh
source scripts/lib/lease.sh
source scripts/test/lib/owned-resources.sh
require_bash
[[ "$#" -eq 1 ]] || { echo 'Usage: cilium-connectivity.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
[[ -f "$kubeconfig" ]] || { echo "Missing selected invocation config: $kubeconfig." >&2; exit 1; }
[[ "${CILIUM_CONNECTIVITY_CONFIRM:-}" == test:cilium-connectivity ]] || {
  echo "Refusing state-changing Cilium connectivity test; set CILIUM_CONNECTIVITY_CONFIRM='test:cilium-connectivity' after reviewing its cleanup scope." >&2
  exit 1
}
run_id="$(basename "${HOMELAB_TEST_RUN_DIR:?canonical run directory is required}")"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$ ]] || exit 1
holder="${TEST_CAMPAIGN_LEASE_HOLDER:-${HOMELAB_DISRUPTION_LEASE_HOLDER:-}}"
kc=(kubectl --kubeconfig "$kubeconfig")
namespaces=(cilium-test-1 cilium-test-ccnp1 cilium-test-ccnp2)
# Keep the pinned client's own policy finalizers; verify that they start and end
# at an empty fixture baseline rather than deleting an existing global policy.
available_resources="$("${kc[@]}" api-resources --output name)"
global_fixtures=(
  ciliumclusterwidenetworkpolicies.cilium.io/allow-ingress-specific-namespace-ccnp
  ciliumclusterwidenetworkpolicies.cilium.io/allow-egress-specific-namespace-ccnp
  ciliumclusterwidenetworkpolicies.cilium.io/host-firewall-ingress
  ciliumclusterwidenetworkpolicies.cilium.io/host-firewall-egress
  ciliumcidrgroups.cilium.io/cilium-test-external-cidr
  ciliumcidrgroups.cilium.io/cilium-test-external-cidr-label
  ciliumclusterwideenvoyconfigs.cilium.io/client-egress-to-fqdns-proxy-one.one.one.one
  clusternetworkpolicies.policy.networking.k8s.io/echo-ingress-from-client-tiered-wildcard-pass-l7
)
assert_global_baseline() {
  local fixture resource name existing
  for fixture in "${global_fixtures[@]}"; do
    resource="${fixture%%/*}"
    name="${fixture#*/}"
    if ! rg -Fxq "$resource" <<<"$available_resources"; then continue; fi
    existing="$("${kc[@]}" get "$resource" "$name" --ignore-not-found --output json)" || return 1
    [[ -z "$existing" ]] || { echo 'A global connectivity fixture remains; refusing adoption or broad cleanup.' >&2; return 1; }
  done
}
assert_global_baseline
# Existing fixtures are evidence of another or incomplete run; never adopt them.
for namespace in "${namespaces[@]}"; do
  existing="$("${kc[@]}" get namespace "$namespace" --ignore-not-found --output json)"
  [[ -z "$existing" ]] || { echo 'Connectivity namespace already exists; refusing allocation.' >&2; exit 1; }
done
umask 077
diagnostic_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-cilium-connectivity.XXXXXX")"
ledger="$diagnostic_dir/owned.jsonl"
attempted=()
cleanup() {
  local primary="$?" failed=false namespace current uid
  trap - EXIT INT TERM
  for namespace in "${attempted[@]}"; do
    uid="$(jq -sr --arg name "$namespace" '[.[] | select(.kind == "Namespace" and .metadata.name == $name)][0].metadata.uid // ""' "$ledger" 2>/dev/null)" || uid=''
    if [[ -z "$uid" ]]; then
      current="$("${kc[@]}" get namespace "$namespace" --ignore-not-found --output json)" || { failed=true; continue; }
      [[ -z "$current" ]] || failed=true
      continue
    fi
    test_delete_owned "$ledger" Namespace '' "$namespace" "${kc[@]}" || failed=true
  done
  assert_global_baseline || failed=true
  if [[ "$failed" == true ]]; then
    echo 'Connectivity cleanup failed; creation ownership was not broadened.' >&2
    printf '%s\n' '{"status":"failed","reason":"connectivity fixture cleanup"}' >"$HOMELAB_TEST_RUN_DIR/cleanup.json"
    [[ "$primary" -ne 0 ]] || primary=1
  else
    printf '%s\n' '{"status":"passed","reason":"connectivity fixture cleanup"}' >"$HOMELAB_TEST_RUN_DIR/cleanup.json"
  fi
  if [[ "$primary" -eq 0 ]]; then
    just kube cilium-postflight || primary="$?"
  fi
  [[ "$primary" -ne 0 ]] || rm -rf -- "$diagnostic_dir"
  exit "$primary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for namespace in "${namespaces[@]}"; do
  verify_test_lease_holder "$kubeconfig" "$holder"
  jq -n --arg name "$namespace" --arg run "$run_id" '{apiVersion:"v1",kind:"Namespace",metadata:{name:$name,labels:{"app.kubernetes.io/name":"cilium-cli","pod-security.kubernetes.io/enforce":"privileged"},annotations:{"homelab.supermorphic.com/test-run":$run}}}' >"$diagnostic_dir/namespace.json"
  attempted+=("$namespace")
  test_create_owned "$ledger" "$diagnostic_dir/namespace.json" "${kc[@]}"
  namespace_uid="$(jq -sr --arg name "$namespace" '[.[] | select(.kind == "Namespace" and .metadata.name == $name)][0].metadata.uid' "$ledger")"
  current="$("${kc[@]}" get namespace "$namespace" --output json)"
  jq -e --arg uid "$namespace_uid" --arg run "$run_id" '.metadata.uid == $uid and .metadata.annotations["homelab.supermorphic.com/test-run"] == $run and .metadata.deletionTimestamp == null' <<<"$current" >/dev/null
  role='homelab-test-cilium-fixtures-ccnp'
  [[ "$namespace" != cilium-test-1 ]] || role='homelab-test-cilium-fixtures-1'
  jq -n --arg ns "$namespace" --arg uid "$namespace_uid" --arg run "$run_id" --arg role "$role" '{apiVersion:"rbac.authorization.k8s.io/v1",kind:"RoleBinding",metadata:{name:"homelab-test-cilium-fixtures",namespace:$ns,annotations:{"homelab.supermorphic.com/test-run":$run},ownerReferences:[{apiVersion:"v1",kind:"Namespace",name:$ns,uid:$uid}]},roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"ClusterRole",name:$role},subjects:[{kind:"ServiceAccount",name:"homelab-test-cilium-connectivity",namespace:"kube-system"}]}' >"$diagnostic_dir/binding.json"
  verify_test_lease_holder "$kubeconfig" "$holder"
  test_create_owned "$ledger" "$diagnostic_dir/binding.json" "${kc[@]}" --namespace "$namespace"
done
echo "Connectivity-test diagnostics, if required, will remain in $diagnostic_dir."
if cilium connectivity test \
  --kubeconfig "$kubeconfig" \
  --namespace kube-system \
  --test-namespace cilium-test \
  --namespace-labels pod-security.kubernetes.io/enforce=privileged \
  --namespace-annotations "homelab.supermorphic.com/test-run=$run_id" \
  --ip-families ipv4 \
  --hubble=false \
  --flow-validation disabled \
  --test '!no-unexpected-packet-drops' \
  --timeout 45m \
  --sysdump-output-filename "$diagnostic_dir/cilium-sysdump-<ts>" 2>&1 | \
  sed -E 's/(containerID=)[[:xdigit:]]{64}([[:space:]]|$)/\1[redacted]\2/g'; then
  echo 'Cilium connectivity assertions passed; removing owned fixtures and checking postflight.'
else
  primary="$?"
  if ! cilium sysdump --kubeconfig "$kubeconfig" --namespace kube-system \
    --output-filename "$diagnostic_dir/cilium-sysdump-<ts>" 2>&1 | \
    sed -E 's/(containerID=)[[:xdigit:]]{64}([[:space:]]|$)/\1[redacted]\2/g'; then
    echo 'Connectivity diagnostics failed; original test status retained.' >&2
    printf '%s\n' '{"status":"failed","reason":"connectivity diagnostics"}' >"$HOMELAB_TEST_RUN_DIR/diagnostics.json"
  fi
  exit "$primary"
fi
