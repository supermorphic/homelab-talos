#!/usr/bin/env bash

# Return the same Git-owned permission oracle packaged for scratch restore Jobs.
automation_data_permission_restore_helpers() {
  cat kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-permissions.sh
}
