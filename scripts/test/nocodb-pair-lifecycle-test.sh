#!/usr/bin/env bash
# Exercise pair operation claims against disposable PostgreSQL sessions.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nocodb-pair-lifecycle.XXXXXX")"
chmod 700 "$scratch"
marker="nocodb-pair-lifecycle-$$-$RANDOM"
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
SOURCE_READER_PASSWORD=$(openssl rand -hex 24)
SOURCE_OPERATOR_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 "$scratch/postgresql.env"
podman run --detach --name "$container" --label "homelab-talos.test-run=$marker" \
  --env-file "$scratch/postgresql.env" --volume "$scripts:/scripts:ro" \
  --volume "$scripts/init-platform.sh:/docker-entrypoint-initdb.d/00-init-platform.sh:ro" \
  postgres:17.11-alpine3.24 >"$scratch/container-id"
for _attempt in {1..60}; do
  if podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
      --tuples-only --no-align --username postgres --dbname automation_data_control \
      --command='SELECT platform_operations.read_platform_revision()' 2>/dev/null \
      | rg -qx '026-nocodb-v2'; then break; fi
  sleep 1
done
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --tuples-only --no-align --username postgres --dbname automation_data_control \
  --command='SELECT platform_operations.read_platform_revision()' | rg -qx '026-nocodb-v2'

cat >"$scratch/setup.sql" <<'SQL'
\getenv migrator_password FIXTURE_MIGRATOR_PASSWORD
\getenv runtime_password FIXTURE_RUNTIME_PASSWORD
SELECT platform_operations.provision_domain('claim_fixture', :'migrator_password', :'runtime_password');
SELECT platform_operations.record_domain_credentials(
  'claim_fixture', 'synthetic-migrator', 'synthetic-runtime',
  '2026-09-01T00:00:00Z'::timestamptz, '2026-09-01T00:00:00Z'::timestamptz);
SELECT platform_operations.configure_nocodb_pair(
  'claim_fixture', 'extra', 'extra_read', 'extra_edit');
SELECT platform_operations.configure_nocodb_pair(
  'claim_fixture', 'sibling', 'sibling_read', NULL);
SQL
podman cp "$scratch/setup.sql" "$container:/tmp/setup.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
  --file /tmp/setup.sql >"$scratch/setup.out"

query() { # <SQL>
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --username postgres --dbname automation_data_control \
    --command="$1"
}
first_id='00000000-0000-4000-8000-000000000101'
second_id='00000000-0000-4000-8000-000000000102'
first_sql="SELECT platform_operations.claim_nocodb_operation(
  'claim_fixture','extra','sync',NULL,'$first_id'::uuid)->>'canExecute'"
second_sql="SELECT platform_operations.claim_nocodb_operation(
  'claim_fixture','extra','sync',NULL,'$second_id'::uuid)->>'canExecute'"

# Hold the first transaction open after claiming while a second session competes.
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --tuples-only --no-align --username postgres --dbname automation_data_control \
  --command="BEGIN; $first_sql; SELECT pg_sleep(2); COMMIT" >"$scratch/first.out" &
first_pid=$!
sleep 0.4
query "$second_sql" >"$scratch/second.out"
wait "$first_pid"
rg -qx 'true' "$scratch/first.out"
rg -qx 'false' "$scratch/second.out"

# A retry observes the retained claim; a different operation cannot change its target.
[[ "$(query "$first_sql")" == false ]]
if query "SELECT platform_operations.claim_nocodb_operation(
  'claim_fixture','extra','rotate','reader','$first_id'::uuid)->>'canExecute'" \
  >"$scratch/target.out" 2>"$scratch/target.err"; then
  echo 'A retry changed the claimed operation target.' >&2
  exit 1
fi
rg -q 'nocodb_claim_target_mismatch' "$scratch/target.err"
[[ "$(query "SELECT platform_operations.claim_nocodb_operation(
  'claim_fixture','sibling','sync',NULL,'$second_id'::uuid)->>'canExecute'")" == true ]]
[[ "$(query "SELECT platform_operations.prepare_nocodb_access(
  'claim_fixture','extra')->>'readerEligible'")" == false ]]
[[ "$(query "SELECT count(*) FROM platform_operations.managed_nocodb_sources
  WHERE domain = 'claim_fixture' AND pair = 'extra' AND state = 'awaiting_grants'")" == 2 ]]

