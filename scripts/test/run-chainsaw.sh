#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/catalog.sh
source scripts/lib/lease.sh
source scripts/test/lib/results.sh
source scripts/test/lib/access.sh
source scripts/lib/disruption-admission.sh
require_bash

[[ "$#" -ge 2 && "$#" -le 3 ]] || {
  echo 'Usage: run-chainsaw.sh <smoke|e2e|resilience|diagnostics> <registered-target> [registered-scenario]' >&2
  exit 2
}

tier="$1"
target="$2"
scenario="${3:-}"
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

kubeconfig=''
observer_kubeconfig=''
coordinator_kubeconfig=''
export -n observer_kubeconfig coordinator_kubeconfig
namespace='flux-system'
results_root="${TEST_RESULTS_ROOT:-.test-results}"

test_access_snapshot || exit 1
entry_json="$(catalog_dispatch_entry - "$tier" "$target" "$scenario" <<<"$TEST_ACCESS_CATALOG_JSON")" || exit "$?"
unset TEST_ACCESS_CATALOG_JSON
suite_id="$(yq -r '.metadata.id' - <<<"$entry_json")"
test_access_resolve "$suite_id" >/dev/null || exit 1
dispatch_mode="$(yq -r '.dispatch.mode' - <<<"$entry_json")"
test_dir="$(yq -r '.dispatch.path' - <<<"$entry_json")"
selector="$(yq -r '.dispatch.selector // ""' - <<<"$entry_json")"
mutates_cluster="$(yq -r '.metadata.mutates_cluster' - <<<"$entry_json")"
confirmation_variable="$(yq -r '.confirmation.variable // "none"' - <<<"$entry_json")"
diagnostics_only=false
[[ "$dispatch_mode" == 'diagnostics' ]] && diagnostics_only=true

# Keep closeout intent out of native/nested backends and reject non-test dispatch.
scoped_acceptance="${TEST_ACCESS_ACCEPTANCE_CONFIRM:-}"
unset TEST_ACCESS_ACCEPTANCE_CONFIRM
if [[ -n "$scoped_acceptance" ]]; then
  [[ "$scoped_acceptance" == verify:scoped-access:ttl-and-denials &&
    "$diagnostics_only" == false &&
    "$(yq -r '.metadata.source' - <<<"$entry_json")" == chainsaw &&
    "$(yq -r '.access.profile // "null"' - <<<"$entry_json")" != null ]] || {
    echo 'Scoped client acceptance requires exact intent and a mapped Kubernetes test.' >&2
    exit 2
  }
fi

case "$confirmation_variable" in
  CLUSTER_E2E_CONFIRM) scripts/test/safety/require-e2e-confirmation.sh "$target" ;;
  CLUSTER_CHAOS_CONFIRM) scripts/test/safety/require-chaos-confirmation.sh "$target" ;;
  none) ;;
  *)
    echo "Unsupported dispatch confirmation variable: $confirmation_variable" >&2
    exit 2
    ;;
esac

