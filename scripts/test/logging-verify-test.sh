#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/verify/logging.sh"
real_python="$(command -v python)"
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
  if [[ "$FAKE_LAYOUT" == 'prometheus-port-forward-fails' ]]; then
    exit 67
  fi
  trap 'printf "prometheus stop %s\n" "$BASHPID" >>"$FAKE_PROCESS_LOG"; exit 0' TERM INT
  printf 'Forwarding from 127.0.0.1:29090 -> 9090\n'
  while true; do /bin/sleep 1; done
fi

case " $* " in
  *' wait --for=condition=Ready '*) exit 0 ;;
  *' rollout status '*) exit 0 ;;
  *' get nodes --output json '*)
    cat <<'JSON'
{"items":[{"metadata":{"name":"private-node-identity-a"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"private-node-identity-b"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"private-node-identity-c"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
    ;;
  *' --namespace monitoring get daemonset alloy-logs --output json '*)
    if [[ "$FAKE_LAYOUT" == 'healthy-two-pod-daemonset' ]]; then scheduled=2; else scheduled=3; fi
    printf '{"metadata":{"generation":7},"status":{"observedGeneration":7,"desiredNumberScheduled":%s,"currentNumberScheduled":%s,"updatedNumberScheduled":%s,"numberReady":%s,"numberAvailable":%s,"numberMisscheduled":0,"numberUnavailable":0}}\n' \
      "$scheduled" "$scheduled" "$scheduled" "$scheduled" "$scheduled"
    ;;
  *' --namespace monitoring get deployment alloy-events --output json '*)
    if [[ "$FAKE_LAYOUT" == 'two-alloy-events-pods' ]]; then replicas=2; else replicas=1; fi
    printf '{"metadata":{"generation":8},"spec":{"replicas":%s},"status":{"observedGeneration":8,"replicas":%s,"updatedReplicas":%s,"readyReplicas":%s,"availableReplicas":%s,"unavailableReplicas":0}}\n' \
      "$replicas" "$replicas" "$replicas" "$replicas" "$replicas"
    ;;
  *' --namespace monitoring get statefulset loki --output json '*)
    if [[ "$FAKE_LAYOUT" == 'two-loki-pods' ]]; then replicas=2; else replicas=1; fi
    if [[ "$FAKE_LAYOUT" == 'ambiguous-mounted-claim' ]]; then
      claim_templates='[{"metadata":{"name":"storage"}},{"metadata":{"name":"archive"}}]'
    else
      claim_templates='[{"metadata":{"name":"storage"}}]'
    fi
    printf '{"metadata":{"name":"loki","uid":"private-loki-statefulset-uid","generation":9},"spec":{"replicas":%s,"volumeClaimTemplates":%s},"status":{"observedGeneration":9,"replicas":%s,"currentReplicas":%s,"updatedReplicas":%s,"readyReplicas":%s,"availableReplicas":%s,"currentRevision":"private-revision","updateRevision":"private-revision"}}\n' \
      "$replicas" "$claim_templates" "$replicas" "$replicas" "$replicas" "$replicas" "$replicas"
    ;;
  *' --namespace monitoring get pods --selector app.kubernetes.io/instance=alloy-logs,app.kubernetes.io/name=alloy --output json '*)
    if [[ "$FAKE_LAYOUT" == 'healthy-two-pod-daemonset' ]]; then
      cat <<'JSON'
{"items":[{"metadata":{"name":"private-alloy-log-pod-a"},"spec":{"nodeName":"private-node-identity-a"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"private-alloy-log-pod-b"},"spec":{"nodeName":"private-node-identity-b"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
    elif [[ "$FAKE_LAYOUT" == 'duplicate-alloy-log-node' ]]; then
      cat <<'JSON'
{"items":[{"metadata":{"name":"private-alloy-log-pod-a"},"spec":{"nodeName":"private-node-identity-a"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"private-alloy-log-pod-b"},"spec":{"nodeName":"private-node-identity-a"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"private-alloy-log-pod-c"},"spec":{"nodeName":"private-node-identity-c"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
    else
      cat <<'JSON'
{"items":[{"metadata":{"name":"private-alloy-log-pod-a"},"spec":{"nodeName":"private-node-identity-a"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"private-alloy-log-pod-b"},"spec":{"nodeName":"private-node-identity-b"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"private-alloy-log-pod-c"},"spec":{"nodeName":"private-node-identity-c"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
    fi
    ;;
  *' --namespace monitoring get pods --selector app.kubernetes.io/instance=alloy-events,app.kubernetes.io/name=alloy --output json '*)
    if [[ "$FAKE_LAYOUT" == 'two-alloy-events-pods' ]]; then
      cat <<'JSON'
{"items":[{"metadata":{"name":"private-alloy-event-pod-a"},"spec":{"nodeName":"private-node-identity-a"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"private-alloy-event-pod-b"},"spec":{"nodeName":"private-node-identity-b"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
    else
      cat <<'JSON'
{"items":[{"metadata":{"name":"private-alloy-event-pod-a"},"spec":{"nodeName":"private-node-identity-a"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
    fi
    ;;
  *' --namespace monitoring get pods --selector app.kubernetes.io/instance=loki,app.kubernetes.io/name=loki --output json '*)
    if [[ "$FAKE_LAYOUT" == 'two-loki-pods' ]]; then
      cat <<'JSON'
{"items":[{"metadata":{"name":"private-loki-pod-a"},"spec":{"nodeName":"private-node-identity-a"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"private-loki-pod-b"},"spec":{"nodeName":"private-node-identity-b"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}
JSON
    else
      owner_uid='private-loki-statefulset-uid'
      [[ "$FAKE_LAYOUT" != 'loki-pod-owner-mismatch' ]] || owner_uid='private-other-statefulset-uid'
      case "$FAKE_LAYOUT" in
        missing-mounted-claim) volumes='[]' ;;
        ambiguous-mounted-claim) volumes='[{"name":"storage","persistentVolumeClaim":{"claimName":"private-telemetry-claim"}},{"name":"archive","persistentVolumeClaim":{"claimName":"private-archive-claim"}}]' ;;
        mismatched-mounted-claim) volumes='[{"name":"foreign-storage","persistentVolumeClaim":{"claimName":"private-telemetry-claim"}}]' ;;
        stale-trim-labeled-pvc) volumes='[{"name":"storage","persistentVolumeClaim":{"claimName":"private-active-claim"}}]' ;;
        *) volumes='[{"name":"storage","persistentVolumeClaim":{"claimName":"private-telemetry-claim"}}]' ;;
      esac
      printf '{"items":[{"metadata":{"name":"private-loki-pod-a","ownerReferences":[{"apiVersion":"apps/v1","kind":"StatefulSet","name":"loki","uid":"%s","controller":true}]},"spec":{"nodeName":"private-node-identity-a","volumes":%s},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}\n' \
        "$owner_uid" "$volumes"
    fi
    ;;
  *' --namespace monitoring get pvc --output json '*)
    if [[ "$FAKE_LAYOUT" == 'stale-trim-labeled-pvc' ]]; then
      cat <<'JSON'
{"items":[{"metadata":{"name":"private-active-claim","labels":{"app.kubernetes.io/name":"loki"}},"spec":{"resources":{"requests":{"storage":"50Gi"}},"volumeName":"private-active-pv"},"status":{"phase":"Bound"}},{"metadata":{"name":"private-telemetry-claim","labels":{"recurring-job.longhorn.io/source":"enabled","recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"spec":{"resources":{"requests":{"storage":"50Gi"}},"volumeName":"private-pv-identity"},"status":{"phase":"Bound"}}]}
JSON
    else
      cat <<'JSON'
{"items":[{"metadata":{"name":"unrelated-claim","labels":{"app.kubernetes.io/name":"other"}},"spec":{"resources":{"requests":{"storage":"1Gi"}},"volumeName":"unrelated-pv"},"status":{"phase":"Bound"}},{"metadata":{"name":"private-telemetry-claim","labels":{"recurring-job.longhorn.io/source":"enabled","recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"spec":{"resources":{"requests":{"storage":"50Gi"}},"volumeName":"private-pv-identity"},"status":{"phase":"Bound"}}]}
JSON
    fi
    ;;
  *' get persistentvolume private-pv-identity --output jsonpath={.spec.csi.volumeHandle} '*)
    echo 'PersistentVolume reads are forbidden in the diagnostic verifier.' >&2
    exit 65
    ;;
  *' --namespace longhorn-system get volumes.longhorn.io --output json '*)
    case "$FAKE_LAYOUT" in
      longhorn-status-missing)
        cat <<'JSON'
{"items":[{"metadata":{"name":"private-longhorn-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"status":{"kubernetesStatus":{"pvName":"private-pv-identity","pvcName":"private-telemetry-claim"}}},{"metadata":{"name":"unrelated-volume"},"status":{"kubernetesStatus":{"pvName":"unrelated-pv","pvcName":"unrelated-claim","namespace":"other"}}}]}
JSON
        ;;
      longhorn-status-mismatch)
        cat <<'JSON'
{"items":[{"metadata":{"name":"private-longhorn-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"status":{"kubernetesStatus":{"pvName":"different-pv","pvcName":"private-telemetry-claim","namespace":"monitoring"}}},{"metadata":{"name":"unrelated-volume"},"status":{"kubernetesStatus":{"pvName":"unrelated-pv","pvcName":"unrelated-claim","namespace":"other"}}}]}
JSON
        ;;
      longhorn-status-ambiguous)
        cat <<'JSON'
{"items":[{"metadata":{"name":"private-longhorn-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"status":{"kubernetesStatus":{"pvName":"private-pv-identity","pvcName":"private-telemetry-claim","namespace":"monitoring"}}},{"metadata":{"name":"private-duplicate-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}},"status":{"kubernetesStatus":{"pvName":"private-pv-identity","pvcName":"private-telemetry-claim","namespace":"monitoring"}}}]}
JSON
        ;;
      *)
        cat <<'JSON'
{"items":[{"metadata":{"name":"private-longhorn-volume","labels":{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"},"annotations":{"fixture-canary":"private-volume-object-value"}},"status":{"kubernetesStatus":{"pvName":"private-pv-identity","pvcName":"private-telemetry-claim","namespace":"monitoring"}}},{"metadata":{"name":"unrelated-volume"},"status":{"kubernetesStatus":{"pvName":"unrelated-pv","pvcName":"unrelated-claim","namespace":"other"}}}]}
JSON
        ;;
    esac
    ;;
  *' --namespace longhorn-system get volumes.longhorn.io private-longhorn-volume --output json '*)
    case "$FAKE_LAYOUT" in
      default-group) labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled","recurring-job-group.longhorn.io/default":"enabled"}' ;;
      daily-snapshot) labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled","recurring-job.longhorn.io/daily-snapshot":"enabled"}' ;;
      daily-backup) labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled","recurring-job.longhorn.io/daily-backup":"enabled"}' ;;
      trim-missing) labels='{"longhornvolume":"private-longhorn-volume"}' ;;
      extra-recurring-job) labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled","recurring-job.longhorn.io/invented-maintenance":"enabled"}' ;;
      *) labels='{"recurring-job.longhorn.io/loki-filesystem-trim":"enabled"}' ;;
    esac
    printf '{"metadata":{"name":"private-longhorn-volume","labels":%s,"annotations":{"fixture-canary":"private-volume-object-value"}}}\n' "$labels"
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
  *' http://127.0.0.1:23100/ready '*) printf 'ready\n' ;;
  *' http://127.0.0.1:23100/config/tenant/v1/limits '*)
    case "$FAKE_LAYOUT" in
      wrong-runtime-retention) printf '{"retention_period":"13d","retention_stream":[],"discover_service_name":[]}\n' ;;
      malformed-runtime-retention) printf '{"retention_period":["not-a-duration"],"retention_stream":[],"discover_service_name":[]}\n' ;;
      runtime-retention-stream-override) printf '{"retention_period":"2w","retention_stream":[{"selector":"{namespace=\\"short\\"}","priority":1,"period":"1d"}],"discover_service_name":[]}\n' ;;
      runtime-discover-service-name-nonempty) printf '{"retention_period":"2w","retention_stream":[],"discover_service_name":["service"]}\n' ;;
      runtime-discover-service-name-missing) printf '{"retention_period":"2w","retention_stream":[]}\n' ;;
      runtime-discover-service-name-malformed) printf '{"retention_period":"2w","retention_stream":[],"discover_service_name":"service"}\n' ;;
      *) printf '{"retention_period":"2w","retention_stream":[],"discover_service_name":[]}\n' ;;
    esac
    ;;
  *' http://127.0.0.1:23100/config?mode=diffs '*)
    case "$FAKE_LAYOUT" in
      runtime-config-unavailable) exit 22 ;;
      runtime-shard-streams-enabled) printf '{"limits_config":{"shard_streams":{"enabled":true}}}\n' ;;
      runtime-shard-streams-missing) printf '{"limits_config":{}}\n' ;;
      runtime-shard-streams-malformed) printf '{"limits_config":{"shard_streams":"disabled"}}\n' ;;
      *) printf '{"limits_config":{"shard_streams":{"enabled":false}}}\n' ;;
    esac
    ;;
  *' http://127.0.0.1:23100/loki/api/v1/labels '*)
    if [[ " $* " == *' query={source="kubernetes"} '* ]]; then
      case "$FAKE_LAYOUT" in
        forbidden-label) data='["app","cluster","container","namespace","node","pod_uid","source","stream"]' ;;
        ip-label) data='["app","client_ip","cluster","container","namespace","node","source","stream"]' ;;
        missing-container-label) data='["app","cluster","container","namespace","node","source"]' ;;
        cross-source-container-label) data='["app","cluster","container","namespace","node","service","source","stream"]' ;;
        global-union-only) data='["app","cluster","container","event_type","namespace","node","service","source","stream"]' ;;
        malformed-label-response) printf '{"status":"success","data":{"labels":[]}}\n'; exit 0 ;;
        *) data='["app","cluster","container","namespace","node","source","stream"]' ;;
      esac
    elif [[ " $* " == *' query={source="talos"} '* ]]; then
      case "$FAKE_LAYOUT" in
        cross-source-talos-label) data='["cluster","namespace","node","service","source"]' ;;
        missing-talos-label) data='["cluster","node","source"]' ;;
        *) data='["cluster","node","service","source"]' ;;
      esac
    elif [[ " $* " == *' query={source="kubernetes_event"} '* ]]; then
      case "$FAKE_LAYOUT" in
        extra-event-label) data='["app","cluster","event_type","namespace","source"]' ;;
        missing-event-label) data='["cluster","event_type","source"]' ;;
        sensitive-name-label) data='["cluster","event_type","namespace","secret_name","source"]' ;;
        *) data='["cluster","event_type","namespace","source"]' ;;
      esac
    else
      printf '{"status":"success","data":["app","cluster","container","event_type","namespace","node","service","source","stream"]}\n'
      exit 0
    fi
    printf '{"status":"success","data":%s}\n' "$data"
    ;;
  *' http://127.0.0.1:23100/loki/api/v1/query '*)
    count=7
    case "$FAKE_LAYOUT:$*" in
      missing-kubernetes:*'query=sum(count_over_time({source="kubernetes"}[30m]))'*) count=0 ;;
      missing-talos-service:*'query=sum(count_over_time({source="talos",service=~".+",service!="kernel"}[30m]))'*) count=0 ;;
      missing-talos-service:*'query=sum(count_over_time({source="talos",service!="kernel"}[30m]))'*) count=0 ;;
      unlabeled-and-kernel-only:*'query=sum(count_over_time({source="talos",service=~".+",service!="kernel"}[30m]))'*) count=0 ;;
      missing-kernel:*'query=sum(count_over_time({source="talos",service="kernel"}[30m]))'*) count=0 ;;
      missing-events:*'query=sum(count_over_time({source="kubernetes_event"}[30m]))'*) count=0 ;;
    esac
    if [[ "$count" -eq 0 ]]; then
      printf '{"status":"success","data":{"resultType":"vector","result":[]}}\n'
    else
      printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1787702400,"%s"]}]}}\n' "$count"
    fi
    ;;
  *' http://127.0.0.1:29090/api/v1/query '*)
    case "$FAKE_LAYOUT" in
      missing-compaction) result='[]' ;;
      stale-compaction) result='[{"metric":{},"value":[1787702400,"10801"]}]' ;;
      future-compaction) result='[{"metric":{},"value":[1787702400,"-1"]}]' ;;
      malformed-compaction) result='[{"metric":{},"value":[1787702400,"not-a-number"]}]' ;;
      *) result='[{"metric":{},"value":[1787702400,"600"]}]' ;;
    esac
    printf '{"status":"success","data":{"resultType":"vector","result":%s}}\n' "$result"
    ;;
  *' http://127.0.0.1:29090/api/v1/targets?state=active '*)
    loki_service='loki'; loki_pool='serviceMonitor/monitoring/loki/0'; loki_job='monitoring/loki'
    alloy_logs_service='alloy-logs'; alloy_logs_pool='serviceMonitor/monitoring/alloy-logs/0'; alloy_logs_job='alloy-logs'
    alloy_events_service='alloy-events'; alloy_events_pool='serviceMonitor/monitoring/alloy-events/0'; alloy_events_job='alloy-events'
    loki_count=1; alloy_logs_count=3; alloy_events_count=1
    case "$FAKE_LAYOUT" in
      unrelated-loki-target) loki_service='unrelated-loki'; loki_pool='serviceMonitor/monitoring/unrelated-loki/0'; loki_job='unrelated-loki' ;;
      unrelated-alloy-logs-target) alloy_logs_service='unrelated-alloy-logs'; alloy_logs_pool='serviceMonitor/monitoring/unrelated-alloy-logs/0'; alloy_logs_job='unrelated-alloy-logs' ;;
      unrelated-alloy-events-target) alloy_events_service='unrelated-alloy-events'; alloy_events_pool='serviceMonitor/monitoring/unrelated-alloy-events/0'; alloy_events_job='unrelated-alloy-events' ;;
      wrong-alloy-logs-job) alloy_logs_job='monitoring/alloy-logs' ;;
      wrong-alloy-events-job) alloy_events_job='monitoring/alloy-events' ;;
      missing-loki-target) loki_count=0 ;;
      extra-loki-target) loki_count=2 ;;
      one-alloy-logs-target) alloy_logs_count=1 ;;
      two-alloy-logs-target) alloy_logs_count=2 ;;
      excess-alloy-logs-target) alloy_logs_count=4 ;;
      missing-alloy-events-target) alloy_events_count=0 ;;
      extra-alloy-events-target) alloy_events_count=2 ;;
    esac
    targets=''
    append_target() {
      local service_name="$1" job="$2" pool="$3" address="$4" health="$5" last_error="$6"
      local target
      printf -v target '{"discoveredLabels":{"__meta_kubernetes_service_name":"%s","__address__":"%s"},"labels":{"service":"%s","job":"%s"},"scrapePool":"%s","health":"%s","lastError":"%s"}' \
        "$service_name" "$address" "$service_name" "$job" "$pool" "$health" "$last_error"
      targets+="${targets:+,}$target"
    }
    for ((index = 0; index < loki_count; index++)); do
      append_target "$loki_service" "$loki_job" "$loki_pool" "192.0.2.$((10 + index)):3100" up ''
    done
    for ((index = 0; index < alloy_logs_count; index++)); do
      health='up'; last_error=''
      if [[ "$FAKE_LAYOUT" == 'unhealthy-alloy-logs-target' && "$index" -eq 2 ]]; then
        health='down'; last_error='fixture scrape failure'
      fi
      append_target "$alloy_logs_service" "$alloy_logs_job" "$alloy_logs_pool" \
        "192.0.2.$((20 + index)):12345" "$health" "$last_error"
    done
    for ((index = 0; index < alloy_events_count; index++)); do
      append_target "$alloy_events_service" "$alloy_events_job" "$alloy_events_pool" \
        "192.0.2.$((30 + index)):12345" up ''
    done
    printf '{"status":"success","data":{"activeTargets":[%s]}}\n' "$targets"
    ;;
  *' http://127.0.0.1:29090/api/v1/rules?type=alert '*)
    cat <<'JSON'
{"status":"success","data":{"groups":[{"name":"centralized-logging","rules":[{"name":"LokiMetricsMissing","health":"ok","lastError":""},{"name":"AlloyInstanceCountLow","health":"ok","lastError":""},{"name":"AlloyLogDeliveryDrops","health":"ok","lastError":""},{"name":"LokiLogEntriesDiscarded","health":"ok","lastError":""},{"name":"LokiRequestErrors","health":"ok","lastError":""},{"name":"LokiCompactorStalled","health":"ok","lastError":""},{"name":"LokiStorageUsageHigh","health":"ok","lastError":""},{"name":"LokiStorageUsageCritical","health":"ok","lastError":""}]}]}}
JSON
    ;;
  *) echo "Unexpected curl invocation: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$fixture/bin/curl"

