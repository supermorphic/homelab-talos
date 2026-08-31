#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

uv run --locked --no-dev python scripts/test/catalog_compatibility.py

[[ "$(yq -r '.suites[] | select(.metadata.id == "validation.repo-validate") | .native_results.strategy' tests/catalog.yaml)" == native-junit ]]

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-repository-shell-validation.XXXXXX")"
artifact_root="$fixture_root/shared"
fragment_root="$fixture_root/fragments"
artifact="$artifact_root/repository-shell-validation.json"
fragment="$fragment_root/repository-shell-validation.xml"
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

for fixture in "$bash_fixture" "$bash_second_fixture" "$shellcheck_fixture" "$legacy_fixture"; do
	[[ ! -e "$fixture" ]] || {
		echo "Refusing to overwrite existing repository shell fixture: $fixture" >&2
		exit 1
	}
done

cleanup() {
	[[ "$bash_fixture_created" == true ]] && rm -f -- "$bash_fixture"
	[[ "$bash_second_fixture_created" == true ]] && rm -f -- "$bash_second_fixture"
	[[ "$shellcheck_fixture_created" == true ]] && rm -f -- "$shellcheck_fixture"
	rm -rf -- "$fixture_root"
}
trap cleanup EXIT

run_repository_validation() {
	local output="$1"
	TEST_SHARED_RESULT_DIR="$artifact_root" \
		TEST_RESULT_FRAGMENT_DIR="$fragment_root" \
		TEST_RUN_ID="$run_id" \
		mise exec -- just repo validate >"$output" 2>&1
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

printf '%s\n' '#!/usr/bin/env bash' 'true' >"$legacy_fixture"
cleanup
[[ "$(cat "$legacy_fixture")" == $'#!/usr/bin/env bash\ntrue' ]]
rm -f -- "$legacy_fixture"
trap - EXIT
