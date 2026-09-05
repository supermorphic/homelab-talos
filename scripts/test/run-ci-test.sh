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

binding_bin="$fixture_root/binding-bin"
binding_catalog="$fixture_root/binding-catalog.yaml"
binding_fake_just_log="$fixture_root/binding-fake-just.log"
binding_output="$fixture_root/binding-output.log"
binding_plan="$fixture_root/binding-plan.json"
binding_unselected_plan="$fixture_root/binding-unselected-plan.json"
binding_malformed_plan="$fixture_root/binding-malformed-plan.json"
binding_wrong_head_plan="$fixture_root/binding-wrong-head-plan.json"
binding_results="$fixture_root/binding-results"
binding_run_id_file="$fixture_root/binding-ci.run-id"
real_uv_bin="$(command -v uv)"
rejected_group_cases=0
mkdir -p "$binding_bin"
cp tests/fixtures/result-coordinator/catalog.yaml "$binding_catalog"
printf '%s\n' \
	'{"schema_version":1,"plan_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","base_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","head_sha":"cccccccccccccccccccccccccccccccccccccccc","mode":"selective","groups":["core"],"reasons":[]}' \
	>"$binding_plan"
cp "$binding_plan" "$binding_unselected_plan"
printf '%s\n' '{' >"$binding_malformed_plan"
printf '%s\n' \
	'{"schema_version":1,"plan_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","base_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","head_sha":"dddddddddddddddddddddddddddddddddddddddd","mode":"selective","groups":["core"],"reasons":[]}' \
	>"$binding_wrong_head_plan"

# The coordinator boundary receives a synthetic Git head so the fixture can use stable
# identities. Any Git call outside the coordinator's documented read-only set fails.
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'case "$*" in' \
	'  "rev-parse --show-toplevel") printf "%s\n" "${REAL_REPO_ROOT:?}" ;;' \
	'  "rev-parse HEAD") printf "%s\n" cccccccccccccccccccccccccccccccccccccccc ;;' \
	'  "rev-parse --short=12 HEAD") printf "%s\n" cccccccccccc ;;' \
	'  "branch --show-current") printf "%s\n" fixture ;;' \
	'  "status --porcelain") exit 0 ;;' \
	'  *) printf "Unexpected git call: %s\n" "$*" >&2; exit 2 ;;' \
	'esac' >"$binding_bin/git"

# The real planner has its own unit tests. This boundary fake accepts the mandated
# synthetic digest while enforcing the validate argv and plan/head consistency.
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'if [[ "$#" -ne 9 || "$1" != run || "$2" != --locked || "$3" != python ||' \
	'  "$4" != scripts/test/ci_plan.py || "$5" != validate ]]; then' \
	'  exec "${REAL_UV_BIN:?}" "$@"' \
	'fi' \
	'[[ "$6" == --plan && "$8" == --head ]] || exit 2' \
	'python - "$7" "$9" <<'"'"'PY'"'"'' \
	'import json' \
	'import re' \
	'import sys' \
	'try:' \
	'    with open(sys.argv[1], encoding="utf-8") as stream:' \
	'        plan = json.load(stream)' \
	'    assert set(plan) == {"schema_version", "plan_id", "base_sha", "head_sha", "mode", "groups", "reasons"}' \
	'    assert plan["schema_version"] == 1' \
	'    assert re.fullmatch(r"[0-9a-f]{64}", plan["plan_id"])' \
	'    assert re.fullmatch(r"[0-9a-f]{40}", plan["base_sha"])' \
	'    assert re.fullmatch(r"[0-9a-f]{40}", plan["head_sha"])' \
	'    assert plan["head_sha"] == sys.argv[2]' \
	'    assert plan["mode"] in ("selective", "full")' \
	'    assert isinstance(plan["groups"], list) and "core" in plan["groups"]' \
	'    assert isinstance(plan["reasons"], list)' \
	'except (AssertionError, json.JSONDecodeError, OSError):' \
	'    raise SystemExit(2)' \
	'PY' >"$binding_bin/uv"

# shellcheck disable=SC2016
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'run_dir="${TEST_SHARED_RESULT_DIR%/diagnostics/shared}"' \
	'[[ ! -e "$run_dir/diagnostics/ci-binding.json" ]]' \
	'printf "%s\n" "$*" >>"${FAKE_JUST_LOG:?}"' \
	'exit 0' >"$binding_bin/just"
chmod +x "$binding_bin/git" "$binding_bin/uv" "$binding_bin/just"

