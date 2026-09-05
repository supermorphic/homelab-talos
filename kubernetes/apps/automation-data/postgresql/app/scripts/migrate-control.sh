#!/bin/sh
set -eu
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-control.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM

# Apply the three revised functions from the same source used by fresh installs.
# No duplicate SQL implementation is maintained for initialized volumes.
{
  cat <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
SET LOCAL ROLE postgres;
DO $guard$
BEGIN
  IF NOT EXISTS (SELECT FROM platform_operations.logical_backup_status
      WHERE completed_at > clock_timestamp() - interval '15 minutes') THEN
    RAISE EXCEPTION 'control_migration_requires_fresh_backup';
  END IF;
  IF EXISTS (SELECT FROM platform_operations.managed_domains
      WHERE domain IN ('postgres', 'template0', 'template1', 'automation_data_control')
        OR state IN ('provisioning', 'rotating')) OR
    EXISTS (SELECT FROM pg_stat_activity WHERE usename = 'automation_data_provisioner'
      AND xact_start IS NOT NULL) THEN
    RAISE EXCEPTION 'control_migration_requires_idle_domains';
  END IF;
  IF EXISTS (SELECT FROM platform_operations.managed_domains m
      WHERE NOT m.has_reached_ready AND (
        EXISTS (SELECT FROM pg_database d WHERE d.datname = m.database_name) OR
        EXISTS (SELECT FROM pg_roles r WHERE r.rolname IN
          (m.owner_role, m.migrator_role, m.runtime_role)))) OR
    EXISTS (SELECT FROM platform_operations.managed_domains m
      JOIN pg_database d ON d.datname = m.database_name
      WHERE NOT EXISTS (SELECT FROM pg_roles r
        WHERE r.rolname = m.owner_role AND r.oid = d.datdba)) THEN
    RAISE EXCEPTION 'control_migration_requires_catalog_review';
  END IF;
  IF EXISTS (SELECT FROM pg_database d
      WHERE d.datname NOT IN ('postgres', 'template0', 'template1', 'automation_data_control')
        AND NOT EXISTS (SELECT FROM platform_operations.managed_domains m
          WHERE m.database_name = d.datname)) OR
    EXISTS (SELECT FROM pg_roles r WHERE r.oid >= 16384
      AND r.rolname ~ '_(owner|migrator|runtime)$'
      AND NOT EXISTS (SELECT FROM platform_operations.managed_domains m
        WHERE r.rolname IN (m.owner_role, m.migrator_role, m.runtime_role))) OR
    EXISTS (SELECT FROM pg_database WHERE
      datname IN ('postgres', 'template0', 'template1', 'automation_data_control')
      AND datdba <> 'postgres'::regrole) THEN
    RAISE EXCEPTION 'control_migration_requires_catalog_review';
  END IF;
END;
$guard$;
SQL
  awk '
    /^CREATE OR REPLACE FUNCTION / {
      selected = ($0 ~ /^CREATE OR REPLACE FUNCTION (platform_internal.assert_domain|platform_operations.provision_domain|platform_operations.record_operation_error)\(/)
    }
    selected { print }
    /^\$function\$;/ { selected = 0 }
  ' "$script_dir/platform-control.sql"
  printf '%s\n' 'COMMIT;'
} >"$temp_dir/control-migration.sql"
# SQL errors can include catalog detail. Expose only a bounded status to Job logs.
if ! psql --no-psqlrc --set=ON_ERROR_STOP=1 --file="$temp_dir/control-migration.sql" >"$temp_dir/migration.log" 2>&1; then
  echo 'control_migration=failed; operator review required' >&2
  exit 1
fi
echo 'control_migration=applied'
