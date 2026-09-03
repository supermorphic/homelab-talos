#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/lease.sh
source scripts/lib/node-lifecycle-state.sh
source scripts/node/common.sh

resize_just() {
  "${NODE_JUST:-just}" "$@"
}

run_resize_longhorn_transaction() {
  local kubeconfig="$1"
  local node="$2"
  local holder="$3"
  verify_test_lease_holder "$kubeconfig" "$holder" || return 1
  assert_cluster_disruption_admissible "$kubeconfig" || return 1
  resize_just bootstrap _resize-longhorn-raw "$node" || return 1
}

resize_longhorn_main() {
  [[ "$#" -eq 3 ]] || {
    echo 'Usage: resize-longhorn.sh <node> <kubeconfig> <talosconfig>' >&2
    return 2
  }
  local requested_node="$1" kubeconfig="$2" talosconfig="$3"
  local holder renewal_failure temp_dir lease_acquired=false
  resolve_node_target "$requested_node"
  require_operator_checkout
  for required in "$kubeconfig" "$talosconfig" "clusterconfig/${NODE_NAME}.yaml"; do
    [[ -f "$required" ]] || {
      echo "Missing $required; run the documented Talos generation workflow first." >&2
      return 1
    }
  done
  require_exact_confirmation TALOS_RESIZE_LONGHORN_CONFIRM \
    "resize-longhorn:${NODE_NAME}:${NODE_IP}"
  holder="node:resize-longhorn:${NODE_NAME}:$$"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-resize-longhorn.XXXXXX")"
  renewal_failure="$temp_dir/lease-renewal-failed"
  acquire_test_lease "$kubeconfig" "$holder"
  lease_acquired=true
  start_test_lease_renewal "$kubeconfig" "$holder" "$renewal_failure"
  # shellcheck disable=SC2154  # task_exit is assigned inside the trap body.
  trap '
    task_exit=$?
    stop_test_lease_renewal
    if [[ "$lease_acquired" == true ]]; then
      release_test_lease "$kubeconfig" "$holder" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$temp_dir"
    exit "$task_exit"
  ' EXIT INT TERM
  run_resize_longhorn_transaction "$kubeconfig" "$NODE_NAME" "$holder"
  [[ ! -f "$renewal_failure" ]] || {
    echo 'Shared disruption Lease renewal failed during Longhorn resize.' >&2
    return 1
  }
  release_test_lease "$kubeconfig" "$holder"
  lease_acquired=false
  rm -rf -- "$temp_dir"
  trap - EXIT INT TERM
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  resize_longhorn_main "$@"
fi
