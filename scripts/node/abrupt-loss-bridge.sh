#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/lease.sh
source scripts/lib/node-lifecycle-state.sh
source scripts/node/common.sh
source scripts/node/lifecycle.sh

[[ "$#" -eq 5 ]] || {
  echo 'Usage: abrupt-loss-bridge.sh <contain|recover> <node> <kubeconfig> <talosconfig> <lease-holder>' >&2
  exit 2
}

action="$1"
requested_node="$2"
kubeconfig="$3"
talosconfig="$4"
holder="$5"
record='{"schemaVersion":1,"kind":"abrupt-loss"}'

require_operator_checkout
resolve_node_target "$requested_node"
verify_test_lease_holder "$kubeconfig" "$holder"

case "$action" in
  contain)
    # The resilience controller proves genuine unprepared loss before this mutation.
    assert_no_active_lifecycle_records "$kubeconfig"
    persist_node_containment "$kubeconfig" "$NODE_NAME" "$record"
    ;;
  recover)
    assert_cluster_disruption_admissible "$kubeconfig" "$NODE_NAME"
    [[ "$(read_node_lifecycle_record "$kubeconfig" "$NODE_NAME")" == "$record" ]]
    run_maintenance_exit_transaction "$kubeconfig" "$talosconfig" "$NODE_NAME" \
      "$NODE_IP" "$holder" "$record"
    ;;
  *)
    echo "Unsupported abrupt-loss bridge action: $action" >&2
    exit 2
    ;;
esac
