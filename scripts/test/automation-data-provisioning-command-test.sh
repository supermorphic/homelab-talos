#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
scenario="$repo_root/scripts/test/scenarios/automation-data-provisioning.sh"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-provisioning-command-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

sed -n '/^error_job_manifest()/,/^}/p' "$scenario" >"$temp_dir/error-job-function.sh"
# shellcheck disable=SC1091 # Extract the production renderer without running the live scenario.
source "$temp_dir/error-job-function.sh"

export error_job='automation-data-error-123456789abc'
export run_hash='123456789abc'
error_job_manifest >"$temp_dir/error-job.yaml"

command="$(yq -r '.spec.template.spec.containers[] | select(.name == "record-error") | .args[0]' \
  "$temp_dir/error-job.yaml")"

mkdir "$temp_dir/bin"
cat >"$temp_dir/bin/psql" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$PSQL_ARGS_FILE"
EOF
chmod +x "$temp_dir/bin/psql"

PSQL_ARGS_FILE="$temp_dir/psql-args" PATH="$temp_dir/bin:$PATH" /bin/sh -ceu "$command"
mapfile -t actual_args <"$temp_dir/psql-args"
expected_args=(
  '--no-psqlrc'
  '--set=ON_ERROR_STOP=1'
  "--command=SELECT platform_operations.record_operation_error('issue317_backup_error', 'acceptance_backup_error');"
)
[[ "${#actual_args[@]}" -eq "${#expected_args[@]}" ]] || {
  echo 'The rendered error Job did not preserve PostgreSQL string arguments.' >&2
  printf 'expected: %s\nactual:   %s\n' "${expected_args[*]}" "${actual_args[*]}" >&2
  exit 1
}
for index in "${!expected_args[@]}"; do
  [[ "${actual_args[$index]}" == "${expected_args[$index]}" ]] || {
    echo 'The rendered error Job did not preserve PostgreSQL string arguments.' >&2
    printf 'expected argument %s: %s\nactual argument %s:   %s\n' \
      "$index" "${expected_args[$index]}" "$index" "${actual_args[$index]}" >&2
    exit 1
  }
done

echo 'automation-data provisioning command test: PASS'
