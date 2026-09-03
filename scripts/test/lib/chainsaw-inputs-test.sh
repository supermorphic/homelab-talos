#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
helper="$repo_root/scripts/test/lib/chainsaw-inputs.sh"
validator="$repo_root/scripts/test/validate-chainsaw.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/chainsaw-inputs-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
[[ -x "$repo_root/scripts/test/lib/chainsaw-inputs-test.sh" ]]

# The production change that must make this assertion fail is recording a literal
# JUnit duration instead of the measured shell-case duration.
run_shell_case_source="$(sed -n '/^run_shell_case() {/,/^}/p' "$validator")"
case_duration_literal="\"\$case_duration\""
[[ "$run_shell_case_source" == *'write_result_case_junit'* ]]
[[ "$run_shell_case_source" == *"$case_duration_literal"* ]]
if rg -q '^[[:space:]]*0$' <<<"$run_shell_case_source"; then
	echo 'Shell case JUnit results must not use a literal zero duration.' >&2
	exit 1
fi

# The production change that must make these tests fail is discovering ignored,
# symlinked, non-test, unsorted, or non-repository YAML inputs.
# shellcheck source=scripts/test/lib/chainsaw-inputs.sh
source "$helper"

repository_oracle() {
	local root="$1" relative
	git -C "$root" ls-files -co --exclude-standard -z -- \
		tests/chainsaw tests/fixtures/chainsaw |
		while IFS= read -r -d '' relative; do
			case "$relative" in
			*/chainsaw-test.yaml | */chainsaw-test.yml)
				[[ -f "$root/$relative" && ! -L "$root/$relative" ]] &&
					printf '%s\n' "$relative"
				;;
			esac
		done | LC_ALL=C sort
}

mapfile -t repository_documents < <(repository_oracle "$repo_root")
[[ "${#repository_documents[@]}" -eq 20 ]]
[[ "$(printf '%s\n' "${repository_documents[@]}" | rg -c '^tests/chainsaw/')" -eq 19 ]]
[[ "$(printf '%s\n' "${repository_documents[@]}" | rg -c '^tests/fixtures/chainsaw/')" -eq 1 ]]

mapfile -t discovered_documents < <(chainsaw_test_files "$repo_root")
[[ "$(printf '%s\n' "${discovered_documents[@]}")" == "$(printf '%s\n' "${repository_documents[@]}")" ]]
mapfile -t repository_support < <(chainsaw_yaml_support_files "$repo_root")
[[ "${#repository_support[@]}" -eq 0 ]]

synthetic_root="$fixture_root/synthetic repository"
mkdir -p "$synthetic_root/tests/chainsaw/nested path" \
	"$synthetic_root/tests/chainsaw/z-last" \
	"$synthetic_root/tests/chainsaw/ignored" \
	"$synthetic_root/tests/fixtures/chainsaw/support files"
git -C "$synthetic_root" init -q
git -C "$synthetic_root" config user.email test@example.invalid
git -C "$synthetic_root" config user.name 'Chainsaw Inputs Test'
printf '%s\n' 'tests/chainsaw/ignored/' >"$synthetic_root/.gitignore"
printf '%s\n' 'apiVersion: chainsaw.kyverno.io/v1alpha1' \
	'kind: Test' >"$synthetic_root/tests/chainsaw/z-last/chainsaw-test.yaml"
printf '%s\n' 'apiVersion: chainsaw.kyverno.io/v1alpha1' \
	'kind: Test' >"$synthetic_root/tests/chainsaw/nested path/chainsaw-test.yml"
printf '%s\n' 'broken: [test' >"$synthetic_root/tests/chainsaw/nested path/malformed-test.yaml"
printf '%s\n' 'support: true' \
	>"$synthetic_root/tests/fixtures/chainsaw/support files/support.yaml"
printf '%s\n' 'ignored: true' >"$synthetic_root/tests/chainsaw/ignored/chainsaw-test.yaml"
ln -s 'chainsaw-test.yml' \
	"$synthetic_root/tests/chainsaw/nested path/symlink.yaml"
git -C "$synthetic_root" add .
git -C "$synthetic_root" commit -qm 'synthetic chainsaw inputs'
mkdir -p "$synthetic_root/tests/chainsaw/untracked"
printf '%s\n' 'apiVersion: chainsaw.kyverno.io/v1alpha1' \
	'kind: Test' >"$synthetic_root/tests/chainsaw/untracked/chainsaw-test.yaml"

mapfile -t synthetic_tests < <(chainsaw_test_files "$synthetic_root")
[[ "$(printf '%s\n' "${synthetic_tests[@]}")" == $'tests/chainsaw/nested path/chainsaw-test.yml\ntests/chainsaw/untracked/chainsaw-test.yaml\ntests/chainsaw/z-last/chainsaw-test.yaml' ]]
mapfile -t synthetic_support < <(chainsaw_yaml_support_files "$synthetic_root")
[[ "$(printf '%s\n' "${synthetic_support[@]}")" == $'tests/chainsaw/nested path/malformed-test.yaml\ntests/fixtures/chainsaw/support files/support.yaml' ]]
for test_file in "${synthetic_tests[@]}"; do
	printf '%s\n' "${synthetic_support[@]}" | rg -Fqx -- "$test_file" && {
		echo "Test and support inputs overlap: $test_file" >&2
		exit 1
	}
