-- Restricted metadata only; install after the pinned application schema exists.
-- Shared by fresh installation and attended upgrade. Never assign passwords here.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '20s';
DO $shape$
BEGIN
  IF current_database() <> 'automation_data_control' OR session_user <> 'postgres' OR
    EXISTS (SELECT FROM (VALUES
      ('platform_operations','managed_domains','domain','text'),
      ('platform_operations','managed_domains','database_name','text'),
      ('platform_operations','managed_domains','owner_role','text'),
      ('platform_operations','managed_domains','migrator_role','text'),
      ('platform_operations','managed_domains','runtime_role','text'),
      ('platform_operations','managed_domains','state','text'),
      ('platform_operations','managed_domains','generation','bigint'),
      ('platform_operations','managed_domains','migrator_credential_id','text'),
      ('platform_operations','managed_domains','runtime_credential_id','text'),
      ('platform_operations','managed_domains','migrator_credential_updated_at','timestamp with time zone'),
      ('platform_operations','managed_domains','runtime_credential_updated_at','timestamp with time zone'),
      ('platform_operations','managed_domains','updated_at','timestamp with time zone'),
      ('platform_operations','managed_nocodb_schema_mappings','domain','text'),
      ('platform_operations','managed_nocodb_schema_mappings','pair','text'),
      ('platform_operations','managed_nocodb_schema_mappings','reader_schema','text'),
      ('platform_operations','managed_nocodb_schema_mappings','operator_schema','text'),
      ('platform_operations','managed_nocodb_sources','domain','text'),
      ('platform_operations','managed_nocodb_sources','pair','text'),
      ('platform_operations','managed_nocodb_sources','access_kind','text'),
      ('platform_operations','managed_nocodb_sources','role_name','text'),
      ('platform_operations','managed_nocodb_sources','base_id','text'),
      ('platform_operations','managed_nocodb_sources','integration_id','text'),
      ('platform_operations','managed_nocodb_sources','source_id','text'),
      ('platform_operations','managed_nocodb_sources','state','text'),
      ('platform_operations','managed_nocodb_sources','operation','text'),
      ('platform_operations','managed_nocodb_sources','generation','bigint'),
      ('platform_operations','managed_nocodb_sources','credential_generation','bigint'),
      ('platform_operations','managed_nocodb_sources','updated_at','timestamp with time zone'),
      ('platform_operations','managed_nocodb_sources','validated_at','timestamp with time zone'),
      ('platform_operations','managed_nocodb_sources','error_code','text'),
      ('platform_operations','nocodb_source_operations','domain','text'),
      ('platform_operations','nocodb_source_operations','pair','text'),
      ('platform_operations','nocodb_source_operations','operation_id','uuid'),
      ('platform_operations','nocodb_source_operations','operation','text'),
      ('platform_operations','nocodb_source_operations','access_kind','text'),
      ('platform_operations','nocodb_source_operations','generation','bigint'),
      ('platform_operations','nocodb_source_operations','phase','text'),
      ('platform_operations','managed_application_logins','domain','text'),
      ('platform_operations','managed_application_logins','application','text'),
      ('platform_operations','managed_application_logins','schema_name','text'),
      ('platform_operations','managed_application_logins','role_name','text'),
      ('platform_operations','managed_application_logins','state','text'),
      ('platform_operations','managed_application_logins','operation','text'),
      ('platform_operations','managed_application_logins','operation_id','uuid'),
      ('platform_operations','managed_application_logins','credential_generation','bigint'),
      ('platform_operations','managed_application_logins','updated_at','timestamp with time zone'),
      ('platform_operations','managed_application_logins','error_code','text')
    ) required(schema_name,table_name,column_name,data_type)
    WHERE NOT EXISTS (SELECT FROM information_schema.columns c
      WHERE c.table_schema=required.schema_name AND c.table_name=required.table_name
        AND c.column_name=required.column_name AND c.data_type=required.data_type)) THEN
    RAISE EXCEPTION USING MESSAGE='discovery_installation_precondition_failed';
  END IF;
