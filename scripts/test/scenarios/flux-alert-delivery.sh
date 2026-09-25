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
ntfy_base_url='https://ntfy.lab.supermorphic.com'
ntfy_resolve="ntfy.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-flux-alert-delivery.XXXXXX")"
umask 077
manifest="$temp_dir/kustomization.yaml"
run_dir="${HOMELAB_TEST_RUN_DIR:-}"
created=false
firing_title="Flux Kustomization $namespace/$test_name is failing to reconcile"
resolved_title="Resolved: $firing_title"

write_phase() {
  local phase="$1"
  local phase_status="$2"
  local reason="$3"
  [[ -n "$run_dir" ]] || return 0
  PHASE_STATUS="$phase_status" PHASE_REASON="$reason" \
    yq --null-input --output-format json '{
      "status": strenv(PHASE_STATUS),
      "reason": strenv(PHASE_REASON)
    }' >"$run_dir/$phase.json"
}

run_owned_kustomization_absent() {
  local resource
  resource="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get kustomization "$test_name" --ignore-not-found --output=name)" || {
    echo "Could not confirm absence of run-owned Kustomization $namespace/$test_name." >&2
    return 1
  }
  assert_empty "$resource" \
    "Run-owned Kustomization $namespace/$test_name still exists after cleanup."
}

delete_run_owned_kustomization() {
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    delete kustomization "$test_name" --wait=true --timeout=2m >/dev/null || return 1
  run_owned_kustomization_absent || return 1
  created=false
}

# shellcheck disable=SC2329 # invoked by the EXIT trap below.
cleanup() {
  local original_exit="$?"
  local cleanup_ok=true
  trap - EXIT INT TERM
  set +e
  if [[ "$created" == 'true' ]]; then
    delete_run_owned_kustomization || cleanup_ok=false
  fi
  rm -rf -- "$temp_dir" || cleanup_ok=false
  [[ ! -e "$temp_dir" ]] || cleanup_ok=false
  if [[ "$cleanup_ok" == 'true' ]]; then
    write_phase cleanup passed 'the run-owned Kustomization and local temporary files are absent'
  else
    write_phase cleanup failed 'the run-owned Kustomization or local temporary files could not be confirmed absent'
    echo 'Flux alert delivery cleanup failed; inspect the run-owned Kustomization before another run.' >&2
  fi
  if [[ "$cleanup_ok" != 'true' ]]; then
    return 1
  fi
  return "$original_exit"
}
trap cleanup EXIT

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}
[[ -z "$run_dir" || -d "$run_dir" ]] || {
  echo "HOMELAB_TEST_RUN_DIR does not exist: $run_dir" >&2
  exit 1
}
write_phase recovery not-required 'the scenario does not disrupt a workload'
write_phase cleanup not-classified 'the run-owned Kustomization has not been verified absent'
[[ "${FLUX_ALERT_E2E_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing the state-changing Flux alert delivery test; set FLUX_ALERT_E2E_CONFIRM='$expected_confirmation' after reviewing its 15-minute failure window and exact cleanup scope." >&2
  exit 1
}

# The operator provisions this dedicated read-only token through the ntfy identity
# registry. Never read the canonical Secret or print the token or cached messages.
token_file="${NTFY_FLUX_ALERT_TOKEN_FILE:-}"
repo_root="$(git rev-parse --show-toplevel)"
token_file_mode=''
if [[ -f "$token_file" && ! -L "$token_file" ]]; then
  token_file_mode="$(stat -c %a "$token_file" 2>/dev/null || stat -f %Lp "$token_file")"
fi
[[ -d "$repo_root/.tmp" && ! -L "$repo_root/.tmp" &&
  "$token_file" == "$repo_root"/.tmp/* && "${token_file#"$repo_root/.tmp/"}" != */* &&
  -f "$token_file" && ! -L "$token_file" &&
  -r "$token_file" && "$token_file_mode" == '600' ]] || {
  echo "NTFY_FLUX_ALERT_TOKEN_FILE must name a readable, regular 0600 file under this worktree's .tmp/ directory." >&2
  exit 1
}
ntfy_token="$(<"$token_file")"
[[ "$ntfy_token" =~ ^tk_[a-z0-9]+$ ]] || {
  echo 'NTFY_FLUX_ALERT_TOKEN_FILE does not contain one ntfy token.' >&2
  exit 1
}
ntfy_config="$temp_dir/ntfy.curl"
printf 'header = "Authorization: Bearer %s"\n' "$ntfy_token" >"$ntfy_config"
unset ntfy_token
ntfy_since="$(date -u +%s)"

poll_ntfy() {
  local response_file="$temp_dir/ntfy-response.jsonl"
  local header_file="$temp_dir/ntfy-headers"
  local since="$1"
  curl --silent --show-error --fail --max-time 20 \
    --config "$ntfy_config" --resolve "$ntfy_resolve" \
    --dump-header "$header_file" --output "$response_file" \
    "$ntfy_base_url/homelab/json?poll=1&since=$since" || {
      echo 'ntfy cached-message poll failed; check the read-only token and service.' >&2
      return 1
    }
  if rg -qi '^X-Messages-Truncated:[[:space:]]*1' "$header_file"; then
    echo 'ntfy cached-message response was truncated; delivery cannot be established.' >&2
    return 1
  fi
}

ntfy_title_count() {
  local title="$1"
  local since="$2"
  jq -s --arg title "$title" --argjson since "$since" \
    '[.[] | select(.event == "message" and .topic == "homelab" and
      .title == $title and (.time | type == "number") and .time >= $since)] | length' \
    "$temp_dir/ntfy-response.jsonl"
}

