-- Access-session objects for specification 036, installed after the 026-nocodb-v4
-- platform revision. Rerunning is idempotent. Never assigns passwords: the issuer and
-- sweeper stay NOLOGIN until their own guarded credential steps enable them.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
SET LOCAL ROLE postgres;

DO $guard$
BEGIN
  IF current_database() <> 'automation_data_control' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'access_sessions_wrong_database';
  END IF;
  IF platform_operations.read_platform_revision() <> '026-nocodb-v4' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'unknown_platform_revision';
  END IF;
END;
$guard$;

-- The issuer and sweeper only execute fixed functions. The marker comment prevents
-- adopting an unrelated role with the same name.
DO $roles$
DECLARE
  identity text;
BEGIN
  FOREACH identity IN ARRAY ARRAY['automation_data_openbao_issuer',
      'automation_data_session_sweeper'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = identity) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT '
        || 'NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 4', identity);
      EXECUTE format('COMMENT ON ROLE %I IS %L', identity, 'homelab:access-sessions:v1');
    ELSIF pg_catalog.shobj_description((SELECT oid FROM pg_catalog.pg_roles
        WHERE rolname = identity), 'pg_authid') IS DISTINCT FROM 'homelab:access-sessions:v1' THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'access_session_role_collision';
    END IF;
    -- Statement text can contain SCRAM verifiers; keep it out of logs, including errors.
    EXECUTE format('ALTER ROLE %I SET log_statement = %L', identity, 'none');
    EXECUTE format('ALTER ROLE %I SET log_min_error_statement = %L', identity, 'panic');
    EXECUTE format('GRANT CONNECT ON DATABASE automation_data_control TO %I', identity);
  END LOOP;
END;
$roles$;

CREATE TABLE IF NOT EXISTS platform_operations.managed_access_capabilities (
  domain text NOT NULL REFERENCES platform_operations.managed_domains(domain),
  capability text NOT NULL CHECK (capability ~ '^[a-z][a-z0-9_]{0,23}$'),
  role_name text NOT NULL UNIQUE,
  schemas text[] NOT NULL CHECK (cardinality(schemas) BETWEEN 1 AND 16),
  access_mode text NOT NULL CHECK (access_mode IN ('read')),
  max_ttl_seconds integer NOT NULL CHECK (max_ttl_seconds BETWEEN 60 AND 600),
  state text NOT NULL CHECK (state IN ('ready', 'suspended')),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (domain, capability),
  CHECK (role_name = 'cap_' || md5(domain || ':' || capability) || '_access')
);

CREATE TABLE IF NOT EXISTS platform_operations.managed_dynamic_logins (
  role_name text PRIMARY KEY CHECK (role_name ~ '^v-[a-z0-9-]{1,40}-[a-z0-9]{20}$'),
  role_oid oid NOT NULL,
  domain text NOT NULL,
  capability text NOT NULL,
  issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  revoked_by text CHECK (revoked_by IN ('openbao', 'sweeper', 'operator', 'restore')),
  FOREIGN KEY (domain, capability)
    REFERENCES platform_operations.managed_access_capabilities(domain, capability),
  CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);
CREATE INDEX IF NOT EXISTS managed_dynamic_logins_active_expiry
  ON platform_operations.managed_dynamic_logins (expires_at) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS platform_operations.access_session_sweeps (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  completed_at timestamptz NOT NULL,
  revoked_count integer NOT NULL CHECK (revoked_count >= 0),
  failed_count integer NOT NULL CHECK (failed_count >= 0)
);

REVOKE ALL ON TABLE platform_operations.managed_access_capabilities,
  platform_operations.managed_dynamic_logins,
  platform_operations.access_session_sweeps FROM PUBLIC;

