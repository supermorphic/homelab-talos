#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-harness-shell-consumer.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
tool_root="$fixture_root/tools"
shared_root="$fixture_root/shared"
producer_fragments="$fixture_root/producer-fragments"
matching_fragments="$fixture_root/matching-fragments"
fallback_fragments="$fixture_root/fallback-fragments"
bash_log="$fixture_root/bash.log"
shellcheck_log="$fixture_root/shellcheck.log"
conftest_log="$fixture_root/conftest.log"
real_bash="$(command -v bash)"
run_id='bounded-harness-run'

mkdir -p \
	"$fixture_root/scripts/test/lib" \
	"$fixture_root/scripts/test/safety" \
	"$fixture_root/scripts/secrets" \
	"$fixture_root/tests/chainsaw/smoke" \
	"$fixture_root/tests/config" \
	"$fixture_root/tests/fixtures/chainsaw" \
	"$fixture_root/tests/probes" \
	"$fixture_root/tests/policy/chainsaw" \
	"$tool_root" "$shared_root" "$producer_fragments"

cp scripts/test/validate-chainsaw.sh "$fixture_root/scripts/test/"
cp scripts/test/lib/chainsaw-inputs.sh "$fixture_root/scripts/test/lib/"
cp scripts/test/run-native-junit-validator.sh \
	"$fixture_root/scripts/test/"
cp scripts/test/repository_shell_validation.py scripts/test/junit_report.py \
	scripts/test/junit_tools.py \
	"$fixture_root/scripts/test/"
# shellcheck disable=SC2016 # The generated function expands its own first argument.
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'write_result_case_junit() { : >"$1"; }' \
	>"$fixture_root/scripts/test/lib/results.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
	>"$fixture_root/scripts/test/validate-catalog.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 97' \
	>"$fixture_root/scripts/test/safety/require-chaos-confirmation-test.sh"
printf '%s\n' '[tools]' 'shellcheck = "fake-1.0"' >"$fixture_root/.mise.toml"

cat >"$tool_root/bash" <<EOF
#!/bin/sh
if [ "\${1:-}" = -n ]; then
  printf '%s\n' "\${2:-}" >>"\${BASH_VALIDATION_LOG:?}"
fi
exec "$real_bash" "\$@"
EOF
cat >"$tool_root/shellcheck" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${SHELLCHECK_VALIDATION_LOG:?}"
printf '%s\n' '[]'
EOF
cat >"$tool_root/chainsaw" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tool_root/conftest" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${CONFTEST_LOG:?}"
case " $* " in
*' --output junit '*) printf '%s\n' '<testsuites tests="1" failures="0" errors="0" skipped="0"><testsuite name="fake" tests="1" failures="0" errors="0" skipped="0"><testcase classname="fake" name="pass"/></testsuite></testsuites>' ;;
esac
exit 0
EOF
chmod +x \
	"$fixture_root/scripts/test/validate-chainsaw.sh" \
	"$fixture_root/scripts/test/run-native-junit-validator.sh" \
	"$fixture_root/scripts/test/validate-catalog.sh" \
	"$fixture_root/scripts/test/safety/require-chaos-confirmation-test.sh" \
	"$tool_root/bash" "$tool_root/shellcheck" "$tool_root/chainsaw" "$tool_root/conftest"

git -C "$fixture_root" init --quiet
git -C "$fixture_root" config user.email tests@example.invalid
git -C "$fixture_root" config user.name 'Harness Shell Consumer Tests'
git -C "$fixture_root" add .
git -C "$fixture_root" commit --quiet -m fixture

declare -a expected_files=()
while IFS= read -r -d '' candidate; do
	[[ "$candidate" == *.sh && -f "$fixture_root/$candidate" &&
		! -L "$fixture_root/$candidate" ]] || continue
	expected_files+=("$candidate")
done < <(
	git -C "$fixture_root" ls-files -co --exclude-standard -z -- \
		scripts/hooks scripts/repository scripts/secrets scripts/talos \
		scripts/validate scripts/verify scripts/test tests/probes
)
mapfile -t expected_files < <(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort)
expected_shellcheck_argv="--external-sources --format=json ${expected_files[*]}"

(
	cd "$fixture_root"
	PATH="$tool_root:$PATH" \
		BASH_VALIDATION_LOG="$bash_log" \
		SHELLCHECK_VALIDATION_LOG="$shellcheck_log" \
		python scripts/test/repository_shell_validation.py produce \
		--suite validation.repo-validate \
		--artifact "$shared_root/repository-shell-validation.json" \
		--run-id "$run_id" \
		--junit "$producer_fragments/repository-shell-validation.xml"
)

run_bounded_harness() {
	local output="$1"
	shift
	set +e
	env "$@" \
		PATH="$tool_root:$PATH" \
		BASH_VALIDATION_LOG="$bash_log" \
		CONFTEST_LOG="$conftest_log" \
		SHELLCHECK_VALIDATION_LOG="$shellcheck_log" \
		"$fixture_root/scripts/test/validate-chainsaw.sh" >"$output" 2>&1
	local status="$?"
	set -e
	[[ "$status" -eq 97 ]] || {
		cat "$output" >&2
		echo "Expected bounded harness stop status 97, got $status." >&2
		exit 1
	}
}

: >"$bash_log"
: >"$shellcheck_log"
: >"$conftest_log"
mkdir "$matching_fragments"
run_bounded_harness "$fixture_root/matching.log" \
	TEST_SHARED_RESULT_DIR="$shared_root" \
	TEST_RUN_ID="$run_id" \
	TEST_RESULT_FRAGMENT_DIR="$matching_fragments"
if [[ -s "$bash_log" ]]; then
	echo 'Matching harness pass must not invoke Bash validation.' >&2
	cat "$bash_log" >&2
	exit 1
fi
if [[ -s "$shellcheck_log" ]]; then
	echo 'Matching harness pass must not invoke ShellCheck.' >&2
	cat "$shellcheck_log" >&2
	exit 1
fi
if [[ -e "$matching_fragments/repository-shell-validation.xml" ]]; then
	echo 'Matching harness pass must not create a consumer fragment.' >&2
	exit 1
fi
[[ "$(wc -l <"$conftest_log")" -eq 1 ]]
[[ "$(cat "$conftest_log")" == \
  'test --all-namespaces --policy tests/policy/chainsaw --output junit tests/config/chainsaw.yaml tests/chainsaw/smoke' ]]

: >"$bash_log"
: >"$shellcheck_log"
: >"$conftest_log"
mkdir "$fallback_fragments"
run_bounded_harness "$fixture_root/fallback.log" \
	-u TEST_SHARED_RESULT_DIR \
	-u TEST_RUN_ID \
	TEST_RESULT_FRAGMENT_DIR="$fallback_fragments"
mapfile -t actual_bash_files <"$bash_log"
[[ "${actual_bash_files[*]}" == "${expected_files[*]}" ]]
[[ "${#actual_bash_files[@]}" -eq "${#expected_files[@]}" ]]
mapfile -t shellcheck_invocations <"$shellcheck_log"
[[ "${#shellcheck_invocations[@]}" -eq 1 ]]
[[ "${shellcheck_invocations[0]}" == "$expected_shellcheck_argv" ]]
[[ -s "$fallback_fragments/repository-shell-validation.xml" ]]
[[ "$(wc -l <"$conftest_log")" -eq 1 ]]
[[ "$(cat "$conftest_log")" == \
  'test --all-namespaces --policy tests/policy/chainsaw --output junit tests/config/chainsaw.yaml tests/chainsaw/smoke' ]]

echo 'Bounded harness repository-shell consumer tests passed.'
