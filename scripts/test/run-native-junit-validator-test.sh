#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
wrapper="$repo_root/scripts/test/run-native-junit-validator.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/native-junit-validator-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
fake_validator="$fixture_root/bin/fake validator"
fragment_root="$fixture_root/fragments"
invocations="$fixture_root/invocations"
mkdir -p "$fixture_root/bin" "$fragment_root"
: >"$invocations"

cat >"$fake_validator" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$#:$*" >>"${FAKE_INVOCATIONS:?}"
case "${FAKE_VALIDATOR_MODE:?}" in
  pass)
    printf '%s\n' '<testsuites tests="1" failures="0" errors="0" skipped="0"><testsuite name="fake" tests="1" failures="0" errors="0" skipped="0"><testcase classname="fake" name="pass"/></testsuite></testsuites>'
    ;;
  policy-failure)
    printf '%s\n' '<testsuites tests="1" failures="1" errors="0" skipped="0"><testsuite name="fake" tests="1" failures="1" errors="0" skipped="0"><testcase classname="fake" name="policy"><failure>denied by policy</failure></testcase></testsuite></testsuites>'
    exit 23
    ;;
  invalid)
    printf '%s\n' 'not junit'
    ;;
  empty)
    :
    ;;
  term)
    printf '%s\n' started >"${FAKE_TERM_READY:?}"
    kill -TERM "$PPID"
    sleep 0.1
    printf '%s\n' '<testsuites tests="1" failures="0" errors="0" skipped="0"><testsuite name="fake" tests="1" failures="0" errors="0" skipped="0"><testcase classname="fake" name="late"/></testsuite></testsuites>'
    ;;
  *)
    exit 99
    ;;
esac
EOF
chmod +x "$fake_validator"

run_wrapper() {
	local mode="$1"
	local output="$2"
	shift 2
	set +e
	FAKE_INVOCATIONS="$invocations" \
		FAKE_VALIDATOR_MODE="$mode" \
		TEST_RESULT_FRAGMENT_DIR="$fragment_root" \
		"$wrapper" --suite validation.test-harness --fragment "$1" --label "$2" -- \
		"$fake_validator" "${@:3}" >"$output" 2>&1
	wrapper_status="$?"
	set -e
}

assert_no_temporary_files() {
	[[ -z "$(find "$fragment_root" -name '.native-junit.*' -print -quit)" ]] || {
		echo 'Native JUnit wrapper left a temporary fragment behind.' >&2
		exit 1
	}
}

[[ -x "$wrapper" ]]

pass_output="$fixture_root/pass.out"
run_wrapper pass "$pass_output" pass.xml Chainsaw
[[ "$wrapper_status" -eq 0 ]]
[[ -f "$fragment_root/pass.xml" ]]
rg -F 'Chainsaw: 1 tests, 1 passed, 0 failures, 0 errors, 0 skipped' "$pass_output"
[[ "$(wc -l <"$invocations")" -eq 1 ]]
assert_no_temporary_files

: >"$invocations"
policy_output="$fixture_root/policy.out"
run_wrapper policy-failure "$policy_output" policy.xml Chainsaw
[[ "$wrapper_status" -eq 23 ]]
[[ -f "$fragment_root/policy.xml" ]]
rg -F 'Chainsaw: 1 tests, 0 passed, 1 failures, 0 errors, 0 skipped' "$policy_output"
rg -F 'failure: fake.policy: denied by policy' "$policy_output"
[[ "$(wc -l <"$invocations")" -eq 1 ]]
assert_no_temporary_files

for invalid_mode in invalid empty; do
	: >"$invocations"
	invalid_output="$fixture_root/$invalid_mode.out"
	invalid_fragment="$invalid_mode.xml"
	run_wrapper "$invalid_mode" "$invalid_output" "$invalid_fragment" Chainsaw
	[[ "$wrapper_status" -eq 2 ]]
	[[ ! -e "$fragment_root/$invalid_fragment" ]]
	rg -F 'JUnit adapter error:' "$invalid_output"
	[[ "$(wc -l <"$invocations")" -eq 1 ]]
	assert_no_temporary_files
