#!/usr/bin/env bash
# Execute one catalog suite with streaming output and a canonical result directory.
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/catalog.sh
source scripts/test/lib/results.sh
source scripts/test/lib/lease.sh
require_bash

[[ "$#" -ge 3 && "$2" == '--' ]] || {
  echo 'Usage: run-catalog-suite.sh <catalog-suite-id> -- <command> [args...]' >&2
  exit 2
}

suite_id="$1"
shift 2
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
catalog="${TEST_CATALOG_PATH:-tests/catalog.yaml}"
results_root="${TEST_RESULTS_ROOT:-.test-results}"
kubeconfig="${TEST_KUBECONFIG:-.kube/config}"
entry_json="$(catalog_entry_by_id "$catalog" "$suite_id")"
mutates_cluster="$(yq -r '.metadata.mutates_cluster' - <<<"$entry_json")"
confirmation_type="$(yq -r '.confirmation.type' - <<<"$entry_json")"
confirmation_variable="$(yq -r '.confirmation.variable // "none"' - <<<"$entry_json")"
confirmation_expected="$(yq -r '.confirmation.expected // ""' - <<<"$entry_json")"

case "$confirmation_type" in
  none|command) ;;
  exact)
    [[ -n "$confirmation_variable" && "$confirmation_variable" != 'none' ]]
    [[ "${!confirmation_variable:-}" == "$confirmation_expected" ]] || {
      echo "Refusing $suite_id: set $confirmation_variable to the documented exact value." >&2
      exit 1
    }
    ;;
  *)
    echo "Unsupported confirmation type '$confirmation_type' for $suite_id." >&2
    exit 2
    ;;
esac

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

execution_origin="$(resolve_execution_origin)"
run_dir="$(create_run_directory "$results_root" "$execution_origin")"
run_id="$(basename "$run_dir")"
run_dir_abs="$(cd "$run_dir" && pwd)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_epoch="$EPOCHSECONDS"
fragment_dir="$run_dir_abs/diagnostics/fragments"
mkdir -p "$fragment_dir"
export HOMELAB_TEST_RUN_DIR="$run_dir_abs"
export HOMELAB_REPO_ROOT="$repo_root"
export TEST_RESULT_FRAGMENT_DIR="$fragment_dir"

signal_exit_code=0
lease_acquired=false
lease_release_status='not-required'
finalized=false

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
finalize_incomplete_run() {
  local original_exit="$?"
  local emergency_finished emergency_duration emergency_cleanup='not-required'
  [[ "$finalized" == 'false' ]] || return
  trap - EXIT INT TERM
  set +e
  [[ "$original_exit" -ne 0 ]] || original_exit=1
  if [[ "$lease_acquired" == 'true' ]]; then
    release_test_lease "$kubeconfig" "$run_id" >/dev/null 2>&1
    emergency_cleanup='failed'
    lease_acquired=false
  fi
  emergency_finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  emergency_duration=$((EPOCHSECONDS - started_epoch))
  [[ ! -f "$run_dir/junit.xml" ]] ||
    cp "$run_dir/junit.xml" "$run_dir/diagnostics/incomplete-junit.xml"
  write_result_case_junit "$run_dir/junit.xml" "$suite_id" \
    coordinator-finalization broken "$emergency_duration"
  write_environment "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
    "$started_at" "$emergency_finished" \
    "${TEST_NAMESPACE:-all}" \
    "$kubeconfig" "$confirmation_variable"
  normalize_native_artifacts "$run_dir" "$run_id"
  write_evidence_index "$run_dir" "$run_id"
  write_summary "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
    "$started_at" "$emergency_finished" "$emergency_duration" broken \
    "$original_exit" not-classified failed "$emergency_cleanup" \
    not-required not-applicable unavailable
  scripts/test/validate-run.sh "$run_dir" >/dev/null 2>&1
  echo "Test coordinator finalized an interrupted run: $run_dir" >&2
}
trap finalize_incomplete_run EXIT

# Invoked indirectly by the signal traps below.
# shellcheck disable=SC2329
handle_signal() {
  case "$1" in
    INT) signal_exit_code=130 ;;
    TERM) signal_exit_code=143 ;;
  esac
  exit "$signal_exit_code"
}
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

if [[ "$mutates_cluster" == 'true' ]]; then
  lease_release_status='failed'
  if acquire_test_lease "$kubeconfig" "$run_id"; then
    lease_acquired=true
    start_test_lease_renewal "$kubeconfig" "$run_id" \
      "$run_dir_abs/diagnostics/lease-renewal-failed"
  else
    write_result_case_junit "$run_dir/junit.xml" "$suite_id" lease-acquisition broken 0
    primary_exit_code=1
    run_result='broken'
  fi
fi

