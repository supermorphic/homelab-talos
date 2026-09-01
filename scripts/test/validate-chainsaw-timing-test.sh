#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/validate-chainsaw-timing-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
runner="$fixture_root/scripts/test/validate-chainsaw.sh"
fragment_root="$fixture_root/fragments"
tool_root="$fixture_root/bin"

mkdir -p "$fixture_root/scripts/test/lib" "$tool_root" "$fragment_root"

# Keep the production runner setup and shell-case wrapper, replace its real case
# inventory with controlled cases, and leave the later Python and Ruff calls stubbed.
awk '
	/^[[:space:]]*run_shell_case chaos-confirmation/ {
		print "run_shell_case immediate-pass true"
		print "run_shell_case delayed-pass sleep 0.05"
		print "run_shell_case failing-case bash -c '\''exit 23'\''"
		print "run_shell_case must-not-run false"
		skip_cases = 1
		next
	}
	/^# Offline Python unit tests/ { skip_cases = 0 }
	!skip_cases { print }
' "$repo_root/scripts/test/validate-chainsaw.sh" >"$runner"
cat >"$fixture_root/scripts/test/lib/chainsaw-inputs.sh" <<'EOF'
#!/usr/bin/env bash
chainsaw_test_files() { :; }
chainsaw_yaml_support_files() { :; }
EOF

cat >"$fixture_root/scripts/test/lib/results.sh" <<'EOF'
#!/usr/bin/env bash
write_result_case_junit() {
	local output_file="$1"
	local suite_name="$2"
	local case_name="$3"
	local result="$4"
	local duration="$5"
	if [[ "$result" == failed ]]; then
		printf '<testsuite name="%s"><testcase classname="%s" name="%s" time="%s"><failure/></testcase></testsuite>\n' \
			"$suite_name" "$suite_name" "$case_name" "$duration" >"$output_file"
		return
	fi
	printf '<testsuite name="%s"><testcase classname="%s" name="%s" time="%s"/></testsuite>\n' \
		"$suite_name" "$suite_name" "$case_name" "$duration" >"$output_file"
}
EOF
cat >"$fixture_root/scripts/test/validate-catalog.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fixture_root/scripts/test/run-native-junit-validator.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tool_root/chainsaw" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tool_root/python" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tool_root/uv" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$runner" "$fixture_root/scripts/test/validate-catalog.sh" \
	"$fixture_root/scripts/test/run-native-junit-validator.sh" "$tool_root/chainsaw" \
	"$tool_root/python" "$tool_root/uv"

read_case_name() {
	sed -n 's/.*<testcase[^>]*name="\([^"]*\)".*/\1/p' "$1"
}

read_case_time() {
	sed -n 's/.*<testcase[^>]*time="\([^"]*\)".*/\1/p' "$1"
}

read_case_result() {
	if rg -q '<failure' "$1"; then
		echo failed
	else
		echo passed
	fi
}

set +e
PATH="$tool_root:$PATH" TEST_RESULT_FRAGMENT_DIR="$fragment_root" \
	bash "$runner" >"$fixture_root/runner.out" 2>&1
runner_status="$?"
set -e

[[ -e "$fragment_root/bash-1.xml" ]] || {
	cat "$fixture_root/runner.out" >&2
	exit 1
}
[[ "$(read_case_name "$fragment_root/bash-1.xml")" == immediate-pass ]]
[[ "$(read_case_name "$fragment_root/bash-2.xml")" == delayed-pass ]]
awk -v value="$(read_case_time "$fragment_root/bash-1.xml")" 'BEGIN { exit !(value >= 0) }'
awk -v value="$(read_case_time "$fragment_root/bash-2.xml")" 'BEGIN { exit !(value >= 0.04) }'
[[ "$(read_case_result "$fragment_root/bash-3.xml")" == failed ]]
[[ "$runner_status" -eq 23 ]]
[[ ! -e "$fragment_root/bash-4.xml" ]]

echo 'Chainsaw shell-case timing tests passed.'
