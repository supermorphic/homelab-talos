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

[[ "$action" == 'cordon' || "$action" == 'uncordon' ]] || {
  echo "Unknown scheduling action: $action" >&2
  exit 2
}
[[ "$node" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || {
  echo 'Unsafe or empty node name.' >&2
  exit 2
}

kubectl --kubeconfig "$kubeconfig" "$action" "$node"
