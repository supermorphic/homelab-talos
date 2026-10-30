#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

workflow=.forgejo/workflows/ci.yml
runner_label='homelab-podman-amd64'
upload_action='https://code.forgejo.org/forgejo/upload-artifact@97a0fba1372883ab732affbe8f94b823f91727db'
download_action='https://code.forgejo.org/forgejo/download-artifact@246d7188e736d3686f6d19628d253ede9697bd55'
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/ci-workflow-contract-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin"

# shellcheck disable=SC2016 # The generated stub expands these values when it runs.
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'printf "call\0" >>"${PLANNER_ARGV_LOG:?}"' \
	'printf "%s\0" "$@" >>"${PLANNER_ARGV_LOG:?}"' \
	>"$fixture_root/bin/mise"
chmod +x "$fixture_root/bin/mise"

assert_planner_argv() {
	local candidate_workflow="$1" sha="$2"
	shift 2
	local command index
	local -a actual expected=(call "$@")
	[[ "$(mise exec -- yq -r '.jobs.plan.steps |
		map(select(.run | contains("just test ci-plan"))) | length' \
		"$candidate_workflow")" -eq 1 ]] || return 1
	command="$(mise exec -- yq -r '.jobs.plan.steps |
		map(select(.run | contains("just test ci-plan"))) | .[0].run' "$candidate_workflow")"
	: >"$fixture_root/argv"
	(
		cd "$fixture_root"
		CANDIDATE_SHA="$sha" PATH="$fixture_root/bin:$PATH" \
			PLANNER_ARGV_LOG="$fixture_root/argv" bash -euo pipefail -c "$command"
	) || return 1
	mapfile -d '' -t actual <"$fixture_root/argv"
	[[ "${#actual[@]}" -eq "${#expected[@]}" ]] || return 1
	for index in "${!expected[@]}"; do
		[[ "${actual[$index]}" == "${expected[$index]}" ]] || return 1
	done
}

# Pull requests use the local merge check: no hosted run may start for a pull
# request or a branch push. Manual dispatch and the nightly schedule remain.
mise exec -- yq -e '
  ((.on | keys | sort | join(",")) == "schedule,workflow_dispatch") and
  .on.workflow_dispatch == null and
  (.on.schedule | length) == 1 and
  .permissions.contents == "read" and
  (.permissions | length) == 1
' "$workflow" >/dev/null

# Every job runs on the shared pool, and every action is pinned to a commit.
RUNNER_LABEL="$runner_label" mise exec -- yq -e '
  (.jobs | keys | sort | join(",")) == "ci,groups,plan" and
  ([.jobs[] | select(."runs-on" != strenv(RUNNER_LABEL))] | length) == 0 and
  ([.jobs[].steps[] | select(has("uses")) |
    select(.uses | test("^https://[^@]+@[0-9a-f]{40}$") | not)] | length) == 0
' "$workflow" >/dev/null

# Every job checks out the exact event commit with full history and no stored token.
# shellcheck disable=SC2016 # Literal workflow expression.
mise exec -- yq -e '
  ([.jobs[] | .steps | map(select(.uses // "" | test("/actions/checkout@"))) |
    select(length == 1 and .[0].with.ref == "${{ forgejo.sha }}" and
      .[0].with."fetch-depth" == 0 and .[0].with."persist-credentials" == false)
  ] | length) == 3
' "$workflow" >/dev/null

# Manual and nightly runs use separate concurrency groups, so neither cancels the other.
# shellcheck disable=SC2016 # Literal workflow expression.
mise exec -- yq -e '
  (.concurrency.group | contains("${{ forgejo.event_name }}")) and
  (.concurrency.group | contains("${{ forgejo.ref }}"))
' "$workflow" >/dev/null

# Each job installs locked tools once, without the job token: GitHub rejects it for
# anonymous attestation checks, and validation never needs it.
mise exec -- yq -e '
  ([.jobs[] | .steps | map(select(.run // "" | contains("mise install"))) |
    select(length == 1 and (.[0].run | contains("mise install --locked")) and
      (.[0].run | contains("-u GITHUB_TOKEN")) and (.[0].run | contains("-u GH_TOKEN")) and
      (.[0].run | contains("-u GITHUB_API_TOKEN")) and
      (.[0].run | contains("-u MISE_GITHUB_TOKEN")) and (.[0].run | contains("-u FORGEJO_TOKEN")))
  ] | length) == 3
' "$workflow" >/dev/null

# The planner command is executed with a synthetic commit so argument order is
# validated at the command boundary rather than inferred from text matches.
sha=3333333333333333333333333333333333333333
assert_planner_argv "$workflow" "$sha" \
	exec -- just test ci-plan-full "$sha" "$sha" .tmp/ci/plan/ci-plan.json

swapped_workflow="$fixture_root/swapped-ci.yml"
cp "$workflow" "$swapped_workflow"
# shellcheck disable=SC2016 # Literal mutation-fixture command.
mise exec -- yq -i '
  (.jobs.plan.steps[] | select(.run | contains("just test ci-plan")).run) =
    "mkdir -p .tmp/ci/plan\nmise exec -- just test ci-plan \"$CANDIDATE_SHA\" \"$CANDIDATE_SHA\" .tmp/ci/plan/ci-plan.json\n"
' "$swapped_workflow"
if assert_planner_argv "$swapped_workflow" "$sha" \
	exec -- just test ci-plan-full "$sha" "$sha" .tmp/ci/plan/ci-plan.json; then
	echo 'The workflow contract accepted an affected-only plan.' >&2
	exit 1
fi

# shellcheck disable=SC2016
UPLOAD_ACTION="$upload_action" mise exec -- yq -e '
  (.jobs.plan.steps | map(select(
    .uses == strenv(UPLOAD_ACTION) and
    .with.name == "ci-plan-${{ forgejo.run_id }}-${{ forgejo.run_attempt }}" and
    .with.path == ".tmp/ci/plan/" and
    .with."if-no-files-found" == "error"
  )) | length) == 1
' "$workflow" >/dev/null

# Execute the exported matrix boundary with real plans. A hard-coded full/core
# output or a swallowed malformed-plan failure must not pass this contract.
selection_script="$(mise exec -- yq -r '.jobs.plan.steps[] |
  select(.id == "selection") | .run' "$workflow")"
selection_script="${selection_script//.tmp\/ci\/plan\/ci-plan.json/$fixture_root\/ci-plan.json}"
candidate="$(git rev-parse HEAD)"
full_groups="$(mise exec -- yq -o=json -I=0 '.full_groups' tests/impact.yaml)"
for mode in selective full; do
	plan_args=()
	expected_groups='groups=["core"]'
	if [[ "$mode" == full ]]; then
		plan_args=(--full)
		expected_groups="groups=$full_groups"
	fi
	mise exec -- uv run --locked python scripts/test/ci_plan.py plan \
		--base "$candidate" --head "$candidate" --impact tests/impact.yaml \
		--catalog tests/catalog.yaml --output "$fixture_root/ci-plan.json" \
		"${plan_args[@]}"
	: >"$fixture_root/output"
	GITHUB_OUTPUT="$fixture_root/output" bash -euo pipefail -c "$selection_script"
	[[ "$(<"$fixture_root/output")" == "$expected_groups" ]] || {
		echo "The workflow did not export the $mode plan groups." >&2
		exit 1
	}
done
printf '{}\n' >"$fixture_root/ci-plan.json"
: >"$fixture_root/output"
if GITHUB_OUTPUT="$fixture_root/output" \
	bash -euo pipefail -c "$selection_script" >/dev/null 2>&1; then
	echo 'The workflow accepted a malformed matrix plan.' >&2
	exit 1
fi
[[ ! -s "$fixture_root/output" ]]

# Every matrix child consumes the same immutable plan and candidate and retains
# its own diagnostic trees.
# shellcheck disable=SC2016
DOWNLOAD_ACTION="$download_action" UPLOAD_ACTION="$upload_action" mise exec -- yq -e '
  .jobs.groups.needs == "plan" and
  .jobs.groups.strategy."fail-fast" == false and
  .jobs.groups.strategy.matrix.group == "${{ fromJSON(needs.plan.outputs.groups) }}" and
  .jobs.plan.outputs.groups == "${{ steps.selection.outputs.groups }}" and
  (.jobs.groups.steps | map(select(
    .uses == strenv(DOWNLOAD_ACTION) and
    .with.name == "ci-plan-${{ forgejo.run_id }}-${{ forgejo.run_attempt }}" and
    .with.path == ".tmp/ci/plan/"
  )) | length) == 1 and
  (.jobs.groups.steps | map(select(
    .env.CI_GROUP == "${{ matrix.group }}" and
    .run == "mise exec -- just test ci-group \"$CI_GROUP\" .tmp/ci/plan/ci-plan.json"
  )) | length) == 1 and
  (.jobs.groups.steps | map(select(
    .uses == strenv(UPLOAD_ACTION) and
    .if == "always()" and
    .with.name == "ci-group-${{ matrix.group }}-${{ forgejo.run_id }}-${{ forgejo.run_attempt }}" and
    .with.path == ".test-results/" and
    .with."if-no-files-found" == "error"
  )) | length) == 1
' "$workflow" >/dev/null

# The gate downloads each impact-map group by its exact current-attempt name, so a
# group added to the map cannot be silently omitted from reconciliation.
mapfile -t impact_groups < <(mise exec -- yq -r '.full_groups[]' tests/impact.yaml)
mapfile -t gate_groups < <(DOWNLOAD_ACTION="$download_action" mise exec -- yq -r '
  .jobs.ci.steps[] | select(.uses == strenv(DOWNLOAD_ACTION)) | .with.name |
  select(test("^ci-group-")) | sub("^ci-group-"; "") |
  sub("-[$][{][{] forgejo[.]run_id [}][}]-[$][{][{] forgejo[.]run_attempt [}][}]$"; "")
' "$workflow")
[[ "${gate_groups[*]}" == "${impact_groups[*]}" ]] || {
	echo "The gate downloads groups '${gate_groups[*]}', not '${impact_groups[*]}'." >&2
	exit 1
}
for group in "${impact_groups[@]}"; do
	# shellcheck disable=SC2016
	GROUP="$group" DOWNLOAD_ACTION="$download_action" mise exec -- yq -e '
    (.jobs.ci.steps | map(select(
      .uses == strenv(DOWNLOAD_ACTION) and
      .if == "always() && contains(fromJSON(needs.plan.outputs.groups || '\''[]'\''), '\''" + strenv(GROUP) + "'\'')" and
      .with.name == "ci-group-" + strenv(GROUP) + "-${{ forgejo.run_id }}-${{ forgejo.run_attempt }}" and
      .with.path == ".tmp/ci/results/" + strenv(GROUP) + "/"
    )) | length) == 1
  ' "$workflow" >/dev/null
done

# shellcheck disable=SC2016
DOWNLOAD_ACTION="$download_action" mise exec -- yq -e '
  (.jobs.ci.steps | map(select(
    .uses == strenv(DOWNLOAD_ACTION) and
    .with.name == "ci-plan-${{ forgejo.run_id }}-${{ forgejo.run_attempt }}" and
    .with.path == ".tmp/ci/plan/"
  )) | length) == 1
' "$workflow" >/dev/null

# Reconciliation combines its outcome with provider plan/matrix conclusions, so
# stale passing artifacts cannot mask a failed, cancelled, or skipped job.
# shellcheck disable=SC2016
mise exec -- yq -e '
  (.jobs.ci.needs | join(" ")) == "plan groups" and
  .jobs.ci.if == "always()" and
  (.jobs.ci.steps | map(select(
    .id == "reconcile" and .if == "always()" and ."continue-on-error" == true and
    (.run | contains("mise exec -- just test ci-reconcile")) and
    (.run | contains(".tmp/ci/plan/ci-plan.json")) and
    (.run | contains(".tmp/ci/results")) and
    (.run | contains(".tmp/ci/gate"))
  )) | length) == 1 and
  (.jobs.ci.steps | map(select(
    .name == "Enforce provider and reconciliation results" and .if == "always()" and
    .env.PLAN_RESULT == "${{ needs.plan.result }}" and
    .env.GROUP_RESULT == "${{ needs.groups.result }}" and
    .env.RECONCILE_OUTCOME == "${{ steps.reconcile.outcome }}"
  )) | length) == 1
' "$workflow" >/dev/null

enforce_script="$(mise exec -- yq -r '.jobs.ci.steps[] |
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
		echo "The CI gate accepted a failed $failed_input result." >&2
		exit 1
	fi
done

if rg -q '\$\{\{[^}]*\b(secrets\.|(forgejo|github)\.token\b)' "$workflow"; then
	echo 'The CI workflow must not pass secrets or the job token to validation jobs.' >&2
	exit 1
fi

echo 'CI workflow contract tests passed.'
