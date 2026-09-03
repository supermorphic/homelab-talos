#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/validate-chainsaw-timing-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
fragment_root="$fixture_root/fragments"
must_not_run="$fixture_root/must-not-run"
mkdir -p "$fragment_root"

write_result_case_junit() {
	local output_file="$1" suite_name="$2" case_name="$3" result="$4" duration="$5"
	printf '<testsuite name="%s"><testcase classname="%s" name="%s" time="%s">' \
		"$suite_name" "$suite_name" "$case_name" "$duration" >"$output_file"
	[[ "$result" != failed ]] || printf '<failure/>' >>"$output_file"
	printf '</testcase></testsuite>\n' >>"$output_file"
}

# shellcheck source=scripts/test/lib/harness-shell-runner.sh
source "$repo_root/scripts/test/lib/harness-shell-runner.sh"
register_harness_shell_case immediate-pass true
register_harness_shell_case delayed-pass sleep 0.05
register_harness_shell_case failing-case bash -c 'exit 23'
register_harness_shell_case must-not-run touch "$must_not_run"

set +e
run_registered_harness_shell_cases "$fragment_root" 1 0 \
	>"$fixture_root/runner.out" 2>&1
runner_status="$?"
set -e

read_case_name() {
	sed -n 's/.*<testcase[^>]*name="\([^"]*\)".*/\1/p' "$1"
}

read_case_time() {
	sed -n 's/.*<testcase[^>]*time="\([^"]*\)".*/\1/p' "$1"
}

[[ "$(read_case_name "$fragment_root/bash-1.xml")" == immediate-pass ]]
[[ "$(read_case_name "$fragment_root/bash-2.xml")" == delayed-pass ]]
awk -v value="$(read_case_time "$fragment_root/bash-1.xml")" \
	'BEGIN { exit !(value >= 0) }'
awk -v value="$(read_case_time "$fragment_root/bash-2.xml")" \
	'BEGIN { exit !(value >= 0.04) }'
rg -q '<failure/>' "$fragment_root/bash-3.xml"
[[ "$runner_status" -eq 23 ]]
[[ ! -e "$fragment_root/bash-4.xml" ]]
[[ ! -e "$must_not_run" ]]

echo 'Chainsaw shell-case timing tests passed.'
