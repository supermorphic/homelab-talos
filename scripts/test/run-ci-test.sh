#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-ci-runner-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
calls="$fixture_root/calls.txt"
touch "$calls"
run_id_file="$fixture_root/ci.run-id"
fake_just="$fixture_root/fake-just.sh"
fake_just_log="$fixture_root/fake-just.log"
catalog="$fixture_root/catalog.yaml"

stdin_catalog="$fixture_root/stdin-catalog.yaml"
stdin_fake_just="$fixture_root/stdin-fake-just.sh"
stdin_fake_just_log="$fixture_root/stdin-fake-just.log"
stdin_run_id_file="$fixture_root/stdin-ci.run-id"
cp tests/fixtures/result-coordinator/catalog.yaml "$stdin_catalog"
yq -i '
  .executions.ci = ["validation.fixture-pass", "validation.fixture-fail", "validation.fixture-skipped"] |
  (.suites[] | select(.metadata.id == "validation.fixture-pass").runner.command) = "mise exec -- just fixture first" |
  (.suites[] | select(.metadata.id == "validation.fixture-fail").runner.command) = "mise exec -- just fixture stdin-consumer" |
  (.suites[] | select(.metadata.id == "validation.fixture-skipped").runner.command) = "mise exec -- just fixture last" |
  (.suites[] | select(.metadata.id == "validation.fixture-pass").native_results.strategy) = "wrapper-junit" |
  (.suites[] | select(.metadata.id == "validation.fixture-fail").native_results.strategy) = "wrapper-junit" |
  (.suites[] | select(.metadata.id == "validation.fixture-skipped").native_results.strategy) = "wrapper-junit"
' "$stdin_catalog"
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'printf "%s\n" "$*" >>"${FAKE_JUST_LOG:?}"' \
	'[[ "$*" != "fixture stdin-consumer" ]] || cat >/dev/null' \
	'exit 0' >"$stdin_fake_just"
chmod +x "$stdin_fake_just"

FAKE_JUST_LOG="$stdin_fake_just_log" \
	UV_CACHE_DIR="$fixture_root/uv-cache" \
	TEST_CATALOG_PATH="$stdin_catalog" \
	TEST_RESULTS_ROOT="$fixture_root/stdin-results" \
	TEST_JUST_BIN="$stdin_fake_just" \
	TEST_EXECUTION_ORIGIN=agent \
	TEST_RUN_ID_FILE="$stdin_run_id_file" \
	scripts/test/run-ci.sh >/dev/null 2>&1
stdin_run_dir="$fixture_root/stdin-results/$(cat "$stdin_run_id_file")"
[[ "$(cat "$stdin_fake_just_log")" == $'fixture first\nfixture stdin-consumer\nfixture last' ]]
[[ "$(yq -r '.suites | length' "$stdin_run_dir/summary.json")" -eq 3 ]]
[[ "$(yq -r '.junit.tests' "$stdin_run_dir/summary.json")" -eq 3 ]]

cp tests/fixtures/result-coordinator/catalog.yaml "$catalog"
yq -i '
  .executions.ci = ["validation.repo-validate", "validation.test-harness"] |
  .suites[1].metadata.id = "validation.repo-validate" |
  .suites[1].runner.command = "mise exec -- just repo validate" |
  .suites[2].metadata.id = "validation.test-harness" |
  .suites[2].runner.command = "mise exec -- just test validate"
' "$catalog"
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'[[ -z "${TEST_RUN_ID_FILE+x}" ]]' \
	'printf "%s\\t%s\\t%s\\n" "$*" "${TEST_SHARED_RESULT_DIR:?}" "${TEST_RUN_ID:?}" >>"${FAKE_JUST_LOG:?}"' \
	'case "$*" in' \
	'  "repo validate") exit 9 ;;' \
	'  "test validate") printf "%s\\n" "repository_shell_validation.py consume" >>"${FAKE_JUST_LOG:?}"; exit 99 ;;' \
	'  *) exit 2 ;;' \
	'esac' >"$fake_just"
chmod +x "$fake_just"

set +e
FAKE_JUST_CALLS="$calls" \
	FAKE_JUST_LOG="$fake_just_log" \
	UV_CACHE_DIR="$fixture_root/uv-cache" \
	TEST_CATALOG_PATH="$catalog" \
	TEST_RESULTS_ROOT="$fixture_root/results" \
	TEST_JUST_BIN="$fake_just" \
	TEST_EXECUTION_ORIGIN=agent \
	TEST_RUN_ID_FILE="$run_id_file" \
	TEST_SHARED_RESULT_DIR="$fixture_root/caller-shared" \
	TEST_RUN_ID=caller-run-id \
	scripts/test/run-ci.sh >/dev/null 2>&1