wait_for_ntfy_title() {
  local title="$1"
  local description="$2"
  local attempts="$3"
  local delay="$4"
  local attempt count
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    poll_ntfy "$ntfy_since" || return 1
    count="$(ntfy_title_count "$title" "$ntfy_since")" || return 1
    if [[ "$count" -gt 0 ]]; then
      return 0
    fi
    sleep "$delay"
  done
  echo "Flux alert delivery evidence is inconclusive: no run-specific $description appeared in ntfy's homelab cache." >&2
  return 1
}

# Fail before creating the Flux object if the token cannot read the topic.
poll_ntfy "$ntfy_since"

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

# This Alertmanager version exposes notification counters by integration, but not by
# receiver. Confirm that ntfy is the only loaded webhook to preserve the receiver
# identity check. That does not make the aggregate counter test-specific: unrelated
# alerts routed to ntfy can still increment it.
alertmanager_status="$(
  flux_alerts_prometheus_get "$alertmanager_base_url" "$alertmanager_resolve" \
    '/api/v2/status'
)"
alertmanager_config="$(yq -r '.config.original // ""' <<<"$alertmanager_status")"
[[ -n "$alertmanager_config" ]] || {
  echo 'Alertmanager status API returned no loaded configuration.' >&2
  exit 1
}
webhook_config_count="$(
  yq -r '[.receivers[]?.webhook_configs[]?] | length' <<<"$alertmanager_config"
)"
ntfy_webhook_config_count="$(
  yq -r '[.receivers[]? | select(.name == "ntfy") | .webhook_configs[]?] | length' \
    <<<"$alertmanager_config"
)"
[[ "$webhook_config_count" -eq 1 && "$ntfy_webhook_config_count" -eq 1 ]] || {
  echo 'Refusing delivery test: ntfy is not the only loaded Alertmanager webhook.' >&2
  exit 1
}

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

notification_total_query='sum(alertmanager_notifications_total{integration="webhook"}) or vector(0)'
notification_failed_query='sum(alertmanager_notifications_failed_total{integration="webhook"}) or vector(0)'
notification_total_series_query='count(alertmanager_notifications_total{integration="webhook"})'
notification_failed_series_query='count(alertmanager_notifications_failed_total{integration="webhook"})'
production_metric_selector="$(flux_alerts_metric_selector)"
alert_metric_query="count(${production_metric_selector%?},customresource_kind=\"Kustomization\",exported_namespace=\"$namespace\",name=\"$test_name\",ready!=\"True\",suspended!=\"true\"})"
pending_alert_query="count(ALERTS{alertname=\"FluxReconciliationFailure\",exported_namespace=\"$namespace\",name=\"$test_name\",alertstate=\"pending\"})"
firing_alert_query="count(ALERTS{alertname=\"FluxReconciliationFailure\",exported_namespace=\"$namespace\",name=\"$test_name\",alertstate=\"firing\"})"
any_alert_query="count(ALERTS{alertname=\"FluxReconciliationFailure\",exported_namespace=\"$namespace\",name=\"$test_name\"})"

notification_total_series_count="$(query_value "$notification_total_series_query")"
notification_failed_series_count="$(query_value "$notification_failed_series_query")"
if ! numeric_gt "$notification_total_series_count" 0 || \
  ! numeric_gt "$notification_failed_series_count" 0; then
  echo 'Refusing delivery test: Alertmanager webhook notification metric series are absent.' >&2
  exit 1
fi

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
  wait_for_query_gt 'the aggregate webhook notification counter after the firing alert' "$notification_total_query" \
    "$notification_total_before" 48 5
)"
notification_failed_firing="$(query_value "$notification_failed_query")"
[[ "$notification_failed_firing" == "$notification_failed_before" ]] || {
  echo 'Alertmanager aggregate webhook failure counter increased after the firing alert.' >&2
  exit 1
}
echo 'Firing alert reached Alertmanager receiver ntfy; aggregate webhook counters increased without failures.'
wait_for_ntfy_title "$firing_title" 'firing notification' 48 5
echo 'The run-specific firing notification appeared in the ntfy homelab cache.'

delete_run_owned_kustomization || {
  echo "Could not delete and confirm absence of the run-owned $namespace/$test_name Kustomization." >&2
  exit 1
}
echo "Deleted only the run-owned $namespace/$test_name Kustomization."

wait_for_query_zero 'the test alert to leave Prometheus' "$any_alert_query" 48 5
wait_for_alertmanager_route 0 'the test alert to resolve' 96 5
wait_for_query_gt 'the aggregate webhook notification counter after the resolved alert' "$notification_total_query" \
  "$notification_total_firing" 96 5 >/dev/null
notification_failed_resolved="$(query_value "$notification_failed_query")"
[[ "$notification_failed_resolved" == "$notification_failed_before" ]] || {
  echo 'Alertmanager aggregate webhook failure counter increased after the resolved alert.' >&2
  exit 1
}
wait_for_ntfy_title "$resolved_title" 'resolved notification' 48 5

echo 'Flux alert delivery passed: the real 15-minute rule fired, and exact run-specific firing and resolved notifications appeared in the ntfy homelab cache.'
echo "Human handset receipt remains separate: confirm the phone received both messages naming $namespace/$test_name."
