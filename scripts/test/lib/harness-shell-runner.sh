#!/usr/bin/env bash

declare -ga HARNESS_SHELL_CASE_NAMES=()

reset_harness_shell_cases() {
	local index argv_name
	for index in "${!HARNESS_SHELL_CASE_NAMES[@]}"; do
		argv_name="HARNESS_SHELL_CASE_ARGV_${index}"
		unset "$argv_name"
	done
	HARNESS_SHELL_CASE_NAMES=()
}

register_harness_shell_case() {
	local case_name="${1:-}" existing argv_name
	[[ "$case_name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
		echo "Invalid harness shell case name: ${case_name:-<empty>}" >&2
		return 2
	}
	shift
	[[ "$#" -gt 0 && -n "${1:-}" ]] || {
		echo "Harness shell case $case_name has an empty command." >&2
		return 2
	}
	for existing in "${HARNESS_SHELL_CASE_NAMES[@]}"; do
		[[ "$existing" != "$case_name" ]] || {
			echo "Duplicate harness shell case name: $case_name" >&2
			return 2
		}
	done
	argv_name="HARNESS_SHELL_CASE_ARGV_${#HARNESS_SHELL_CASE_NAMES[@]}"
	declare -g -a "$argv_name"
	local -n argv_ref="$argv_name"
	# shellcheck disable=SC2034 # The runner reads this dynamic argv array by nameref.
	argv_ref=("$@")
	HARNESS_SHELL_CASE_NAMES+=("$case_name")
}

_harness_epoch_milliseconds() {
	local now seconds fraction
	now="$EPOCHREALTIME"
	seconds="${now%%.*}"
	fraction="${now#*.}000"
	printf '%s\n' "$((10#$seconds * 1000 + 10#${fraction:0:3}))"
}

validate_harness_shell_jobs() {
	local jobs="${1:-}"
	[[ "$jobs" =~ ^[1-8]$ ]] || {
		echo "TEST_HARNESS_JOBS must be an integer from 1 through 8: ${jobs:-<empty>}" >&2
		return 2
	}
}

run_registered_harness_shell_cases() (
	set -euo pipefail
	local result_fragment_root="${1:-}" jobs="${2:-}" start_index="${3:-}"
	validate_harness_shell_jobs "$jobs"
	[[ "$start_index" =~ ^[0-9]+$ ]] || {
		echo "Harness shell start index must be a non-negative integer: ${start_index:-<empty>}" >&2
		return 2
	}

	local runner_root next_index=0 active_count=0 first_failure=0
	local completed_pid completed_status completed_index now duration_ms duration
	local index pid result fragment_number argv_name
	local -a active_pids=()
	local -A pid_to_index=() case_status=() case_started=()
	local -A case_duration_ms=() case_canceled=()
	runner_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-shell-runner.XXXXXX")"

	# shellcheck disable=SC2329 # EXIT, INT, and TERM traps invoke this function.
	cleanup_harness_workers() {
		local owned_pid
		for owned_pid in "${!pid_to_index[@]}"; do
			kill -TERM "$owned_pid" 2>/dev/null || true
		done
		for owned_pid in "${!pid_to_index[@]}"; do
			wait "$owned_pid" 2>/dev/null || true
		done
		rm -rf -- "$runner_root"
	}
	trap cleanup_harness_workers EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	start_case() {
		local case_index="$1" case_root
		argv_name="HARNESS_SHELL_CASE_ARGV_${case_index}"
		local -n case_argv="$argv_name"
		case_root="$runner_root/case-${case_index}"
		mkdir -p "$case_root/tmp"
		case_started["$case_index"]="$(_harness_epoch_milliseconds)"
		(
			export TMPDIR="$case_root/tmp"
			unset TEST_RESULT_FRAGMENT_DIR TEST_SHARED_RESULT_DIR TEST_RUN_ID
			exec "${case_argv[@]}"
		) >"$case_root/stdout" 2>"$case_root/stderr" &
		pid="$!"
		pid_to_index["$pid"]="$case_index"
		active_count=$((active_count + 1))
	}

	while ((next_index < ${#HARNESS_SHELL_CASE_NAMES[@]} && active_count < jobs)); do
		start_case "$next_index"
		next_index=$((next_index + 1))
	done

	while ((active_count > 0)); do
		active_pids=()
		for pid in "${!pid_to_index[@]}"; do active_pids+=("$pid"); done
		set +e
		wait -n -p completed_pid "${active_pids[@]}"
		completed_status="$?"
		set -e
		completed_index="${pid_to_index[$completed_pid]}"
		now="$(_harness_epoch_milliseconds)"
		case_duration_ms["$completed_index"]=$((now - case_started[$completed_index]))
		case_status["$completed_index"]="$completed_status"
		unset 'pid_to_index[$completed_pid]'
		active_count=$((active_count - 1))

		if ((completed_status != 0)); then
			first_failure="$completed_status"
			for pid in "${!pid_to_index[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
			for pid in "${!pid_to_index[@]}"; do
				index="${pid_to_index[$pid]}"
				set +e
				wait "$pid"
				set -e
				now="$(_harness_epoch_milliseconds)"
				case_duration_ms["$index"]=$((now - case_started[$index]))
				case_status["$index"]=143
				case_canceled["$index"]=true
				unset 'pid_to_index[$pid]'
			done
			active_count=0
			break
		fi

		while ((next_index < ${#HARNESS_SHELL_CASE_NAMES[@]} && active_count < jobs)); do
			start_case "$next_index"
			next_index=$((next_index + 1))
		done
	done

	for ((index = 0; index < next_index; index++)); do
		cat "$runner_root/case-${index}/stdout"
		cat "$runner_root/case-${index}/stderr" >&2
		[[ -n "$result_fragment_root" ]] || continue
		duration_ms="${case_duration_ms[$index]}"
		printf -v duration '%d.%03d' \
			"$((duration_ms / 1000))" "$((duration_ms % 1000))"
		result=passed
		if [[ "${case_canceled[$index]:-false}" == true ]]; then
			result=skipped
		elif ((case_status[$index] != 0)); then
			result=failed
		fi
		fragment_number=$((start_index + index + 1))
		write_result_case_junit \
			"$result_fragment_root/bash-${fragment_number}.xml" \
			validation.test-harness \
			"${HARNESS_SHELL_CASE_NAMES[$index]}" \
			"$result" \
			"$duration"
	done

	return "$first_failure"
)
