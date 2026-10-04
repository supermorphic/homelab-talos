#!/usr/bin/env bash
# Atomic, exact-node cordon/uncordon action for resilience controllers.
set -euo pipefail

[[ "$#" -eq 3 ]] || {
  echo 'Usage: node-scheduling.sh <cordon|uncordon> <kubeconfig> <node>' >&2
  exit 2
}
action="$1"
kubeconfig="$2"
node="$3"
[[ "$action" == cordon || "$action" == uncordon ]] || exit 2
[[ "$node" == nuc1 || "$node" == nuc2 || "$node" == nuc3 ]] || exit 2
[[ -f "$kubeconfig" ]] || exit 1
source scripts/lib/lease.sh
current="$(kubectl --kubeconfig "$kubeconfig" get node "$node" --output json)"
jq -e --arg node "$node" '
  .kind == "Node" and .metadata.name == $node and
  (.metadata.uid | type == "string" and length > 0) and
  (.metadata.resourceVersion | type == "string" and length > 0) and
  (.spec | type == "object") and
  (.spec.unschedulable == null or (.spec.unschedulable | type == "boolean"))
' <<<"$current" >/dev/null || exit 1
verify_test_lease_holder "$kubeconfig" \
  "${TEST_CAMPAIGN_LEASE_HOLDER:-${HOMELAB_DISRUPTION_LEASE_HOLDER:-}}" || exit 1
patch="$(jq -ce --arg action "$action" '[
  {op:"test",path:"/metadata/uid",value:.metadata.uid},
  {op:"test",path:"/metadata/resourceVersion",value:.metadata.resourceVersion},
  {op:"add",path:"/spec/unschedulable",value:($action == "cordon")}
]' <<<"$current")"
kubectl --kubeconfig "$kubeconfig" patch node "$node" --type=json --patch "$patch" >/dev/null
