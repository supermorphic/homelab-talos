#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/catalog.sh
source scripts/test/lib/results.sh

result_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-results-test.XXXXXX")"
trap 'rm -rf -- "$result_root"' EXIT

entry_json="$(catalog_dispatch_entry tests/catalog.yaml smoke cluster flux-ready)"
export TEST_EXECUTION_ORIGIN=agent
[[ "$(GITHUB_HEAD_REF=feat/ci-fixture GITHUB_REF_NAME='' \
	resolve_git_branch '')" == 'feat/ci-fixture' ]]
[[ "$(GITHUB_HEAD_REF='' GITHUB_REF_NAME=main \
	resolve_git_branch '')" == 'main' ]]
[[ "$(GITHUB_HEAD_REF='' GITHUB_REF_NAME='' resolve_git_branch '')" == 'detached' ]]
run_dir="$(create_run_directory "$result_root" "$(resolve_execution_origin)")"
run_id="$(basename "$run_dir")"

[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-agent-[0-9a-f]{8}$ ]]
for required in logs diagnostics evidence.json; do
	[[ -e "$run_dir/$required" ]] || {
		echo "Run initialization omitted $required." >&2
		exit 1
	}
done
[[ ! -e "$run_dir/diagnostics/shared" ]] || {
	echo 'Standalone run initialization must not create the CI shared-result boundary.' >&2
	exit 1
}

ci_three_catalog="$result_root/ci-three-catalog.yaml"
ci_four_catalog="$result_root/ci-four-catalog.yaml"
ci_fake_just="$result_root/ci-fake-just.sh"
ci_fake_log="$result_root/ci-fake-just.log"
ci_initial_log="$result_root/ci-initial.log"
touch "$ci_initial_log"
cp tests/fixtures/result-coordinator/catalog.yaml "$ci_three_catalog"
yq -i '
  .executions.ci = ["validation.core", "validation.observability", "validation.automation"]
' "$ci_three_catalog"
cp tests/fixtures/result-coordinator/catalog.yaml "$ci_four_catalog"
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'case "$*" in' \
	'  fixture-pass)' \
	'    [[ -z "$(find "${TEST_SHARED_RESULT_DIR:?}" -mindepth 1 -print -quit)" ]]' \
	'    printf "%s\\t%s\\n" "${TEST_SHARED_RESULT_DIR:?}" "${TEST_RUN_ID:?}" >>"${FAKE_INITIAL_LOG:?}"' \
	'    ;;' \
	'  fixture-fail|fixture-skipped) ;;' \
	'  *) exit 2 ;;' \
	'esac' \
	'printf "%s\\n" "$*" >"${TEST_SHARED_RESULT_DIR:?}/$1.marker"' \
	'printf "%s\\t%s\\n" "${TEST_SHARED_RESULT_DIR:?}" "${TEST_RUN_ID:?}" >>"${FAKE_JUST_LOG:?}"' >"$ci_fake_just"
chmod +x "$ci_fake_just"
FAKE_JUST_LOG="$ci_fake_log" \
	FAKE_INITIAL_LOG="$ci_initial_log" \
	TEST_CATALOG_PATH="$ci_three_catalog" \
	TEST_RESULTS_ROOT="$result_root/ci-results" \
	TEST_JUST_BIN="$ci_fake_just" \
	TEST_EXECUTION_ORIGIN=agent \
	TEST_SHARED_RESULT_DIR="$result_root/caller-shared" \
	TEST_RUN_ID=caller-run-id \
	scripts/test/run-ci.sh >/dev/null
FAKE_JUST_LOG="$ci_fake_log" \
	FAKE_INITIAL_LOG="$ci_initial_log" \
	TEST_CATALOG_PATH="$ci_four_catalog" \
	TEST_RESULTS_ROOT="$result_root/ci-results" \
	TEST_JUST_BIN="$ci_fake_just" \
	TEST_EXECUTION_ORIGIN=agent \
	TEST_SHARED_RESULT_DIR="$result_root/caller-shared-second" \
	TEST_RUN_ID=caller-run-id-second \
	scripts/test/run-ci.sh >/dev/null
