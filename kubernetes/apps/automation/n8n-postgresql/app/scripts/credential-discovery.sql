-- Restricted metadata only; install after the pinned application schema exists.
-- Shared by fresh installation and attended upgrade. Never assign passwords here.
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '20s';
DO $roles$
DECLARE identity text;
BEGIN
  FOREACH identity IN ARRAY ARRAY['n8n_inventory','n8n_inventory_projection'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname=identity) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS', identity);
      EXECUTE format('COMMENT ON ROLE %I IS %L', identity, 'homelab:credential-discovery:v1');
    ELSIF pg_catalog.shobj_description((SELECT oid FROM pg_catalog.pg_roles WHERE rolname=identity),'pg_authid') IS DISTINCT FROM 'homelab:credential-discovery:v1' THEN
      RAISE EXCEPTION USING MESSAGE='discovery_role_collision';
    END IF;
    IF EXISTS (SELECT FROM pg_catalog.pg_roles r WHERE rolname=identity AND
      (rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls)) OR
      EXISTS (SELECT FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles r ON r.oid=m.member OR r.oid=m.roleid WHERE r.rolname=identity) THEN
      RAISE EXCEPTION USING MESSAGE='discovery_role_authority_invalid';
    END IF;
  END LOOP;
END;
$roles$;
DO $schema$
BEGIN
  IF EXISTS (SELECT FROM pg_catalog.pg_namespace n JOIN pg_catalog.pg_roles r ON r.oid=n.nspowner
      WHERE n.nspname='platform_discovery' AND r.rolname <> 'n8n_inventory_projection') THEN
    RAISE EXCEPTION USING MESSAGE='discovery_schema_collision';
  END IF;
