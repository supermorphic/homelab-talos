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
kc=(kubectl --kubeconfig "$kubeconfig")
cilium_context_args=()
if "${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1; then
  kc+=(--context homelab-diagnostic)
  cilium_context_args=(--context homelab-diagnostic)
fi
expected_names=$'nuc1\nnuc2\nnuc3'
temp_dir="$(mktemp -d /tmp/homelab-talos-cilium-verify.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

assert_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "$label: expected $expected, got ${actual:-<empty>}." >&2
    return 1
  }
}

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run just talos kubeconfig." >&2
  exit 1
}
api_server="$("${kc[@]}" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
assert_equal 'Kubernetes API server' 'https://192.168.90.20:6443' "$api_server"

release_json="$("${kc[@]}" --namespace kube-system \
  get helmrelease cilium --output json)"
source_json="$("${kc[@]}" --namespace kube-system \
  get ocirepository cilium --output json)"
assert_equal 'Cilium HelmRelease Ready status' 'True' \
  "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$release_json")"
assert_equal 'Cilium HelmRelease observed generation' \
  "$(yq -r '.metadata.generation' - <<<"$release_json")" \
  "$(yq -r '.status.observedGeneration' - <<<"$release_json")"
assert_equal 'Cilium Helm chart name' 'cilium' \
  "$(yq -r '.status.history[0].chartName' - <<<"$release_json")"
source_revision="$(yq -r '.status.artifact.revision // ""' - <<<"$source_json")"
[[ "$source_revision" =~ ^1\.19\.6@sha256:([0-9a-f]{64})$ ]] || {
  echo "Cilium OCI source revision has unexpected form: ${source_revision:-<empty>}." >&2
  exit 1
}
expected_chart_version="1.19.6+${BASH_REMATCH[1]:0:12}"
assert_equal 'Cilium Helm chart version' "$expected_chart_version" \
  "$(yq -r '.status.history[0].chartVersion' - <<<"$release_json")"

# The HelmRelease consumes this ConfigMap as its sole valuesFrom source. Ready at the
# observed generation plus exact ConfigMap contents preserves the live values oracle
# without asking Helm to read its Secret-backed release storage.
"${kc[@]}" --namespace kube-system get configmap cilium-values \
  --output go-template='{{ index .data "values.yaml" }}' >"$temp_dir/live-values.yaml"
yq -o=json -I=0 'sort_keys(..)' "$values_file" >"$temp_dir/expected-values.json"
yq -o=json -I=0 'sort_keys(..)' "$temp_dir/live-values.yaml" >"$temp_dir/normalized-live-values.json"
cmp -s "$temp_dir/expected-values.json" "$temp_dir/normalized-live-values.json" || {
  echo "Live Cilium Helm values differ from $values_file." >&2
  diff -u "$temp_dir/expected-values.json" "$temp_dir/normalized-live-values.json" || true
  exit 1
}

nodes_json="$("${kc[@]}" get nodes --output json)"
node_names="$(yq -r '.items[].metadata.name' - <<<"$nodes_json" | sort)"
assert_equal 'Cilium node names' "$expected_names" "$node_names"
node_states="$(yq -r '.items[] | .metadata.name + " " + ([.status.conditions[] | select(.type == "Ready") | .status][0]) + " " + ((.spec.unschedulable // false) | tostring)' - <<<"$nodes_json" | sort)"
assert_equal 'Cilium node readiness and schedulability' \
  $'nuc1 True false\nnuc2 True false\nnuc3 True false' "$node_states"
# shellcheck disable=SC2016  # $name is a yq expression variable, not a shell variable
forbidden_taints="$(yq -r '.items[] | .metadata.name as $name | (.spec.taints // [])[] | select(.effect == "NoSchedule" or .effect == "NoExecute") | $name + " " + .key' - <<<"$nodes_json")"
[[ -z "$forbidden_taints" ]]

daemonset_json="$("${kc[@]}" --namespace kube-system get daemonset cilium --output json)"
assert_equal 'Cilium DaemonSet desired/ready/unavailable' '3 3 0' \
  "$(yq -r '[.status.desiredNumberScheduled, .status.numberReady, (.status.numberUnavailable // 0)] | join(" ")' - <<<"$daemonset_json")"
operator_json="$("${kc[@]}" --namespace kube-system get deployment cilium-operator --output json)"
assert_equal 'Cilium operator desired/available replicas' '2 2' \
  "$(yq -r '[.spec.replicas, .status.availableReplicas] | join(" ")' - <<<"$operator_json")"
relay_json="$("${kc[@]}" --namespace kube-system get deployment hubble-relay --output json)"
assert_equal 'Hubble Relay desired/available replicas' '1 1' \
  "$(yq -r '[.spec.replicas, .status.availableReplicas] | join(" ")' - <<<"$relay_json")"
coredns_json="$("${kc[@]}" --namespace kube-system get deployment coredns --output json)"
coredns_available="$(yq -r '.status.availableReplicas // 0' - <<<"$coredns_json")"
[[ "$coredns_available" -ge 1 ]] || {
  echo "CoreDNS available replicas: expected at least 1, got $coredns_available." >&2
  exit 1
}

kube_proxy="$("${kc[@]}" --namespace kube-system get daemonset kube-proxy --ignore-not-found --output name)"
hubble_ui="$("${kc[@]}" --namespace kube-system get deployment hubble-ui --ignore-not-found --output name)"
cilium_envoy="$("${kc[@]}" --namespace kube-system get daemonset cilium-envoy --ignore-not-found --output name)"
assert_empty "$kube_proxy" 'kube-proxy must remain absent.'
assert_empty "$hubble_ui" 'Hubble UI must remain absent.'
assert_empty "$cilium_envoy" 'The standalone Cilium Envoy DaemonSet must remain absent.'

cilium status \
  --kubeconfig "$kubeconfig" \
  --namespace kube-system \
  "${cilium_context_args[@]}" \
  --wait \
  --wait-duration 10m

cilium_status_json="$(cilium status \
  --kubeconfig "$kubeconfig" \
  --namespace kube-system \
  "${cilium_context_args[@]}" \
  --output json)"
assert_equal 'Hubble Relay Cilium status desired/ready/available/unavailable' '1 1 1 0' \
  "$(yq -r '.pod_state."hubble-relay" | [.Desired, .Ready, .Available, .Unavailable] | join(" ")' - <<<"$cilium_status_json")"
assert_equal 'Cilium agent Hubble states' 'Ok' \
  "$(yq -r '[.cilium_status[].hubble.state] | unique | join(" ")' - <<<"$cilium_status_json")"
assert_equal 'Hubble Relay Cilium errors and warnings' '0' \
  "$(yq -r '.errors."hubble-relay"."hubble-relay" | ((.Errors | length) + (.Warnings | length))' - <<<"$cilium_status_json")"

just kube cilium-postflight

echo 'Cilium read-only verification passed: Cilium 1.19.6, three Ready nodes, healthy DNS and Hubble, expected architecture, Talos, and etcd.'
