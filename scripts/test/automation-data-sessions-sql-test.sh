#!/usr/bin/env bash
# Exercise access-session capability registration, validation, and temporary login
# lifecycle in disposable PostgreSQL.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-sessions.XXXXXX")"
chmod 700 "$scratch"
marker="automation-data-sessions-$$-$RANDOM"
container="${marker:0:63}"
cleanup() {
  if podman container exists "$container" >/dev/null 2>&1 &&
      [[ "$(podman inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' "$container")" == "$marker" ]]; then
    podman rm --force "$container" >/dev/null || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
fail() {
  echo "automation-data sessions SQL test failed: $*" >&2
  exit 1
}
# Podman may run as a sibling engine that sees TMPDIR but not this checkout, so
# containers mount a staged copy of the scripts.
cp -R "$(pwd)/kubernetes/apps/automation-data/postgresql/app/scripts" "$scratch/scripts"
scripts="$scratch/scripts"
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

# Run SQL as postgres in a database; output is tuples only.
dbquery() {
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --username postgres --dbname "$1" --command="$2"
}
query() { dbquery automation_data_control "$1"; }
# Require that SQL fails with the named error code in its message.
expect_error() {
  local code="$1" database="$2" sql="$3"
  if dbquery "$database" "$sql" >"$scratch/expect.out" 2>"$scratch/expect.err"; then
    fail "expected $code from: $sql"
  fi
  rg -q -- "$code" "$scratch/expect.err" || {
    cat "$scratch/expect.err" >&2
    fail "expected $code, got a different error"
  }
}
install_sessions() {
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 --username postgres \
    --dbname automation_data_control --file /scripts/access-sessions.sql >"$scratch/install.out"
}

install_sessions
cat >"$scratch/setup.sql" <<'SQL'
\getenv migrator_password FIXTURE_MIGRATOR_PASSWORD
\getenv runtime_password FIXTURE_RUNTIME_PASSWORD
SELECT platform_operations.provision_domain('session_fixture', :'migrator_password', :'runtime_password');
SELECT platform_operations.record_domain_credentials('session_fixture', 'synthetic-migrator',
  'synthetic-runtime', '2026-09-01T00:00:00Z'::timestamptz,
  '2026-09-01T00:00:00Z'::timestamptz);
SQL
podman cp "$scratch/setup.sql" "$container:/tmp/sessions-setup.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --username postgres --dbname automation_data_control \
  --file /tmp/sessions-setup.sql >"$scratch/setup.out"
dbquery session_fixture "
  CREATE SCHEMA read_api AUTHORIZATION session_fixture_owner;
  REVOKE ALL ON SCHEMA read_api FROM PUBLIC;
  ALTER DEFAULT PRIVILEGES FOR ROLE session_fixture_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
  SET ROLE session_fixture_owner;
  CREATE TABLE read_api.present (id integer PRIMARY KEY);
  INSERT INTO read_api.present VALUES (1);
  RESET ROLE;" >/dev/null

cap="cap_$(printf 'session_fixture:read' | md5sum | cut -d' ' -f1)_access"
valid() { query "SELECT platform_operations.validate_access_capability('session_fixture','read')->>'valid'"; }

# Registration creates a dedicated grant target and is idempotent for the same binding.
[[ "$(query "SELECT platform_operations.register_access_capability(
  'session_fixture','read',ARRAY['read_api'],600)->>'role'")" == "$cap" ]] ||
  fail 'registration did not return the capability role'
[[ "$(query "SELECT rolcanlogin::text || rolinherit::text || rolsuper::text || rolcreaterole::text
  FROM pg_roles WHERE rolname = '$cap'")" == falsefalsefalsefalse ]] ||
  fail 'capability role must be NOLOGIN NOINHERIT without attributes'
[[ "$(query "SELECT count(*) FROM pg_auth_members m JOIN pg_roles r
  ON r.oid = m.member OR r.oid = m.roleid WHERE r.rolname = '$cap'")" == 0 ]] ||
  fail 'capability role must start without memberships'
[[ "$(query "SELECT platform_operations.register_access_capability(
  'session_fixture','read',ARRAY['read_api'],600)->>'state'")" == ready ]] ||
  fail 'repeated registration must return the existing capability'
expect_error access_capability_binding_conflict automation_data_control \
  "SELECT platform_operations.register_access_capability('session_fixture','read',ARRAY['other_api'],600)"
collide="cap_$(printf 'session_fixture:collide' | md5sum | cut -d' ' -f1)_access"
query "CREATE ROLE \"$collide\" NOLOGIN" >/dev/null
expect_error access_capability_role_collision automation_data_control \
  "SELECT platform_operations.register_access_capability('session_fixture','collide',ARRAY['read_api'],600)"
expect_error invalid_access_capability automation_data_control \
  "SELECT platform_operations.register_access_capability('session_fixture','Bad-Name',ARRAY['read_api'],600)"
expect_error invalid_access_capability_ttl automation_data_control \
  "SELECT platform_operations.register_access_capability('session_fixture','long',ARRAY['read_api'],601)"

# Validation enforces the read-only privilege ceiling on effective privileges.
[[ "$(valid)" == false ]] || fail 'a capability without grants must be invalid'
dbquery session_fixture "
  GRANT CONNECT ON DATABASE session_fixture TO \"$cap\";
  GRANT USAGE ON SCHEMA read_api TO \"$cap\";
  GRANT SELECT ON read_api.present TO \"$cap\";" >/dev/null
[[ "$(valid)" == true ]] || fail 'reviewed read grants must validate'
dbquery session_fixture "GRANT INSERT ON read_api.present TO \"$cap\"" >/dev/null
[[ "$(valid)" == false ]] || fail 'direct DML must invalidate the capability'
dbquery session_fixture "REVOKE INSERT ON read_api.present FROM \"$cap\"" >/dev/null
[[ "$(valid)" == true ]] || fail 'revoking DML must restore validity'
dbquery session_fixture "
  SET ROLE session_fixture_owner;
  CREATE FUNCTION read_api.write_present() RETURNS void LANGUAGE sql SECURITY DEFINER
    SET search_path = pg_catalog AS 'INSERT INTO read_api.present VALUES (2)';
  RESET ROLE;
  GRANT EXECUTE ON FUNCTION read_api.write_present() TO PUBLIC;" >/dev/null
[[ "$(valid)" == false ]] || fail 'a PUBLIC SECURITY DEFINER function must invalidate read'
dbquery session_fixture "REVOKE EXECUTE ON FUNCTION read_api.write_present() FROM PUBLIC" >/dev/null
[[ "$(valid)" == true ]] || fail 'revoking the definer function must restore validity'
dbquery session_fixture "GRANT TEMP ON DATABASE session_fixture TO \"$cap\"" >/dev/null
[[ "$(valid)" == false ]] || fail 'TEMP must invalidate the capability'
dbquery session_fixture "REVOKE TEMP ON DATABASE session_fixture FROM \"$cap\"" >/dev/null
query "GRANT CONNECT ON DATABASE postgres TO \"$cap\"" >/dev/null
[[ "$(valid)" == false ]] || fail 'CONNECT to another database must invalidate the capability'
query "REVOKE CONNECT ON DATABASE postgres FROM \"$cap\"" >/dev/null
[[ "$(valid)" == true ]] || fail 'capability must be valid after reverting violations'
query "GRANT \"$cap\" TO session_fixture_runtime" >/dev/null
[[ "$(valid)" == false ]] || fail 'an unregistered member must invalidate the capability'
query "REVOKE \"$cap\" FROM session_fixture_runtime" >/dev/null
[[ "$(valid)" == true ]] || fail 'capability must be valid after removing the member'
query "SELECT platform_internal.assert_access_session_contract()" >/dev/null

echo 'automation-data sessions SQL test passed'
