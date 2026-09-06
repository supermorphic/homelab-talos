#!/usr/bin/env bash
set -uo pipefail

source scripts/lib/network.sh
source scripts/lib/flux-alerts.sh
source scripts/test/lib/results.sh

flux_alerts_source

readonly suite_id='diagnostics.flux-alerts'
readonly namespace='monitoring'
readonly exporter_name="$flux_alerts_service"
readonly exporter_subject="system:serviceaccount:monitoring:${flux_alerts_serviceaccount}"
readonly exporter_values="$flux_alerts_values"
readonly exporter_values_root="$flux_alerts_values_root"
readonly prometheus_base_url='https://prometheus.lab.supermorphic.com'
readonly prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
readonly alertmanager_base_url='https://alertmanager.lab.supermorphic.com'
readonly alertmanager_resolve="alertmanager.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"

declare -a configured_gvks=()
declare -A discovered_resources=()
declare -a stage_labels=()
declare -a stage_results=()
stage_index=0
kubeconfig=''
temp_dir=''
exporter_pod=''
raw_metric_present=false

bounded_text() {
  awk 'length($0) > 400 {print substr($0, 1, 400) "...[truncated]"; next} {print}'
}

load_configured_gvks() {
  local configured
  if ! configured="$(flux_alerts_configured_gvks "$exporter_values" "$exporter_values_root" 2>&1)"; then
    echo "Could not read configured Flux GVKs: $(printf '%s' "$configured" | bounded_text)" >&2
    return 1
  fi
  mapfile -t configured_gvks <<<"$configured"
  [[ "${#configured_gvks[@]}" -gt 0 ]]
}

discover_resource_name() {
  local group="$1"
  local version="$2"
  local kind="$3"
  local key="${group}/${version}/${kind}"
  local discovery resource

  if [[ -n "${discovered_resources[$key]:-}" ]]; then
    printf '%s\n' "${discovered_resources[$key]}"
    return 0
  fi
  if ! discovery="$(
    kubectl --kubeconfig "$kubeconfig" get --raw "/apis/${group}/${version}" 2>&1
  )"; then
    echo "Discovery failed for $key: $(printf '%s' "$discovery" | bounded_text)" >&2
    return 1
  fi
  resource="$(
    KIND="$kind" yq -r '
      [
        .resources[] |
        select(.kind == strenv(KIND)) |
        select(.name | contains("/") | not) |
        .name
      ][0] // ""
    ' <<<"$discovery"
  )"
  [[ -n "$resource" ]] || {
    echo "Discovery returned no resource for $key." >&2
    return 1
  }
  discovered_resources["$key"]="$resource"
  printf '%s\n' "$resource"
}

stage_flux_resources() {
  local status=0
  local group version kind resource objects count readiness
  local gvk

  [[ "${#configured_gvks[@]}" -gt 0 ]] || {
    echo 'No configured Flux GVKs were loaded.' >&2
    return 1
  }
  echo "Configured GVKs are derived from $exporter_values."
  for gvk in "${configured_gvks[@]}"; do
    IFS=$'\t' read -r group version kind <<<"$gvk"
    if ! resource="$(discover_resource_name "$group" "$version" "$kind")"; then
      status=1
      continue
    fi
    if ! objects="$(
      kubectl --kubeconfig "$kubeconfig" get "${resource}.${group}" \
        --all-namespaces --output json 2>&1
    )"; then
      echo "$kind: read failed: $(printf '%s' "$objects" | bounded_text)" >&2
      status=1
      continue
    fi
    count="$(yq -r '.items | length' <<<"$objects")"
    readiness="$(
      yq -r '
        [
          .items[].status.conditions[]? |
          select(.type == "Ready") |
          .status
        ] |
        group_by(.) |
        map("\(.[0])=\(length)") |
        join(",")
      ' <<<"$objects"
    )"
    [[ -n "$readiness" ]] || readiness='no-Ready-condition'
    printf '  %-18s resource=%-48s objects=%s readiness=%s\n' \
      "$kind" "${resource}.${group}" "$count" "$readiness"
    [[ "$count" -gt 0 ]] || status=1
  done
  return "$status"
}

