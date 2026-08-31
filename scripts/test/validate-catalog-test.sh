#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

uv run --locked --no-dev python scripts/test/catalog_compatibility.py
scripts/test/validate-harness-shell-consumer-test.sh

[[ "$(yq -r '.suites[] | select(.metadata.id == "validation.repo-validate") | .native_results.strategy' tests/catalog.yaml)" == native-junit ]]

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-repository-shell-validation.XXXXXX")"
artifact_root="$fixture_root/shared"
fragment_root="$fixture_root/fragments"
artifact="$artifact_root/repository-shell-validation.json"
fragment="$fragment_root/repository-shell-validation.xml"
consumer_fragment="$fragment_root/consumer-repository-shell-validation.xml"
run_id='catalog-repository-shell-validation'
fixture_token="${fixture_root##*/}"
fixture_prefix="scripts/test/.repository-shell-validation-${fixture_token}"
bash_fixture="${fixture_prefix}-bash-first.sh"
bash_second_fixture="${fixture_prefix}-bash-second.sh"
shellcheck_fixture="${fixture_prefix}-shellcheck.sh"
legacy_fixture='scripts/test/.repository-shell-validation-shellcheck-fixture.sh'
bash_fixture_created=false
bash_second_fixture_created=false
shellcheck_fixture_created=false
legacy_fixture_created=false
tool_root="$fixture_root/tools"
bash_log="$fixture_root/bash.log"
shellcheck_log="$fixture_root/shellcheck.log"
real_bash="$(command -v bash)"

cleanup() {
	[[ "$bash_fixture_created" == true ]] && rm -f -- "$bash_fixture"
	[[ "$bash_second_fixture_created" == true ]] && rm -f -- "$bash_second_fixture"
	[[ "$shellcheck_fixture_created" == true ]] && rm -f -- "$shellcheck_fixture"
	[[ "$legacy_fixture_created" == true ]] && rm -f -- "$legacy_fixture"
	rm -rf -- "$fixture_root"
}
trap cleanup EXIT

for fixture in "$bash_fixture" "$bash_second_fixture" "$shellcheck_fixture" "$legacy_fixture"; do
	[[ ! -e "$fixture" ]] || {
		echo "Refusing to overwrite existing repository shell fixture: $fixture" >&2
		exit 1
	}
done

run_repository_validation() {
	local output="$1"
	TEST_SHARED_RESULT_DIR="$artifact_root" \
		TEST_RESULT_FRAGMENT_DIR="$fragment_root" \
		TEST_RUN_ID="$run_id" \
		mise exec -- just repo validate >"$output" 2>&1
}

run_consumer() {
	local artifact_path="${1:-}"
	local -a args=(consume --suite validation.test-harness)
	[[ -z "$artifact_path" ]] || args+=(--artifact "$artifact_path")
	[[ -z "${2:-}" ]] || args+=(--run-id "$2")
	args+=(--junit "$consumer_fragment")
	PATH="$tool_root:$PATH" \
		BASH_VALIDATION_LOG="$bash_log" \
		SHELLCHECK_VALIDATION_LOG="$shellcheck_log" \
		python scripts/test/repository_shell_validation.py "${args[@]}"
}

assert_one_consumer_recomputation() {
	local artifact_path="${1:-}"
	local consumer_run_id="${2:-}"
	: >"$bash_log"
	: >"$shellcheck_log"
	rm -f -- "$consumer_fragment"
	run_consumer "$artifact_path" "$consumer_run_id"
	[[ "$(wc -l <"$bash_log" | tr -d ' ')" -eq "${#expected_files[@]}" ]]
	[[ "$(wc -l <"$shellcheck_log" | tr -d ' ')" -eq 1 ]]
	[[ -s "$consumer_fragment" ]]
	[[ "$(yq -p=xml -o=yaml -r '.testsuites."+@tests"' "$consumer_fragment")" == 1 ]]
	[[ "$(yq -p=xml -o=yaml -r '.testsuites."+@failures"' "$consumer_fragment")" == 0 ]]
}

declare -a expected_files=()
while IFS= read -r -d '' candidate; do
	[[ "$candidate" == *.sh && -f "$candidate" && ! -L "$candidate" ]] || continue
	expected_files+=("$candidate")
done < <(
	git ls-files -co --exclude-standard -z -- \
		scripts/hooks scripts/repository scripts/secrets scripts/talos scripts/validate scripts/verify scripts/test tests/probes
)
mapfile -t expected_files < <(printf '%s\n' "${expected_files[@]}" | LC_ALL=C sort)

declare -a expected_harness_files=()
while IFS= read -r -d '' candidate; do
	[[ "$candidate" == *.sh && -f "$candidate" && ! -L "$candidate" ]] || continue
	expected_harness_files+=("$candidate")
done < <(
	git ls-files -co --exclude-standard -z -- scripts/secrets scripts/test tests/probes
)
mapfile -t expected_harness_files < <(
	printf '%s\n' "${expected_harness_files[@]}" | LC_ALL=C sort
)
for file in "${expected_harness_files[@]}"; do
	printf '%s\n' "${expected_files[@]}" | rg -Fqx -- "$file"
