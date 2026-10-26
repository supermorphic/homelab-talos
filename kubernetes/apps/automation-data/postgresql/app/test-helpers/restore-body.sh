# Optional application probe: application-owned read-only SQL, approved by digest in the
# reviewed allowlist that ships with these immutable helpers. Refuse before connecting.
application_probe_enabled=false
application_probe_sql=''
probe_path="${RESTORE_PROBE_PATH:-/probe/probe.sql}"
probe_allowlist="${RESTORE_PROBE_ALLOWLIST:-/helpers/restore-probes.allow}"
if test -n "${RESTORE_PROBE_SHA256:-}${RESTORE_PROBE_DATABASE:-}" || test -e "$probe_path"; then
  printf '%s\n' 'restore_stage=application-probe-admission'
  printf '%s\n' "${RESTORE_PROBE_SHA256:-}" | grep -Eqx '[0-9a-f]{64}' ||
    restore_fail application-probe-input
  printf '%s\n' "${RESTORE_PROBE_DATABASE:-}" | grep -Eqx '[a-z][a-z0-9_]{0,47}' ||
    restore_fail application-probe-input
  test -f "$probe_path" -a -s "$probe_path" || restore_fail application-probe-input
  probe_digest="$(sha256sum "$probe_path" | cut -d' ' -f1)" ||
    restore_fail application-probe-digest
  test "$probe_digest" = "$RESTORE_PROBE_SHA256" || restore_fail application-probe-digest
  probe_allowed_database="$(awk -v digest="$probe_digest" '
    /^[[:space:]]*(#|$)/ { next }
    NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ ||
      $2 !~ /^[a-z][a-z0-9_]*$/ || length($2) > 48 { malformed = 1; next }
    $1 == digest { count += 1; database = $2 }
    END { if (malformed || count != 1) exit 1; print database }
  ' "$probe_allowlist")" || restore_fail application-probe-authorization
  test "$probe_allowed_database" = "$RESTORE_PROBE_DATABASE" ||
    restore_fail application-probe-authorization
  # A leading backslash would make psql treat the --command string as a meta-command.
  probe_first="$(tr -d ' \t\r\n\f\v' < "$probe_path" | head -c 1)" ||
    restore_fail application-probe-input
  test "$probe_first" != "\\" || restore_fail application-probe-input
  application_probe_sql="$(cat "$probe_path")" || restore_fail application-probe-input
  application_probe_enabled=true
fi

initial_database_count="$(psql --dbname=postgres --tuples-only --no-align \
  --command="SELECT count(*) FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres'")" ||
  restore_fail initial-catalog-query
test "$initial_database_count" = 0 || restore_fail destination-not-empty

printf '%s\n' 'restore_stage=globals-restore'
bootstrap_role_declarations="$(awk '$0 == "CREATE ROLE postgres;" { count += 1 } END { print count + 0 }' \
  "$selected/globals.sql")" || restore_fail globals-bootstrap-inspection
test "$bootstrap_role_declarations" = 1 || restore_fail globals-bootstrap-declaration
umask 077
globals_restore_file=/tmp/restore-globals-without-bootstrap-create.sql
trap 'rm -f -- "$globals_restore_file"' 0
awk '$0 != "CREATE ROLE postgres;"' "$selected/globals.sql" > "$globals_restore_file" ||
  restore_fail globals-bootstrap-filter
psql --dbname=postgres --set=ON_ERROR_STOP=1 --file="$globals_restore_file" \
  >/tmp/restore-globals.log 2>&1 || restore_fail globals-restore
rm -f -- "$globals_restore_file"

printf '%s\n' 'restore_stage=database-restore'
while IFS="$(printf '\t')" read -r record encoded dump_path extra; do
  test "$record" = database || continue
  database_with_sentinel="$(printf '%s' "$encoded" | base64 -d; printf x)"
  database_name="${database_with_sentinel%x}"
  if test "$database_name" = postgres; then
    pg_restore --exit-on-error --dbname=postgres "$selected/$dump_path" \
      >/tmp/restore-database.log 2>&1 || restore_fail database-restore
  else
    pg_restore --exit-on-error --create --dbname=postgres "$selected/$dump_path" \
      >/tmp/restore-database.log 2>&1 || restore_fail database-restore
  fi
done < "$selected/manifest.tsv"

printf '%s\n' 'restore_stage=catalog-validation'
psql --dbname=postgres --tuples-only --no-align --command="
SELECT replace(encode(convert_to(datname, 'UTF8'), 'base64'), E'\\n', '')
FROM pg_database
WHERE datallowconn AND NOT datistemplate
ORDER BY datname;
" | LC_ALL=C sort -u > /tmp/restore-actual-databases-base64 ||
  restore_fail catalog-query
cmp -s /tmp/restore-expected-databases-base64 /tmp/restore-actual-databases-base64 ||
  restore_fail database-set-mismatch

restored_registry_base64="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
WITH registry_text AS (
  SELECT
    'domain' || E'\\t' || 'database_name' || E'\\t' || 'owner_role' || E'\\t' ||
    'migrator_role' || E'\\t' || 'runtime_role' || E'\\t' || 'state' || E'\\t' ||
    'has_reached_ready' || E'\\t' || 'generation' || E'\\t' ||
    'migrator_credential_id' || E'\\t' || 'runtime_credential_id' || E'\\t' ||
    'migrator_credential_updated_at' || E'\\t' || 'runtime_credential_updated_at' || E'\\t' ||
    'operation_started_at' || E'\\t' || 'updated_at' || E'\\t' || 'error_code' ||
    COALESCE(E'\\n' || string_agg(concat_ws(E'\\t', domain, database_name,
      owner_role, migrator_role, runtime_role, state, has_reached_ready::text,
      generation::text, COALESCE(migrator_credential_id, ''),
      COALESCE(runtime_credential_id, ''), COALESCE(migrator_credential_updated_at::text, ''),
      COALESCE(runtime_credential_updated_at::text, ''), operation_started_at::text,
      updated_at::text, COALESCE(error_code, '')), E'\\n' ORDER BY domain), '') AS body
  FROM platform_operations.managed_domains
)
SELECT replace(encode(convert_to(body, 'UTF8'), 'base64'), E'\\n', '') FROM registry_text;
")" || restore_fail registry-query
printf '%s' "$restored_registry_base64" | base64 -d > /tmp/restore-actual-registry ||
  restore_fail registry-decode
cmp -s "$selected/registry.tsv" /tmp/restore-actual-registry ||
  restore_fail registry-mismatch

printf '%s\n' 'restore_stage=permission-restore-comparison'
awk -F '\t' 'NR > 1 && $6 == "ready" { print $1 "\t" $2 }' \
  "$selected/registry.tsv" > /tmp/restore-ready-domains ||
  restore_fail permission-restore-comparison
while IFS="$(printf '\t')" read -r domain database_name extra; do
  test -n "$domain" || continue
  test -n "$database_name" -a -z "${extra:-}" ||
    restore_fail permission-restore-comparison
  printf '%s\n' "$domain" | grep -Eq '^[a-z][a-z0-9_]{0,47}$' ||
    restore_fail permission-restore-comparison
  printf '%s\n' "$database_name" | grep -Eq '^[a-z][a-z0-9_]{0,47}$' ||
    restore_fail permission-restore-comparison
  encoded_database="$(printf '%s' "$database_name" | base64 | tr -d '\n')" ||
    restore_fail permission-restore-comparison
  dump_path="$(awk -F '\t' -v encoded="$encoded_database" '
    $1 == "database" && $2 == encoded { count += 1; path = $3 }
    END { if (count == 1) print path; else exit 1 }
  ' "$selected/manifest.tsv")" || {
    printf 'restore_permission_fidelity_failure domain=%s\n' "$domain" >&2
    restore_fail permission-restore-comparison
  }
  if ! automation_data_compare_restored_permissions \
    "$selected/$dump_path" "$database_name"; then
    printf 'restore_permission_fidelity_failure domain=%s\n' "$domain" >&2
    restore_fail permission-restore-comparison
  fi