if [[ "$mutates_cluster" != 'true' || "$lease_acquired" == 'true' ]]; then
  set +e
  "$@" 2>&1 | tee "$run_dir/logs/console.log"
  primary_exit_code="${PIPESTATUS[0]}"
  set -e
  if [[ "$signal_exit_code" -ne 0 ]]; then
    primary_exit_code="$signal_exit_code"
  fi

  duration_seconds=$((EPOCHSECONDS - started_epoch))
  mapfile -t native_fragments < <(
    find "$fragment_dir" -type f -name '*.xml' -print | LC_ALL=C sort
  )
  if [[ "${#native_fragments[@]}" -gt 0 ]] &&
    merge_junit_reports "$run_dir/junit.xml" "$suite_id" "${native_fragments[@]}"; then
    counts="$(read_junit_counts "$run_dir/junit.xml")"
    read -r _tests failures errors _skipped _passed <<<"$counts"
    if [[ "$errors" -gt 0 ]]; then
      run_result='broken'
    elif [[ "$failures" -gt 0 ]]; then
      run_result='failed'
    elif [[ "$primary_exit_code" -ne 0 ]]; then
      write_result_case_junit "$run_dir/junit.xml" "$suite_id" exit-mismatch broken \
        "$duration_seconds"
      run_result='broken'
    else
      run_result='passed'
    fi
  elif [[ "${#native_fragments[@]}" -gt 0 ]]; then
    write_result_case_junit "$run_dir/junit.xml" "$suite_id" junit-merge broken \
      "$duration_seconds"
    run_result='broken'
  elif [[ "$signal_exit_code" -ne 0 ]]; then
    write_result_case_junit "$run_dir/junit.xml" "$suite_id" signal broken \
      "$duration_seconds"
    run_result='broken'
  elif [[ "$primary_exit_code" -eq 0 ]]; then
    write_result_case_junit "$run_dir/junit.xml" "$suite_id" command passed \
      "$duration_seconds"
    run_result='passed'
  else
    write_result_case_junit "$run_dir/junit.xml" "$suite_id" command failed \
      "$duration_seconds"
    run_result='failed'
  fi
fi

primary_assertion_status='failed'
[[ "$primary_exit_code" -ne 0 ]] || primary_assertion_status='passed'
primary_counts="$(read_junit_counts "$run_dir/junit.xml")"
read -r _primary_tests _primary_failures primary_errors _primary_skipped _primary_passed \
  <<<"$primary_counts"
[[ "$primary_errors" -eq 0 ]] || primary_assertion_status='not-classified'

if [[ "$lease_acquired" == 'true' ]]; then
  lease_release_status='passed'
  lease_finalization_failed=false
  [[ ! -f "$run_dir/diagnostics/lease-renewal-failed" ]] ||
    lease_finalization_failed=true
  release_test_lease "$kubeconfig" "$run_id" ||
    lease_finalization_failed=true
  lease_acquired=false
  if [[ "$lease_finalization_failed" == 'true' ]]; then
    lease_release_status='failed'
    run_result='broken'
    lease_error="$run_dir/diagnostics/lease-release.xml"
    write_result_case_junit "$lease_error" "$suite_id" lease-finalization broken 0
    cp "$run_dir/junit.xml" "$run_dir/diagnostics/primary-junit.xml"
    merge_junit_reports "$run_dir/junit.xml" "$suite_id" \
      "$run_dir/diagnostics/primary-junit.xml" "$lease_error"
  fi
fi

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
duration_seconds=$((EPOCHSECONDS - started_epoch))
cleanup_status="$lease_release_status"
recovery_status='not-required'
external_dependency_status='not-applicable'
if [[ "$mutates_cluster" == 'true' && -f "$run_dir/recovery.json" ]]; then
  recovery_status="$(recorded_recovery_status "$run_dir")"
  scenario_cleanup_status="$recovery_status"
  if [[ -f "$run_dir/cleanup.json" ]]; then
    scenario_cleanup_status="$(recorded_phase_status "$run_dir" cleanup)"
  fi
  case "$scenario_cleanup_status" in
    passed|not-required)
      [[ "$cleanup_status" != 'failed' ]] || scenario_cleanup_status='failed'
      cleanup_status="$scenario_cleanup_status"
      ;;
    failed|not-classified)
      cleanup_status="$scenario_cleanup_status"
      run_result='broken'
      counts="$(read_junit_counts "$run_dir/junit.xml")"
      read -r _tests _failures cleanup_errors _skipped _passed <<<"$counts"
      if [[ "$cleanup_errors" -eq 0 ]]; then
        cleanup_error="$run_dir/diagnostics/scenario-cleanup.xml"
        write_result_case_junit "$cleanup_error" "$suite_id" \
          scenario-cleanup broken 0
        cp "$run_dir/junit.xml" "$run_dir/diagnostics/pre-cleanup-junit.xml"
        merge_junit_reports "$run_dir/junit.xml" "$suite_id" \
          "$run_dir/diagnostics/pre-cleanup-junit.xml" "$cleanup_error"
      fi
      ;;
  esac
fi
if [[ -f "$run_dir/external-dependency.json" ]]; then
  external_dependency_status="$(recorded_phase_status "$run_dir" external-dependency)"
  if [[ "$external_dependency_status" == 'failed' ||
    "$external_dependency_status" == 'not-classified' ]]; then
    run_result='broken'
  fi
fi
assertion_status="$primary_assertion_status"
if [[ -f "$run_dir/assertion.json" ]]; then
  assertion_status="$(recorded_phase_status "$run_dir" assertion)"
fi
append_lifecycle_junit "$run_dir/junit.xml" "$suite_id" \
  "$external_dependency_status" "$cleanup_status" "$recovery_status" \
  passed "$run_result"
cluster_name="$(lease_kubectl "$kubeconfig" config view --minify \
  --output jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
[[ -n "$cluster_name" ]] || cluster_name='unavailable'
write_environment "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
  "$started_at" "$finished_at" "${TEST_NAMESPACE:-all}" \
  "$kubeconfig" "$confirmation_variable"
normalize_native_artifacts "$run_dir" "$run_id"
write_evidence_index "$run_dir" "$run_id"
write_summary "$run_dir" "$run_id" "$entry_json" "$execution_origin" \
  "$started_at" "$finished_at" "$duration_seconds" "$run_result" \
  "$primary_exit_code" "$assertion_status" passed "$cleanup_status" \
  "$recovery_status" "$external_dependency_status" "$cluster_name"
scripts/test/validate-run.sh "$run_dir"

finalized=true
trap - EXIT INT TERM
echo "Test results: $run_dir"
exit "$(result_exit_code "$primary_exit_code" "$run_result")"