done

run_repository_validation "$fixture_root/clean.log"
[[ -s "$artifact" ]]
[[ -s "$fragment" ]]
[[ "$(yq -r '.run_id' "$artifact")" == "$run_id" ]]
[[ "$(yq -r '.head_sha' "$artifact")" == "$(git rev-parse HEAD)" ]]
expected_source_set_sha256="$(
	python - "${expected_files[@]}" <<'PY'
import hashlib
import sys
from pathlib import Path

digest = hashlib.sha256()
for name in sys.argv[1:]:
    digest.update(name.encode("utf-8") + b"\0")
    digest.update(Path(name).read_bytes() + b"\0")
print(digest.hexdigest())
PY
)"
[[ "$(yq -r '.source_set_sha256' "$artifact")" == "$expected_source_set_sha256" ]]
[[ "$(yq -r '.result.sorted_files[]' "$artifact")" == "$(printf '%s\n' "${expected_files[@]}")" ]]

for file in "${expected_files[@]}"; do
	bash -n "$file"
done
[[ "$(yq -r '.result.bash_status' "$artifact")" == 0 ]]
[[ "$(yq -r '.result.bash_first_failure' "$artifact")" == null ]]
set +e
shellcheck --external-sources --format=json "${expected_files[@]}" >"$fixture_root/expected.json"
shellcheck_status="$?"
set -e
[[ "$shellcheck_status" == 0 ]]
[[ "$(yq -r '.result.shellcheck_status' "$artifact")" == "$shellcheck_status" ]]
yq -o=json '[.[] | {"file": .file, "line": .line, "column": .column, "level": .level, "code": .code, "message": .message}]' "$fixture_root/expected.json" \
	>"$fixture_root/expected-findings.json"
yq -o=json '.findings' "$artifact" >"$fixture_root/artifact-findings.json"
cmp -s "$fixture_root/expected-findings.json" "$fixture_root/artifact-findings.json"

mkdir -p "$tool_root"
cat >"$tool_root/bash" <<EOF
#!/bin/sh
if [ "\${1:-}" = -n ]; then
  printf '%s\n' "\${2:-}" >>"\${BASH_VALIDATION_LOG:?}"
fi
exec "$real_bash" "\$@"
EOF
cat >"$tool_root/shellcheck" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"\${SHELLCHECK_VALIDATION_LOG:?}"
printf '%s\n' '[]'
EOF
chmod +x "$tool_root/bash" "$tool_root/shellcheck"

: >"$bash_log"
: >"$shellcheck_log"
rm -f -- "$consumer_fragment"
run_consumer "$artifact" "$run_id"
[[ ! -s "$bash_log" ]]
[[ ! -s "$shellcheck_log" ]]
[[ ! -e "$consumer_fragment" ]]

baseline_artifact="$fixture_root/baseline.json"
cp "$artifact" "$baseline_artifact"
assert_one_consumer_recomputation '' ''

rejected_artifact="$fixture_root/rejected.json"
for rejection in \
	missing failed status-inconsistent stale-run stale-head stale-source \
	stale-bash stale-shellcheck stale-argv stale-files malformed truncated \
	schema-invalid corrupt; do
	cp "$baseline_artifact" "$rejected_artifact"
	case "$rejection" in
	missing) rm -f -- "$rejected_artifact" ;;
	failed)
		yq -i \
			'.shellcheck_version = "not-run" |
			 .result.bash_status = 2 |
			 .result.bash_first_failure = {"file":"scripts/test/ok.sh","stderr":"bad"} |
			 .result.shellcheck_status = null |
			 .findings = []' "$rejected_artifact"
		;;
	status-inconsistent)
		yq -i '.findings = [{"file":"scripts/test/ok.sh","line":1,"column":1,"level":"warning","code":2086,"message":"unexpected"}]' "$rejected_artifact"
		;;
	stale-run) yq -i '.run_id = "other-run"' "$rejected_artifact" ;;
	stale-head) yq -i '.head_sha = "0000000000000000000000000000000000000000"' "$rejected_artifact" ;;
	stale-source) yq -i '.source_set_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$rejected_artifact" ;;
	stale-bash) yq -i '.bash_version = "other"' "$rejected_artifact" ;;
	stale-shellcheck) yq -i '.shellcheck_version = "other"' "$rejected_artifact" ;;
	stale-argv) yq -i '.bash_argv = ["bash", "-x"]' "$rejected_artifact" ;;
	stale-files) yq -i '.result.sorted_files = .result.sorted_files[:-1]' "$rejected_artifact" ;;
	malformed) printf '%s\n' '[]' >"$rejected_artifact" ;;
	truncated) printf '%s' '{' >"$rejected_artifact" ;;
	schema-invalid) yq -i '.unexpected = true' "$rejected_artifact" ;;
	corrupt) printf '%s\n' 'not-json' >"$rejected_artifact" ;;
	esac
	assert_one_consumer_recomputation "$rejected_artifact" "$run_id"
done