stage_exporter_rbac() {
  local status=0
  local group version kind resource list_result watch_result
  local gvk

  [[ "${#configured_gvks[@]}" -gt 0 ]] || {
    echo 'No configured Flux GVKs were loaded.' >&2
    return 1
  }
  for gvk in "${configured_gvks[@]}"; do
    IFS=$'\t' read -r group version kind <<<"$gvk"
    if ! resource="$(discover_resource_name "$group" "$version" "$kind")"; then
      status=1
      continue
    fi
    list_result="$(
      kubectl --kubeconfig "$kubeconfig" auth can-i list "${resource}.${group}" \
        --as="$exporter_subject" --all-namespaces 2>/dev/null || true
    )"
    watch_result="$(
      kubectl --kubeconfig "$kubeconfig" auth can-i watch "${resource}.${group}" \
        --as="$exporter_subject" --all-namespaces 2>/dev/null || true
    )"
    printf '  %-18s list=%-3s watch=%-3s resource=%s\n' \
      "$kind" "${list_result:-error}" "${watch_result:-error}" "${resource}.${group}"
    [[ "$list_result" == 'yes' && "$watch_result" == 'yes' ]] || status=1
  done
  list_result="$(
    kubectl --kubeconfig "$kubeconfig" auth can-i list \
      customresourcedefinitions.apiextensions.k8s.io \
      --as="$exporter_subject" 2>/dev/null || true
  )"
  watch_result="$(
    kubectl --kubeconfig "$kubeconfig" auth can-i watch \
      customresourcedefinitions.apiextensions.k8s.io \
      --as="$exporter_subject" 2>/dev/null || true
  )"
  printf '  %-18s list=%-3s watch=%-3s resource=%s\n' \
    'KSM CRD discovery' "${list_result:-error}" "${watch_result:-error}" \
    'customresourcedefinitions.apiextensions.k8s.io'
  [[ "$list_result" == 'yes' && "$watch_result" == 'yes' ]] || status=1
  return "$status"
}

stage_exporter_workload() {
  local status=0
  local kustomization_ready helmrelease_ready deployment pod_rows logs filtered
  local desired ready

  kustomization_ready="$(
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
      get kustomization "$exporter_name" \
      --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null ||
      true
  )"
  helmrelease_ready="$(
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      get helmrelease "$exporter_name" \
      --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null ||
      true
  )"
  if deployment="$(
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      get deployment "$exporter_name" --output json 2>&1
  )"; then
    desired="$(yq -r '.spec.replicas // 1' <<<"$deployment")"
    ready="$(yq -r '.status.readyReplicas // 0' <<<"$deployment")"
  else
    echo "Deployment read failed: $(printf '%s' "$deployment" | bounded_text)" >&2
    desired='?'
    ready='0'
    status=1
  fi
  printf '  Kustomization Ready=%s; HelmRelease Ready=%s; Deployment ready=%s/%s\n' \
    "${kustomization_ready:-unknown}" "${helmrelease_ready:-unknown}" "$ready" "$desired"
  [[ "$kustomization_ready" == 'True' && "$helmrelease_ready" == 'True' ]] || status=1
  [[ "$desired" != '?' && "$ready" -eq "$desired" && "$ready" -gt 0 ]] || status=1

  pod_rows="$(
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      get pods --selector "app.kubernetes.io/instance=${exporter_name}" \
      --output custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount' \
      --no-headers 2>&1
  )" || {
    echo "Pod read failed: $(printf '%s' "$pod_rows" | bounded_text)" >&2
    status=1
    pod_rows=''
  }
  if [[ -n "$pod_rows" ]]; then
    printf '%s\n' "$pod_rows" | sed 's/^/  pod /'
    exporter_pod="$(awk 'NR == 1 {print $1}' <<<"$pod_rows")"
    if ! awk 'NF >= 4 && $2 == "Running" && $3 == "true" {good++} END {exit good > 0 ? 0 : 1}' \
      <<<"$pod_rows"; then
      status=1
    fi
  else
    echo '  No exporter pod found.'
    status=1
  fi

  echo '  Relevant bounded log tail:'
  if logs="$(
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      logs "deployment/${exporter_name}" --tail=160 2>&1
  )"; then
    filtered="$(
      printf '%s\n' "$logs" |
        sed -E 's/^[A-Z][0-9]{4} [0-9:.]+[[:space:]]+[0-9]+[[:space:]]+//' |
        bounded_text |
        rg --ignore-case \
          'custom resource|customresource|metric|config|forbidden|unauthorized|error|warn' ||
        true
    )"
    if [[ -n "$filtered" ]]; then
      printf '%s\n' "$filtered" |
        sort |
        uniq -c |
        sort -nr |
        head -n 20 |
        sed 's/^/    /'
    else
      echo '    No matching custom-resource/config/RBAC warnings or errors.'
    fi
  else
    echo "    Log read failed: $(printf '%s' "$logs" | bounded_text)" >&2
    status=1
  fi
  return "$status"
}