mapfile -t ci_runs < <(find "$result_root/ci-results" -mindepth 1 -maxdepth 1 -type d)
[[ "${#ci_runs[@]}" -eq 2 ]]
ci_three_run_dir=''
ci_four_run_dir=''
for ci_run_dir in "${ci_runs[@]}"; do
	case "$(yq -r '.suites | length' "$ci_run_dir/summary.json")" in
	3)
		[[ -z "$ci_three_run_dir" ]] || {
			echo 'Expected exactly one three-target CI fixture run.' >&2
			exit 1
		}
		ci_three_run_dir="$(cd "$ci_run_dir" && pwd)"
		;;
	4)
		[[ -z "$ci_four_run_dir" ]] || {
			echo 'Expected exactly one four-target CI fixture run.' >&2
			exit 1
		}
		ci_four_run_dir="$(cd "$ci_run_dir" && pwd)"
		;;
	*)
		echo 'CI fixture run has an unexpected suite count.' >&2
		exit 1
		;;
	esac
done
[[ -n "$ci_three_run_dir" && -n "$ci_four_run_dir" ]]
ci_three_shared="$ci_three_run_dir/diagnostics/shared"
ci_four_shared="$ci_four_run_dir/diagnostics/shared"
ci_three_run_id="$(basename "$ci_three_run_dir")"
ci_four_run_id="$(basename "$ci_four_run_dir")"
[[ "$ci_three_shared" != "$ci_four_shared" ]]
[[ "$ci_three_run_id" != "$ci_four_run_id" ]]
ci_three_children=0
ci_four_children=0
while IFS=$'\t' read -r captured_shared captured_run_id; do
	if [[ "$captured_shared" == "$ci_three_shared" && "$captured_run_id" == "$ci_three_run_id" ]]; then
		ci_three_children=$((ci_three_children + 1))
	elif [[ "$captured_shared" == "$ci_four_shared" && "$captured_run_id" == "$ci_four_run_id" ]]; then
		ci_four_children=$((ci_four_children + 1))
	else
		echo 'CI child received an unexpected shared-result boundary.' >&2
		exit 1
	fi
done <"$ci_fake_log"
[[ "$ci_three_children" -eq 3 ]]
[[ "$ci_four_children" -eq 4 ]]
mapfile -t ci_initial_boundaries <"$ci_initial_log"
[[ "${#ci_initial_boundaries[@]}" -eq 2 ]]
ci_three_initial=0
ci_four_initial=0
for ci_initial_boundary in "${ci_initial_boundaries[@]}"; do
	if [[ "$ci_initial_boundary" == "$ci_three_shared"$'\t'"$ci_three_run_id" ]]; then
		ci_three_initial=$((ci_three_initial + 1))
	elif [[ "$ci_initial_boundary" == "$ci_four_shared"$'\t'"$ci_four_run_id" ]]; then
		ci_four_initial=$((ci_four_initial + 1))
	else
		echo 'CI fixture observed an unexpected initial shared-result boundary.' >&2
		exit 1
	fi
done
[[ "$ci_three_initial" -eq 1 ]]
[[ "$ci_four_initial" -eq 1 ]]
[[ ! -e "$result_root/caller-shared" ]]
[[ ! -e "$result_root/caller-shared-second" ]]

started_at='2026-07-27T00:00:00Z'
finished_at='2026-07-27T00:00:03Z'
write_single_case_junit "$run_dir/junit.xml" cluster flux-ready passed 3
printf '%s\n' 'captured output' >"$run_dir/logs/chainsaw.log"
printf '%s\n' '{"observation":"sanitized fixture"}' >"$run_dir/evidence.json"
printf '%s\n' '{"status":"passed","reason":"fixture cleanup"}' >"$run_dir/recovery.json"
cp "$run_dir/junit.xml" "$run_dir/diagnostics/chainsaw-junit.xml"
append_lifecycle_junit "$run_dir/junit.xml" chainsaw.smoke.cluster.flux-ready \
	not-applicable passed passed passed passed

