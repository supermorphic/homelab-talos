#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/network.sh
source scripts/lib/flux-alerts.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: flux-alert-delivery.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
expected_confirmation='test:flux-alert:firing-resolved'
namespace='flux-system'
test_name="flux-alert-e2e-$(date -u +%Y%m%d%H%M%S)-$$"
source_name="${test_name}-source-does-not-exist"
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
alertmanager_base_url='https://alertmanager.lab.supermorphic.com'
alertmanager_resolve="alertmanager.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-flux-alert-delivery.XXXXXX")"
manifest="$temp_dir/kustomization.yaml"
created=false

cleanup() {
  if [[ "$created" == 'true' ]]; then
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      delete kustomization "$test_name" --ignore-not-found --wait=true \
      --timeout=2m >/dev/null 2>&1 || true
  fi
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}
[[ "${FLUX_ALERT_E2E_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing the state-changing Flux alert delivery test; set FLUX_ALERT_E2E_CONFIRM='$expected_confirmation' after reviewing its 15-minute failure window and exact cleanup scope." >&2
  exit 1
}

if kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get kustomization "$test_name" >/dev/null 2>&1; then
  echo "Refusing to adopt pre-existing Kustomization $namespace/$test_name." >&2
  exit 1
fi
if kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  get gitrepository "$source_name" >/dev/null 2>&1; then
  echo "Refusing to run because the deliberately missing source $namespace/$source_name exists." >&2
  exit 1
fi

query_value() {
  local query="$1"
  local response
  response="$(
    flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "$query"
  )"
  [[ "$(yq -r '.status // ""' <<<"$response")" == 'success' ]] || {
    echo "Prometheus query failed: $query" >&2
    return 1
  }
  yq -r '.data.result[0].value[1] // "0"' <<<"$response"
}

numeric_gt() {
  awk -v value="$1" -v threshold="$2" \
    'BEGIN { exit !((value + 0) > (threshold + 0)) }'
}

wait_for_query_gt() {
  local description="$1"
  local query="$2"
  local threshold="$3"
  local attempts="$4"
  local delay="$5"
  local value='0'
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    value="$(query_value "$query")"
    if numeric_gt "$value" "$threshold"; then
      printf '%s\n' "$value"
      return 0
    fi
    sleep "$delay"
  done
  echo "Timed out waiting for $description (last value=$value, threshold=$threshold)." >&2
  return 1
}

wait_for_query_zero() {
  local description="$1"
  local query="$2"
  local attempts="$3"
  local delay="$4"
  local value='0'
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    value="$(query_value "$query")"
    if awk -v value="$value" 'BEGIN { exit !((value + 0) == 0) }'; then
      return 0
    fi
    sleep "$delay"
  done
  echo "Timed out waiting for $description (last value=$value)." >&2
  return 1
}

wait_for_alertmanager_route() {
  local expected_count="$1"
  local description="$2"
  local attempts="$3"
  local delay="$4"
  local response count='0'
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    response="$(
      flux_alerts_prometheus_get "$alertmanager_base_url" "$alertmanager_resolve" \
        '/api/v2/alerts/groups'
    )"
    count="$(
      NAME="$test_name" yq -r '
        [
          .[] |
          select(.receiver.name == "ntfy") |
          .alerts[]? |
          select(
            .labels.alertname == "FluxReconciliationFailure" and
            .labels.name == strenv(NAME) and
            .labels.exported_namespace == "flux-system" and
            .status.state == "active"
          )
        ] |
        length
      ' <<<"$response"
    )"
    if [[ "$count" -eq "$expected_count" ]]; then
      return 0
    fi
    sleep "$delay"
  done
  echo "Timed out waiting for $description in Alertmanager's ntfy route (last count=$count)." >&2
  return 1
}

