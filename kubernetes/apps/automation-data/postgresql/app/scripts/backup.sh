#!/bin/sh
# shellcheck shell=ash
set -eu
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

backup_dir="${BACKUP_DIR:-/backups}"
artifact_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
final_name="automation-data-$artifact_timestamp"
final_bundle="$backup_dir/$final_name"
max_attempts=3

capture_platform_state() {
  output_registry="$1"
  capture_line="$({
    psql --no-align --tuples-only --quiet --set=ON_ERROR_STOP=1 --field-separator='|' --command="
WITH captured AS MATERIALIZED (
  SELECT platform_operations.capture_backup_state() AS state
),
registry_rows AS (
  SELECT managed.*
  FROM captured
  CROSS JOIN LATERAL jsonb_to_recordset(captured.state->'registry') AS managed(
    domain text,
    database_name text,
    owner_role text,
    migrator_role text,
    runtime_role text,
    state text,
    has_reached_ready boolean,
    generation bigint,
    migrator_credential_id text,
    runtime_credential_id text,
    migrator_credential_updated_at timestamptz,
    runtime_credential_updated_at timestamptz,
    operation_started_at timestamptz,
    updated_at timestamptz,
    error_code text
  )
),
registry_text AS (
  SELECT
    'domain' || E'\\t' || 'database_name' || E'\\t' || 'owner_role' || E'\\t' ||
    'migrator_role' || E'\\t' || 'runtime_role' || E'\\t' || 'state' || E'\\t' ||
    'has_reached_ready' || E'\\t' || 'generation' || E'\\t' ||
    'migrator_credential_id' || E'\\t' || 'runtime_credential_id' || E'\\t' ||
    'migrator_credential_updated_at' || E'\\t' || 'runtime_credential_updated_at' || E'\\t' ||
    'operation_started_at' || E'\\t' || 'updated_at' || E'\\t' || 'error_code' ||
    COALESCE(
      E'\\n' || string_agg(
        concat_ws(
          E'\\t',
          domain,
          database_name,
          owner_role,
          migrator_role,
          runtime_role,
          state,
          has_reached_ready::text,
          generation::text,
          COALESCE(migrator_credential_id, ''),
          COALESCE(runtime_credential_id, ''),
          COALESCE(migrator_credential_updated_at::text, ''),
          COALESCE(runtime_credential_updated_at::text, ''),
          COALESCE(operation_started_at::text, ''),
          updated_at::text,
          COALESCE(error_code, '')
        ),
        E'\\n' ORDER BY domain
      ),
      ''
    ) AS body
  FROM registry_rows
)
SELECT
  captured.state->>'generation',
  replace(encode(convert_to(registry_text.body, 'UTF8'), 'base64'), E'\\n', '')
FROM captured
CROSS JOIN registry_text;
"
  } 2>/dev/null)" || return 1
  case "$capture_line" in
    *'|'*) ;;
    *) return 1 ;;
  esac
  captured_generation="${capture_line%%|*}"
  encoded_registry="${capture_line#*|}"
  case "$captured_generation" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ -n "$encoded_registry" ] || return 1
  printf '%s' "$encoded_registry" | base64 -d >"$output_registry"
  [ -s "$output_registry" ] || return 1
  printf '%s\n' "$captured_generation"
}

capture_databases() {
  output_databases="$1"
  raw_databases="$output_databases.raw"
  psql --no-align --tuples-only --quiet --set=ON_ERROR_STOP=1 --command="
SELECT replace(encode(convert_to(datname, 'UTF8'), 'base64'), E'\\n', '')
FROM pg_database
WHERE datallowconn AND NOT datistemplate
ORDER BY datname;
" >"$raw_databases"
  LC_ALL=C sort -u "$raw_databases" >"$output_databases"
  rm -f -- "$raw_databases"
  [ -s "$output_databases" ]
}

valid_complete_bundle() {
  candidate="$1"
  [ -f "$candidate/COMPLETE" ] &&
    [ -f "$candidate/SHA256SUMS" ] &&
    (cd "$candidate" && sha256sum -c SHA256SUMS >/dev/null 2>&1 &&
      sha256sum -c COMPLETE >/dev/null 2>&1)
}

cleanup_published_bundles() {
  find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name '.automation-data-*.tmp' -print |
    while IFS= read -r temporary; do
      rm -rf -- "$temporary"
    done

  find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name 'automation-data-*' -print |
    while IFS= read -r candidate; do
      candidate_name="$(basename "$candidate")"
      if ! printf '%s\n' "$candidate_name" |
        grep -Eq '^automation-data-[0-9]{8}T[0-9]{6}Z$' ||
        ! valid_complete_bundle "$candidate"; then
        rm -rf -- "$candidate"
      fi
    done

  find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name 'automation-data-*' -print |
    LC_ALL=C sort -r |
    awk 'NR > 7 { print }' |
    while IFS= read -r old_bundle; do
      rm -rf -- "$old_bundle"
    done
}