[[ "$(recorded_recovery_status "$run_dir")" == 'passed' ]]
normalize_native_artifacts "$run_dir" "$run_id"
write_evidence_index "$run_dir" "$run_id"
write_environment "$run_dir" "$run_id" "$entry_json" agent \
	"$started_at" "$finished_at" flux-system "$result_root/no-kubeconfig" none
write_summary "$run_dir" "$run_id" "$entry_json" agent \
	"$started_at" "$finished_at" 3 passed 0 passed passed passed passed \
	not-applicable unavailable
scripts/test/validate-run.sh "$run_dir" >/dev/null

for required in junit.xml summary.json environment.json evidence.json logs diagnostics; do
	[[ -e "$run_dir/$required" ]] || {
		echo "Canonical run omitted $required." >&2
		exit 1
	}
done

yq -e '
  .schema_version == 1 and
  .run_id == "'"$run_id"'" and
  .source == "chainsaw" and
  .framework == "chainsaw" and
  .suite == "cluster" and
  .tier == "smoke" and
  .target == "cluster" and
  .scenario == "flux-ready" and
  .scope == "cluster" and
  .intent == "acceptance" and
  .git_sha != "" and
  .execution_origin == "agent" and
  .cluster == null and
  .node == null and
  .start == "2026-07-27T00:00:00Z" and
  .end == "2026-07-27T00:00:03Z" and
  .duration_seconds == 3 and
  .result == "passed" and
  .junit.tests == 6 and
  .junit.failures == 0 and
  .junit.errors == 0 and
  .junit.skipped == 1 and
  .junit.passed == 5 and
  .suites[0].id == "chainsaw.smoke.cluster.flux-ready"
' "$run_dir/summary.json" >/dev/null

yq -e '
  .schema_version == 1 and
  .execution_origin == "agent" and
  .git.sha != "" and
  .git.branch != "" and
  (.git.dirty | type == "!!bool") and
  .host.os != "" and
  .host.architecture != "" and
  .suite.id == "chainsaw.smoke.cluster.flux-ready" and
  .cluster.namespace == "flux-system" and
  .confirmation_variable == null
' "$run_dir/environment.json" >/dev/null

yq -e '
  .schema_version == 1 and
  .run_id == "'"$run_id"'" and
  ([.artifacts[].path] | sort | join("|")) ==
    "diagnostics/chainsaw-junit.xml|diagnostics/phases/recovery.json|diagnostics/scenario-evidence.json|logs/chainsaw.log" and
  ([.artifacts[].path | select(test("^/|(^|/)\\.\\.(/|$)"))] | length) == 0
' "$run_dir/evidence.json" >/dev/null

cp "$run_dir/summary.json" "$result_root/summary.valid.json"
yq -i '.junit.tests = 2' "$run_dir/summary.json"
if scripts/test/validate-run.sh "$run_dir" >/dev/null 2>&1; then
	echo 'Run validation must reject summary/JUnit count disagreement.' >&2
	exit 1
fi
cp "$result_root/summary.valid.json" "$run_dir/summary.json"

yq -i '.result = "broken" | .suites[0].result = "broken"' "$run_dir/summary.json"
if scripts/test/validate-run.sh "$run_dir" >/dev/null 2>&1; then
	echo 'Run validation must reject a broken result without a JUnit error.' >&2
	exit 1
fi
cp "$result_root/summary.valid.json" "$run_dir/summary.json"

exact_entry_json="$(yq -o=json -I=0 \
	'.suites[] | select(.metadata.id == "test.e2e.qbit-manage-policy")' \
	tests/catalog.yaml)"
secret_environment_dir="$result_root/secret-environment"
mkdir "$secret_environment_dir"
export CLUSTER_E2E_CONFIRM='must-not-appear-in-test-artifacts'
write_environment "$secret_environment_dir" secret-environment "$exact_entry_json" agent \
	"$started_at" "$finished_at" media "$result_root/no-kubeconfig" CLUSTER_E2E_CONFIRM
yq -e '.confirmation_variable == "CLUSTER_E2E_CONFIRM"' \
	"$secret_environment_dir/environment.json" >/dev/null
