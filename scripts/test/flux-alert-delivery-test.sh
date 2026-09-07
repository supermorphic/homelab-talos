#!/usr/bin/env bash
set -euo pipefail

scenario='scripts/test/scenarios/flux-alert-delivery.sh'
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-flux-alert-delivery-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
kubeconfig="$temp_dir/kubeconfig"
stub_bin="$temp_dir/bin"
kubectl_marker="$temp_dir/kubectl-called"
mkdir -p "$stub_bin"
touch "$kubeconfig"

cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"$KUBECTL_MARKER"
exit 99
EOF
chmod +x "$stub_bin/kubectl"
cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod +x "$stub_bin/curl"

expect_guard_rejection() {
  local confirmation="${1:-}"
  local output exit_code
  rm -f -- "$kubectl_marker"
  set +e
  if [[ -n "$confirmation" ]]; then
    output="$(
      PATH="$stub_bin:$PATH" \
      KUBECTL_MARKER="$kubectl_marker" \
      FLUX_ALERT_E2E_CONFIRM="$confirmation" \
        "$scenario" "$kubeconfig" 2>&1
    )"
    exit_code="$?"
  else
    output="$(
      PATH="$stub_bin:$PATH" \
      KUBECTL_MARKER="$kubectl_marker" \
      env -u FLUX_ALERT_E2E_CONFIRM \
        "$scenario" "$kubeconfig" 2>&1
    )"
    exit_code="$?"
  fi
  set -e
  [[ "$exit_code" -eq 1 ]] || {
    echo "Expected guard rejection, got exit $exit_code." >&2
    exit 1
  }
  rg -q "FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved'" <<<"$output"
  [[ ! -e "$kubectl_marker" ]] || {
    echo 'Flux alert E2E touched Kubernetes before validating its confirmation.' >&2
    exit 1
  }
}

expect_guard_rejection
expect_guard_rejection 'test:flux-alert:wrong'

set +e
PATH="$stub_bin:$PATH" \
KUBECTL_MARKER="$kubectl_marker" \
FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved' \
  "$scenario" "$kubeconfig" >/dev/null 2>&1
confirmed_exit="$?"
set -e
[[ "$confirmed_exit" -ne 0 && -e "$kubectl_marker" ]] || {
  echo 'Exact confirmation did not pass control to the Kubernetes preflight.' >&2
  exit 1
}

expect_aggregate_counter_evidence_is_inconclusive() {
  local fixture="$temp_dir/aggregate-counter-fixture"
  local output exit_code
  mkdir -p "$fixture/bin" "$fixture/run"
  touch "$fixture/kubeconfig"

  cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$KUBECTL_LOG"
case " $* " in
  *' get kustomization flux-alert-e2e-'*)
    if [[ -e "$RUN_RESOURCE_CREATED" ]]; then
      [[ " $* " == *' --output=name '* ]] && echo "kustomization.kustomize.toolkit.fluxcd.io/$test_name"
      exit 0
    fi
    if [[ -e "$DELETE_ATTEMPTED" ]]; then
      if [[ "${POST_DELETE_GET_ERROR:-false}" == 'true' ]]; then
        echo 'Error from server (Forbidden): cleanup lookup denied' >&2
        exit 1
      fi
      if [[ " $* " == *' --ignore-not-found '* && " $* " == *' --output=name '* ]]; then
        exit 0
      fi
    fi
    exit 1
    ;;
  *' get gitrepository flux-alert-e2e-'*) exit 1 ;;
  *' create --filename '*) touch "$RUN_RESOURCE_CREATED" ;;
  *' delete kustomization flux-alert-e2e-'*)
    touch "$DELETE_ATTEMPTED"
    [[ "${KEEP_RUN_RESOURCE:-false}" == 'true' ]] || rm -f -- "$RUN_RESOURCE_CREATED"
    ;;
  *) echo "Unexpected kubectl request: $*" >&2; exit 64 ;;
esac
EOF
  chmod +x "$fixture/bin/kubectl"

  cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

json_value() {
  printf '{"status":"success","data":{"result":[{"value":[0,"%s"]}]}}\n' "$1"
}

