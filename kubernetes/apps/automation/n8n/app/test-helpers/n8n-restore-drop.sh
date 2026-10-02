#!/bin/sh
set -eu
printf '%s\n' "${RESTORE_DATABASE:-}" | grep -Eq '^n8n_restore_[0-9a-f]{12}$' || {
  printf '%s\n' 'restore_failure=database-name' >&2
  exit 1
}

dropdb --if-exists --force "$RESTORE_DATABASE"
database_count="$(PGOPTIONS="-c restore.database=$RESTORE_DATABASE" psql --dbname=postgres --tuples-only --no-align --command="SELECT count(*) FROM pg_database WHERE datname = current_setting('restore.database')")"
test "$database_count" = 0
