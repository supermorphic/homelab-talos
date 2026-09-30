#!/usr/bin/env bash
# Exercise pair registration against a disposable instance of the pinned PostgreSQL image.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nocodb-pair-registry.XXXXXX")"
chmod 700 "$scratch"
marker="nocodb-pair-registry-$$-$RANDOM"
container="${marker:0:63}"
cleanup() {
  if podman container exists "$container" >/dev/null 2>&1; then
    if [[ "$(podman inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$container")" == "$marker" ]]; then
      podman rm --force "$container" >/dev/null || true
    fi
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT

scripts="$repo_root/kubernetes/apps/automation-data/postgresql/app/scripts"
cat >"$scratch/postgresql.env" <<EOF
POSTGRES_USER=postgres
POSTGRES_DB=automation_data_control
POSTGRES_PASSWORD=$(openssl rand -hex 24)
PROVISIONER_PASSWORD=$(openssl rand -hex 24)
BACKUP_PASSWORD=$(openssl rand -hex 24)
EXPORTER_PASSWORD=$(openssl rand -hex 24)
FIXTURE_MIGRATOR_PASSWORD=$(openssl rand -hex 24)
FIXTURE_RUNTIME_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 "$scratch/postgresql.env"

podman run --detach --name "$container" --label "homelab-talos.test-run=$marker" \
  --env-file "$scratch/postgresql.env" \
  --volume "$scripts:/scripts:ro" \
  --volume "$scripts/init-platform.sh:/docker-entrypoint-initdb.d/00-init-platform.sh:ro" \
  postgres:17.11-alpine3.24 >"$scratch/container-id"
for _attempt in {1..60}; do
  if podman exec "$container" pg_isready --username postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
podman exec "$container" pg_isready --username postgres >/dev/null

cat >"$scratch/assertions.sql" <<'SQL'
\getenv migrator_password FIXTURE_MIGRATOR_PASSWORD
\getenv runtime_password FIXTURE_RUNTIME_PASSWORD
SELECT platform_operations.provision_domain('pair_fixture', :'migrator_password', :'runtime_password');
SELECT platform_operations.record_domain_credentials(
  'pair_fixture', 'fixture-migrator-id', 'fixture-runtime-id',
  '2026-09-01T00:00:00Z'::timestamptz, '2026-09-01T00:00:00Z'::timestamptz
);
SELECT platform_operations.configure_nocodb_schema_mapping(
  'pair_fixture', 'legacy_read', 'legacy_edit'
);

-- These snapshots originate from the pre-existing contract, not the new pair builder.
CREATE TEMP TABLE original_mapping AS
  SELECT row_to_json(mapping)::text AS body FROM platform_operations.managed_nocodb_schema_mappings AS mapping
  WHERE domain = 'pair_fixture';
CREATE TEMP TABLE original_roles AS
  SELECT rolname, oid, rolpassword FROM pg_authid
  WHERE rolname IN ('pair_fixture_reader', 'pair_fixture_operator');
CREATE TEMP TABLE original_generation AS
  SELECT generation FROM platform_operations.platform_generation WHERE singleton;

-- named_pair_registration_is_idempotent
DO $test$
DECLARE
  first_result jsonb;
  second_result jsonb;
  first_mapping text;
  first_generation bigint;
BEGIN
  first_result := platform_operations.configure_nocodb_pair(
    'pair_fixture', 'extra', 'extra_read', 'extra_edit');
  IF first_result->>'pair' <> 'extra' OR
     first_result->>'readerSchema' <> 'extra_read' OR
     first_result->>'operatorSchema' <> 'extra_edit' OR
     first_result->>'readerRole' <> 'nocodb_' || md5('pair_fixture:extra') || '_reader' OR
     first_result->>'operatorRole' <> 'nocodb_' || md5('pair_fixture:extra') || '_operator' THEN
    RAISE EXCEPTION 'named registration result mismatch';
  END IF;
  SELECT row_to_json(mapping)::text INTO first_mapping
  FROM platform_operations.managed_nocodb_schema_mappings AS mapping
  WHERE domain = 'pair_fixture' AND pair = 'extra';
  SELECT generation INTO first_generation FROM platform_operations.platform_generation
  WHERE singleton;
  second_result := platform_operations.configure_nocodb_pair(
    'pair_fixture', 'extra', 'extra_read', 'extra_edit');
  IF second_result IS DISTINCT FROM first_result OR first_mapping IS DISTINCT FROM (
    SELECT row_to_json(mapping)::text FROM platform_operations.managed_nocodb_schema_mappings AS mapping
    WHERE domain = 'pair_fixture' AND pair = 'extra') OR first_generation IS DISTINCT FROM (
    SELECT generation FROM platform_operations.platform_generation WHERE singleton) THEN
    RAISE EXCEPTION 'repeated registration changed identity';
  END IF;
END;
$test$;

-- A named pair must not make the default mapping query ambiguous.
DO $test$
BEGIN
  IF platform_operations.configure_nocodb_schema_mapping(
      'pair_fixture', 'legacy_read', 'legacy_edit')->>'readerRole' <>
      'pair_fixture_reader' THEN
    RAISE EXCEPTION 'default mapping was changed by named pair registration';
  END IF;
END;
$test$;

-- An unchanged registration stays idempotent after one of its sources activates.
DO $test$
DECLARE
  reader_name text := 'nocodb_' || md5('pair_fixture:extra') || '_reader';
BEGIN
  INSERT INTO platform_operations.managed_nocodb_sources
    (domain, pair, access_kind, role_name, base_id, integration_id, source_id,
     state, operation, generation, credential_generation)
  VALUES ('pair_fixture', 'extra', 'reader', reader_name, 'synthetic-base',
    'synthetic-integration', 'synthetic-source', 'ready', 'sync', 1, 1);
  EXECUTE format('ALTER ROLE %I LOGIN', reader_name);
  IF platform_operations.configure_nocodb_pair(
      'pair_fixture', 'extra', 'extra_read', 'extra_edit')->>'readerRole' <> reader_name THEN
    RAISE EXCEPTION 'ready pair did not remain registered';
  END IF;
END;
$test$;

-- default_pair_registration_preserves_state (populated v2 upgrade is tested later)
DO $test$
BEGIN
  IF (SELECT body FROM original_mapping) IS DISTINCT FROM (
    SELECT row_to_json(mapping)::text FROM platform_operations.managed_nocodb_schema_mappings AS mapping
    WHERE domain = 'pair_fixture' AND pair = 'default') OR
     EXISTS (
       SELECT rolname, oid, rolpassword FROM original_roles
       EXCEPT
       SELECT rolname, oid, rolpassword FROM pg_authid
       WHERE rolname IN ('pair_fixture_reader', 'pair_fixture_operator')
     ) OR (SELECT count(*) FROM original_roles) <> 2 THEN
    RAISE EXCEPTION 'default mapping or role identity changed';
  END IF;
END;
$test$;

-- registration_rejects_conflicting_bindings
DO $test$
BEGIN
  BEGIN
    PERFORM platform_operations.configure_nocodb_pair(
      'pair_fixture', 'extra', 'different_read', 'extra_edit');
    RAISE EXCEPTION 'changed mapping was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
  BEGIN
    PERFORM platform_operations.configure_nocodb_pair(
      'pair_fixture', 'other', 'legacy_read', 'other_edit');
    RAISE EXCEPTION 'default schema reuse was accepted';
  EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
  END;
END;
$test$;

-- maximum_names_do_not_truncate
DO $test$
DECLARE
  result jsonb;
BEGIN
  result := platform_operations.configure_nocodb_pair(
    'pair_fixture', repeat('p', 24), 'max_read', NULL);
  IF length(result->>'readerRole') > 63 OR
     result->>'readerRole' <> 'nocodb_' || md5('pair_fixture:' || repeat('p', 24)) || '_reader' THEN
    RAISE EXCEPTION 'role name was truncated';
  END IF;
END;
$test$;
SQL
chmod 600 "$scratch/assertions.sql"
podman cp "$scratch/assertions.sql" "$container:/tmp/assertions.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --tuples-only --no-align --username postgres \
  --dbname automation_data_control --file /tmp/assertions.sql >"$scratch/results"
echo 'NocoDB pair registry PostgreSQL behavior passed.'
