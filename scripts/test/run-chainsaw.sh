#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/catalog.sh
source scripts/test/lib/lease.sh
source scripts/test/lib/results.sh
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

kubeconfig='.kube/config'
namespace='flux-system'
catalog='tests/catalog.yaml'

entry_json="$(catalog_dispatch_entry "$catalog" "$tier" "$target" "$scenario")" || exit "$?"
dispatch_mode="$(yq -r '.dispatch.mode' - <<<"$entry_json")"
test_dir="$(yq -r '.dispatch.path' - <<<"$entry_json")"
selector="$(yq -r '.dispatch.selector // ""' - <<<"$entry_json")"
mutates_cluster="$(yq -r '.metadata.mutates_cluster' - <<<"$entry_json")"
confirmation_variable="$(yq -r '.confirmation.variable // "none"' - <<<"$entry_json")"
diagnostics_only=false
[[ "$dispatch_mode" == 'diagnostics' ]] && diagnostics_only=true

case "$confirmation_variable" in
  CLUSTER_E2E_CONFIRM) scripts/test/safety/require-e2e-confirmation.sh "$target" ;;
  CLUSTER_CHAOS_CONFIRM) scripts/test/safety/require-chaos-confirmation.sh "$target" ;;
  none) ;;
  *)
    echo "Unsupported dispatch confirmation variable: $confirmation_variable" >&2
    exit 2
    ;;
esac

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

execution_origin="$(resolve_execution_origin)"
run_dir="$(create_run_directory '.test-results' "$execution_origin")"
run_id="$(basename "$run_dir")"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_epoch="$EPOCHSECONDS"
cluster_name="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
  --output jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
[[ -n "$cluster_name" ]] || cluster_name='unavailable'
lease_acquired=false
# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
release_chainsaw_lease() {
  if [[ "$lease_acquired" == 'true' ]]; then
    release_test_lease "$kubeconfig" "$run_id" >/dev/null 2>&1 || true
    lease_acquired=false
  fi
}
trap release_chainsaw_lease EXIT
if [[ "$mutates_cluster" == 'true' ]]; then
  if ! acquire_test_lease "$kubeconfig" "$run_id"; then
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
    echo "Chainsaw results: $run_dir"
    exit 1
  fi
  lease_acquired=true
  start_test_lease_renewal "$kubeconfig" "$run_id" \
    "$(cd "$run_dir" && pwd)/diagnostics/lease-renewal-failed"
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
set +e
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
  --no-color 2>&1 | tee "$run_dir/logs/chainsaw.log"
primary_exit_code="${PIPESTATUS[0]}"
set -e

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
  release_test_lease "$kubeconfig" "$run_id" ||
    lease_finalization_failed=true
  if [[ "$lease_finalization_failed" == 'true' ]]; then
    diagnostics_status='failed'
  fi
  lease_acquired=false
fi

# State-changing scenarios drive cleanup/recovery in a trap/finally block and record its
# outcome in recovery.json. Surface it separately without rewriting the primary assertion.
cleanup_status='not-required'
recovery_status='not-required'
external_dependency_status='not-applicable'
if [[ "$tier" == 'e2e' || "$tier" == 'resilience' ]]; then
  recovery_status="$(recorded_recovery_status "$run_dir")"
  cleanup_status="$recovery_status"
fi
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
cp "$run_dir/junit.xml" "$run_dir/diagnostics/chainsaw-junit.xml"
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

overall_exit_code="$(result_exit_code "$primary_exit_code" "$run_result")"
echo "Chainsaw results: $run_dir"
trap - EXIT
exit "$overall_exit_code"
