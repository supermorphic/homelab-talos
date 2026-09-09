#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

workflow=.github/workflows/ci.yml
checkout_action='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
mise_action='jdx/mise-action@dad1bfd3df957f44999b559dd69dc1671cb4e9ea'
mise_version='2026.9.2'
upload_action='actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
download_action='actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/ci-workflow-contract-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin" "$fixture_root/runner-temp"

# shellcheck disable=SC2016 # The generated stub expands these values when it runs.
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'printf "call\0" >>"${PLANNER_ARGV_LOG:?}"' \
	'printf "%s\0" "$@" >>"${PLANNER_ARGV_LOG:?}"' \
	>"$fixture_root/bin/mise"
chmod +x "$fixture_root/bin/mise"

assert_planner_argv() {
	local candidate_workflow="$1" event_name="$2" recipe="$3"
	shift 3
	local condition command rendered token index
	local -a actual expected=(call "$@")
	condition="github.event_name == '$event_name'"
	[[ "$(EVENT_CONDITION="$condition" RECIPE="$recipe" mise exec -- yq -r \
		'.jobs.plan.steps | map(select(.if == strenv(EVENT_CONDITION) and (.run | contains(strenv(RECIPE))))) | length' \
		"$candidate_workflow")" -eq 1 ]] || return 1
	command="$(EVENT_CONDITION="$condition" RECIPE="$recipe" mise exec -- yq -r \
		'.jobs.plan.steps | map(select(.if == strenv(EVENT_CONDITION) and (.run | contains(strenv(RECIPE))))) | .[0].run' \
		"$candidate_workflow")"
	rendered="$command"
	# shellcheck disable=SC2016 # Literal GitHub expression replaced for execution.
	token='${{ github.event.pull_request.base.sha }}'
	rendered="${rendered//$token/1111111111111111111111111111111111111111}"
	# shellcheck disable=SC2016 # Literal GitHub expression replaced for execution.
	token='${{ github.event.pull_request.head.sha }}'
	rendered="${rendered//$token/2222222222222222222222222222222222222222}"
	# shellcheck disable=SC2016 # Literal GitHub expression replaced for execution.
	token='${{ github.sha }}'
	rendered="${rendered//$token/3333333333333333333333333333333333333333}"
	# shellcheck disable=SC2016 # Literal runner expression replaced for execution.
	token='$RUNNER_TEMP'
	rendered="${rendered//$token/$fixture_root\/runner-temp}"
	: >"$fixture_root/argv"
	PATH="$fixture_root/bin:$PATH" PLANNER_ARGV_LOG="$fixture_root/argv" \
		bash -euo pipefail -c "$rendered" || return 1
	mapfile -d '' -t actual <"$fixture_root/argv"
	[[ "${#actual[@]}" -eq "${#expected[@]}" ]] || return 1
	for index in "${!expected[@]}"; do
		[[ "${actual[$index]}" == "${expected[$index]}" ]] || return 1
	done
}

# The required workflow always starts; selected groups replace the duplicate full job.
mise exec -- yq -e '((.on.pull_request.branches | length) == 1) and
  .on.pull_request.branches[0] == "main" and
  (.on.pull_request | has("paths") | not) and
  (.on.pull_request | has("paths-ignore") | not) and
  (.jobs.ci == null) and (.jobs.plan != null) and
  (.jobs.groups != null) and (.jobs."merge-gate" != null)' "$workflow" >/dev/null

mise exec -- yq -e '
  (.on | has("pull_request_target") | not) and
  (.on | has("workflow_dispatch")) and
  .on.workflow_dispatch == null and
  .permissions.contents == "read" and
  (.permissions | length) == 1
' "$workflow" >/dev/null

