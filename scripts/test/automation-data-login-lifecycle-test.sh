#!/usr/bin/env bash
# Exercise application login registration and credential transitions in disposable PostgreSQL.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-login.XXXXXX")"
chmod 700 "$scratch"
marker="automation-data-login-$$-$RANDOM"
container="${marker:0:63}"
cleanup() {
  if podman container exists "$container" >/dev/null 2>&1 &&
      [[ "$(podman inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$container")" == "$marker" ]]; then
    podman rm --force "$container" >/dev/null || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
scripts="$(pwd)/kubernetes/apps/automation-data/postgresql/app/scripts"
cat >"$scratch/postgresql.env" <<EOF
POSTGRES_USER=postgres
POSTGRES_DB=automation_data_control
POSTGRES_PASSWORD=$(openssl rand -hex 24)
PROVISIONER_PASSWORD=$(openssl rand -hex 24)
BACKUP_PASSWORD=$(openssl rand -hex 24)
EXPORTER_PASSWORD=$(openssl rand -hex 24)
FIXTURE_MIGRATOR_PASSWORD=$(openssl rand -hex 24)
FIXTURE_RUNTIME_PASSWORD=$(openssl rand -hex 24)
APPLICATION_PASSWORD=$(openssl rand -hex 32)
ROTATED_PASSWORD=$(openssl rand -hex 32)
SIBLING_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 "$scratch/postgresql.env"
podman run --detach --name "$container" --label "homelab-talos.test-run=$marker" \
  --env-file "$scratch/postgresql.env" --volume "$scripts:/scripts:ro" \
  --volume "$scripts/init-platform.sh:/docker-entrypoint-initdb.d/00-init-platform.sh:ro" \
  docker.io/library/postgres:17.11-alpine3.24 >"$scratch/container-id"
for _attempt in {1..60}; do
  if podman exec "$container" sh -eu -c 'grep -qx postgres /proc/1/comm' >/dev/null 2>&1 &&
      podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
      --tuples-only --no-align --username postgres --dbname automation_data_control \
      --command='SELECT platform_operations.read_platform_revision()' 2>/dev/null \
      | rg -qx '026-nocodb-v4'; then break; fi
  sleep 1
done
podman exec "$container" sh -eu -c 'grep -qx postgres /proc/1/comm'
query() {
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --username postgres --dbname automation_data_control \
    --command="$1"
}
cat >"$scratch/setup.sql" <<'SQL'
\getenv migrator_password FIXTURE_MIGRATOR_PASSWORD
\getenv runtime_password FIXTURE_RUNTIME_PASSWORD
SELECT platform_operations.provision_domain('login_fixture', :'migrator_password', :'runtime_password');
SELECT platform_operations.record_domain_credentials('login_fixture', 'synthetic-migrator',
  'synthetic-runtime', '2026-09-01T00:00:00Z'::timestamptz,
  '2026-09-01T00:00:00Z'::timestamptz);
SELECT platform_operations.register_application_login('login_fixture','interview','interview_api');
SELECT platform_operations.register_application_login('login_fixture','sibling','sibling_api');
SQL
podman cp "$scratch/setup.sql" "$container:/tmp/login-setup.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
  --file /tmp/login-setup.sql >"$scratch/setup.out"
role="app_$(printf 'login_fixture:interview' | md5sum | cut -d' ' -f1)_integration"
sibling="app_$(printf 'login_fixture:sibling' | md5sum | cut -d' ' -f1)_integration"
[[ "$(query "SELECT rolcanlogin FROM pg_roles WHERE rolname = '$role'")" == f ]]
[[ "$(query "SELECT platform_operations.read_application_login_state('login_fixture','interview')->>'credentialGeneration'")" == 0 ]]
if query "SELECT platform_operations.register_application_login('login_fixture','interview','another_schema')" \
  >"$scratch/rebind.out" 2>"$scratch/rebind.err"; then
  echo 'Application registration rebound a schema.' >&2; exit 1
fi
rg -q 'application_binding_conflict' "$scratch/rebind.err"

activate_id='00000000-0000-4000-8000-000000000201'
rotate_id='00000000-0000-4000-8000-000000000202'
stale_id='00000000-0000-4000-8000-000000000203'
cat >"$scratch/activate.sql" <<SQL
\getenv password APPLICATION_PASSWORD
SELECT platform_operations.install_application_credential(
  'login_fixture','interview','activate','$activate_id'::uuid,0,:'password');
SQL
podman cp "$scratch/activate.sql" "$container:/tmp/login-activate.sql"
if podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
    --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
    --file /tmp/login-activate.sql >"$scratch/early.out" 2>"$scratch/early.err"; then
  echo 'Activation bypassed reviewed grants.' >&2; exit 1
fi
rg -q 'application_grants_invalid' "$scratch/early.err"
cat >"$scratch/grants.sql" <<SQL
CREATE SCHEMA interview_api AUTHORIZATION login_fixture_owner;
CREATE SCHEMA sibling_api AUTHORIZATION login_fixture_owner;
REVOKE ALL ON SCHEMA interview_api, sibling_api FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE login_fixture_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
SET ROLE login_fixture_owner;
CREATE TABLE interview_api.present (id integer PRIMARY KEY);
CREATE FUNCTION interview_api.allowed() RETURNS integer LANGUAGE sql AS 'SELECT 1';
CREATE TABLE sibling_api.present (id integer PRIMARY KEY);
CREATE FUNCTION sibling_api.allowed() RETURNS integer LANGUAGE sql AS 'SELECT 1';
RESET ROLE;
GRANT CONNECT ON DATABASE login_fixture TO "$role", "$sibling";
GRANT USAGE ON SCHEMA interview_api TO "$role";
GRANT SELECT ON interview_api.present TO "$role";
GRANT EXECUTE ON FUNCTION interview_api.allowed() TO "$role";
GRANT USAGE ON SCHEMA sibling_api TO "$sibling";
GRANT SELECT ON sibling_api.present TO "$sibling";
GRANT EXECUTE ON FUNCTION sibling_api.allowed() TO "$sibling";
SQL
podman cp "$scratch/grants.sql" "$container:/tmp/login-grants.sql"
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username postgres --dbname login_fixture --file /tmp/login-grants.sql >"$scratch/grants.out"
[[ "$(query "SELECT platform_operations.validate_application_login('login_fixture','interview')->>'valid'")" == true ]]
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --tuples-only --no-align --username postgres \
  --dbname automation_data_control --file /tmp/login-activate.sql >"$scratch/activated.out"
rg -q '"credentialGeneration": 1' "$scratch/activated.out"
[[ "$(query "SELECT state FROM platform_operations.managed_application_logins
  WHERE domain = 'login_fixture' AND application = 'interview'")" == activating ]]
[[ "$(query "SELECT rolcanlogin FROM pg_roles WHERE rolname = '$role'")" == t ]]
verifier_before="$(query "SELECT rolpassword FROM pg_authid WHERE rolname = '$role'")"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --tuples-only --no-align --username postgres \
  --dbname automation_data_control --file /tmp/login-activate.sql >"$scratch/retry.out"
[[ "$(query "SELECT rolpassword FROM pg_authid WHERE rolname = '$role'")" == "$verifier_before" ]]
[[ "$(query "SELECT credential_generation FROM platform_operations.managed_application_logins
  WHERE domain = 'login_fixture' AND application = 'interview'")" == 1 ]]
[[ "$(query "SELECT platform_operations.complete_application_credential(
  'login_fixture','interview','$activate_id'::uuid,1)->>'state'")" == ready ]]
sibling_id='00000000-0000-4000-8000-000000000204'
cat >"$scratch/sibling.sql" <<SQL
\getenv password SIBLING_PASSWORD
SELECT platform_operations.install_application_credential(
  'login_fixture','sibling','activate','$sibling_id'::uuid,0,:'password');
SQL
podman cp "$scratch/sibling.sql" "$container:/tmp/login-sibling.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
  --file /tmp/login-sibling.sql >"$scratch/sibling.out"
[[ "$(query "SELECT platform_operations.complete_application_credential(
  'login_fixture','sibling','$sibling_id'::uuid,1)->>'state'")" == ready ]]
if query "SELECT platform_operations.install_application_credential(
  'login_fixture','interview','rotate','$stale_id'::uuid,0,repeat('x',40))" \
  >"$scratch/stale.out" 2>"$scratch/stale.err"; then
  echo 'Stale candidate replaced a newer generation.' >&2; exit 1
fi
rg -q 'application_generation_mismatch' "$scratch/stale.err"
cat >"$scratch/rotate.sql" <<SQL
\getenv password ROTATED_PASSWORD
SELECT platform_operations.install_application_credential(
  'login_fixture','interview','rotate','$rotate_id'::uuid,1,:'password');
SQL
podman cp "$scratch/rotate.sql" "$container:/tmp/login-rotate.sql"
sibling_before="$(query "SELECT rolpassword FROM pg_authid WHERE rolname = '$sibling'")"
[[ -n "$sibling_before" ]]
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
  --file /tmp/login-rotate.sql >"$scratch/rotated.out"
[[ "$(query "SELECT credential_generation FROM platform_operations.managed_application_logins
  WHERE domain = 'login_fixture' AND application = 'interview'")" == 2 ]]
[[ "$(query "SELECT rolpassword FROM pg_authid WHERE rolname = '$sibling'")" == "$sibling_before" ]]
[[ "$(query "SELECT rolpassword FROM pg_authid WHERE rolname = '$role'")" != "$verifier_before" ]]
[[ "$(query "SELECT platform_operations.complete_application_credential(
  'login_fixture','interview','$rotate_id'::uuid,2)->>'state'")" == ready ]]
# Retirement disables an unused login only after its consumer removed every grant.
generation() { query 'SELECT generation FROM platform_operations.platform_generation'; }
retire() {
  query "SET ROLE automation_data_provisioner;
    SELECT platform_operations.retire_application_login('login_fixture','$1')" | tail -n 1
}
login_state() {
  query "SELECT state FROM platform_operations.managed_application_logins
    WHERE domain = 'login_fixture' AND application = '$1'"
}
retire interview >"$scratch/granted.out"
[[ "$(jq -r '.errorCode' "$scratch/granted.out")" == application_login_still_granted ]]
jq -e '.failedChecks | index("schemaPrivilegesValid")' "$scratch/granted.out" >/dev/null
[[ "$(login_state interview)" == ready ]]
[[ "$(query "SELECT rolcanlogin FROM pg_roles WHERE rolname = '$role'")" == t ]]
if query "SET ROLE login_fixture_owner;
    SELECT platform_operations.retire_application_login('login_fixture','interview')" \
  >"$scratch/denied.out" 2>"$scratch/denied.err"; then
  echo 'A non-provisioner role retired an application login.' >&2; exit 1
fi
rg -q 'permission denied' "$scratch/denied.err"
# An open session survives the consumer's revocation; retirement must not end it.
podman exec --detach --env-file "$scratch/postgresql.env" "$container" sh -eu -c \
  "PGPASSWORD=\"\$ROTATED_PASSWORD\" psql --no-psqlrc --host 127.0.0.1 --username '$role' \
    --dbname login_fixture --command 'SELECT pg_sleep(120)'"
for _attempt in {1..30}; do
  [[ "$(query "SELECT count(*) FROM pg_stat_activity WHERE usename = '$role'")" == 1 ]] && break
  sleep 1
done
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 --username postgres \
  --dbname login_fixture --command "REVOKE CONNECT ON DATABASE login_fixture FROM \"$role\";
    REVOKE USAGE ON SCHEMA interview_api FROM \"$role\";
    REVOKE SELECT ON interview_api.present FROM \"$role\";
    REVOKE EXECUTE ON FUNCTION interview_api.allowed() FROM \"$role\"" >"$scratch/revoke.out"
retire interview >"$scratch/in-use.out"
jq -e '.errorCode == "application_login_in_use"' "$scratch/in-use.out" >/dev/null ||
  { cat "$scratch/in-use.out" >&2; exit 1; }
[[ "$(jq -r '.errorCode' "$scratch/in-use.out")" == application_login_in_use ]]
[[ "$(query "SELECT count(*) FROM pg_stat_activity WHERE usename = '$role'")" == 1 ]]
query "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '$role'" >/dev/null
for _attempt in {1..30}; do
  [[ "$(query "SELECT count(*) FROM pg_stat_activity WHERE usename = '$role'")" == 0 ]] && break
  sleep 1
done
before="$(generation)"
retire interview >"$scratch/retired.out"
[[ "$(jq -r '.state' "$scratch/retired.out")" == retired ]]
[[ "$(jq -r 'has("errorCode")' "$scratch/retired.out")" == false ]]
[[ "$(jq -r '.credentialGeneration' "$scratch/retired.out")" == 2 ]]
[[ "$(query "SELECT rolcanlogin FROM pg_roles WHERE rolname = '$role'")" == f ]]
[[ "$(query "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname = '$role'")" == t ]]
[[ "$(query "SELECT concat_ws(',', operation_id, operation, expected_generation,
  operation_started_at, error_code) FROM platform_operations.managed_application_logins
  WHERE domain = 'login_fixture' AND application = 'interview'")" == '' ]]
[[ "$(generation)" == $((before + 1)) ]]
retire interview >"$scratch/repeat.out"
[[ "$(jq -r '.state' "$scratch/repeat.out")" == retired ]]
[[ "$(generation)" == $((before + 1)) ]]
[[ "$(query "SELECT platform_operations.validate_application_login('login_fixture','interview')->>'valid'")" == true ]]
expect_retired() {
  if query "$1" >"$scratch/refused.out" 2>"$scratch/refused.err"; then
    echo "A retired login accepted: $2" >&2; exit 1
  fi
  rg -q 'application_login_retired' "$scratch/refused.err"
}
expect_retired "SELECT platform_operations.register_application_login('login_fixture','interview','interview_api')" registration
expect_retired "SELECT platform_operations.install_application_credential('login_fixture','interview','activate',
  '00000000-0000-4000-8000-000000000205'::uuid,2,repeat('x',40))" activation
