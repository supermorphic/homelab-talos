#!/usr/bin/env bash

automation_data_restore_job_command() {
  cat <<'EOF'
restore_fail() {
  printf 'restore_failure=%s\n' "$1" >&2
  exit 1
}

validate_bundle() {
  candidate="$1"
  test -d "$candidate" -a ! -L "$candidate" || return 1
  candidate_name="$(basename "$candidate")"
  printf '%s\n' "$candidate_name" | grep -Eq '^automation-data-[0-9]{8}T[0-9]{6}Z$' || return 1
  test -s "$candidate/globals.sql" -a -s "$candidate/registry.tsv" -a \
    -s "$candidate/manifest.tsv" -a -s "$candidate/SHA256SUMS" -a \
    -s "$candidate/COMPLETE" || return 1
  (cd "$candidate" && sha256sum -c SHA256SUMS >/dev/null 2>&1 && \
    sha256sum -c COMPLETE >/dev/null 2>&1) || return 1

  awk 'NF == 2 {print $2}' "$candidate/SHA256SUMS" | LC_ALL=C sort -u \
    > /tmp/restore-listed-files
  {
    cat /tmp/restore-listed-files
    printf '%s\n' COMPLETE SHA256SUMS
  } | LC_ALL=C sort -u > /tmp/restore-expected-files
  (cd "$candidate" && find . -type f -print | sed 's#^./##' | LC_ALL=C sort -u) \
    > /tmp/restore-actual-files
  cmp -s /tmp/restore-expected-files /tmp/restore-actual-files || return 1

  test "$(sed -n '1p' "$candidate/manifest.tsv")" = \
    "$(printf 'bundle_version\t1')" || return 1
  test "$(sed -n '5p' "$candidate/manifest.tsv")" = \
    "$(printf 'record_type\tdatabase_name_base64\tdump_path')" || return 1
  awk -F '\t' '$1 == "database" {print $3}' "$candidate/manifest.tsv" |
    LC_ALL=C sort -u > /tmp/restore-manifest-dumps
  find "$candidate/databases" -maxdepth 1 -type f -name 'db-*.dump' -print |
    sed "s#^$candidate/##" | LC_ALL=C sort -u > /tmp/restore-actual-dumps
  test -s /tmp/restore-manifest-dumps || return 1
  cmp -s /tmp/restore-manifest-dumps /tmp/restore-actual-dumps || return 1

  : > /tmp/restore-databases-base64
  while IFS="$(printf '\t')" read -r record encoded dump_path extra; do
    test "$record" = database || continue
    test -n "$encoded" -a -n "$dump_path" -a -z "${extra:-}" || return 1
    printf '%s\n' "$dump_path" | grep -Eq '^databases/db-[A-Za-z0-9_-]+\.dump$' || return 1
    database_with_sentinel="$(printf '%s' "$encoded" | base64 -d 2>/dev/null; printf x)" || return 1
    database_name="${database_with_sentinel%x}"
    test -n "$database_name" || return 1
    printf '%s\n' "$encoded" >> /tmp/restore-databases-base64
    pg_restore --list "$candidate/$dump_path" >/dev/null 2>&1 || return 1
  done < "$candidate/manifest.tsv"
  LC_ALL=C sort -u /tmp/restore-databases-base64 > /tmp/restore-databases-base64.sorted
  test "$(wc -l < /tmp/restore-databases-base64 | tr -d ' ')" = \
    "$(wc -l < /tmp/restore-databases-base64.sorted | tr -d ' ')" || return 1
  mv /tmp/restore-databases-base64.sorted /tmp/restore-databases-base64
  return 0
}

printf '%s\n' 'restore_stage=artifact-selection'
selected=''
requested_bundle="${AUTOMATION_DATA_RESTORE_BUNDLE:-}"
if test -n "$requested_bundle"; then
  printf '%s\n' "$requested_bundle" |
    grep -Eq '^automation-data-[0-9]{8}T[0-9]{6}Z$' || restore_fail artifact-selection
  candidate="$BACKUP_DIR/$requested_bundle"
  validate_bundle "$candidate" || restore_fail artifact-selection
  selected="$candidate"
else
  for candidate in $(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
    -name 'automation-data-*' | LC_ALL=C sort -r); do
    if validate_bundle "$candidate"; then
      selected="$candidate"
      break
    fi
  done
fi
test -n "$selected" || restore_fail artifact-selection
selected_name="$(basename "$selected")"
cp /tmp/restore-databases-base64 /tmp/restore-expected-databases-base64

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

printf '%s\n' 'restore_stage=permission-validation'
permission_contract="$(psql --dbname=automation_data_control --tuples-only --no-align --command="
SELECT COALESCE(bool_and(
  validation.result->>'state' = 'ready' AND
  (validation.result->>'ownerNoLogin')::boolean AND
  (validation.result->>'migratorCanSetOwner')::boolean AND
  (validation.result->>'runtimeCannotSetOwner')::boolean AND
  (validation.result->>'migratorControlConnectDenied')::boolean AND
  (validation.result->>'runtimeControlConnectDenied')::boolean AND
  (validation.result->>'migratorDomainConnectAllowed')::boolean AND
  (validation.result->>'runtimeDomainConnectAllowed')::boolean AND
  (validation.result->>'runtimePrivilegesValid')::boolean AND
  (validation.result->>'defaultPrivilegesValid')::boolean AND
  (validation.result->>'crossDomainConnectDenied')::boolean AND
  (validation.result->>'migratorDdlValid')::boolean AND
  (validation.result->>'runtimeCrudValid')::boolean AND
  (validation.result->>'runtimeDdlDenied')::boolean AND
  (validation.result->>'runtimeOwnerAssumptionDenied')::boolean AND
  (validation.result->>'runtimeRoleManagementDenied')::boolean
), true)::text
FROM platform_operations.managed_domains AS managed
CROSS JOIN LATERAL platform_operations.validate_domain(managed.domain) AS validation(result)
WHERE managed.state = 'ready';
")" || restore_fail permission-query
test "$permission_contract" = true || restore_fail permission-validation

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
EOF
}
