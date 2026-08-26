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
    printf 'synthetic-longhorn-volume'
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
    cat <<'JSON'
{"status":"success","data":{"activeTargets":[{"discoveredLabels":{"__meta_kubernetes_service_name":"loki","__address__":"192.0.2.10:3100"},"scrapePool":"serviceMonitor/monitoring/loki/0","health":"up","lastError":""},{"discoveredLabels":{"__meta_kubernetes_service_name":"alloy-logs","__address__":"192.0.2.11:12345"},"scrapePool":"serviceMonitor/monitoring/alloy-logs/0","health":"up","lastError":""},{"discoveredLabels":{"__meta_kubernetes_service_name":"alloy-events","__address__":"192.0.2.12:12345"},"scrapePool":"serviceMonitor/monitoring/alloy-events/0","health":"up","lastError":""}]}}
JSON
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

run_case trim-only 0 'Logging acceptance passed' 2
rg -F -q -- '--context homelab-diagnostic' "$fixture/trim-only/kubectl.log"
rg -F -q -- 'get persistentvolume synthetic-pv-name --output jsonpath={.spec.csi.volumeHandle}' "$fixture/trim-only/kubectl.log"
rg -F -q -- 'get volumes.longhorn.io synthetic-longhorn-volume --output json' "$fixture/trim-only/kubectl.log"
if rg -F -q -- 'storage-loki-0' "$fixture/trim-only/kubectl.log"; then
  echo 'Verifier assumed the generated Loki PVC name.' >&2
  exit 1
fi

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

run_case default-group 1 'forbidden recurring-job assignment recurring-job-group.longhorn.io/default' 0
run_case daily-snapshot 1 'forbidden recurring-job assignment recurring-job.longhorn.io/daily-snapshot' 0
run_case daily-backup 1 'forbidden recurring-job assignment recurring-job.longhorn.io/daily-backup' 0
run_case trim-missing 1 'does not have the required filesystem-trim assignment' 0
run_case forbidden-label 1 'forbidden indexed label pod_uid' 2
run_case missing-kubernetes 1 'Missing nonzero Loki aggregate count: Kubernetes containers.' 2
run_case missing-talos 1 'Missing nonzero Loki aggregate count: Talos services.' 2
run_case missing-kernel 1 'Missing nonzero Loki aggregate count: Talos kernel.' 2
run_case missing-events 1 'Missing nonzero Loki aggregate count: Kubernetes Events.' 2

echo 'Logging live-acceptance verifier fixture tests passed.'