END;
$schema$;
CREATE SCHEMA IF NOT EXISTS platform_discovery AUTHORIZATION n8n_inventory_projection;
REVOKE ALL ON SCHEMA platform_discovery FROM PUBLIC;
GRANT USAGE ON SCHEMA platform_discovery TO n8n_inventory;
GRANT CONNECT ON DATABASE n8n TO n8n_inventory;
GRANT USAGE ON SCHEMA public TO n8n_inventory_projection;
GRANT SELECT ("id", "name", "type", "updatedAt") ON public.credentials_entity TO n8n_inventory_projection;
GRANT USAGE ON SCHEMA public TO n8n_inventory_projection;
GRANT SELECT ("id", "active", "activeVersionId", "isArchived") ON public.workflow_entity TO n8n_inventory_projection;
GRANT USAGE ON SCHEMA public TO n8n_inventory_projection;
GRANT SELECT ("versionId", "workflowId", "nodes") ON public.workflow_history TO n8n_inventory_projection;
GRANT USAGE ON SCHEMA public TO n8n_inventory_projection;
GRANT SELECT ("workflowId", "publishedVersionId") ON public.workflow_published_version TO n8n_inventory_projection;
CREATE OR REPLACE VIEW platform_discovery.objects WITH (security_barrier=true) AS
SELECT 'credential'::text kind,id::text id,jsonb_build_object('kind','credential','id',id,'name',CASE WHEN name IN ('Automation Data Provisioner','Automation Data n8n API','Automation Data Provisioning Header','NocoDB Operator API','NocoDB Source Provisioning Header','NocoDB Acceptance Header','Platform Canary Header','Automation Data Inventory Reader','NocoDB Inventory Reader','n8n Inventory Reader','Automation Data Inventory Header') OR name ~ '^automation-data/[a-z][a-z0-9_]{0,47}/(runtime|migrator)$' THEN name ELSE NULL END,'type',type,'updatedAt',"updatedAt") body FROM public.credentials_entity
UNION ALL
SELECT 'workflow', w.id, jsonb_build_object('kind','workflow','id',w.id,'versionId',w."activeVersionId",'published', w.active AND NOT w."isArchived" AND h."versionId" IS NOT NULL AND (p."publishedVersionId" IS NULL OR p."publishedVersionId"=w."activeVersionId")) FROM public.workflow_entity w LEFT JOIN public.workflow_history h ON h."workflowId"=w.id AND h."versionId"=w."activeVersionId" LEFT JOIN public.workflow_published_version p ON p."workflowId"=w.id
UNION ALL
SELECT 'binding',w.id||':'||n.ordinality::text||':'||c.key,jsonb_build_object('kind','binding','id',w.id||':'||n.ordinality::text||':'||c.key,'workflowId',w.id,'node',n.ordinality::text,'credentialId',c.value->>'id','credentialType',c.key,'published',true) FROM public.workflow_entity w JOIN public.workflow_history h ON h."workflowId"=w.id AND h."versionId"=w."activeVersionId" LEFT JOIN public.workflow_published_version p ON p."workflowId"=w.id CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(h.nodes::jsonb)='array' THEN h.nodes::jsonb ELSE '[]'::jsonb END) WITH ORDINALITY n(node,ordinality) CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(n.node->'credentials')='object' THEN n.node->'credentials' ELSE '{}'::jsonb END) c WHERE w.active AND NOT w."isArchived" AND (p."publishedVersionId" IS NULL OR p."publishedVersionId"=w."activeVersionId");
ALTER VIEW platform_discovery.objects OWNER TO n8n_inventory_projection;
REVOKE ALL ON platform_discovery.objects FROM PUBLIC, n8n_inventory;
CREATE OR REPLACE FUNCTION platform_discovery.read_snapshot()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, platform_discovery
AS $snapshot$
DECLARE payload jsonb; observed timestamptz := statement_timestamp(); total integer;
BEGIN
  IF EXISTS (SELECT FROM (VALUES
      ('public','credentials_entity','id','character varying'),
      ('public','credentials_entity','name','character varying'),
      ('public','credentials_entity','type','character varying'),
      ('public','credentials_entity','updatedAt','timestamp with time zone'),
      ('public','workflow_entity','id','character varying'),
      ('public','workflow_entity','active','boolean'),
      ('public','workflow_entity','activeVersionId','character varying'),
      ('public','workflow_entity','isArchived','boolean'),
      ('public','workflow_history','versionId','character varying'),
      ('public','workflow_history','workflowId','character varying'),
      ('public','workflow_history','nodes','json'),
      ('public','workflow_published_version','workflowId','character varying'),
      ('public','workflow_published_version','publishedVersionId','character varying')
    ) required(schema_name,table_name,column_name,data_type)
    WHERE NOT EXISTS (SELECT FROM information_schema.columns c
      WHERE c.table_schema=required.schema_name AND c.table_name=required.table_name
        AND c.column_name=required.column_name AND c.data_type=required.data_type)) THEN
    RETURN jsonb_build_object('source','n8n','status','unavailable','complete',false,'errorCode','unsupported_schema');
  END IF;
  SELECT count(*), COALESCE(jsonb_agg(body ORDER BY kind,id),'[]'::jsonb)
    INTO total,payload FROM (SELECT kind,id,body FROM platform_discovery.objects ORDER BY kind,id LIMIT 1001) bounded;
  IF total > 1000 OR octet_length(payload::text) > 1048000 THEN
    RETURN jsonb_build_object('source','n8n','status','unavailable','complete',false,'errorCode','limit_exceeded');
  END IF;
  RETURN jsonb_build_object('source','n8n','status','ok','complete',true,
    'schemaRevision','n8n-2.36.7-v1','observedAt',observed,'objectCount',total,
    'fingerprint',md5(payload::text),'objects',payload);
END;
$snapshot$;
ALTER FUNCTION platform_discovery.read_snapshot() OWNER TO n8n_inventory_projection;
REVOKE ALL ON FUNCTION platform_discovery.read_snapshot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION platform_discovery.read_snapshot() TO n8n_inventory;
COMMIT;
