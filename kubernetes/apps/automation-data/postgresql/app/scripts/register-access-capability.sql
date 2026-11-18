-- Register a specification 036 access capability, or re-read an existing identical
-- registration, and print its validation. Values come only from the environment.
\set ON_ERROR_STOP on
\getenv capability_domain CAPABILITY_DOMAIN
\getenv capability_name CAPABILITY_NAME
\getenv capability_schemas CAPABILITY_SCHEMAS
\getenv capability_max_ttl CAPABILITY_MAX_TTL
SELECT platform_operations.register_access_capability(:'capability_domain',
  :'capability_name', string_to_array(:'capability_schemas', ','),
  :'capability_max_ttl'::integer) AS registered \gset
SELECT platform_operations.validate_access_capability(:'capability_domain', :'capability_name');
