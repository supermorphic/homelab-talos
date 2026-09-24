#!/usr/bin/env bash

NODE_CLUSTER_ENDPOINTS=''
NODE_NAME=''
NODE_IP=''
export NODE_CLUSTER_ENDPOINTS NODE_NAME NODE_IP

resolve_cluster_node() {
  local requested="$1" source_file="${2:-talos/talconfig.yaml}" row endpoints
  [[ -f "$source_file" ]] || {
    echo "Missing desired node source: $source_file" >&2
    return 1
  }
  row="$(NODE="$requested" yq -o=json -I=0 '[.nodes[] | select(.controlPlane == true and .hostname == strenv(NODE))]' "$source_file")" || return 1
  [[ "$(yq -r 'length' <<<"$row")" == 1 ]] || {
    echo "Node $requested is not one unique control-plane node in $source_file." >&2
    return 1
  }
  NODE_NAME="$(yq -r '.[0].hostname' <<<"$row")"
  NODE_IP="$(yq -r '.[0].ipAddress' <<<"$row")"
  endpoints="$(yq -r '[.nodes[] | select(.controlPlane == true) | .ipAddress] | join(",")' "$source_file")"
  [[ -n "$NODE_NAME" && -n "$NODE_IP" && "$(tr ',' '\n' <<<"$endpoints" | sort -u | awk 'NF {count++} END {print count + 0}')" == 3 ]] || {
    echo 'Desired source must contain three unique control-plane node addresses.' >&2
    return 1
  }
  NODE_CLUSTER_ENDPOINTS="$endpoints"
  export NODE_CLUSTER_ENDPOINTS NODE_NAME NODE_IP
}

resolve_node_target() {
  resolve_cluster_node "$@"
}

require_operator_checkout() {
  [[ "${NODE_ALLOW_LINKED_WORKTREE_FOR_TESTS:-}" != true ]] || return 0
  local git_dir git_common superproject
  git_dir="$(git rev-parse --path-format=absolute --git-dir)"
  git_common="$(git rev-parse --path-format=absolute --git-common-dir)"
  superproject="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
  if [[ -z "$superproject" && "$git_dir" != "$git_common" ]]; then
    echo 'Refusing node mutation from a linked worktree. Run this operator command from the primary checkout.' >&2
    return 1
  fi
}

require_exact_confirmation() {
  local variable="$1" expected="$2"
  [[ "${!variable:-}" == "$expected" ]] || {
    echo "Refusing operation: set $variable='$expected' after reviewing the preflight." >&2
    return 1
  }
}