# These GitHub expressions are literal workflow values, not shell expansions.
# shellcheck disable=SC2016
CHECKOUT_ACTION="$checkout_action" MISE_ACTION="$mise_action" MISE_VERSION="$mise_version" \
	mise exec -- yq -e '
  (.jobs.plan.steps | map(select(.uses == strenv(CHECKOUT_ACTION))) | length) == 1 and
  (.jobs.plan.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with.ref) ==
    "${{ github.event_name == '\''pull_request'\'' && github.event.pull_request.head.sha || github.sha }}" and
  (.jobs.plan.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with."fetch-depth") == 0 and
  (.jobs.plan.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with."persist-credentials") == false and
  (.jobs.plan.steps | map(select(.uses == strenv(MISE_ACTION))) | length) == 1 and
  (.jobs.plan.steps | map(select(
    .uses == strenv(MISE_ACTION) and .with.version == strenv(MISE_VERSION)
  )) | length) == 1 and
  (.jobs.groups.steps | map(select(
    .uses == strenv(MISE_ACTION) and .with.version == strenv(MISE_VERSION)
  )) | length) == 1 and
  (.jobs."merge-gate".steps | map(select(
    .uses == strenv(MISE_ACTION) and .with.version == strenv(MISE_VERSION)
  )) | length) == 1
' "$workflow" >/dev/null

# The planner commands are executed with synthetic event values so argument order is
# validated at the command boundary rather than inferred from independent text matches.
assert_planner_argv "$workflow" pull_request 'mise exec -- just test ci-plan' \
	exec -- just test ci-plan \
	1111111111111111111111111111111111111111 \
	2222222222222222222222222222222222222222 \
	"$fixture_root/runner-temp/ci-plan.json"
assert_planner_argv "$workflow" workflow_dispatch 'mise exec -- just test ci-plan-full' \
	exec -- just test ci-plan-full \
	3333333333333333333333333333333333333333 \
	3333333333333333333333333333333333333333 \
	"$fixture_root/runner-temp/ci-plan.json"

swapped_workflow="$fixture_root/swapped-ci.yml"
cp "$workflow" "$swapped_workflow"
# shellcheck disable=SC2016 # These are literal mutation-fixture workflow expressions.
mise exec -- yq -i '
  (.jobs.plan.steps[] | select(
    .if == "github.event_name == '\''pull_request'\''" and
    (.run | contains("mise exec -- just test ci-plan"))
  ).run) = "mise exec -- just test ci-plan \\\n    \"${{ github.event.pull_request.head.sha }}\" \\\n    \"${{ github.event.pull_request.base.sha }}\" \\\n    \"$RUNNER_TEMP/ci-plan.json\"" |
  (.jobs.plan.steps[] | select(
    .if == "github.event_name == '\''workflow_dispatch'\''" and
    (.run | contains("mise exec -- just test ci-plan-full"))
  ).run) = "mise exec -- just test ci-plan-full \\\n    \"${{ github.sha }}\" \\\n    \"$RUNNER_TEMP/ci-plan.json\" \\\n    \"${{ github.sha }}\""
' "$swapped_workflow"
# Each mutation must execute exactly the intended permutation, with no extra arguments.
assert_planner_argv "$swapped_workflow" pull_request \
	'mise exec -- just test ci-plan' exec -- just test ci-plan \
	2222222222222222222222222222222222222222 \
	1111111111111111111111111111111111111111 \
	"$fixture_root/runner-temp/ci-plan.json"
assert_planner_argv "$swapped_workflow" workflow_dispatch \
	'mise exec -- just test ci-plan-full' exec -- just test ci-plan-full \
	3333333333333333333333333333333333333333 \
	"$fixture_root/runner-temp/ci-plan.json" \
	3333333333333333333333333333333333333333
if assert_planner_argv "$swapped_workflow" pull_request \
	'mise exec -- just test ci-plan' exec -- just test ci-plan \
	1111111111111111111111111111111111111111 \
	2222222222222222222222222222222222222222 \
	"$fixture_root/runner-temp/ci-plan.json"; then
	echo 'The workflow contract accepted reversed pull-request planner SHAs.' >&2
	exit 1
fi
if assert_planner_argv "$swapped_workflow" workflow_dispatch \
	'mise exec -- just test ci-plan-full' exec -- just test ci-plan-full \
	3333333333333333333333333333333333333333 \
	3333333333333333333333333333333333333333 \
	"$fixture_root/runner-temp/ci-plan.json"; then
	echo 'The workflow contract accepted reordered manual planner arguments.' >&2
	exit 1
fi

