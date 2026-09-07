#!/usr/bin/env bash

# Shared, read-only helpers for the Flux resource-state alert signal path.
# Callers own policy (fail-fast verification vs. aggregate diagnostics).

# shellcheck disable=SC2034 # This source interface deliberately initializes caller-owned variables.
flux_alerts_source() {
  # Production selects the verified bundled KPS resources. Do not infer these
  # identities from target health or chart-generated name fragments.
  flux_alerts_service='kube-prometheus-stack-kube-state-metrics'
  flux_alerts_deployment='kube-prometheus-stack-kube-state-metrics'
  flux_alerts_serviceaccount='kube-prometheus-stack-kube-state-metrics'
  flux_alerts_release='kube-prometheus-stack'
  flux_alerts_workload_instance='kube-prometheus-stack'
  flux_alerts_workload_name='kube-state-metrics'
  flux_alerts_values='kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml'
  flux_alerts_values_root='."kube-state-metrics"'
}

flux_alerts_metric_selector() {
  flux_alerts_source
  printf 'gotk_resource_info{service="%s",namespace="monitoring"}\n' \
    "$flux_alerts_service"
}

flux_alerts_workload_selector() {
  flux_alerts_source
  printf 'app.kubernetes.io/name=%s,app.kubernetes.io/instance=%s\n' \
    "$flux_alerts_workload_name" "$flux_alerts_workload_instance"
}

flux_alerts_configured_gvks() {
  local values_file="$1"
  local values_root="${2-.}"
  yq -r "
    (${values_root}).customResourceState.config.spec.resources[] |
    [
      .groupVersionKind.group,
      .groupVersionKind.version,
      .groupVersionKind.kind
    ] |
    @tsv
  " "$values_file"
}

flux_alerts_prometheus_get() {
  local base_url="$1"
  local resolve="$2"
  local path="$3"
  curl --silent --show-error --fail --max-time 20 \
    --resolve "$resolve" \
    "${base_url}${path}"
}

flux_alerts_prometheus_query() {
  local base_url="$1"
  local resolve="$2"
  local query="$3"
  curl --silent --show-error --fail --max-time 20 \
    --resolve "$resolve" \
    --get \
    --data-urlencode "query=$query" \
    "${base_url}/api/v1/query"
}

flux_alerts_target_count() {
  local service_name="$1"
  local target_namespace="${2-}"
  SERVICE_NAME="$service_name" NAMESPACE="$target_namespace" yq -r '
    [
      .data.activeTargets[]? |
      select(
        .discoveredLabels.__meta_kubernetes_service_name == strenv(SERVICE_NAME) and
        (strenv(NAMESPACE) == "" or .discoveredLabels.__meta_kubernetes_namespace == strenv(NAMESPACE))
      )
    ] |
    length
  '
}

flux_alerts_target_healths() {
  local service_name="$1"
  local target_namespace="${2-}"
  SERVICE_NAME="$service_name" NAMESPACE="$target_namespace" yq -r '
    [
      .data.activeTargets[]? |
      select(
        .discoveredLabels.__meta_kubernetes_service_name == strenv(SERVICE_NAME) and
        (strenv(NAMESPACE) == "" or .discoveredLabels.__meta_kubernetes_namespace == strenv(NAMESPACE))
      ) |
      (.health // "unknown")
    ] |
    unique |
    sort |
    join(",")
  '
}

flux_alerts_target_errors() {
  local service_name="$1"
  local target_namespace="${2-}"
  SERVICE_NAME="$service_name" NAMESPACE="$target_namespace" yq -r '
    [
      .data.activeTargets[]? |
      select(
        .discoveredLabels.__meta_kubernetes_service_name == strenv(SERVICE_NAME) and
        (strenv(NAMESPACE) == "" or .discoveredLabels.__meta_kubernetes_namespace == strenv(NAMESPACE))
      ) |
      select((.lastError // "") != "") |
      .lastError
    ] |
    unique |
    .[]
  '
}

flux_alerts_metric_kinds() {
  yq -r '
    [
      .data.result[]?.metric.customresource_kind |
      select(. != null and . != "")
    ] |
    unique |
    sort |
    .[]
  '
}

flux_alerts_rule_rows() {
  local first_rule="$1"
  local second_rule="$2"
  FIRST_RULE="$first_rule" SECOND_RULE="$second_rule" yq -r '
    .data.groups[]?.rules[]? |
    select(.name == strenv(FIRST_RULE) or .name == strenv(SECOND_RULE)) |
    [
      .name,
      (.state // "unknown"),
      (.health // "unknown"),
      (.lastError // "")
    ] |
    @tsv
  '
}

flux_alerts_rules_select_production_source() {
  flux_alerts_source
  local rule_json rule_name query remaining selector match
  local service_without_expected namespace_without_expected
  local selector_count status=0
  local reconciliation_seen=false missing_seen=false

  while IFS= read -r rule_json; do
    rule_name="$(yq -r '.name // ""' <<<"$rule_json")"
    query="$(yq -r '.query // ""' <<<"$rule_json")"
    case "$rule_name" in
    FluxReconciliationFailure)
      [[ "$reconciliation_seen" == 'false' ]] || status=1
      reconciliation_seen=true
      ;;
    FluxResourceMetricsMissing)
      [[ "$missing_seen" == 'false' ]] || status=1
      missing_seen=true
      ;;
    *) status=1 ;;
    esac

    selector_count=0
    remaining="$query"
    while [[ "$remaining" =~ gotk_resource_info\{([^}]*)\} ]]; do
      match="${BASH_REMATCH[0]}"
      selector="${BASH_REMATCH[1]}"
      selector_count=$((selector_count + 1))
      service_without_expected="${selector/"service=\"$flux_alerts_service\""/}"
      namespace_without_expected="${selector/namespace=\"monitoring\"/}"
      [[ "$selector" == *"service=\"$flux_alerts_service\""* &&
        "$service_without_expected" != *'service='* &&
        "$selector" == *'namespace="monitoring"'* &&
        "$namespace_without_expected" != *'namespace='* ]] || status=1
      remaining="${remaining#*"$match"}"
    done
    [[ "$selector_count" -gt 0 ]] || status=1
  done < <(
    yq -o=json -I=0 '
      .data.groups[]?.rules[]? |
      select(
        .name == "FluxReconciliationFailure" or
        .name == "FluxResourceMetricsMissing"
      ) |
      .
    '
  )

  if [[ "$status" -eq 0 && "$reconciliation_seen" == 'true' && "$missing_seen" == 'true' ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

flux_alerts_active_alertmanager_count() {
  yq -r '.data.activeAlertmanagers | length'
}