stage_exporter_raw_metric() {
  local status=0
  local metric_count raw_kinds telemetry_path
  local error_file="$temp_dir/exporter-metrics.error"
  local metrics_file="$temp_dir/exporter-metrics.txt"
  local telemetry_file="$temp_dir/exporter-telemetry.txt"

  if [[ -z "$exporter_pod" ]]; then
    exporter_pod="$(
      kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
        get pods --selector "app.kubernetes.io/instance=${exporter_name}" \
        --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
    )"
  fi
  [[ -n "$exporter_pod" ]] || {
    echo 'No exporter pod is available for the raw metrics boundary.' >&2
    return 1
  }

  if ! kubectl --kubeconfig "$kubeconfig" get --raw \
    "/api/v1/namespaces/${namespace}/pods/${exporter_pod}:8080/proxy/metrics" \
    >"$metrics_file" 2>"$error_file"; then
    echo "Pod metrics proxy failed: $(bounded_text <"$error_file")" >&2
    return 1
  fi
  metric_count="$(rg -c --fixed-strings 'gotk_resource_info{' "$metrics_file" || true)"
  raw_kinds="$(
    rg -o 'customresource_kind="[^"]+"' "$metrics_file" |
      sed -E 's/^customresource_kind="|"$//g' |
      sort -u |
      paste -sd, - ||
      true
  )"
  printf '  gotk_resource_info series at exporter=%s kinds=%s\n' \
    "${metric_count:-0}" "${raw_kinds:-none}"
  if [[ "${metric_count:-0}" -gt 0 ]]; then
    raw_metric_present=true
  else
    status=1
    telemetry_path="/api/v1/namespaces/${namespace}/pods/${exporter_pod}:8081/proxy/metrics"
    if kubectl --kubeconfig "$kubeconfig" get --raw "$telemetry_path" \
      >"$telemetry_file" 2>/dev/null; then
      echo '  Exporter custom-resource config telemetry:'
      rg '^kube_state_metrics_(config_hash|last_config_reload)' "$telemetry_file" |
        bounded_text |
        sed 's/^/    /' ||
        echo '    No custom-resource config telemetry series found.'
    fi
  fi
  return "$status"
}

stage_service_monitor() {
  local status=0
  local service_file="$temp_dir/service.json"
  local monitor_file="$temp_dir/servicemonitor.json"
  local slices_file="$temp_dir/endpointslices.json"
  local key value actual selector_count endpoint_count endpoint_port service_ports

  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get service "$exporter_name" --output json >"$service_file" 2>/dev/null || status=1
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get servicemonitor "$exporter_name" --output json >"$monitor_file" 2>/dev/null ||
    status=1
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get endpointslices.discovery.k8s.io \
    --selector "kubernetes.io/service-name=${exporter_name}" \
    --output json >"$slices_file" 2>/dev/null || status=1
  if [[ "$status" -ne 0 ]]; then
    echo 'Could not read the exporter Service, ServiceMonitor, or EndpointSlices.' >&2
    return 1
  fi

  selector_count=0
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    selector_count=$((selector_count + 1))
    actual="$(KEY="$key" yq -r '.metadata.labels[strenv(KEY)] // ""' "$service_file")"
    [[ "$actual" == "$value" ]] || {
      echo "ServiceMonitor selector mismatch: $key expected=$value actual=${actual:-absent}" >&2
      status=1
    }
  done < <(
    yq -r '.spec.selector.matchLabels | to_entries[] | [.key, .value] | @tsv' \
      "$monitor_file"
  )
  [[ "$selector_count" -gt 0 ]] || {
    echo 'ServiceMonitor has no matchLabels selector.' >&2
    status=1
  }
  endpoint_port="$(yq -r '.spec.endpoints[0].port // ""' "$monitor_file")"
  service_ports="$(yq -r '[.spec.ports[].name] | join(",")' "$service_file")"
  rg -Fxq "$endpoint_port" < <(tr ',' '\n' <<<"$service_ports") || status=1
  endpoint_count="$(
    yq -r '
      [
        .items[].endpoints[]? |
        select(.conditions.ready != false) |
        .addresses[]
      ] |
      length
    ' "$slices_file"
  )"
  printf '  Service=%s ports=%s; ServiceMonitor=%s port=%s; ready endpoints=%s\n' \
    "$exporter_name" "$service_ports" "$exporter_name" "${endpoint_port:-none}" \
    "$endpoint_count"
  [[ -n "$endpoint_port" && "$endpoint_count" -gt 0 ]] || status=1
  return "$status"
}

