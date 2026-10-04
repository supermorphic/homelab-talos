#!/bin/sh
set -eu
printf '%s\n' "$PGHOST" | grep -Eq '^(ad|nc)-restore-[0-9a-f]{12}-db$' || {
  echo 'Expected a run-scoped scratch database host.' >&2
  exit 1
}
# shellcheck source=kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-validation.sh
. "/helpers/restore-validation.sh"
# shellcheck source=kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-permissions.sh
. "/helpers/restore-permissions.sh"
# shellcheck source=kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-selection.sh
. "/helpers/restore-selection.sh"
# shellcheck source=kubernetes/apps/automation-data/postgresql/app/test-helpers/restore-body.sh
. "/helpers/restore-body.sh"