if rg -q 'must-not-appear-in-test-artifacts' "$secret_environment_dir"; then
	echo 'Confirmation values must never be written to test artifacts.' >&2
	exit 1
fi
unset CLUSTER_E2E_CONFIRM

[[ "$(read_junit_counts "$run_dir/junit.xml")" == '6 0 0 1 5' ]]
[[ "$(classify_run_result 0 valid passed passed)" == 'passed' ]]
[[ "$(classify_run_result 1 failures passed passed)" == 'failed' ]]
[[ "$(classify_run_result 1 errors passed passed)" == 'broken' ]]
[[ "$(classify_run_result 1 valid passed passed)" == 'broken' ]]
[[ "$(classify_run_result 0 valid failed passed)" == 'broken' ]]
[[ "$(classify_run_result 0 valid passed failed)" == 'broken' ]]
[[ "$(result_exit_code 7 failed)" -eq 7 ]]
[[ "$(result_exit_code 0 passed)" -eq 0 ]]
[[ "$(result_exit_code 0 broken)" -eq 1 ]]

lifecycle_junit="$result_root/lifecycle.xml"
write_single_case_junit "$lifecycle_junit" cluster primary passed 1
# Offline cleanup-failure regression: the primary assertion remains passed while
# cleanup/recovery/finalization are separately represented as harness errors.
append_lifecycle_junit "$lifecycle_junit" chainsaw.e2e.fixture \
	not-applicable failed failed passed broken
[[ "$(read_junit_counts "$lifecycle_junit")" == '6 0 3 1 2' ]]
yq --input-format xml --output-format json '.' "$lifecycle_junit" |
	yq -e '
    .testsuites."+@tests" == "6" and
    .testsuites."+@errors" == "3" and
    .testsuites."+@skipped" == "1" and
    ([.. | select((type == "!!map") and
      .["+@classname"] == "chainsaw.e2e.fixture.lifecycle")] | length) == 5 and
    ([.. | select((type == "!!map") and .["+@name"] == "primary" and
      .failure == null and .error == null)] | length) == 1
  ' - >/dev/null

attribute_free_junit="$result_root/attribute-free.xml"
printf '%s\n' \
	'<testsuites><testsuite>' \
	'<testcase name="failed"><failure message="assertion"/></testcase>' \
	'<testcase name="broken"><error message="harness"/></testcase>' \
	'<testcase name="skipped"><skipped/></testcase>' \
	'</testsuite></testsuites>' >"$attribute_free_junit"
[[ "$(read_junit_counts "$attribute_free_junit")" == '3 1 1 1 0' ]]

zero_junit="$result_root/zero.xml"
printf '%s\n' '<testsuites tests="0" failures="0" errors="0" skipped="0"/>' >"$zero_junit"
if read_junit_counts "$zero_junit" >/dev/null 2>&1; then
	echo 'A zero-test JUnit document must be rejected.' >&2
	exit 1
fi

ln -s ../junit.xml "$run_dir/diagnostics/unsafe-link"
if write_evidence_index "$run_dir" "$run_id" >/dev/null 2>&1; then
	echo 'Evidence indexing must reject symlinks.' >&2
	exit 1
fi
rm "$run_dir/diagnostics/unsafe-link"

printf 'oversized-fixture' >"$run_dir/diagnostics/oversized"
write_evidence_index "$run_dir" "$run_id"
if TEST_RESULT_MAX_FILE_BYTES=8 \
	scripts/test/validate-run.sh "$run_dir" >/dev/null 2>&1; then
	echo 'Run validation must reject oversized evidence files.' >&2
	exit 1
fi
rm "$run_dir/diagnostics/oversized"
write_evidence_index "$run_dir" "$run_id"

TEST_EXECUTION_ORIGIN=unknown
export TEST_EXECUTION_ORIGIN
if resolve_execution_origin >/dev/null 2>&1; then
	echo 'Unknown execution origins must be rejected.' >&2
	exit 1
fi

echo 'Canonical result contract tests passed.'
