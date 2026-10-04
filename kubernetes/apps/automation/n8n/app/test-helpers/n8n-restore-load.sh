#!/bin/sh
set -eu
printf '%s\n' "${RESTORE_DATABASE:-}" | grep -Eq '^n8n_restore_[0-9a-f]{12}$' || {
  printf '%s\n' 'restore_failure=database-name' >&2
  exit 1
}

exec /bin/sh -eu /helpers/n8n-restore-common.sh