run_group_case() {
	local execution="$1"
	local group="$2"
	local plan="$3"
	rm -rf -- "$binding_results"
	rm -f -- "$binding_run_id_file"
	: >"$binding_fake_just_log"
	: >"$binding_output"
	set +e
	PATH="$binding_bin:$PATH" \
		REAL_REPO_ROOT="$(pwd -P)" \
		REAL_UV_BIN="$real_uv_bin" \
		FAKE_JUST_LOG="$binding_fake_just_log" \
		TEST_CATALOG_PATH="$binding_catalog" \
		TEST_RESULTS_ROOT="$binding_results" \
		TEST_JUST_BIN="$binding_bin/just" \
		TEST_EXECUTION_ORIGIN=agent \
		TEST_RUN_ID_FILE="$binding_run_id_file" \
		scripts/test/run-ci.sh --execution "$execution" --group "$group" \
		--plan "$plan" >"$binding_output" 2>&1
	group_exit="$?"
	set -e
}

assert_group_rejected_before_execution() {
	local execution="$1"
	local group="$2"
	local plan="$3"
	run_group_case "$execution" "$group" "$plan"
	if [[ "$group_exit" -ne 2 ]]; then
		echo "Rejected grouped CI case exited $group_exit; expected 2." >&2
		cat "$binding_output" >&2
		exit 1
	fi
	if [[ -s "$binding_fake_just_log" ]]; then
		echo 'Rejected grouped CI case invoked the fake just command.' >&2
		exit 1
	fi
	if [[ -e "$binding_results" &&
		-n "$(find "$binding_results" -mindepth 1 -print -quit)" ]]; then
		echo 'Rejected grouped CI case created a result entry.' >&2
		exit 1
	fi
	if [[ -e "$binding_run_id_file" ]]; then
		echo 'Rejected grouped CI case wrote a run ID.' >&2
		exit 1
	fi
	rejected_group_cases=$((rejected_group_cases + 1))
}

run_group_case ci-core core "$binding_plan"
if [[ "$group_exit" -ne 0 ]]; then
	echo "Selected grouped CI run exited $group_exit; expected 0." >&2
	cat "$binding_output" >&2
	exit 1
fi
if [[ "$(cat "$binding_fake_just_log")" != 'fixture-pass' ]]; then
	echo 'Selected grouped CI run did not execute only the core fixture.' >&2
	exit 1
fi
binding_run_dir="$binding_results/$(cat "$binding_run_id_file")"
scripts/test/validate-run.sh "$binding_run_dir" >/dev/null
mise exec -- yq -e '
  (keys | sort | join(",")) == "base_sha,execution,group,head_sha,plan_id,schema_version" and
  .schema_version == 1 and
  .plan_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .base_sha == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
  .head_sha == "cccccccccccccccccccccccccccccccccccccccc" and
  .group == "core" and
  .execution == "ci-core"
' "$binding_run_dir/diagnostics/ci-binding.json" >/dev/null
mise exec -- yq -e \
	'.artifacts | map(.path == "diagnostics/ci-binding.json") | any' \
	"$binding_run_dir/evidence.json" >/dev/null

cp "$binding_run_dir/diagnostics/ci-binding.json" "$fixture_root/ci-binding.json"
mise exec -- yq -i '.schema_version = 2' \
	"$binding_run_dir/diagnostics/ci-binding.json"
if scripts/test/validate-run.sh "$binding_run_dir" >/dev/null 2>&1; then
	echo 'Canonical validation must reject an invalid CI binding schema.' >&2
	exit 1
fi
cp "$fixture_root/ci-binding.json" "$binding_run_dir/diagnostics/ci-binding.json"
mise exec -- yq -i \
	'.head_sha = "dddddddddddddddddddddddddddddddddddddddd"' \
	"$binding_run_dir/diagnostics/ci-binding.json"
if scripts/test/validate-run.sh "$binding_run_dir" >/dev/null 2>&1; then
	echo 'Canonical validation must reject a CI binding for another Git SHA.' >&2
	exit 1
fi
cp "$fixture_root/ci-binding.json" "$binding_run_dir/diagnostics/ci-binding.json"

assert_group_rejected_before_execution ci-unknown core "$binding_plan"
assert_group_rejected_before_execution ci-observability observability \
	"$binding_unselected_plan"
assert_group_rejected_before_execution ci-observability core "$binding_plan"
assert_group_rejected_before_execution ci-core core "$binding_malformed_plan"
assert_group_rejected_before_execution ci-core core "$binding_wrong_head_plan"
echo "Grouped CI pre-execution rejections passed: $rejected_group_cases cases, 0 fake executions."

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
