\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '1s';

SELECT pg_try_advisory_xact_lock(
  hashtextextended('automation-data:platform-upgrade:026-nocodb-v1', 0)
) AS upgrade_lock_acquired \gset
\if :upgrade_lock_acquired
\else
  DO $locked$
  BEGIN
    RAISE EXCEPTION USING ERRCODE = '55P03', MESSAGE = 'platform_upgrade_already_running';
  END;
  $locked$;
\endif

SELECT (to_regclass('platform_operations.platform_schema_revision') IS NULL) AS apply_upgrade \gset

DO $validation$
DECLARE
  revision_table regclass := to_regclass('platform_operations.platform_schema_revision');
  recorded_revision text;
  old_table_names text[];
  old_function_names text[];
  old_capture jsonb;
BEGIN
  IF revision_table IS NOT NULL THEN
    EXECUTE 'SELECT CASE WHEN count(*) = 1 THEN min(revision) ELSE NULL END FROM platform_operations.platform_schema_revision'
      INTO recorded_revision;
    IF recorded_revision IS DISTINCT FROM '026-nocodb-v1' THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'unknown_platform_revision';
    END IF;
    IF to_regprocedure('platform_operations.read_platform_revision()') IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'incomplete_nocodb_extension';
    END IF;
    PERFORM platform_operations.read_platform_revision();
    RETURN;
  END IF;

  SELECT array_agg(class.relname ORDER BY class.relname)
  INTO old_table_names
  FROM pg_class AS class
  JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
  WHERE namespace.nspname = 'platform_operations' AND class.relkind = 'r';
  IF old_table_names IS DISTINCT FROM ARRAY[
      'logical_backup_status', 'managed_domains', 'platform_generation'
    ]::text[] THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'incompatible_pre_extension_tables';
  END IF;

  SELECT array_agg(procedure.proname ORDER BY procedure.proname)
  INTO old_function_names
  FROM pg_proc AS procedure
  JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
  WHERE namespace.nspname = 'platform_operations';
  IF old_function_names IS DISTINCT FROM ARRAY[
      'capture_backup_state', 'provision_domain', 'publish_backup',
      'reconcile_domain', 'record_domain_credentials', 'record_operation_error',
      'rotate_domain_credential', 'validate_domain'
    ]::text[] THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'incompatible_pre_extension_functions';
  END IF;

  IF to_regprocedure('platform_operations.provision_domain(text,text,text)') IS NULL OR
    to_regprocedure('platform_operations.reconcile_domain(text)') IS NULL OR
    to_regprocedure('platform_operations.record_domain_credentials(text,text,text,timestamptz,timestamptz)') IS NULL OR
    to_regprocedure('platform_operations.rotate_domain_credential(text,text,text)') IS NULL OR
    to_regprocedure('platform_operations.record_operation_error(text,text)') IS NULL OR
    to_regprocedure('platform_operations.validate_domain(text)') IS NULL OR
    to_regprocedure('platform_operations.capture_backup_state()') IS NULL OR
    to_regprocedure('platform_operations.publish_backup(text,text,text)') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'incompatible_pre_extension_signatures';
  END IF;

  old_capture := platform_operations.capture_backup_state();
  IF jsonb_typeof(old_capture->'registry') <> 'array' OR
    jsonb_typeof(old_capture->'generation') <> 'number' OR
    (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(old_capture) AS key) IS DISTINCT FROM
      ARRAY['generation', 'registry']::text[] THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'incompatible_pre_extension_backup_state';
  END IF;

  IF to_regclass('platform_operations.managed_nocodb_sources') IS NOT NULL OR
    EXISTS (
      SELECT 1
      FROM pg_proc AS procedure
      JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname IN ('platform_operations', 'platform_internal')
        AND procedure.proname LIKE '%nocodb%'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'partial_nocodb_extension';
  END IF;
END;
$validation$;

\if :apply_upgrade
  \ir nocodb-extension.sql
\endif

SELECT platform_internal.assert_nocodb_extension_contract();
-- Reconcile the fixed metadata function on installed v1 as well as fresh installs.
-- Keep the schema/backup format revision; advance backup freshness only on change.
SELECT md5(prosrc) AS previous_metadata_body FROM pg_proc
WHERE oid = 'platform_operations.provision_nocodb_metadata(text)'::regprocedure \gset
SET LOCAL ROLE postgres;
\ir nocodb-metadata.sql
UPDATE platform_operations.platform_schema_revision
SET installed_at = clock_timestamp()
WHERE singleton AND :'previous_metadata_body' <> (
  SELECT md5(prosrc) FROM pg_proc
  WHERE oid = 'platform_operations.provision_nocodb_metadata(text)'::regprocedure
);
SELECT platform_internal.assert_nocodb_extension_contract();
COMMIT;

SELECT 'installed_revision=' || platform_operations.read_platform_revision();
SELECT 'managed_domain_count=' || count(*)::text
FROM platform_operations.managed_domains;
SELECT 'managed_domain_identity_hash=' || md5(COALESCE(string_agg(
  concat_ws('|', domain, database_name, owner_role, migrator_role, runtime_role),
  E'\n' ORDER BY domain
), ''))
FROM platform_operations.managed_domains;
SELECT 'extension_contract_valid=true';