cat >"$fixture/bin/python" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'python' >>"$FAKE_PYTHON_LOG"
printf ' %s' "$@" >>"$FAKE_PYTHON_LOG"
printf '\n' >>"$FAKE_PYTHON_LOG"
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$fixture/bin/python"

cat >"$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
/bin/sleep 0.001
EOF
chmod +x "$fixture/bin/sleep"

run_case() {
  local layout="$1" expected_status="$2" expected_message="$3" expected_starts="$4" expected_stops="$5"
  local case_root="$fixture/$layout" output status
  mkdir -p "$case_root"
  : >"$case_root/kubectl.log"; : >"$case_root/curl.log"; : >"$case_root/process.log"
  : >"$case_root/python.log"
  output="$case_root/output"

  set +e
  PATH="$fixture/bin:$PATH" TMPDIR="$fixture/tmp" FAKE_LAYOUT="$layout" \
    FAKE_KUBECTL_LOG="$case_root/kubectl.log" FAKE_CURL_LOG="$case_root/curl.log" \
    FAKE_PROCESS_LOG="$case_root/process.log" \
    FAKE_PYTHON_LOG="$case_root/python.log" REAL_PYTHON="$real_python" \
    "$verifier" "$fixture/kubeconfig" >"$output" 2>&1
  status="$?"
  set -e

  [[ "$status" -eq "$expected_status" ]] || { echo "$layout: expected exit $expected_status, got $status" >&2; cat "$output" >&2; exit 1; }
  rg -F -q -- "$expected_message" "$output" || { echo "$layout: missing expected diagnostic: $expected_message" >&2; cat "$output" >&2; exit 1; }
  [[ "$(rg -c ' start ' "$case_root/process.log" || true)" -eq "$expected_starts" ]]
  [[ "$(rg -c ' stop ' "$case_root/process.log" || true)" -eq "$expected_stops" ]]
  [[ -z "$(find "$fixture/tmp" -mindepth 1 -print -quit)" ]] || { echo "$layout: verifier left temporary files behind" >&2; exit 1; }
  for private_identity in private-telemetry-claim private-active-claim private-pv-identity private-longhorn-volume private-node-identity private-alloy-log-pod private-alloy-event-pod private-loki-pod private-loki-statefulset-uid private-revision private-volume-object-value; do
    if rg -F -q -- "$private_identity" "$output"; then echo "$layout: verifier printed a private infrastructure identity" >&2; exit 1; fi
  done
}