execution_origin="$(resolve_execution_origin)"
run_dir="$(create_run_directory "$results_root" "$execution_origin")"
run_id="$(basename "$run_dir")"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_epoch="$EPOCHSECONDS"
cluster_name='unavailable'
lease_acquired=false
lease_joined=false
lease_cleanup_status='not-required'
finalized=false
backend_pid=''
# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
release_chainsaw_lease() {
  if [[ "$lease_acquired" == 'true' ]]; then
    if release_test_lease "$coordinator_kubeconfig" "$run_id" >/dev/null 2>&1; then
      lease_cleanup_status='passed'
    else
      lease_cleanup_status='failed'
    fi
    lease_acquired=false
  fi
}

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
finalize_incomplete_chainsaw_run() {
  local original_exit="$?" emergency_finished emergency_duration
  [[ "$finalized" == false ]] || return
  trap - EXIT INT TERM
  set +e
  [[ "$original_exit" -ne 0 ]] || original_exit=1
  release_chainsaw_lease
  emergency_finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  emergency_duration=$((EPOCHSECONDS - started_epoch))
  [[ ! -f "$run_dir/junit.xml" ]] ||
    cp "$run_dir/junit.xml" "$run_dir/diagnostics/incomplete-chainsaw-junit.xml"
  write_result_case_junit "$run_dir/junit.xml" "$suite_id" \
    coordinator-finalization broken "$emergency_duration"
  write_environment "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
    "$started_at" "$emergency_finished" "$namespace" "$kubeconfig" "$confirmation_variable"
  normalize_native_artifacts "$run_dir" "$run_id"
  write_evidence_index "$run_dir" "$run_id"
  write_summary "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
    "$started_at" "$emergency_finished" "$emergency_duration" broken \
    "$original_exit" not-classified failed "$lease_cleanup_status" not-required \
    not-applicable "$cluster_name"
  scripts/test/validate-run.sh "$run_dir" >/dev/null 2>&1
  primary_exit_code="$original_exit"
  finished_at="$emergency_finished"
  duration_seconds="$emergency_duration"
  run_result='broken'
  assertion_status='not-classified'
  diagnostics_status='failed'
  recovery_status='not-required'
  external_dependency_status='not-applicable'
  finalize_chainsaw_access
}
trap finalize_incomplete_chainsaw_run EXIT

# Invoked indirectly by signal traps; wait for backend cleanup before finalization.
# shellcheck disable=SC2329
handle_chainsaw_signal() {
  local signal_exit=143
  [[ "$1" != INT ]] || signal_exit=130
  if [[ -n "$backend_pid" ]]; then
    kill -s "$1" "$backend_pid" 2>/dev/null || true
    wait "$backend_pid" || true
    backend_pid=''
  fi
  exit "$signal_exit"
}
trap 'handle_chainsaw_signal INT' INT
trap 'handle_chainsaw_signal TERM' TERM

finalize_chainsaw_access() {
  local config_cleanup_failed=false
  test_access_close || config_cleanup_failed=true
  test_access_purposes_close || config_cleanup_failed=true
  if [[ "$config_cleanup_failed" == true ]]; then
    run_result='broken'
    cleanup_status='failed'
    local config_error="$run_dir/diagnostics/config-cleanup.xml"
    write_result_case_junit "$config_error" "$suite_id" config-cleanup broken 0
    cp "$run_dir/junit.xml" "$run_dir/diagnostics/pre-config-cleanup-junit.xml"
    merge_junit_reports "$run_dir/junit.xml" "$suite_id" \
      "$run_dir/diagnostics/pre-config-cleanup-junit.xml" "$config_error"
    normalize_native_artifacts "$run_dir" "$run_id"
    write_evidence_index "$run_dir" "$run_id"
    write_summary "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
      "$started_at" "$finished_at" "$duration_seconds" "$run_result" \
      "$primary_exit_code" "$assertion_status" "$diagnostics_status" "$cleanup_status" \
      "$recovery_status" "$external_dependency_status" "$cluster_name"
    scripts/test/validate-run.sh "$run_dir"
  fi
  finalized=true
  trap - EXIT INT TERM
}

write_run_id_output "$run_id"
unset TEST_RUN_ID_FILE
test_access_open "$suite_id" "$run_id" || exit 1
kubeconfig="$TEST_KUBECONFIG"
cluster_name="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
  --output jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
