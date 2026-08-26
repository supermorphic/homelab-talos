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

# Rollout status alone does not prove the required topology. Verify exact controller
# counters and exact Ready Pod placement without emitting Pod or node identities.
nodes_json="$("${kc[@]}" get nodes --output json)"
mapfile -t production_nodes < <(
  yq -r '
    .items[]? |
    select((.spec.unschedulable // false) == false) |
    select([
      .status.conditions[]? |
      select(.type == "Ready" and .status == "True")
    ] | length == 1) |
    .metadata.name
  ' <<<"$nodes_json" | LC_ALL=C sort
)
[[ "${#production_nodes[@]}" -eq 3 ]] || {
  echo 'Production topology does not contain exactly three Ready schedulable nodes.' >&2
  exit 1
}

alloy_logs_daemonset_json="$("${kc[@]}" --namespace "$ns" \
  get daemonset alloy-logs --output json)"
yq -e '
  .metadata.generation == .status.observedGeneration and
  .status.desiredNumberScheduled == 3 and
  .status.currentNumberScheduled == 3 and
  .status.updatedNumberScheduled == 3 and
  .status.numberReady == 3 and
  .status.numberAvailable == 3 and
  (.status.numberMisscheduled // 0) == 0 and
  (.status.numberUnavailable // 0) == 0
' >/dev/null 2>&1 <<<"$alloy_logs_daemonset_json" || {
  echo 'Alloy Logs topology does not have exactly three fully available scheduled instances.' >&2
  exit 1
}
alloy_logs_pods_json="$("${kc[@]}" --namespace "$ns" get pods \
  --selector app.kubernetes.io/instance=alloy-logs,app.kubernetes.io/name=alloy \
  --output json)"
yq -e '
  ((.items | type) == "!!seq" and (.items | length) == 3) and
  ([
    .items[] |
    select((.metadata.deletionTimestamp // "") == "") |
    select(.status.phase == "Running") |
    select((.spec.nodeName // "") != "") |
    select([
      .status.conditions[]? |
      select(.type == "Ready" and .status == "True")
    ] | length == 1)
  ] | length == 3) and
  ([.items[].spec.nodeName] | unique | length) == 3
' >/dev/null 2>&1 <<<"$alloy_logs_pods_json" || {
  echo 'Alloy Logs pods are not Ready on exactly three distinct production nodes.' >&2
  exit 1
}
alloy_logs_nodes="$(yq -r '.items[].spec.nodeName' <<<"$alloy_logs_pods_json" | LC_ALL=C sort)"
production_node_set="$(printf '%s\n' "${production_nodes[@]}" | LC_ALL=C sort)"
[[ "$alloy_logs_nodes" == "$production_node_set" ]] || {
  echo 'Alloy Logs pods are not Ready on exactly three distinct production nodes.' >&2
  exit 1
}

alloy_events_deployment_json="$("${kc[@]}" --namespace "$ns" \
  get deployment alloy-events --output json)"
yq -e '
  .metadata.generation == .status.observedGeneration and
  .spec.replicas == 1 and
  .status.replicas == 1 and
  .status.updatedReplicas == 1 and
  .status.readyReplicas == 1 and
  .status.availableReplicas == 1 and
  (.status.unavailableReplicas // 0) == 0
' >/dev/null 2>&1 <<<"$alloy_events_deployment_json" || {
  echo 'Alloy Events topology does not have exactly one fully available instance.' >&2
  exit 1
}
alloy_events_pods_json="$("${kc[@]}" --namespace "$ns" get pods \
  --selector app.kubernetes.io/instance=alloy-events,app.kubernetes.io/name=alloy \
  --output json)"
yq -e '
  ((.items | type) == "!!seq" and (.items | length) == 1) and
  ([
    .items[] |
    select((.metadata.deletionTimestamp // "") == "") |
    select(.status.phase == "Running") |
    select((.spec.nodeName // "") != "") |
    select([
      .status.conditions[]? |
      select(.type == "Ready" and .status == "True")
    ] | length == 1)
  ] | length == 1)
' >/dev/null 2>&1 <<<"$alloy_events_pods_json" || {
  echo 'Alloy Events does not have exactly one Ready pod.' >&2
  exit 1
}

loki_statefulset_json="$("${kc[@]}" --namespace "$ns" \
  get statefulset loki --output json)"
yq -e '
  .metadata.generation == .status.observedGeneration and
  .spec.replicas == 1 and
  .status.replicas == 1 and
  .status.currentReplicas == 1 and
  .status.updatedReplicas == 1 and
  .status.readyReplicas == 1 and
  .status.availableReplicas == 1 and
  ((.status.currentRevision | type) == "!!str" and
    (.status.currentRevision | length) > 0) and
  .status.currentRevision == .status.updateRevision
' >/dev/null 2>&1 <<<"$loki_statefulset_json" || {
  echo 'Loki topology does not have exactly one fully available instance.' >&2
  exit 1
}
loki_pods_json="$("${kc[@]}" --namespace "$ns" get pods \
  --selector app.kubernetes.io/instance=loki,app.kubernetes.io/name=loki \
  --output json)"
yq -e '
  ((.items | type) == "!!seq" and (.items | length) == 1) and
  ([
    .items[] |
    select((.metadata.deletionTimestamp // "") == "") |
    select(.status.phase == "Running") |
    select((.spec.nodeName // "") != "") |
    select([
      .status.conditions[]? |
      select(.type == "Ready" and .status == "True")
    ] | length == 1)
  ] | length == 1)
' >/dev/null 2>&1 <<<"$loki_pods_json" || {
  echo 'Loki does not have exactly one Ready pod.' >&2
  exit 1
}

# Bind storage verification to the sole Ready Pod and the StatefulSet that owns it.
# Identities stay internal and are never included in diagnostics.
loki_statefulset_name="$(yq -r '.metadata.name // ""' <<<"$loki_statefulset_json")"
loki_statefulset_uid="$(yq -r '.metadata.uid // ""' <<<"$loki_statefulset_json")"
[[ -n "$loki_statefulset_name" && -n "$loki_statefulset_uid" ]] || {
  echo 'Verified Loki StatefulSet identity is incomplete.' >&2
  exit 1
}
STS_NAME="$loki_statefulset_name" STS_UID="$loki_statefulset_uid" yq -e '
  [
    .items[0].metadata.ownerReferences[]? |
    select(.apiVersion == "apps/v1") |
    select(.kind == "StatefulSet") |
    select(.name == strenv(STS_NAME)) |
    select(.uid == strenv(STS_UID)) |
    select(.controller == true)
  ] | length == 1
' >/dev/null 2>&1 <<<"$loki_pods_json" || {
  echo 'Loki Ready pod is not controlled by the verified StatefulSet.' >&2
  exit 1
}
mapfile -t loki_claim_template_names < <(
  yq -r '.spec.volumeClaimTemplates[]?.metadata.name // ""' \
    <<<"$loki_statefulset_json"
)
mapfile -t loki_pvc_mount_rows < <(
  yq -r '
    .items[0].spec.volumes[]? |
    select((.persistentVolumeClaim.claimName // "") != "") |
    [(.name // ""), .persistentVolumeClaim.claimName] |
    @tsv
  ' <<<"$loki_pods_json"
)
[[ "${#loki_claim_template_names[@]}" -eq 1 &&
  "${#loki_pvc_mount_rows[@]}" -eq 1 ]] || {
  echo 'Loki Ready pod does not mount exactly one claim from the verified StatefulSet.' >&2
  exit 1
}
IFS=$'\t' read -r loki_pvc_volume_name loki_pvc \
  <<<"${loki_pvc_mount_rows[0]}"
[[ -n "$loki_pvc" &&
  "$loki_pvc_volume_name" == "${loki_claim_template_names[0]}" ]] || {
  echo 'Loki Ready pod does not mount exactly one claim from the verified StatefulSet.' >&2
  exit 1
}

pvc_json="$("${kc[@]}" --namespace "$ns" get pvc --output json)"
pvc_match_count="$(PVC_NAME="$loki_pvc" yq -r '
  [
    .items[]? |
    select(.metadata.name == strenv(PVC_NAME)) |
    select((.metadata.deletionTimestamp // "") == "")
  ] | length
' <<<"$pvc_json")"
[[ "$pvc_match_count" == '1' ]] || {
  echo "The mounted Loki claim does not resolve to exactly one current PVC; found $pvc_match_count." >&2
  exit 1
}
mounted_pvc_recurring_labels="$(PVC_NAME="$loki_pvc" yq -r '
  [
    .items[] |
    select(.metadata.name == strenv(PVC_NAME)) |
    (.metadata.labels // {}) | to_entries[] |
    select(.key | test("^recurring-job(-group)?\\.longhorn\\.io/")) |
    "\(.key)=\(.value)"
  ] | sort | join(",")
' <<<"$pvc_json")"
[[ "$mounted_pvc_recurring_labels" == \
  'recurring-job.longhorn.io/loki-filesystem-trim=enabled,recurring-job.longhorn.io/source=enabled' ]] || {
  echo 'The mounted Loki claim does not have the exact recurring-job intent labels.' >&2
  exit 1
}
pvc_phase="$(PVC_NAME="$loki_pvc" yq -r '
  .items[] | select(.metadata.name == strenv(PVC_NAME)) | .status.phase // ""
' <<<"$pvc_json")"
[[ "$pvc_phase" == 'Bound' ]] || {
  echo 'The selected Loki claim is not Bound.' >&2
  exit 1
}
pvc_request="$(PVC_NAME="$loki_pvc" yq -r '
  .items[] | select(.metadata.name == strenv(PVC_NAME)) |
  .spec.resources.requests.storage // ""
' <<<"$pvc_json")"
[[ "$pvc_request" == '50Gi' ]] || {
  echo 'The selected Loki claim does not request 50 GiB.' >&2
  exit 1
}
pv_name="$(PVC_NAME="$loki_pvc" yq -r '
  .items[] | select(.metadata.name == strenv(PVC_NAME)) | .spec.volumeName // ""
' <<<"$pvc_json")"
[[ -n "$pv_name" ]] || {
  echo 'The bound Loki claim has no PersistentVolume identity.' >&2
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
  echo "Expected exactly one actual Longhorn Volume with complete bound-claim identity; found ${#matching_longhorn_volumes[@]}." >&2
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
  echo 'Actual Longhorn Volume does not have the required filesystem-trim assignment after synchronization retries.' >&2
  exit 1
fi

for forbidden_label in \
  'recurring-job-group.longhorn.io/default' \
  'recurring-job.longhorn.io/daily-snapshot' \
  'recurring-job.longhorn.io/daily-backup'; do
  if LABEL_KEY="$forbidden_label" yq -e '
    (.metadata.labels // {}) | has(strenv(LABEL_KEY))
  ' >/dev/null 2>&1 <<<"$volume_json"; then
    echo "Actual Longhorn Volume has forbidden recurring-job assignment $forbidden_label." >&2
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
  echo 'Actual Longhorn Volume has an unexpected recurring-job assignment after synchronization retries.' >&2
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

# Loki 3.6.11 publishes the resolved per-tenant limits at this endpoint. The
# prometheus/common duration serializer reports 336h canonically as 2w. Checking this
# surface, rather than only the rendered ConfigMap, includes any runtime override.
runtime_limits_response=''
if ! runtime_limits_response="$(curl --silent --show-error --fail --max-time 20 \
  --header 'X-Scope-OrgID: fake' \
  "$loki_base_url/config/tenant/v1/limits")"; then
  echo 'Loki effective runtime limits endpoint was unavailable.' >&2
  exit 1
fi
yq -e '
  (. | type == "!!map") and
  .retention_period == "2w" and
  (((.retention_stream // []) | type) == "!!seq" and
    ((.retention_stream // []) | length) == 0)
' >/dev/null 2>&1 <<<"$runtime_limits_response" || {
  echo 'Loki effective runtime retention is not exactly 336h with no stream override.' >&2
  exit 1
}
yq -e '
  ((.discover_service_name | type) == "!!seq") and
  (.discover_service_name | length) == 0
' >/dev/null 2>&1 <<<"$runtime_limits_response" || {
  echo 'Loki effective runtime service-name discovery is not disabled.' >&2
  exit 1
}

end_seconds="$(date -u +%s)"
start_seconds="$((end_seconds - 1800))"

verify_exact_label_names() {
  local selector="$1"
  local description="$2"
  local expected_csv="$3"
  local response actual_csv

  if ! response="$(curl --silent --show-error --fail --max-time 20 \
    --get \
    --data-urlencode "start=${start_seconds}000000000" \
    --data-urlencode "end=${end_seconds}000000000" \
    --data-urlencode "query=$selector" \
    "$loki_base_url/loki/api/v1/labels")"; then
    echo "$description label-name API request failed." >&2
    return 1
  fi
  yq -e '
    .status == "success" and
    ((.data | type) == "!!seq" and (.data | length) > 0) and
    ([.data[] | select(type != "!!str" or length == 0)] | length == 0) and
    (.data | length) == (.data | unique | length)
  ' >/dev/null 2>&1 <<<"$response" || {
    echo "$description label-name API response is malformed." >&2
    return 1
  }
  actual_csv="$(yq -r '.data | sort | join(",")' <<<"$response")"
  [[ "$actual_csv" == "$expected_csv" ]] || {
    echo "$description indexed-label names do not exactly match the approved set." >&2
    return 1
  }
}

verify_exact_label_names \
  '{source="kubernetes"}' \
  'Kubernetes container' \
  'app,cluster,container,namespace,node,source,stream'
verify_exact_label_names \
  '{source="talos"}' \
  'Talos' \
  'cluster,node,service,source'
verify_exact_label_names \
  '{source="kubernetes_event"}' \
  'Kubernetes Event' \
  'cluster,event_type,namespace,source'

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
  '{source="talos",service=~".+",service!="kernel"}'
  '{source="talos",service="kernel"}'
  '{source="kubernetes_event"}'
)
count_descriptions=(
  'Kubernetes containers'
  'Talos non-kernel services'
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
declare -A prometheus_target_counts=(
  [loki]=1
  [alloy-logs]=3
  [alloy-events]=1
)
for service_name in loki alloy-logs alloy-events; do
  scrape_pool="serviceMonitor/$ns/$service_name/0"
  prometheus_job="${prometheus_jobs[$service_name]}"
  expected_target_count="${prometheus_target_counts[$service_name]}"
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
  target_noun='targets'
  [[ "$expected_target_count" -ne 1 ]] || target_noun='target'
  [[ "${#exact_target_rows[@]}" -eq "$expected_target_count" ]] || {
    echo "Prometheus does not have exactly $expected_target_count healthy $service_name ServiceMonitor $target_noun." >&2
    exit 1
  }
  for target_row in "${exact_target_rows[@]}"; do
    IFS=$'\t' read -r target_health target_error <<<"$target_row"
    [[ "$target_health" == 'up' && -z "$target_error" ]] || {
      echo "Prometheus does not have exactly $expected_target_count healthy $service_name ServiceMonitor $target_noun." >&2
      exit 1
    }
  done
done

compaction_query='time() - loki_boltdb_shipper_compact_tables_operation_last_successful_run_timestamp_seconds{namespace="monitoring",job="monitoring/loki"}'
compaction_response=''
if ! compaction_response="$(flux_alerts_prometheus_query \
  "$prometheus_base_url" "$prometheus_resolve" "$compaction_query")"; then
  echo 'Prometheus compaction-freshness query failed.' >&2
  exit 1
fi
yq -e '
  .status == "success" and
  .data.resultType == "vector" and
  (.data.result | length == 1) and
  ((.data.result[0].value | type) == "!!seq" and
    (.data.result[0].value | length) == 2) and
  ((.data.result[0].value[1] | tonumber) >= 0) and
  ((.data.result[0].value[1] | tonumber) <= 10800)
' >/dev/null 2>&1 <<<"$compaction_response" || {
  echo 'Loki does not report exactly one fresh successful compaction timestamp.' >&2
  exit 1
}

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

echo 'Logging acceptance passed: exact three-node Alloy Logs, single Alloy Events, and single Loki topology is Ready; one bound 50 GiB claim has trim-only labels on its actual Longhorn Volume; effective retention is 336h and compaction is fresh; exact source-specific label names and bounded aggregate counts passed; Prometheus sees exact up Loki and Alloy targets and eight healthy logging alert rules.'
