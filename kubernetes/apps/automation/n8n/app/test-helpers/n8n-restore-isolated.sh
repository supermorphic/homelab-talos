#!/bin/sh
set -eu
printf '%s\n' "$PGHOST" | grep -Eq '^ad-restore-[0-9a-f]{12}-n8n-db$' || {
  echo 'Expected a run-scoped scratch database host.' >&2
  exit 1
}
test "$RESTORE_DATABASE" = n8n || {
  echo 'Expected the isolated n8n database.' >&2
  exit 1
}
# shellcheck source=kubernetes/apps/automation/n8n/app/test-helpers/n8n-restore-common.sh
. "/helpers/n8n-restore-common.sh"
