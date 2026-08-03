#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/tautulli.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/tautulli-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

if [[ " $* " == *' config get-contexts homelab-diagnostic --no-headers '* ]]; then
  [[ "$FAKE_LAYOUT" == named ]]
  exit
fi

case " $* " in
  *' get kustomization tautulli '*)
    printf 'True\n'
    ;;
  *' get helmrelease tautulli '*)
    printf 'True\n'
    ;;
  *' rollout status deployment/tautulli '*)
    ;;
  *' get httproute tautulli '*)
    printf 'True\n'
    ;;
  *' exec deployment/tautulli --container app -- curl '*)
    [[ " $* " == *' --write-out %{http_code} '* ]]
    [[ " $* " == *' --max-time 15 --max-redirs 0 '* ]]
    [[ " $* " == *' http://tautulli.media.svc.cluster.local:8181/status '* ]]
    printf '200'
    ;;
  *' proxy '*)
    echo 'kubectl proxy is not an application Service oracle.' >&2
    exit 64
    ;;
  *)
    echo "Unexpected kubectl request: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '192.168.90.30\n'
EOF
chmod +x "$fixture/bin/dig"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

if [[ " $* " == *' https://tautulli.lab.supermorphic.com/status '* ]]; then
  [[ " $* " == *' --write-out %{http_code} '* ]]
  [[ " $* " == *' --resolve tautulli.lab.supermorphic.com:443:192.168.90.30 '* ]]
  printf '200'
  exit
fi

if [[ " $* " == *' https://prometheus.lab.supermorphic.com/api/v1/query '* ]]; then
  [[ " $* " == *' --resolve prometheus.lab.supermorphic.com:443:192.168.90.30 '* ]]
  [[ " $* " == *' --get '* ]]
  [[ " $* " == *' --data-urlencode query=gatus_results_endpoint_success{group="Media", name="tautulli"} '* ]]
  case "$FAKE_LAYOUT" in
    missing-series)
      cat <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[]}}
JSON
      ;;
    *)
      cat <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"gatus_results_endpoint_success","group":"Media","name":"tautulli"},"value":[1722729600,"1"]}]}}
JSON
      ;;
  esac
  exit
fi