url="${!#}"
case "$url" in
  */api/v2/status)
    FAKE_CONFIG=$'route:\n  routes:\n    - receiver: ntfy\nreceivers:\n  - name: ntfy\n    webhook_configs:\n      - url: http://example.invalid/hook' \
      yq --null-input --output-format json '{"config":{"original":strenv(FAKE_CONFIG)}}'
    ;;
  */api/v2/alerts/groups)
    calls=0
    [[ -f "$ALERT_GROUP_CALLS" ]] && calls="$(<"$ALERT_GROUP_CALLS")"
    calls=$((calls + 1))
    printf '%s' "$calls" >"$ALERT_GROUP_CALLS"
    if [[ "$calls" -eq 1 ]]; then
      TEST_NAME="$test_name" yq --null-input --output-format json \
        '[{"receiver":{"name":"ntfy"},"alerts":[{"labels":{"alertname":"FluxReconciliationFailure","name":strenv(TEST_NAME),"exported_namespace":"flux-system"},"status":{"state":"active"}}]}]'
    else
      printf '%s\n' '[]'
    fi
    ;;
  */api/v1/query)
    query=''
    for arg in "$@"; do
      [[ "$arg" == query=* ]] && query="${arg#query=}"
    done
    case "$query" in
      'count(alertmanager_notifications_total'*|'count(alertmanager_notifications_failed_total'*) json_value 1 ;;
      'sum(alertmanager_notifications_total'*)
        calls=0
        [[ -f "$NOTIFICATION_TOTAL_CALLS" ]] && calls="$(<"$NOTIFICATION_TOTAL_CALLS")"
        calls=$((calls + 1))
        printf '%s' "$calls" >"$NOTIFICATION_TOTAL_CALLS"
        # These increments model unrelated webhook notifications; this fixture has no
        # test-specific publication receipt.
        case "$calls" in 1) json_value 100 ;; 2) json_value 101 ;; *) json_value 102 ;; esac
        ;;
      'sum(alertmanager_notifications_failed_total'*) json_value 0 ;;
      *'customresource_kind="Kustomization"'*) json_value 1 ;;
      *'alertstate="pending"'*) json_value 1 ;;
      *'alertstate="firing"'*) json_value 1 ;;
      'count(ALERTS{'*) json_value 0 ;;
      *) echo "Unexpected Prometheus query: $query" >&2; exit 64 ;;
    esac
    ;;
  *) echo "Unexpected curl request: $*" >&2; exit 64 ;;
