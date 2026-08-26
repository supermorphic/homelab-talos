#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/flux-alerts.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: logging.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
[[ -f "$kubeconfig" ]] || {
  echo 'Logging verification kubeconfig is missing.' >&2
  exit 2
}

ns='monitoring'
longhorn_ns='longhorn-system'
kc=(kubectl --kubeconfig "$kubeconfig")
"${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1 || {
  echo 'Logging verification requires kubeconfig context homelab-diagnostic.' >&2
  exit 2
}
kc+=(--context homelab-diagnostic)

for resource in loki alloy-logs alloy-events; do
  "${kc[@]}" --namespace flux-system wait \
    --for=condition=Ready "kustomization/$resource" --timeout=5m >/dev/null
  "${kc[@]}" --namespace "$ns" wait \
    --for=condition=Ready "helmrelease/$resource" --timeout=5m >/dev/null
done

"${kc[@]}" --namespace "$ns" rollout status statefulset/loki --timeout=5m >/dev/null
"${kc[@]}" --namespace "$ns" rollout status daemonset/alloy-logs --timeout=5m >/dev/null
"${kc[@]}" --namespace "$ns" rollout status deployment/alloy-events --timeout=5m >/dev/null

pvc_json="$("${kc[@]}" --namespace "$ns" get pvc --output json)"
mapfile -t loki_pvcs < <(
  yq -r '
    .items[] |
    select(.metadata.labels."recurring-job.longhorn.io/source" == "enabled") |
    select(.metadata.labels."recurring-job.longhorn.io/loki-filesystem-trim" == "enabled") |
    .metadata.name
  ' <<<"$pvc_json"
)
[[ "${#loki_pvcs[@]}" -eq 1 ]] || {
  echo "Expected exactly one Loki PVC selected by its recurring-job intent labels; found ${#loki_pvcs[@]}." >&2
  exit 1
}
loki_pvc="${loki_pvcs[0]}"
pvc_phase="$(PVC_NAME="$loki_pvc" yq -r '
  .items[] | select(.metadata.name == strenv(PVC_NAME)) | .status.phase // ""
' <<<"$pvc_json")"
[[ "$pvc_phase" == 'Bound' ]] || {
  echo "Loki PVC $loki_pvc is not Bound." >&2
  exit 1
}
pvc_request="$(PVC_NAME="$loki_pvc" yq -r '
  .items[] | select(.metadata.name == strenv(PVC_NAME)) |
  .spec.resources.requests.storage // ""
' <<<"$pvc_json")"
[[ "$pvc_request" == '50Gi' ]] || {
  echo "Loki PVC $loki_pvc does not request 50 GiB." >&2
  exit 1
}
pv_name="$(PVC_NAME="$loki_pvc" yq -r '
  .items[] | select(.metadata.name == strenv(PVC_NAME)) | .spec.volumeName // ""
' <<<"$pvc_json")"
[[ -n "$pv_name" ]] || {
  echo "Bound Loki PVC $loki_pvc has no PersistentVolume name." >&2
  exit 1
}
longhorn_volumes_json="$("${kc[@]}" --namespace "$longhorn_ns" \
  get volumes.longhorn.io --output json)"
