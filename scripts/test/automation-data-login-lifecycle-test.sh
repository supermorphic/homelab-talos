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
  postgres:17.11-alpine3.24 >"$scratch/container-id"
for _attempt in {1..60}; do
  if podman exec "$container" sh -eu -c 'grep -qx postgres /proc/1/comm' >/dev/null 2>&1 &&
      podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
      --tuples-only --no-align --username postgres --dbname automation_data_control \
      --command='SELECT platform_operations.read_platform_revision()' 2>/dev/null \
      | rg -qx '026-nocodb-v3'; then break; fi
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
echo 'Application login lifecycle PostgreSQL behavior passed.'
