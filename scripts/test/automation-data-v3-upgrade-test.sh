#!/usr/bin/env bash
# Real PostgreSQL v2-to-v3 preservation and v3 backup-state behavior.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-v3-upgrade.XXXXXX")"
chmod 700 "$scratch"
marker="automation-data-v3-upgrade-$$-$RANDOM"
container="${marker:0:63}"
stage=historical-init
trap 'echo "v3 fixture failed during $stage" >&2' ERR
cleanup() {
  if podman container exists "$container" >/dev/null 2>&1 &&
      [[ "$(podman inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$container")" == "$marker" ]]; then
    podman rm --force "$container" >/dev/null || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
mkdir -m 700 "$scratch/historical"
for name in init-platform.sh platform-control.sql nocodb-extension.sql \
    nocodb-metadata.sql domain-validation.sql; do
  git show "97c06e1:kubernetes/apps/automation-data/postgresql/app/scripts/$name" \
    >"$scratch/historical/$name"
done
chmod +x "$scratch/historical/init-platform.sh"
cat >"$scratch/postgresql.env" <<EOF
POSTGRES_USER=postgres
POSTGRES_DB=automation_data_control
POSTGRES_PASSWORD=$(openssl rand -hex 24)
PROVISIONER_PASSWORD=$(openssl rand -hex 24)
BACKUP_PASSWORD=$(openssl rand -hex 24)
EXPORTER_PASSWORD=$(openssl rand -hex 24)
FIXTURE_MIGRATOR_PASSWORD=$(openssl rand -hex 24)
FIXTURE_RUNTIME_PASSWORD=$(openssl rand -hex 24)
FIXTURE_SOURCE_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 "$scratch/postgresql.env"
candidate="$(pwd)/kubernetes/apps/automation-data/postgresql/app/scripts"
podman run --detach --name "$container" --label "homelab-talos.test-run=$marker" \
  --env-file "$scratch/postgresql.env" \
  --volume "$scratch/historical:/scripts:ro" \
  --volume "$scratch/historical/init-platform.sh:/docker-entrypoint-initdb.d/00-init-platform.sh:ro" \
  --volume "$candidate:/candidate:ro" \
  postgres:17.11-alpine3.24 >"$scratch/container-id"
query() {
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --username postgres --dbname automation_data_control \
    --command="$1"
}
for _attempt in {1..60}; do
  if podman exec "$container" sh -eu -c 'grep -qx postgres /proc/1/comm' >/dev/null 2>&1 &&
      query 'SELECT platform_operations.read_platform_revision()' 2>/dev/null \
      | rg -qx '026-nocodb-v2'; then break; fi
  sleep 1
done
podman exec "$container" sh -eu -c 'grep -qx postgres /proc/1/comm'
[[ "$(query 'SELECT platform_operations.read_platform_revision()')" == 026-nocodb-v2 ]]
cat >"$scratch/setup.sql" <<'SQL'
\getenv migrator_password FIXTURE_MIGRATOR_PASSWORD
\getenv runtime_password FIXTURE_RUNTIME_PASSWORD
\getenv source_password FIXTURE_SOURCE_PASSWORD
SELECT platform_operations.provision_domain('v3_fixture', :'migrator_password', :'runtime_password');
SELECT platform_operations.record_domain_credentials('v3_fixture', 'synthetic-migrator',
  'synthetic-runtime', '2026-09-01T00:00:00Z'::timestamptz,
  '2026-09-01T00:00:00Z'::timestamptz);
SELECT platform_operations.provision_domain('v3_partial', :'migrator_password', :'runtime_password');
SELECT platform_operations.record_operation_error('v3_partial', 'acceptance_backup_error');
GRANT TEMP ON DATABASE v3_partial TO PUBLIC;
SELECT platform_internal.exec_in_database('v3_partial', 'GRANT ALL ON SCHEMA public TO PUBLIC');
SELECT platform_operations.provision_domain('v3_missing_ready', :'migrator_password', :'runtime_password');
SELECT platform_operations.record_domain_credentials('v3_missing_ready', 'synthetic-missing-migrator',
  'synthetic-missing-runtime', '2026-09-01T00:00:00Z'::timestamptz,
  '2026-09-01T00:00:00Z'::timestamptz);
DROP DATABASE v3_missing_ready;
CREATE ROLE v3_fixture_reader LOGIN NOINHERIT PASSWORD :'source_password';
INSERT INTO platform_operations.managed_nocodb_sources
  (domain, access_kind, role_name, base_id, integration_id, source_id,
   source_create_job_id, state, operation, generation, credential_generation,
   operation_started_at, validated_at, updated_at)
VALUES ('v3_fixture', 'reader', 'v3_fixture_reader', 'synthetic-base',
  'synthetic-integration', 'synthetic-source', 'synthetic-job', 'ready', 'sync',
  7, 1, '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z');
SQL
podman cp "$scratch/setup.sql" "$container:/tmp/v3-setup.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
  --file /tmp/v3-setup.sql >"$scratch/setup.out"
query "SELECT to_jsonb(source)::text FROM platform_operations.managed_nocodb_sources AS source
  WHERE domain = 'v3_fixture' AND access_kind = 'reader'" >"$scratch/source-before.json"
query "SELECT rolpassword FROM pg_authid WHERE rolname = 'v3_fixture_reader'" \
  >"$scratch/verifier-before"
chmod 600 "$scratch/verifier-before"
query "SELECT platform_operations.capture_backup_state()->>'platformRevision'" \
  | rg -qx '026-nocodb-v2'
query "UPDATE platform_operations.managed_nocodb_sources SET state = 'error'
  WHERE domain = 'v3_fixture' AND access_kind = 'reader'" >/dev/null
if podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --username postgres --dbname automation_data_control \
    --file /candidate/upgrade-nocodb.sql >"$scratch/incomplete-v2-upgrade.out" \
    2>"$scratch/incomplete-v2-upgrade.err"; then
  echo 'v3 upgrade accepted an unresolved v2 source.' >&2
  exit 1
fi
rg -q 'incomplete_platform_operation' "$scratch/incomplete-v2-upgrade.err"
[[ "$(query 'SELECT platform_operations.read_platform_revision()')" == 026-nocodb-v2 ]]
query "UPDATE platform_operations.managed_nocodb_sources SET state = 'ready'
  WHERE domain = 'v3_fixture' AND access_kind = 'reader'" >/dev/null
stage=missing-previously-ready-domain
if podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --username postgres --dbname automation_data_control \
    --file /candidate/upgrade-nocodb.sql >"$scratch/missing-ready-upgrade.out" \
    2>"$scratch/missing-ready-upgrade.err"; then
  echo 'v3 upgrade accepted a missing previously ready database.' >&2
  exit 1
fi
rg -q 'database "v3_missing_ready" does not exist' "$scratch/missing-ready-upgrade.err"
[[ "$(query 'SELECT platform_operations.read_platform_revision()')" == 026-nocodb-v2 ]]
query "DELETE FROM platform_operations.managed_domains WHERE domain = 'v3_missing_ready'" >/dev/null
stage=retained-unmaterialized-domain
query "INSERT INTO platform_operations.managed_domains
  (domain,database_name,owner_role,migrator_role,runtime_role,state,generation,error_code)
  VALUES ('v3_never_ready','v3_never_ready','v3_never_ready_owner',
    'v3_never_ready_migrator','v3_never_ready_runtime','error',
    platform_internal.bump_generation(),'acceptance_backup_error')" >/dev/null
query "SELECT to_jsonb(managed)::text FROM platform_operations.managed_domains managed
  WHERE domain = 'v3_never_ready'" >"$scratch/never-ready-before.json"
[[ "$(query "SELECT count(*) FROM pg_database WHERE datname = 'v3_never_ready'")" == 0 ]]
[[ "$(query "SELECT has_database_privilege('v3_fixture_reader', 'v3_partial', 'TEMP')")" == t ]]
stage=upgrade
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username postgres --dbname automation_data_control \
  --file /candidate/upgrade-nocodb.sql >"$scratch/upgrade.out"
[[ "$(query 'SELECT platform_operations.read_platform_revision()')" == 026-nocodb-v3 ]]
query "SELECT to_jsonb(managed)::text FROM platform_operations.managed_domains managed
  WHERE domain = 'v3_never_ready'" >"$scratch/never-ready-after.json"
cmp -s "$scratch/never-ready-before.json" "$scratch/never-ready-after.json"
[[ "$(query "SELECT count(*) FROM pg_database WHERE datname = 'v3_never_ready'")" == 0 ]]
query "SELECT (to_jsonb(source) - 'pair')::text FROM platform_operations.managed_nocodb_sources AS source
  WHERE domain = 'v3_fixture' AND pair = 'default' AND access_kind = 'reader'" \
  >"$scratch/source-after.json"
cmp -s "$scratch/source-before.json" "$scratch/source-after.json"
query "SELECT rolpassword FROM pg_authid WHERE rolname = 'v3_fixture_reader'" \
  >"$scratch/verifier-after"
chmod 600 "$scratch/verifier-after"
cmp -s "$scratch/verifier-before" "$scratch/verifier-after"
[[ "$(query "SELECT has_database_privilege('v3_fixture_reader', 'v3_fixture', 'TEMP')")" == f ]]
[[ "$(podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --tuples-only --no-align --username postgres --dbname v3_fixture \
  --command="SELECT has_schema_privilege('v3_fixture_reader', 'public', 'CREATE')")" == f ]]
[[ "$(query "SELECT has_reached_ready FROM platform_operations.managed_domains WHERE domain = 'v3_partial'")" == f ]]
[[ "$(query "SELECT has_database_privilege('v3_fixture_reader', 'v3_partial', 'TEMP')")" == f ]]
[[ "$(podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --tuples-only --no-align --username postgres --dbname v3_partial \
  --command="SELECT has_schema_privilege('v3_fixture_reader', 'public', 'CREATE')")" == f ]]

stage=backup-state
query "SELECT platform_operations.configure_nocodb_pair(
  'v3_fixture','second','second_read',NULL)" >/dev/null
query "SELECT platform_operations.register_application_login(
  'v3_fixture','interview','second_read')" >/dev/null
