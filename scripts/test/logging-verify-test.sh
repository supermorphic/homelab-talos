#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/verify/logging.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/logging-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/tmp"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'kubectl' >>"$FAKE_KUBECTL_LOG"
printf ' %s' "$@" >>"$FAKE_KUBECTL_LOG"
printf '\n' >>"$FAKE_KUBECTL_LOG"

if [[ " $* " == *' config get-contexts homelab-diagnostic --no-headers '* ]]; then
  [[ "$FAKE_LAYOUT" != 'missing-diagnostic-context' ]] || exit 1
  printf 'homelab-diagnostic\n'
  exit 0
fi

if [[ " $* " == *' port-forward '* && " $* " == *' service/loki :3100 '* ]]; then
  printf 'loki start %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
  trap 'printf "loki stop %s\n" "$BASHPID" >>"$FAKE_PROCESS_LOG"; exit 0' TERM INT
  printf 'Forwarding from 127.0.0.1:23100 -> 3100\n'
  while true; do /bin/sleep 1; done
fi

if [[ " $* " == *' port-forward '* && \
  " $* " == *' service/kube-prometheus-stack-prometheus :9090 '* ]]; then
  printf 'prometheus start %s\n' "$BASHPID" >>"$FAKE_PROCESS_LOG"
  trap 'printf "prometheus stop %s\n" "$BASHPID" >>"$FAKE_PROCESS_LOG"; exit 0' TERM INT
  printf 'Forwarding from 127.0.0.1:29090 -> 9090\n'
  while true; do /bin/sleep 1; done
fi

case " $* " in
  *' wait --for=condition=Ready '*)
    exit 0
    ;;
  *' rollout status '*)
    exit 0
    ;;
  *' --namespace monitoring get pvc --output json '*)
    cat <<'JSON'
{"items":[{"metadata":{"name":"unrelated-claim","labels":{"app.kubernetes.io/name":"other"}},"spec":{"resources":{"requests":{"storage":"1Gi"}},"volumeName":"unrelated-pv"},"status":{"phase":"Bound"}},{"metadata":{"name":"telemetry-claim-synthetic","labels":{"recurring-job.longhorn.io/source":"enabled","recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"spec":{"resources":{"requests":{"storage":"50Gi"}},"volumeName":"synthetic-pv-name"},"status":{"phase":"Bound"}}]}
JSON
    ;;
  *' get persistentvolume synthetic-pv-name --output jsonpath={.spec.csi.volumeHandle} '*)
    echo 'PersistentVolume reads are forbidden in the diagnostic verifier.' >&2
    exit 65
    ;;
  *' --namespace longhorn-system get volumes.longhorn.io --output json '*)
    case "$FAKE_LAYOUT" in
      longhorn-status-missing)
        cat <<'JSON'
{"items":[{"metadata":{"name":"synthetic-longhorn-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"status":{"kubernetesStatus":{"pvName":"synthetic-pv-name","pvcName":"telemetry-claim-synthetic"}}},{"metadata":{"name":"unrelated-volume"},"status":{"kubernetesStatus":{"pvName":"unrelated-pv","pvcName":"unrelated-claim","namespace":"other"}}}]}
JSON
        ;;
      longhorn-status-mismatch)
        cat <<'JSON'
{"items":[{"metadata":{"name":"synthetic-longhorn-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"status":{"kubernetesStatus":{"pvName":"different-pv","pvcName":"telemetry-claim-synthetic","namespace":"monitoring"}}},{"metadata":{"name":"unrelated-volume"},"status":{"kubernetesStatus":{"pvName":"unrelated-pv","pvcName":"unrelated-claim","namespace":"other"}}}]}
JSON
        ;;
      longhorn-status-ambiguous)
        cat <<'JSON'
{"items":[{"metadata":{"name":"synthetic-longhorn-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"status":{"kubernetesStatus":{"pvName":"synthetic-pv-name","pvcName":"telemetry-claim-synthetic","namespace":"monitoring"}}},{"metadata":{"name":"duplicate-synthetic-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"status":{"kubernetesStatus":{"pvName":"synthetic-pv-name","pvcName":"telemetry-claim-synthetic","namespace":"monitoring"}}}]}
JSON
        ;;
      *)
        cat <<'JSON'
{"items":[{"metadata":{"name":"synthetic-longhorn-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"},"annotations":{"fixture-canary":"private-volume-object-value"}},"status":{"kubernetesStatus":{"pvName":"synthetic-pv-name","pvcName":"telemetry-claim-synthetic","namespace":"monitoring"}}},{"metadata":{"name":"unrelated-volume"},"status":{"kubernetesStatus":{"pvName":"unrelated-pv","pvcName":"unrelated-claim","namespace":"other"}}}]}
JSON
        ;;
    esac
    ;;
  *' --namespace longhorn-system get volumes.longhorn.io synthetic-longhorn-volume --output json '*)
    case "$FAKE_LAYOUT" in
      default-group)
        labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled","recurring-job-group.longhorn.io/default":"enabled"}'
        ;;
      daily-snapshot)
        labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled","recurring-job.longhorn.io/daily-snapshot":"enabled"}'
        ;;
      daily-backup)
        labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled","recurring-job.longhorn.io/daily-backup":"enabled"}'
        ;;
      trim-missing)
        labels='{"longhornvolume":"synthetic-longhorn-volume"}'
        ;;
      extra-recurring-job)
        labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled","recurring-job.longhorn.io/invented-maintenance":"enabled"}'
        ;;
      *)
        labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}'
        ;;
    esac
    printf '{"metadata":{"name":"synthetic-longhorn-volume","labels":%s,"annotations":{"fixture-canary":"private-volume-object-value"}}}\n' "$labels"
    ;;
  *' --namespace longhorn-system get recurringjobs.longhorn.io loki-filesystem-trim --output jsonpath={.spec.task} '*)
    printf 'filesystem-trim'
    ;;
  *)
    echo "Unexpected kubectl invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'curl' >>"$FAKE_CURL_LOG"