[[ -n "$cluster_name" ]] || cluster_name='unavailable'
test_access_check "$suite_id" || exit 1
if [[ "$mutates_cluster" == 'true' ]]; then
  test_access_purpose_open campaign-observer "$run_id" || exit 1
  observer_kubeconfig="$TEST_ACCESS_PURPOSE_CONFIG"
  if [[ -z "${TEST_CAMPAIGN_LEASE_HOLDER:-}" ]]; then
    test_access_purpose_open campaign-coordinator "$run_id" || exit 1
    coordinator_kubeconfig="$TEST_ACCESS_PURPOSE_CONFIG"
  fi
  lease_ready=false
  if [[ -n "${TEST_CAMPAIGN_LEASE_HOLDER:-}" ]]; then
    if verify_test_lease_holder "$kubeconfig" "$TEST_CAMPAIGN_LEASE_HOLDER"; then
      lease_joined=true
      lease_ready=true
    fi
  elif acquire_test_lease "$coordinator_kubeconfig" "$run_id" 5 existing-only; then
    lease_acquired=true
    lease_ready=true
    start_test_lease_renewal "$coordinator_kubeconfig" "$run_id" \
      "$(cd "$run_dir" && pwd)/diagnostics/lease-renewal-failed"
  fi
  if [[ "$lease_ready" != 'true' ]]; then
    finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    duration_seconds=$((EPOCHSECONDS - started_epoch))
    write_result_case_junit "$run_dir/junit.xml" \
      "$(yq -r '.metadata.id' - <<<"$entry_json")" lease-acquisition broken \
      "$duration_seconds"
    write_environment "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
      "$started_at" "$finished_at" "$namespace" "$kubeconfig" "$confirmation_variable"
    write_evidence_index "$run_dir" "$run_id"
    write_summary "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
      "$started_at" "$finished_at" "$duration_seconds" broken 1 \
      not-classified passed failed not-required not-applicable "$cluster_name"
    scripts/test/validate-run.sh "$run_dir"
    primary_exit_code=1
    run_result='broken'
    assertion_status='not-classified'
    diagnostics_status='passed'
    recovery_status='not-required'
    external_dependency_status='not-applicable'
    finalize_chainsaw_access
    echo "Chainsaw results: $run_dir"
    exit 1
  fi
fi

if [[ "$diagnostics_only" == true ]]; then
  set +e
  scripts/test/diagnostics/collect.sh "$kubeconfig" "$run_dir/diagnostics" "$namespace"
  primary_exit_code="$?"
  set -e
  diagnostics_status='passed'
  run_result='passed'
  [[ "$primary_exit_code" -eq 0 ]] || { diagnostics_status='failed'; run_result='broken'; }
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  duration_seconds=$((EPOCHSECONDS - started_epoch))
  write_single_case_junit "$run_dir/junit.xml" diagnostics collection \
    "$run_result" "$duration_seconds"
  write_environment "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
    "$started_at" "$finished_at" "$namespace" "$kubeconfig" "$confirmation_variable"
  normalize_native_artifacts "$run_dir" "$run_id"
  write_evidence_index "$run_dir" "$run_id"
  write_summary "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
    "$started_at" "$finished_at" "$duration_seconds" "$run_result" \
    "$primary_exit_code" not-applicable "$diagnostics_status" not-required \
    not-required not-applicable "$cluster_name"
  scripts/test/validate-run.sh "$run_dir"
  assertion_status='not-applicable'
  recovery_status='not-required'
  external_dependency_status='not-applicable'
  finalize_chainsaw_access
  overall_exit_code="$(result_exit_code "$primary_exit_code" "$run_result")"
  echo "Diagnostics results: $run_dir"
  exit "$overall_exit_code"
fi

export KUBECONFIG="$kubeconfig"
# State-changing scenarios write recovery.json here so the runner can record cleanup/recovery
# separately from the primary assertion. E2E and resilience share this result contract.
# Chainsaw runs script ops from its own working directory, so export the run dir as an
# ABSOLUTE path (works regardless of a script op's cwd) and the repo root for scenarios
# that invoke repo-relative guard/orchestrator scripts.
run_dir_abs="$(cd "$run_dir" && pwd)"
export HOMELAB_TEST_RUN_DIR="$run_dir_abs"
export HOMELAB_REPO_ROOT="$repo_root"
test_access_check "$suite_id" || exit 1
if [[ "$mutates_cluster" == true ]]; then
  test_access_purpose_check campaign-observer "$run_id" "$observer_kubeconfig" || exit 1
  assert_established_disruption_admissible "$observer_kubeconfig" || exit 1
  if [[ "$lease_acquired" == true ]]; then
    test_access_purpose_check campaign-coordinator "$run_id" "$coordinator_kubeconfig" || exit 1
    verify_test_lease_holder "$coordinator_kubeconfig" "$run_id" || exit 1
  else
    verify_test_lease_holder "$kubeconfig" "$TEST_CAMPAIGN_LEASE_HOLDER" || exit 1
  fi
