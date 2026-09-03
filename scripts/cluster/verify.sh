#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo 'Usage: verify.sh <kubeconfig> <talosconfig>' >&2
  exit 2
}

kubeconfig="$1"
talosconfig="$2"
kubectl_bin="${CLUSTER_KUBECTL:-kubectl}"
talosctl_bin="${CLUSTER_TALOSCTL:-talosctl}"
just_bin="${CLUSTER_JUST:-just}"
nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
expected_names=$'nuc1\nnuc2\nnuc3'
expected_endpoints=$'192.168.90.10\n192.168.90.11\n192.168.90.12'

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}
[[ -f "$talosconfig" ]] || {
  echo "Missing $talosconfig." >&2
  exit 1
}

# shellcheck disable=SC2016  # $context is a yq variable.
actual_endpoints="$(yq -r '.context as $context | .contexts[$context].endpoints[]' "$talosconfig" | sort)"
[[ "$actual_endpoints" == "$expected_endpoints" ]] || {
  echo 'Talos client configuration does not name exactly the three cluster endpoints.' >&2
  exit 1
}

nodes_json="$("$kubectl_bin" --kubeconfig "$kubeconfig" get nodes --output json)"
actual_names="$(yq -r '.items[].metadata.name' - <<<"$nodes_json" | sort)"
[[ "$actual_names" == "$expected_names" ]] || {
  echo 'Kubernetes does not contain exactly nuc1, nuc2, and nuc3.' >&2
  exit 1
}
node_states="$(yq -r '
  .items[] |
  .metadata.name + " " +
  ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown") + " " +
  ((.spec.unschedulable // false) | tostring)
' <<<"$nodes_json" | sort)"
[[ "$node_states" == $'nuc1 True false\nnuc2 True false\nnuc3 True false' ]] || {
  printf 'Established Nodes must all be Ready and schedulable:\n%s\n' "$node_states" >&2
  exit 1
}

for node_spec in 'nuc1:192.168.90.10' 'nuc2:192.168.90.11' 'nuc3:192.168.90.12'; do
  node="${node_spec%%:*}"
  node_ip="${node_spec#*:}"
  common=(--nodes "$node_ip" --endpoints "$nodes_csv" --talosconfig "$talosconfig" --output yaml)
  hostname_state="$("$talosctl_bin" get hostname "${common[@]}")"
  [[ "$(yq -r '.spec.hostname' - <<<"$hostname_state")" == "$node" ]] || {
    echo "Talos identity for $node_ip is not $node." >&2
    exit 1
  }
  security_state="$("$talosctl_bin" get securitystate "${common[@]}")"
  [[ "$(yq -r '.spec.secureBoot' - <<<"$security_state")" == 'true' ]]
  [[ "$(yq -r '.spec.bootedWithUKI' - <<<"$security_state")" == 'true' ]]
done

# Cilium verification owns the authoritative Talos diagnostics and etcd postflight.
# Storage verification owns Longhorn and composes the foundation acceptance gate.
"$just_bin" kube cilium-verify
"$just_bin" kube storage-verify

echo 'Established cluster verification passed: Nodes, Talos, etcd, Cilium, Longhorn, and foundation are healthy.'
