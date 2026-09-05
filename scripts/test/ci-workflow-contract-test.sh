#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

workflow=.github/workflows/ci.yml
checkout_action='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
mise_action='jdx/mise-action@dad1bfd3df957f44999b559dd69dc1671cb4e9ea'
upload_action='actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
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
		'.jobs.plan-shadow.steps | map(select(.if == strenv(EVENT_CONDITION) and (.run | contains(strenv(RECIPE))))) | length' \
		"$candidate_workflow")" -eq 1 ]] || return 1
	command="$(EVENT_CONDITION="$condition" RECIPE="$recipe" mise exec -- yq -r \
		'.jobs.plan-shadow.steps | map(select(.if == strenv(EVENT_CONDITION) and (.run | contains(strenv(RECIPE))))) | .[0].run' \
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

# A missing shadow job is the initial RED. The authoritative full CI job and its
# unfiltered pull-request trigger must remain present throughout the rollout.
mise exec -- yq -e '((.on.pull_request.branches | length) == 1) and
  .on.pull_request.branches[0] == "main" and
  (.on.pull_request | has("paths") | not) and
  (.on.pull_request | has("paths-ignore") | not) and
  (.jobs.ci != null) and (.jobs.plan-shadow != null)' "$workflow" >/dev/null

mise exec -- yq -e '
  (.on | has("pull_request_target") | not) and
  (.on | has("workflow_dispatch")) and
  .on.workflow_dispatch == null and
  .permissions.contents == "read" and
  (.permissions | length) == 1 and
  (.jobs.ci.steps | map(select(.run == "mise exec -- just ci")) | length) == 1
' "$workflow" >/dev/null

# These GitHub expressions are literal workflow values, not shell expansions.
# shellcheck disable=SC2016
CHECKOUT_ACTION="$checkout_action" MISE_ACTION="$mise_action" \
	mise exec -- yq -e '
  (.jobs.plan-shadow.steps | map(select(.uses == strenv(CHECKOUT_ACTION))) | length) == 1 and
  (.jobs.plan-shadow.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with.ref) ==
    "${{ github.event_name == '\''pull_request'\'' && github.event.pull_request.head.sha || github.sha }}" and
  (.jobs.plan-shadow.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with."fetch-depth") == 0 and
  (.jobs.plan-shadow.steps[] | select(.uses == strenv(CHECKOUT_ACTION)) | .with."persist-credentials") == false and
  (.jobs.plan-shadow.steps | map(select(.uses == strenv(MISE_ACTION))) | length) == 1
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
  (.jobs.plan-shadow.steps[] | select(
    .if == "github.event_name == '\''pull_request'\''" and
    (.run | contains("mise exec -- just test ci-plan"))
  ).run) = "mise exec -- just test ci-plan \\\n+    \"${{ github.event.pull_request.head.sha }}\" \\\n+    \"${{ github.event.pull_request.base.sha }}\" \\\n+    \"$RUNNER_TEMP/ci-plan.json\"" |
  (.jobs.plan-shadow.steps[] | select(
    .if == "github.event_name == '\''workflow_dispatch'\''" and
    (.run | contains("mise exec -- just test ci-plan-full"))
  ).run) = "mise exec -- just test ci-plan-full \\\n+    \"${{ github.sha }}\" \\\n+    \"$RUNNER_TEMP/ci-plan.json\" \\\n+    \"${{ github.sha }}\""
' "$swapped_workflow"
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
  (.jobs.plan-shadow.steps | map(select(
    .uses == strenv(UPLOAD_ACTION) and
    .if == "always()" and
    .with.name == "ci-plan-shadow-${{ github.run_id }}-${{ github.run_attempt }}" and
    .with.path == "${{ runner.temp }}/ci-plan.json" and
    .with."if-no-files-found" == "warn"
  )) | length) == 1
' "$workflow" >/dev/null

if rg -q '\$\{\{[[:space:]]*secrets\.' "$workflow"; then
	echo 'The CI workflow must not pass secrets to shadow planning.' >&2
	exit 1
fi

echo 'CI workflow contract tests passed.'
