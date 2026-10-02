#!/usr/bin/env bash

# Keep the canonical programs with the Git-managed immutable fixture.
n8n_restore_helper_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/kubernetes/apps/automation/n8n/app/test-helpers"

n8n_restore_job_command() {
  cat "$n8n_restore_helper_directory/n8n-restore-common.sh"
}

n8n_drop_restore_database_job_command() {
  cat "$n8n_restore_helper_directory/n8n-restore-drop.sh"
}