END;
$shape$;
DO $roles$
DECLARE identity text;
BEGIN
  FOREACH identity IN ARRAY ARRAY['automation_data_inventory','automation_data_inventory_projection'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname=identity) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS', identity);
      EXECUTE format('COMMENT ON ROLE %I IS %L', identity, 'homelab:credential-discovery:v1');
    ELSIF pg_catalog.shobj_description((SELECT oid FROM pg_catalog.pg_roles WHERE rolname=identity),'pg_authid') IS DISTINCT FROM 'homelab:credential-discovery:v1' THEN
      RAISE EXCEPTION USING MESSAGE='discovery_role_collision';
    END IF;
    IF EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE rolname=identity AND
      ((rolname='automation_data_inventory_projection' AND rolcanlogin) OR rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls)) OR
      EXISTS (SELECT FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles r ON r.oid=m.member OR r.oid=m.roleid WHERE r.rolname=identity) THEN
      RAISE EXCEPTION USING MESSAGE='discovery_role_authority_invalid';
    END IF;
  END LOOP;
END;
$roles$;
DO $schema$
BEGIN
  IF EXISTS (SELECT FROM pg_catalog.pg_namespace n JOIN pg_catalog.pg_roles r ON r.oid=n.nspowner
      WHERE n.nspname='platform_discovery' AND r.rolname <> 'automation_data_inventory_projection') THEN
    RAISE EXCEPTION USING MESSAGE='discovery_schema_collision';
  END IF;