expect_retired "SELECT platform_operations.install_application_credential('login_fixture','interview','rotate',
  '00000000-0000-4000-8000-000000000206'::uuid,2,repeat('x',40))" rotation
expect_retired "SELECT platform_operations.complete_application_credential('login_fixture','interview',
  '$rotate_id'::uuid,2)" completion
# A consumer rebuilt on the existing platform may grant the retired role again.
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 --username postgres \
  --dbname login_fixture --command "GRANT USAGE ON SCHEMA interview_api TO \"$role\"" >/dev/null
query "SELECT platform_operations.validate_application_login('login_fixture','interview')" >"$scratch/regranted.out"
[[ "$(jq -r '.valid' "$scratch/regranted.out")" == false ]]
[[ "$(jq -r '.schemaPrivilegesValid' "$scratch/regranted.out")" == false ]]
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 --username postgres \
  --dbname login_fixture --command "REVOKE USAGE ON SCHEMA interview_api FROM \"$role\"" >/dev/null
# Never-activated and failed logins retire directly; an active operation refuses.
query "SELECT platform_operations.register_application_login('login_fixture','pending','pending_api');
  SELECT platform_operations.register_application_login('login_fixture','broken','broken_api');
  SELECT platform_operations.register_application_login('login_fixture','busy','busy_api');
  UPDATE platform_operations.managed_application_logins SET state = 'error', error_code = 'synthetic_failure'
    WHERE domain = 'login_fixture' AND application = 'broken';
  UPDATE platform_operations.managed_application_logins SET state = 'activating',
    operation = 'activate', operation_id = '00000000-0000-4000-8000-000000000207'::uuid,
    expected_generation = 0, operation_started_at = clock_timestamp()
    WHERE domain = 'login_fixture' AND application = 'busy'" >/dev/null
[[ "$(retire pending | jq -r '.state')" == retired ]]
[[ "$(retire broken | jq -r '.state')" == retired ]]
[[ "$(query "SELECT error_code IS NULL FROM platform_operations.managed_application_logins
  WHERE domain = 'login_fixture' AND application = 'broken'")" == t ]]
[[ "$(retire busy | jq -r '.errorCode')" == application_operation_active ]]
[[ "$(login_state busy)" == activating ]]
query 'SELECT platform_operations.read_platform_revision()' | rg -qx '026-nocodb-v4'
echo 'Application login lifecycle PostgreSQL behavior passed.'