done

missing_output="$fixture_root/missing-command.out"
set +e
TEST_RESULT_FRAGMENT_DIR="$fragment_root" \
	"$wrapper" --suite validation.test-harness --fragment missing.xml --label Chainsaw -- \
	>"$missing_output" 2>&1
missing_status="$?"
set -e
[[ "$missing_status" -eq 2 ]]
[[ ! -e "$fragment_root/missing.xml" ]]

: >"$invocations"
missing_binary_output="$fixture_root/missing-binary.out"
set +e
FAKE_INVOCATIONS="$invocations" \
	TEST_RESULT_FRAGMENT_DIR="$fragment_root" \
	"$wrapper" --suite validation.test-harness --fragment missing-binary.xml --label Chainsaw -- \
	"$fixture_root/bin/missing validator" >"$missing_binary_output" 2>&1
missing_binary_status="$?"
set -e
[[ "$missing_binary_status" -eq 127 ]]
[[ ! -e "$fragment_root/missing-binary.xml" ]]
rg -F 'No such file or directory' "$missing_binary_output"
assert_no_temporary_files

: >"$invocations"
space_root="$fixture_root/fragments with spaces"
mkdir -p "$space_root"
space_output="$fixture_root/spaces.out"
set +e
FAKE_INVOCATIONS="$invocations" \
	FAKE_VALIDATOR_MODE=pass \
	TEST_RESULT_FRAGMENT_DIR="$space_root" \
	"$wrapper" --suite 'validation.test harness' --fragment 'native report.xml' \
	--label 'Chainsaw native report' -- "$fake_validator" 'argument with spaces' \
	>"$space_output" 2>&1
space_status="$?"
set -e
[[ "$space_status" -eq 0 ]]
[[ -f "$space_root/native report.xml" ]]
rg -F 'Chainsaw native report: 1 tests, 1 passed, 0 failures, 0 errors, 0 skipped' \
	"$space_output"
[[ "$(cat "$invocations")" == '1:argument with spaces' ]]

: >"$invocations"
collision_fragment="$fragment_root/collision.xml"
printf '%s\n' preserved >"$collision_fragment"
collision_output="$fixture_root/collision.out"
run_wrapper pass "$collision_output" collision.xml Chainsaw
[[ "$wrapper_status" -eq 2 ]]
[[ "$(cat "$collision_fragment")" == preserved ]]
[[ ! -s "$invocations" ]]
assert_no_temporary_files

: >"$invocations"
term_ready="$fixture_root/term-ready"
term_output="$fixture_root/term.out"
set +e
FAKE_INVOCATIONS="$invocations" \
	FAKE_VALIDATOR_MODE=term \
	FAKE_TERM_READY="$term_ready" \
	TEST_RESULT_FRAGMENT_DIR="$fragment_root" \
	"$wrapper" --suite validation.test-harness --fragment term.xml --label Chainsaw -- \
	"$fake_validator" >"$term_output" 2>&1
term_status="$?"
set -e
[[ -f "$term_ready" ]]
[[ "$term_status" -eq 143 ]]
[[ ! -e "$fragment_root/term.xml" ]]
[[ "$(wc -l <"$invocations")" -eq 1 ]]
assert_no_temporary_files

: >"$invocations"
standalone_tmp="$fixture_root/standalone-tmp"
mkdir -p "$standalone_tmp"
standalone_output="$fixture_root/standalone.out"
set +e
FAKE_INVOCATIONS="$invocations" \
	FAKE_VALIDATOR_MODE=pass \
	TMPDIR="$standalone_tmp" \
	"$wrapper" --suite validation.test-harness --fragment standalone.xml --label Chainsaw -- \
	"$fake_validator" >"$standalone_output" 2>&1
standalone_status="$?"
set -e
[[ "$standalone_status" -eq 0 ]]
[[ -z "$(find "$standalone_tmp" -mindepth 1 -print -quit)" ]]
[[ "$(wc -l <"$invocations")" -eq 1 ]]

echo 'Native JUnit validator wrapper tests passed.'
