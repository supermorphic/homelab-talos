#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/test/lib/n8n-restore-command.sh
source scripts/test/lib/n8n-restore-command.sh

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-restore-command-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
mkdir -p "$temp_dir/backups"

restore_command="$(n8n_restore_job_command)"
fixture_command="${restore_command//\/backups/$temp_dir/backups}"
restore_status=0
restore_output="$(RESTORE_DATABASE=n8n_restore_fixture \
  /bin/sh -ceu "$fixture_command" 2>&1)" || restore_status="$?"
[[ "$restore_status" -eq 1 ]] || {
  echo "Restore command returned status $restore_status instead of 1." >&2
  exit 1
}
[[ "$restore_output" == $'restore_stage=artifact-selection\nrestore_failure=artifact-selection' ]] || {
  echo 'Restore command did not report the exact artifact-selection failure.' >&2
  exit 1
}

for stage in artifact-selection database-absence database-create dump-restore \
  schema-contract workflow-contract credential-contract credential-binding complete; do
  rg -Fq "restore_stage=$stage" <<<"$restore_command" || {
    echo "Restore command is missing stage marker: $stage" >&2
    exit 1
  }
done

echo 'n8n restore command stage diagnostics passed.'
