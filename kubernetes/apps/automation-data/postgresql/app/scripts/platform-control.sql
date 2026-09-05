CREATE EXTENSION IF NOT EXISTS dblink;

CREATE SCHEMA platform_operations AUTHORIZATION postgres;
CREATE SCHEMA platform_internal AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA platform_operations FROM PUBLIC;
REVOKE ALL ON SCHEMA platform_internal FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA platform_operations
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA platform_internal
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE platform_operations.platform_generation (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0)
);
INSERT INTO platform_operations.platform_generation (singleton, generation)
VALUES (true, 0);

CREATE TABLE platform_operations.managed_domains (
  domain text PRIMARY KEY CHECK (domain ~ '^[a-z][a-z0-9_]{0,47}$'),
  database_name text NOT NULL,
  owner_role text NOT NULL,
  migrator_role text NOT NULL,
  runtime_role text NOT NULL,
  state text NOT NULL CHECK (state IN ('provisioning', 'ready', 'rotating', 'error')),
  has_reached_ready boolean NOT NULL DEFAULT false,
  generation bigint NOT NULL DEFAULT 1 CHECK (generation > 0),
  migrator_credential_id text,
  runtime_credential_id text,
  migrator_credential_updated_at timestamp with time zone,
  runtime_credential_updated_at timestamp with time zone,
  operation_started_at timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamp with time zone NOT NULL DEFAULT clock_timestamp(),
  error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{0,63}$'),
  CHECK (database_name = domain),
  CHECK (owner_role = domain || '_owner'),
  CHECK (migrator_role = domain || '_migrator'),
  CHECK (runtime_role = domain || '_runtime')
);

CREATE TABLE platform_operations.logical_backup_status (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  completed_at timestamp with time zone NOT NULL,
  bundle text NOT NULL CHECK (bundle ~ '^automation-data-[0-9]{8}T[0-9]{6}Z$'),
  checksum character(64) NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$'),
  database_set_hash character(64) NOT NULL CHECK (database_set_hash ~ '^[0-9a-f]{64}$')
);

CREATE OR REPLACE FUNCTION platform_internal.assert_domain(p_domain text)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  IF p_domain IS NULL OR p_domain !~ '^[a-z][a-z0-9_]{0,47}$' OR
    p_domain IN ('postgres', 'template0', 'template1', 'automation_data_control') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_domain';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.bump_generation()