done < /tmp/restore-ready-domains

printf '%s\n' 'restore_stage=permission-validation'
permission_contract="$(psql --dbname=automation_data_control --set=ON_ERROR_STOP=1 --tuples-only --no-align --command="
WITH validations AS MATERIALIZED (
  SELECT managed.domain, platform_operations.validate_domain(managed.domain) AS result
  FROM platform_operations.managed_domains AS managed
  WHERE managed.state = 'ready'
), failed_checks AS (
  SELECT validation.domain, expected.name
  FROM validations AS validation
  CROSS JOIN (VALUES
    ('state', to_jsonb('ready'::text)),
    ('ownerNoLogin', 'true'::jsonb),
    ('migratorCanSetOwner', 'true'::jsonb),
    ('runtimeCannotSetOwner', 'true'::jsonb),
    ('migratorControlConnectDenied', 'true'::jsonb),
    ('runtimeControlConnectDenied', 'true'::jsonb),
    ('migratorDomainConnectAllowed', 'true'::jsonb),
    ('runtimeDomainConnectAllowed', 'true'::jsonb),
    ('runtimePrivilegesValid', 'true'::jsonb),
    ('defaultPrivilegesValid', 'true'::jsonb),
    ('crossDomainConnectDenied', 'true'::jsonb),
    ('migratorDdlValid', 'true'::jsonb),
    ('runtimeCrudValid', 'true'::jsonb),
    ('runtimeDdlDenied', 'true'::jsonb),
    ('runtimeOwnerAssumptionDenied', 'true'::jsonb),
    ('runtimeRoleManagementDenied', 'true'::jsonb)
  ) AS expected(name, value)
  WHERE (validation.result->expected.name) IS DISTINCT FROM expected.value
)
SELECT COALESCE(string_agg(
  'restore_permission_failure domain=' || domain || ' check=' || name,
  E'\\n' ORDER BY domain, name
), 'true') FROM failed_checks;
")" || restore_fail permission-query
if test "$permission_contract" != true; then
  printf '%s\n' "$permission_contract" >&2
  restore_fail permission-validation
