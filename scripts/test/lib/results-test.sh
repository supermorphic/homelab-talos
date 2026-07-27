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
  '.suites[] | select(.metadata.id == "chainsaw.e2e.qbit-manage-policy")' \
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
append_lifecycle_junit "$lifecycle_junit" chainsaw.e2e.fixture \
  not-applicable failed failed passed broken
[[ "$(read_junit_counts "$lifecycle_junit")" == '6 0 3 1 2' ]]
yq --input-format xml --output-format json '.' "$lifecycle_junit" |
  yq -e '
    .testsuites."+@tests" == "6" and
    .testsuites."+@errors" == "3" and
    .testsuites."+@skipped" == "1" and
    ([.. | select((type == "!!map") and
      .["+@classname"] == "chainsaw.e2e.fixture.lifecycle")] | length) == 5
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