[ -d "$backup_dir" ] || mkdir -p "$backup_dir"
[ ! -e "$final_bundle" ] || {
  echo "Refusing to replace existing backup bundle: $final_name" >&2
  exit 1
}

attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
  temporary_bundle="$backup_dir/.automation-data-$artifact_timestamp-$$-$attempt.tmp"
  [ ! -e "$temporary_bundle" ] || {
    echo 'Refusing to reuse an existing temporary backup directory.' >&2
    exit 1
  }
  mkdir -p "$temporary_bundle/databases"
  start_databases="$temporary_bundle/.database-set.start"
  end_databases="$temporary_bundle/.database-set.end"
  end_registry="$temporary_bundle/.registry.end"
  database_manifest="$temporary_bundle/.database-manifest"
  : >"$database_manifest"

  start_generation="$(capture_platform_state "$temporary_bundle/registry.tsv")"
  capture_databases "$start_databases"
  database_set_hash="$(sha256sum "$start_databases" | awk '{print $1}')"

  pg_dumpall --globals-only --file="$temporary_bundle/globals.sql"
  [ -s "$temporary_bundle/globals.sql" ]

  while IFS= read -r database_base64; do
    [ -n "$database_base64" ] || continue
    database_with_sentinel="$(printf '%s' "$database_base64" | base64 -d; printf x)"
    database_name="${database_with_sentinel%x}"
    encoded_name="$(printf '%s' "$database_base64" | tr '+/' '-_' | tr -d '=')"
    [ -n "$encoded_name" ] || {
      echo 'Captured an invalid empty database name.' >&2
      exit 1
    }
    dump_relative="databases/db-$encoded_name.dump"
    dump_path="$temporary_bundle/$dump_relative"
    pg_dump --format=custom --compress=9 --file "$dump_path" --dbname "$database_name"
    pg_restore --list "$dump_path" >/dev/null
    printf 'database\t%s\t%s\n' "$database_base64" "$dump_relative" >>"$database_manifest"
  done <"$start_databases"

  end_generation="$(capture_platform_state "$end_registry")"
  capture_databases "$end_databases"
  if [ "$start_generation" != "$end_generation" ] ||
    ! cmp -s "$start_databases" "$end_databases"; then
    rm -rf -- "$temporary_bundle"
    if [ "$attempt" -eq "$max_attempts" ]; then
      echo 'PostgreSQL catalog or platform generation remained unstable.' >&2
      exit 1
    fi
    attempt=$((attempt + 1))
    continue
  fi

  {
    printf 'bundle_version\t1\n'
    printf 'captured_at\t%s\n' "$captured_at"
    printf 'platform_generation\t%s\n' "$start_generation"
    printf 'database_set_hash\t%s\n' "$database_set_hash"
    printf 'record_type\tdatabase_name_base64\tdump_path\n'
    cat "$database_manifest"
  } >"$temporary_bundle/manifest.tsv"
  rm -f -- "$start_databases" "$end_databases" "$end_registry" "$database_manifest"

  (
    cd "$temporary_bundle"
    sha256sum globals.sql registry.tsv manifest.tsv
    for dump_path in databases/*.dump; do
      sha256sum "$dump_path"
    done
  ) >"$temporary_bundle/SHA256SUMS"
  (cd "$temporary_bundle" && sha256sum -c SHA256SUMS >/dev/null)
  complete_checksum="$(sha256sum "$temporary_bundle/SHA256SUMS" | awk '{print $1}')"
  printf '%s  SHA256SUMS\n' "$complete_checksum" >"$temporary_bundle/COMPLETE"
  (cd "$temporary_bundle" && sha256sum -c COMPLETE >/dev/null)

  if ! mv "$temporary_bundle" "$final_bundle"; then
    rm -f -- "$temporary_bundle/COMPLETE"
    echo 'Atomic backup bundle publication failed.' >&2
    exit 1
  fi
  if ! (cd "$final_bundle" && sha256sum -c SHA256SUMS >/dev/null &&
    sha256sum -c COMPLETE >/dev/null); then
    rm -f -- "$final_bundle/COMPLETE"
    echo 'Final backup bundle validation failed.' >&2
    exit 1
  fi
  if ! psql --set=ON_ERROR_STOP=1 --set=bundle="$final_name" \
    --set=checksum="$complete_checksum" --set=database_set_hash="$database_set_hash" \
    --file=/scripts/update-backup-status.sql; then
    rm -f -- "$final_bundle/COMPLETE"
    echo 'Backup freshness publication failed.' >&2
    exit 1
  fi

  cleanup_published_bundles
  exit 0
done

exit 1