fi

restored_catalog_state="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
WITH operation_tables AS (
  SELECT array_agg(class.relname::text ORDER BY class.relname) AS names
  FROM pg_class AS class
  JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
  WHERE namespace.nspname = 'platform_operations' AND class.relkind = 'r'
),
operation_functions AS (
  SELECT array_agg(procedure.proname::text ORDER BY procedure.proname) AS names
  FROM pg_proc AS procedure
  JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
  WHERE namespace.nspname = 'platform_operations'
)
SELECT CASE
  WHEN COALESCE(operation_tables.names = ARRAY[
      'logical_backup_status', 'managed_domains', 'platform_generation'
    ]::text[], false) AND
    COALESCE(operation_functions.names = ARRAY[
      'capture_backup_state', 'provision_domain', 'publish_backup',
      'reconcile_domain', 'record_domain_credentials', 'record_operation_error',
      'rotate_domain_credential', 'validate_domain'
    ]::text[], false) AND
    to_regprocedure('platform_operations.provision_domain(text,text,text)') IS NOT NULL AND
    to_regprocedure('platform_operations.reconcile_domain(text)') IS NOT NULL AND
    to_regprocedure('platform_operations.record_domain_credentials(text,text,text,timestamptz,timestamptz)') IS NOT NULL AND
    to_regprocedure('platform_operations.rotate_domain_credential(text,text,text)') IS NOT NULL AND
    to_regprocedure('platform_operations.record_operation_error(text,text)') IS NOT NULL AND
    to_regprocedure('platform_operations.validate_domain(text)') IS NOT NULL AND
    to_regprocedure('platform_operations.capture_backup_state()') IS NOT NULL AND
    to_regprocedure('platform_operations.publish_backup(text,text,text)') IS NOT NULL AND
    NOT EXISTS (
      SELECT 1
      FROM pg_proc AS procedure
      JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname IN ('platform_operations', 'platform_internal')
        AND (procedure.proname = 'assert_nocodb_access_kind' OR
          procedure.proname LIKE '%nocodb%')
    ) THEN '025-baseline'
  WHEN to_regclass('platform_operations.platform_schema_revision') IS NOT NULL AND
    to_regclass('platform_operations.managed_nocodb_sources') IS NOT NULL
    THEN 'upgraded-candidate'
  ELSE 'invalid'
END
FROM operation_tables, operation_functions;
")" || restore_fail platform-catalog-query
case "$restored_catalog_state" in
  025-baseline) restored_platform_revision='025-baseline' ;;
  upgraded-candidate)
    restored_platform_revision="$(psql --dbname=automation_data_control \
      --tuples-only --no-align \
      --command='SELECT platform_operations.read_platform_revision();'
    )" || restore_fail platform-revision-oracle
    case "$restored_platform_revision" in
      026-nocodb-v1 | 026-nocodb-v2 | 026-nocodb-v3 | 026-nocodb-v4) ;;
      *) restore_fail platform-revision-validation ;;
    esac
    ;;
  *) restore_fail platform-catalog-validation ;;
esac

