#!/usr/bin/env bash

# Target and authority helpers shared by retained node operations.

# These globals are the validated result consumed by node operation coordinators.
# shellcheck disable=SC2034
NODE_CLUSTER_ENDPOINTS='192.168.90.10,192.168.90.11,192.168.90.12'
# shellcheck disable=SC2034
NODE_NAME=''
# shellcheck disable=SC2034
NODE_IP=''
export NODE_CLUSTER_ENDPOINTS NODE_NAME NODE_IP

resolve_node_target() {
  local requested="$1"
  case "$requested" in
    nuc1) NODE_NAME='nuc1'; NODE_IP='192.168.90.10' ;;
    nuc2) NODE_NAME='nuc2'; NODE_IP='192.168.90.11' ;;
    nuc3) NODE_NAME='nuc3'; NODE_IP='192.168.90.12' ;;
    *)
      echo 'Node must be one of: nuc1, nuc2, nuc3.' >&2
      return 1
      ;;
  esac
}

require_operator_checkout() {
  [[ "${NODE_ALLOW_LINKED_WORKTREE_FOR_TESTS:-}" != 'true' ]] || return 0
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
  local variable="$1"
  local expected="$2"
  [[ "${!variable:-}" == "$expected" ]] || {
    echo "Refusing operation: set $variable='$expected' after reviewing the preflight." >&2
    return 1
  }
}
