-- Shared NocoDB extension definitions for fresh initialization and revision 026 upgrade.
-- The caller must have created the accepted specification-025 platform schema.
SET ROLE postgres;

-- NocoDB source roles must not inherit access to bootstrap maintenance databases.
-- This shared file runs inside the guarded upgrade transaction and during fresh init.
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;

CREATE TABLE IF NOT EXISTS platform_operations.platform_schema_revision (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  revision text NOT NULL CHECK (revision ~ '^[0-9]{3}-[a-z0-9-]+$'),
  installed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS platform_operations.managed_nocodb_sources (
  domain text NOT NULL REFERENCES platform_operations.managed_domains(domain),
  pair text NOT NULL DEFAULT 'default'
    CHECK (pair = 'default' OR pair ~ '^[a-z][a-z0-9_]{0,23}$'),
  access_kind text NOT NULL CHECK (access_kind IN ('reader', 'operator')),
  role_name text NOT NULL,
  base_id text,
  integration_id text,
  source_id text,
  source_create_job_id text,
  state text NOT NULL CHECK (state IN (
    'awaiting_grants', 'provisioning', 'waiting_for_source',
    'ready', 'rotating', 'error'
  )),
  operation text NOT NULL CHECK (operation IN ('sync', 'rotate')),
  generation bigint NOT NULL CHECK (generation > 0),
  credential_generation bigint NOT NULL DEFAULT 0 CHECK (credential_generation >= 0),
  operation_started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  validated_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{0,63}$'),
  PRIMARY KEY (domain, pair, access_kind),
  CHECK (role_name = CASE WHEN pair = 'default' THEN domain ELSE
    'nocodb_' || md5(domain || ':' || pair) END || CASE access_kind
    WHEN 'reader' THEN '_reader' ELSE '_operator' END)
);
CREATE TABLE IF NOT EXISTS platform_operations.managed_nocodb_schema_mappings (
  domain text NOT NULL REFERENCES platform_operations.managed_domains(domain),
  pair text NOT NULL DEFAULT 'default'
    CHECK (pair = 'default' OR pair ~ '^[a-z][a-z0-9_]{0,23}$'),
  reader_schema text NOT NULL CHECK (reader_schema ~ '^[a-z][a-z0-9_]{0,47}$'),
  operator_schema text CHECK (operator_schema ~ '^[a-z][a-z0-9_]{0,47}$'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (domain, pair),
  CHECK (operator_schema IS NULL OR operator_schema <> reader_schema),
  CHECK (reader_schema NOT LIKE 'pg\_%' ESCAPE '\' AND
    reader_schema NOT LIKE 'platform%' AND
    reader_schema NOT IN ('app', 'public', 'read_model', 'operator',
      'information_schema')),
  CHECK (operator_schema IS NULL OR (operator_schema NOT LIKE 'pg\_%' ESCAPE '\' AND
    operator_schema NOT LIKE 'platform%' AND
    operator_schema NOT IN ('app', 'public', 'read_model', 'operator',
      'information_schema')))
);
-- Existing v2 rows acquire the reserved pair key without changing their other fields.
ALTER TABLE platform_operations.managed_nocodb_sources
  ADD COLUMN IF NOT EXISTS pair text NOT NULL DEFAULT 'default';
ALTER TABLE platform_operations.managed_nocodb_schema_mappings
  ADD COLUMN IF NOT EXISTS pair text NOT NULL DEFAULT 'default';
DO $upgrade$
BEGIN
  IF EXISTS (SELECT FROM pg_constraint WHERE conrelid =
      'platform_operations.managed_nocodb_sources'::regclass
      AND conname = 'managed_nocodb_sources_pkey' AND array_length(conkey, 1) = 2) THEN
    ALTER TABLE platform_operations.managed_nocodb_sources
      DROP CONSTRAINT managed_nocodb_sources_pkey;
    ALTER TABLE platform_operations.managed_nocodb_sources
      ADD CONSTRAINT managed_nocodb_sources_pkey PRIMARY KEY (domain, pair, access_kind);
  END IF;
  IF EXISTS (SELECT FROM pg_constraint WHERE conrelid =
      'platform_operations.managed_nocodb_schema_mappings'::regclass
      AND conname = 'managed_nocodb_schema_mappings_pkey' AND array_length(conkey, 1) = 1) THEN
    ALTER TABLE platform_operations.managed_nocodb_schema_mappings
      DROP CONSTRAINT managed_nocodb_schema_mappings_pkey;
    ALTER TABLE platform_operations.managed_nocodb_schema_mappings
      ADD CONSTRAINT managed_nocodb_schema_mappings_pkey PRIMARY KEY (domain, pair);
  END IF;
END;
$upgrade$;
ALTER TABLE platform_operations.managed_nocodb_sources
  DROP CONSTRAINT IF EXISTS managed_nocodb_sources_role_name_check;
ALTER TABLE platform_operations.managed_nocodb_sources
  DROP CONSTRAINT IF EXISTS managed_nocodb_sources_check;
ALTER TABLE platform_operations.managed_nocodb_sources
  ADD CONSTRAINT managed_nocodb_sources_role_name_check CHECK (
    role_name = (CASE WHEN pair = 'default' THEN domain ELSE
      'nocodb_' || md5(domain || ':' || pair) END) ||
      (CASE access_kind WHEN 'reader' THEN '_reader' ELSE '_operator' END)
  );
ALTER TABLE platform_operations.managed_nocodb_sources
  DROP CONSTRAINT IF EXISTS managed_nocodb_sources_pair_check;
ALTER TABLE platform_operations.managed_nocodb_sources
  ADD CONSTRAINT managed_nocodb_sources_pair_check CHECK (
    pair = 'default' OR pair ~ '^[a-z][a-z0-9_]{0,23}$'
  );
ALTER TABLE platform_operations.managed_nocodb_schema_mappings
  DROP CONSTRAINT IF EXISTS managed_nocodb_schema_mappings_pair_check;
ALTER TABLE platform_operations.managed_nocodb_schema_mappings
  ADD CONSTRAINT managed_nocodb_schema_mappings_pair_check CHECK (
    pair = 'default' OR pair ~ '^[a-z][a-z0-9_]{0,23}$'
  );
CREATE TABLE IF NOT EXISTS platform_operations.nocodb_source_operations (
  domain text NOT NULL REFERENCES platform_operations.managed_domains(domain),
  pair text NOT NULL CHECK (pair = 'default' OR pair ~ '^[a-z][a-z0-9_]{0,23}$'),
  operation_id uuid NOT NULL,
  operation text NOT NULL CHECK (operation IN ('sync', 'rotate')),
  access_kind text CHECK (access_kind IN ('reader', 'operator')),
  generation bigint NOT NULL CHECK (generation > 0),
  phase text NOT NULL CHECK (phase IN ('active', 'uncertain', 'complete')),
  operation_started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{0,63}$'),
  PRIMARY KEY (domain, pair)
);
REVOKE ALL ON platform_operations.nocodb_source_operations FROM PUBLIC;

CREATE OR REPLACE FUNCTION platform_internal.nocodb_operation_result(
  p_domain text, p_pair text, p_can_execute boolean
)
RETURNS jsonb
LANGUAGE sql
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT jsonb_build_object(
    'domain', operation.domain, 'pair', operation.pair,
    'operationId', operation.operation_id, 'operation', operation.operation,
    'accessKind', operation.access_kind, 'generation', operation.generation,
    'phase', operation.phase, 'canExecute', p_can_execute,
    'operationStartedAt', operation.operation_started_at,
    'updatedAt', operation.updated_at, 'errorCode', operation.error_code)
  FROM platform_operations.nocodb_source_operations AS operation
  WHERE operation.domain = p_domain AND operation.pair = p_pair;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.assert_nocodb_claim(
  p_domain text, p_pair text, p_operation text, p_access_kind text,
  p_operation_id uuid, p_generation bigint
)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  claimed platform_operations.nocodb_source_operations%ROWTYPE;
BEGIN
  IF p_operation_id IS NULL OR p_generation IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_claim';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO claimed FROM platform_operations.nocodb_source_operations
    WHERE domain = p_domain AND pair = p_pair FOR UPDATE;
  IF NOT FOUND OR claimed.operation_id <> p_operation_id OR
     claimed.generation <> p_generation OR claimed.phase <> 'active' OR
     claimed.operation <> p_operation OR
     (p_operation = 'rotate' AND claimed.access_kind IS DISTINCT FROM p_access_kind) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_claim_stale';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.claim_nocodb_operation(
  p_domain text, p_pair text, p_operation text, p_access_kind text,
  p_operation_id uuid, p_quiesced_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  existing platform_operations.nocodb_source_operations%ROWTYPE;
  explicit_retry boolean := p_quiesced_operation_id IS NOT NULL;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_pair IS NULL OR (p_pair <> 'default' AND
      p_pair !~ '^[a-z][a-z0-9_]{0,23}$') OR
     p_operation NOT IN ('sync', 'rotate') OR p_operation IS NULL OR
     (p_operation = 'sync' AND p_access_kind IS NOT NULL) OR
     (p_operation = 'rotate' AND p_access_kind NOT IN ('reader', 'operator')) OR
     (p_operation = 'rotate' AND p_access_kind IS NULL) OR
     p_operation_id IS NULL OR
     (explicit_retry AND p_operation <> 'rotate') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_claim';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  IF NOT EXISTS (SELECT FROM platform_operations.managed_domains
      WHERE domain = p_domain AND state = 'ready') OR
     (p_pair <> 'default' AND NOT EXISTS (
       SELECT FROM platform_operations.managed_nocodb_schema_mappings
       WHERE domain = p_domain AND pair = p_pair)) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_pair_not_registered';
  END IF;
  SELECT * INTO existing FROM platform_operations.nocodb_source_operations
    WHERE domain = p_domain AND pair = p_pair FOR UPDATE;
  IF FOUND THEN
    IF existing.operation_id = p_operation_id THEN
      IF existing.operation <> p_operation OR
         existing.access_kind IS DISTINCT FROM p_access_kind THEN
        RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_claim_target_mismatch';
      END IF;
      RETURN platform_internal.nocodb_operation_result(p_domain, p_pair, false);
    END IF;
    IF existing.phase <> 'complete' AND NOT explicit_retry THEN
      RETURN platform_internal.nocodb_operation_result(p_domain, p_pair, false);
    END IF;
    IF explicit_retry AND (existing.operation_id <> p_quiesced_operation_id OR
        existing.phase <> 'uncertain' OR
        existing.operation <> 'rotate' OR
        existing.access_kind IS DISTINCT FROM p_access_kind OR
        NOT EXISTS (
          SELECT FROM platform_operations.managed_nocodb_sources AS source
          WHERE source.domain = p_domain AND source.pair = p_pair AND
            source.access_kind = p_access_kind AND
            source.state IN ('rotating', 'error') AND
            source.operation = 'rotate' AND source.source_id IS NOT NULL AND
            source.integration_id IS NOT NULL AND source.base_id IS NOT NULL)) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_retry_not_eligible';
    END IF;
  ELSIF explicit_retry THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_retry_not_eligible';
  END IF;
  IF p_operation = 'rotate' AND NOT EXISTS (
    SELECT FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind
      AND (state = 'ready' OR (explicit_retry AND state IN ('rotating', 'error')))
      AND source_id IS NOT NULL
      AND integration_id IS NOT NULL AND base_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_not_ready';
  END IF;
  next_generation := platform_internal.bump_generation();
  INSERT INTO platform_operations.nocodb_source_operations (
    domain, pair, operation_id, operation, access_kind, generation, phase,
    operation_started_at, updated_at, error_code
  ) VALUES (
    p_domain, p_pair, p_operation_id, p_operation, p_access_kind,
    next_generation, 'active', clock_timestamp(), clock_timestamp(), NULL
  ) ON CONFLICT (domain, pair) DO UPDATE SET
    operation_id = EXCLUDED.operation_id, operation = EXCLUDED.operation,
    access_kind = EXCLUDED.access_kind, generation = EXCLUDED.generation,
    phase = 'active', operation_started_at = EXCLUDED.operation_started_at,
    updated_at = EXCLUDED.updated_at, error_code = NULL;
  RETURN platform_internal.nocodb_operation_result(p_domain, p_pair, true);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.claim_nocodb_operation(
  p_domain text, p_pair text, p_operation text, p_access_kind text,
  p_operation_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_operations.claim_nocodb_operation(
    p_domain, p_pair, p_operation, p_access_kind, p_operation_id, NULL::uuid);
$function$;

CREATE OR REPLACE FUNCTION platform_operations.read_nocodb_operation_state(
  p_domain text, p_pair text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_pair IS NULL OR (p_pair <> 'default' AND
      p_pair !~ '^[a-z][a-z0-9_]{0,23}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_pair';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  PERFORM 1 FROM platform_operations.managed_domains WHERE domain = p_domain;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'domain_not_found';
  END IF;
  RETURN COALESCE(platform_internal.nocodb_operation_result(
    p_domain, p_pair, false), 'null'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.mark_nocodb_operation_uncertain(
  p_domain text, p_pair text, p_operation_id uuid, p_generation bigint,
  p_error_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  existing platform_operations.nocodb_source_operations%ROWTYPE;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_pair IS NULL OR (p_pair <> 'default' AND
      p_pair !~ '^[a-z][a-z0-9_]{0,23}$') OR
     p_operation_id IS NULL OR p_generation IS NULL OR
     p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_]{0,63}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_claim';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT existing FROM platform_operations.nocodb_source_operations
    WHERE domain = p_domain AND pair = p_pair FOR UPDATE;
  IF existing.operation_id <> p_operation_id OR
     existing.generation <> p_generation OR existing.phase = 'complete' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_claim_stale';
  END IF;
  IF existing.phase <> 'uncertain' OR existing.error_code IS DISTINCT FROM p_error_code THEN
    UPDATE platform_operations.nocodb_source_operations
      SET phase = 'uncertain', error_code = p_error_code,
          updated_at = clock_timestamp()
      WHERE domain = p_domain AND pair = p_pair;
    PERFORM platform_internal.bump_generation();
  END IF;
  RETURN platform_internal.nocodb_operation_result(p_domain, p_pair, false);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.complete_nocodb_operation(
  p_domain text, p_pair text, p_operation_id uuid, p_generation bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  existing platform_operations.nocodb_source_operations%ROWTYPE;
  mapping platform_operations.managed_nocodb_schema_mappings%ROWTYPE;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_pair IS NULL OR (p_pair <> 'default' AND
      p_pair !~ '^[a-z][a-z0-9_]{0,23}$') OR
     p_operation_id IS NULL OR p_generation IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_claim';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT existing FROM platform_operations.nocodb_source_operations
    WHERE domain = p_domain AND pair = p_pair FOR UPDATE;
  IF existing.operation_id <> p_operation_id OR
     existing.generation <> p_generation THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_claim_stale';
  END IF;
  IF existing.phase = 'complete' THEN
    RETURN platform_internal.nocodb_operation_result(p_domain, p_pair, false);
  END IF;
  SELECT * INTO mapping FROM platform_operations.managed_nocodb_schema_mappings
    WHERE domain = p_domain AND pair = p_pair;
  IF existing.operation = 'sync' THEN
    IF NOT EXISTS (SELECT FROM platform_operations.managed_nocodb_sources
        WHERE domain = p_domain AND pair = p_pair AND access_kind = 'reader'
          AND state = 'ready' AND source_id IS NOT NULL AND
          base_id IS NOT NULL AND integration_id IS NOT NULL AND
          validated_at IS NOT NULL) OR
       (mapping.operator_schema IS NOT NULL AND NOT EXISTS (
         SELECT FROM platform_operations.managed_nocodb_sources
         WHERE domain = p_domain AND pair = p_pair AND access_kind = 'operator'
           AND ((state = 'ready' AND source_id IS NOT NULL AND
             base_id IS NOT NULL AND integration_id IS NOT NULL AND
             validated_at IS NOT NULL) OR
             (state = 'awaiting_grants' AND source_id IS NULL AND
             base_id IS NULL AND integration_id IS NULL AND
             credential_generation = 0)))) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_sources_not_ready';
    END IF;
  ELSE
    IF NOT EXISTS (SELECT FROM platform_operations.managed_nocodb_sources
        WHERE domain = p_domain AND pair = p_pair AND
          access_kind = existing.access_kind AND state = 'ready' AND
          source_id IS NOT NULL AND base_id IS NOT NULL AND
          integration_id IS NOT NULL AND validated_at IS NOT NULL) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_source_not_ready';
    END IF;
  END IF;
  IF existing.operation = 'sync' THEN
    IF NOT COALESCE((platform_operations.validate_nocodb_access(
        p_domain, p_pair, 'reader')->>'valid')::boolean, false) OR
       (mapping.operator_schema IS NOT NULL AND EXISTS (
         SELECT FROM platform_operations.managed_nocodb_sources
         WHERE domain = p_domain AND pair = p_pair AND access_kind = 'operator'
           AND state = 'ready') AND NOT COALESCE(
         (platform_operations.validate_nocodb_access(
           p_domain, p_pair, 'operator')->>'valid')::boolean, false)) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_source_access_invalid';
    END IF;
  ELSIF NOT COALESCE((platform_operations.validate_nocodb_access(
      p_domain, p_pair, existing.access_kind)->>'valid')::boolean, false) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_source_access_invalid';
  END IF;
  UPDATE platform_operations.nocodb_source_operations
    SET phase = 'complete', updated_at = clock_timestamp(), error_code = NULL
    WHERE domain = p_domain AND pair = p_pair;
  PERFORM platform_internal.bump_generation();
  RETURN platform_internal.nocodb_operation_result(p_domain, p_pair, false);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.nocodb_pair_role(
  p_domain text, p_pair text, p_access_kind text
)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_pair IS NULL OR (p_pair <> 'default' AND
      p_pair !~ '^[a-z][a-z0-9_]{0,23}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_pair';
  END IF;
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  RETURN (CASE WHEN p_pair = 'default' THEN p_domain ELSE
    'nocodb_' || md5(p_domain || ':' || p_pair) END) ||
    (CASE WHEN p_access_kind = 'reader' THEN '_reader' ELSE '_operator' END);
END;
$function$;
CREATE OR REPLACE FUNCTION platform_internal.assert_nocodb_access_kind(p_access_kind text)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  IF p_access_kind IS NULL OR p_access_kind NOT IN ('reader', 'operator') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_access_kind';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.assert_nocodb_identifier(
  p_value text,
  p_error text
)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  IF p_value IS NULL OR p_value = '' OR length(p_value) > 512 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = p_error;
  END IF;
END;
$function$;
CREATE OR REPLACE FUNCTION platform_internal.nocodb_source_result(
  p_domain text,
  p_pair text,
  p_access_kind text
)
RETURNS jsonb
LANGUAGE sql
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT jsonb_build_object(
    'domain', source.domain,
    'accessKind', source.access_kind,
    'role', source.role_name,
    'baseId', source.base_id,
    'integrationId', source.integration_id,
    'sourceCreateJobId', source.source_create_job_id,
    'sourceId', source.source_id,
    'state', source.state,
    'operation', source.operation,
    'generation', source.generation,
    'credentialGeneration', source.credential_generation,
    'operationStartedAt', source.operation_started_at,
    'validatedAt', source.validated_at,
    'updatedAt', source.updated_at,
    'errorCode', source.error_code
  ) || CASE WHEN source.pair = 'default' THEN '{}'::jsonb
    ELSE jsonb_build_object('pair', source.pair) END
  FROM platform_operations.managed_nocodb_sources AS source
  WHERE source.domain = p_domain AND source.pair = p_pair AND source.access_kind = p_access_kind;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.nocodb_source_result(
  p_domain text, p_access_kind text
)
RETURNS jsonb
LANGUAGE sql
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_internal.nocodb_source_result(p_domain, 'default', p_access_kind);
$function$;

CREATE OR REPLACE FUNCTION platform_operations.read_nocodb_source_state(
  p_domain text, p_pair text, p_access_kind text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  IF p_pair IS NULL OR (p_pair <> 'default' AND
      p_pair !~ '^[a-z][a-z0-9_]{0,23}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_pair';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  PERFORM 1 FROM platform_operations.managed_domains WHERE domain = p_domain FOR KEY SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'domain_not_found';
  END IF;
  RETURN COALESCE(platform_internal.nocodb_source_result(
    p_domain, p_pair, p_access_kind), 'null'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.read_nocodb_source_state(
  p_domain text,
  p_access_kind text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  RETURN platform_operations.read_nocodb_source_state(p_domain, 'default', p_access_kind);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.configure_nocodb_schema_mapping(
  p_domain text,
  p_reader_schema text,
  p_operator_schema text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  mapping platform_operations.managed_nocodb_schema_mappings%ROWTYPE;
  reader_name text;
  operator_name text;
  candidate_name text;
  role_valid boolean;
  database_isolation_valid boolean;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_reader_schema IS NULL OR
     p_reader_schema !~ '^[a-z][a-z0-9_]{0,47}$' OR
     p_reader_schema LIKE 'pg\_%' ESCAPE '\' OR
     p_reader_schema LIKE 'platform%' OR
     p_reader_schema IN ('app', 'public', 'read_model', 'operator', 'information_schema') OR
     (p_operator_schema IS NOT NULL AND (
       p_operator_schema !~ '^[a-z][a-z0-9_]{0,47}$' OR
       p_operator_schema LIKE 'pg\_%' ESCAPE '\' OR
       p_operator_schema LIKE 'platform%' OR
       p_operator_schema IN ('app', 'public', 'read_model', 'operator', 'information_schema') OR
       p_operator_schema = p_reader_schema)) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_schema_mapping';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT managed FROM platform_operations.managed_domains
  WHERE domain = p_domain;
  IF managed.state <> 'ready' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'domain_not_ready';
  END IF;
  reader_name := p_domain || '_reader';
  operator_name := CASE WHEN p_operator_schema IS NULL THEN NULL
    ELSE p_domain || '_operator' END;
  SELECT * INTO mapping FROM platform_operations.managed_nocodb_schema_mappings
  WHERE domain = p_domain AND pair = 'default';
  IF FOUND THEN
    IF mapping.reader_schema <> p_reader_schema OR
       mapping.operator_schema IS DISTINCT FROM p_operator_schema THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_schema_mapping_frozen';
    END IF;
    IF EXISTS (SELECT FROM platform_operations.managed_nocodb_sources
      WHERE domain = p_domain AND pair = 'default' AND (access_kind = 'reader' OR
        state <> 'awaiting_grants' OR source_id IS NOT NULL OR
        integration_id IS NOT NULL OR base_id IS NOT NULL)) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_already_registered';
    END IF;
  ELSE
    IF EXISTS (SELECT FROM platform_operations.managed_nocodb_sources
               WHERE domain = p_domain AND pair = 'default') THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_already_registered';
    END IF;
    IF EXISTS (SELECT FROM pg_roles WHERE rolname IN (reader_name, operator_name)) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_role_collision';
    END IF;
    -- Reserve the mapping, create both candidates, and advance backup freshness
    -- in one independently committed transaction. No existing role is adopted.
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format($sql$
        DO $guard$
        BEGIN
          IF EXISTS (
            SELECT FROM pg_database AS database
            CROSS JOIN LATERAL aclexplode(COALESCE(database.datacl,
              acldefault('d', database.datdba))) AS privilege
            WHERE database.datallowconn AND privilege.grantee = 0
              AND privilege.privilege_type = 'CONNECT'
          ) THEN
            RAISE EXCEPTION USING ERRCODE = '55000',
              MESSAGE = 'nocodb_public_database_connect';
          END IF;
        END;
        $guard$;
        INSERT INTO platform_operations.managed_nocodb_schema_mappings
          (domain, reader_schema, operator_schema) VALUES (%1$L, %2$L, %3$L);
        CREATE ROLE %4$I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
          NOINHERIT NOREPLICATION NOBYPASSRLS;
        %5$s
        DO $guard$
        BEGIN
          IF EXISTS (
            SELECT FROM pg_database AS database WHERE database.datallowconn
              AND (has_database_privilege(%6$L::name, database.datname, 'CONNECT') OR
                COALESCE(has_database_privilege(%7$L::name, database.datname, 'CONNECT'), false))
          ) THEN
            RAISE EXCEPTION USING ERRCODE = '55000',
              MESSAGE = 'nocodb_role_not_dedicated';
          END IF;
        END;
        $guard$;
        UPDATE platform_operations.platform_generation
          SET generation = generation + 1 WHERE singleton;
      $sql$,
        p_domain, p_reader_schema, p_operator_schema, reader_name,
        CASE WHEN operator_name IS NULL THEN '' ELSE format(
          'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;',
          operator_name) END,
        reader_name, operator_name)
    );
  END IF;
  FOREACH candidate_name IN ARRAY ARRAY[reader_name, operator_name] LOOP
    IF candidate_name IS NULL THEN
      CONTINUE;
    END IF;
    SELECT NOT role.rolcanlogin AND NOT role.rolsuper AND NOT role.rolcreatedb AND
      NOT role.rolcreaterole AND NOT role.rolinherit AND NOT role.rolreplication AND
      NOT role.rolbypassrls AND NOT EXISTS (
        SELECT FROM pg_auth_members AS member
        WHERE member.member = role.oid OR member.roleid = role.oid
      ) INTO role_valid
    FROM pg_roles AS role WHERE role.rolname = candidate_name;
    IF NOT COALESCE(role_valid, false) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_role_not_dedicated';
    END IF;
    SELECT COALESCE(bool_and(database.datname = managed.database_name OR
      NOT has_database_privilege(candidate_name, database.datname, 'CONNECT')), false)
    INTO database_isolation_valid FROM pg_database AS database
    WHERE database.datallowconn;
    IF NOT database_isolation_valid THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_role_not_dedicated';
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'domain', p_domain,
    'readerSchema', p_reader_schema,
    'operatorSchema', p_operator_schema,
    'readerRole', reader_name,
    'operatorRole', operator_name
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.configure_nocodb_pair(
  p_domain text, p_pair text, p_reader_schema text, p_operator_schema text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  mapping platform_operations.managed_nocodb_schema_mappings%ROWTYPE;
  reader_name text;
  operator_name text;
  candidate_name text;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_pair IS NULL OR p_pair = 'default' OR p_pair !~ '^[a-z][a-z0-9_]{0,23}$' OR
     p_reader_schema IS NULL OR p_reader_schema !~ '^[a-z][a-z0-9_]{0,47}$' OR
     p_reader_schema LIKE 'pg\_%' ESCAPE '\' OR
     p_reader_schema LIKE 'platform%' OR
     p_reader_schema IN ('app', 'public', 'read_model', 'operator', 'information_schema') OR
     (p_operator_schema IS NOT NULL AND (
       p_operator_schema !~ '^[a-z][a-z0-9_]{0,47}$' OR
       p_operator_schema LIKE 'pg\_%' ESCAPE '\' OR
       p_operator_schema LIKE 'platform%' OR
       p_operator_schema IN ('app', 'public', 'read_model', 'operator', 'information_schema') OR
       p_operator_schema = p_reader_schema)) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_pair_mapping';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT managed FROM platform_operations.managed_domains
    WHERE domain = p_domain;
  IF managed.state <> 'ready' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'domain_not_ready';
  END IF;
  reader_name := platform_internal.nocodb_pair_role(p_domain, p_pair, 'reader');
  operator_name := CASE WHEN p_operator_schema IS NULL THEN NULL ELSE
    platform_internal.nocodb_pair_role(p_domain, p_pair, 'operator') END;
  SELECT * INTO mapping FROM platform_operations.managed_nocodb_schema_mappings
    WHERE domain = p_domain AND pair = p_pair;
  IF FOUND THEN
    IF mapping.reader_schema IS DISTINCT FROM p_reader_schema OR
       mapping.operator_schema IS DISTINCT FROM p_operator_schema THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_pair_mapping_frozen';
    END IF;
  ELSE
    IF EXISTS (
      SELECT FROM platform_operations.managed_nocodb_schema_mappings AS other
      WHERE other.domain = p_domain AND other.pair <> p_pair AND
        (other.reader_schema IN (p_reader_schema, p_operator_schema) OR
         other.operator_schema IN (p_reader_schema, p_operator_schema))
    ) OR EXISTS (
      SELECT FROM pg_roles WHERE rolname IN (reader_name, operator_name)
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_pair_collision';
    END IF;
    -- The reservation and role creation commit together in the control database.
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format($sql$
        INSERT INTO platform_operations.managed_nocodb_schema_mappings
          (domain, pair, reader_schema, operator_schema)
          VALUES (%1$L, %2$L, %3$L, %4$L);
        CREATE ROLE %5$I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
          NOINHERIT NOREPLICATION NOBYPASSRLS;
        %6$s
        UPDATE platform_operations.platform_generation
          SET generation = generation + 1 WHERE singleton;
      $sql$, p_domain, p_pair, p_reader_schema, p_operator_schema, reader_name,
      CASE WHEN operator_name IS NULL THEN '' ELSE format(
        'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;',
        operator_name) END)
    );
  END IF;
  FOREACH candidate_name IN ARRAY ARRAY[reader_name, operator_name] LOOP
    IF candidate_name IS NULL THEN CONTINUE; END IF;
    IF NOT EXISTS (
      SELECT FROM pg_roles AS role WHERE role.rolname = candidate_name AND
        (NOT role.rolcanlogin OR EXISTS (
          SELECT FROM platform_operations.managed_nocodb_sources AS source
          WHERE source.domain = p_domain AND source.pair = p_pair AND
            source.role_name = candidate_name AND source.credential_generation > 0 AND
            source.state IN ('provisioning', 'waiting_for_source', 'ready', 'rotating', 'error')
        )) AND NOT role.rolsuper AND NOT role.rolcreatedb AND
        NOT role.rolcreaterole AND NOT role.rolinherit AND NOT role.rolreplication AND
        NOT role.rolbypassrls AND NOT EXISTS (
          SELECT FROM pg_auth_members AS member
          WHERE member.member = role.oid OR member.roleid = role.oid
        )
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'nocodb_pair_role_invalid';
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'domain', p_domain, 'pair', p_pair,
    'readerSchema', p_reader_schema, 'operatorSchema', p_operator_schema,
    'readerRole', reader_name, 'operatorRole', operator_name
  );
END;
$function$;

\ir nocodb-metadata.sql

CREATE OR REPLACE FUNCTION platform_operations.prepare_nocodb_access(p_domain text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  mapping platform_operations.managed_nocodb_schema_mappings%ROWTYPE;
  operator_source platform_operations.managed_nocodb_sources%ROWTYPE;
  reader_source platform_operations.managed_nocodb_sources%ROWTYPE;
  reader_name text;
  operator_name text;
  reader_eligible boolean;
  operator_requested boolean;
  operator_eligible boolean := false;
  reader_authority jsonb;
  operator_authority jsonb;
  reader_expect_login boolean;
  operator_expect_login boolean;
  operator_source_exists boolean := false;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT managed FROM platform_operations.managed_domains
  WHERE domain = p_domain FOR UPDATE;
  IF managed.state <> 'ready' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'domain_not_ready';
  END IF;
  reader_name := p_domain || '_reader';
  operator_name := p_domain || '_operator';
  SELECT * INTO mapping FROM platform_operations.managed_nocodb_schema_mappings
  WHERE domain = p_domain AND pair = 'default';
  IF FOUND THEN
    -- Custom grants belong to the domain migration. This path is observational
    -- toward every domain schema, object, and default ACL.
    SELECT * INTO reader_source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = 'default' AND access_kind = 'reader' FOR UPDATE;
    reader_expect_login := FOUND AND reader_source.state IN
      ('provisioning', 'waiting_for_source', 'ready', 'rotating');
    IF FOUND AND reader_source.state = 'error' AND
       reader_source.operation = 'sync' AND reader_source.source_id IS NULL AND
       reader_source.credential_generation > 0 THEN
      SELECT rolcanlogin INTO reader_expect_login FROM pg_roles
      WHERE rolname = reader_name;
    ELSIF FOUND AND reader_source.state = 'error' AND
          reader_source.source_id IS NOT NULL THEN
      reader_expect_login := true;
    END IF;
    reader_eligible := platform_internal.query_boolean(managed.database_name,
      format('SELECT EXISTS (SELECT FROM pg_namespace WHERE nspname = %L)',
        mapping.reader_schema));
    IF reader_eligible THEN
      reader_authority := platform_internal.validate_nocodb_access_authority(
        p_domain, 'reader', reader_name, reader_expect_login);
      reader_eligible := COALESCE((reader_authority->>'valid')::boolean, false);
    END IF;
    operator_requested := mapping.operator_schema IS NOT NULL;
    IF operator_requested THEN
      SELECT * INTO operator_source FROM platform_operations.managed_nocodb_sources
      WHERE domain = p_domain AND pair = 'default' AND access_kind = 'operator' FOR UPDATE;
      operator_source_exists := FOUND;
      operator_expect_login := operator_source_exists AND operator_source.state IN
        ('provisioning', 'waiting_for_source', 'ready', 'rotating');
      IF operator_source_exists AND operator_source.state = 'error' AND
         operator_source.operation = 'sync' AND operator_source.source_id IS NULL AND
         operator_source.credential_generation > 0 THEN
        SELECT rolcanlogin INTO operator_expect_login FROM pg_roles
        WHERE rolname = operator_name;
      ELSIF operator_source_exists AND operator_source.state = 'error' AND
            operator_source.source_id IS NOT NULL THEN
        operator_expect_login := true;
      END IF;
      operator_eligible := platform_internal.query_boolean(managed.database_name,
        format('SELECT EXISTS (SELECT FROM pg_namespace WHERE nspname = %L)',
          mapping.operator_schema));
      IF operator_eligible THEN
        operator_authority := platform_internal.validate_nocodb_access_authority(
          p_domain, 'operator', operator_name, operator_expect_login);
        operator_eligible := COALESCE((operator_authority->>'valid')::boolean, false);
      END IF;
      IF NOT operator_eligible AND
         (NOT operator_source_exists OR
          (operator_source.state IN ('awaiting_grants', 'error') AND
           operator_source.source_id IS NULL)) THEN
        IF NOT operator_source_exists OR operator_source.state <> 'awaiting_grants' THEN
          next_generation := platform_internal.bump_generation();
          INSERT INTO platform_operations.managed_nocodb_sources (
            domain, access_kind, role_name, state, operation, generation,
            credential_generation, operation_started_at, updated_at, error_code
          ) VALUES (
            p_domain, 'operator', operator_name, 'awaiting_grants', 'sync',
            next_generation, 0, clock_timestamp(), clock_timestamp(), NULL
          ) ON CONFLICT (domain, pair, access_kind) DO UPDATE SET
            state = 'awaiting_grants', operation = 'sync',
            generation = EXCLUDED.generation,
            operation_started_at = EXCLUDED.operation_started_at,
            updated_at = EXCLUDED.updated_at, error_code = NULL;
        END IF;
      END IF;
    END IF;
    RETURN jsonb_build_object(
      'domain', p_domain,
      'readerRole', reader_name,
      'readerEligible', reader_eligible,
      'readerSchema', mapping.reader_schema,
      'operatorRequested', operator_requested,
      'operatorRole', CASE WHEN operator_requested THEN operator_name ELSE NULL END,
      'operatorEligible', operator_eligible,
      'operatorSchema', mapping.operator_schema
    );
  END IF;
  reader_eligible := platform_internal.query_boolean(
    managed.database_name,
    'SELECT EXISTS (SELECT FROM pg_namespace WHERE nspname = ''read_model'')'
  );
  IF NOT reader_eligible THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'read_model_missing';
  END IF;
  operator_requested := platform_internal.query_boolean(
    managed.database_name,
    'SELECT EXISTS (SELECT FROM pg_namespace WHERE nspname = ''operator'')'
  );
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = reader_name) THEN
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS', reader_name)
    );
  END IF;
  SELECT * INTO reader_source FROM platform_operations.managed_nocodb_sources
  WHERE domain = p_domain AND pair = 'default' AND access_kind = 'reader' FOR UPDATE;
  reader_expect_login := FOUND AND reader_source.state IN ('provisioning', 'waiting_for_source', 'ready', 'rotating');
  IF NOT reader_expect_login THEN
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format('ALTER ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS', reader_name)
    );
  END IF;
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format('REVOKE ALL ON DATABASE %1$I FROM %2$I; GRANT CONNECT ON DATABASE %1$I TO %2$I',
      managed.database_name, reader_name)
  );
  PERFORM platform_internal.exec_in_database(
    managed.database_name,
    format(
      'REVOKE ALL ON SCHEMA public FROM PUBLIC; REVOKE ALL ON SCHEMA public, app, read_model FROM %1$I; REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public, app, read_model FROM %1$I; REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public, app, read_model FROM %1$I; GRANT USAGE ON SCHEMA read_model TO %1$I; GRANT SELECT ON ALL TABLES IN SCHEMA read_model TO %1$I; ALTER DEFAULT PRIVILEGES FOR ROLE %2$I IN SCHEMA read_model REVOKE ALL ON TABLES FROM %1$I; ALTER DEFAULT PRIVILEGES FOR ROLE %2$I IN SCHEMA read_model GRANT SELECT ON TABLES TO %1$I',
      reader_name, managed.owner_role)
  );
  reader_authority := platform_internal.validate_nocodb_access_authority(
    p_domain, 'reader', reader_name, reader_expect_login
  );
  reader_eligible := COALESCE((reader_authority->>'valid')::boolean, false);
  IF NOT reader_eligible THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'reader_access_not_eligible';
  END IF;
  IF operator_requested THEN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = operator_name) THEN
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS', operator_name)
      );
    END IF;
    SELECT * INTO operator_source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = 'default' AND access_kind = 'operator' FOR UPDATE;
    operator_source_exists := FOUND;
    operator_expect_login := operator_source_exists AND operator_source.state IN ('provisioning', 'waiting_for_source', 'ready', 'rotating');
    IF NOT operator_expect_login THEN
      PERFORM platform_internal.exec_in_database(
        'automation_data_control',
        format('ALTER ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS', operator_name)
      );
    END IF;
    PERFORM platform_internal.exec_in_database(
      'automation_data_control',
      format('REVOKE ALL ON DATABASE %1$I FROM %2$I; GRANT CONNECT ON DATABASE %1$I TO %2$I',
        managed.database_name, operator_name)
    );
    PERFORM platform_internal.exec_in_database(
      managed.database_name,
      format('REVOKE ALL ON SCHEMA operator FROM %1$I; REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA operator FROM %1$I; REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA operator FROM %1$I', reader_name)
    );
    operator_eligible := platform_internal.query_boolean(
      managed.database_name,
      format(
        'SELECT (EXISTS (SELECT FROM pg_class AS relation CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault(''r'', relation.relowner))) AS acl WHERE relation.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = ''operator'') AND relation.relkind IN (''r'', ''p'', ''v'', ''m'') AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L) AND acl.privilege_type IN (''INSERT'', ''UPDATE'', ''DELETE'')) OR EXISTS (SELECT FROM pg_attribute AS relation_attribute CROSS JOIN LATERAL aclexplode(relation_attribute.attacl) AS acl WHERE relation_attribute.attrelid IN (SELECT oid FROM pg_class WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = ''operator'') AND relkind IN (''r'', ''p'', ''v'', ''m'')) AND relation_attribute.attnum > 0 AND NOT relation_attribute.attisdropped AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L) AND acl.privilege_type IN (''INSERT'', ''UPDATE''))) AND NOT EXISTS (SELECT FROM pg_namespace AS namespace WHERE namespace.nspname NOT IN (''pg_catalog'', ''information_schema'', ''operator'') AND (has_schema_privilege(%1$L, namespace.nspname, ''USAGE'') OR has_schema_privilege(%1$L, namespace.nspname, ''CREATE'')))',
        operator_name)
    );
    operator_eligible := operator_eligible AND platform_internal.query_boolean(
      managed.database_name,
      format(
        'SELECT NOT EXISTS (SELECT FROM pg_class AS relation JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname NOT IN (''pg_catalog'', ''information_schema'', ''operator'') AND (has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''SELECT'') OR has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''INSERT'') OR has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''UPDATE'') OR has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''DELETE'') OR has_any_column_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''SELECT,INSERT,UPDATE,REFERENCES''))) AND NOT EXISTS (SELECT FROM pg_class AS relation JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname NOT IN (''pg_catalog'', ''information_schema'', ''operator'') AND relation.relkind = ''S'' AND (has_sequence_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''USAGE'') OR has_sequence_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''SELECT'') OR has_sequence_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''UPDATE'')))',
        operator_name)
    );
    operator_authority := platform_internal.validate_nocodb_access_authority(
      p_domain, 'operator', operator_name, operator_expect_login
    );
    operator_eligible := COALESCE((operator_authority->>'valid')::boolean, false);
    IF operator_requested AND NOT operator_eligible THEN
      IF operator_source_exists AND (operator_source.state NOT IN ('awaiting_grants', 'error') OR operator_source.source_id IS NOT NULL) THEN
        NULL;
      ELSE
      next_generation := platform_internal.bump_generation();
      INSERT INTO platform_operations.managed_nocodb_sources (
        domain, access_kind, role_name, state, operation, generation, credential_generation,
        operation_started_at, updated_at, error_code
      ) VALUES (
        p_domain, 'operator', operator_name, 'awaiting_grants', 'sync', next_generation, 0,
        clock_timestamp(), clock_timestamp(), NULL
      ) ON CONFLICT (domain, pair, access_kind) DO UPDATE SET
        role_name = EXCLUDED.role_name,
        state = 'awaiting_grants',
        operation = 'sync',
        generation = EXCLUDED.generation,
        operation_started_at = EXCLUDED.operation_started_at,
        updated_at = EXCLUDED.updated_at,
        error_code = NULL;
      END IF;
    END IF;
  END IF;
  RETURN jsonb_build_object(
    'domain', p_domain,
    'readerRole', reader_name,
    'readerEligible', reader_eligible,
    'readerSchema', 'read_model',
    'operatorRequested', operator_requested,
    'operatorRole', CASE WHEN operator_requested THEN operator_name ELSE NULL END,
    'operatorEligible', operator_eligible,
    'operatorSchema', CASE WHEN operator_requested THEN 'operator' ELSE NULL END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.prepare_nocodb_access(
  p_domain text, p_pair text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  mapping platform_operations.managed_nocodb_schema_mappings%ROWTYPE;
  reader_source platform_operations.managed_nocodb_sources%ROWTYPE;
  operator_source platform_operations.managed_nocodb_sources%ROWTYPE;
  reader_name text;
  operator_name text;
  reader_eligible boolean;
  operator_eligible boolean := false;
  reader_login boolean := false;
  operator_login boolean := false;
BEGIN
  IF p_pair = 'default' THEN
    RETURN platform_operations.prepare_nocodb_access(p_domain);
  END IF;
  PERFORM platform_internal.assert_domain(p_domain);
  IF p_pair IS NULL OR p_pair !~ '^[a-z][a-z0-9_]{0,23}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_pair';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT managed FROM platform_operations.managed_domains
    WHERE domain = p_domain;
  IF managed.state <> 'ready' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'domain_not_ready';
  END IF;
  SELECT * INTO STRICT mapping FROM platform_operations.managed_nocodb_schema_mappings
    WHERE domain = p_domain AND pair = p_pair;
  reader_name := platform_internal.nocodb_pair_role(p_domain, p_pair, 'reader');
  operator_name := CASE WHEN mapping.operator_schema IS NULL THEN NULL ELSE
    platform_internal.nocodb_pair_role(p_domain, p_pair, 'operator') END;
  SELECT * INTO reader_source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = p_pair AND access_kind = 'reader';
  IF FOUND THEN
    reader_login := reader_source.state IN
      ('provisioning', 'waiting_for_source', 'ready', 'rotating');
    IF reader_source.state = 'error' THEN
      SELECT rolcanlogin INTO reader_login FROM pg_roles WHERE rolname = reader_name;
    END IF;
  END IF;
  reader_eligible := platform_internal.query_boolean(managed.database_name,
    format('SELECT EXISTS (SELECT FROM pg_namespace WHERE nspname = %L)',
      mapping.reader_schema));
  IF reader_eligible THEN
    reader_eligible := COALESCE((platform_internal.validate_nocodb_access_authority(
      p_domain, p_pair, 'reader', reader_name, reader_login)->>'valid')::boolean, false);
  END IF;
  IF NOT reader_eligible AND reader_source.domain IS NULL THEN
    INSERT INTO platform_operations.managed_nocodb_sources (
      domain, pair, access_kind, role_name, state, operation, generation,
      credential_generation
    ) VALUES (
      p_domain, p_pair, 'reader', reader_name, 'awaiting_grants', 'sync',
      platform_internal.bump_generation(), 0
    ) ON CONFLICT (domain, pair, access_kind) DO NOTHING;
  END IF;
  IF operator_name IS NOT NULL THEN
    SELECT * INTO operator_source FROM platform_operations.managed_nocodb_sources
      WHERE domain = p_domain AND pair = p_pair AND access_kind = 'operator';
    IF FOUND THEN
      operator_login := operator_source.state IN
        ('provisioning', 'waiting_for_source', 'ready', 'rotating');
      IF operator_source.state = 'error' THEN
        SELECT rolcanlogin INTO operator_login FROM pg_roles WHERE rolname = operator_name;
      END IF;
    END IF;
    operator_eligible := platform_internal.query_boolean(managed.database_name,
      format('SELECT EXISTS (SELECT FROM pg_namespace WHERE nspname = %L)',
        mapping.operator_schema));
    IF operator_eligible THEN
      operator_eligible := COALESCE((platform_internal.validate_nocodb_access_authority(
        p_domain, p_pair, 'operator', operator_name, operator_login)->>'valid')::boolean,
        false);
    END IF;
    IF NOT operator_eligible AND operator_source.domain IS NULL THEN
      INSERT INTO platform_operations.managed_nocodb_sources (
        domain, pair, access_kind, role_name, state, operation, generation,
        credential_generation
      ) VALUES (
        p_domain, p_pair, 'operator', operator_name, 'awaiting_grants', 'sync',
        platform_internal.bump_generation(), 0
      ) ON CONFLICT (domain, pair, access_kind) DO NOTHING;
    END IF;
  END IF;
  RETURN jsonb_build_object(
    'domain', p_domain, 'pair', p_pair, 'readerRole', reader_name,
    'readerEligible', reader_eligible, 'readerSchema', mapping.reader_schema,
    'operatorRequested', operator_name IS NOT NULL, 'operatorRole', operator_name,
    'operatorEligible', operator_eligible, 'operatorSchema', mapping.operator_schema);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.begin_nocodb_source(
  p_domain text,
  p_access_kind text,
  p_base_id text,
  p_password text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  reader_source platform_operations.managed_nocodb_sources%ROWTYPE;
  target_role text;
  prepared jsonb;
  result jsonb;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  PERFORM platform_internal.assert_nocodb_identifier(p_base_id, 'invalid_base_id');
  IF p_password IS NULL OR length(p_password) < 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_generated_password';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO source FROM platform_operations.managed_nocodb_sources
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind FOR UPDATE;
  IF FOUND AND source.state NOT IN ('error', 'awaiting_grants') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  IF FOUND AND p_access_kind = 'reader' AND source.state = 'awaiting_grants' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  IF FOUND AND source.state = 'error' AND source.operation <> 'sync' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  IF FOUND AND source.source_id IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_identity_requires_rotation';
  END IF;
  IF FOUND AND source.base_id IS NOT NULL AND source.base_id <> p_base_id THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'source_base_identity_mismatch';
  END IF;
  prepared := platform_operations.prepare_nocodb_access(p_domain);
  IF p_access_kind = 'reader' AND NOT COALESCE((prepared->>'readerEligible')::boolean, false) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'reader_access_not_eligible';
  END IF;
  IF p_access_kind = 'operator' AND NOT COALESCE((prepared->>'operatorRequested')::boolean, false) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'operator_schema_missing';
  END IF;
  IF p_access_kind = 'operator' AND NOT COALESCE((prepared->>'operatorEligible')::boolean, false) THEN
    RETURN platform_internal.nocodb_source_result(p_domain, p_access_kind);
  END IF;
  target_role := p_domain || CASE p_access_kind WHEN 'reader' THEN '_reader' ELSE '_operator' END;
  IF p_access_kind = 'operator' THEN
    SELECT * INTO STRICT reader_source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = 'default' AND access_kind = 'reader';
    IF reader_source.base_id <> p_base_id THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'operator_base_mismatch';
    END IF;
  END IF;
  next_generation := platform_internal.bump_generation();
  INSERT INTO platform_operations.managed_nocodb_sources (
    domain, access_kind, role_name, base_id, state, operation, generation,
    credential_generation, operation_started_at, updated_at, error_code
  ) VALUES (
    p_domain, p_access_kind, target_role, p_base_id, 'provisioning', 'sync', next_generation,
    1, clock_timestamp(), clock_timestamp(), NULL
  ) ON CONFLICT (domain, pair, access_kind) DO UPDATE SET
    role_name = EXCLUDED.role_name,
    base_id = EXCLUDED.base_id,
    state = 'provisioning', operation = 'sync',
    generation = EXCLUDED.generation,
    credential_generation = platform_operations.managed_nocodb_sources.credential_generation + 1,
    operation_started_at = EXCLUDED.operation_started_at,
    updated_at = EXCLUDED.updated_at,
    error_code = NULL;
  result := platform_internal.nocodb_source_result(p_domain, p_access_kind);
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
      target_role, p_password)
  );
  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.begin_nocodb_source(
  p_domain text, p_pair text, p_access_kind text, p_base_id text,
  p_password text, p_operation_id uuid, p_claim_generation bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  reader_source platform_operations.managed_nocodb_sources%ROWTYPE;
  prepared jsonb;
  target_role text;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  PERFORM platform_internal.assert_nocodb_identifier(p_base_id, 'invalid_base_id');
  IF p_password IS NULL OR length(p_password) < 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_generated_password';
  END IF;
  PERFORM platform_internal.assert_nocodb_claim(
    p_domain, p_pair, 'sync', p_access_kind, p_operation_id, p_claim_generation);
  SELECT * INTO source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind FOR UPDATE;
  IF FOUND AND (source.state NOT IN ('awaiting_grants', 'error') OR
      source.credential_generation > 0 OR source.source_id IS NOT NULL OR
      (source.base_id IS NOT NULL AND source.base_id <> p_base_id)) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  prepared := platform_operations.prepare_nocodb_access(p_domain, p_pair);
  IF NOT COALESCE((prepared->>(CASE WHEN p_access_kind = 'reader'
      THEN 'readerEligible' ELSE 'operatorEligible' END))::boolean, false) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_access_not_eligible';
  END IF;
  IF p_access_kind = 'operator' THEN
    SELECT * INTO STRICT reader_source FROM platform_operations.managed_nocodb_sources
      WHERE domain = p_domain AND pair = p_pair AND access_kind = 'reader';
    IF reader_source.base_id <> p_base_id THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'operator_base_mismatch';
    END IF;
  END IF;
  target_role := platform_internal.nocodb_pair_role(p_domain, p_pair, p_access_kind);
  next_generation := platform_internal.bump_generation();
  INSERT INTO platform_operations.managed_nocodb_sources (
    domain, pair, access_kind, role_name, base_id, state, operation, generation,
    credential_generation, operation_started_at, updated_at, error_code
  ) VALUES (
    p_domain, p_pair, p_access_kind, target_role, p_base_id,
    'provisioning', 'sync', next_generation, 1,
    clock_timestamp(), clock_timestamp(), NULL
  ) ON CONFLICT (domain, pair, access_kind) DO UPDATE SET
    base_id = EXCLUDED.base_id, state = 'provisioning', operation = 'sync',
    generation = EXCLUDED.generation,
    credential_generation = platform_operations.managed_nocodb_sources.credential_generation + 1,
    operation_started_at = EXCLUDED.operation_started_at,
    updated_at = EXCLUDED.updated_at, error_code = NULL;
  PERFORM platform_internal.exec_in_database(
    'automation_data_control', format(
      'ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
      target_role, p_password));
  RETURN platform_internal.nocodb_source_result(p_domain, p_pair, p_access_kind);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_integration(
  p_domain text,
  p_access_kind text,
  p_integration_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  PERFORM platform_internal.assert_nocodb_identifier(p_integration_id, 'invalid_integration_id');
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind FOR UPDATE;
  IF source.state <> 'provisioning' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  IF source.integration_id IS NOT NULL AND source.integration_id <> p_integration_id THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'integration_identity_mismatch';
  END IF;
  IF source.integration_id = p_integration_id THEN
    RETURN platform_internal.nocodb_source_result(p_domain, p_access_kind);
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_nocodb_sources
  SET integration_id = p_integration_id, generation = next_generation,
      updated_at = clock_timestamp(), error_code = NULL
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind;
  RETURN platform_internal.nocodb_source_result(p_domain, p_access_kind);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_integration(
  p_domain text, p_pair text, p_access_kind text, p_integration_id text,
  p_operation_id uuid, p_claim_generation bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  PERFORM platform_internal.assert_nocodb_identifier(p_integration_id, 'invalid_integration_id');
  PERFORM platform_internal.assert_nocodb_claim(
    p_domain, p_pair, 'sync', p_access_kind, p_operation_id, p_claim_generation);
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind FOR UPDATE;
  IF source.state <> 'provisioning' OR
     (source.integration_id IS NOT NULL AND source.integration_id <> p_integration_id) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  IF source.integration_id = p_integration_id THEN
    RETURN platform_internal.nocodb_source_result(p_domain, p_pair, p_access_kind);
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_nocodb_sources
    SET integration_id = p_integration_id, generation = next_generation,
        updated_at = clock_timestamp(), error_code = NULL
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind;
  RETURN platform_internal.nocodb_source_result(p_domain, p_pair, p_access_kind);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_job(
  p_domain text,
  p_access_kind text,
  p_job_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  PERFORM platform_internal.assert_nocodb_identifier(p_job_id, 'invalid_source_job_id');
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind FOR UPDATE;
  IF source.state = 'waiting_for_source' THEN
    IF source.source_create_job_id = p_job_id THEN
      RETURN platform_internal.nocodb_source_result(p_domain, p_access_kind);
    END IF;
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_job_identity_mismatch';
  END IF;
  IF source.state <> 'provisioning' OR source.integration_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_nocodb_sources
  SET source_create_job_id = p_job_id, state = 'waiting_for_source',
      generation = next_generation, updated_at = clock_timestamp(), error_code = NULL
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind;
  RETURN platform_internal.nocodb_source_result(p_domain, p_access_kind);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_job(
  p_domain text, p_pair text, p_access_kind text, p_job_id text,
  p_operation_id uuid, p_claim_generation bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  PERFORM platform_internal.assert_nocodb_identifier(p_job_id, 'invalid_source_job_id');
  PERFORM platform_internal.assert_nocodb_claim(
    p_domain, p_pair, 'sync', p_access_kind, p_operation_id, p_claim_generation);
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind FOR UPDATE;
  IF source.state = 'waiting_for_source' AND source.source_create_job_id = p_job_id THEN
    RETURN platform_internal.nocodb_source_result(p_domain, p_pair, p_access_kind);
  END IF;
  IF source.state <> 'provisioning' OR source.integration_id IS NULL OR
     source.source_create_job_id IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_nocodb_sources
    SET source_create_job_id = p_job_id, state = 'waiting_for_source',
        generation = next_generation, updated_at = clock_timestamp(), error_code = NULL
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind;
  RETURN platform_internal.nocodb_source_result(p_domain, p_pair, p_access_kind);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_ready(
  p_domain text,
  p_access_kind text,
  p_source_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  PERFORM platform_internal.assert_nocodb_identifier(p_source_id, 'invalid_source_id');
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind FOR UPDATE;
  IF source.state = 'ready' THEN
    IF source.source_id = p_source_id THEN
      RETURN platform_internal.nocodb_source_result(p_domain, p_access_kind);
    END IF;
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_identity_mismatch';
  END IF;
  IF source.state NOT IN ('waiting_for_source', 'rotating') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  IF source.state = 'rotating' AND source.source_id <> p_source_id THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_identity_mismatch';
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_nocodb_sources
  SET source_id = p_source_id, state = 'ready', generation = next_generation,
      validated_at = clock_timestamp(), updated_at = clock_timestamp(), error_code = NULL
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind;
  RETURN platform_internal.nocodb_source_result(p_domain, p_access_kind);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_ready(
  p_domain text, p_pair text, p_access_kind text, p_source_id text,
  p_operation_id uuid, p_claim_generation bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  PERFORM platform_internal.assert_nocodb_identifier(p_source_id, 'invalid_source_id');
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind FOR UPDATE;
  PERFORM platform_internal.assert_nocodb_claim(
    p_domain, p_pair, source.operation, p_access_kind,
    p_operation_id, p_claim_generation);
  IF source.state = 'ready' AND source.source_id = p_source_id THEN
    RETURN platform_internal.nocodb_source_result(p_domain, p_pair, p_access_kind);
  END IF;
  IF source.state NOT IN ('waiting_for_source', 'rotating') OR
     (source.state = 'rotating' AND source.source_id <> p_source_id) OR
     (source.state = 'waiting_for_source' AND source.source_create_job_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  IF NOT COALESCE((platform_internal.validate_nocodb_access_authority(
    p_domain, p_pair, p_access_kind, source.role_name, true)->>'valid')::boolean,
    false) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_access_not_eligible';
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_nocodb_sources
    SET source_id = p_source_id, state = 'ready', generation = next_generation,
        validated_at = clock_timestamp(), updated_at = clock_timestamp(), error_code = NULL
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind;
  RETURN platform_internal.nocodb_source_result(p_domain, p_pair, p_access_kind);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_error(
  p_domain text,
  p_access_kind text,
  p_operation text,
  p_error_code text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  IF p_operation IS NULL OR p_operation NOT IN ('sync', 'rotate') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_source_operation';
  END IF;
  IF p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_]{0,63}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_error_code';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind FOR UPDATE;
  IF source.state NOT IN ('provisioning', 'waiting_for_source', 'rotating', 'ready', 'error') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_nocodb_sources
  SET state = 'error', operation = p_operation, generation = next_generation,
      updated_at = clock_timestamp(), error_code = p_error_code
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_error(
  p_domain text, p_pair text, p_access_kind text, p_operation text,
  p_error_code text, p_operation_id uuid, p_claim_generation bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  IF p_operation IS NULL OR p_operation NOT IN ('sync', 'rotate') OR
     p_error_code IS NULL OR p_error_code !~ '^[a-z][a-z0-9_]{0,63}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_source_error';
  END IF;
  PERFORM platform_internal.assert_nocodb_claim(
    p_domain, p_pair, p_operation, p_access_kind, p_operation_id, p_claim_generation);
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind FOR UPDATE;
  IF source.state NOT IN ('provisioning', 'waiting_for_source', 'rotating', 'ready', 'error') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_transition_invalid';
  END IF;
  UPDATE platform_operations.managed_nocodb_sources
    SET state = 'error', operation = p_operation,
        generation = platform_internal.bump_generation(),
        updated_at = clock_timestamp(), error_code = p_error_code
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.rotate_nocodb_source_credential(
  p_domain text,
  p_access_kind text,
  p_password text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  next_generation bigint;
  result jsonb;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  IF p_password IS NULL OR length(p_password) < 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_generated_password';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind FOR UPDATE;
  IF source.state NOT IN ('ready', 'error') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_not_ready';
  END IF;
  IF source.state = 'error' AND source.operation <> 'rotate' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_rotation_retry_invalid';
  END IF;
  IF source.source_id IS NULL OR source.integration_id IS NULL OR source.base_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_rotation_identity_missing';
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_nocodb_sources
  SET state = 'rotating', operation = 'rotate', generation = next_generation,
      credential_generation = credential_generation + 1,
      operation_started_at = clock_timestamp(), updated_at = clock_timestamp(), error_code = NULL
  WHERE domain = p_domain AND pair = 'default' AND access_kind = p_access_kind;
  result := platform_internal.nocodb_source_result(p_domain, p_access_kind);
  PERFORM platform_internal.exec_in_database(
    'automation_data_control',
    format(
      'ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
      source.role_name,
      p_password
    )
  );
  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.rotate_nocodb_source_credential(
  p_domain text, p_pair text, p_access_kind text, p_password text,
  p_operation_id uuid, p_claim_generation bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  next_generation bigint;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  IF p_password IS NULL OR length(p_password) < 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_generated_password';
  END IF;
  PERFORM platform_internal.assert_nocodb_claim(
    p_domain, p_pair, 'rotate', p_access_kind, p_operation_id, p_claim_generation);
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind FOR UPDATE;
  IF source.state NOT IN ('ready', 'rotating', 'error') OR
     (source.state IN ('rotating', 'error') AND
       (source.operation <> 'rotate' OR p_claim_generation <= source.generation)) OR
     source.source_id IS NULL OR
     source.integration_id IS NULL OR source.base_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'source_not_ready';
  END IF;
  next_generation := platform_internal.bump_generation();
  UPDATE platform_operations.managed_nocodb_sources
    SET state = 'rotating', operation = 'rotate', generation = next_generation,
        credential_generation = credential_generation + 1,
        operation_started_at = clock_timestamp(), updated_at = clock_timestamp(),
        error_code = NULL
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind;
  PERFORM platform_internal.exec_in_database(
    'automation_data_control', format(
      'ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
      source.role_name, p_password));
  RETURN platform_internal.nocodb_source_result(p_domain, p_pair, p_access_kind);
END;
$function$;

-- Compatibility SQL entrypoints remain bound to the active default-pair claim.
-- The webhook retains its request shape while the workflow obtains a claim first.
CREATE OR REPLACE FUNCTION platform_operations.begin_nocodb_source(
  p_domain text, p_access_kind text, p_base_id text, p_password text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_operations.begin_nocodb_source(
    p_domain, 'default', p_access_kind, p_base_id, p_password,
    (SELECT operation_id FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'),
    (SELECT generation FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'));
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_integration(
  p_domain text, p_access_kind text, p_integration_id text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_operations.record_nocodb_integration(
    p_domain, 'default', p_access_kind, p_integration_id,
    (SELECT operation_id FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'),
    (SELECT generation FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'));
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_job(
  p_domain text, p_access_kind text, p_job_id text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_operations.record_nocodb_source_job(
    p_domain, 'default', p_access_kind, p_job_id,
    (SELECT operation_id FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'),
    (SELECT generation FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'));
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_ready(
  p_domain text, p_access_kind text, p_source_id text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_operations.record_nocodb_source_ready(
    p_domain, 'default', p_access_kind, p_source_id,
    (SELECT operation_id FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'),
    (SELECT generation FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'));
$function$;

CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_error(
  p_domain text, p_access_kind text, p_operation text, p_error_code text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_operations.record_nocodb_source_error(
    p_domain, 'default', p_access_kind, p_operation, p_error_code,
    (SELECT operation_id FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'),
    (SELECT generation FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'));
$function$;

CREATE OR REPLACE FUNCTION platform_operations.rotate_nocodb_source_credential(
  p_domain text, p_access_kind text, p_password text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_operations.rotate_nocodb_source_credential(
    p_domain, 'default', p_access_kind, p_password,
    (SELECT operation_id FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'),
    (SELECT generation FROM platform_operations.nocodb_source_operations
      WHERE domain = p_domain AND pair = 'default'));
$function$;

CREATE OR REPLACE FUNCTION platform_internal.public_data_privileges_denied(p_database text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_internal.query_boolean(p_database, $sql$
    SELECT NOT EXISTS (
      SELECT FROM pg_class AS relation
      JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl,
        acldefault((CASE WHEN relation.relkind = 'S' THEN 'S' ELSE 'r' END)::"char",
          relation.relowner))) AS acl
      WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema')
        AND acl.grantee = 0
    ) AND NOT EXISTS (
      SELECT FROM pg_attribute AS attribute
      JOIN pg_class AS relation ON relation.oid = attribute.attrelid
      JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      CROSS JOIN LATERAL aclexplode(attribute.attacl) AS acl
      WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema')
        AND acl.grantee = 0
    )
  $sql$);
$function$;

CREATE OR REPLACE FUNCTION platform_internal.validate_nocodb_access_authority(
  p_domain text,
  p_pair text,
  p_access_kind text,
  p_role_name text,
  p_expect_login boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  managed platform_operations.managed_domains%ROWTYPE;
  mapping platform_operations.managed_nocodb_schema_mappings%ROWTYPE;
  source platform_operations.managed_nocodb_sources%ROWTYPE;
  target_schema text;
  schema_privileges_valid boolean;
  object_privileges_valid boolean;
  default_privileges_valid boolean;
  outside_schema_denied boolean;
  database_isolation_valid boolean;
  forbidden_attributes_denied boolean;
  forbidden_memberships_denied boolean;
  ddl_denied boolean;
  controlled_dml_present boolean;
  routine_execution_denied boolean;
  grant_options_denied boolean;
  public_privileges_denied boolean;
  login_valid boolean;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  IF p_pair IS NULL OR (p_pair <> 'default' AND
      p_pair !~ '^[a-z][a-z0-9_]{0,23}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_pair';
  END IF;
  IF p_role_name IS NULL OR p_role_name = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_role';
  END IF;
  IF p_role_name <> platform_internal.nocodb_pair_role(p_domain, p_pair, p_access_kind) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_role';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT managed FROM platform_operations.managed_domains WHERE domain = p_domain;
  source.role_name := p_role_name;
  SELECT * INTO mapping FROM platform_operations.managed_nocodb_schema_mappings
  WHERE domain = p_domain AND pair = p_pair;
  target_schema := CASE p_access_kind
    WHEN 'reader' THEN COALESCE(mapping.reader_schema, 'read_model')
    ELSE COALESCE(mapping.operator_schema, 'operator') END;
  schema_privileges_valid := platform_internal.query_boolean(managed.database_name, format(
    'SELECT has_schema_privilege(%1$L, %2$L, ''USAGE'') AND NOT has_schema_privilege(%1$L, %2$L, ''CREATE'')',
    source.role_name, target_schema));
  object_privileges_valid := CASE p_access_kind
    WHEN 'reader' THEN CASE WHEN mapping.domain IS NOT NULL THEN true
      ELSE platform_internal.query_boolean(managed.database_name, format(
      'SELECT COALESCE((SELECT bool_and(has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''SELECT'') AND NOT has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''INSERT'') AND NOT has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''UPDATE'') AND NOT has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''DELETE'') AND NOT has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''TRUNCATE'') AND NOT has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''REFERENCES'') AND NOT has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''TRIGGER'') AND NOT has_any_column_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''INSERT,UPDATE,REFERENCES'')) FROM pg_class AS relation JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname = %2$L AND relation.relkind IN (''r'', ''p'', ''v'', ''m'')), true) AND NOT EXISTS (SELECT FROM pg_class AS relation JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname = %2$L AND relation.relkind = ''S'' AND (has_sequence_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''USAGE'') OR has_sequence_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''SELECT'') OR has_sequence_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''UPDATE'')))',
      source.role_name, target_schema)) END
    WHEN 'operator' THEN platform_internal.query_boolean(managed.database_name, format(
      'SELECT NOT EXISTS (SELECT FROM pg_class AS relation CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault(''r'', relation.relowner))) AS acl WHERE relation.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = %2$L) AND relation.relkind IN (''r'', ''p'', ''v'', ''m'') AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L) AND acl.privilege_type IN (''TRUNCATE'', ''REFERENCES'', ''TRIGGER'')) AND NOT EXISTS (SELECT FROM pg_attribute AS relation_attribute CROSS JOIN LATERAL aclexplode(relation_attribute.attacl) AS acl WHERE relation_attribute.attrelid IN (SELECT oid FROM pg_class WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = %2$L) AND relkind IN (''r'', ''p'', ''v'', ''m'')) AND relation_attribute.attnum > 0 AND NOT relation_attribute.attisdropped AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L) AND acl.privilege_type = ''REFERENCES'') AND NOT EXISTS (SELECT FROM pg_class AS relation CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault(''S'', relation.relowner))) AS acl WHERE relation.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = %2$L) AND relation.relkind = ''S'' AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L) AND acl.privilege_type NOT IN (''USAGE'', ''SELECT'', ''UPDATE''))',
      source.role_name, target_schema))
  END;
  IF p_access_kind = 'operator' THEN
    object_privileges_valid := object_privileges_valid AND platform_internal.query_boolean(
      managed.database_name, format(
        'SELECT NOT EXISTS (SELECT FROM pg_class AS relation JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname = %2$L AND relation.relkind IN (''r'', ''p'', ''v'', ''m'') AND (has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''TRUNCATE'') OR has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''REFERENCES'') OR has_table_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''TRIGGER'') OR has_any_column_privilege(%1$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''REFERENCES'')))',
        source.role_name, target_schema)
    );
  END IF;
  IF mapping.domain IS NOT NULL AND p_access_kind = 'reader' THEN
    -- A reviewed custom mapping can expose only its declared presentation objects.
    object_privileges_valid := platform_internal.query_boolean(managed.database_name,
      format($sql$
        SELECT EXISTS (
          SELECT FROM pg_class AS relation JOIN pg_namespace AS namespace
            ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = %2$L AND relation.relkind IN ('r', 'p', 'v', 'm')
            AND has_table_privilege(%1$L, relation.oid, 'SELECT')
        ) AND NOT EXISTS (
          SELECT FROM pg_class AS relation JOIN pg_namespace AS namespace
            ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = %2$L AND relation.relkind IN ('r', 'p', 'v', 'm')
            AND (has_table_privilege(%1$L, relation.oid,
                 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR
                 has_any_column_privilege(%1$L, relation.oid, 'INSERT,UPDATE,REFERENCES'))
        ) AND NOT EXISTS (
          SELECT FROM pg_class AS relation JOIN pg_namespace AS namespace
            ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = %2$L
            AND CASE WHEN relation.relkind = 'S' THEN
              has_sequence_privilege(%1$L, relation.oid, 'USAGE,SELECT,UPDATE')
            ELSE false END
        )
      $sql$, source.role_name, target_schema));
  END IF;
  default_privileges_valid := CASE p_access_kind
    WHEN 'reader' THEN platform_internal.query_boolean(managed.database_name, format(
      'SELECT COALESCE((SELECT array_agg(DISTINCT acl.privilege_type ORDER BY acl.privilege_type) = ARRAY[''SELECT'']::text[] FROM pg_default_acl AS defaults JOIN pg_namespace AS namespace ON namespace.oid = defaults.defaclnamespace CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS acl WHERE defaults.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = %1$L) AND namespace.nspname = %3$L AND defaults.defaclobjtype = ''r'' AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %2$L)), false) AND NOT EXISTS (SELECT FROM pg_default_acl AS defaults LEFT JOIN pg_namespace AS namespace ON namespace.oid = defaults.defaclnamespace CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS acl WHERE acl.grantee IN (0, (SELECT oid FROM pg_roles WHERE rolname = %2$L)) AND NOT (acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %2$L) AND defaults.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = %1$L) AND namespace.nspname = %3$L AND defaults.defaclobjtype = ''r'' AND acl.privilege_type = ''SELECT''))',
      managed.owner_role, source.role_name, target_schema))
    WHEN 'operator' THEN platform_internal.query_boolean(managed.database_name, format(
      'SELECT NOT EXISTS (SELECT FROM pg_default_acl AS defaults CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS acl WHERE acl.grantee IN (0, (SELECT oid FROM pg_roles WHERE rolname = %1$L)))',
      source.role_name))
  END;
  IF mapping.domain IS NOT NULL AND p_access_kind = 'reader' THEN
    default_privileges_valid := platform_internal.query_boolean(
      managed.database_name,
      format('SELECT NOT EXISTS (SELECT FROM pg_default_acl AS defaults CROSS JOIN LATERAL aclexplode(defaults.defaclacl) AS acl WHERE acl.grantee IN (0, (SELECT oid FROM pg_roles WHERE rolname = %1$L)))',
        source.role_name)
    );
  END IF;
  outside_schema_denied := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT NOT EXISTS (
        SELECT FROM pg_namespace AS namespace
        WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema', %2$L)
          AND (has_schema_privilege(%1$L, namespace.oid, 'USAGE') OR
               has_schema_privilege(%1$L, namespace.oid, 'CREATE'))
      ) AND NOT EXISTS (
        SELECT FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema', %2$L)
          AND CASE WHEN relation.relkind IN ('r', 'p', 'v', 'm', 'f') THEN
            has_table_privilege(%1$L, relation.oid,
              'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR
            has_any_column_privilege(%1$L, relation.oid,
              'SELECT,INSERT,UPDATE,REFERENCES')
          WHEN relation.relkind = 'S' THEN
            has_sequence_privilege(%1$L, relation.oid, 'USAGE,SELECT,UPDATE')
          ELSE false END
      )
    $sql$, source.role_name, target_schema));
  SELECT COALESCE(bool_and(CASE WHEN database.datname = managed.database_name
    THEN has_database_privilege(source.role_name, database.datname, 'CONNECT')
      AND NOT has_database_privilege(source.role_name, database.datname, 'CREATE')
      AND NOT has_database_privilege(source.role_name, database.datname, 'TEMP')
    ELSE NOT has_database_privilege(source.role_name, database.datname, 'CONNECT') END), false)
  INTO database_isolation_valid
  FROM pg_database AS database
  WHERE database.datallowconn;
  SELECT NOT role.rolsuper AND NOT role.rolcreatedb AND NOT role.rolcreaterole AND
    NOT role.rolreplication AND NOT role.rolbypassrls AND NOT role.rolinherit
  INTO forbidden_attributes_denied FROM pg_roles AS role WHERE role.rolname = source.role_name;
  SELECT NOT EXISTS (SELECT FROM pg_auth_members AS member
    WHERE member.member = role.oid OR member.roleid = role.oid)
  INTO forbidden_memberships_denied FROM pg_roles AS role WHERE role.rolname = source.role_name;
  ddl_denied := platform_internal.query_boolean(managed.database_name, format(
    'SELECT NOT has_schema_privilege(%1$L, %2$L, ''CREATE'') AND NOT EXISTS (SELECT FROM pg_namespace WHERE nspowner = (SELECT oid FROM pg_roles WHERE rolname = %1$L)) AND NOT EXISTS (SELECT FROM pg_class WHERE relowner = (SELECT oid FROM pg_roles WHERE rolname = %1$L)) AND NOT EXISTS (SELECT FROM pg_proc WHERE proowner = (SELECT oid FROM pg_roles WHERE rolname = %1$L))',
    source.role_name, target_schema));
  routine_execution_denied := platform_internal.query_boolean(managed.database_name,
    format($sql$
      SELECT NOT EXISTS (
        SELECT FROM pg_proc AS routine JOIN pg_namespace AS namespace
          ON namespace.oid = routine.pronamespace
        WHERE namespace.nspname NOT IN ('pg_catalog', 'information_schema')
          AND has_function_privilege(%1$L, routine.oid, 'EXECUTE')
      )
    $sql$, source.role_name));
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
    $sql$, source.role_name));
  public_privileges_denied := platform_internal.public_data_privileges_denied(
    managed.database_name);
  controlled_dml_present := p_access_kind = 'operator' AND platform_internal.query_boolean(
    managed.database_name, format(
      'SELECT EXISTS (SELECT FROM pg_class AS relation CROSS JOIN LATERAL aclexplode(COALESCE(relation.relacl, acldefault(''r'', relation.relowner))) AS acl WHERE relation.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = %2$L) AND relation.relkind IN (''r'', ''p'', ''v'', ''m'') AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L) AND acl.privilege_type IN (''INSERT'', ''UPDATE'', ''DELETE'')) OR EXISTS (SELECT FROM pg_attribute AS relation_attribute CROSS JOIN LATERAL aclexplode(relation_attribute.attacl) AS acl WHERE relation_attribute.attrelid IN (SELECT oid FROM pg_class WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = %2$L) AND relkind IN (''r'', ''p'', ''v'', ''m'')) AND relation_attribute.attnum > 0 AND NOT relation_attribute.attisdropped AND acl.grantee = (SELECT oid FROM pg_roles WHERE rolname = %1$L) AND acl.privilege_type IN (''INSERT'', ''UPDATE''))',
      source.role_name, target_schema));
  SELECT rolcanlogin INTO login_valid FROM pg_roles WHERE rolname = source.role_name;
  RETURN jsonb_build_object(
    'domain', p_domain, 'accessKind', p_access_kind, 'role', source.role_name,
    'valid', (CASE WHEN p_expect_login THEN COALESCE(login_valid, false) ELSE NOT login_valid END) AND schema_privileges_valid AND object_privileges_valid AND default_privileges_valid AND outside_schema_denied AND database_isolation_valid AND forbidden_attributes_denied AND forbidden_memberships_denied AND ddl_denied AND routine_execution_denied AND grant_options_denied AND public_privileges_denied AND (p_access_kind = 'reader' OR controlled_dml_present),
    'loginValid', COALESCE(login_valid, false),
    'schemaPrivilegesValid', schema_privileges_valid,
    'objectPrivilegesValid', object_privileges_valid,
    'defaultPrivilegesValid', default_privileges_valid,
    'outsideSchemaDenied', outside_schema_denied,
    'databaseIsolationValid', database_isolation_valid,
    'forbiddenAttributesDenied', forbidden_attributes_denied,
    'forbiddenMembershipsDenied', forbidden_memberships_denied,
    'ddlDenied', ddl_denied,
    'controlledDmlPresent', controlled_dml_present,
    'routineExecutionDenied', routine_execution_denied,
    'grantOptionsDenied', grant_options_denied,
    'publicPrivilegesDenied', public_privileges_denied
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.validate_nocodb_access_authority(
  p_domain text, p_access_kind text, p_role_name text, p_expect_login boolean
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_internal.validate_nocodb_access_authority(
    p_domain, 'default', p_access_kind, p_role_name, p_expect_login);
$function$;

CREATE OR REPLACE FUNCTION platform_operations.validate_nocodb_access(
  p_domain text,
  p_pair text,
  p_access_kind text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  source platform_operations.managed_nocodb_sources%ROWTYPE;
BEGIN
  PERFORM platform_internal.assert_domain(p_domain);
  PERFORM platform_internal.assert_nocodb_access_kind(p_access_kind);
  IF p_pair IS NULL OR (p_pair <> 'default' AND
      p_pair !~ '^[a-z][a-z0-9_]{0,23}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_nocodb_pair';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('automation-data:' || p_domain, 0));
  SELECT * INTO STRICT source FROM platform_operations.managed_nocodb_sources
    WHERE domain = p_domain AND pair = p_pair AND access_kind = p_access_kind;
  RETURN platform_internal.validate_nocodb_access_authority(
    p_domain, p_pair, p_access_kind, source.role_name, true);
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.validate_nocodb_access(
  p_domain text,
  p_access_kind text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
  SELECT platform_operations.validate_nocodb_access(p_domain, 'default', p_access_kind);
$function$;

CREATE OR REPLACE FUNCTION platform_operations.capture_backup_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
BEGIN
  IF EXISTS (SELECT FROM platform_operations.managed_application_logins
      WHERE state IN ('activating', 'rotating', 'error')) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'incomplete_application_operation';
  END IF;
  IF EXISTS (SELECT FROM platform_operations.nocodb_source_operations
      WHERE phase <> 'complete') OR
     EXISTS (SELECT FROM platform_operations.managed_nocodb_sources
       WHERE state IN ('provisioning', 'waiting_for_source', 'rotating', 'error')) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'incomplete_nocodb_operation';
  END IF;
  RETURN jsonb_build_object(
    'platformRevision', (SELECT revision
      FROM platform_operations.platform_schema_revision WHERE singleton),
    'generation', (SELECT generation FROM platform_operations.platform_generation WHERE singleton),
    'registry', COALESCE(
      (SELECT jsonb_agg(to_jsonb(managed) ORDER BY managed.domain)
       FROM platform_operations.managed_domains AS managed),
      '[]'::jsonb
    ),
    'nocodbSources', COALESCE(
      (SELECT jsonb_agg(to_jsonb(source) ORDER BY source.domain, source.pair, source.access_kind)
       FROM platform_operations.managed_nocodb_sources AS source),
      '[]'::jsonb
    ),
    'nocodbSchemaMappings', COALESCE(
      (SELECT jsonb_agg(to_jsonb(mapping) ORDER BY mapping.domain, mapping.pair)
       FROM platform_operations.managed_nocodb_schema_mappings AS mapping),
      '[]'::jsonb
    ),
    'nocodbOperations', COALESCE(
      (SELECT jsonb_agg(to_jsonb(claim) ORDER BY claim.domain, claim.pair)
       FROM platform_operations.nocodb_source_operations AS claim),
      '[]'::jsonb
    ),
    'applicationLogins', COALESCE(
      (SELECT jsonb_agg(to_jsonb(login) ORDER BY login.domain, login.application)
       FROM platform_operations.managed_application_logins AS login),
      '[]'::jsonb
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION platform_internal.assert_nocodb_extension_contract()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  installed_revision text;
  required_function regprocedure;
BEGIN
  SELECT revision INTO STRICT installed_revision
  FROM platform_operations.platform_schema_revision
  WHERE singleton = true;
  IF installed_revision <> '026-nocodb-v3' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'unknown_platform_revision';
  END IF;
  IF to_regclass('platform_operations.managed_nocodb_sources') IS NULL OR
     to_regclass('platform_operations.managed_nocodb_schema_mappings') IS NULL OR
     to_regclass('platform_operations.nocodb_source_operations') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'incomplete_nocodb_extension';
  END IF;
  FOREACH required_function IN ARRAY ARRAY[
    'platform_operations.provision_nocodb_metadata(text)'::regprocedure,
    'platform_operations.configure_nocodb_schema_mapping(text,text,text)'::regprocedure,
    'platform_operations.prepare_nocodb_access(text)'::regprocedure,
    'platform_operations.read_nocodb_source_state(text,text)'::regprocedure,
    'platform_operations.begin_nocodb_source(text,text,text,text)'::regprocedure,
    'platform_operations.record_nocodb_integration(text,text,text)'::regprocedure,
    'platform_operations.record_nocodb_source_job(text,text,text)'::regprocedure,
    'platform_operations.record_nocodb_source_ready(text,text,text)'::regprocedure,
    'platform_operations.record_nocodb_source_error(text,text,text,text)'::regprocedure,
    'platform_operations.rotate_nocodb_source_credential(text,text,text)'::regprocedure,
    'platform_operations.validate_nocodb_access(text,text)'::regprocedure,
    'platform_operations.configure_nocodb_pair(text,text,text,text)'::regprocedure,
    'platform_operations.claim_nocodb_operation(text,text,text,text,uuid)'::regprocedure,
    'platform_operations.claim_nocodb_operation(text,text,text,text,uuid,uuid)'::regprocedure,
    'platform_operations.read_nocodb_operation_state(text,text)'::regprocedure,
    'platform_operations.mark_nocodb_operation_uncertain(text,text,uuid,bigint,text)'::regprocedure,
    'platform_operations.complete_nocodb_operation(text,text,uuid,bigint)'::regprocedure,
    'platform_operations.prepare_nocodb_access(text,text)'::regprocedure,
    'platform_operations.begin_nocodb_source(text,text,text,text,text,uuid,bigint)'::regprocedure,
    'platform_operations.record_nocodb_source_ready(text,text,text,text,uuid,bigint)'::regprocedure,
    'platform_operations.rotate_nocodb_source_credential(text,text,text,text,uuid,bigint)'::regprocedure,
    'platform_operations.validate_nocodb_access(text,text,text)'::regprocedure
  ] LOOP
    IF NOT has_function_privilege('automation_data_provisioner', required_function, 'EXECUTE') OR
      has_function_privilege('public', required_function, 'EXECUTE') THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'invalid_nocodb_function_grant';
    END IF;
  END LOOP;
  IF NOT has_function_privilege(
      'automation_data_backup',
      'platform_operations.capture_backup_state()'::regprocedure,
      'EXECUTE'
    ) OR
    (SELECT array_agg(
       (CASE WHEN privilege.grantee = 0 THEN 'PUBLIC'
         ELSE grantee_role.rolname::text END) || '|' ||
       privilege.privilege_type || '|' || privilege.is_grantable::text
       ORDER BY CASE WHEN privilege.grantee = 0 THEN 'PUBLIC'
         ELSE grantee_role.rolname::text END
     )
     FROM pg_proc AS oracle
     CROSS JOIN LATERAL aclexplode(
       COALESCE(oracle.proacl, acldefault('f', oracle.proowner))
     ) AS privilege
     LEFT JOIN pg_roles AS grantee_role ON grantee_role.oid = privilege.grantee
     WHERE oracle.oid = 'platform_operations.read_platform_revision()'::regprocedure
       AND privilege.grantee <> oracle.proowner) IS DISTINCT FROM ARRAY[
         'automation_data_backup|EXECUTE|false',
         'automation_data_provisioner|EXECUTE|false'
       ]::text[] OR
    has_table_privilege('public', 'platform_operations.managed_nocodb_sources', 'SELECT') OR
    has_table_privilege('public', 'platform_operations.managed_nocodb_schema_mappings', 'SELECT') OR
    has_table_privilege('public', 'platform_operations.nocodb_source_operations', 'SELECT') OR
    (SELECT md5(prosrc) FROM pg_proc WHERE oid =
      'platform_operations.capture_backup_state()'::regprocedure) <>
      '56f338a80f1846f7009e5164b0a9c037' OR
    (SELECT md5(prosrc) FROM pg_proc WHERE oid =
      'platform_operations.claim_nocodb_operation(text,text,text,text,uuid,uuid)'::regprocedure) <>
      '1a5e81572c73cdf366b3bb2abd984681' OR
    (SELECT md5(prosrc) FROM pg_proc WHERE oid =
      'platform_operations.complete_nocodb_operation(text,text,uuid,bigint)'::regprocedure) <>
      '259dc1698eddf76399d4680798cc700c' OR
    NOT EXISTS (SELECT FROM pg_constraint WHERE conrelid =
      'platform_operations.managed_nocodb_sources'::regclass AND contype = 'p' AND
      pg_get_constraintdef(oid) = 'PRIMARY KEY (domain, pair, access_kind)') OR
    NOT EXISTS (SELECT FROM pg_constraint WHERE conrelid =
      'platform_operations.managed_nocodb_schema_mappings'::regclass AND contype = 'p' AND
      pg_get_constraintdef(oid) = 'PRIMARY KEY (domain, pair)') OR
    NOT EXISTS (SELECT FROM pg_constraint WHERE conrelid =
      'platform_operations.nocodb_source_operations'::regclass AND contype = 'p' AND
      pg_get_constraintdef(oid) = 'PRIMARY KEY (domain, pair)') OR
    EXISTS (
      SELECT 1
      FROM pg_database AS database
      CROSS JOIN LATERAL aclexplode(
        COALESCE(database.datacl, acldefault('d', database.datdba))
      ) AS privilege
      WHERE database.datname IN ('postgres', 'template1')
        AND privilege.grantee = 0
        AND privilege.privilege_type = 'CONNECT'
    ) OR
    EXISTS (
      SELECT 1 FROM pg_tables
      WHERE schemaname = 'platform_operations'
        AND tablename IN ('managed_nocodb_sources', 'managed_nocodb_schema_mappings',
          'nocodb_source_operations', 'platform_schema_revision')
        AND tableowner <> 'postgres'
    ) OR
    EXISTS (
      SELECT 1
      FROM pg_proc AS procedure
      JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      JOIN pg_roles AS owner_role ON owner_role.oid = procedure.proowner
      WHERE namespace.nspname IN ('platform_operations', 'platform_internal')
        AND (procedure.proname LIKE '%nocodb%' OR
          procedure.proname IN ('capture_backup_state', 'read_platform_revision'))
        AND owner_role.rolname <> 'postgres'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'invalid_nocodb_extension_contract';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION platform_operations.read_platform_revision()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, platform_operations
AS $function$
DECLARE
  installed_revision text;
BEGIN
  PERFORM platform_internal.assert_nocodb_extension_contract();
  PERFORM platform_internal.assert_application_login_contract();
  SELECT revision INTO STRICT installed_revision
  FROM platform_operations.platform_schema_revision
  WHERE singleton = true;
  RETURN installed_revision;
END;
$function$;

REVOKE ALL ON TABLE platform_operations.platform_schema_revision,
  platform_operations.managed_nocodb_sources,
  platform_operations.managed_nocodb_schema_mappings,
  platform_operations.nocodb_source_operations FROM PUBLIC;
REVOKE ALL ON FUNCTION platform_internal.assert_nocodb_access_kind(text),
  platform_internal.nocodb_pair_role(text, text, text),
  platform_internal.nocodb_operation_result(text, text, boolean),
  platform_internal.assert_nocodb_claim(text, text, text, text, uuid, bigint),
  platform_internal.assert_nocodb_identifier(text, text),
  platform_internal.nocodb_source_result(text, text, text),
  platform_internal.nocodb_source_result(text, text),
  platform_internal.public_data_privileges_denied(text),
  platform_internal.validate_nocodb_access_authority(text, text, text, text, boolean),
  platform_internal.validate_nocodb_access_authority(text, text, text, boolean),
  platform_internal.assert_nocodb_extension_contract() FROM PUBLIC;
REVOKE ALL ON FUNCTION platform_operations.provision_nocodb_metadata(text),
  platform_operations.configure_nocodb_pair(text, text, text, text),
  platform_operations.claim_nocodb_operation(text, text, text, text, uuid),
  platform_operations.claim_nocodb_operation(text, text, text, text, uuid, uuid),
  platform_operations.read_nocodb_operation_state(text, text),
  platform_operations.mark_nocodb_operation_uncertain(text, text, uuid, bigint, text),
  platform_operations.complete_nocodb_operation(text, text, uuid, bigint),
  platform_operations.configure_nocodb_schema_mapping(text, text, text),
  platform_operations.prepare_nocodb_access(text, text),
  platform_operations.prepare_nocodb_access(text),
  platform_operations.read_nocodb_source_state(text, text, text),
  platform_operations.read_nocodb_source_state(text, text),
  platform_operations.begin_nocodb_source(text, text, text, text, text, uuid, bigint),
  platform_operations.begin_nocodb_source(text, text, text, text),
  platform_operations.record_nocodb_integration(text, text, text, text, uuid, bigint),
  platform_operations.record_nocodb_integration(text, text, text),
  platform_operations.record_nocodb_source_job(text, text, text, text, uuid, bigint),
  platform_operations.record_nocodb_source_job(text, text, text),
  platform_operations.record_nocodb_source_ready(text, text, text, text, uuid, bigint),
  platform_operations.record_nocodb_source_ready(text, text, text),
  platform_operations.record_nocodb_source_error(text, text, text, text, text, uuid, bigint),
  platform_operations.record_nocodb_source_error(text, text, text, text),
  platform_operations.rotate_nocodb_source_credential(text, text, text, text, uuid, bigint),
  platform_operations.rotate_nocodb_source_credential(text, text, text),
  platform_operations.validate_nocodb_access(text, text, text),
  platform_operations.validate_nocodb_access(text, text),
  platform_operations.read_platform_revision() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION platform_operations.read_nocodb_source_state(text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION platform_operations.provision_nocodb_metadata(text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.configure_nocodb_pair(text, text, text, text)
  TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.claim_nocodb_operation(text, text, text, text, uuid) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.claim_nocodb_operation(text, text, text, text, uuid, uuid) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.read_nocodb_operation_state(text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.mark_nocodb_operation_uncertain(text, text, uuid, bigint, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.complete_nocodb_operation(text, text, uuid, bigint) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.configure_nocodb_schema_mapping(text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.prepare_nocodb_access(text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.prepare_nocodb_access(text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.read_nocodb_source_state(text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.read_nocodb_source_state(text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.begin_nocodb_source(text, text, text, text, text, uuid, bigint) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.begin_nocodb_source(text, text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_nocodb_integration(text, text, text, text, uuid, bigint) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_nocodb_integration(text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_nocodb_source_job(text, text, text, text, uuid, bigint) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_nocodb_source_job(text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_nocodb_source_ready(text, text, text, text, uuid, bigint) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_nocodb_source_ready(text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_nocodb_source_error(text, text, text, text, text, uuid, bigint) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.record_nocodb_source_error(text, text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.rotate_nocodb_source_credential(text, text, text, text, uuid, bigint) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.rotate_nocodb_source_credential(text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.validate_nocodb_access(text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.validate_nocodb_access(text, text, text) TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.read_platform_revision() TO automation_data_provisioner;
GRANT EXECUTE ON FUNCTION platform_operations.capture_backup_state() TO automation_data_backup;
GRANT EXECUTE ON FUNCTION platform_operations.read_platform_revision() TO automation_data_backup;
GRANT SELECT (domain, pair, access_kind, role_name, state, operation_started_at)
  ON platform_operations.managed_nocodb_sources TO automation_data_exporter;
GRANT SELECT (domain, pair, phase, operation_started_at)
  ON platform_operations.nocodb_source_operations TO automation_data_exporter;
GRANT SELECT (domain, pair)
  ON platform_operations.managed_nocodb_schema_mappings TO automation_data_exporter;

INSERT INTO platform_operations.platform_schema_revision (singleton, revision)
VALUES (true, '026-nocodb-v3')
ON CONFLICT (singleton) DO UPDATE SET
  revision = EXCLUDED.revision,
  installed_at = clock_timestamp()
WHERE platform_operations.platform_schema_revision.revision <> EXCLUDED.revision;

SELECT platform_internal.assert_nocodb_extension_contract();
RESET ROLE;