done
if printf '%s\n' "${synthetic_tests[@]}" "${synthetic_support[@]}" |
	rg -q 'ignored|symlink'; then
	echo 'Ignored or symlinked YAML input was discovered.' >&2
	exit 1
fi

failing_git_root="$fixture_root/failing git"
mkdir -p "$failing_git_root"
cat >"$failing_git_root/git" <<'EOF'
#!/usr/bin/env bash
exit 61
EOF
chmod +x "$failing_git_root/git"
for discovery_function in chainsaw_test_files chainsaw_yaml_support_files; do
	set +e
	PATH="$failing_git_root:$PATH" "$discovery_function" "$synthetic_root" \
		>"$fixture_root/${discovery_function}.out" 2>&1
	discovery_status="$?"
	set -e
	[[ "$discovery_status" -ne 0 ]] || {
		echo "$discovery_function accepted a failed Git discovery." >&2
		exit 1
	}
done

validator_root="$fixture_root/validator repository"
mkdir -p "$validator_root/scripts/test/lib" "$validator_root/tests/chainsaw/nested" \
	"$validator_root/tests/chainsaw/with space" \
	"$validator_root/tests/fixtures/chainsaw/support" "$validator_root/bin"
cp "$repo_root/scripts/test/validate-chainsaw.sh" \
	"$validator_root/scripts/test/validate-chainsaw.sh"
cp "$repo_root/scripts/test/lib/chainsaw-inputs.sh" \
	"$validator_root/scripts/test/lib/chainsaw-inputs.sh"
printf '%s\n' ':' >"$validator_root/scripts/test/lib/results.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
	>"$validator_root/scripts/test/run-native-junit-validator.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
	>"$validator_root/scripts/test/validate-catalog.sh"
chmod +x "$validator_root/scripts/test/run-native-junit-validator.sh" \
	"$validator_root/scripts/test/validate-catalog.sh"

while IFS= read -r test_script; do
	[[ "$test_script" == 'scripts/test/validate-chainsaw.sh' ]] && continue
	mkdir -p "$validator_root/$(dirname -- "$test_script")"
	{
		printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
		# shellcheck disable=SC2016 # The generated stub expands its own log path.
		printf 'printf "%%s\\n" %q >>"${SHELL_CASE_LOG:?}"\n' "$test_script"
	} >"$validator_root/$test_script"
	chmod +x "$validator_root/$test_script"
done < <(
	awk '
		/^[[:space:]]*run_shell_case / {
			for (field = 1; field <= NF; field++) {
				if ($field ~ /^(scripts\/test|tests\/probes)\/.*\.sh$/) print $field
			}
			awaiting_script = ($0 ~ /\\[[:space:]]*$/)
			next
		}
		awaiting_script && /^[[:space:]]*(scripts\/test|tests\/probes)\/.*\.sh$/ {
			print $1
			awaiting_script = 0
		}
	' "$repo_root/scripts/test/validate-chainsaw.sh"
)

printf '%s\n' 'apiVersion: chainsaw.kyverno.io/v1alpha1' \
	'kind: Test' >"$validator_root/tests/chainsaw/nested/chainsaw-test.yaml"
printf '%s\n' 'not: [valid' \
	>"$validator_root/tests/chainsaw/with space/chainsaw-test.yml"
printf '%s\n' 'support: true' \
	>"$validator_root/tests/fixtures/chainsaw/support/values.yaml"
printf '%s\n' 'apiVersion: chainsaw.kyverno.io/v1alpha1' \
	'kind: Configuration' >"$validator_root/tests/config.yaml"

cat >"$validator_root/bin/chainsaw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1 $2" == 'lint test' ]]; then
	printf '%q\t' "$@" >>"${CHAINSAW_LOG:?}"
	printf '\n' >>"${CHAINSAW_LOG:?}"
fi
if [[ "$1 $2" == 'lint test' && "$4" == 'tests/chainsaw/with space/chainsaw-test.yml' && \
	"${CHAINSAW_FAIL_MALFORMED:-false}" == true ]]; then
	printf '%s: malformed test document\n' "$4" >&2
	exit 37
fi
EOF
cat >"$validator_root/bin/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "${@: -1}" >>"${YQ_LOG:?}"
EOF
cat >"$validator_root/bin/python" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$validator_root/bin/uv" <<'EOF'
#!/usr/bin/env bash
printf '%q\t' "$@" >>"${UV_LOG:?}"
printf '\n' >>"${UV_LOG:?}"
exit 0
EOF
real_git="$(command -v git)"
cat >"$validator_root/bin/git" <<EOF
#!/usr/bin/env bash
if [[ "\${CHAINSAW_GIT_FAIL:-false}" == true ]]; then
  exit 61
