#!/bin/sh
set -eu
psql --no-psqlrc --set=ON_ERROR_STOP=1 >/dev/null <<'EOSQL'
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('automation-data:automation_data_backup_error', 0));
DO $fixture$
BEGIN
  IF EXISTS (SELECT FROM pg_database WHERE datname = 'automation_data_backup_error') OR
    EXISTS (SELECT FROM pg_roles WHERE rolname IN ('automation_data_backup_error_owner', 'automation_data_backup_error_migrator', 'automation_data_backup_error_runtime')) THEN
    RAISE EXCEPTION 'backup_fixture_collision';
  END IF;
  IF NOT EXISTS (SELECT FROM platform_operations.managed_domains WHERE domain = 'automation_data_backup_error') THEN
    INSERT INTO platform_operations.managed_domains
      (domain, database_name, owner_role, migrator_role, runtime_role, state, generation)
    VALUES ('automation_data_backup_error', 'automation_data_backup_error', 'automation_data_backup_error_owner',
      'automation_data_backup_error_migrator', 'automation_data_backup_error_runtime', 'error', platform_internal.bump_generation());
  END IF;
  IF EXISTS (SELECT FROM platform_operations.managed_domains WHERE domain = 'automation_data_backup_error'
      AND (has_reached_ready OR state <> 'error')) THEN
    RAISE EXCEPTION 'backup_fixture_not_error';
  END IF;
  PERFORM platform_operations.record_operation_error('automation_data_backup_error', 'acceptance_backup_error');
END;
$fixture$;
COMMIT;
EOSQL
