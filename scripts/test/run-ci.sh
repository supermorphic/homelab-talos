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
execution='ci'
group=''
plan=''
grouped=false
execution_set=false
group_set=false
plan_set=false
execution_id_lines=''
plan_id=''
base_sha=''
head_sha=''

usage() {
	echo 'Usage: run-ci.sh [--execution NAME --group GROUP --plan FILE]' >&2
}

if [[ "$#" -gt 0 ]]; then
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		--execution)
			[[ "$execution_set" == false && "$#" -ge 2 && -n "$2" ]] || {
				usage
				exit 2
			}
			execution="$2"
			execution_set=true
			shift 2
			;;
		--group)
			[[ "$group_set" == false && "$#" -ge 2 && -n "$2" ]] || {
				usage
				exit 2
			}
			group="$2"
			group_set=true
			shift 2
			;;
		--plan)
			[[ "$plan_set" == false && "$#" -ge 2 && -n "$2" ]] || {
				usage
				exit 2
			}
			plan="$2"
			plan_set=true
			shift 2
			;;
		*)
			usage
			exit 2
			;;
		esac
	done
	[[ "$execution_set" == true && "$group_set" == true && "$plan_set" == true ]] || {
		usage
		exit 2
	}
	grouped=true

	current_head="$(git rev-parse HEAD)" || {
		echo 'Failed to resolve the current Git head.' >&2
		exit 2
	}
	if ! uv run --locked python scripts/test/ci_plan.py validate \
		--plan "$plan" --head "$current_head"; then
		echo 'The CI plan is invalid for the current Git head.' >&2
		exit 2
	fi
	mapped_execution="$(GROUP="$group" yq -er \
		'.groups[strenv(GROUP)].execution // ""' tests/impact.yaml)" || {
		echo "Unknown CI group: $group." >&2
		exit 2
	}
	[[ "$execution" == "$mapped_execution" ]] || {
		echo "CI group '$group' maps to '$mapped_execution', not '$execution'." >&2
		exit 2
	}
	GROUP="$group" yq -e '.groups | map(. == strenv(GROUP)) | any' "$plan" \
		>/dev/null || {
		echo "CI group '$group' is not selected by the plan." >&2
		exit 2
	}
	read -r plan_id base_sha head_sha < <(
		yq -r '[.plan_id, .base_sha, .head_sha] | @tsv' "$plan"
	)
	execution_id_lines="$(catalog_execution_ids "$catalog" "$execution")" || {
		echo "Failed to resolve CI execution '$execution'." >&2
		exit 2
	}
	[[ -n "$execution_id_lines" ]] || {
		echo "CI execution '$execution' is empty." >&2
		exit 2
	}
fi

aggregate_entry="$(catalog_entry_by_id "$catalog" validation.ci)"
execution_origin="$(resolve_execution_origin)"
run_dir="$(create_run_directory "$results_root" "$execution_origin")"
run_id="$(basename "$run_dir")"
write_run_id_output "$run_id"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_epoch="$EPOCHSECONDS"
mkdir -p "$run_dir/diagnostics/fragments" "$run_dir/diagnostics/suites" \
	"$run_dir/diagnostics/shared"
shared_result_dir="$(cd "$run_dir/diagnostics/shared" && pwd)"

declare -a suite_reports=()
suite_records=''
fail_fast=false
run_result='passed'
primary_exit_code=0
signal_exit_code=0

if [[ "$grouped" == false ]]; then
	execution_id_lines="$(catalog_execution_ids "$catalog" ci)" || {
		echo 'Failed to resolve the complete CI execution list.' >&2
		exit 2
	}
	[[ -n "$execution_id_lines" ]] || {
		echo 'The CI execution list is empty.' >&2
		exit 2
	}
fi
mapfile -t execution_ids <<<"$execution_id_lines"

epoch_milliseconds() {
	local now seconds fraction
	now="$EPOCHREALTIME"
	seconds="${now%%.*}"
	fraction="${now#*.}"
	echo "$((10#$seconds * 1000 + 10#${fraction:0:3}))"
}

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
	local duration_ms="$4"
	local counts tests failures errors skipped _passed record
	counts="$(read_junit_counts "$report")"
	read -r tests failures errors skipped _passed <<<"$counts"
	record="$(
		SUITE_ID="$suite_id" \
			SUITE_RESULT="$suite_result" \
			DURATION_MS="$duration_ms" \
			TESTS="$tests" \
			FAILURES="$failures" \
			ERRORS="$errors" \
			SKIPPED="$skipped" \
			yq --null-input --output-format json --indent 0 '{
        "id": strenv(SUITE_ID),
        "result": strenv(SUITE_RESULT),
        "duration_ms": (strenv(DURATION_MS) | tonumber),
        "tests": (strenv(TESTS) | tonumber),
        "failures": (strenv(FAILURES) | tonumber),
        "errors": (strenv(ERRORS) | tonumber),
        "skipped": (strenv(SKIPPED) | tonumber)
      }'
	)"
	suite_records+="${suite_records:+$'\n'}$record"
}

