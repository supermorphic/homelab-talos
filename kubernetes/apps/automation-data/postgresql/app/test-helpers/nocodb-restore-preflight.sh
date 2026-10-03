#!/bin/sh
set -eu
# shellcheck source=kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-validation.sh
. "/helpers/restore-validation.sh"
# shellcheck source=kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-selection.sh
. "/helpers/restore-selection.sh" >/dev/null
for required_database in nocodb automation_data_control automation_data_acceptance; do
  encoded="$(printf '%s' "$required_database" | base64 | tr -d '\n')"
  grep -Fxq "$encoded" /tmp/restore-expected-databases-base64 || restore_fail required-database-missing
done
printf 'selected_bundle=%s\n' "$selected_name"
