#!/usr/bin/env bash

drain_kubectl() {
  local kubeconfig="$1"
  shift
  "${NODE_KUBECTL:-kubectl}" --kubeconfig "$kubeconfig" "$@"
}

validate_drain_pods() {
  local pods_json="$1"
  local unmanaged
  # shellcheck disable=SC2016  # $kind is a yq variable.
  unmanaged="$(yq -r '
    .items[] |
    select(.metadata.annotations."kubernetes.io/config.mirror" == null) |
    ([.metadata.ownerReferences[]? | select(.controller == true) | .kind][0] // "") as $kind |
    select($kind != "DaemonSet" and $kind == "") |
    .metadata.namespace + "/" + .metadata.name
  ' <<<"$pods_json")"
  [[ -z "$unmanaged" ]] || {
    printf 'Drain is blocked by unmanaged Pods:\n%s\n' "$unmanaged" >&2
    return 1
  }
}

report_drain_local_data() {
  local pods_json="$1"
  local report
  # shellcheck disable=SC2016  # $kind, $namespace, and $pod are yq variables.
  report="$(yq -r '
    .items[] |
    select(.metadata.annotations."kubernetes.io/config.mirror" == null) |
    ([.metadata.ownerReferences[]? | select(.controller == true) | .kind][0] // "") as $kind |
    select($kind != "DaemonSet") |
    .metadata.namespace as $namespace |
    .metadata.name as $pod |
    .spec.volumes[]? |
    select(.emptyDir != null) |
    $namespace + "/" + $pod + " emptyDir/" + .name
  ' <<<"$pods_json")"
  if [[ -n "$report" ]]; then
    printf 'Node-local emptyDir data will be discarded:\n%s\n' "$report"
  fi
}

capture_drain_inventory() {
  local kubeconfig="$1"
  local node="$2"
  local output_file="$3"
  local pods_json
  pods_json="$(drain_kubectl "$kubeconfig" get pods --all-namespaces \
    --field-selector "spec.nodeName=$node" --output json)" || return 1
  validate_drain_pods "$pods_json" || return 1
  report_drain_local_data "$pods_json" >&2
  printf '%s\n' "$pods_json" >"$output_file"
}

perform_kubernetes_drain() {
  local kubeconfig="$1"
  local node="$2"
  local discovery
  discovery="$(drain_kubectl "$kubeconfig" get --raw /apis/policy/v1)" || {
    echo 'Cannot verify the Kubernetes policy/v1 Eviction API.' >&2
    return 1
  }
  [[ "$(yq -r '[.resources[]? | select(.name == "pods/eviction" and .kind == "Eviction")] | length' - <<<"$discovery")" -eq 1 ]] || {
    echo 'Refusing drain because the policy/v1 Pod eviction resource is unavailable.' >&2
    return 1
  }
  drain_kubectl "$kubeconfig" drain "$node" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout="${NODE_DRAIN_TIMEOUT:-15m}"
}

verify_no_drainable_workloads() {
  local kubeconfig="$1"
  local node="$2"
  local pods_json remaining
  pods_json="$(drain_kubectl "$kubeconfig" get pods --all-namespaces \
    --field-selector "spec.nodeName=$node" --output json)" || return 1
  # shellcheck disable=SC2016  # $kind is a yq variable.
  remaining="$(yq -r '
    .items[] |
    select(.metadata.annotations."kubernetes.io/config.mirror" == null) |
    ([.metadata.ownerReferences[]? | select(.controller == true) | .kind][0] // "") as $kind |
    select($kind != "DaemonSet") |
    .metadata.namespace + "/" + .metadata.name
  ' <<<"$pods_json")"
  [[ -z "$remaining" ]] || {
    printf 'Drainable workloads remain on %s:\n%s\n' "$node" "$remaining" >&2
    return 1
  }
}

verify_workload_replacements() {
  local kubeconfig="$1"
  local node="$2"
  local inventory_file="$3"
  local pod_json namespace pod_name kind selector candidates replacement claims claim
  [[ -f "$inventory_file" ]] || return 1
  while IFS= read -r pod_json; do
    [[ -n "$pod_json" ]] || continue
    kind="$(yq -r '[.metadata.ownerReferences[]? | select(.controller == true) | .kind][0] // ""' <<<"$pod_json")"
    [[ -n "$kind" && "$kind" != 'DaemonSet' ]] || continue
    namespace="$(yq -r '.metadata.namespace' <<<"$pod_json")"
    pod_name="$(yq -r '.metadata.name' <<<"$pod_json")"
    selector="$(yq -r '.metadata.labels // {} | to_entries | map(.key + "=" + .value) | join(",")' <<<"$pod_json")"
    [[ -n "$selector" ]] || {
      echo "Cannot identify a replacement for $namespace/$pod_name without labels." >&2
      return 1
    }
    candidates="$(drain_kubectl "$kubeconfig" --namespace "$namespace" get pods \
      --selector "$selector" --output json)" || return 1
    replacement="$(TARGET="$node" yq -o=json -I=0 '
      [.items[] |
        select(.spec.nodeName != strenv(TARGET)) |
        select(.metadata.deletionTimestamp == null) |
        select(.status.phase == "Running") |
        select([.status.conditions[]? | select(.type == "Ready") | .status][0] == "True")][0] // ""
    ' <<<"$candidates")"
    [[ -n "$replacement" && "$replacement" != '""' ]] || {
      echo "No Ready surviving replacement exists for $namespace/$pod_name." >&2
      return 1
    }
    claims="$(yq -r '.spec.volumes[]? | select(.persistentVolumeClaim != null) | .persistentVolumeClaim.claimName' <<<"$pod_json")"
    while IFS= read -r claim; do
      [[ -n "$claim" ]] || continue
      CLAIM="$claim" yq --exit-status \
        '[.spec.volumes[]? | select(.persistentVolumeClaim.claimName == strenv(CLAIM))] | length > 0' \
        <<<"$replacement" >/dev/null || {
        echo "Replacement for $namespace/$pod_name does not mount PVC $claim." >&2
        return 1
      }
      drain_kubectl "$kubeconfig" --namespace "$namespace" get pvc "$claim" \
        --output jsonpath='{.spec.volumeName}' >/dev/null
    done <<<"$claims"
  done < <(yq -o=json -I=0 '.items[]' "$inventory_file")
}