query "INSERT INTO platform_operations.nocodb_source_operations
  (domain,pair,operation_id,operation,access_kind,generation,phase)
  VALUES ('v3_fixture','second','00000000-0000-4000-8000-000000000302',
    'sync',NULL,10,'complete')" >/dev/null
state="$(query 'SELECT platform_operations.capture_backup_state()::text')"
jq -e '(keys | sort) ==
  ["applicationLogins", "generation", "nocodbOperations", "nocodbSchemaMappings",
   "nocodbSources", "platformRevision", "registry"]' <<<"$state" >/dev/null
jq -e '.platformRevision == "026-nocodb-v3"' <<<"$state" >/dev/null
jq -e '
  ([.nocodbSources[] | select(.domain == "v3_fixture" and .pair == "default" and
    .source_id == "synthetic-source")] | length) == 1' <<<"$state" >/dev/null
jq -e '([.nocodbSchemaMappings[] | select(.domain == "v3_fixture" and .pair == "second")] |
  length) == 1' <<<"$state" >/dev/null
jq -e '([.nocodbOperations[] | select(.domain == "v3_fixture" and .pair == "second")] |
  length) == 1' <<<"$state" >/dev/null
jq -e '([.applicationLogins[] | select(.domain == "v3_fixture" and
  .application == "interview")] | length) == 1' <<<"$state" >/dev/null
