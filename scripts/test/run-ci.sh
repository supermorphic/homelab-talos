#!/usr/bin/env bash
# Fail-fast CI coordinator. Streams each existing recipe unchanged while producing one
# canonical multi-suite run. Child runners may place native JUnit fragments in
# TEST_RESULT_FRAGMENT_DIR; commands without a native reporter receive a wrapper case.
set -euo pipefail

source scripts/lib/common.sh
source scripts/test/lib/catalog.sh
source scripts/test/lib/results.sh
require_bash

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
catalog="${TEST_CATALOG_PATH:-tests/catalog.yaml}"
results_root="${TEST_RESULTS_ROOT:-.test-results}"
just_bin="${TEST_JUST_BIN:-just}"
aggregate_entry="$(catalog_entry_by_id "$catalog" validation.ci)"
execution_origin="$(resolve_execution_origin)"
run_dir="$(create_run_directory "$results_root" "$execution_origin")"
run_id="$(basename "$run_dir")"
write_run_id_output "$run_id"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_epoch="$EPOCHSECONDS"
mkdir -p "$run_dir/diagnostics/fragments" "$run_dir/diagnostics/suites"

declare -a suite_reports=()
suite_records=''
fail_fast=false
run_result='passed'
primary_exit_code=0
signal_exit_code=0

handle_signal() {
  local signal="$1"
  case "$signal" in
    INT) signal_exit_code=130 ;;
    TERM) signal_exit_code=143 ;;
  esac
}
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

append_suite_record() {
  local suite_id="$1"
  local suite_result="$2"
  local report="$3"
  local counts tests failures errors skipped _passed record
  counts="$(read_junit_counts "$report")"
  read -r tests failures errors skipped _passed <<<"$counts"
  record="$(
    SUITE_ID="$suite_id" \
    SUITE_RESULT="$suite_result" \
    TESTS="$tests" \
    FAILURES="$failures" \
    ERRORS="$errors" \
    SKIPPED="$skipped" \
      yq --null-input --output-format json --indent 0 '{
        "id": strenv(SUITE_ID),
        "result": strenv(SUITE_RESULT),
        "tests": (strenv(TESTS) | tonumber),
        "failures": (strenv(FAILURES) | tonumber),
        "errors": (strenv(ERRORS) | tonumber),
        "skipped": (strenv(SKIPPED) | tonumber)
      }'
  )"
  suite_records+="${suite_records:+$'\n'}$record"
}

while IFS= read -r suite_id; do
  [[ -n "$suite_id" ]] || continue
  entry="$(catalog_entry_by_id "$catalog" "$suite_id")"
  command="$(yq -r '.runner.command' - <<<"$entry")"
  command_args="${command#mise exec -- just }"
  [[ "$command_args" != "$command" && "$command_args" =~ ^[a-zA-Z0-9_.-]+([[:space:]][a-zA-Z0-9_.-]+)*$ ]] || {
    echo "Unsafe CI catalog command for $suite_id: $command" >&2
    exit 2
  }
  read -r -a just_args <<<"$command_args"

  fragment_dir="$run_dir/diagnostics/fragments/$suite_id"
  suite_report="$run_dir/diagnostics/suites/$suite_id.xml"
  suite_log="$run_dir/logs/$suite_id.log"
  mkdir -p "$fragment_dir"

  if [[ "$fail_fast" == true ]]; then
    printf 'Skipped after earlier CI suite failure.\n' >"$suite_log"
    write_result_case_junit "$suite_report" "$suite_id" fail-fast skipped 0
    append_suite_record "$suite_id" skipped "$suite_report"
    suite_reports+=("$suite_report")
    continue
  fi

  suite_started="$EPOCHSECONDS"
  echo "=== $suite_id: just $command_args ==="
  set +e
  TEST_RESULT_FRAGMENT_DIR="$(cd "$fragment_dir" && pwd)" \
    "$just_bin" "${just_args[@]}" 2>&1 | tee "$suite_log"
  command_exit_code="${PIPESTATUS[0]}"
  set -e
  if [[ "$signal_exit_code" -ne 0 ]]; then
    command_exit_code="$signal_exit_code"
  fi
  suite_duration=$((EPOCHSECONDS - suite_started))

  mapfile -t native_fragments < <(
    find "$fragment_dir" -type f -name '*.xml' -print | LC_ALL=C sort
  )
  suite_result='passed'
  if [[ "${#native_fragments[@]}" -gt 0 ]]; then
    set +e
    merge_junit_reports "$suite_report" "$suite_id" "${native_fragments[@]}"
    merge_exit_code="$?"
    set -e
    if [[ "$merge_exit_code" -ne 0 ]]; then
      write_result_case_junit "$suite_report" "$suite_id" junit-merge broken \
        "$suite_duration"
      suite_result='broken'
    else
      counts="$(read_junit_counts "$suite_report")"
      read -r _tests failures errors _skipped _passed <<<"$counts"
      if [[ "$errors" -gt 0 ]]; then
        suite_result='broken'
      elif [[ "$failures" -gt 0 ]]; then
        suite_result='failed'
      elif [[ "$command_exit_code" -ne 0 ]]; then
        write_result_case_junit "$suite_report" "$suite_id" exit-mismatch broken \
          "$suite_duration"
        suite_result='broken'
      fi
    fi
  elif [[ "$signal_exit_code" -ne 0 ]]; then
    write_result_case_junit "$suite_report" "$suite_id" signal broken \
      "$suite_duration"
    suite_result='broken'
  elif [[ "$command_exit_code" -eq 0 ]]; then
    write_result_case_junit "$suite_report" "$suite_id" command passed \
      "$suite_duration"
  else
    write_result_case_junit "$suite_report" "$suite_id" command failed \
      "$suite_duration"
    suite_result='failed'
  fi

  append_suite_record "$suite_id" "$suite_result" "$suite_report"
  suite_reports+=("$suite_report")
  if [[ "$command_exit_code" -ne 0 || "$suite_result" != 'passed' ]]; then
    fail_fast=true
    primary_exit_code="$command_exit_code"
    [[ "$primary_exit_code" -ne 0 ]] || primary_exit_code=1
    run_result="$suite_result"
    echo "CI fail-fast stop after $suite_id ($suite_result)." >&2
  fi
done < <(catalog_execution_ids "$catalog" ci)

merge_junit_reports "$run_dir/junit.xml" validation.ci "${suite_reports[@]}"
suites_json="$(
  SUITE_RECORDS="$suite_records" yq --null-input --output-format json '[
    strenv(SUITE_RECORDS) | split("\n")[] | select(. != "") | from_json
  ]'
)"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
duration_seconds=$((EPOCHSECONDS - started_epoch))
write_environment "$run_dir" "$run_id" "$aggregate_entry" "$execution_origin" \
  "$started_at" "$finished_at" offline tests/.offline-validation-no-kubeconfig none
write_evidence_index "$run_dir" "$run_id"
write_multi_summary "$run_dir" "$run_id" "$aggregate_entry" "$execution_origin" \
  "$started_at" "$finished_at" "$duration_seconds" "$run_result" \
  "$primary_exit_code" "$suites_json"
scripts/test/validate-run.sh "$run_dir"

echo "CI results: $run_dir"
if [[ "$primary_exit_code" -ne 0 ]]; then
  exit "$primary_exit_code"
fi
[[ "$run_result" == 'passed' ]]