RETURNS bigint
LANGUAGE sql
SET search_path = pg_catalog, platform_operations
AS $function$
  UPDATE platform_operations.platform_generation
  SET generation = generation + 1
  WHERE singleton = true
  RETURNING generation;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.exec_in_database(p_database text, p_sql text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  connection_name text := format('automation_data_%s', pg_backend_pid());
BEGIN
  PERFORM public.dblink_connect(
    connection_name,
    format('dbname=%L user=%L', p_database, 'postgres')
  );
  PERFORM public.dblink_exec(connection_name, p_sql);
  PERFORM public.dblink_disconnect(connection_name);
EXCEPTION WHEN OTHERS THEN
  BEGIN
    PERFORM public.dblink_disconnect(connection_name);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RAISE;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.reconcile_database(
  p_domain text,
  p_owner text,
  p_migrator text,
  p_runtime text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  PERFORM platform_internal.exec_in_database(
    p_domain,
    format(
      $sql$
      REVOKE CREATE ON SCHEMA public FROM PUBLIC;
      CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION %1$I;
      ALTER SCHEMA app OWNER TO %1$I;
      REVOKE ALL ON SCHEMA app FROM PUBLIC;
      GRANT USAGE ON SCHEMA app TO %3$I;
      GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO %3$I;
      GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA app TO %3$I;
      ALTER DEFAULT PRIVILEGES FOR ROLE %1$I IN SCHEMA app
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %3$I;
      ALTER DEFAULT PRIVILEGES FOR ROLE %1$I IN SCHEMA app
        GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %3$I;
      $sql$,
      p_owner,
      p_migrator,
      p_runtime
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.query_boolean(p_database text, p_sql text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  connection_name text := format('automation_data_query_%s', pg_backend_pid());
  result boolean;
BEGIN
  PERFORM public.dblink_connect(
    connection_name,
    format('dbname=%L user=%L', p_database, 'postgres')
  );
  SELECT response.value INTO STRICT result
  FROM public.dblink(connection_name, p_sql) AS response(value boolean);
  PERFORM public.dblink_disconnect(connection_name);
  RETURN result;
EXCEPTION WHEN OTHERS THEN
  BEGIN
    PERFORM public.dblink_disconnect(connection_name);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RAISE;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.provision_domain(p_domain text, p_migrator_password text, p_runtime_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  owner_name text;
  migrator_name text;
  runtime_name text;
  existing platform_operations.managed_domains%ROWTYPE;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_migrator_password IS NULL OR length(p_migrator_password) < 32 OR
    p_runtime_password IS NULL OR length(p_runtime_password) < 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_generated_password';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));

  owner_name := p_domain || '_owner';
  migrator_name := p_domain || '_migrator';
  runtime_name := p_domain || '_runtime';
  SELECT * INTO existing
  FROM platform_operations.managed_domains
  WHERE domain = p_domain;
  IF FOUND AND existing.has_reached_ready THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'ready_domain_requires_reconcile';
  END IF;

  IF FOUND THEN
    IF existing.state <> 'error' AND NOT (
      existing.state = 'provisioning' AND
      existing.operation_started_at < clock_timestamp() - interval '30 minutes'
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'domain_operation_in_progress';
    END IF;
  ELSIF EXISTS (SELECT FROM pg_database WHERE datname = p_domain) OR
    EXISTS (SELECT FROM pg_roles WHERE rolname IN (owner_name, migrator_name, runtime_name)) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'unmanaged_object_collision';
  END IF;

  -- The outer advisory lock serializes callers. Do not lock or write the registry
  -- in this transaction before the independent connection commits the reservation.
  -- A caller rollback must not erase ownership of independently committed DDL.
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format($sql$
      INSERT INTO platform_operations.managed_domains (
        domain, database_name, owner_role, migrator_role, runtime_role,
        state, generation
      ) VALUES (%1$L, %1$L, %2$L, %3$L, %4$L,
        'provisioning', platform_internal.bump_generation())
      ON CONFLICT (domain) DO UPDATE SET
        state = 'provisioning', generation = EXCLUDED.generation,
        operation_started_at = clock_timestamp(), updated_at = clock_timestamp(),
        error_code = NULL
      $sql$, p_domain, owner_name, migrator_name, runtime_name)
  );

  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = owner_name) THEN
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', owner_name)
      );
    ELSE
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('ALTER ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', owner_name)
      );
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = migrator_name) THEN
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD %L', migrator_name, p_migrator_password)
      );
    ELSE
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD %L', migrator_name, p_migrator_password)
      );
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = runtime_name) THEN
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD %L', runtime_name, p_runtime_password)
      );
    ELSE
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD %L', runtime_name, p_runtime_password)
      );
    END IF;
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format('GRANT %I TO %I WITH INHERIT FALSE, SET TRUE', owner_name, migrator_name)
    );

    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = p_domain) THEN
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('CREATE DATABASE %I OWNER %I', p_domain, owner_name)
      );
    ELSE
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('ALTER DATABASE %I OWNER TO %I', p_domain, owner_name)
      );
    END IF;
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format(
        'REVOKE CONNECT ON DATABASE %1$I FROM PUBLIC; GRANT CONNECT ON DATABASE %1$I TO %2$I, %3$I, %4$I; REVOKE CONNECT ON DATABASE automation_data_control FROM %2$I, %3$I, %4$I',
        p_domain,
        owner_name,
        migrator_name,
        runtime_name
      )
    );
    PERFORM platform_internal.reconcile_database(
      p_domain,
      owner_name,
      migrator_name,
      runtime_name
    );

  EXCEPTION WHEN OTHERS THEN
    -- Only a call that committed a reservation may mark its DDL attempt failed.
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format($sql$
        UPDATE platform_operations.managed_domains
        SET state = 'error', generation = platform_internal.bump_generation(),
          updated_at = clock_timestamp(), error_code = 'provisioning_failed'
        WHERE domain = %L
        $sql$, p_domain)
    );
    RAISE;
  END;

  RETURN jsonb_build_object(
    'domain', p_domain,
    'database', p_domain,
    'schema', 'app',
    'ownerRole', owner_name,
    'migratorRole', migrator_name,
    'runtimeRole', runtime_name,
    'state', 'provisioning'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.reconcile_domain(p_domain text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT managed
  FROM platform_operations.managed_domains
  WHERE domain = p_domain
  FOR UPDATE;
  IF NOT managed.has_reached_ready OR
    managed.migrator_credential_id IS NULL OR managed.runtime_credential_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'domain_not_ready';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = managed.owner_role) OR
    NOT EXISTS (SELECT FROM pg_roles WHERE rolname = managed.migrator_role) OR
    NOT EXISTS (SELECT FROM pg_roles WHERE rolname = managed.runtime_role) OR
    NOT EXISTS (SELECT FROM pg_database WHERE datname = managed.database_name) THEN
    UPDATE platform_operations.managed_domains
    SET state = 'error', error_code = 'missing_ready_object', updated_at = clock_timestamp()
    WHERE domain = p_domain;
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'missing_ready_object';
  END IF;

  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format('ALTER ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', managed.owner_role)
  );
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT', managed.migrator_role)
  );
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT', managed.runtime_role)
  );
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format('GRANT %I TO %I WITH INHERIT FALSE, SET TRUE', managed.owner_role, managed.migrator_role)
  );
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format(
      'ALTER DATABASE %1$I OWNER TO %2$I; REVOKE CONNECT ON DATABASE %1$I FROM PUBLIC; GRANT CONNECT ON DATABASE %1$I TO %2$I, %3$I, %4$I; REVOKE CONNECT ON DATABASE automation_data_control FROM %2$I, %3$I, %4$I',
      managed.database_name,
      managed.owner_role,
      managed.migrator_role,
      managed.runtime_role
    )
  );
  PERFORM platform_internal.reconcile_database(
    managed.database_name,
    managed.owner_role,
    managed.migrator_role,
    managed.runtime_role
  );

  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_domains
  SET state = 'ready', generation = next_generation, updated_at = clock_timestamp(), error_code = NULL
  WHERE domain = p_domain;
  RETURN jsonb_build_object(
    'domain', p_domain,
    'database', managed.database_name,
    'schema', 'app',
    'ownerRole', managed.owner_role,
    'migratorRole', managed.migrator_role,
    'runtimeRole', managed.runtime_role,
    'migratorCredentialId', managed.migrator_credential_id,
    'runtimeCredentialId', managed.runtime_credential_id,
    'state', 'ready',
    'passwordsUnchanged', true
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_domain_credentials(p_domain text, p_migrator_credential_id text, p_runtime_credential_id text, p_migrator_updated_at timestamptz, p_runtime_updated_at timestamptz)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_migrator_credential_id IS NULL OR p_migrator_credential_id = '' OR
    p_runtime_credential_id IS NULL OR p_runtime_credential_id = '' OR
    p_migrator_updated_at IS NULL OR p_runtime_updated_at IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_credential_metadata';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  PERFORM 1 FROM platform_operations.managed_domains WHERE domain = p_domain FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'domain_not_found';
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_domains
  SET state = 'ready',
      has_reached_ready = true,
      generation = next_generation,
      migrator_credential_id = p_migrator_credential_id,
      runtime_credential_id = p_runtime_credential_id,
      migrator_credential_updated_at = p_migrator_updated_at,
      runtime_credential_updated_at = p_runtime_updated_at,
      updated_at = clock_timestamp(),
      error_code = NULL
  WHERE domain = p_domain;
  RETURN jsonb_build_object('domain', p_domain, 'state', 'ready');
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.rotate_domain_credential(p_domain text, p_credential text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  target_role text;
  target_credential_id text;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_credential NOT IN ('migrator', 'runtime') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_credential_kind';
  END IF;
  IF p_password IS NULL OR length(p_password) < 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_generated_password';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT managed
  FROM platform_operations.managed_domains
  WHERE domain = p_domain
  FOR UPDATE;
  -- An explicit rotation is also the repair path after an interrupted attempt. The
  -- durable credential IDs remain authoritative after a domain has reached ready once.
  IF NOT managed.has_reached_ready THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'domain_not_ready';
  END IF;
  IF p_credential = 'migrator' THEN
    target_role := managed.migrator_role;
    target_credential_id := managed.migrator_credential_id;
  ELSE
    target_role := managed.runtime_role;
    target_credential_id := managed.runtime_credential_id;
  END IF;
  IF target_credential_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'credential_not_recorded';
  END IF;
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format('ALTER ROLE %I PASSWORD %L', target_role, p_password)
  );
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_domains
  SET state = 'rotating', generation = next_generation,
      operation_started_at = clock_timestamp(), updated_at = clock_timestamp(), error_code = NULL
  WHERE domain = p_domain;
  RETURN jsonb_build_object(
    'domain', p_domain,
    'credential', p_credential,
    'role', target_role,
    'credentialId', target_credential_id,
    'state', 'rotating'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_operation_error(p_domain text, p_error_code text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_]{0,63}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_error_code';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  PERFORM 1 FROM platform_operations.managed_domains WHERE domain = p_domain FOR UPDATE;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_domains
  SET state = 'error', generation = next_generation,
      updated_at = clock_timestamp(), error_code = p_error_code
  WHERE domain = p_domain;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.validate_role_behavior(
  p_database text,
  p_owner text,
  p_migrator text,
  p_runtime text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  connection_name text := format('automation_data_permission_%s', pg_backend_pid());
  probe_table text := format('__automation_data_permission_probe_%s', pg_backend_pid());
  denied_table text := format('__automation_data_permission_denied_%s', pg_backend_pid());
  command_status text;
  runtime_crud_valid boolean := false;
  runtime_ddl_denied boolean := false;
  runtime_owner_assumption_denied boolean := false;
  runtime_role_management_denied boolean := false;
BEGIN
  PERFORM public.dblink_connect(
    connection_name,
    format('dbname=%L user=%L', p_database, 'postgres')
  );

  PERFORM public.dblink_exec(
    connection_name,
    format('SET SESSION AUTHORIZATION %I', p_migrator)
  );
  PERFORM public.dblink_exec(connection_name, format('SET ROLE %I', p_owner));
  PERFORM public.dblink_exec(
    connection_name,
    format('CREATE TABLE app.%I (id bigint PRIMARY KEY, value text NOT NULL)', probe_table)
  );
  PERFORM public.dblink_exec(
    connection_name,
    format('ALTER TABLE app.%I ADD COLUMN note text', probe_table)
  );
  PERFORM public.dblink_exec(connection_name, 'RESET ROLE');
  PERFORM public.dblink_exec(connection_name, 'RESET SESSION AUTHORIZATION');

  PERFORM public.dblink_exec(
    connection_name,
    format('SET SESSION AUTHORIZATION %I', p_runtime)
  );
  PERFORM public.dblink_exec(
    connection_name,
    format('INSERT INTO app.%I (id, value) VALUES (1, %L)', probe_table, 'created')
  );
  PERFORM public.dblink_exec(
    connection_name,
    format('UPDATE app.%I SET value = %L WHERE id = 1', probe_table, 'updated')
  );
  SELECT response.value INTO STRICT runtime_crud_valid
  FROM public.dblink(
    connection_name,
    format('SELECT count(*) = 1 AND min(value) = %L FROM app.%I', 'updated', probe_table)
  ) AS response(value boolean);
  PERFORM public.dblink_exec(
    connection_name,
    format('DELETE FROM app.%I WHERE id = 1', probe_table)
  );

  command_status := public.dblink_exec(
    connection_name,
    format('CREATE TABLE app.%I (id bigint)', denied_table),
    false
  );
  runtime_ddl_denied := command_status = 'ERROR';
  command_status := public.dblink_exec(
    connection_name,
    format('SET ROLE %I', p_owner),
    false
  );
  runtime_owner_assumption_denied := command_status = 'ERROR';
  PERFORM public.dblink_exec(connection_name, 'RESET SESSION AUTHORIZATION');

  SELECT NOT role.rolcreaterole AND NOT role.rolcreatedb AND NOT role.rolsuper
  INTO STRICT runtime_role_management_denied
  FROM pg_roles AS role
  WHERE role.rolname = p_runtime;

  PERFORM public.dblink_exec(
    connection_name,
    format('DROP TABLE app.%I', probe_table)
  );
  PERFORM public.dblink_exec(
    connection_name,
    format('DROP TABLE IF EXISTS app.%I', denied_table)
  );
  PERFORM public.dblink_disconnect(connection_name);

  RETURN jsonb_build_object(
    'migratorDdlValid', true,
    'runtimeCrudValid', runtime_crud_valid,
    'runtimeDdlDenied', runtime_ddl_denied,
    'runtimeOwnerAssumptionDenied', runtime_owner_assumption_denied,
    'runtimeRoleManagementDenied', runtime_role_management_denied
  );
EXCEPTION WHEN OTHERS THEN
  BEGIN
    PERFORM public.dblink_exec(connection_name, 'RESET ROLE', false);
    PERFORM public.dblink_exec(connection_name, 'RESET SESSION AUTHORIZATION', false);
    PERFORM public.dblink_exec(
      connection_name,
      format('DROP TABLE IF EXISTS app.%I', probe_table),
      false
    );
    PERFORM public.dblink_exec(
      connection_name,
      format('DROP TABLE IF EXISTS app.%I', denied_table),
      false
    );
    PERFORM public.dblink_disconnect(connection_name);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RAISE;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.validate_domain(p_domain text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  runtime_privileges_valid boolean;
  default_privileges_valid boolean;
  cross_domain_connect_denied boolean;
  role_behavior jsonb;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT managed
  FROM platform_operations.managed_domains
  WHERE domain = p_domain;
  runtime_privileges_valid := platform_internal.query_boolean(
    managed.database_name,
    format(
      $sql$
      SELECT
        has_schema_privilege(%1$L, 'app', 'USAGE') AND
        NOT has_schema_privilege(%1$L, 'app', 'CREATE') AND
        COALESCE((
          SELECT bool_and(
            has_table_privilege(
              %1$L,
              format('%%I.%%I', schemaname, tablename),
              'SELECT,INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
              %1$L,
              format('%%I.%%I', schemaname, tablename),
              'TRUNCATE,REFERENCES,TRIGGER'
            )
          )
          FROM pg_tables
          WHERE schemaname = 'app'
        ), true) AND
        COALESCE((
          SELECT bool_and(has_sequence_privilege(
            %1$L,
            format('%%I.%%I', sequence_schema, sequence_name),
            'USAGE,SELECT,UPDATE'
          ))
          FROM information_schema.sequences
          WHERE sequence_schema = 'app'
        ), true)
      $sql$,
      managed.runtime_role
    )
  );
  default_privileges_valid := platform_internal.query_boolean(
    managed.database_name,
    format(
      $sql$
      SELECT
        COALESCE((
          SELECT array_agg(DISTINCT acl.privilege_type ORDER BY acl.privilege_type) =
            ARRAY['DELETE', 'INSERT', 'SELECT', 'UPDATE']::text[]
          FROM pg_default_acl AS defaults
          JOIN pg_namespace AS namespace ON namespace.oid = defaults.defaclnamespace
          CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS acl
          WHERE defaults.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = %1$L)
            AND namespace.nspname = 'app'
            AND defaults.defaclobjtype = 'r'
            AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %2$L)
        ), false) AND
        COALESCE((
          SELECT array_agg(DISTINCT acl.privilege_type ORDER BY acl.privilege_type) =
            ARRAY['SELECT', 'UPDATE', 'USAGE']::text[]
          FROM pg_default_acl AS defaults
          JOIN pg_namespace AS namespace ON namespace.oid = defaults.defaclnamespace
          CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS acl
          WHERE defaults.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = %1$L)
            AND namespace.nspname = 'app'
            AND defaults.defaclobjtype = 'S'
            AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %2$L)
        ), false)
      $sql$,
      managed.owner_role,
      managed.runtime_role
    )
  );
  SELECT NOT EXISTS (
    SELECT 1
    FROM platform_operations.managed_domains AS other
    JOIN pg_database AS database ON database.datname = other.database_name
    WHERE other.domain <> p_domain
      AND (
        has_database_privilege(managed.migrator_role, database.datname, 'CONNECT') OR
        has_database_privilege(managed.runtime_role, database.datname, 'CONNECT')
      )
  ) INTO cross_domain_connect_denied;
  role_behavior := platform_internal.validate_role_behavior(
    managed.database_name,
    managed.owner_role,
    managed.migrator_role,
    managed.runtime_role
  );
  RETURN jsonb_build_object(
    'domain', p_domain,
    'database', managed.database_name,
    'migratorCredentialId', managed.migrator_credential_id,
    'runtimeCredentialId', managed.runtime_credential_id,
    'migratorCredentialUpdatedAt', managed.migrator_credential_updated_at,
    'runtimeCredentialUpdatedAt', managed.runtime_credential_updated_at,
    'ownerNoLogin', COALESCE((SELECT NOT rolcanlogin FROM pg_roles WHERE rolname = managed.owner_role), false),
    'migratorCanSetOwner', pg_has_role(managed.migrator_role, managed.owner_role, 'SET'),
    'runtimeCannotSetOwner', NOT pg_has_role(managed.runtime_role, managed.owner_role, 'SET'),
    'migratorControlConnectDenied', NOT has_database_privilege(managed.migrator_role, 'automation_data_control', 'CONNECT'),
    'runtimeControlConnectDenied', NOT has_database_privilege(managed.runtime_role, 'automation_data_control', 'CONNECT'),
    'migratorDomainConnectAllowed', has_database_privilege(managed.migrator_role, managed.database_name, 'CONNECT'),
    'runtimeDomainConnectAllowed', has_database_privilege(managed.runtime_role, managed.database_name, 'CONNECT'),
    'runtimePrivilegesValid', runtime_privileges_valid,
    'defaultPrivilegesValid', default_privileges_valid,
    'crossDomainConnectDenied', cross_domain_connect_denied,
    'migratorDdlValid', (role_behavior->>'migratorDdlValid')::boolean,
    'runtimeCrudValid', (role_behavior->>'runtimeCrudValid')::boolean,
    'runtimeDdlDenied', (role_behavior->>'runtimeDdlDenied')::boolean,
    'runtimeOwnerAssumptionDenied', (role_behavior->>'runtimeOwnerAssumptionDenied')::boolean,
    'runtimeRoleManagementDenied', (role_behavior->>'runtimeRoleManagementDenied')::boolean,
    'state', managed.state
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.capture_backup_state()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT jsonb_build_object(
    'generation', (SELECT generation FROM platform_operations.platform_generation WHERE singleton),
    'registry', COALESCE(
      (SELECT jsonb_agg(to_jsonb(managed) ORDER BY managed.domain)
       FROM platform_operations.managed_domains AS managed),
      '[]'::jsonb
    )
  );
$function$;

CREATE OR REPLACE FUNCTION platform_operations.publish_backup(p_bundle text, p_checksum text, p_database_set_hash text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  IF p_bundle IS NULL OR p_bundle !~ '^automation-data-[0-9]{8}T[0-9]{6}Z$' OR
    p_checksum IS NULL OR p_checksum !~ '^[0-9a-f]{64}$' OR
    p_database_set_hash IS NULL OR p_database_set_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_backup_publication';
  END IF;
  INSERT INTO platform_operations.logical_backup_status (
    singleton,
    completed_at,
    bundle,
    checksum,
    database_set_hash
  ) VALUES (
    true,
    clock_timestamp(),
    p_bundle,
    p_checksum,
    p_database_set_hash
  ) ON CONFLICT (singleton) DO UPDATE SET
    completed_at = EXCLUDED.completed_at,
    bundle = EXCLUDED.bundle,
    checksum = EXCLUDED.checksum,
    database_set_hash = EXCLUDED.database_set_hash;
END;
$function$;

REVOKE ALL ON ALL TABLES IN SCHEMA platform_operations FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA platform_operations FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA platform_internal FROM PUBLIC;

GRANT USAGE ON SCHEMA platform_operations TO automation_data_provisioner;
GRANT SELECT ON platform_operations.managed_domains TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.provision_domain(text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.reconcile_domain(text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_domain_credentials(text, text, text, timestamptz, timestamptz) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.rotate_domain_credential(text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_operation_error(text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.validate_domain(text) TO automation_data_provisioner;

GRANT USAGE ON SCHEMA platform_operations TO automation_data_backup;
GRANT SELECT ON platform_operations.managed_domains,
  platform_operations.platform_generation,
  platform_operations.logical_backup_status TO automation_data_backup;
GRANT EXECUTE ON FUNCTION platform_operations.capture_backup_state() TO automation_data_backup;
GRANT EXECUTE ON FUNCTION platform_operations.publish_backup(text, text, text) TO automation_data_backup;

GRANT USAGE ON SCHEMA platform_operations TO automation_data_exporter;
GRANT SELECT ON platform_operations.managed_domains,
  platform_operations.platform_generation,
  platform_operations.logical_backup_status TO automation_data_exporter;
