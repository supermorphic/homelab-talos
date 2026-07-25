#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo 'Usage: cilium.sh <kubeconfig> <cilium_values>' >&2
  exit 2
}

kubeconfig="$1"
values_file="$2"
expected_names=$'nuc1\nnuc2\nnuc3'
diagnostic_dir="$(mktemp -d /tmp/homelab-talos-cilium-test.XXXXXX)"
cleanup() {
  cilium connectivity test \
    --kubeconfig "$kubeconfig" \
    --test-namespace cilium-test \
    --cleanup >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
  exit 1
}
api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
[[ "$api_server" == 'https://192.168.90.20:6443' ]]

release_json="$(helm list --namespace kube-system --kubeconfig "$kubeconfig" --output json)"
[[ "$(yq -r '.[] | select(.name == "cilium") | .status' - <<<"$release_json")" == 'deployed' ]]
[[ "$(yq -r '.[] | select(.name == "cilium") | .chart' - <<<"$release_json")" == 'cilium-1.19.6' ]]

helm get values cilium \
  --namespace kube-system \
  --kubeconfig "$kubeconfig" \
  --output yaml >"$diagnostic_dir/live-values.yaml"
yq -o=json -I=0 'sort_keys(..)' "$values_file" >"$diagnostic_dir/expected-values.json"
yq -o=json -I=0 'sort_keys(..)' "$diagnostic_dir/live-values.yaml" >"$diagnostic_dir/normalized-live-values.json"
cmp -s "$diagnostic_dir/expected-values.json" "$diagnostic_dir/normalized-live-values.json" || {
  echo "Live Cilium Helm values differ from $values_file." >&2
  diff -u "$diagnostic_dir/expected-values.json" "$diagnostic_dir/normalized-live-values.json" || true
  exit 1
}

nodes_json="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json)"
node_names="$(yq -r '.items[].metadata.name' - <<<"$nodes_json" | sort)"
[[ "$node_names" == "$expected_names" ]]
node_states="$(yq -r '.items[] | .metadata.name + " " + ([.status.conditions[] | select(.type == "Ready") | .status][0]) + " " + ((.spec.unschedulable // false) | tostring)' - <<<"$nodes_json" | sort)"
[[ "$node_states" == $'nuc1 True false\nnuc2 True false\nnuc3 True false' ]]
# shellcheck disable=SC2016  # $name is a yq expression variable, not a shell variable
forbidden_taints="$(yq -r '.items[] | .metadata.name as $name | (.spec.taints // [])[] | select(.effect == "NoSchedule" or .effect == "NoExecute") | $name + " " + .key' - <<<"$nodes_json")"
[[ -z "$forbidden_taints" ]]

daemonset_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset cilium --output json)"
[[ "$(yq -r '[.status.desiredNumberScheduled, .status.numberReady, (.status.numberUnavailable // 0)] | join(" ")' - <<<"$daemonset_json")" == '3 3 0' ]]
operator_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment cilium-operator --output json)"
[[ "$(yq -r '[.spec.replicas, .status.availableReplicas] | join(" ")' - <<<"$operator_json")" == '2 2' ]]
relay_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment hubble-relay --output json)"
[[ "$(yq -r '[.spec.replicas, .status.availableReplicas] | join(" ")' - <<<"$relay_json")" == '1 1' ]]
coredns_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment coredns --output json)"
[[ "$(yq -r '.status.availableReplicas // 0' - <<<"$coredns_json")" -ge 1 ]]

# shellcheck disable=SC2251  # preserve original non-gating negation (behavior-preserving extraction)
! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset kube-proxy >/dev/null 2>&1
# shellcheck disable=SC2251  # preserve original non-gating negation (behavior-preserving extraction)
! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment hubble-ui >/dev/null 2>&1
# shellcheck disable=SC2251  # preserve original non-gating negation (behavior-preserving extraction)
! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset cilium-envoy >/dev/null 2>&1

cilium status \
  --kubeconfig "$kubeconfig" \
  --namespace kube-system \
  --wait \
  --wait-duration 10m

cilium_status_json="$(cilium status \
  --kubeconfig "$kubeconfig" \
  --namespace kube-system \
  --output json)"
[[ "$(yq -r '.pod_state."hubble-relay" | [.Desired, .Ready, .Available, .Unavailable] | join(" ")' - <<<"$cilium_status_json")" == '1 1 1 0' ]]
[[ "$(yq -r '[.cilium_status[].hubble.state] | unique | join(" ")' - <<<"$cilium_status_json")" == 'Ok' ]]
[[ "$(yq -r '.errors."hubble-relay"."hubble-relay" | ((.Errors | length) + (.Warnings | length))' - <<<"$cilium_status_json")" == '0' ]]

cleanup
echo "Connectivity-test diagnostics, if required, will remain in $diagnostic_dir."
if ! cilium connectivity test \
  --kubeconfig "$kubeconfig" \
  --namespace kube-system \
  --test-namespace cilium-test \
  --namespace-labels pod-security.kubernetes.io/enforce=privileged \
  --ip-families ipv4 \
  --hubble=false \
  --flow-validation disabled \
  --test '!no-unexpected-packet-drops' \
  --timeout 45m \
  --sysdump-output-filename "$diagnostic_dir/cilium-sysdump-<ts>"; then
  cilium sysdump \
    --kubeconfig "$kubeconfig" \
    --namespace kube-system \
    --output-filename "$diagnostic_dir/cilium-sysdump-<ts>" || true
  exit 1
fi

cleanup
just kube cilium-postflight

trap - EXIT
rm -rf -- "$diagnostic_dir"
echo 'Phase 5 verification passed: Cilium 1.19.6, three Ready nodes, healthy DNS, Hubble, connectivity, Talos, and etcd.'
