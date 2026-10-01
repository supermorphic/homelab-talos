-- Restricted metadata only; install after the pinned application schema exists.
-- Shared by fresh installation and attended upgrade. Never assign passwords here.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '20s';
DO $shape$
BEGIN
  IF current_database() <> 'nocodb' OR session_user <> 'postgres' OR
    EXISTS (SELECT FROM (VALUES
      ('public','workspace','id','character varying'),
      ('public','workspace','deleted','boolean'),
      ('public','nc_bases_v2','id','character varying'),
      ('public','nc_bases_v2','fk_workspace_id','character varying'),
      ('public','nc_bases_v2','deleted','boolean'),
      ('public','nc_integrations_v2','id','character varying'),
      ('public','nc_integrations_v2','fk_workspace_id','character varying'),
      ('public','nc_integrations_v2','type','character varying'),
      ('public','nc_integrations_v2','sub_type','character varying'),
      ('public','nc_integrations_v2','deleted','boolean'),
      ('public','nc_integrations_v2','updated_at','timestamp with time zone'),
      ('public','nc_sources_v2','id','character varying'),
      ('public','nc_sources_v2','base_id','character varying'),
      ('public','nc_sources_v2','fk_workspace_id','character varying'),
      ('public','nc_sources_v2','fk_integration_id','character varying'),
      ('public','nc_sources_v2','is_data_readonly','boolean'),
      ('public','nc_sources_v2','is_schema_readonly','boolean'),
      ('public','nc_sources_v2','enabled','boolean'),
      ('public','nc_sources_v2','deleted','boolean'),
      ('public','nc_sources_v2','is_local','boolean'),
      ('public','nc_sources_v2','updated_at','timestamp with time zone'),
      ('public','nc_users_v2','id','character varying'),
      ('public','nc_users_v2','is_deleted','boolean'),
      ('public','nc_base_users_v2','base_id','character varying'),
      ('public','nc_base_users_v2','fk_user_id','character varying'),
      ('public','nc_base_users_v2','roles','text'),
      ('public','workspace_user','fk_workspace_id','character varying'),
      ('public','workspace_user','fk_user_id','character varying'),
      ('public','workspace_user','roles','character varying'),
      ('public','workspace_user','deleted','boolean'),
      ('public','nc_api_tokens','id','integer'),
      ('public','nc_api_tokens','expiry','character varying'),
      ('public','nc_api_tokens','enabled','boolean'),
      ('public','nc_api_tokens','updated_at','timestamp with time zone')
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
  FOREACH identity IN ARRAY ARRAY['nocodb_inventory','nocodb_inventory_projection'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname=identity) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS', identity);
      EXECUTE format('COMMENT ON ROLE %I IS %L', identity, 'homelab:credential-discovery:v1');
    ELSIF pg_catalog.shobj_description((SELECT oid FROM pg_catalog.pg_roles WHERE rolname=identity),'pg_authid') IS DISTINCT FROM 'homelab:credential-discovery:v1' THEN
      RAISE EXCEPTION USING MESSAGE='discovery_role_collision';
    END IF;
    IF EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE rolname=identity AND
      ((rolname='nocodb_inventory_projection' AND rolcanlogin) OR rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls)) OR
      EXISTS (SELECT FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles r ON r.oid=m.member OR r.oid=m.roleid WHERE r.rolname=identity) THEN
      RAISE EXCEPTION USING MESSAGE='discovery_role_authority_invalid';
    END IF;
  END LOOP;
END;
$roles$;
DO $schema$
BEGIN
  IF EXISTS (SELECT FROM pg_catalog.pg_namespace n JOIN pg_catalog.pg_roles r ON r.oid=n.nspowner
      WHERE n.nspname='platform_discovery' AND r.rolname <> 'nocodb_inventory_projection') THEN
    RAISE EXCEPTION USING MESSAGE='discovery_schema_collision';
  END IF;
END;
$schema$;
CREATE SCHEMA IF NOT EXISTS platform_discovery AUTHORIZATION nocodb_inventory_projection;
REVOKE ALL ON SCHEMA platform_discovery FROM PUBLIC;
GRANT USAGE ON SCHEMA platform_discovery TO nocodb_inventory;
GRANT CONNECT ON DATABASE nocodb TO nocodb_inventory;
REVOKE CREATE, TEMPORARY ON DATABASE nocodb FROM PUBLIC;
DO $authority$
BEGIN
  IF has_database_privilege('nocodb_inventory', 'nocodb', 'CREATE,TEMPORARY') OR
    EXISTS (SELECT FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
        AND c.relkind IN ('r','p','v','m','f') AND
        (has_table_privilege('nocodb_inventory',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR
         has_any_column_privilege('nocodb_inventory',c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))) OR
    EXISTS (SELECT FROM pg_catalog.pg_namespace n WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
      AND has_schema_privilege('nocodb_inventory',n.oid,'CREATE')) OR
    EXISTS (SELECT FROM pg_catalog.pg_proc f JOIN pg_catalog.pg_namespace n ON n.oid=f.pronamespace
      WHERE n.nspname='platform_operations' AND has_function_privilege('nocodb_inventory',f.oid,'EXECUTE')) THEN
    RAISE EXCEPTION USING MESSAGE='discovery_role_authority_invalid';
  END IF;
END;
$authority$;
GRANT USAGE ON SCHEMA public TO nocodb_inventory_projection;
GRANT SELECT ("id", "deleted") ON public.workspace TO nocodb_inventory_projection;
GRANT USAGE ON SCHEMA public TO nocodb_inventory_projection;
GRANT SELECT ("id", "fk_workspace_id", "deleted") ON public.nc_bases_v2 TO nocodb_inventory_projection;
GRANT USAGE ON SCHEMA public TO nocodb_inventory_projection;
GRANT SELECT ("id", "fk_workspace_id", "type", "sub_type", "deleted", "updated_at") ON public.nc_integrations_v2 TO nocodb_inventory_projection;
GRANT USAGE ON SCHEMA public TO nocodb_inventory_projection;
GRANT SELECT ("id", "base_id", "fk_workspace_id", "fk_integration_id", "is_data_readonly", "is_schema_readonly", "enabled", "deleted", "is_local", "updated_at") ON public.nc_sources_v2 TO nocodb_inventory_projection;
GRANT USAGE ON SCHEMA public TO nocodb_inventory_projection;
GRANT SELECT ("id", "is_deleted") ON public.nc_users_v2 TO nocodb_inventory_projection;
GRANT USAGE ON SCHEMA public TO nocodb_inventory_projection;
GRANT SELECT ("base_id", "fk_user_id", "roles") ON public.nc_base_users_v2 TO nocodb_inventory_projection;
GRANT USAGE ON SCHEMA public TO nocodb_inventory_projection;
GRANT SELECT ("fk_workspace_id", "fk_user_id", "roles", "deleted") ON public.workspace_user TO nocodb_inventory_projection;
GRANT USAGE ON SCHEMA public TO nocodb_inventory_projection;
GRANT SELECT ("id", "expiry", "enabled", "updated_at") ON public.nc_api_tokens TO nocodb_inventory_projection;
CREATE OR REPLACE VIEW platform_discovery.objects WITH (security_barrier=true) AS
SELECT 'workspace'::text kind,id::text id,jsonb_build_object('kind','workspace','id',id) body FROM public.workspace WHERE NOT COALESCE(deleted,false)
UNION ALL
SELECT 'base',id,jsonb_build_object('kind','base','id',id,'workspaceId',fk_workspace_id) FROM public.nc_bases_v2 WHERE NOT COALESCE(deleted,false)
UNION ALL
SELECT 'integration',id,jsonb_build_object('kind','integration','id',id,'workspaceId',fk_workspace_id,'type',type,'subType',sub_type,'updatedAt',updated_at) FROM public.nc_integrations_v2 WHERE NOT COALESCE(deleted,false)
UNION ALL
SELECT 'source',id,jsonb_build_object('kind','source','id',id,'baseId',base_id,'workspaceId',fk_workspace_id,'integrationId',fk_integration_id,'dataEditAllowed',NOT is_data_readonly,'schemaEditAllowed',NOT is_schema_readonly,'enabled',enabled,'deleted',deleted,'intrinsic',COALESCE(is_local,false) AND fk_integration_id IS NULL,'updatedAt',updated_at) FROM public.nc_sources_v2 WHERE NOT COALESCE(deleted,false)
UNION ALL
SELECT 'account',id,jsonb_build_object('kind','account','id',id) FROM public.nc_users_v2 WHERE NOT COALESCE(is_deleted,false)
UNION ALL
SELECT 'membership','base:'||base_id||':'||fk_user_id,jsonb_build_object('kind','membership','id','base:'||base_id||':'||fk_user_id,'accountId',fk_user_id,'baseId',base_id,'access',CASE WHEN roles IN ('owner','creator','editor','viewer') THEN roles ELSE 'custom' END) FROM public.nc_base_users_v2
UNION ALL
SELECT 'membership','workspace:'||fk_workspace_id||':'||fk_user_id,jsonb_build_object('kind','membership','id','workspace:'||fk_workspace_id||':'||fk_user_id,'accountId',fk_user_id,'workspaceId',fk_workspace_id,'access',CASE WHEN roles IN ('owner','creator','editor','viewer') THEN roles ELSE 'custom' END) FROM public.workspace_user WHERE NOT COALESCE(deleted,false)
UNION ALL
SELECT 'api_token',id::text,jsonb_build_object('kind','api_token','id',id::text,'expiresAt',CASE WHEN expiry ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' THEN expiry ELSE NULL END,'updatedAt',updated_at) FROM public.nc_api_tokens WHERE COALESCE(enabled,false);
ALTER VIEW platform_discovery.objects OWNER TO nocodb_inventory_projection;
REVOKE ALL ON platform_discovery.objects FROM PUBLIC, nocodb_inventory;
CREATE OR REPLACE FUNCTION platform_discovery.read_snapshot()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, platform_discovery
AS $snapshot$
DECLARE payload jsonb; observed timestamptz := statement_timestamp(); total integer;
BEGIN
  IF EXISTS (SELECT FROM (VALUES
      ('public','workspace','id','character varying'),
      ('public','workspace','deleted','boolean'),
      ('public','nc_bases_v2','id','character varying'),
      ('public','nc_bases_v2','fk_workspace_id','character varying'),
      ('public','nc_bases_v2','deleted','boolean'),
      ('public','nc_integrations_v2','id','character varying'),
      ('public','nc_integrations_v2','fk_workspace_id','character varying'),
      ('public','nc_integrations_v2','type','character varying'),
      ('public','nc_integrations_v2','sub_type','character varying'),
      ('public','nc_integrations_v2','deleted','boolean'),
      ('public','nc_integrations_v2','updated_at','timestamp with time zone'),
      ('public','nc_sources_v2','id','character varying'),
      ('public','nc_sources_v2','base_id','character varying'),
      ('public','nc_sources_v2','fk_workspace_id','character varying'),
      ('public','nc_sources_v2','fk_integration_id','character varying'),
      ('public','nc_sources_v2','is_data_readonly','boolean'),
      ('public','nc_sources_v2','is_schema_readonly','boolean'),
      ('public','nc_sources_v2','enabled','boolean'),
      ('public','nc_sources_v2','deleted','boolean'),
      ('public','nc_sources_v2','is_local','boolean'),
      ('public','nc_sources_v2','updated_at','timestamp with time zone'),
      ('public','nc_users_v2','id','character varying'),
      ('public','nc_users_v2','is_deleted','boolean'),
      ('public','nc_base_users_v2','base_id','character varying'),
      ('public','nc_base_users_v2','fk_user_id','character varying'),
      ('public','nc_base_users_v2','roles','text'),
      ('public','workspace_user','fk_workspace_id','character varying'),
      ('public','workspace_user','fk_user_id','character varying'),
      ('public','workspace_user','roles','character varying'),
      ('public','workspace_user','deleted','boolean'),
      ('public','nc_api_tokens','id','integer'),
      ('public','nc_api_tokens','expiry','character varying'),
      ('public','nc_api_tokens','enabled','boolean'),
      ('public','nc_api_tokens','updated_at','timestamp with time zone')
    ) required(schema_name,table_name,column_name,data_type)
    WHERE NOT EXISTS (SELECT FROM information_schema.columns c
      WHERE c.table_schema=required.schema_name AND c.table_name=required.table_name
        AND c.column_name=required.column_name AND c.data_type=required.data_type)) THEN
    RETURN jsonb_build_object('source','nocodb','status','unavailable','complete',false,'errorCode','unsupported_schema');
  END IF;
  SELECT count(*), COALESCE(jsonb_agg(body ORDER BY kind,id),'[]'::jsonb)
    INTO total,payload FROM (SELECT kind,id,body FROM platform_discovery.objects ORDER BY kind,id LIMIT 1001) bounded;
  IF total > 1000 OR octet_length(payload::text) > 1048000 THEN
    RETURN jsonb_build_object('source','nocodb','status','unavailable','complete',false,'errorCode','limit_exceeded');
  END IF;
  RETURN jsonb_build_object('source','nocodb','status','ok','complete',true,
    'schemaRevision','nocodb-2026.08.2-v1','observedAt',observed,'objectCount',total,
    'fingerprint',md5(payload::text),'objects',payload);
END;
$snapshot$;
ALTER FUNCTION platform_discovery.read_snapshot() OWNER TO nocodb_inventory_projection;
REVOKE ALL ON FUNCTION platform_discovery.read_snapshot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform_discovery.read_snapshot() TO nocodb_inventory;
COMMIT;
