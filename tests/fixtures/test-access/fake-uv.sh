#!/usr/bin/env bash
# Replace private credential installation only; canonical catalog reads stay real.
set -euo pipefail
argv=("$@")
while [[ "$#" -gt 0 && "$1" != scripts.test.access ]]; do shift; done
[[ "$#" -gt 0 ]] || exec "$TEST_FIXTURE_REAL_UV" "${argv[@]}"
shift
printf '%s\n' "$*" >>"$TEST_FIXTURE_ACCESS_TRACE"
case "$1" in
  resolve) exec "$TEST_FIXTURE_REAL_UV" "${argv[@]}" ;;
  prepare)
    config="$TEST_FIXTURE_ACCESS_ROOT/private/$3/config"
    mkdir -p "$(dirname "$config")"
    printf 'synthetic invocation\n' >"$config"
    SUITE_ID="$2" RUN_ID="$3" yq -n -o=json \
      '{"suite_id":strenv(SUITE_ID),"run_id":strenv(RUN_ID)}' >"$(dirname "$config")/binding.json"
    printf '%s\n' "$config"
    ;;
  validate)
    [[ "$2" == "$TEST_FIXTURE_ACCESS_ROOT/private/"* && -f "$2" ]]
    ;;
  purpose)
    case "$2" in campaign-observer|campaign-coordinator|report-publisher) ;; *) exit 2 ;; esac
    config="$TEST_FIXTURE_ACCESS_ROOT/private/$3-$2/config"
    mkdir -p "$(dirname "$config")"
    printf 'synthetic purpose invocation\n' >"$config"
    PURPOSE="$2" RUN_ID="$3" yq -n -o=json \
      '{"purpose":strenv(PURPOSE),"run_id":strenv(RUN_ID)}' >"$(dirname "$config")/binding.json"
    printf '%s\n' "$config"
    ;;
  purpose-check)
    [[ "${TEST_FIXTURE_PURPOSE_CHECK_FAIL:-}" != true ]] || exit 7
    [[ "$4" == "$TEST_FIXTURE_ACCESS_ROOT/private/"* && -f "$4" ]]
    [[ "$(yq -r '.purpose' "$(dirname "$4")/binding.json")" == "$2" &&
       "$(yq -r '.run_id' "$(dirname "$4")/binding.json")" == "$3" ]]
    ;;
  inherit)
    [[ "${TEST_FIXTURE_ACCESS_CHECK_FAIL:-}" != true ]] || exit 7
    config="$3"
    [[ "$config" == "$TEST_FIXTURE_ACCESS_ROOT/private/"* && -f "$config" ]]
    parent="$(yq -r '.suite_id' "$(dirname "$config")/binding.json")"
    [[ "$2" == "$parent" || "$2" == verification.* || "$2" == diagnostics.cluster ]]
    ;;
  remove)
    [[ "$2" == "$TEST_FIXTURE_ACCESS_ROOT/private/"* ]]
    if [[ -n "${TEST_FIXTURE_ACCESS_FINALIZATION_ROOT:-}" ]]; then
      run_id="$(yq -r '.run_id' "$(dirname "$2")/binding.json")"
      [[ -f "$TEST_FIXTURE_ACCESS_FINALIZATION_ROOT/$run_id/summary.json" &&
         -f "$TEST_FIXTURE_ACCESS_FINALIZATION_ROOT/$run_id/junit.xml" &&
         -f "$TEST_FIXTURE_ACCESS_FINALIZATION_ROOT/$run_id/evidence.json" ]]
    fi
    [[ "${TEST_FIXTURE_ACCESS_REMOVE_FAIL:-}" != true ]] || exit 7
    rm -- "$2"
    ;;
  *) exit 2 ;;
esac