bash_fixture_created=true
printf '%s\n' '#!/usr/bin/env bash' 'if true; then' >"$bash_fixture"
bash_second_fixture_created=true
printf '%s\n' '#!/usr/bin/env bash' 'if false; then' >"$bash_second_fixture"
rm -f -- "$artifact" "$fragment"
set +e
run_repository_validation "$fixture_root/bash.log"
bash_status="$?"
set -e
[[ "$bash_status" -ne 0 ]]
[[ -s "$artifact" ]]
[[ -s "$fragment" ]]
set +e
expected_bash_stderr="$(bash -n "$bash_fixture" 2>&1)"
expected_bash_status="$?"
set -e
[[ "$(yq -r '.result.bash_status' "$artifact")" == "$expected_bash_status" ]]
[[ "$(yq -r '.result.bash_first_failure.file' "$artifact")" == "$bash_fixture" ]]
[[ "$(yq -r '.result.bash_first_failure.stderr' "$artifact")" == "$expected_bash_stderr" ]]
[[ "$(yq -r '.result.shellcheck_status' "$artifact")" == null ]]
[[ "$(yq -r '.shellcheck_version' "$artifact")" == not-run ]]
[[ "$(yq -r '.findings | length' "$artifact")" == 0 ]]
rm -f -- "$bash_fixture" "$bash_second_fixture"
bash_fixture_created=false
bash_second_fixture_created=false

shellcheck_fixture_created=true
{
	printf '%s\n' '#!/usr/bin/env bash'
	printf '%s%s%s\n' 'value=' '$' 1
	printf '%s%s%s\n' 'echo ' '$' value
} >"$shellcheck_fixture"
rm -f -- "$artifact" "$fragment"
set +e
run_repository_validation "$fixture_root/shellcheck.log"
shellcheck_fixture_status="$?"
set -e
[[ "$shellcheck_fixture_status" -ne 0 ]]
[[ -s "$artifact" ]]
[[ -s "$fragment" ]]
[[ "$(yq -r '.result.bash_status' "$artifact")" == 0 ]]
[[ "$(yq -r '.result.shellcheck_status' "$artifact")" == 1 ]]
[[ "$(yq -r '.findings | length' "$artifact")" == 1 ]]
expected_shellcheck_finding="${shellcheck_fixture}"$'\t3\t6\tinfo\t2086\tDouble quote to prevent globbing and word splitting.'
[[ "$(yq -r '.findings[0] | [.file, .line, .column, .level, .code, .message] | @tsv' "$artifact")" == "$expected_shellcheck_finding" ]]
rm -f -- "$shellcheck_fixture" "$artifact" "$fragment"
shellcheck_fixture_created=false

inconsistent_tool_root="$fixture_root/inconsistent-tools"
mkdir -p "$inconsistent_tool_root"
cat >"$inconsistent_tool_root/shellcheck" <<'EOF'
#!/bin/sh
printf '%s\n' '[{"file":"scripts/test/run-ci.sh","line":1,"column":1,"level":"warning","code":2086,"message":"inconsistent fixture"}]'
exit 0
EOF
chmod +x "$inconsistent_tool_root/shellcheck"
set +e
# shellcheck disable=SC2016 # The child Bash expands its injected tool path.
FAKE_TOOL_ROOT="$inconsistent_tool_root" \
	TEST_SHARED_RESULT_DIR="$artifact_root" \
	TEST_RESULT_FRAGMENT_DIR="$fragment_root" \
	TEST_RUN_ID="$run_id" \
	mise exec -- bash -c 'PATH="$FAKE_TOOL_ROOT:$PATH" just repo validate' \
	>"$fixture_root/inconsistent-shellcheck.log" 2>&1
inconsistent_shellcheck_status="$?"
set -e
[[ "$inconsistent_shellcheck_status" -ne 0 ]]
[[ ! -e "$artifact" ]]
[[ ! -e "$fragment" ]]

legacy_fixture_created=true
printf '%s\n' '#!/usr/bin/env bash' 'true' >"$legacy_fixture"
(
	legacy_fixture_created=false
	cleanup
)
[[ "$(cat "$legacy_fixture")" == $'#!/usr/bin/env bash\ntrue' ]]
rm -f -- "$legacy_fixture"
legacy_fixture_created=false
trap - EXIT

if rg -n 'bash -n.*\$|find scripts/secrets scripts/test tests/probes' \
	scripts/test/validate-chainsaw.sh; then
	echo 'Harness must not rerun canonical Bash validation.' >&2
	exit 1
fi
if rg -n 'shellcheck.*--format=json|while .*shellcheck' \
	scripts/test/validate-chainsaw.sh; then
	echo 'Harness must not rerun canonical ShellCheck validation.' >&2
	exit 1
fi
if rg -n 'qbit-manage-policy-shellcheck' \
	scripts/test/validate-chainsaw.sh tests/catalog.yaml; then
	echo 'Focused qbit ShellCheck must remain owned by repository validation.' >&2
	exit 1
fi
git ls-files -co --exclude-standard -- scripts/validate |
	rg -qx 'scripts/validate/qbit-manage-policy.sh'