esac
EOF
  chmod +x "$fixture/bin/curl"

  set +e
  output="$(
    PATH="$fixture/bin:$PATH" \
    KUBECTL_LOG="$fixture/kubectl.log" \
    RUN_RESOURCE_CREATED="$fixture/run-resource-created" \
    DELETE_ATTEMPTED="$fixture/delete-attempted" \
    ALERT_GROUP_CALLS="$fixture/alert-group-calls" \
    NOTIFICATION_TOTAL_CALLS="$fixture/notification-total-calls" \
    HOMELAB_TEST_RUN_DIR="$fixture/run" \
    FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved' \
      "$scenario" "$fixture/kubeconfig" 2>&1
  )"
  exit_code="$?"
  set -e

  [[ "$exit_code" -ne 0 ]] || {
    echo 'Aggregate webhook counter increments incorrectly proved test-specific delivery.' >&2
    exit 1
  }
  rg -q 'delivery evidence is inconclusive' <<<"$output" || {
    echo 'Scenario did not report its aggregate-counter evidence limitation.' >&2
    printf '%s\n' "$output" >&2
    exit 1
  }
  [[ ! -e "$fixture/run-resource-created" ]] || {
    echo 'Scenario left its run-owned Kustomization after inconclusive delivery evidence.' >&2
    exit 1
  }
  [[ "$(yq -r '.status' "$fixture/run/recovery.json")" == 'not-required' ]] || {
    echo 'Scenario did not record wrapper-compatible non-disruptive recovery status.' >&2
    exit 1
  }
  [[ "$(yq -r '.status' "$fixture/run/cleanup.json")" == 'passed' ]] || {
    echo 'Scenario did not record wrapper-compatible successful cleanup status.' >&2
    exit 1
  }
  [[ "$(rg -c '^.* create --filename ' "$fixture/kubectl.log")" -eq 1 ]] || {
    echo 'Scenario did not create exactly one run-owned Kustomization.' >&2
    exit 1
  }
  [[ "$(rg -c '^.* delete kustomization flux-alert-e2e-' "$fixture/kubectl.log")" -eq 1 ]] || {
    echo 'Scenario did not delete exactly its run-owned Kustomization.' >&2
    exit 1
  }

  rm -f -- "$fixture/run-resource-created" "$fixture/delete-attempted" \
    "$fixture/alert-group-calls" "$fixture/notification-total-calls"
  : >"$fixture/kubectl.log"
  set +e
  output="$(
    PATH="$fixture/bin:$PATH" \
    KUBECTL_LOG="$fixture/kubectl.log" \
    RUN_RESOURCE_CREATED="$fixture/run-resource-created" \
    DELETE_ATTEMPTED="$fixture/delete-attempted" \
    ALERT_GROUP_CALLS="$fixture/alert-group-calls" \
    NOTIFICATION_TOTAL_CALLS="$fixture/notification-total-calls" \
    HOMELAB_TEST_RUN_DIR="$fixture/run" \
    KEEP_RUN_RESOURCE=true \
    FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved' \
      "$scenario" "$fixture/kubeconfig" 2>&1
  )"
  exit_code="$?"
  set -e
  [[ "$exit_code" -ne 0 ]] || {
    echo 'Scenario accepted a run-owned Kustomization left after deletion.' >&2
    exit 1
  }
  rg -q 'Flux alert delivery cleanup failed' <<<"$output" || {
    echo 'Scenario did not report cleanup failure when its resource remained.' >&2
    exit 1
  }
  [[ "$(yq -r '.status' "$fixture/run/cleanup.json")" == 'failed' ]] || {
    echo 'Scenario did not record wrapper-compatible cleanup failure status.' >&2
    exit 1
  }

  rm -f -- "$fixture/run-resource-created" "$fixture/delete-attempted" \
    "$fixture/alert-group-calls" "$fixture/notification-total-calls"
  : >"$fixture/kubectl.log"
  set +e
  output="$(
    PATH="$fixture/bin:$PATH" \
    KUBECTL_LOG="$fixture/kubectl.log" \
    RUN_RESOURCE_CREATED="$fixture/run-resource-created" \
    DELETE_ATTEMPTED="$fixture/delete-attempted" \
    ALERT_GROUP_CALLS="$fixture/alert-group-calls" \
    NOTIFICATION_TOTAL_CALLS="$fixture/notification-total-calls" \
    HOMELAB_TEST_RUN_DIR="$fixture/run" \
    POST_DELETE_GET_ERROR=true \
    FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved' \
      "$scenario" "$fixture/kubeconfig" 2>&1
  )"
  exit_code="$?"
  set -e
  [[ "$exit_code" -ne 0 ]] || {
    echo 'Scenario accepted an API-error cleanup lookup.' >&2
    exit 1
  }
  rg -q 'Flux alert delivery cleanup failed' <<<"$output" || {
    echo 'Scenario did not report cleanup failure after an API-error lookup.' >&2
    exit 1
  }
  [[ "$(yq -r '.status' "$fixture/run/cleanup.json")" == 'failed' ]] || {
    echo 'Scenario recorded successful cleanup after an API-error lookup.' >&2
    exit 1
  }
}

expect_aggregate_counter_evidence_is_inconclusive

rg -Fq 'source_name="${test_name}-source-does-not-exist"' "$scenario"
rg -Fq 'get gitrepository "$source_name"' "$scenario"
rg -q '\.homelab-talos-tests/' "$scenario"
rg -q 'homelab-talos/test.*flux-alert-delivery' "$scenario"
rg -q 'FluxReconciliationFailure' "$scenario"
rg -q 'alertmanager_notifications_total' "$scenario"
rg -q 'alertmanager_notifications_failed_total' "$scenario"
# The deployed Alertmanager notification metrics expose the integration label but not a
# receiver or alert identity. The loaded configuration still checks receiver identity,
# but aggregate counter movement cannot prove this test alert was published.
rg -Fq 'sum(alertmanager_notifications_total{integration="webhook"}) or vector(0)' "$scenario"
rg -Fq 'sum(alertmanager_notifications_failed_total{integration="webhook"}) or vector(0)' "$scenario"
rg -Fq 'webhook_config_count=' "$scenario"
rg -Fq 'ntfy_webhook_config_count=' "$scenario"
rg -Fq 'ntfy is not the only loaded Alertmanager webhook' "$scenario"
rg -Fq 'notification_total_series_query=' "$scenario"
rg -Fq 'notification_failed_series_query=' "$scenario"
rg -Fq 'notification metric series are absent' "$scenario"
rg -Fq 'production_metric_selector="$(flux_alerts_metric_selector)"' "$scenario"
rg -Fq '${production_metric_selector%?},customresource_kind=' "$scenario"
rg -q 'delete kustomization "\$test_name"' "$scenario"
rg -q 'created=false' "$scenario"

echo 'Flux alert delivery E2E guard and ownership assertions passed.'