selected_case="${1:-all}"
case_selected() { [[ "$selected_case" == 'all' || "$selected_case" == "$1" ]]; }

if case_selected trim-only; then
  run_case trim-only 0 'Logging acceptance passed' 2 2
  rg -F -q -- '--context homelab-diagnostic' "$fixture/trim-only/kubectl.log"
  rg -F -q -- 'get volumes.longhorn.io --output json' "$fixture/trim-only/kubectl.log"
  ! rg -q -- ' get persistentvolume(s)? ' "$fixture/trim-only/kubectl.log" || { echo 'Verifier attempted a forbidden PersistentVolume read.' >&2; exit 1; }
  ! rg -F -q -- 'storage-loki-0' "$fixture/trim-only/kubectl.log" || { echo 'Verifier assumed the generated Loki PVC name.' >&2; exit 1; }
fi

if case_selected all-evidence-present; then
  run_case all-evidence-present 0 'Logging acceptance passed' 2 2
  for query in 'sum(count_over_time({source="kubernetes"}[30m]))' 'sum(count_over_time({source="talos",service=~".+",service!="kernel"}[30m]))' 'sum(count_over_time({source="talos",service="kernel"}[30m]))' 'sum(count_over_time({source="kubernetes_event"}[30m]))'; do
    rg -F -q -- "query=$query" "$fixture/all-evidence-present/curl.log"
  done
  for selector in '{source="kubernetes"}' '{source="talos"}' '{source="kubernetes_event"}'; do
    rg -F -q -- "query=$selector" "$fixture/all-evidence-present/curl.log"
  done
  rg -F -q -- '/config/tenant/v1/limits' "$fixture/all-evidence-present/curl.log"
  rg -F -q -- '/config?mode=diffs' "$fixture/all-evidence-present/curl.log"
  rg -F -q -- 'loki_boltdb_shipper_compact_tables_operation_last_successful_run_timestamp_seconds{namespace="monitoring",job="monitoring/loki"}' "$fixture/all-evidence-present/curl.log"
  [[ "$(rg -c -- '--kind topology --input .*loki-statefulset\.json' "$fixture/all-evidence-present/python.log")" -eq 1 ]]
  [[ "$(rg -c '127.0.0.1:23100/loki/api/v1/labels$' "$fixture/all-evidence-present/curl.log")" -eq 3 ]]
  [[ "$(rg -c '127.0.0.1:23100/loki/api/v1/query$' "$fixture/all-evidence-present/curl.log")" -eq 4 ]]
  if rg -q '/loki/api/v1/(query_range|tail)| query=\{source="talos"\}$|query=sum\(count_over_time\(\{source="talos",service!="kernel"\}' "$fixture/all-evidence-present/curl.log"; then
    echo 'Verifier requested raw Loki entries or used an unlabeled or kernel-inclusive Talos selector.' >&2; exit 1
  fi
