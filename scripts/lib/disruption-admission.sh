#!/usr/bin/env bash

# Conservative, read-only admission for local operations that can disrupt cluster
# capacity. The annotation key is deliberately fixed: callers cannot select a
# different containment protocol or interpret recovery records here.

disruption_kubectl() {
  local kubeconfig="$1"
  shift
  "${DISRUPTION_KUBECTL:-kubectl}" --kubeconfig "$kubeconfig" "$@"
}

read_disruption_nodes() {
  local kubeconfig="$1"
  local nodes_json

  nodes_json="$(disruption_kubectl "$kubeconfig" get nodes --output json)" || {
    echo 'Cannot inspect node containment through the Kubernetes API.' >&2
    return 1
  }
  yq --exit-status -p=json '
    [
      (type == "!!map"),
      (.items | [type == "!!seq", length > 0] | all),
      ([.items[] | [
        (type == "!!map"),
        (.metadata | type == "!!map"),
        (.metadata.name | [type == "!!str", length > 0] | all),
        ((.metadata.annotations == null) or
          (.metadata.annotations | type == "!!map"))
      ] | all] | all)
    ] | all
  ' <<<"$nodes_json" >/dev/null 2>&1 || {
    echo 'Kubernetes returned a malformed or empty Node inventory.' >&2
    return 1
  }
  printf '%s\n' "$nodes_json"
}

assert_no_node_containment() {
  [[ "$#" -eq 1 ]] || {
    echo 'assert_no_node_containment requires one kubeconfig argument.' >&2
    return 2
  }
  local nodes_json blocked
  nodes_json="$(read_disruption_nodes "$1")" || return 1
  blocked="$(yq -p=json -r '
    .items[] |
    select((.metadata.annotations // {}) |
      has("homelab.supermorphic.com/node-lifecycle")) |
    .metadata.name
  ' <<<"$nodes_json")" || return 1
  [[ -z "$blocked" ]] || {
    echo 'Node containment blocks this operation; follow the documented recovery procedure.' >&2
    return 1
  }
}

assert_established_disruption_admissible() {
  [[ "$#" -eq 1 ]] || {
    echo 'assert_established_disruption_admissible requires one kubeconfig argument.' >&2
    return 2
  }
  local nodes_json
  nodes_json="$(read_disruption_nodes "$1")" || return 1
  _assert_no_node_containment_json "$nodes_json" || return 1
  yq --exit-status -p=json '
    [.items[] | [
      ((.spec == null) or (.spec | type == "!!map")),
      ((.spec.unschedulable == null) or
        (.spec.unschedulable | type == "!!bool")),
      ((.spec.unschedulable // false) == false),
      (.status | type == "!!map"),
      (.status.conditions | type == "!!seq"),
      (([.status.conditions[] |
        select([type == "!!map", .type == "Ready"] | all)
      ] | length) == 1),
      (([.status.conditions[] |
        select([type == "!!map", .type == "Ready"] | all) |
        .status
      ][0]) == "True")
    ] | all] | all
  ' <<<"$nodes_json" >/dev/null 2>&1 || {
    echo 'Every Node must be Ready and schedulable before this operation.' >&2
    return 1
  }
}

_assert_no_node_containment_json() {
  local nodes_json="$1"
  local blocked
  blocked="$(yq -p=json -r '
    .items[] |
    select((.metadata.annotations // {}) |
      has("homelab.supermorphic.com/node-lifecycle")) |
    .metadata.name
  ' <<<"$nodes_json")" || return 1
  [[ -z "$blocked" ]] || {
    echo 'Node containment blocks this operation; follow the documented recovery procedure.' >&2
    return 1
  }
}
