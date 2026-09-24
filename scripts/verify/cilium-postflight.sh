#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

[[ "$#" -eq 5 ]] || {
  echo 'Usage: cilium-postflight.sh <kubeconfig> <kube-context> <talosconfig> <talos-context> <endpoints-csv>' >&2
  exit 2
}
kubeconfig="$1"
kube_context="$2"
talosconfig="$3"
talos_context="$4"
nodes_csv="$5"
kc=(kubectl --kubeconfig "$kubeconfig" --context "$kube_context")
tc=(talosctl --talosconfig "$talosconfig" --context "$talos_context")

status=0
IFS=',' read -r -a endpoints <<<"$nodes_csv"
[[ "${#endpoints[@]}" -eq 3 ]] || {
  echo 'Cilium postflight requires exactly three Talos endpoints.' >&2
  exit 1
}
for node_ip in "${endpoints[@]}"; do
  diagnostics="$("${tc[@]}" get diagnostics --nodes "$node_ip" --endpoints "$nodes_csv" --output json)" || {
    status=1
    continue
  }
  [[ -z "$diagnostics" ]] || status=1
done
[[ "$status" -eq 0 ]] || {
  echo 'Talos diagnostics reported a failure.' >&2
  exit 1
}

terminating_namespaces="$("${kc[@]}" get namespaces --output json | yq -r '.items[] | select(.metadata.name | test("^cilium-test")) | select(.metadata.deletionTimestamp != null) | .metadata.name')"
while IFS= read -r namespace; do
  [[ -n "$namespace" ]] || continue
  "${kc[@]}" wait --for=delete "namespace/$namespace" --timeout=2m
done <<<"$terminating_namespaces"
remaining_namespaces="$("${kc[@]}" get namespaces --output json | yq -r '.items[].metadata.name | select(test("^cilium-test"))')"
[[ -z "$remaining_namespaces" ]] || {
  echo "Cilium test namespaces remain: $remaining_namespaces" >&2
  exit 1
}

etcd_status="$("${tc[@]}" etcd status --nodes "$nodes_csv" --endpoints "$nodes_csv")"
[[ "$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$etcd_status")" == 3 ]]
alarm_status="$("${tc[@]}" etcd alarm list --nodes "$nodes_csv" --endpoints "$nodes_csv")"
[[ "$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$alarm_status")" == 0 ]]

echo 'Cilium postflight passed: test resources removed, no Talos diagnostics, three etcd members, and no etcd alarms.'