printf ' %s' "$@" >>"$FAKE_CURL_LOG"
printf '\n' >>"$FAKE_CURL_LOG"

case " $* " in
  *' http://127.0.0.1:23100/ready '*)
    printf 'ready\n'
    ;;
  *' http://127.0.0.1:23100/loki/api/v1/labels '*)
    if [[ "$FAKE_LAYOUT" == 'forbidden-label' ]]; then
      printf '{"status":"success","data":["app","cluster","pod_uid","source"]}\n'
    else
      printf '{"status":"success","data":["app","cluster","container","event_type","namespace","node","service","source","stream"]}\n'
    fi
    ;;
  *' http://127.0.0.1:23100/loki/api/v1/query '*)
    count=7
    case "$FAKE_LAYOUT:$*" in
      missing-kubernetes:*'query=sum(count_over_time({source="kubernetes"}[30m]))'*) count=0 ;;
      missing-talos:*'query=sum(count_over_time({source="talos"}[30m]))'*) count=0 ;;
      missing-kernel:*'query=sum(count_over_time({source="talos",service="kernel"}[30m]))'*) count=0 ;;
      missing-events:*'query=sum(count_over_time({source="kubernetes_event"}[30m]))'*) count=0 ;;
    esac
    if [[ "$count" -eq 0 ]]; then
      printf '{"status":"success","data":{"resultType":"vector","result":[]}}\n'
    else
      printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1787702400,"%s"]}]}}\n' "$count"
    fi
    ;;
  *' http://127.0.0.1:29090/api/v1/targets?state=active '*)
    loki_service='loki'
    loki_pool='serviceMonitor/monitoring/loki/0'
    loki_job='monitoring/loki'
    alloy_logs_service='alloy-logs'
    alloy_logs_pool='serviceMonitor/monitoring/alloy-logs/0'
    alloy_logs_job='monitoring/alloy-logs'
    alloy_events_service='alloy-events'
    alloy_events_pool='serviceMonitor/monitoring/alloy-events/0'
    alloy_events_job='monitoring/alloy-events'
    case "$FAKE_LAYOUT" in
      unrelated-loki-target)
        loki_service='unrelated'
        loki_pool='serviceMonitor/monitoring/unrelated-loki/0'
        loki_job='monitoring/unrelated-loki'
        ;;
      unrelated-alloy-logs-target)
        alloy_logs_service='unrelated'
        alloy_logs_pool='serviceMonitor/monitoring/unrelated-alloy-logs/0'
        alloy_logs_job='monitoring/unrelated-alloy-logs'
        ;;
      unrelated-alloy-events-target)
        alloy_events_service='unrelated'
        alloy_events_pool='serviceMonitor/monitoring/unrelated-alloy-events/0'
        alloy_events_job='monitoring/unrelated-alloy-events'
        ;;
    esac
    printf '{"status":"success","data":{"activeTargets":[{"discoveredLabels":{"__meta_kubernetes_service_name":"%s","__address__":"192.0.2.10:3100"},"labels":{"service":"%s","job":"%s"},"scrapePool":"%s","health":"up","lastError":""},{"discoveredLabels":{"__meta_kubernetes_service_name":"%s","__address__":"192.0.2.11:12345"},"labels":{"service":"%s","job":"%s"},"scrapePool":"%s","health":"up","lastError":""},{"discoveredLabels":{"__meta_kubernetes_service_name":"%s","__address__":"192.0.2.12:12345"},"labels":{"service":"%s","job":"%s"},"scrapePool":"%s","health":"up","lastError":""}]}}\n' \
      "$loki_service" "$loki_service" "$loki_job" "$loki_pool" \
      "$alloy_logs_service" "$alloy_logs_service" "$alloy_logs_job" "$alloy_logs_pool" \
      "$alloy_events_service" "$alloy_events_service" "$alloy_events_job" "$alloy_events_pool"
    ;;
  *' http://127.0.0.1:29090/api/v1/rules?type=alert '*)
    cat <<'JSON'
{"status":"success","data":{"groups":[{"name":"centralized-logging","rules":[{"name":"LokiMetricsMissing","health":"ok","lastError":""},{"name":"AlloyInstanceCountLow","health":"ok","lastError":""},{"name":"AlloyLogDeliveryDrops","health":"ok","lastError":""},{"name":"LokiLogEntriesDiscarded","health":"ok","lastError":""},{"name":"LokiRequestErrors","health":"ok","lastError":""},{"name":"LokiCompactorStalled","health":"ok","lastError":""},{"name":"LokiStorageUsageHigh","health":"ok","lastError":""},{"name":"LokiStorageUsageCritical","health":"ok","lastError":""}]}]}}
JSON
    ;;
  *)
    echo "Unexpected curl invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/curl"

