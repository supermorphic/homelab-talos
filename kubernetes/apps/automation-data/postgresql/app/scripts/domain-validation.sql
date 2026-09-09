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
  -- Exercise runtime CRUD only on this run-owned probe, independently of the
  -- application's default grants. Never grant access to application tables.
  PERFORM public.dblink_exec(
    connection_name,
    format('GRANT SELECT, INSERT, UPDATE, DELETE ON app.%I TO %I', probe_table, p_runtime)
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
  -- Application migrations may narrow direct grants or use controlled functions.
  -- The platform validates a ceiling, not mandatory access to every object.
  runtime_privileges_valid := platform_internal.query_boolean(
    managed.database_name,
    format(
      $sql$
      SELECT
        has_schema_privilege(%1$L, 'app', 'USAGE') AND
        NOT has_schema_privilege(%1$L, 'app', 'CREATE,USAGE WITH GRANT OPTION') AND
        NOT EXISTS (
          SELECT FROM pg_class AS relation
          JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = 'app'
            AND CASE WHEN relation.relkind IN ('r', 'p', 'v', 'm', 'f') THEN (
              has_table_privilege(%1$L, relation.oid,
                'TRUNCATE,REFERENCES,TRIGGER,MAINTAIN,SELECT WITH GRANT OPTION,INSERT WITH GRANT OPTION,UPDATE WITH GRANT OPTION,DELETE WITH GRANT OPTION')
              OR has_any_column_privilege(%1$L, relation.oid,
                'REFERENCES,SELECT WITH GRANT OPTION,INSERT WITH GRANT OPTION,UPDATE WITH GRANT OPTION')
            ) ELSE false END
        ) AND
        NOT EXISTS (
          SELECT FROM pg_class AS relation
          JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = 'app'
            AND CASE WHEN relation.relkind = 'S' THEN
              has_sequence_privilege(%1$L, relation.oid,
                'USAGE WITH GRANT OPTION,SELECT WITH GRANT OPTION,UPDATE WITH GRANT OPTION')
            ELSE false END
        ) AND
        NOT EXISTS (
          SELECT FROM pg_proc AS routine
          JOIN pg_namespace AS namespace ON namespace.oid = routine.pronamespace
          WHERE namespace.nspname = 'app'
            AND has_function_privilege(%1$L, routine.oid, 'EXECUTE WITH GRANT OPTION')
        )
      $sql$,
      managed.runtime_role
    )
  );
  default_privileges_valid := platform_internal.query_boolean(
    managed.database_name,
    format(
      $sql$
      SELECT NOT EXISTS (
        SELECT FROM pg_default_acl AS defaults
        CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS acl
        WHERE defaults.defaclnamespace IN (
            0, (SELECT oid FROM pg_namespace WHERE nspname = 'app')
          )
          AND defaults.defaclobjtype IN ('r', 'S', 'f')
          AND CASE WHEN acl.grantee = 0 THEN true
            ELSE pg_has_role(%1$L, acl.grantee, 'USAGE') END
          AND (
            acl.is_grantable OR
            (defaults.defaclobjtype = 'r' AND
              acl.privilege_type NOT IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE')) OR
            (defaults.defaclobjtype = 'S' AND
              acl.privilege_type NOT IN ('USAGE', 'SELECT', 'UPDATE')) OR
            (defaults.defaclobjtype = 'f' AND acl.privilege_type <> 'EXECUTE')
          )
      )
      $sql$,
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
