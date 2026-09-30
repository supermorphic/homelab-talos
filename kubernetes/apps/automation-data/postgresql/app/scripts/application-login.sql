-- Registration state for optional application logins in an existing managed database.
-- Fixed lifecycle functions are added with the complete v3 control upgrade.
SET ROLE postgres;

CREATE TABLE IF NOT EXISTS platform_operations.managed_application_logins (
  domain text NOT NULL REFERENCES platform_operations.managed_domains(domain),
  application text NOT NULL CHECK (application ~ '^[a-z][a-z0-9_]{0,23}$'),
  schema_name text NOT NULL CHECK (schema_name ~ '^[a-z][a-z0-9_]{0,47}$'),
  role_name text NOT NULL,
  state text NOT NULL CHECK (state IN (
    'awaiting_grants', 'activating', 'ready', 'rotating', 'error'
  )),
  operation_id uuid,
  credential_generation bigint NOT NULL DEFAULT 0 CHECK (credential_generation >= 0),
  operation_started_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{0,63}$'),
  PRIMARY KEY (domain, application),
  UNIQUE (role_name),
  CHECK (role_name = 'app_' || md5(domain || ':' || application) || '_integration')
);
REVOKE ALL ON platform_operations.managed_application_logins FROM PUBLIC;

CREATE OR REPLACE FUNCTION platform_operations.validate_application_login(
  p_domain text, p_application text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  login platform_operations.managed_application_logins%ROWTYPE;
  role_valid boolean;
  database_valid boolean;
  schema_valid boolean;
  object_valid boolean;
  routine_valid boolean;
  defaults_valid boolean;
  ownership_denied boolean;
  grant_options_denied boolean;
  public_privileges_denied boolean;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_application IS NULL OR p_application !~ '^[a-z][a-z0-9_]{0,23}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_application';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT managed FROM platform_operations.managed_domains
    WHERE domain = p_domain;
  SELECT * INTO STRICT login FROM platform_operations.managed_application_logins
    WHERE domain = p_domain AND application = p_application;
  IF login.role_name <> 'app_' || md5(p_domain || ':' || p_application) || '_integration' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_application_role';
  END IF;
  SELECT NOT role.rolsuper AND NOT role.rolcreatedb AND NOT role.rolcreaterole
      AND NOT role.rolreplication AND NOT role.rolbypassrls AND NOT role.rolinherit
      AND role.rolcanlogin = (login.state IN ('ready', 'rotating'))
      AND NOT EXISTS (
        SELECT FROM pg_auth_members AS member
        WHERE member.member = role.oid OR member.roleid = role.oid
      )
    INTO role_valid FROM pg_roles AS role WHERE role.rolname = login.role_name;
  SELECT COALESCE(bool_and(CASE WHEN database.datname = managed.database_name
      THEN has_database_privilege(login.role_name, database.datname, 'CONNECT')
        AND NOT has_database_privilege(login.role_name, database.datname, 'CREATE')
        AND NOT has_database_privilege(login.role_name, database.datname, 'TEMP')
      ELSE NOT has_database_privilege(login.role_name, database.datname, 'CONNECT') END), false)
    INTO database_valid FROM pg_database AS database WHERE database.datallowconn;
  schema_valid := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT has_schema_privilege(%1$L, %2$L, 'USAGE')
        AND NOT has_schema_privilege(%1$L, %2$L, 'CREATE')
        AND NOT EXISTS (
          SELECT FROM pg_namespace AS namespace
          WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema', %2$L)
            AND (has_schema_privilege(%1$L, namespace.oid, 'USAGE') OR
                 has_schema_privilege(%1$L, namespace.oid, 'CREATE'))
        )
    $sql$, login.role_name, login.schema_name));
  object_valid := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT EXISTS (
        SELECT FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = %2$L AND relation.relkind IN ('r','p','v','m')
          AND has_table_privilege(%1$L, relation.oid, 'SELECT')
      ) AND NOT EXISTS (
        SELECT FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname NOT IN ('pg_catalog','information_schema')
          AND CASE WHEN relation.relkind IN ('r','p','v','m','f') THEN
            (namespace.nspname <> %2$L AND
              (has_table_privilege(%1$L, relation.oid,
                'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR
               has_any_column_privilege(%1$L, relation.oid,
                'SELECT,INSERT,UPDATE,REFERENCES')))
            OR has_table_privilege(%1$L, relation.oid,
                'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
            OR has_any_column_privilege(%1$L, relation.oid,
                'INSERT,UPDATE,REFERENCES')
          WHEN relation.relkind = 'S' THEN
            has_sequence_privilege(%1$L, relation.oid, 'USAGE,SELECT,UPDATE')
          ELSE false END
      )
    $sql$, login.role_name, login.schema_name));
  routine_valid := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT EXISTS (
        SELECT FROM pg_proc AS routine JOIN pg_namespace AS namespace
          ON namespace.oid = routine.pronamespace
        CROSS JOIN LATERAL aclexplode(COALESCE(routine.proacl,
          acldefault('f', routine.proowner))) AS acl
        WHERE namespace.nspname = %2$L
          AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L)
          AND acl.privilege_type = 'EXECUTE'
          AND has_function_privilege(%1$L, routine.oid, 'EXECUTE')
      ) AND NOT EXISTS (
        SELECT FROM pg_proc AS routine JOIN pg_namespace AS namespace
          ON namespace.oid = routine.pronamespace
        WHERE namespace.nspname NOT IN ('pg_catalog','information_schema')
          AND (namespace.nspname <> %2$L OR EXISTS (
            SELECT FROM aclexplode(COALESCE(routine.proacl,
              acldefault('f', routine.proowner))) AS acl
            WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE'
          ))
          AND has_function_privilege(%1$L, routine.oid, 'EXECUTE')
      )
    $sql$, login.role_name, login.schema_name));
  defaults_valid := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT NOT EXISTS (
        SELECT FROM pg_default_acl AS defaults
        CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS acl
        WHERE acl.grantee IN (0, (SELECT oid FROM pg_roles WHERE rolname = %1$L))
      )
    $sql$, login.role_name));
  ownership_denied := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT NOT EXISTS (SELECT FROM pg_namespace WHERE nspowner =
        (SELECT oid FROM pg_roles WHERE rolname = %1$L))
      AND NOT EXISTS (SELECT FROM pg_class WHERE relowner =
        (SELECT oid FROM pg_roles WHERE rolname = %1$L))
      AND NOT EXISTS (SELECT FROM pg_proc WHERE proowner =
        (SELECT oid FROM pg_roles WHERE rolname = %1$L))
    $sql$, login.role_name));
  grant_options_denied := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT NOT EXISTS (
        SELECT FROM pg_database AS database
        CROSS JOIN LATERAL aclexplode(COALESCE(database.datacl,
          acldefault('d', database.datdba))) AS acl
        WHERE acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L)
          AND acl.is_grantable
      ) AND NOT EXISTS (
        SELECT FROM pg_class AS relation
        CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl,
          acldefault((CASE WHEN relation.relkind = 'S' THEN 'S' ELSE 'r' END)::"char",
            relation.relowner))) AS acl
        WHERE acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L)
          AND acl.is_grantable
      ) AND NOT EXISTS (
        SELECT FROM pg_attribute AS attribute
        CROSS JOIN LATERAL aclexplode(attribute.attacl) AS acl
        WHERE acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L)
          AND acl.is_grantable
      ) AND NOT EXISTS (
        SELECT FROM pg_namespace AS namespace
        CROSS JOIN LATERAL aclexplode(COALESCE(namespace.nspacl,
          acldefault('n', namespace.nspowner))) AS acl
        WHERE acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L)
          AND acl.is_grantable
      ) AND NOT EXISTS (
        SELECT FROM pg_proc AS routine
        CROSS JOIN LATERAL aclexplode(COALESCE(routine.proacl,
          acldefault('f', routine.proowner))) AS acl
        WHERE acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L)
          AND acl.is_grantable
      )
    $sql$, login.role_name));
  public_privileges_denied := platform_internal.public_data_privileges_denied(
    managed.database_name);
  RETURN jsonb_build_object(
    'domain', p_domain, 'application', p_application, 'role', login.role_name,
    'state', login.state, 'valid', COALESCE(role_valid, false) AND database_valid
      AND schema_valid AND object_valid AND routine_valid AND defaults_valid
      AND ownership_denied AND grant_options_denied AND public_privileges_denied,
    'roleValid', COALESCE(role_valid, false), 'databaseIsolationValid', database_valid,
    'schemaPrivilegesValid', schema_valid, 'objectPrivilegesValid', object_valid,
    'routinePrivilegesValid', routine_valid, 'defaultPrivilegesValid', defaults_valid,
    'ownershipDenied', ownership_denied, 'grantOptionsDenied', grant_options_denied,
    'publicPrivilegesDenied', public_privileges_denied
  );
END;
$function$;
REVOKE EXECUTE ON FUNCTION platform_operations.validate_application_login(text, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform_operations.validate_application_login(text, text)
  TO automation_data_provisioner;