if [[ " $* " == *' https://prometheus.lab.supermorphic.com/api/v1/rules?type=alert '* ]]; then
  [[ " $* " == *' --resolve prometheus.lab.supermorphic.com:443:192.168.90.30 '* ]]
  case "$FAKE_LAYOUT" in
    incomplete-rules)
      cat <<'JSON'
{"status":"success","data":{"groups":[{"name":"media.rules","file":"/etc/prometheus/rules/media.rules","rules":[{"state":"inactive","name":"MediaEndpointDown","query":"gatus_results_endpoint_success == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Media endpoint down"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"MediaEndpointsProbeMissing","query":"absent(gatus_results_endpoint_success)","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Media probes missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"PlexProbeMissing","query":"absent(gatus_results_endpoint_success{name=\"plex\"})","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Plex probe missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"TautulliProbeMissing","query":"absent(gatus_results_endpoint_success{name=\"tautulli\"})","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Tautulli probe missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"PlexPersistentVolumeClaimNotBound","query":"kube_persistentvolumeclaim_status_phase{phase=\"Bound\"} == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Plex PVC not bound"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"}] }]}}
JSON
      ;;
    unhealthy-empty-error)
      cat <<'JSON'
{"status":"success","data":{"groups":[{"name":"media.rules","file":"/etc/prometheus/rules/media.rules","rules":[{"state":"inactive","name":"MediaEndpointDown","query":"gatus_results_endpoint_success == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Media endpoint down"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"MediaEndpointsProbeMissing","query":"absent(gatus_results_endpoint_success)","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Media probes missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"PlexProbeMissing","query":"absent(gatus_results_endpoint_success{name=\"plex\"})","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Plex probe missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"TautulliProbeMissing","query":"absent(gatus_results_endpoint_success{name=\"tautulli\"})","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Tautulli probe missing"},"alerts":[],"health":"err","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"PlexPersistentVolumeClaimNotBound","query":"kube_persistentvolumeclaim_status_phase{phase=\"Bound\"} == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Plex PVC not bound"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"TautulliPersistentVolumeClaimNotBound","query":"kube_persistentvolumeclaim_status_phase{phase=\"Bound\"} == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Tautulli PVC not bound"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"}] }]}}
JSON
      ;;
    duplicate-replacement-rules|healthy-nonempty-last-error)
      case "$FAKE_LAYOUT" in
        duplicate-replacement-rules)
          yq_program='.data.groups[0].rules[5].name = "PlexPersistentVolumeClaimNotBound"'
          ;;
        healthy-nonempty-last-error)
          yq_program='.data.groups[0].rules[3].lastError = "stale evaluation error"'
          ;;
      esac
      cat <<'JSON' | yq -o=json \
        "$yq_program"
{"status":"success","data":{"groups":[{"name":"media.rules","file":"/etc/prometheus/rules/media.rules","rules":[{"state":"inactive","name":"MediaEndpointDown","query":"gatus_results_endpoint_success == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Media endpoint down"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"MediaEndpointsProbeMissing","query":"absent(gatus_results_endpoint_success)","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Media probes missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"PlexProbeMissing","query":"absent(gatus_results_endpoint_success{name=\"plex\"})","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Plex probe missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"TautulliProbeMissing","query":"absent(gatus_results_endpoint_success{name=\"tautulli\"})","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Tautulli probe missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"PlexPersistentVolumeClaimNotBound","query":"kube_persistentvolumeclaim_status_phase{phase=\"Bound\"} == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Plex PVC not bound"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"TautulliPersistentVolumeClaimNotBound","query":"kube_persistentvolumeclaim_status_phase{phase=\"Bound\"} == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Tautulli PVC not bound"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"}] }]}}
JSON
      ;;
    *)
      cat <<'JSON'
{"status":"success","data":{"groups":[{"name":"media.rules","file":"/etc/prometheus/rules/media.rules","rules":[{"state":"inactive","name":"MediaEndpointDown","query":"gatus_results_endpoint_success == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Media endpoint down"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"MediaEndpointsProbeMissing","query":"absent(gatus_results_endpoint_success)","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Media probes missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"PlexProbeMissing","query":"absent(gatus_results_endpoint_success{name=\"plex\"})","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Plex probe missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"TautulliProbeMissing","query":"absent(gatus_results_endpoint_success{name=\"tautulli\"})","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Tautulli probe missing"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"PlexPersistentVolumeClaimNotBound","query":"kube_persistentvolumeclaim_status_phase{phase=\"Bound\"} == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Plex PVC not bound"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"},{"state":"inactive","name":"TautulliPersistentVolumeClaimNotBound","query":"kube_persistentvolumeclaim_status_phase{phase=\"Bound\"} == 0","duration":0,"labels":{"severity":"warning"},"annotations":{"summary":"Tautulli PVC not bound"},"alerts":[],"health":"ok","lastError":"","evaluationTime":0.001,"lastEvaluation":"2026-08-02T00:00:00Z","type":"alerting"}] }]}}
JSON
      ;;
  esac
  exit
fi

echo "Unexpected curl request: $*" >&2
exit 64
EOF
chmod +x "$fixture/bin/curl"

run_layout() {
  local layout="$1"
  local log="$fixture/$layout.log"
  : >"$log"
  PATH="$fixture/bin:$PATH" FAKE_LAYOUT="$layout" FAKE_CALL_LOG="$log" \
    "$verifier" "$fixture/kubeconfig" >"$fixture/$layout.out"
  printf '%s\n' "$log"
}

run_layout_expect_failure() {
  local layout="$1"
  local expected_error="$2"
  local log="$fixture/$layout.log"
  : >"$log"
  if PATH="$fixture/bin:$PATH" FAKE_LAYOUT="$layout" FAKE_CALL_LOG="$log" \
    "$verifier" "$fixture/kubeconfig" >"$fixture/$layout.out" 2>"$fixture/$layout.err"; then
    echo "$layout verification unexpectedly passed." >&2
    exit 1
  fi
  if ! rg -F -q -- "$expected_error" "$fixture/$layout.err"; then
    cat "$fixture/$layout.err" >&2
    echo "$layout verification did not report: $expected_error" >&2
    exit 1
  fi
  printf '%s\n' "$log"
}

named_log="$(run_layout named)"
rg -q -- '--context homelab-diagnostic' "$named_log"
rg -q -- 'exec deployment/tautulli --container app -- curl' "$named_log"
rg -q -- 'http://tautulli.media.svc.cluster.local:8181/status' "$named_log"
rg -F -q -- 'https://prometheus.lab.supermorphic.com/api/v1/query' "$named_log"
rg -F -q -- 'query=gatus_results_endpoint_success\{group=\"Media\"\,\ name=\"tautulli\"\}' "$named_log"
rg -F -q -- 'https://prometheus.lab.supermorphic.com/api/v1/rules\?type=alert' "$named_log"
if rg -q -- ' proxy ' "$named_log"; then
  echo 'Named-context verification unexpectedly used kubectl proxy.' >&2
  exit 1
fi

admin_log="$(run_layout admin)"
if rg -q -- '--context' "$admin_log"; then
  echo 'Admin fallback unexpectedly selected a scoped context.' >&2
  exit 1
fi
rg -q -- 'exec deployment/tautulli --container app -- curl' "$admin_log"

missing_series_log="$(run_layout_expect_failure missing-series 'Prometheus has no gatus_results_endpoint_success{group="Media", name="tautulli"} series.')"
rg -F -q -- 'https://prometheus.lab.supermorphic.com/api/v1/query' "$missing_series_log"

incomplete_rules_log="$(run_layout_expect_failure incomplete-rules 'Prometheus loaded 5 of 6 expected media rules.')"
rg -F -q -- 'https://prometheus.lab.supermorphic.com/api/v1/rules\?type=alert' "$incomplete_rules_log"

duplicate_replacement_rules_log="$(run_layout_expect_failure duplicate-replacement-rules 'Prometheus loaded rule names do not exactly match the six expected media rules.')"
rg -F -q -- 'https://prometheus.lab.supermorphic.com/api/v1/rules\?type=alert' "$duplicate_replacement_rules_log"

unhealthy_empty_error_log="$(run_layout_expect_failure unhealthy-empty-error 'Prometheus rule TautulliProbeMissing is unhealthy: no error text.')"
rg -F -q -- 'https://prometheus.lab.supermorphic.com/api/v1/rules\?type=alert' "$unhealthy_empty_error_log"

healthy_nonempty_last_error_log="$(run_layout_expect_failure healthy-nonempty-last-error 'Prometheus rule TautulliProbeMissing is unhealthy: stale evaluation error.')"
rg -F -q -- 'https://prometheus.lab.supermorphic.com/api/v1/rules\?type=alert' "$healthy_nonempty_last_error_log"

echo 'Tautulli Service, gateway, metric, and rule verifier tests passed.'