notification_total_query='sum(alertmanager_notifications_total{integration="webhook",receiver="ntfy"}) or vector(0)'
notification_failed_query='sum(alertmanager_notifications_failed_total{integration="webhook",receiver="ntfy"}) or vector(0)'
alert_metric_query="count(gotk_resource_info{customresource_kind=\"Kustomization\",exported_namespace=\"$namespace\",name=\"$test_name\",ready!=\"True\",suspended!=\"true\"})"
pending_alert_query="count(ALERTS{alertname=\"FluxReconciliationFailure\",exported_namespace=\"$namespace\",name=\"$test_name\",alertstate=\"pending\"})"
firing_alert_query="count(ALERTS{alertname=\"FluxReconciliationFailure\",exported_namespace=\"$namespace\",name=\"$test_name\",alertstate=\"firing\"})"
any_alert_query="count(ALERTS{alertname=\"FluxReconciliationFailure\",exported_namespace=\"$namespace\",name=\"$test_name\"})"

notification_total_before="$(query_value "$notification_total_query")"
notification_failed_before="$(query_value "$notification_failed_query")"

export namespace source_name test_name
yq --null-input \
  '.apiVersion = "kustomize.toolkit.fluxcd.io/v1" |
   .kind = "Kustomization" |
   .metadata.name = strenv(test_name) |
   .metadata.namespace = strenv(namespace) |
   .metadata.labels."homelab-talos/test" = "flux-alert-delivery" |
   .spec.interval = "1m" |
   .spec.retryInterval = "30s" |
   .spec.timeout = "30s" |
   .spec.prune = false |
   .spec.wait = true |
   .spec.path = ("./.homelab-talos-tests/" + strenv(test_name)) |
   .spec.sourceRef.apiVersion = "source.toolkit.fluxcd.io/v1" |
   .spec.sourceRef.kind = "GitRepository" |
   .spec.sourceRef.name = strenv(source_name)' \
  >"$manifest"

kubectl --kubeconfig "$kubeconfig" create --filename "$manifest" >/dev/null
created=true
echo "Created isolated $namespace/$test_name with a deliberately nonexistent source."

wait_for_query_gt 'the failed test Kustomization metric' "$alert_metric_query" 0 36 5 \
  >/dev/null
wait_for_query_gt 'the Flux alert pending state' "$pending_alert_query" 0 36 5 \
  >/dev/null
echo 'Prometheus sees the test resource and the 15-minute Flux alert timer is pending.'

wait_for_query_gt 'FluxReconciliationFailure to fire' "$firing_alert_query" 0 120 10 \
  >/dev/null
wait_for_alertmanager_route 1 'the firing test alert' 48 5
notification_total_firing="$(
  wait_for_query_gt 'the firing ntfy webhook success' "$notification_total_query" \
    "$notification_total_before" 48 5
)"
notification_failed_firing="$(query_value "$notification_failed_query")"
[[ "$notification_failed_firing" == "$notification_failed_before" ]] || {
  echo 'Alertmanager recorded a failed ntfy webhook while sending the firing alert.' >&2
  exit 1
}
echo 'Firing alert reached Alertmanager receiver ntfy and its synchronous webhook succeeded.'

kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  delete kustomization "$test_name" --wait=true --timeout=2m >/dev/null
created=false
echo "Deleted only the run-owned $namespace/$test_name Kustomization."

wait_for_query_zero 'the test alert to leave Prometheus' "$any_alert_query" 48 5
wait_for_alertmanager_route 0 'the test alert to resolve' 96 5
wait_for_query_gt 'the resolved ntfy webhook success' "$notification_total_query" \
  "$notification_total_firing" 96 5 >/dev/null
notification_failed_resolved="$(query_value "$notification_failed_query")"
[[ "$notification_failed_resolved" == "$notification_failed_before" ]] || {
  echo 'Alertmanager recorded a failed ntfy webhook while sending the resolved alert.' >&2
  exit 1
}

echo 'Flux alert delivery E2E passed: the run-owned Kustomization became non-ready, the real 15-minute rule fired through Alertmanager receiver ntfy, both synchronous firing/resolved webhooks succeeded, and the test resource was deleted.'
echo "Human acceptance: confirm the phone received the warning and 'Resolved:' messages naming $namespace/$test_name on the homelab topic."