fi
set +e
python -m scripts.test.run_bound_backend "$run_dir/logs/chainsaw.log" -- \
  chainsaw test "$test_dir" \
  --config tests/config/chainsaw.yaml \
  --namespace "$namespace" \
  --parallel 1 \
  --selector "$selector" \
  --apply-timeout 1m \
  --assert-timeout 2m \
  --cleanup-timeout 1m \
  --delete-timeout 1m \
  --error-timeout 30s \
  --exec-timeout 1m \
  --kube-request-timeout 30s \
  --report-format JUNIT-STEP \
  --report-name junit \
  --report-path "$run_dir" \
  --no-color <&0 &
backend_pid="$!"
wait "$backend_pid"
primary_exit_code="$?"
backend_pid=''
set -e

case "$primary_exit_code" in
  130|143)
    signal_error="$run_dir/diagnostics/signal.xml"
    write_result_case_junit "$signal_error" "$suite_id" signal broken 0
    if [[ -f "$run_dir/junit.xml" ]]; then
      cp "$run_dir/junit.xml" "$run_dir/diagnostics/interrupted-chainsaw-junit.xml"
      merge_junit_reports "$run_dir/junit.xml" "$suite_id" \
        "$run_dir/diagnostics/interrupted-chainsaw-junit.xml" "$signal_error"
    else
      cp "$signal_error" "$run_dir/junit.xml"
    fi
    ;;
esac

assertion_status='passed'
[[ "$primary_exit_code" -eq 0 ]] || {
  assertion_status='not-classified'
}

junit_status='invalid'
if [[ ! -f "$run_dir/junit.xml" ]]; then
  echo 'Chainsaw did not produce the required junit.xml report.' >&2
  primary_exit_code=1
  assertion_status='not-classified'
elif counts="$(read_junit_counts "$run_dir/junit.xml")"; then
  read -r _report_tests report_failures report_errors _report_skipped _report_passed <<<"$counts"
  if [[ "$report_errors" -gt 0 ]]; then
    junit_status='errors'
  elif [[ "$report_failures" -gt 0 ]]; then
    junit_status='failures'
  else
    junit_status='valid'
  fi
else
  echo 'Chainsaw report is invalid or vacuous.' >&2
  primary_exit_code=1
  assertion_status='not-classified'
fi

# Retain the original native assertions before appending optional credential proof.
if [[ -f "$run_dir/junit.xml" ]]; then
  cp "$run_dir/junit.xml" "$run_dir/diagnostics/chainsaw-junit.xml"
fi
if [[ "$primary_exit_code" -eq 0 && "$junit_status" == valid && -n "$scoped_acceptance" ]]; then
  fragment_dir="$run_dir_abs/diagnostics/fragments"
  mkdir -p "$fragment_dir"
  acceptance_fragment="$fragment_dir/scoped-access.xml"
  set +e
  TEST_RESULT_FRAGMENT_DIR="$fragment_dir" \
    python -m scripts.test.run_bound_backend "$run_dir/logs/scoped-access.log" -- \
    uv run --locked --no-dev python -m scripts.test.scoped_access_acceptance \
    "$suite_id" "$scoped_acceptance" &
  backend_pid="$!"
  wait "$backend_pid"
  acceptance_exit_code="$?"
  backend_pid=''
  set -e
  if ! acceptance_counts="$(read_junit_counts "$acceptance_fragment")"; then
    write_result_case_junit "$acceptance_fragment" "$suite_id" \
      scoped-client-refresh-and-boundary broken 0
  else
    read -r _acceptance_tests acceptance_failures acceptance_errors _acceptance_skipped _acceptance_passed \
      <<<"$acceptance_counts"
    if [[ "$acceptance_exit_code" -ne 0 && "$acceptance_failures" -eq 0 && "$acceptance_errors" -eq 0 ]]; then
      write_result_case_junit "$acceptance_fragment" "$suite_id" \
        scoped-client-refresh-and-boundary broken 0
    fi
  fi
  merge_junit_reports "$run_dir/junit.xml" "$suite_id" \
    "$run_dir/diagnostics/chainsaw-junit.xml" "$acceptance_fragment"
  counts="$(read_junit_counts "$run_dir/junit.xml")"
  read -r _report_tests report_failures report_errors _report_skipped _report_passed <<<"$counts"
  if [[ "$report_errors" -gt 0 ]]; then
    junit_status='errors'
  elif [[ "$report_failures" -gt 0 ]]; then
    junit_status='failures'
  fi
