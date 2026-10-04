printf '%s\n' 'restore_stage=nocodb-source-registry'
if [ "$restored_platform_revision" = '026-nocodb-v3' ]; then
source_registry="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
SELECT jsonb_build_object(
  'items', COALESCE(jsonb_agg(jsonb_build_object(
    'domain', source.domain,
    'pair', source.pair,
    'accessKind', source.access_kind,
    'state', source.state,
    'baseId', source.base_id,
    'sourceId', source.source_id,
    'integrationId', source.integration_id,
    'schema', CASE source.access_kind WHEN 'reader' THEN
      COALESCE(mapping.reader_schema, 'read_model') ELSE
      COALESCE(mapping.operator_schema, 'operator') END,
    'valid', (platform_operations.validate_nocodb_access(source.domain, source.pair, source.access_kind)->>'valid')::boolean
  ) ORDER BY source.pair, source.access_kind), '[]'::jsonb)
)
FROM platform_operations.managed_nocodb_sources AS source
LEFT JOIN platform_operations.managed_nocodb_schema_mappings AS mapping
  ON mapping.domain = source.domain AND mapping.pair = source.pair
WHERE source.domain = 'automation_data_acceptance';
")" || restore_fail nocodb-source-registry-query
elif [ "$restored_platform_revision" = '026-nocodb-v2' ]; then
source_registry="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
SELECT jsonb_build_object(
  'items', COALESCE(jsonb_agg(jsonb_build_object(
    'domain', source.domain,
    'pair', 'default',
    'accessKind', source.access_kind,
    'state', source.state,
    'baseId', source.base_id,
    'sourceId', source.source_id,
    'integrationId', source.integration_id,
    'schema', CASE source.access_kind WHEN 'reader' THEN
      COALESCE(mapping.reader_schema, 'read_model') ELSE
      COALESCE(mapping.operator_schema, 'operator') END,
    'valid', (platform_operations.validate_nocodb_access(source.domain, source.access_kind)->>'valid')::boolean
  ) ORDER BY source.access_kind), '[]'::jsonb)
)
FROM platform_operations.managed_nocodb_sources AS source
LEFT JOIN platform_operations.managed_nocodb_schema_mappings AS mapping
  ON mapping.domain = source.domain
WHERE source.domain = 'automation_data_acceptance';
")" || restore_fail nocodb-source-registry-query
else
source_registry="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
SELECT jsonb_build_object(
  'items', COALESCE(jsonb_agg(jsonb_build_object(
    'domain', source.domain,
    'pair', 'default',
    'accessKind', source.access_kind,
    'state', source.state,
    'baseId', source.base_id,
    'sourceId', source.source_id,
    'integrationId', source.integration_id,
    'schema', CASE source.access_kind WHEN 'reader' THEN 'read_model' ELSE 'operator' END,
    'valid', (platform_operations.validate_nocodb_access(source.domain, source.access_kind)->>'valid')::boolean
  ) ORDER BY source.access_kind), '[]'::jsonb)
)
FROM platform_operations.managed_nocodb_sources AS source
WHERE source.domain = 'automation_data_acceptance';
")" || restore_fail nocodb-source-registry-query
fi
# Validate decoded JSON in the caller; the pinned PostgreSQL image has no jq.
test -n "$source_registry" || restore_fail nocodb-source-registry-shape
printf 'source_registry_base64=%s\n' "$(printf '%s' "$source_registry" | base64 | tr -d '\n')"