cat >"$scratch/grants.sql" <<'SQL'
CREATE SCHEMA extra_read AUTHORIZATION claim_fixture_owner;
CREATE SCHEMA extra_edit AUTHORIZATION claim_fixture_owner;
REVOKE ALL ON SCHEMA extra_read, extra_edit FROM PUBLIC;
SET ROLE claim_fixture_owner;
CREATE TABLE extra_read.present (id integer PRIMARY KEY, value text);
CREATE TABLE extra_edit.decision (id integer PRIMARY KEY, status text);
RESET ROLE;
GRANT CONNECT ON DATABASE claim_fixture TO
  nocodb_5be7e292440d4855a97bfecf0b31463d_reader,
  nocodb_5be7e292440d4855a97bfecf0b31463d_operator;
GRANT USAGE ON SCHEMA extra_read TO
  nocodb_5be7e292440d4855a97bfecf0b31463d_reader;
GRANT SELECT ON extra_read.present TO
  nocodb_5be7e292440d4855a97bfecf0b31463d_reader;
GRANT USAGE ON SCHEMA extra_edit TO
  nocodb_5be7e292440d4855a97bfecf0b31463d_operator;
GRANT SELECT ON extra_edit.decision TO
  nocodb_5be7e292440d4855a97bfecf0b31463d_operator;
GRANT UPDATE (status) ON extra_edit.decision TO
  nocodb_5be7e292440d4855a97bfecf0b31463d_operator;
SQL
pair_hash="$(printf 'claim_fixture:extra' | md5sum | cut -d' ' -f1)"
sed -i.bak "s/5be7e292440d4855a97bfecf0b31463d/$pair_hash/g" "$scratch/grants.sql"
rm -f "$scratch/grants.sql.bak"
podman cp "$scratch/grants.sql" "$container:/tmp/grants.sql"
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username postgres --dbname claim_fixture --file /tmp/grants.sql >"$scratch/grants.out"

[[ "$(query "SELECT platform_operations.prepare_nocodb_access(
  'claim_fixture','extra')->>'readerEligible'")" == true ]]
[[ "$(query "SELECT platform_operations.prepare_nocodb_access(
  'claim_fixture','extra')->>'operatorEligible'")" == true ]]

cat >"$scratch/transitions.sql" <<'SQL'
\getenv reader_password SOURCE_READER_PASSWORD
\getenv operator_password SOURCE_OPERATOR_PASSWORD
SELECT platform_operations.begin_nocodb_source(
  'claim_fixture','extra','reader','synthetic-base',:'reader_password',
  '00000000-0000-4000-8000-000000000101'::uuid,
  (SELECT generation FROM platform_operations.nocodb_source_operations
    WHERE domain = 'claim_fixture' AND pair = 'extra'));
SELECT platform_operations.record_nocodb_integration(
  'claim_fixture','extra','reader','synthetic-reader-integration',
  '00000000-0000-4000-8000-000000000101'::uuid,
  (SELECT generation FROM platform_operations.nocodb_source_operations
    WHERE domain = 'claim_fixture' AND pair = 'extra'));
SELECT platform_operations.record_nocodb_source_job(
  'claim_fixture','extra','reader','synthetic-reader-job',
  '00000000-0000-4000-8000-000000000101'::uuid,
  (SELECT generation FROM platform_operations.nocodb_source_operations
    WHERE domain = 'claim_fixture' AND pair = 'extra'));
SELECT platform_operations.record_nocodb_source_ready(
  'claim_fixture','extra','reader','synthetic-reader-source',
  '00000000-0000-4000-8000-000000000101'::uuid,
  (SELECT generation FROM platform_operations.nocodb_source_operations
    WHERE domain = 'claim_fixture' AND pair = 'extra'));
SELECT platform_operations.begin_nocodb_source(
  'claim_fixture','extra','operator','synthetic-base',:'operator_password',
  '00000000-0000-4000-8000-000000000101'::uuid,
  (SELECT generation FROM platform_operations.nocodb_source_operations
    WHERE domain = 'claim_fixture' AND pair = 'extra'));
SELECT platform_operations.record_nocodb_integration(
  'claim_fixture','extra','operator','synthetic-operator-integration',
  '00000000-0000-4000-8000-000000000101'::uuid,
  (SELECT generation FROM platform_operations.nocodb_source_operations
    WHERE domain = 'claim_fixture' AND pair = 'extra'));
