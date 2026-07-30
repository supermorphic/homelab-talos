#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-ci-runner-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
calls="$fixture_root/calls.txt"
touch "$calls"
run_id_file="$fixture_root/ci.run-id"

set +e
FAKE_JUST_CALLS="$calls" \
UV_CACHE_DIR="$fixture_root/uv-cache" \
TEST_CATALOG_PATH=tests/fixtures/result-coordinator/catalog.yaml \
TEST_RESULTS_ROOT="$fixture_root/results" \
TEST_JUST_BIN=tests/fixtures/result-coordinator/fake-just.sh \
TEST_EXECUTION_ORIGIN=agent \
TEST_RUN_ID_FILE="$run_id_file" \
  scripts/test/run-ci.sh >/dev/null 2>&1
runner_exit="$?"
set -e
[[ "$runner_exit" -eq 9 ]]
[[ "$(cat "$calls")" == $'fixture-pass\nfixture-fail' ]]

mapfile -t runs < <(find "$fixture_root/results" -mindepth 1 -maxdepth 1 -type d)
[[ "${#runs[@]}" -eq 1 ]]
run_dir="${runs[0]}"
[[ "$(cat "$run_id_file")" == "$(basename "$run_dir")" ]]
scripts/test/validate-run.sh "$run_dir" >/dev/null
[[ "$(yq -r '.result' "$run_dir/summary.json")" == 'failed' ]]
[[ "$(yq -r '.junit.tests' "$run_dir/summary.json")" == '3' ]]
[[ "$(yq -r '.junit.failures' "$run_dir/summary.json")" == '1' ]]
[[ "$(yq -r '.junit.skipped' "$run_dir/summary.json")" == '1' ]]
[[ "$(yq -r '.suites[0].result' "$run_dir/summary.json")" == 'passed' ]]
[[ "$(yq -r '.suites[1].result' "$run_dir/summary.json")" == 'failed' ]]
[[ "$(yq -r '.suites[2].result' "$run_dir/summary.json")" == 'skipped' ]]
[[ "$(yq -r '.suites[0].duration_ms >= 20' "$run_dir/summary.json")" == 'true' ]]
[[ "$(yq -r '.suites[1].duration_ms >= 20' "$run_dir/summary.json")" == 'true' ]]
[[ "$(yq -r '.suites[2].duration_ms' "$run_dir/summary.json")" == '0' ]]
yq -i '.suites[0].duration_ms = -1' "$run_dir/summary.json"
if scripts/test/validate-run.sh "$run_dir" >/dev/null 2>&1; then
  echo 'Canonical validation must reject a negative suite duration.' >&2
  exit 1
fi
yq -i '.suites[0].duration_ms = 0 | del(.suites[1].duration_ms)' \
  "$run_dir/summary.json"
if scripts/test/validate-run.sh "$run_dir" >/dev/null 2>&1; then
  echo 'Canonical validation must reject a missing multi-suite duration.' >&2
  exit 1
fi

echo 'CI result coordinator fail-fast tests passed.'