runner_exit="$?"
set -e
[[ "$runner_exit" -eq 9 ]]
[[ ! -e "$fixture_root/caller-shared" ]]

mapfile -t runs < <(find "$fixture_root/results" -mindepth 1 -maxdepth 1 -type d)
[[ "${#runs[@]}" -eq 1 ]]
run_dir="$(cd "${runs[0]}" && pwd)"
[[ "$(cat "$run_id_file")" == "$(basename "$run_dir")" ]]
shared_result_dir="$run_dir/diagnostics/shared"
[[ -d "$shared_result_dir" ]]
[[ -z "$(find "$shared_result_dir" -mindepth 1 -print -quit)" ]]
captured_children=0
while IFS=$'\t' read -r command captured_shared captured_run_id; do
	[[ "$captured_shared" == "$shared_result_dir" ]]
	[[ "$captured_run_id" == "$(basename "$run_dir")" ]]
	[[ "$command" == 'repo validate' ]]
	captured_children=$((captured_children + 1))
done <"$fake_just_log"
[[ "$captured_children" -eq 1 ]]
if rg -q 'repository_shell_validation.py consume' "$fake_just_log"; then
	echo 'Fail-fast must prevent repository shell result consumption.' >&2
	exit 1
fi
scripts/test/validate-run.sh "$run_dir" >/dev/null
[[ "$(yq -r '.result' "$run_dir/summary.json")" == 'failed' ]]
[[ "$(yq -r '.junit.tests' "$run_dir/summary.json")" == '2' ]]
[[ "$(yq -r '.junit.failures' "$run_dir/summary.json")" == '1' ]]
[[ "$(yq -r '.junit.skipped' "$run_dir/summary.json")" == '1' ]]
[[ "$(yq -r '.suites[0].result' "$run_dir/summary.json")" == 'failed' ]]
[[ "$(yq -r '.suites[1].result' "$run_dir/summary.json")" == 'skipped' ]]
[[ "$(yq -r '.suites[0].duration_ms >= 0' "$run_dir/summary.json")" == 'true' ]]
[[ "$(yq -r '.suites[1].duration_ms' "$run_dir/summary.json")" == '0' ]]
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

native_catalog="$fixture_root/native-catalog.yaml"
native_fake_just="$fixture_root/native-fake-just.sh"
native_fake_just_log="$fixture_root/native-fake-just.log"
native_run_id_file="$fixture_root/native-ci.run-id"
cp tests/fixtures/result-coordinator/catalog.yaml "$native_catalog"
yq -i '
  .suites[1].native_results.strategy = "wrapper-junit" |
  .suites[2].native_results.strategy = "native-junit" |
  .suites[3].native_results.strategy = "wrapper-junit"
' "$native_catalog"
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'printf "%s\\n" "$*" >>"${FAKE_JUST_LOG:?}"' \
	'exit 0' >"$native_fake_just"
chmod +x "$native_fake_just"

set +e
FAKE_JUST_LOG="$native_fake_just_log" \
	UV_CACHE_DIR="$fixture_root/uv-cache" \
	TEST_CATALOG_PATH="$native_catalog" \
	TEST_RESULTS_ROOT="$fixture_root/native-results" \
	TEST_JUST_BIN="$native_fake_just" \
	TEST_EXECUTION_ORIGIN=agent \
	TEST_RUN_ID_FILE="$native_run_id_file" \
	scripts/test/run-ci.sh >/dev/null 2>&1
native_runner_exit="$?"
set -e
[[ "$native_runner_exit" -ne 0 ]]

mapfile -t native_runs < <(
	find "$fixture_root/native-results" -mindepth 1 -maxdepth 1 -type d
)
[[ "${#native_runs[@]}" -eq 1 ]]
native_run_dir="$(cd "${native_runs[0]}" && pwd)"
[[ "$(wc -l <"$native_fake_just_log" | tr -d ' ')" -eq 2 ]]
[[ "$(sed -n '1p' "$native_fake_just_log")" == 'fixture-pass' ]]
[[ "$(sed -n '2p' "$native_fake_just_log")" == 'fixture-fail' ]]
scripts/test/validate-run.sh "$native_run_dir" >/dev/null
[[ "$(yq -r '.result' "$native_run_dir/summary.json")" == 'broken' ]]
[[ "$(yq -r '.suites[0].result' "$native_run_dir/summary.json")" == 'passed' ]]
[[ "$(yq -r '.suites[1].result' "$native_run_dir/summary.json")" == 'broken' ]]
[[ "$(yq -r '.suites[1].errors' "$native_run_dir/summary.json")" == '1' ]]
[[ "$(yq -r '.suites[2].result' "$native_run_dir/summary.json")" == 'skipped' ]]

echo 'CI result coordinator fail-fast tests passed.'