# shellcheck disable=SC2016
UPLOAD_ACTION="$upload_action" mise exec -- yq -e '
  (.jobs.plan.steps | map(select(
    .uses == strenv(UPLOAD_ACTION) and
    .if == "always()" and
    .with.name == "ci-plan-${{ github.run_id }}-${{ github.run_attempt }}" and
    .with.path == "${{ runner.temp }}/ci-plan.json" and
    .with."if-no-files-found" == "warn"
  )) | length) == 1
' "$workflow" >/dev/null

# Execute the exported matrix boundary with real plans. A hard-coded full/core
# output or a swallowed malformed-plan failure must not pass this contract.
selection_script="$(mise exec -- yq -r '.jobs.plan.steps[] |
  select(.id == "selection") | .run' "$workflow")"
candidate="$(git rev-parse HEAD)"
for mode in selective full; do
	plan_args=()
	expected_groups='groups=["core"]'
	if [[ "$mode" == full ]]; then
		plan_args=(--full)
		expected_groups='groups=["core","observability","automation","ci-framework"]'
	fi
	mise exec -- uv run --locked python scripts/test/ci_plan.py plan \
		--base "$candidate" --head "$candidate" --impact tests/impact.yaml \
		--catalog tests/catalog.yaml --output "$fixture_root/runner-temp/ci-plan.json" \
		"${plan_args[@]}"
	: >"$fixture_root/output"
	RUNNER_TEMP="$fixture_root/runner-temp" GITHUB_OUTPUT="$fixture_root/output" \
		bash -euo pipefail -c "$selection_script"
	[[ "$(<"$fixture_root/output")" == "$expected_groups" ]] || {
		echo "The workflow did not export the $mode plan groups." >&2
		exit 1
	}
done
printf '{}\n' >"$fixture_root/runner-temp/ci-plan.json"
: >"$fixture_root/output"
if RUNNER_TEMP="$fixture_root/runner-temp" GITHUB_OUTPUT="$fixture_root/output" \
	bash -euo pipefail -c "$selection_script" >/dev/null 2>&1; then
	echo 'The workflow accepted a malformed matrix plan.' >&2
	exit 1
fi
[[ ! -s "$fixture_root/output" ]]

# Selected execution is bounded. Every matrix child consumes the
# same immutable plan and candidate and retains its own diagnostic trees.
# shellcheck disable=SC2016
CHECKOUT_ACTION="$checkout_action" MISE_ACTION="$mise_action" \
DOWNLOAD_ACTION="$download_action" UPLOAD_ACTION="$upload_action" \
	mise exec -- yq -e '
  .jobs.groups.needs == "plan" and
  .jobs.groups.strategy."fail-fast" == false and
  .jobs.groups.strategy."max-parallel" == 4 and
  .jobs.groups.strategy.matrix.group == "${{ fromJSON(needs.plan.outputs.groups) }}" and
  .jobs.plan.outputs.groups == "${{ steps.selection.outputs.groups }}" and
  (.jobs.groups.steps | map(select(.uses == strenv(CHECKOUT_ACTION))) | length) == 1 and
  (.jobs.groups.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with.ref) ==
    "${{ github.event_name == '\''pull_request'\'' && github.event.pull_request.head.sha || github.sha }}" and
  (.jobs.groups.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with."fetch-depth") == 0 and
  (.jobs.groups.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with."persist-credentials") == false and
  (.jobs.groups.steps | map(select(.uses == strenv(MISE_ACTION))) | length) == 1 and
  (.jobs.groups.steps | map(select(
    .uses == strenv(DOWNLOAD_ACTION) and
    .with.name == "ci-plan-${{ github.run_id }}-${{ github.run_attempt }}" and
    .with.path == "${{ runner.temp }}/ci-plan"
  )) | length) == 1 and
  (.jobs.groups.steps | map(select(
    (.run | contains("mise exec -- just test ci-group")) and
    (.run | contains("${{ matrix.group }}")) and
    (.run | contains("$RUNNER_TEMP/ci-plan/ci-plan.json"))
  )) | length) == 1 and
  (.jobs.groups.steps | map(select(
    .uses == strenv(UPLOAD_ACTION) and
    .if == "always()" and
    .with.name == "ci-group-${{ matrix.group }}-${{ github.run_id }}-${{ github.run_attempt }}" and
    .with.path == ".test-results/" and
    .with."if-no-files-found" == "error"
  )) | length) == 1 and
  (.jobs.groups.steps | map(select(
    .uses == strenv(UPLOAD_ACTION) and
    .if == "always() && steps.allure_report.outcome == '\''success'\''" and
    .with.name == "allure-group-report-${{ matrix.group }}-${{ github.run_id }}-${{ github.run_attempt }}" and
    .with.path == ".test-reports/"
  )) | length) == 1