restored_platform_shape="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
WITH captured AS (
  SELECT platform_operations.capture_backup_state() AS state
)
SELECT '$restored_platform_revision'
FROM captured
WHERE
  ('$restored_platform_revision' = '025-baseline' AND
    (SELECT array_agg(key ORDER BY key)
     FROM captured, LATERAL jsonb_object_keys(captured.state) AS key) =
      ARRAY['generation', 'registry']::text[] AND
    jsonb_typeof(captured.state->'generation') = 'number' AND
    jsonb_typeof(captured.state->'registry') = 'array') OR
  ('$restored_platform_revision' = '026-nocodb-v1' AND
    captured.state->>'platformRevision' = '026-nocodb-v1' AND
    (SELECT array_agg(key ORDER BY key)
     FROM captured, LATERAL jsonb_object_keys(captured.state) AS key) =
      ARRAY['generation', 'nocodbSources', 'platformRevision', 'registry']::text[] AND
    jsonb_typeof(captured.state->'generation') = 'number' AND
    jsonb_typeof(captured.state->'registry') = 'array' AND
    jsonb_typeof(captured.state->'nocodbSources') = 'array') OR
  ('$restored_platform_revision' = '026-nocodb-v2' AND
    captured.state->>'platformRevision' = '026-nocodb-v2' AND
    (SELECT array_agg(key ORDER BY key)
     FROM captured, LATERAL jsonb_object_keys(captured.state) AS key) =
      ARRAY['generation', 'nocodbSchemaMappings', 'nocodbSources',
        'platformRevision', 'registry']::text[] AND
    jsonb_typeof(captured.state->'generation') = 'number' AND
    jsonb_typeof(captured.state->'registry') = 'array' AND
    jsonb_typeof(captured.state->'nocodbSources') = 'array' AND
    jsonb_typeof(captured.state->'nocodbSchemaMappings') = 'array') OR
  ('$restored_platform_revision' IN ('026-nocodb-v3', '026-nocodb-v4') AND
    captured.state->>'platformRevision' = '$restored_platform_revision' AND
    (SELECT array_agg(key ORDER BY key)
     FROM captured, LATERAL jsonb_object_keys(captured.state) AS key) =
      ARRAY['applicationLogins', 'generation', 'nocodbOperations',
        'nocodbSchemaMappings', 'nocodbSources', 'platformRevision',
        'registry']::text[] AND
    jsonb_typeof(captured.state->'generation') = 'number' AND
    jsonb_typeof(captured.state->'registry') = 'array' AND
    jsonb_typeof(captured.state->'nocodbSources') = 'array' AND
    jsonb_typeof(captured.state->'nocodbSchemaMappings') = 'array' AND
    jsonb_typeof(captured.state->'nocodbOperations') = 'array' AND
    jsonb_typeof(captured.state->'applicationLogins') = 'array');
")" || restore_fail platform-state-query
test "$restored_platform_shape" = "$restored_platform_revision" ||
  restore_fail platform-state-validation
case "$restored_platform_revision" in
  025-baseline) ;;
  026-nocodb-v1 | 026-nocodb-v2)
    nocodb_permission_contract="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
SELECT COALESCE(bool_and(
  source.state = 'ready' AND
  (platform_operations.validate_nocodb_access(
    source.domain, source.access_kind
  )->>'valid')::boolean
), true)::text
FROM platform_operations.managed_nocodb_sources AS source
WHERE source.state = 'ready';
")" || restore_fail nocodb-permission-query
    test "$nocodb_permission_contract" = true || restore_fail nocodb-permission-validation
    ;;
  026-nocodb-v3 | 026-nocodb-v4)
    # Name each failing source and check, as the domain permission stage does.
    nocodb_permission_contract="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
WITH validations AS MATERIALIZED (
  SELECT source.domain, source.pair, source.access_kind,
    platform_operations.validate_nocodb_access(
      source.domain, source.pair, source.access_kind
    ) AS result
  FROM platform_operations.managed_nocodb_sources AS source
  WHERE source.state = 'ready'
), failed_checks AS (
  SELECT validation.domain, validation.pair, validation.access_kind,
    COALESCE(checks.name, 'valid') AS name
  FROM validations AS validation
  LEFT JOIN LATERAL (
    SELECT entry.key AS name
    FROM jsonb_each(validation.result) AS entry
    WHERE entry.key <> 'valid' AND jsonb_typeof(entry.value) IN ('boolean', 'null') AND
      entry.value IS DISTINCT FROM 'true'::jsonb AND
      NOT (entry.key = 'controlledDmlPresent' AND validation.access_kind = 'reader')
  ) AS checks ON true
  WHERE (validation.result->'valid') IS DISTINCT FROM 'true'::jsonb
)
SELECT COALESCE(string_agg(
  'restore_nocodb_failure domain=' || domain || ' pair=' || pair ||
    ' access=' || access_kind || ' check=' || name,
  E'\\n' ORDER BY domain, pair, access_kind, name
), 'true') FROM failed_checks;
")" || restore_fail nocodb-permission-query
    if test "$nocodb_permission_contract" != true; then
      printf '%s\n' "$nocodb_permission_contract" >&2
      restore_fail nocodb-permission-validation
    fi
    application_permission_contract="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