stage_prometheus_target() {
  local response target_count healths errors
  if ! response="$(
    flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
      '/api/v1/targets?state=active' 2>&1
  )"; then
    echo "Prometheus targets API failed: $(printf '%s' "$response" | bounded_text)" >&2
    return 1
  fi
  [[ "$(yq -r '.status // ""' <<<"$response")" == 'success' ]] || {
    echo 'Prometheus targets API did not return status=success.' >&2
    return 1
  }
  target_count="$(flux_alerts_target_count "$exporter_name" "$namespace" <<<"$response")"
  healths="$(flux_alerts_target_healths "$exporter_name" "$namespace" <<<"$response")"
  printf '  discovered targets=%s health=%s\n' "$target_count" "${healths:-none}"
  errors="$(flux_alerts_target_errors "$exporter_name" "$namespace" <<<"$response")"
  if [[ -n "$errors" ]]; then
    echo '  bounded target errors:'
    printf '%s\n' "$errors" | bounded_text | sed 's/^/    /'
  fi
  [[ "$target_count" -gt 0 && "$healths" == 'up' ]]
}

stage_prometheus_metric() {
  local response result_count actual_kinds missing=''
  local group version expected_kind
  local gvk

  if ! response="$(
    flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" \
      "$(flux_alerts_metric_selector)" 2>&1
  )"; then
    echo "Prometheus metric query failed: $(printf '%s' "$response" | bounded_text)" >&2
    return 1
  fi
  [[ "$(yq -r '.status // ""' <<<"$response")" == 'success' ]] || {
    echo 'Prometheus metric query did not return status=success.' >&2
    return 1
  }
  result_count="$(yq -r '.data.result | length' <<<"$response")"
  actual_kinds="$(flux_alerts_metric_kinds <<<"$response")"
  for gvk in "${configured_gvks[@]}"; do
    IFS=$'\t' read -r group version expected_kind <<<"$gvk"
    if ! rg -Fxq "$expected_kind" <<<"$actual_kinds"; then
      missing+="${missing:+,}${expected_kind}"
    fi
  done
  printf '  Prometheus series=%s kinds=%s\n' \
    "$result_count" "$(paste -sd, - <<<"$actual_kinds")"
  if [[ -n "$missing" ]]; then
    echo "  Missing configured representative kinds: $missing" >&2
  fi
  if [[ "$raw_metric_present" == 'true' && "$result_count" -eq 0 ]]; then
    echo '  Boundary hint: the exporter has gotk_resource_info, but Prometheus does not; inspect Service/ServiceMonitor and target discovery.' >&2
  fi
  [[ "$result_count" -gt 0 && -z "$missing" ]]
}

stage_prometheus_rule() {
  local response rows found=0 status=0
  local name state health last_error
  if ! response="$(
    flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
      '/api/v1/rules?type=alert' 2>&1
  )"; then
    echo "Prometheus rules API failed: $(printf '%s' "$response" | bounded_text)" >&2
    return 1
  fi
  [[ "$(yq -r '.status // ""' <<<"$response")" == 'success' ]] || return 1
  rows="$(
    flux_alerts_rule_rows FluxReconciliationFailure FluxResourceMetricsMissing \
      <<<"$response"
  )"
  while IFS=$'\t' read -r name state health last_error; do
    [[ -n "$name" ]] || continue
    found=$((found + 1))
    printf '  %-34s state=%-9s health=%s\n' "$name" "$state" "$health"
    [[ "$health" == 'ok' && -z "$last_error" ]] || {
      echo "    error=$(printf '%s' "$last_error" | bounded_text)" >&2
      status=1
    }
  done <<<"$rows"
  [[ "$found" -eq 2 ]] || {
    echo "Expected two Flux alert rules from Prometheus; found $found." >&2
    status=1
  }
  return "$status"
}