' "$workflow" >/dev/null

# Reconciliation sees only the four separately downloaded result artifacts.
# The final step combines its outcome with provider plan/matrix conclusions, so
# stale passing artifacts cannot mask a failed, cancelled, or skipped job.
# shellcheck disable=SC2016
CHECKOUT_ACTION="$checkout_action" MISE_ACTION="$mise_action" \
DOWNLOAD_ACTION="$download_action" mise exec -- yq -e '
  (.jobs."merge-gate".needs | join(" ")) == "plan groups" and
  .jobs."merge-gate".if == "always()" and
  (.jobs."merge-gate".steps | map(select(.uses == strenv(CHECKOUT_ACTION))) | length) == 1 and
  (.jobs."merge-gate".steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with.ref) ==
    "${{ github.event_name == '\''pull_request'\'' && github.event.pull_request.head.sha || github.sha }}" and
  (.jobs."merge-gate".steps | map(select(.uses == strenv(MISE_ACTION))) | length) == 1 and
  (.jobs."merge-gate".steps | map(select(
    .uses == strenv(DOWNLOAD_ACTION) and
    .with.name == "ci-plan-${{ github.run_id }}-${{ github.run_attempt }}" and
    .with.path == "${{ runner.temp }}/merge-gate-plan"
  )) | length) == 1 and
  (.jobs."merge-gate".steps | map(select(
    .uses == strenv(DOWNLOAD_ACTION) and
    .with.pattern == "ci-group-?*-${{ github.run_id }}-${{ github.run_attempt }}" and
    .with.path == "${{ runner.temp }}/ci-results" and
    .with."merge-multiple" == false
  )) | length) == 1 and
  (.jobs."merge-gate".steps | map(select(
    .id == "reconcile" and .if == "always()" and ."continue-on-error" == true and
    (.run | contains("mise exec -- just test ci-reconcile")) and
    (.run | contains("$RUNNER_TEMP/merge-gate-plan/ci-plan.json")) and
    (.run | contains("$RUNNER_TEMP/ci-results")) and
    (.run | contains("$RUNNER_TEMP/merge-gate-output"))
  )) | length) == 1 and
  (.jobs."merge-gate".steps | map(select(
    .name == "Enforce provider and reconciliation results" and .if == "always()" and
    .env.PLAN_RESULT == "${{ needs.plan.result }}" and
    .env.GROUP_RESULT == "${{ needs.groups.result }}" and
    .env.RECONCILE_OUTCOME == "${{ steps.reconcile.outcome }}"
  )) | length) == 1
' "$workflow" >/dev/null

enforce_script="$(mise exec -- yq -r '.jobs."merge-gate".steps[] |
  select(.name == "Enforce provider and reconciliation results") | .run' "$workflow")"
PLAN_RESULT=success GROUP_RESULT=success RECONCILE_OUTCOME=success \
	bash -euo pipefail -c "$enforce_script"
for failed_input in plan group reconcile; do
	plan_result=success group_result=success reconcile_outcome=success
	case "$failed_input" in
		plan) plan_result=failure ;;
		group) group_result=cancelled ;;
		reconcile) reconcile_outcome=failure ;;
	esac
	if PLAN_RESULT="$plan_result" GROUP_RESULT="$group_result" \
		RECONCILE_OUTCOME="$reconcile_outcome" \
		bash -euo pipefail -c "$enforce_script" >/dev/null 2>&1; then
		echo "The merge gate accepted a failed $failed_input result." >&2
		exit 1
	fi
done

if rg -q '\$\{\{[[:space:]]*secrets\.' "$workflow"; then
	echo 'The CI workflow must not pass secrets to validation jobs.' >&2
	exit 1
fi

echo 'CI workflow contract tests passed.'
