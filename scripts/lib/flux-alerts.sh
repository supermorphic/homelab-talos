#!/usr/bin/env bash

# Shared, read-only helpers for the Flux resource-state alert signal path.
# Callers own policy (fail-fast verification vs. aggregate diagnostics).

# shellcheck disable=SC2034 # This source interface deliberately initializes caller-owned variables.
flux_alerts_source() {
  # Production remains on the dedicated exporter during shadow collection. Do not
  # infer these identities from target health or chart-generated name fragments.
  flux_alerts_service='flux-kube-state-metrics'
  flux_alerts_deployment='flux-kube-state-metrics'
  flux_alerts_serviceaccount='flux-kube-state-metrics'
  flux_alerts_release='flux-kube-state-metrics'
  flux_alerts_values='kubernetes/apps/monitoring/flux-kube-state-metrics/app/values.yaml'
  flux_alerts_values_root='.'
}

flux_alerts_metric_selector() {
  flux_alerts_source
  printf 'gotk_resource_info{service="%s",namespace="monitoring"}\n' \
    "$flux_alerts_service"
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

flux_alerts_active_alertmanager_count() {
  yq -r '.data.activeAlertmanagers | length'
}