stage_alertmanager() {
  local status=0 response active_count encoded config_file route_match
  config_file="$temp_dir/alertmanager.yaml"

  if curl --silent --show-error --fail --max-time 20 \
    --resolve "$alertmanager_resolve" \
    "${alertmanager_base_url}/-/healthy" >/dev/null; then
    echo '  Alertmanager health=up'
  else
    echo '  Alertmanager health=down' >&2
    status=1
  fi

  if response="$(
    flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
      '/api/v1/alertmanagers' 2>&1
  )" && [[ "$(yq -r '.status // ""' <<<"$response")" == 'success' ]]; then
    active_count="$(flux_alerts_active_alertmanager_count <<<"$response")"
    printf '  Prometheus active Alertmanagers=%s\n' "$active_count"
    [[ "$active_count" -gt 0 ]] || status=1
  else
    echo "  Prometheus Alertmanager discovery failed: $(printf '%s' "$response" | bounded_text)" >&2
    status=1
  fi

  encoded="$(
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      get secret alertmanager-kube-prometheus-stack-alertmanager-generated \
      --output jsonpath='{.data.alertmanager\.yaml\.gz}' 2>/dev/null ||
      true
  )"
  if [[ -n "$encoded" ]] &&
    printf '%s' "$encoded" | base64 -d | gunzip >"$config_file" 2>/dev/null; then
    if yq -e '
      .receivers[] |
      select(.name == "ntfy") |
      (.webhook_configs | length) > 0
    ' "$config_file" >/dev/null 2>&1; then
      echo '  Alertmanager receiver ntfy=loaded'
    else
      echo '  Alertmanager receiver ntfy=missing' >&2
      status=1
    fi
    route_match="$(
      yq -r '
        .route.routes[] |
        select(.receiver == "ntfy") |
        .matchers[]
      ' "$config_file" 2>/dev/null |
        rg 'severity.*critical.*warning' ||
        true
    )"
    if [[ -n "$route_match" ]]; then
      echo '  severity warning/critical route to ntfy=loaded'
    else
      echo '  severity warning/critical route to ntfy=missing' >&2
      status=1
    fi
  else
    echo '  Could not inspect the generated Alertmanager routing config.' >&2
    status=1
  fi
  return "$status"
}

record_stage() {
  local label="$1"
  local result="$2"
  local slug result_word fragment

  stage_index=$((stage_index + 1))
  stage_labels+=("$label")
  stage_results+=("$result")
  if [[ -n "${TEST_RESULT_FRAGMENT_DIR:-}" ]]; then
    slug="$(
      tr '[:upper:] ' '[:lower:]-' <<<"$label" |
        tr -cd 'a-z0-9-\n'
    )"
    result_word='passed'
    [[ "$result" == 'PASS' ]] || result_word='failed'
    fragment="$TEST_RESULT_FRAGMENT_DIR/$(printf '%02d' "$stage_index")-${slug}.xml"
    write_result_case_junit "$fragment" "$suite_id" "$slug" "$result_word" 0
  fi
}

run_stage() {
  local label="$1"
  local function_name="$2"
  local result='PASS'
  echo
  echo "=== $label ==="
  "$function_name" || result='FAIL'
  record_stage "$label" "$result"
}

print_stage_table() {
  local first_broken=''
  local index

  echo
  printf '%-35s %s\n' 'Stage' 'Result'
  printf '%-35s %s\n' '-----------------------------------' '------'
  for index in "${!stage_labels[@]}"; do
    printf '%-35s %s\n' "${stage_labels[$index]}" "${stage_results[$index]}"
    if [[ -z "$first_broken" && "${stage_results[$index]}" == 'FAIL' ]]; then
      first_broken="${stage_labels[$index]}"
    fi
  done
  echo
  if [[ -n "$first_broken" ]]; then
    echo 'First broken stage:'
    echo "$first_broken"
    return 1
  fi
  echo 'First broken stage:'
  echo 'none'
}

flux_alerts_diagnostics_main() {
  [[ "$#" -eq 1 ]] || {
    echo 'Usage: flux-alerts.sh <kubeconfig>' >&2
    return 2
  }
  kubeconfig="$1"
  [[ -f "$kubeconfig" ]] || {
    echo "Missing kubeconfig: $kubeconfig" >&2
    return 1
  }
  [[ -f "$exporter_values" ]] || {
    echo "Missing exporter source: $exporter_values" >&2
    return 1
  }
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-flux-alerts-diagnostics.XXXXXX")"
  trap 'rm -rf -- "$temp_dir"' EXIT

  if ! load_configured_gvks; then
    echo 'The configured Flux resource set could not be loaded; dependent stages will fail.' >&2
  fi

  run_stage 'Flux resources' stage_flux_resources
  run_stage 'Exporter list/watch RBAC' stage_exporter_rbac
  run_stage 'Exporter workload' stage_exporter_workload
  run_stage 'Exporter raw metric' stage_exporter_raw_metric
  run_stage 'Service/ServiceMonitor' stage_service_monitor
  run_stage 'Prometheus scrape target' stage_prometheus_target
  run_stage 'Prometheus metric' stage_prometheus_metric
  run_stage 'Flux alert rule loaded' stage_prometheus_rule
  run_stage 'Alertmanager' stage_alertmanager

  print_stage_table
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  flux_alerts_diagnostics_main "$@"
fi
