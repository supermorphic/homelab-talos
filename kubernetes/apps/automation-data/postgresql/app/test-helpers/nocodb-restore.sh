#!/bin/sh
set -eu
printf '%s\n' "$PGHOST" | grep -Eq '^nc-restore-[0-9a-f]{12}-db$' || {
  echo 'Expected a run-scoped scratch database host.' >&2
  exit 1
}
# shellcheck source=kubernetes/apps/automation-data/postgresql/app/test-helpers/automation-data-restore.sh
. "/helpers/automation-data-restore.sh"
# shellcheck source=kubernetes/apps/automation-data/postgresql/app/test-helpers/nocodb-restore-assertions.sh
. "/helpers/nocodb-restore-assertions.sh"