cat >"$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fixture/bin/sleep"

run_case() {
  local layout="$1"
  local expected_status="$2"
  local expected_message="$3"
  local expected_forwards="$4"
  local case_root="$fixture/$layout"
  local output status

  mkdir -p "$case_root"
  : >"$case_root/kubectl.log"
  : >"$case_root/curl.log"
  : >"$case_root/process.log"
  output="$case_root/output"

  set +e
  PATH="$fixture/bin:$PATH" \
    TMPDIR="$fixture/tmp" \
    FAKE_LAYOUT="$layout" \
    FAKE_KUBECTL_LOG="$case_root/kubectl.log" \
    FAKE_CURL_LOG="$case_root/curl.log" \
    FAKE_PROCESS_LOG="$case_root/process.log" \
    "$verifier" "$fixture/kubeconfig" >"$output" 2>&1
  status="$?"
  set -e

  [[ "$status" -eq "$expected_status" ]] || {
    echo "$layout: expected exit $expected_status, got $status" >&2
    cat "$output" >&2
    exit 1
  }
  rg -F -q -- "$expected_message" "$output" || {
    echo "$layout: missing expected diagnostic: $expected_message" >&2
    cat "$output" >&2
    exit 1
  }
  [[ "$(rg -c ' start ' "$case_root/process.log" || true)" -eq "$expected_forwards" ]]
  [[ "$(rg -c ' stop ' "$case_root/process.log" || true)" -eq "$expected_forwards" ]]
  [[ -z "$(find "$fixture/tmp" -mindepth 1 -print -quit)" ]] || {
    echo "$layout: verifier left temporary files behind" >&2
    find "$fixture/tmp" -mindepth 1 -maxdepth 2 -print >&2
    exit 1
  }
  if rg -F -q -- 'private-volume-object-value' "$output"; then
    echo "$layout: verifier printed the Longhorn Volume fixture" >&2
    exit 1
  fi
}

