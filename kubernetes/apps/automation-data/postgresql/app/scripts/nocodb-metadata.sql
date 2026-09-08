CREATE OR REPLACE FUNCTION platform_operations.provision_nocodb_metadata(
  p_metadata_password text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
BEGIN
  IF p_metadata_password IS NULL OR length(p_metadata_password) < 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_generated_password';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:nocodb', 0));
  -- Failed provisioning can leave a registry row before database creation.
  -- Previously ready domains must still exist; validate before remote DDL commits.
  IF EXISTS (
    SELECT FROM platform_operations.managed_domains AS domain
    WHERE domain.has_reached_ready AND NOT EXISTS (
      SELECT FROM pg_database WHERE datname = domain.database_name
    )
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'managed_database_missing';
  END IF;
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'nocodb_metadata') THEN
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
        'nocodb_metadata', p_metadata_password)
    );
  ELSE
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
        'nocodb_metadata', p_metadata_password)
    );
  END IF;
  IF EXISTS (SELECT FROM pg_database WHERE datname = 'nocodb') THEN
    PERFORM platform_internal.exec_in_database(
      'automation_data_control', format('ALTER DATABASE %I OWNER TO %I', 'nocodb', 'nocodb_metadata')
    );
  ELSE
    PERFORM platform_internal.exec_in_database(
      'automation_data_control', format('CREATE DATABASE %I OWNER %I', 'nocodb', 'nocodb_metadata')
    );
  END IF;
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format('REVOKE CONNECT ON DATABASE %1$I FROM PUBLIC; GRANT CONNECT ON DATABASE %1$I TO %2$I; REVOKE ALL ON DATABASE %3$I FROM %2$I',
      'nocodb', 'nocodb_metadata', 'automation_data_control')
  );
  FOR managed IN
    SELECT domain.* FROM platform_operations.managed_domains AS domain
    JOIN pg_database AS database ON database.datname = domain.database_name
  LOOP
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format('REVOKE ALL ON DATABASE %I FROM %I', managed.database_name, 'nocodb_metadata')
    );
  END LOOP;
END;
$function$;