END;
$schema$;
CREATE SCHEMA IF NOT EXISTS platform_discovery AUTHORIZATION automation_data_inventory_projection;
REVOKE ALL ON SCHEMA platform_discovery FROM PUBLIC;
GRANT USAGE ON SCHEMA platform_discovery TO automation_data_inventory;
GRANT CONNECT ON DATABASE automation_data_control TO automation_data_inventory;
REVOKE CREATE, TEMPORARY ON DATABASE automation_data_control FROM PUBLIC;
DO $authority$
BEGIN
  IF has_database_privilege('automation_data_inventory', 'automation_data_control', 'CREATE,TEMPORARY') OR
    EXISTS (SELECT FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
        AND c.relkind IN ('r','p','v','m','f') AND
        (has_table_privilege('automation_data_inventory',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR
         has_any_column_privilege('automation_data_inventory',c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))) OR
    EXISTS (SELECT FROM pg_catalog.pg_namespace n WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
      AND has_schema_privilege('automation_data_inventory',n.oid,'CREATE')) OR
    EXISTS (SELECT FROM pg_catalog.pg_proc f JOIN pg_catalog.pg_namespace n ON n.oid=f.pronamespace
      WHERE n.nspname='platform_operations' AND has_function_privilege('automation_data_inventory',f.oid,'EXECUTE')) THEN
    RAISE EXCEPTION USING MESSAGE='discovery_role_authority_invalid';
  END IF;
END;
$authority$;
GRANT USAGE ON SCHEMA platform_operations TO automation_data_inventory_projection;
GRANT SELECT ("domain", "database_name", "owner_role", "migrator_role", "runtime_role", "state", "generation", "migrator_credential_id", "runtime_credential_id", "migrator_credential_updated_at", "runtime_credential_updated_at", "updated_at") ON platform_operations.managed_domains TO automation_data_inventory_projection;
GRANT USAGE ON SCHEMA platform_operations TO automation_data_inventory_projection;
GRANT SELECT ("domain", "pair", "reader_schema", "operator_schema") ON platform_operations.managed_nocodb_schema_mappings TO automation_data_inventory_projection;
GRANT USAGE ON SCHEMA platform_operations TO automation_data_inventory_projection;
GRANT SELECT ("domain", "pair", "access_kind", "role_name", "base_id", "integration_id", "source_id", "state", "operation", "generation", "credential_generation", "updated_at", "validated_at", "error_code") ON platform_operations.managed_nocodb_sources TO automation_data_inventory_projection;
GRANT USAGE ON SCHEMA platform_operations TO automation_data_inventory_projection;
GRANT SELECT ("domain", "pair", "operation_id", "operation", "access_kind", "generation", "phase") ON platform_operations.nocodb_source_operations TO automation_data_inventory_projection;
GRANT USAGE ON SCHEMA platform_operations TO automation_data_inventory_projection;
GRANT SELECT ("domain", "application", "schema_name", "role_name", "state", "operation", "operation_id", "credential_generation", "updated_at", "error_code") ON platform_operations.managed_application_logins TO automation_data_inventory_projection;
CREATE OR REPLACE VIEW platform_discovery.objects WITH (security_barrier=true) AS
SELECT 'domain'::text kind, domain::text id, jsonb_build_object('kind','domain','id',domain,'domain',domain,'database',database_name,'ownerRole',owner_role,'migratorRole',migrator_role,'runtimeRole',runtime_role,'state',state,'generation',generation,'migratorCredentialId',migrator_credential_id,'runtimeCredentialId',runtime_credential_id,'migratorUpdatedAt',migrator_credential_updated_at,'runtimeUpdatedAt',runtime_credential_updated_at,'updatedAt',updated_at) body FROM platform_operations.managed_domains
UNION ALL
SELECT 'mapping', domain||':'||pair, jsonb_build_object('kind','mapping','id',domain||':'||pair,'domain',domain,'pair',pair,'readerSchema',reader_schema,'operatorSchema',operator_schema) FROM platform_operations.managed_nocodb_schema_mappings
UNION ALL
SELECT 'source', domain||':'||pair||':'||access_kind, jsonb_build_object('kind','source','id',domain||':'||pair||':'||access_kind,'domain',domain,'pair',pair,'accessKind',access_kind,'role',role_name,'baseId',base_id,'integrationId',integration_id,'sourceId',source_id,'state',state,'operation',operation,'generation',generation,'credentialGeneration',credential_generation,'updatedAt',updated_at,'validatedAt',validated_at,'errorCode',CASE WHEN error_code IS NULL THEN NULL ELSE 'operation_error' END) FROM platform_operations.managed_nocodb_sources
UNION ALL
SELECT 'claim', domain||':'||pair, jsonb_build_object('kind','claim','id',domain||':'||pair,'domain',domain,'pair',pair,'operationId',operation_id,'operation',operation,'accessKind',access_kind,'generation',generation,'phase',phase) FROM platform_operations.nocodb_source_operations
UNION ALL
SELECT 'application', domain||':'||application, jsonb_build_object('kind','application','id',domain||':'||application,'domain',domain,'application',application,'schema',schema_name,'role',role_name,'state',state,'operation',operation,'operationId',operation_id,'credentialGeneration',credential_generation,'updatedAt',updated_at,'errorCode',CASE WHEN error_code IS NULL THEN NULL ELSE 'operation_error' END) FROM platform_operations.managed_application_logins
UNION ALL
SELECT 'role', rolname::text, jsonb_build_object('kind','role','id',rolname,'role',rolname,'login',rolcanlogin,'superuser',rolsuper,'createDb',rolcreatedb,'createRole',rolcreaterole,'inherit',rolinherit,'replication',rolreplication,'bypassRls',rolbypassrls) FROM pg_catalog.pg_roles WHERE rolname !~ '^pg_';
ALTER VIEW platform_discovery.objects OWNER TO automation_data_inventory_projection;
REVOKE ALL ON platform_discovery.objects FROM PUBLIC, automation_data_inventory;
CREATE OR REPLACE FUNCTION platform_discovery.read_snapshot()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, platform_discovery
AS $snapshot$
DECLARE payload jsonb; observed timestamptz := statement_timestamp(); total integer;
BEGIN
  IF EXISTS (SELECT FROM (VALUES
      ('platform_operations','managed_domains','domain','text'),
      ('platform_operations','managed_domains','database_name','text'),
      ('platform_operations','managed_domains','owner_role','text'),
      ('platform_operations','managed_domains','migrator_role','text'),
      ('platform_operations','managed_domains','runtime_role','text'),
      ('platform_operations','managed_domains','state','text'),
      ('platform_operations','managed_domains','generation','bigint'),
      ('platform_operations','managed_domains','migrator_credential_id','text'),
      ('platform_operations','managed_domains','runtime_credential_id','text'),
      ('platform_operations','managed_domains','migrator_credential_updated_at','timestamp with time zone'),
      ('platform_operations','managed_domains','runtime_credential_updated_at','timestamp with time zone'),
      ('platform_operations','managed_domains','updated_at','timestamp with time zone'),
      ('platform_operations','managed_nocodb_schema_mappings','domain','text'),
      ('platform_operations','managed_nocodb_schema_mappings','pair','text'),
      ('platform_operations','managed_nocodb_schema_mappings','reader_schema','text'),
      ('platform_operations','managed_nocodb_schema_mappings','operator_schema','text'),
      ('platform_operations','managed_nocodb_sources','domain','text'),
      ('platform_operations','managed_nocodb_sources','pair','text'),
      ('platform_operations','managed_nocodb_sources','access_kind','text'),
      ('platform_operations','managed_nocodb_sources','role_name','text'),
      ('platform_operations','managed_nocodb_sources','base_id','text'),
      ('platform_operations','managed_nocodb_sources','integration_id','text'),
      ('platform_operations','managed_nocodb_sources','source_id','text'),
      ('platform_operations','managed_nocodb_sources','state','text'),
      ('platform_operations','managed_nocodb_sources','operation','text'),
      ('platform_operations','managed_nocodb_sources','generation','bigint'),
      ('platform_operations','managed_nocodb_sources','credential_generation','bigint'),
      ('platform_operations','managed_nocodb_sources','updated_at','timestamp with time zone'),
      ('platform_operations','managed_nocodb_sources','validated_at','timestamp with time zone'),
      ('platform_operations','managed_nocodb_sources','error_code','text'),
      ('platform_operations','nocodb_source_operations','domain','text'),
      ('platform_operations','nocodb_source_operations','pair','text'),
      ('platform_operations','nocodb_source_operations','operation_id','uuid'),
      ('platform_operations','nocodb_source_operations','operation','text'),
      ('platform_operations','nocodb_source_operations','access_kind','text'),
      ('platform_operations','nocodb_source_operations','generation','bigint'),
      ('platform_operations','nocodb_source_operations','phase','text'),
      ('platform_operations','managed_application_logins','domain','text'),
      ('platform_operations','managed_application_logins','application','text'),
      ('platform_operations','managed_application_logins','schema_name','text'),
      ('platform_operations','managed_application_logins','role_name','text'),
      ('platform_operations','managed_application_logins','state','text'),
      ('platform_operations','managed_application_logins','operation','text'),
      ('platform_operations','managed_application_logins','operation_id','uuid'),
      ('platform_operations','managed_application_logins','credential_generation','bigint'),
      ('platform_operations','managed_application_logins','updated_at','timestamp with time zone'),
      ('platform_operations','managed_application_logins','error_code','text')
    ) required(schema_name,table_name,column_name,data_type)
    WHERE NOT EXISTS (SELECT FROM information_schema.columns c
      WHERE c.table_schema=required.schema_name AND c.table_name=required.table_name
        AND c.column_name=required.column_name AND c.data_type=required.data_type)) THEN
    RETURN jsonb_build_object('source','platform','status','unavailable','complete',false,'errorCode','unsupported_schema');
  END IF;
  SELECT count(*), COALESCE(jsonb_agg(body ORDER BY kind,id),'[]'::jsonb)
    INTO total,payload FROM (SELECT kind,id,body FROM platform_discovery.objects ORDER BY kind,id LIMIT 1001) bounded;
  IF total > 1000 OR octet_length(payload::text) > 1048000 THEN
    RETURN jsonb_build_object('source','platform','status','unavailable','complete',false,'errorCode','limit_exceeded');
  END IF;
  RETURN jsonb_build_object('source','platform','status','ok','complete',true,
    'schemaRevision','automation-data-discovery-v1','observedAt',observed,'objectCount',total,
    'fingerprint',md5(payload::text),'objects',payload);
END;
$snapshot$;
ALTER FUNCTION platform_discovery.read_snapshot() OWNER TO automation_data_inventory_projection;
REVOKE ALL ON FUNCTION platform_discovery.read_snapshot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform_discovery.read_snapshot() TO automation_data_inventory;
COMMIT;