mapfile -t matching_longhorn_volumes < <(
  PV_NAME="$pv_name" PVC_NAME="$loki_pvc" PVC_NAMESPACE="$ns" yq -r '
    .items[]? |
    select((.status.kubernetesStatus.pvName // "") == strenv(PV_NAME)) |
    select((.status.kubernetesStatus.pvcName // "") == strenv(PVC_NAME)) |
    select((.status.kubernetesStatus.namespace // "") == strenv(PVC_NAMESPACE)) |
    .metadata.name
  ' <<<"$longhorn_volumes_json"
)
[[ "${#matching_longhorn_volumes[@]}" -eq 1 ]] || {
  echo "Expected exactly one actual Longhorn Volume matching PersistentVolume $pv_name and PVC $ns/$loki_pvc with complete status.kubernetesStatus identity; found ${#matching_longhorn_volumes[@]}." >&2
  exit 1
}
longhorn_volume="${matching_longhorn_volumes[0]}"

trim_label='recurring-job.longhorn.io/loki-filesystem-trim'
volume_json=''
volume_labels_synchronized=false
for _ in {1..30}; do
  if volume_json="$("${kc[@]}" --namespace "$longhorn_ns" \
    get volumes.longhorn.io "$longhorn_volume" --output json 2>/dev/null)" && \
    TRIM_LABEL="$trim_label" yq -e '
      [
        (.metadata.labels // {}) | to_entries[] |
        select(.key | test("^recurring-job(-group)?\\.longhorn\\.io/")) |
        "\(.key)=\(.value)"
      ] |
      sort == ["\(strenv(TRIM_LABEL))=enabled"]
    ' >/dev/null 2>&1 <<<"$volume_json"; then
    volume_labels_synchronized=true
    break
  fi
  sleep 10
done
if [[ "$volume_labels_synchronized" != 'true' ]] && ! \
  TRIM_LABEL="$trim_label" yq -e '
    (.metadata.labels // {})[strenv(TRIM_LABEL)] == "enabled"
  ' >/dev/null 2>&1 <<<"$volume_json"; then
  echo "Longhorn Volume $longhorn_volume does not have the required filesystem-trim assignment after synchronization retries." >&2
  exit 1
fi

for forbidden_label in \
  'recurring-job-group.longhorn.io/default' \
  'recurring-job.longhorn.io/daily-snapshot' \
  'recurring-job.longhorn.io/daily-backup'; do
  if LABEL_KEY="$forbidden_label" yq -e '
    (.metadata.labels // {}) | has(strenv(LABEL_KEY))
  ' >/dev/null 2>&1 <<<"$volume_json"; then
    echo "Longhorn Volume $longhorn_volume has forbidden recurring-job assignment $forbidden_label." >&2
    exit 1
  fi
done

actual_recurring_labels="$(yq -r '
  [
    (.metadata.labels // {}) | to_entries[] |
    select(.key | test("^recurring-job(-group)?\\.longhorn\\.io/")) |
    "\(.key)=\(.value)"
  ] |
  sort |
  join(",")
' <<<"$volume_json")"
[[ "$actual_recurring_labels" == "$trim_label=enabled" ]] || {
  echo "Longhorn Volume $longhorn_volume has an unexpected recurring-job assignment after synchronization retries." >&2
  exit 1
}

trim_task="$("${kc[@]}" --namespace "$longhorn_ns" \
  get recurringjobs.longhorn.io loki-filesystem-trim \
  --output jsonpath='{.spec.task}')"
[[ "$trim_task" == 'filesystem-trim' ]] || {
  echo 'RecurringJob loki-filesystem-trim is not a filesystem-trim job.' >&2
  exit 1
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/logging-verify.XXXXXX")"
loki_pf_pid=''
prometheus_pf_pid=''
cleanup() {
  local status="$?"
  trap - EXIT INT TERM HUP
  for pid in "$loki_pf_pid" "$prometheus_pf_pid"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  for pid in "$loki_pf_pid" "$prometheus_pf_pid"; do
    [[ -n "$pid" ]] || continue
    wait "$pid" 2>/dev/null || true
  done
  rm -rf -- "$temp_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

start_port_forward() {
  local service_name="$1"
  local remote_port="$2"
  local log_file="$3"
  local -n result_pid="$4"
  local -n result_port="$5"
  local port=''

  "${kc[@]}" --namespace "$ns" port-forward --address 127.0.0.1 \
    "service/$service_name" ":$remote_port" >"$log_file" 2>&1 &
  result_pid="$!"
  for _ in {1..50}; do
    port="$(sed -n "s/^Forwarding from 127\\.0\\.0\\.1:\\([0-9][0-9]*\\) -> ${remote_port}$/\\1/p" \
      "$log_file" | head -n 1)"
    if [[ -n "$port" ]]; then
      # shellcheck disable=SC2034  # Assignment updates the caller through a nameref.
      result_port="$port"
      return 0
    fi
    if ! kill -0 "$result_pid" 2>/dev/null; then
      echo "Port-forward to Service $service_name stopped before becoming ready." >&2
      return 1
    fi
    sleep 0.1
  done
  echo "Port-forward to Service $service_name did not become ready." >&2
  return 1
}

loki_port=''
prometheus_port=''
start_port_forward loki 3100 "$temp_dir/loki-port-forward.log" \
  loki_pf_pid loki_port
start_port_forward kube-prometheus-stack-prometheus 9090 \
  "$temp_dir/prometheus-port-forward.log" prometheus_pf_pid prometheus_port

loki_base_url="http://127.0.0.1:$loki_port"
loki_ready=false
for _ in {1..30}; do
  if curl --silent --show-error --fail --max-time 5 \
    "$loki_base_url/ready" >/dev/null 2>&1; then
    loki_ready=true
    break
  fi
  sleep 2
done
[[ "$loki_ready" == 'true' ]] || {
  echo 'Loki did not report ready through its temporary local port-forward.' >&2
  exit 1
}

end_seconds="$(date -u +%s)"
start_seconds="$((end_seconds - 1800))"
labels_response="$(curl --silent --show-error --fail --max-time 20 \
  --get \
  --data-urlencode "start=${start_seconds}000000000" \
  --data-urlencode "end=${end_seconds}000000000" \
  "$loki_base_url/loki/api/v1/labels")"
yq -e '.status == "success" and (.data | type == "!!seq")' \
  >/dev/null 2>&1 <<<"$labels_response" || {
  echo 'Loki label-name API did not return a successful label-name list.' >&2
  exit 1
}
mapfile -t indexed_labels < <(yq -r '.data[]' <<<"$labels_response" | LC_ALL=C sort -u)
declare -A allowed_labels=(
  [app]=1
  [cluster]=1
  [container]=1
  [event_type]=1
  [namespace]=1
  [node]=1
  [service]=1
  [source]=1
  [stream]=1
)
forbidden_labels=(
  pod pod_name pod_uid
  container_id image_digest path filename
  ip pod_ip client_ip source_ip host_ip
  name uid event_name event_uid reason reporting_instance
  request request_id user user_id session session_id
  torrent torrent_id trace trace_id
)
for label in "${indexed_labels[@]}"; do
  for forbidden_label in "${forbidden_labels[@]}"; do
    [[ "$label" != "$forbidden_label" ]] || {
      echo "Loki returned forbidden indexed label $label." >&2
      exit 1
    }
  done
  [[ -n "${allowed_labels[$label]:-}" ]] || {
    echo "Loki returned indexed label $label outside the bounded allowlist." >&2
    exit 1
  }
done

loki_count_nonzero() {
  local selector="$1"
  local response
  response="$(curl --silent --show-error --fail --max-time 20 \
    --get \
    --data-urlencode "query=sum(count_over_time(${selector}[30m]))" \
    "$loki_base_url/loki/api/v1/query" 2>/dev/null)" || return 1
  yq -e '
    .status == "success" and
    .data.resultType == "vector" and
    (.data.result | length == 1) and
    ((.data.result[0].value[1] | tonumber) > 0)
  ' >/dev/null 2>&1 <<<"$response"
}

count_selectors=(
  '{source="kubernetes"}'
  '{source="talos"}'
  '{source="talos",service="kernel"}'
  '{source="kubernetes_event"}'
)
count_descriptions=(
  'Kubernetes containers'
  'Talos services'
  'Talos kernel'
  'Kubernetes Events'
)
counts_ready=false
missing_counts=()
for _ in {1..30}; do
  missing_counts=()
  for index in "${!count_selectors[@]}"; do
    loki_count_nonzero "${count_selectors[$index]}" || \
      missing_counts+=("${count_descriptions[$index]}")
  done
  if [[ "${#missing_counts[@]}" -eq 0 ]]; then
    counts_ready=true
    break
  fi
  sleep 10
done
if [[ "$counts_ready" != 'true' ]]; then
  for description in "${missing_counts[@]}"; do
    echo "Missing nonzero Loki aggregate count: $description." >&2
  done
  exit 1
fi

prometheus_base_url="http://127.0.0.1:$prometheus_port"
prometheus_resolve="127.0.0.1:${prometheus_port}:127.0.0.1"
targets_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/targets?state=active'
)"
[[ "$(yq -r '.status // ""' <<<"$targets_response")" == 'success' ]] || {
  echo 'Prometheus targets API did not return status=success.' >&2
  exit 1
}
declare -A prometheus_jobs=(
  [loki]='monitoring/loki'
  [alloy-logs]='alloy-logs'
  [alloy-events]='alloy-events'
)
for service_name in loki alloy-logs alloy-events; do
  scrape_pool="serviceMonitor/$ns/$service_name/0"
  prometheus_job="${prometheus_jobs[$service_name]}"
  mapfile -t exact_target_rows < <(
    SERVICE_NAME="$service_name" SCRAPE_POOL="$scrape_pool" \
      PROMETHEUS_JOB="$prometheus_job" yq -r '
        .data.activeTargets[]? |
        select((.scrapePool // "") == strenv(SCRAPE_POOL)) |
        select(
          (.discoveredLabels.__meta_kubernetes_service_name // "") ==
          strenv(SERVICE_NAME)
        ) |
        select((.labels.service // "") == strenv(SERVICE_NAME)) |
        select((.labels.job // "") == strenv(PROMETHEUS_JOB)) |
        [(.health // "unknown"), (.lastError // "")] |
        @tsv
      ' <<<"$targets_response"
  )
  [[ "${#exact_target_rows[@]}" -gt 0 ]] || {
    echo "Prometheus does not have an exact up $service_name ServiceMonitor target." >&2
    exit 1
  }
  for target_row in "${exact_target_rows[@]}"; do
    IFS=$'\t' read -r target_health target_error <<<"$target_row"
    [[ "$target_health" == 'up' && -z "$target_error" ]] || {
      echo "Prometheus does not have an exact up $service_name ServiceMonitor target." >&2
      exit 1
    }
  done
done

expected_rules=(
  LokiMetricsMissing
  AlloyInstanceCountLow
  AlloyLogDeliveryDrops
  LokiLogEntriesDiscarded
  LokiRequestErrors
  LokiCompactorStalled
  LokiStorageUsageHigh
  LokiStorageUsageCritical
)
rules_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/rules?type=alert'
)"
[[ "$(yq -r '.status // ""' <<<"$rules_response")" == 'success' ]] || {
  echo 'Prometheus rules API did not return status=success.' >&2
  exit 1
}
expected_rules_csv="$(IFS=,; echo "${expected_rules[*]}")"
mapfile -t logging_rule_rows < <(
  # shellcheck disable=SC2016  # $name is a yq expression variable.
  EXPECTED_RULES="$expected_rules_csv" yq -r '
    .data.groups[]?.rules[]? |
    select(.name as $name | (strenv(EXPECTED_RULES) | split(",") | contains([$name]))) |
    [.name, (.health // "unknown"), (.lastError // "")] |
    @tsv
  ' <<<"$rules_response"
)
[[ "${#logging_rule_rows[@]}" -eq "${#expected_rules[@]}" ]] || {
  echo "Prometheus has not loaded all ${#expected_rules[@]} logging alert rules." >&2
  exit 1
}
loaded_rule_names="$(printf '%s\n' "${logging_rule_rows[@]}" | cut -f1 | LC_ALL=C sort)"
expected_rule_names="$(printf '%s\n' "${expected_rules[@]}" | LC_ALL=C sort)"
[[ "$loaded_rule_names" == "$expected_rule_names" ]] || {
  echo 'Prometheus logging alert-rule names do not match the required set.' >&2
  exit 1
}
for row in "${logging_rule_rows[@]}"; do
  IFS=$'\t' read -r rule_name rule_health rule_error <<<"$row"
  [[ "$rule_health" == 'ok' && -z "$rule_error" ]] || {
    echo "Prometheus logging alert rule $rule_name is unhealthy." >&2
    exit 1
  }
done

echo "Logging acceptance passed: workloads are Ready; Loki PVC $loki_pvc, PersistentVolume $pv_name, Longhorn Volume $longhorn_volume, and RecurringJob loki-filesystem-trim satisfy storage acceptance; bounded label-name and aggregate-count checks passed; Prometheus sees up Loki and Alloy targets and eight healthy logging alert rules."
