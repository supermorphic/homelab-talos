#!/usr/bin/env bash

source scripts/lib/node-lifecycle-state.sh

longhorn_kubectl() {
  local kubeconfig="$1"
  shift
  "${NODE_KUBECTL:-kubectl}" --kubeconfig "$kubeconfig" \
    --namespace longhorn-system "$@"
}

read_longhorn_node() {
  local kubeconfig="$1"
  local node="$2"
  longhorn_kubectl "$kubeconfig" get nodes.longhorn.io "$node" --output json
}

build_maintenance_lifecycle_record() {
  local kubeconfig="$1"
  local node="$2"
  local state allow eviction
  state="$(read_longhorn_node "$kubeconfig" "$node")" || return 1
  allow="$(yq -r '.spec.allowScheduling' - <<<"$state")"
  eviction="$(yq -r '.spec.evictionRequested' - <<<"$state")"
  [[ "$allow" =~ ^(true|false)$ && "$eviction" =~ ^(true|false)$ ]] || {
    echo "Longhorn node $node has invalid scheduling state." >&2
    return 1
  }
  ALLOW="$allow" EVICTION="$eviction" \
    yq --null-input --output-format json '
      {
        "schemaVersion": 1,
        "kind": "maintenance",
        "longhorn": {
          "allowScheduling": {
            "before": (strenv(ALLOW) == "true"),
            "during": false
          },
          "evictionRequested": {
            "before": (strenv(EVICTION) == "true"),
            "during": true
          }
        }
      }
    '
}

replace_longhorn_node_state() {
  local kubeconfig="$1"
  local replacement="$2"
  printf '%s\n' "$replacement" |
    longhorn_kubectl "$kubeconfig" replace --filename - >/dev/null
}

verify_longhorn_node_values() {
  local kubeconfig="$1"
  local node="$2"
  local expected_allow="$3"
  local expected_eviction="$4"
  local state actual
  state="$(read_longhorn_node "$kubeconfig" "$node")" || return 1
  actual="$(yq -r '[.spec.allowScheduling, .spec.evictionRequested] | join(" ")' - <<<"$state")"
  [[ "$actual" == "$expected_allow $expected_eviction" ]] || {
    echo "Longhorn node $node state is '$actual', expected '$expected_allow $expected_eviction'." >&2
    return 1
  }
}

apply_longhorn_maintenance_state() {
  local kubeconfig="$1"
  local node="$2"
  local record="$3"
  local state current_allow current_eviction before_allow before_eviction replacement
  [[ "$(lifecycle_record_kind "$record")" == 'maintenance' ]] || return 1
  state="$(read_longhorn_node "$kubeconfig" "$node")" || return 1
  current_allow="$(yq -r '.spec.allowScheduling' - <<<"$state")"
  current_eviction="$(yq -r '.spec.evictionRequested' - <<<"$state")"
  before_allow="$(yq -r '.longhorn.allowScheduling.before' - <<<"$record")"
  before_eviction="$(yq -r '.longhorn.evictionRequested.before' - <<<"$record")"
  [[ "$current_allow" == "$before_allow" && "$current_eviction" == "$before_eviction" ]] || {
    echo "Longhorn node $node changed before maintenance settings were applied." >&2
    return 1
  }
  replacement="$(yq --output-format json '
    .spec.allowScheduling = false |
    .spec.evictionRequested = true
  ' <<<"$state")"
  replace_longhorn_node_state "$kubeconfig" "$replacement" || return 1
  verify_longhorn_node_values "$kubeconfig" "$node" false true
}

restore_longhorn_maintenance_state() {
  local kubeconfig="$1"
  local node="$2"
  local record="$3"
  local state current_allow current_eviction before_allow before_eviction
  local allow_action eviction_action replacement
  [[ "$(lifecycle_record_kind "$record")" == 'maintenance' ]] || return 1
  state="$(read_longhorn_node "$kubeconfig" "$node")" || return 1
  current_allow="$(yq -r '.spec.allowScheduling' - <<<"$state")"
  current_eviction="$(yq -r '.spec.evictionRequested' - <<<"$state")"
  before_allow="$(yq -r '.longhorn.allowScheduling.before' - <<<"$record")"
  before_eviction="$(yq -r '.longhorn.evictionRequested.before' - <<<"$record")"
  allow_action="$(compare_owned_value "$current_allow" "$before_allow" false)" || return 1
  eviction_action="$(compare_owned_value "$current_eviction" "$before_eviction" true)" || return 1
  if [[ "$allow_action" == 'noop' && "$eviction_action" == 'noop' ]]; then
    return 0
  fi
  replacement="$(ALLOW="$before_allow" EVICTION="$before_eviction" \
    yq --output-format json '
      .spec.allowScheduling = (strenv(ALLOW) == "true") |
      .spec.evictionRequested = (strenv(EVICTION) == "true")
    ' <<<"$state")"
  replace_longhorn_node_state "$kubeconfig" "$replacement" || return 1
  verify_longhorn_node_values "$kubeconfig" "$node" "$before_allow" "$before_eviction"
}