WITH validations AS MATERIALIZED (
  SELECT login.domain, login.application,
    platform_operations.validate_application_login(login.domain, login.application) AS result
  FROM platform_operations.managed_application_logins AS login
  WHERE login.state IN ('ready', 'retired')
), failed_checks AS (
  SELECT validation.domain, validation.application, COALESCE(checks.name, 'valid') AS name
  FROM validations AS validation
  LEFT JOIN LATERAL (
    SELECT entry.key AS name
    FROM jsonb_each(validation.result) AS entry
    WHERE entry.key <> 'valid' AND jsonb_typeof(entry.value) IN ('boolean', 'null') AND
      entry.value IS DISTINCT FROM 'true'::jsonb
  ) AS checks ON true
  WHERE (validation.result->'valid') IS DISTINCT FROM 'true'::jsonb
)
SELECT COALESCE(string_agg(
  'restore_application_failure domain=' || domain || ' application=' || application ||
    ' check=' || name,
  E'\\n' ORDER BY domain, application, name
), 'true') FROM failed_checks;
")" || restore_fail application-permission-query
    if test "$application_permission_contract" != true; then
      printf '%s\n' "$application_permission_contract" >&2
      restore_fail application-permission-validation
    fi
    ;;
  *) restore_fail platform-revision-validation ;;
esac

# Optional application probe, admitted before any database connection above. psql sends
# a --command string to the server unparsed: no meta-commands or variable interpolation.
application_probe_result=''
if test "$application_probe_enabled" = true; then
  printf '%s\n' 'restore_stage=application-probe'
  probe_database_base64="$(printf '%s' "$RESTORE_PROBE_DATABASE" | base64 | tr -d '\n')" ||
    restore_fail application-probe-database
  grep -Fxq "$probe_database_base64" /tmp/restore-expected-databases-base64 ||
    restore_fail application-probe-database
  PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=300s' \
    psql --dbname="$RESTORE_PROBE_DATABASE" --no-psqlrc --quiet --single-transaction \
      --set=ON_ERROR_STOP=1 --tuples-only --no-align --command="$application_probe_sql" \
      >/tmp/restore-application-probe.out 2>/tmp/restore-application-probe.log ||
    restore_fail application-probe
  test "$(wc -l < /tmp/restore-application-probe.out | tr -d ' ')" = 1 ||
    restore_fail application-probe-result
  test "$(wc -c < /tmp/restore-application-probe.out | tr -d ' ')" -le 16385 ||
    restore_fail application-probe-result
  grep -Eqx '[{].*[}]' /tmp/restore-application-probe.out ||
    restore_fail application-probe-result
  application_probe_result="$(base64 < /tmp/restore-application-probe.out | tr -d '\n')" ||
    restore_fail application-probe-result
fi

printf '%s\n' 'restore_stage=post-recovery-backup'
mkdir -p "$POST_RECOVERY_BACKUP_DIR"
PGDATABASE=automation_data_control \
PGUSER=automation_data_backup \
PGPASSWORD="$AUTOMATION_DATA_BACKUP_PASSWORD" \
BACKUP_DIR="$POST_RECOVERY_BACKUP_DIR" \
  "${AUTOMATION_DATA_BACKUP_SCRIPT:-/scripts/backup.sh}" \
  >/tmp/post-recovery-backup.log 2>&1 || restore_fail post-recovery-backup
post_recovery_bundle=''
for candidate in $(find "$POST_RECOVERY_BACKUP_DIR" -mindepth 1 -maxdepth 1 \
  -type d -name 'automation-data-*' | LC_ALL=C sort -r); do
  test -s "$candidate/COMPLETE" -a -s "$candidate/SHA256SUMS" || continue
  if (cd "$candidate" && sha256sum -c SHA256SUMS >/dev/null 2>&1 && \
    sha256sum -c COMPLETE >/dev/null 2>&1); then
    post_recovery_bundle="$(basename "$candidate")"
    break
  fi
done
test -n "$post_recovery_bundle" || restore_fail post-recovery-validation

printf '%s\n' 'restore_stage=complete'
printf 'selected_bundle=%s\n' "$selected_name"
printf 'database_count=%s\n' "$(wc -l < /tmp/restore-expected-databases-base64 | tr -d ' ')"
printf 'post_recovery_bundle=%s\n' "$post_recovery_bundle"
if test -n "$application_probe_result"; then
  printf 'application_probe_result=%s\n' "$application_probe_result"
fi