fi
exec "$real_git" "\$@"
EOF
chmod +x "$validator_root/bin/chainsaw" "$validator_root/bin/yq" \
	"$validator_root/bin/python" "$validator_root/bin/uv" "$validator_root/bin/git"
git -C "$validator_root" init -q
git -C "$validator_root" config user.email test@example.invalid
git -C "$validator_root" config user.name 'Chainsaw Validator Test'
git -C "$validator_root" add tests
git -C "$validator_root" commit -qm 'validator fixture'

chainsaw_log="$fixture_root/chainsaw.log"
yq_log="$fixture_root/yq.log"
shell_case_log="$fixture_root/shell-cases.log"
uv_log="$fixture_root/uv.log"
malformed_output="$fixture_root/malformed.out"
set +e
PATH="$validator_root/bin:$PATH" \
	CHAINSAW_LOG="$chainsaw_log" YQ_LOG="$yq_log" CHAINSAW_FAIL_MALFORMED=true \
	UV_LOG="$uv_log" \
	TEST_RESULT_FRAGMENT_DIR='' TEST_SHARED_RESULT_DIR='' TEST_RUN_ID='' \
	bash "$validator_root/scripts/test/validate-chainsaw.sh" >"$malformed_output" 2>&1
malformed_status="$?"
set -e
[[ "$malformed_status" -eq 37 ]]
rg -F 'tests/chainsaw/with space/chainsaw-test.yml: malformed test document' "$malformed_output"
mapfile -t malformed_lints <"$chainsaw_log"
[[ "${#malformed_lints[@]}" -eq 2 ]]
[[ "${malformed_lints[0]}" == $'lint\ttest\t--file\ttests/chainsaw/nested/chainsaw-test.yaml\t' ]]
[[ "${malformed_lints[1]}" == $'lint\ttest\t--file\ttests/chainsaw/with\\ space/chainsaw-test.yml\t' ]]
[[ ! -s "$yq_log" ]]

: >"$chainsaw_log"
: >"$yq_log"
: >"$shell_case_log"
: >"$uv_log"
PATH="$validator_root/bin:$PATH" \
	CHAINSAW_LOG="$chainsaw_log" YQ_LOG="$yq_log" SHELL_CASE_LOG="$shell_case_log" \
	UV_LOG="$uv_log" \
	TEST_RESULT_FRAGMENT_DIR='' TEST_SHARED_RESULT_DIR='' TEST_RUN_ID='' \
	bash "$validator_root/scripts/test/validate-chainsaw.sh" >/dev/null
mapfile -t passing_lints <"$chainsaw_log"
[[ "${#passing_lints[@]}" -eq 2 ]]
[[ "${passing_lints[0]}" == $'lint\ttest\t--file\ttests/chainsaw/nested/chainsaw-test.yaml\t' ]]
[[ "${passing_lints[1]}" == $'lint\ttest\t--file\ttests/chainsaw/with\\ space/chainsaw-test.yml\t' ]]
[[ "$(cat "$yq_log")" == 'tests/fixtures/chainsaw/support/values.yaml' ]]
if rg -q 'chainsaw-test\.ya?ml' "$yq_log"; then
	echo 'Chainsaw test documents were reparsed with yq.' >&2
	exit 1
fi
for expected_case in \
	scripts/test/lib/chainsaw-inputs-test.sh \
	scripts/test/run-native-junit-validator-test.sh; do
	invocation_count=0
	while IFS= read -r invoked_case; do
		[[ "$invoked_case" == "$expected_case" ]] && invocation_count=$((invocation_count + 1))
	done <"$shell_case_log"
	[[ "$invocation_count" -eq 1 ]] || {
		echo "$expected_case must appear exactly once in the real harness inventory." >&2
		exit 1
	}
done
[[ "$(rg -c $'^run\t--locked\truff\tcheck\t.*scripts/test/test_catalog_compatibility.py' "$uv_log")" -eq 1 ]]
[[ "$(rg -c $'^run\t--locked\truff\tformat\t--check\t.*scripts/test/test_catalog_compatibility.py' "$uv_log")" -eq 1 ]]

: >"$chainsaw_log"
: >"$yq_log"
: >"$uv_log"
git_failure_output="$fixture_root/git-failure.out"
set +e
PATH="$validator_root/bin:$PATH" \
	CHAINSAW_LOG="$chainsaw_log" YQ_LOG="$yq_log" CHAINSAW_GIT_FAIL=true \
	UV_LOG="$uv_log" \
	TEST_RESULT_FRAGMENT_DIR='' TEST_SHARED_RESULT_DIR='' TEST_RUN_ID='' \
	bash "$validator_root/scripts/test/validate-chainsaw.sh" >"$git_failure_output" 2>&1
git_failure_status="$?"
set -e
[[ "$git_failure_status" -ne 0 ]]
[[ ! -s "$chainsaw_log" ]]
[[ ! -s "$yq_log" ]]

echo 'Chainsaw input discovery tests passed.'