exporter_config=kubernetes/apps/automation-data/postgresql/app/sql-exporter.yml
registry_metric="$(yq -r '.collectors[0].metrics[] |
  select(.metric_name == "automation_data_postgresql_optional_registry_consistent").query' \
  "$exporter_config")"
age_metric="$(yq -r '.collectors[0].metrics[] |
  select(.metric_name == "automation_data_postgresql_oldest_incomplete_optional_operation_age_seconds").query' \
  "$exporter_config")"
metric_registry_result="$(query "SET ROLE automation_data_exporter; $registry_metric" | tail -n 1)"
metric_age_result="$(query "SET ROLE automation_data_exporter; $age_metric" | tail -n 1)"
[[ "$metric_registry_result" == 1 ]]
[[ "$metric_age_result" == 0 ]]
if query "BEGIN; CREATE OR REPLACE FUNCTION platform_operations.capture_backup_state()
  RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS \$\$ SELECT '{}'::jsonb \$\$;
  SELECT platform_operations.read_platform_revision();" \
    >"$scratch/tampered-oracle.out" 2>"$scratch/tampered-oracle.err"; then
  echo 'v3 revision oracle accepted a modified backup function body.' >&2
  exit 1
fi
rg -q 'invalid_nocodb_extension_contract' "$scratch/tampered-oracle.err"
query "UPDATE platform_operations.nocodb_source_operations SET phase = 'active'
  WHERE domain = 'v3_fixture' AND pair = 'second'" >/dev/null
if query 'SELECT platform_operations.capture_backup_state()' \
    >"$scratch/active-source-capture.out" 2>"$scratch/active-source-capture.err"; then
  echo 'v3 capture accepted an incomplete source operation.' >&2
  exit 1
fi
rg -q 'incomplete_nocodb_operation' "$scratch/active-source-capture.err"
if podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --username postgres --dbname automation_data_control \
    --file /candidate/upgrade-nocodb.sql >"$scratch/active-upgrade.out" \
    2>"$scratch/active-upgrade.err"; then
  echo 'v3 upgrade accepted an unresolved source operation.' >&2
  exit 1
fi
rg -q 'incomplete_platform_operation' "$scratch/active-upgrade.err"
query "UPDATE platform_operations.nocodb_source_operations SET phase = 'complete'
  WHERE domain = 'v3_fixture' AND pair = 'second'" >/dev/null
query "UPDATE platform_operations.managed_application_logins
  SET state = 'rotating', credential_generation = 1
  WHERE domain = 'v3_fixture' AND application = 'interview'" >/dev/null
if query 'SELECT platform_operations.capture_backup_state()' \
    >"$scratch/active-capture.out" 2>"$scratch/active-capture.err"; then
  echo 'v3 capture accepted an incomplete credential change.' >&2
  exit 1
fi
rg -q 'incomplete_application_operation' "$scratch/active-capture.err"
stage='done'
echo 'Automation-data v3 upgrade and backup state passed.'
