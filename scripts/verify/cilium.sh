#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

[[ "$#" -eq 2 ]] || {
  echo 'Usage: cilium.sh <kubeconfig> <cilium_values>' >&2
  exit 2
}

kubeconfig="$1"
values_file="$2"
expected_names=$'nuc1\nnuc2\nnuc3'
temp_dir="$(mktemp -d /tmp/homelab-talos-cilium-verify.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
  exit 1
}
api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
[[ "$api_server" == 'https://192.168.90.20:6443' ]]

release_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system \
  get helmrelease cilium --output json)"
[[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$release_json")" == 'True' ]]
[[ "$(yq -r '.status.observedGeneration' - <<<"$release_json")" == \
  "$(yq -r '.metadata.generation' - <<<"$release_json")" ]]
[[ "$(yq -r '.status.history[0].chartName' - <<<"$release_json")" == 'cilium' ]]
[[ "$(yq -r '.status.history[0].chartVersion' - <<<"$release_json")" == '1.19.6' ]]

# The HelmRelease consumes this ConfigMap as its sole valuesFrom source. Ready at the
# observed generation plus exact ConfigMap contents preserves the live values oracle
# without asking Helm to read its Secret-backed release storage.
kubectl --kubeconfig "$kubeconfig" --namespace kube-system get configmap cilium-values \
  --output go-template='{{ index .data "values.yaml" }}' >"$temp_dir/live-values.yaml"
yq -o=json -I=0 'sort_keys(..)' "$values_file" >"$temp_dir/expected-values.json"
yq -o=json -I=0 'sort_keys(..)' "$temp_dir/live-values.yaml" >"$temp_dir/normalized-live-values.json"
cmp -s "$temp_dir/expected-values.json" "$temp_dir/normalized-live-values.json" || {
  echo "Live Cilium Helm values differ from $values_file." >&2
  diff -u "$temp_dir/expected-values.json" "$temp_dir/normalized-live-values.json" || true
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

kube_proxy="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset kube-proxy --ignore-not-found --output name)"
hubble_ui="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment hubble-ui --ignore-not-found --output name)"
cilium_envoy="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset cilium-envoy --ignore-not-found --output name)"
assert_empty "$kube_proxy" 'kube-proxy must remain absent.'
assert_empty "$hubble_ui" 'Hubble UI must remain absent.'
assert_empty "$cilium_envoy" 'The standalone Cilium Envoy DaemonSet must remain absent.'

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

just kube cilium-postflight

echo 'Phase 5 read-only verification passed: Cilium 1.19.6, three Ready nodes, healthy DNS and Hubble, expected architecture, Talos, and etcd.'