selected_case="${1:-all}"
case_selected() {
  [[ "$selected_case" == 'all' || "$selected_case" == "$1" ]]
}

if case_selected trim-only; then
  run_case trim-only 0 'Logging acceptance passed' 2
  rg -F -q -- '--context homelab-diagnostic' "$fixture/trim-only/kubectl.log"
  rg -F -q -- 'get volumes.longhorn.io --output json' "$fixture/trim-only/kubectl.log"
  if rg -q -- ' get persistentvolume(s)? ' "$fixture/trim-only/kubectl.log"; then
    echo 'Verifier attempted a forbidden PersistentVolume read.' >&2
    exit 1
  fi
  if rg -F -q -- 'storage-loki-0' "$fixture/trim-only/kubectl.log"; then
    echo 'Verifier assumed the generated Loki PVC name.' >&2
    exit 1
  fi
fi

if case_selected all-counts-present; then
  run_case all-counts-present 0 'Logging acceptance passed' 2
  for query in \
    'sum(count_over_time({source="kubernetes"}[30m]))' \
    'sum(count_over_time({source="talos"}[30m]))' \
    'sum(count_over_time({source="talos",service="kernel"}[30m]))' \
    'sum(count_over_time({source="kubernetes_event"}[30m]))'; do
    rg -F -q -- "query=$query" "$fixture/all-counts-present/curl.log"
  done
  [[ "$(rg -c '/loki/api/v1/query$' "$fixture/all-counts-present/curl.log")" -eq 4 ]]
  if rg -q '/loki/api/v1/(query_range|tail)| query=\{source=' \
    "$fixture/all-counts-present/curl.log"; then
    echo 'Verifier requested raw Loki entries instead of bounded aggregate counts.' >&2
    exit 1
  fi
fi

case_selected missing-diagnostic-context && \
  run_case missing-diagnostic-context 2 'Logging verification requires kubeconfig context homelab-diagnostic.' 0
case_selected longhorn-status-missing && \
  run_case longhorn-status-missing 1 'with complete status.kubernetesStatus identity; found 0.' 0
case_selected longhorn-status-mismatch && \
  run_case longhorn-status-mismatch 1 'with complete status.kubernetesStatus identity; found 0.' 0
case_selected longhorn-status-ambiguous && \
  run_case longhorn-status-ambiguous 1 'with complete status.kubernetesStatus identity; found 2.' 0
case_selected default-group && \
  run_case default-group 1 'forbidden recurring-job assignment recurring-job-group.longhorn.io/default' 0
case_selected daily-snapshot && \
  run_case daily-snapshot 1 'forbidden recurring-job assignment recurring-job.longhorn.io/daily-snapshot' 0
case_selected daily-backup && \
  run_case daily-backup 1 'forbidden recurring-job assignment recurring-job.longhorn.io/daily-backup' 0
case_selected trim-missing && \
  run_case trim-missing 1 'does not have the required filesystem-trim assignment' 0
case_selected extra-recurring-job && \
  run_case extra-recurring-job 1 'has an unexpected recurring-job assignment after synchronization retries' 0
case_selected forbidden-label && \
  run_case forbidden-label 1 'forbidden indexed label pod_uid' 2
case_selected missing-kubernetes && \
  run_case missing-kubernetes 1 'Missing nonzero Loki aggregate count: Kubernetes containers.' 2
case_selected missing-talos && \
  run_case missing-talos 1 'Missing nonzero Loki aggregate count: Talos services.' 2
case_selected missing-kernel && \
  run_case missing-kernel 1 'Missing nonzero Loki aggregate count: Talos kernel.' 2
case_selected missing-events && \
  run_case missing-events 1 'Missing nonzero Loki aggregate count: Kubernetes Events.' 2
case_selected unrelated-loki-target && \
  run_case unrelated-loki-target 1 'Prometheus does not have an exact up loki ServiceMonitor target.' 2
case_selected unrelated-alloy-logs-target && \
  run_case unrelated-alloy-logs-target 1 'Prometheus does not have an exact up alloy-logs ServiceMonitor target.' 2
case_selected unrelated-alloy-events-target && \
  run_case unrelated-alloy-events-target 1 'Prometheus does not have an exact up alloy-events ServiceMonitor target.' 2

echo 'Logging live-acceptance verifier fixture tests passed.'