-- Report one capability role's effective authority against the read-only ceiling.
-- Callers validate input and hold the domain lock.
CREATE OR REPLACE FUNCTION platform_internal.access_capability_checks(
  p_domain text, p_capability text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations, pg_temp
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  registered platform_operations.managed_access_capabilities%ROWTYPE;
  role_valid boolean;
  members_valid boolean;
  database_valid boolean;
  schema_valid boolean;
  object_valid boolean;
  routine_valid boolean;
  defaults_valid boolean;
  ownership_denied boolean;
  grant_options_denied boolean;
  public_privileges_denied boolean;
BEGIN
  SELECT * INTO STRICT managed FROM platform_operations.managed_domains
    WHERE domain = p_domain;
  SELECT * INTO STRICT registered FROM platform_operations.managed_access_capabilities
    WHERE domain = p_domain AND capability = p_capability;
  SELECT NOT role.rolcanlogin AND NOT role.rolsuper AND NOT role.rolcreatedb
      AND NOT role.rolcreaterole AND NOT role.rolreplication AND NOT role.rolbypassrls
      AND NOT role.rolinherit
      AND NOT EXISTS (SELECT FROM pg_auth_members AS member WHERE member.member = role.oid)
    INTO role_valid FROM pg_roles AS role WHERE role.rolname = registered.role_name;
  -- Only active issuer-created logins may be members, with inheritance but no SET or
  -- ADMIN option, and no other membership.
  SELECT NOT EXISTS (
      SELECT FROM pg_auth_members AS member
      JOIN pg_roles AS capability_role ON capability_role.oid = member.roleid
      WHERE capability_role.rolname = registered.role_name
        AND NOT (member.inherit_option AND NOT member.set_option AND NOT member.admin_option
          AND EXISTS (
            SELECT FROM platform_operations.managed_dynamic_logins AS login
            WHERE login.role_oid = member.member AND login.revoked_at IS NULL
              AND login.domain = p_domain AND login.capability = p_capability)
          AND (SELECT count(*) FROM pg_auth_members AS other
            WHERE other.member = member.member) = 1)
    ) INTO members_valid;
  SELECT COALESCE(bool_and(CASE WHEN database.datname = managed.database_name
      THEN has_database_privilege(registered.role_name, database.datname, 'CONNECT')
        AND NOT has_database_privilege(registered.role_name, database.datname, 'CREATE')
        AND NOT has_database_privilege(registered.role_name, database.datname, 'TEMP')
      ELSE NOT has_database_privilege(registered.role_name, database.datname, 'CONNECT') END),
      false)
    INTO database_valid FROM pg_database AS database WHERE database.datallowconn;
  schema_valid := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT NOT EXISTS (
        SELECT FROM unnest(%2$L::text[]) AS registered(name)
        WHERE to_regnamespace(registered.name) IS NULL
          OR NOT has_schema_privilege(%1$L, registered.name, 'USAGE')
      ) AND NOT EXISTS (
        SELECT FROM pg_namespace AS namespace
        WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema')
          AND (has_schema_privilege(%1$L, namespace.oid, 'CREATE') OR (
            has_schema_privilege(%1$L, namespace.oid, 'USAGE')
            AND namespace.nspname <> ALL (%2$L::text[])))
      )
    $sql$, registered.role_name, registered.schemas));
  object_valid := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT EXISTS (
        SELECT FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = ANY (%2$L::text[])
          AND relation.relkind IN ('r','p','v','m')
          AND has_table_privilege(%1$L, relation.oid, 'SELECT')
      ) AND NOT EXISTS (
        SELECT FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname NOT IN ('pg_catalog','information_schema')
          AND CASE WHEN relation.relkind IN ('r','p','v','m','f') THEN
            (namespace.nspname <> ALL (%2$L::text[]) AND
              (has_table_privilege(%1$L, relation.oid, 'SELECT') OR
               has_any_column_privilege(%1$L, relation.oid, 'SELECT')))
            OR has_table_privilege(%1$L, relation.oid,
                'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
            OR has_any_column_privilege(%1$L, relation.oid, 'INSERT,UPDATE,REFERENCES')
          WHEN relation.relkind = 'S' THEN
            has_sequence_privilege(%1$L, relation.oid, 'USAGE,UPDATE')
            OR (namespace.nspname <> ALL (%2$L::text[]) AND
              has_sequence_privilege(%1$L, relation.oid, 'SELECT'))
          ELSE false END
      )
    $sql$, registered.role_name, registered.schemas));
  -- A definer routine is the only way a login without write grants can write.
  routine_valid := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT NOT EXISTS (
        SELECT FROM pg_proc AS routine JOIN pg_namespace AS namespace
          ON namespace.oid = routine.pronamespace
        WHERE namespace.nspname NOT IN ('pg_catalog','information_schema')
          AND routine.prosecdef
          AND has_function_privilege(%1$L, routine.oid, 'EXECUTE')
      )
    $sql$, registered.role_name));
  defaults_valid := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT NOT EXISTS (
        SELECT FROM pg_default_acl AS defaults
        CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS acl
        WHERE acl.grantee IN (0, (SELECT oid FROM pg_roles WHERE rolname = %1$L))
      )
    $sql$, registered.role_name));
  ownership_denied := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT NOT EXISTS (SELECT FROM pg_namespace WHERE nspowner =
        (SELECT oid FROM pg_roles WHERE rolname = %1$L))
      AND NOT EXISTS (SELECT FROM pg_class WHERE relowner =
        (SELECT oid FROM pg_roles WHERE rolname = %1$L))
      AND NOT EXISTS (SELECT FROM pg_proc WHERE proowner =
        (SELECT oid FROM pg_roles WHERE rolname = %1$L))
      AND NOT EXISTS (SELECT FROM pg_largeobject_metadata WHERE lomowner =
        (SELECT oid FROM pg_roles WHERE rolname = %1$L))
    $sql$, registered.role_name));
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
    $sql$, registered.role_name));
  public_privileges_denied := platform_internal.public_data_privileges_denied(
    managed.database_name);
  RETURN jsonb_build_object(
    'roleValid', COALESCE(role_valid, false),
    'membersValid', COALESCE(members_valid, false),
    'databaseIsolationValid', COALESCE(database_valid, false),
    'schemaPrivilegesValid', COALESCE(schema_valid, false),
    'objectPrivilegesValid', COALESCE(object_valid, false),
    'routinePrivilegesValid', COALESCE(routine_valid, false),
    'defaultPrivilegesValid', COALESCE(defaults_valid, false),
    'ownershipDenied', COALESCE(ownership_denied, false),
    'grantOptionsDenied', COALESCE(grant_options_denied, false),
    'publicPrivilegesDenied', COALESCE(public_privileges_denied, false)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.assert_access_capability_identity(
  p_domain text, p_capability text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations, pg_temp
AS $function$
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_capability IS NULL OR p_capability !~ '^[a-z][a-z0-9_]{0,23}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_access_capability';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.access_capability_result(
  p_domain text, p_capability text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations, pg_temp
AS $function$
  SELECT jsonb_build_object(
    'domain', registered.domain, 'capability', registered.capability,
    'role', registered.role_name, 'schemas', to_jsonb(registered.schemas),
    'accessMode', registered.access_mode, 'maxTtlSeconds', registered.max_ttl_seconds,
    'state', registered.state)
  FROM platform_operations.managed_access_capabilities AS registered
  WHERE registered.domain = p_domain AND registered.capability = p_capability;
$function$;

-- Create the stable grant target for one read capability. Consumers grant authority
-- through reviewed migrations; registration grants nothing.
CREATE OR REPLACE FUNCTION platform_operations.register_access_capability(
  p_domain text, p_capability text, p_schemas text[], p_max_ttl_seconds integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations, pg_temp
AS $function$
DECLARE
  existing platform_operations.managed_access_capabilities%ROWTYPE;
  canonical_schemas text[];
  generated_role text;
BEGIN
  PERFORM platform_internal.assert_access_capability_identity(p_domain, p_capability);
  IF p_max_ttl_seconds IS NULL OR p_max_ttl_seconds NOT BETWEEN 60 AND 600 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_access_capability_ttl';
  END IF;
  SELECT array_agg(DISTINCT schema_name ORDER BY schema_name) INTO canonical_schemas
    FROM unnest(p_schemas) AS schema_name;
  IF p_schemas IS NULL OR cardinality(p_schemas) NOT BETWEEN 1 AND 16 OR
     cardinality(canonical_schemas) <> cardinality(p_schemas) OR
     EXISTS (SELECT FROM unnest(p_schemas) AS schema_name
       WHERE schema_name IS NULL OR schema_name !~ '^[a-z][a-z0-9_]{0,47}$' OR
         schema_name IN ('public', 'pg_catalog', 'information_schema') OR
         schema_name LIKE 'pg\_%' ESCAPE '\') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_access_capability_schemas';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  IF NOT EXISTS (SELECT FROM platform_operations.managed_domains
      WHERE domain = p_domain AND state = 'ready') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'access_capability_domain_not_ready';
  END IF;
  generated_role := 'cap_' || md5(p_domain || ':' || p_capability) || '_access';
  SELECT * INTO existing FROM platform_operations.managed_access_capabilities
    WHERE domain = p_domain AND capability = p_capability FOR UPDATE;
  IF FOUND THEN
    IF existing.schemas IS DISTINCT FROM canonical_schemas OR
       existing.max_ttl_seconds <> p_max_ttl_seconds THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'access_capability_binding_conflict';
    END IF;
    RETURN platform_internal.access_capability_result(p_domain, p_capability);
  END IF;
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = generated_role) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'access_capability_role_collision';
  END IF;
  EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE '
    || 'NOINHERIT NOREPLICATION NOBYPASSRLS', generated_role);
  INSERT INTO platform_operations.managed_access_capabilities
    (domain, capability, role_name, schemas, access_mode, max_ttl_seconds, state)
  VALUES (p_domain, p_capability, generated_role, canonical_schemas, 'read',
    p_max_ttl_seconds, 'ready');
  PERFORM platform_internal.bump_generation();
  RETURN platform_internal.access_capability_result(p_domain, p_capability);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.validate_access_capability(
  p_domain text, p_capability text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations, pg_temp
AS $function$
DECLARE
  checks jsonb;
BEGIN
  PERFORM platform_internal.assert_access_capability_identity(p_domain, p_capability);
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  IF NOT EXISTS (SELECT FROM platform_operations.managed_access_capabilities
      WHERE domain = p_domain AND capability = p_capability) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'unknown_access_capability';
  END IF;
  checks := platform_internal.access_capability_checks(p_domain, p_capability);
  RETURN platform_internal.access_capability_result(p_domain, p_capability)
    || jsonb_build_object('valid',
      (SELECT bool_and(value = 'true'::jsonb) FROM jsonb_each(checks)))
    || checks;
END;
$function$;

-- Verify ownership, function hardening, exact EXECUTE grants, and the dedicated
-- issuer and sweeper roles.
CREATE OR REPLACE FUNCTION platform_internal.assert_access_session_contract()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations, pg_temp
AS $function$
DECLARE
  expected record;
  actual text[];
BEGIN
  FOR expected IN SELECT * FROM (VALUES
    ('platform_operations.register_access_capability(text,text,text[],integer)'::regprocedure,
      ARRAY['automation_data_provisioner']),
    ('platform_operations.validate_access_capability(text,text)'::regprocedure,
      ARRAY['automation_data_provisioner']),
    ('platform_internal.access_capability_checks(text,text)'::regprocedure, ARRAY[]::text[]),
    ('platform_internal.assert_access_capability_identity(text,text)'::regprocedure,
      ARRAY[]::text[]),
    ('platform_internal.access_capability_result(text,text)'::regprocedure, ARRAY[]::text[]),
    ('platform_internal.assert_access_session_contract()'::regprocedure, ARRAY[]::text[])
  ) AS contract(routine, grantees) LOOP
    SELECT COALESCE(array_agg(CASE WHEN privilege.grantee = 0 THEN 'PUBLIC'
        ELSE grantee_role.rolname::text END ORDER BY 1), ARRAY[]::text[])
      INTO actual
    FROM pg_proc AS routine
    CROSS JOIN LATERAL aclexplode(COALESCE(routine.proacl,
      acldefault('f', routine.proowner))) AS privilege
    LEFT JOIN pg_roles AS grantee_role ON grantee_role.oid = privilege.grantee
    WHERE routine.oid = expected.routine AND privilege.grantee <> routine.proowner;
    IF actual IS DISTINCT FROM expected.grantees OR NOT EXISTS (
        SELECT FROM pg_proc AS routine
        WHERE routine.oid = expected.routine AND routine.prosecdef
          AND routine.proowner = 'postgres'::regrole
          AND 'search_path=pg_catalog, platform_operations, pg_temp' = ANY (routine.proconfig)) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'invalid_access_session_contract';
    END IF;
  END LOOP;
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'platform_operations'
      AND tablename IN ('managed_access_capabilities', 'managed_dynamic_logins',
        'access_session_sweeps') AND tableowner <> 'postgres') OR
    (SELECT count(*) FROM pg_tables WHERE schemaname = 'platform_operations'
      AND tablename IN ('managed_access_capabilities', 'managed_dynamic_logins',
        'access_session_sweeps')) <> 3 OR
    has_table_privilege('public', 'platform_operations.managed_access_capabilities', 'SELECT') OR
    has_table_privilege('public', 'platform_operations.managed_dynamic_logins', 'SELECT') OR
    has_table_privilege('public', 'platform_operations.access_session_sweeps', 'SELECT') OR
    (SELECT count(*) FROM pg_roles AS role
      WHERE role.rolname IN ('automation_data_openbao_issuer', 'automation_data_session_sweeper')
        AND NOT role.rolsuper AND NOT role.rolcreatedb AND NOT role.rolcreaterole
        AND NOT role.rolinherit AND NOT role.rolreplication AND NOT role.rolbypassrls
        AND pg_catalog.shobj_description(role.oid, 'pg_authid') = 'homelab:access-sessions:v1'
        AND NOT EXISTS (SELECT FROM pg_auth_members AS member
          WHERE member.member = role.oid OR member.roleid = role.oid)) <> 2 THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'invalid_access_session_contract';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION platform_internal.access_capability_checks(text, text),
  platform_internal.assert_access_capability_identity(text, text),
  platform_internal.access_capability_result(text, text),
  platform_internal.assert_access_session_contract(),
  platform_operations.register_access_capability(text, text, text[], integer),
  platform_operations.validate_access_capability(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform_operations.register_access_capability(text, text, text[], integer),
  platform_operations.validate_access_capability(text, text) TO automation_data_provisioner;

SELECT platform_internal.assert_access_session_contract();
COMMIT;
SELECT 'access_sessions_contract_valid=true';