SELECT platform_operations.record_nocodb_source_job(
  'claim_fixture','extra','operator','synthetic-operator-job',
  '00000000-0000-4000-8000-000000000101'::uuid,
  (SELECT generation FROM platform_operations.nocodb_source_operations
    WHERE domain = 'claim_fixture' AND pair = 'extra'));
SELECT platform_operations.record_nocodb_source_ready(
  'claim_fixture','extra','operator','synthetic-operator-source',
  '00000000-0000-4000-8000-000000000101'::uuid,
  (SELECT generation FROM platform_operations.nocodb_source_operations
    WHERE domain = 'claim_fixture' AND pair = 'extra'));
SQL
podman cp "$scratch/transitions.sql" "$container:/tmp/transitions.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
  --file /tmp/transitions.sql >"$scratch/transitions.out"

generation="$(query "SELECT generation FROM platform_operations.nocodb_source_operations
  WHERE domain = 'claim_fixture' AND pair = 'extra'")"
if query "SELECT platform_operations.complete_nocodb_operation(
  'claim_fixture','extra','$second_id'::uuid,$generation)" \
  >"$scratch/stale.out" 2>"$scratch/stale.err"; then
  echo 'A stale operation completed another caller’s claim.' >&2
  exit 1
fi
rg -q 'nocodb_claim_stale' "$scratch/stale.err"
[[ "$(query "SELECT platform_operations.complete_nocodb_operation(
  'claim_fixture','extra','$first_id'::uuid,$generation)->>'phase'")" == complete ]]
[[ "$(query "SELECT platform_operations.read_nocodb_operation_state(
  'claim_fixture','extra')->>'operationId'")" == "$first_id" ]]
[[ "$(query "SELECT platform_operations.read_nocodb_source_state(
  'claim_fixture','extra','reader')->>'sourceId'")" == synthetic-reader-source ]]
[[ "$(query "SELECT count(*) FROM platform_operations.managed_nocodb_sources
  WHERE domain = 'claim_fixture' AND pair = 'sibling'")" == 0 ]]
[[ "$(query "SELECT credential_generation FROM platform_operations.managed_nocodb_sources
  WHERE domain = 'claim_fixture' AND pair = 'extra' AND access_kind = 'reader'")" == 1 ]]

if query "SELECT platform_operations.begin_nocodb_source(
  'claim_fixture','reader','synthetic-base',repeat('x',48))" \
  >"$scratch/unclaimed.out" 2>"$scratch/unclaimed.err"; then
  echo 'Legacy source begin bypassed the default claim.' >&2
  exit 1
fi
rg -q 'invalid_nocodb_claim' "$scratch/unclaimed.err"

default_id='00000000-0000-4000-8000-000000000103'
[[ "$(query "SELECT platform_operations.claim_nocodb_operation(
  'claim_fixture','default','sync',NULL,'$default_id'::uuid)->>'canExecute'")" == true ]]
[[ "$(query "SELECT platform_operations.claim_nocodb_operation(
  'claim_fixture','default','sync',NULL,'$second_id'::uuid)->>'canExecute'")" == false ]]

# An unresolved outcome cannot be replaced by a timeout or another caller.
sibling_generation="$(query "SELECT generation FROM platform_operations.nocodb_source_operations
  WHERE domain = 'claim_fixture' AND pair = 'sibling'")"
[[ "$(query "SELECT platform_operations.mark_nocodb_operation_uncertain(
  'claim_fixture','sibling','$second_id'::uuid,$sibling_generation,
  'api_response_unknown')->>'phase'")" == uncertain ]]
[[ "$(query "SELECT platform_operations.claim_nocodb_operation(
  'claim_fixture','sibling','sync',NULL,'$default_id'::uuid)->>'canExecute'")" == false ]]

rotate_id='00000000-0000-4000-8000-000000000104'
[[ "$(query "SELECT platform_operations.claim_nocodb_operation(
  'claim_fixture','extra','rotate','reader','$rotate_id'::uuid)->>'canExecute'")" == true ]]
cat >"$scratch/rotate.sql" <<'SQL'
\getenv reader_password SOURCE_READER_PASSWORD
CREATE TEMP TABLE verifier_before AS
  SELECT rolname, rolpassword FROM pg_authid
  WHERE rolname IN (
    'nocodb_' || md5('claim_fixture:extra') || '_reader',
    'nocodb_' || md5('claim_fixture:extra') || '_operator');