fi

case_selected missing-diagnostic-context && run_case missing-diagnostic-context 2 'Logging verification requires kubeconfig context homelab-diagnostic.' 0 0
case_selected healthy-two-pod-daemonset && run_case healthy-two-pod-daemonset 1 'Alloy Logs topology does not have exactly three fully available scheduled instances.' 0 0
case_selected duplicate-alloy-log-node && run_case duplicate-alloy-log-node 1 'Alloy Logs pods are not Ready on exactly three distinct production nodes.' 0 0
case_selected two-alloy-events-pods && run_case two-alloy-events-pods 1 'Alloy Events topology does not have exactly one fully available instance.' 0 0
case_selected two-loki-pods && run_case two-loki-pods 1 'Loki topology does not have exactly one fully available instance.' 0 0
case_selected loki-pod-owner-mismatch && run_case loki-pod-owner-mismatch 1 'Loki Ready pod is not controlled by the verified StatefulSet.' 0 0
case_selected missing-mounted-claim && run_case missing-mounted-claim 1 'Loki Ready pod does not mount exactly one claim from the verified StatefulSet.' 0 0
case_selected ambiguous-mounted-claim && run_case ambiguous-mounted-claim 1 'Loki Ready pod does not mount exactly one claim from the verified StatefulSet.' 0 0
case_selected mismatched-mounted-claim && run_case mismatched-mounted-claim 1 'Loki Ready pod does not mount exactly one claim from the verified StatefulSet.' 0 0
case_selected stale-trim-labeled-pvc && run_case stale-trim-labeled-pvc 1 'The mounted Loki claim does not have the exact recurring-job intent labels.' 0 0
case_selected longhorn-status-missing && run_case longhorn-status-missing 1 'Expected exactly one actual Longhorn Volume with complete bound-claim identity; found 0.' 0 0
case_selected longhorn-status-mismatch && run_case longhorn-status-mismatch 1 'Expected exactly one actual Longhorn Volume with complete bound-claim identity; found 0.' 0 0
case_selected longhorn-status-ambiguous && run_case longhorn-status-ambiguous 1 'Expected exactly one actual Longhorn Volume with complete bound-claim identity; found 2.' 0 0
case_selected default-group && run_case default-group 1 'Actual Longhorn Volume has forbidden recurring-job assignment recurring-job-group.longhorn.io/default.' 0 0
case_selected daily-snapshot && run_case daily-snapshot 1 'Actual Longhorn Volume has forbidden recurring-job assignment recurring-job.longhorn.io/daily-snapshot.' 0 0
case_selected daily-backup && run_case daily-backup 1 'Actual Longhorn Volume has forbidden recurring-job assignment recurring-job.longhorn.io/daily-backup.' 0 0
case_selected trim-missing && run_case trim-missing 1 'Actual Longhorn Volume does not have the required filesystem-trim assignment after synchronization retries.' 0 0
case_selected extra-recurring-job && run_case extra-recurring-job 1 'Actual Longhorn Volume has an unexpected recurring-job assignment after synchronization retries.' 0 0
case_selected prometheus-port-forward-fails && run_case prometheus-port-forward-fails 1 'Port-forward to Service kube-prometheus-stack-prometheus stopped before becoming ready.' 2 1
case_selected wrong-runtime-retention && run_case wrong-runtime-retention 1 'Loki effective runtime retention is not exactly 336h with no stream override.' 2 2
case_selected malformed-runtime-retention && run_case malformed-runtime-retention 1 'Loki effective runtime retention is not exactly 336h with no stream override.' 2 2
case_selected runtime-retention-stream-override && run_case runtime-retention-stream-override 1 'Loki effective runtime retention is not exactly 336h with no stream override.' 2 2
case_selected runtime-discover-service-name-nonempty && run_case runtime-discover-service-name-nonempty 1 'Loki effective runtime service-name discovery is not disabled.' 2 2
case_selected runtime-discover-service-name-missing && run_case runtime-discover-service-name-missing 1 'Loki effective runtime service-name discovery is not disabled.' 2 2
case_selected runtime-discover-service-name-malformed && run_case runtime-discover-service-name-malformed 1 'Loki effective runtime service-name discovery is not disabled.' 2 2
case_selected runtime-config-unavailable && run_case runtime-config-unavailable 1 'Loki resolved runtime configuration endpoint was unavailable.' 2 2
case_selected runtime-shard-streams-enabled && run_case runtime-shard-streams-enabled 1 'Loki effective runtime automatic stream sharding is not disabled.' 2 2
case_selected runtime-shard-streams-missing && run_case runtime-shard-streams-missing 1 'Loki effective runtime automatic stream sharding is not disabled.' 2 2
case_selected runtime-shard-streams-malformed && run_case runtime-shard-streams-malformed 1 'Loki effective runtime automatic stream sharding is not disabled.' 2 2
case_selected forbidden-label && run_case forbidden-label 1 'Kubernetes container indexed-label names do not exactly match the approved set.' 2 2
case_selected ip-label && run_case ip-label 1 'Kubernetes container indexed-label names do not exactly match the approved set.' 2 2
case_selected missing-container-label && run_case missing-container-label 1 'Kubernetes container indexed-label names do not exactly match the approved set.' 2 2
case_selected cross-source-container-label && run_case cross-source-container-label 1 'Kubernetes container indexed-label names do not exactly match the approved set.' 2 2
case_selected cross-source-talos-label && run_case cross-source-talos-label 1 'Talos indexed-label names do not exactly match the approved set.' 2 2
case_selected missing-talos-label && run_case missing-talos-label 1 'Talos indexed-label names do not exactly match the approved set.' 2 2
case_selected extra-event-label && run_case extra-event-label 1 'Kubernetes Event indexed-label names do not exactly match the approved set.' 2 2
case_selected missing-event-label && run_case missing-event-label 1 'Kubernetes Event indexed-label names do not exactly match the approved set.' 2 2
case_selected sensitive-name-label && run_case sensitive-name-label 1 'Kubernetes Event indexed-label names do not exactly match the approved set.' 2 2
case_selected global-union-only && run_case global-union-only 1 'Kubernetes container indexed-label names do not exactly match the approved set.' 2 2
case_selected malformed-label-response && run_case malformed-label-response 1 'Kubernetes container label-name API response is malformed.' 2 2
case_selected missing-kubernetes && run_case missing-kubernetes 1 'Missing nonzero Loki aggregate count: Kubernetes containers.' 2 2
case_selected missing-talos-service && run_case missing-talos-service 1 'Missing nonzero Loki aggregate count: Talos non-kernel services.' 2 2
case_selected unlabeled-and-kernel-only && run_case unlabeled-and-kernel-only 1 'Missing nonzero Loki aggregate count: Talos non-kernel services.' 2 2
case_selected missing-kernel && run_case missing-kernel 1 'Missing nonzero Loki aggregate count: Talos kernel.' 2 2
case_selected missing-events && run_case missing-events 1 'Missing nonzero Loki aggregate count: Kubernetes Events.' 2 2
case_selected missing-compaction && run_case missing-compaction 1 'Loki does not report exactly one fresh successful compaction timestamp.' 2 2
case_selected stale-compaction && run_case stale-compaction 1 'Loki does not report exactly one fresh successful compaction timestamp.' 2 2
case_selected future-compaction && run_case future-compaction 1 'Loki does not report exactly one fresh successful compaction timestamp.' 2 2
case_selected malformed-compaction && run_case malformed-compaction 1 'Loki does not report exactly one fresh successful compaction timestamp.' 2 2
case_selected unrelated-loki-target && run_case unrelated-loki-target 1 'Prometheus does not have exactly 1 healthy loki ServiceMonitor target.' 2 2
case_selected unrelated-alloy-logs-target && run_case unrelated-alloy-logs-target 1 'Prometheus does not have exactly 3 healthy alloy-logs ServiceMonitor targets.' 2 2
case_selected unrelated-alloy-events-target && run_case unrelated-alloy-events-target 1 'Prometheus does not have exactly 1 healthy alloy-events ServiceMonitor target.' 2 2
case_selected wrong-alloy-logs-job && run_case wrong-alloy-logs-job 1 'Prometheus does not have exactly 3 healthy alloy-logs ServiceMonitor targets.' 2 2
case_selected wrong-alloy-events-job && run_case wrong-alloy-events-job 1 'Prometheus does not have exactly 1 healthy alloy-events ServiceMonitor target.' 2 2
case_selected missing-loki-target && run_case missing-loki-target 1 'Prometheus does not have exactly 1 healthy loki ServiceMonitor target.' 2 2
case_selected extra-loki-target && run_case extra-loki-target 1 'Prometheus does not have exactly 1 healthy loki ServiceMonitor target.' 2 2
case_selected one-alloy-logs-target && run_case one-alloy-logs-target 1 'Prometheus does not have exactly 3 healthy alloy-logs ServiceMonitor targets.' 2 2
case_selected two-alloy-logs-target && run_case two-alloy-logs-target 1 'Prometheus does not have exactly 3 healthy alloy-logs ServiceMonitor targets.' 2 2
case_selected excess-alloy-logs-target && run_case excess-alloy-logs-target 1 'Prometheus does not have exactly 3 healthy alloy-logs ServiceMonitor targets.' 2 2
case_selected unhealthy-alloy-logs-target && run_case unhealthy-alloy-logs-target 1 'Prometheus does not have exactly 3 healthy alloy-logs ServiceMonitor targets.' 2 2
case_selected missing-alloy-events-target && run_case missing-alloy-events-target 1 'Prometheus does not have exactly 1 healthy alloy-events ServiceMonitor target.' 2 2
case_selected extra-alloy-events-target && run_case extra-alloy-events-target 1 'Prometheus does not have exactly 1 healthy alloy-events ServiceMonitor target.' 2 2

echo 'Logging live-acceptance verifier fixture tests passed.'