fi

set +e
scripts/test/diagnostics/collect.sh "$kubeconfig" "$run_dir/diagnostics" "$namespace"
diagnostics_exit_code="$?"
set -e
diagnostics_status='passed'
[[ "$diagnostics_exit_code" -eq 0 ]] || diagnostics_status='failed'
if [[ "$lease_acquired" == 'true' ]]; then
  lease_finalization_failed=false
  [[ ! -f "$run_dir/diagnostics/lease-renewal-failed" ]] ||
    lease_finalization_failed=true
  release_test_lease "$coordinator_kubeconfig" "$run_id" ||
    lease_finalization_failed=true
  if [[ "$lease_finalization_failed" == 'true' ]]; then
    diagnostics_status='failed'
    lease_cleanup_status='failed'
  else
    lease_cleanup_status='passed'
  fi
  lease_acquired=false
elif [[ "$lease_joined" == 'true' ]]; then
  if ! verify_test_lease_holder "$kubeconfig" "$TEST_CAMPAIGN_LEASE_HOLDER"; then
    diagnostics_status='failed'
    lease_cleanup_status='failed'
  fi
  if [[ -n "${TEST_CAMPAIGN_LEASE_FAILURE_MARKER:-}" &&
    -e "$TEST_CAMPAIGN_LEASE_FAILURE_MARKER" ]]; then
    diagnostics_status='failed'
    lease_cleanup_status='failed'
  fi
  lease_joined=false
fi

# State-changing scenarios drive cleanup/recovery in a trap/finally block and record its
# outcome in recovery.json. Surface it separately without rewriting the primary assertion.
cleanup_status="$lease_cleanup_status"
recovery_status='not-required'
external_dependency_status='not-applicable'
if [[ "$tier" == 'e2e' || "$tier" == 'resilience' ]]; then
  recovery_status="$(recorded_recovery_status "$run_dir")"
  cleanup_status="$recovery_status"
fi
[[ "$lease_cleanup_status" != failed ]] || cleanup_status='failed'
if [[ "$tier" == 'e2e' && "$target" == 'qbit-manage-policy' ]]; then
  assertion_status="$(recorded_phase_status "$run_dir" assertion)"
  external_dependency_status="$(recorded_phase_status "$run_dir" external-dependency)"
fi

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
duration_seconds=$((EPOCHSECONDS - started_epoch))
run_result="$(classify_run_result "$primary_exit_code" "$junit_status" \
  "$diagnostics_status" "$cleanup_status")"
if [[ "$external_dependency_status" == 'failed' ]]; then
  run_result='broken'
fi
suite_id="$(yq -r '.metadata.id' - <<<"$entry_json")"
append_lifecycle_junit "$run_dir/junit.xml" "$suite_id" \
  "$external_dependency_status" "$cleanup_status" "$recovery_status" \
  "$diagnostics_status" "$run_result"
write_environment "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
  "$started_at" "$finished_at" "$namespace" "$kubeconfig" "$confirmation_variable"
normalize_native_artifacts "$run_dir" "$run_id"
write_evidence_index "$run_dir" "$run_id"
write_summary "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
  "$started_at" "$finished_at" "$duration_seconds" "$run_result" \
  "$primary_exit_code" "$assertion_status" "$diagnostics_status" "$cleanup_status" \
  "$recovery_status" "$external_dependency_status" "$cluster_name"
scripts/test/validate-run.sh "$run_dir"
finalize_chainsaw_access

overall_exit_code="$(result_exit_code "$primary_exit_code" "$run_result")"
echo "Chainsaw results: $run_dir"
exit "$overall_exit_code"