SELECT platform_operations.rotate_nocodb_source_credential(
  'claim_fixture','extra','reader',:'reader_password',
  '00000000-0000-4000-8000-000000000104'::uuid,
  (SELECT generation FROM platform_operations.nocodb_source_operations
    WHERE domain = 'claim_fixture' AND pair = 'extra'));
DO $test$
BEGIN
  IF NOT EXISTS (SELECT FROM verifier_before AS before
      JOIN pg_authid AS after ON after.rolname = before.rolname
      WHERE before.rolname LIKE '%_operator' AND
        after.rolpassword IS NOT DISTINCT FROM before.rolpassword) OR
     (SELECT credential_generation FROM platform_operations.managed_nocodb_sources
       WHERE domain = 'claim_fixture' AND pair = 'extra' AND access_kind = 'reader') <> 2 THEN
    RAISE EXCEPTION 'rotation touched a sibling or did not advance once';
  END IF;
END;
$test$;
SQL
podman cp "$scratch/rotate.sql" "$container:/tmp/rotate.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
  --file /tmp/rotate.sql >"$scratch/rotate.out"
if podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
    --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
    --file /tmp/rotate.sql >"$scratch/rotate-again.out" 2>"$scratch/rotate-again.err"; then
  echo 'A repeated rotation was accepted.' >&2
  exit 1
fi
rg -q 'source_not_ready' "$scratch/rotate-again.err"
[[ "$(query "SELECT credential_generation FROM platform_operations.managed_nocodb_sources
  WHERE domain = 'claim_fixture' AND pair = 'extra' AND access_kind = 'reader'")" == 2 ]]

# A mapped operator still awaiting reviewed grants does not block a ready reader.
query "SELECT platform_operations.configure_nocodb_pair(
  'claim_fixture','pending','pending_read','pending_edit')" >"$scratch/pending-registration.out"
cat >"$scratch/pending-grants.sql" <<'SQL'
CREATE SCHEMA pending_read AUTHORIZATION claim_fixture_owner;
CREATE SCHEMA pending_edit AUTHORIZATION claim_fixture_owner;
REVOKE ALL ON SCHEMA pending_read, pending_edit FROM PUBLIC;
SET ROLE claim_fixture_owner;
CREATE TABLE pending_read.present (id integer PRIMARY KEY);
RESET ROLE;
DO $test$
DECLARE reader_name text := 'nocodb_' || md5('claim_fixture:pending') || '_reader';
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE claim_fixture TO %I', reader_name);
  EXECUTE format('GRANT USAGE ON SCHEMA pending_read TO %I', reader_name);
  EXECUTE format('GRANT SELECT ON pending_read.present TO %I', reader_name);
  EXECUTE format('ALTER ROLE %I LOGIN', reader_name);
END;
$test$;
SQL
podman cp "$scratch/pending-grants.sql" "$container:/tmp/pending-grants.sql"
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username postgres --dbname claim_fixture --file /tmp/pending-grants.sql \
  >"$scratch/pending-grants.out"
query "INSERT INTO platform_operations.managed_nocodb_sources
  (domain,pair,access_kind,role_name,base_id,integration_id,source_id,
   source_create_job_id,state,operation,generation,credential_generation,validated_at)
  VALUES ('claim_fixture','pending','reader',
    'nocodb_' || md5('claim_fixture:pending') || '_reader',
    'pending-base','pending-integration','pending-source','pending-job',
    'ready','sync',1,1,clock_timestamp())" >"$scratch/pending-source.out"
[[ "$(query "SELECT platform_operations.prepare_nocodb_access(
  'claim_fixture','pending')->>'operatorEligible'")" == false ]]
[[ "$(query "SELECT state FROM platform_operations.managed_nocodb_sources
  WHERE domain = 'claim_fixture' AND pair = 'pending' AND access_kind = 'operator'")" == awaiting_grants ]]
pending_id='00000000-0000-4000-8000-000000000105'
[[ "$(query "SELECT platform_operations.claim_nocodb_operation(
  'claim_fixture','pending','sync',NULL,'$pending_id'::uuid)->>'canExecute'")" == true ]]
pending_generation="$(query "SELECT generation FROM platform_operations.nocodb_source_operations
  WHERE domain = 'claim_fixture' AND pair = 'pending'")"
[[ "$(query "SELECT platform_operations.complete_nocodb_operation(
  'claim_fixture','pending','$pending_id'::uuid,$pending_generation)->>'phase'")" == complete ]]
echo 'NocoDB pair lifecycle PostgreSQL claims passed.'
