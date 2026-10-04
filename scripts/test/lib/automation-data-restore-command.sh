#!/usr/bin/env bash

# shellcheck source=scripts/test/lib/automation-data-permission-restore.sh
source scripts/test/lib/automation-data-permission-restore.sh

automation_data_restore_job_command() {
  cat kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-validation.sh
  automation_data_permission_restore_helpers
  cat kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-selection.sh
  printf '\n'
  cat kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-body.sh
}
