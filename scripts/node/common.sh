#!/usr/bin/env bash

source scripts/lib/node-lifecycle-state.sh
source scripts/lib/node-operations.sh

node_kubectl() {
  local kubeconfig="$1"
  shift
  "${NODE_KUBECTL:-kubectl}" --kubeconfig "$kubeconfig" "$@"
}

read_node_lifecycle_record() {
  local kubeconfig="$1"
  local node="$2"
  local node_json
  node_json="$(node_kubectl "$kubeconfig" get node "$node" --output json)" || return 1
  ANNOTATION="$NODE_LIFECYCLE_ANNOTATION" \
    yq -r '.metadata.annotations[strenv(ANNOTATION)] // ""' <<<"$node_json"
}

persist_node_containment() {
  local kubeconfig="$1"
  local node="$2"
  local record="$3"
  local node_json current_record replacement verified
  validate_lifecycle_record "$record" || {
    echo 'Refusing to persist an invalid lifecycle record.' >&2
    return 1
  }
  node_json="$(node_kubectl "$kubeconfig" get node "$node" --output json)" || return 1
  current_record="$(ANNOTATION="$NODE_LIFECYCLE_ANNOTATION" \
    yq -r '.metadata.annotations[strenv(ANNOTATION)] // ""' <<<"$node_json")"
  [[ -z "$current_record" ]] || {
    echo "Node $node already has lifecycle containment." >&2
    return 1
  }
  [[ "$(yq -r '.spec.unschedulable // false' - <<<"$node_json")" == 'false' ]] || {
    echo "Node $node is already cordoned outside this lifecycle transaction." >&2
    return 1
  }
  replacement="$(ANNOTATION="$NODE_LIFECYCLE_ANNOTATION" RECORD="$record" \
    yq --output-format json '
      .metadata.annotations[strenv(ANNOTATION)] = strenv(RECORD) |
      .spec.unschedulable = true
    ' <<<"$node_json")"
  printf '%s\n' "$replacement" |
    node_kubectl "$kubeconfig" replace --filename - >/dev/null || {
      echo "Could not atomically annotate and cordon $node; lifecycle did not claim the Node object." >&2
      return 1
    }
  verified="$(node_kubectl "$kubeconfig" get node "$node" --output json)" || return 1
  [[ "$(ANNOTATION="$NODE_LIFECYCLE_ANNOTATION" \
    yq -r '.metadata.annotations[strenv(ANNOTATION)] // ""' <<<"$verified")" == "$record" &&
    "$(yq -r '.spec.unschedulable // false' - <<<"$verified")" == 'true' ]] || {
    echo "Node $node containment did not persist exactly as requested." >&2
    return 1
  }
}

remove_node_containment_and_uncordon() {
  local kubeconfig="$1"
  local node="$2"
  local expected_record="$3"
  local acceptance="$4"
  local node_json current_record replacement verified
  [[ "$acceptance" == 'recovery-accepted' ]] || {
    echo "Refusing to make $node schedulable before recovery acceptance." >&2
    return 1
  }
  validate_lifecycle_record "$expected_record" || return 1
  node_json="$(node_kubectl "$kubeconfig" get node "$node" --output json)" || return 1
  current_record="$(ANNOTATION="$NODE_LIFECYCLE_ANNOTATION" \
    yq -r '.metadata.annotations[strenv(ANNOTATION)] // ""' <<<"$node_json")"
  [[ "$current_record" == "$expected_record" ]] || {
    echo "Lifecycle record on $node changed; preserving containment." >&2
    return 1
  }
  [[ "$(yq -r '.spec.unschedulable // false' - <<<"$node_json")" == 'true' ]] || {
    echo "Node $node became schedulable before acceptance; refusing final transition." >&2
    return 1
  }
  replacement="$(ANNOTATION="$NODE_LIFECYCLE_ANNOTATION" \
    yq --output-format json '
      del(.metadata.annotations[strenv(ANNOTATION)]) |
      .spec.unschedulable = false
    ' <<<"$node_json")"
  printf '%s\n' "$replacement" |
    node_kubectl "$kubeconfig" replace --filename - >/dev/null || {
      echo "Final lifecycle transition for $node conflicted; it remains contained." >&2
      return 1
    }
  verified="$(node_kubectl "$kubeconfig" get node "$node" --output json)" || return 1
  [[ "$(ANNOTATION="$NODE_LIFECYCLE_ANNOTATION" \
    yq -r '.metadata.annotations[strenv(ANNOTATION)] // ""' <<<"$verified")" == '' &&
    "$(yq -r '.spec.unschedulable // false' - <<<"$verified")" == 'false' ]] || {
    echo "Final lifecycle transition for $node could not be verified." >&2
    return 1
  }
}