for suite_id in "${execution_ids[@]}"; do
	[[ -n "$suite_id" ]] || continue
	entry="$(catalog_entry_by_id "$catalog" "$suite_id")"
	command="$(yq -r '.runner.command' - <<<"$entry")"
	native_strategy="$(yq -r '.native_results.strategy' - <<<"$entry")"
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
		append_suite_record "$suite_id" skipped "$suite_report" 0
		suite_reports+=("$suite_report")
		continue
	fi

	suite_started_ms="$(epoch_milliseconds)"
	echo "=== $suite_id: just $command_args ==="
	set +e
	env -u TEST_RUN_ID_FILE \
		TEST_SHARED_RESULT_DIR="$shared_result_dir" \
		TEST_RUN_ID="$run_id" \
		TEST_RESULT_FRAGMENT_DIR="$(cd "$fragment_dir" && pwd)" \
		"$just_bin" "${just_args[@]}" </dev/null 2>&1 | tee "$suite_log"
	command_exit_code="${PIPESTATUS[0]}"
	set -e
	if [[ "$signal_exit_code" -ne 0 ]]; then
		command_exit_code="$signal_exit_code"
	fi
	suite_duration_ms=$(($(epoch_milliseconds) - suite_started_ms))
	printf -v suite_duration_seconds '%d.%03d' \
		"$((suite_duration_ms / 1000))" "$((suite_duration_ms % 1000))"

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
				"$suite_duration_seconds"
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
					"$suite_duration_seconds"
				suite_result='broken'
			fi
		fi
	elif [[ "$signal_exit_code" -ne 0 ]]; then
		write_result_case_junit "$suite_report" "$suite_id" signal broken \
			"$suite_duration_seconds"
		suite_result='broken'
	elif [[ "$command_exit_code" -eq 0 && "$native_strategy" == 'native-junit' ]]; then
		write_result_case_junit "$suite_report" "$suite_id" missing-native-junit broken \
			"$suite_duration_seconds"
		suite_result='broken'
	elif [[ "$command_exit_code" -eq 0 ]]; then
		write_result_case_junit "$suite_report" "$suite_id" command passed \
			"$suite_duration_seconds"
	else
		write_result_case_junit "$suite_report" "$suite_id" command failed \
			"$suite_duration_seconds"
		suite_result='failed'
	fi

	append_suite_record "$suite_id" "$suite_result" "$suite_report" "$suite_duration_ms"
	suite_reports+=("$suite_report")
	if [[ "$command_exit_code" -ne 0 || "$suite_result" != 'passed' ]]; then
		fail_fast=true
		primary_exit_code="$command_exit_code"
		[[ "$primary_exit_code" -ne 0 ]] || primary_exit_code=1
		run_result="$suite_result"
		echo "CI fail-fast stop after $suite_id ($suite_result)." >&2
	fi
done

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
if [[ "$grouped" == true ]]; then
	binding_temporary="$(mktemp "$run_dir/diagnostics/.ci-binding.json.XXXXXX")"
	if ! PLAN_ID="$plan_id" BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
		GROUP="$group" EXECUTION="$execution" \
		yq --null-input --output-format json '{
      "schema_version": 1,
      "plan_id": strenv(PLAN_ID),
      "base_sha": strenv(BASE_SHA),
      "head_sha": strenv(HEAD_SHA),
      "group": strenv(GROUP),
      "execution": strenv(EXECUTION)
    }' >"$binding_temporary"; then
		rm -f -- "$binding_temporary"
		exit 1
	fi
	mv "$binding_temporary" "$run_dir/diagnostics/ci-binding.json"
fi
write_evidence_index "$run_dir" "$run_id"
write_multi_summary "$run_dir" "$run_id" "$aggregate_entry" "$execution_origin" \
	"$started_at" "$finished_at" "$duration_seconds" "$run_result" \
	"$primary_exit_code" "$suites_json"
scripts/test/validate-run.sh "$run_dir"
write_run_id_output "$run_id"

echo "CI results: $run_dir"
if [[ "$primary_exit_code" -ne 0 ]]; then
	exit "$primary_exit_code"
fi
[[ "$run_result" == 'passed' ]]
