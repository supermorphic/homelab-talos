#!/usr/bin/env bash
# Atomic marker action for resilience phase controllers.
set -euo pipefail

[[ "$#" -ge 6 ]] || {
  echo 'Usage: pod-marker.sh <create|read|remove> <kubeconfig> <namespace> <pod> <container> <path> [token]' >&2
  exit 2
}

action="$1"
kubeconfig="$2"
namespace="$3"
pod="$4"
container="$5"
path="$6"
token="${7:-}"

name_pattern='^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'
[[ "$namespace" =~ $name_pattern && "$pod" =~ $name_pattern && "$container" =~ $name_pattern ]] || {
  echo 'Unsafe Kubernetes resource name.' >&2
  exit 2
}
[[ "$path" =~ ^/config/\.[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo 'Marker path must be a safe hidden file directly under /config.' >&2
  exit 2
}

case "$action" in
  create)
    [[ -n "$token" ]] || { echo 'create requires a marker token.' >&2; exit 2; }
    # The single-quoted program expands positional parameters in the remote shell.
    # shellcheck disable=SC2016
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      exec "$pod" -c "$container" -- sh -c 'printf %s "$1" >"$2" && sync' sh "$token" "$path"
    ;;
  read)
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      exec "$pod" -c "$container" -- cat "$path"
    ;;
  remove)
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      exec "$pod" -c "$container" -- rm -f "$path"
    ;;
  *)
    echo "Unknown marker action: $action" >&2
    exit 2
    ;;
esac
