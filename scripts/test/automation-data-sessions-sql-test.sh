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
POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=trust
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
dbquery session_fixture "
  SET ROLE session_fixture_owner;
  SELECT lo_create(424242);
  RESET ROLE;
  GRANT UPDATE ON LARGE OBJECT 424242 TO PUBLIC;" >/dev/null
[[ "$(valid)" == false ]] || fail 'a large object writable by PUBLIC must invalidate read'
dbquery session_fixture "SELECT lo_unlink(424242)" >/dev/null
[[ "$(valid)" == true ]] || fail 'removing the writable large object must restore validity'
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

# Temporary logins: OpenBao calls issue/revoke as the issuer with a SCRAM verifier.
issuer=automation_data_openbao_issuer
sweeper=automation_data_session_sweeper
login_name() { printf 'v-session-read-%s' "$(openssl rand -hex 10)"; }
# Create a password in a private env file and print its SCRAM-SHA-256 verifier.
scram_verifier() {
  printf 'LOGIN_PASSWORD=%s\n' "$(openssl rand -hex 24)" >"$scratch/$1.env"
  chmod 600 "$scratch/$1.env"
  # shellcheck disable=SC2016 # Python source, not shell expansion.
  python3 -I -c '
import base64, hashlib, hmac, os, sys
with open(sys.argv[1], encoding="ascii") as env:
    password = env.read().strip().partition("=")[2].encode()
salt, iterations = os.urandom(16), 4096
salted = hashlib.pbkdf2_hmac("sha256", password, salt, iterations)
client = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
server = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
encode = lambda value: base64.b64encode(value).decode()
print(f"SCRAM-SHA-256${iterations}:{encode(salt)}${encode(hashlib.sha256(client).digest())}:{encode(server)}")
' "$scratch/$1.env"
}
expiration_in() {
  query "SELECT to_char(clock_timestamp() + make_interval(secs => $1), 'YYYY-MM-DD HH24:MI:SSOF')"
}
# issue NAME SECONDS [VERIFIER] [CAPABILITY]; runs as the issuer.
issue() {
  local name="$1" verifier="${3:-}" capability="${4:-read}"
  [[ -n "$verifier" ]] || verifier="$(scram_verifier "$name")"
  printf "SET ROLE %s;\nSELECT platform_operations.issue_session_login('%s', '%s', '%s', 'session_fixture', '%s');\n" \
    "$issuer" "$name" "$verifier" "$(expiration_in "$2")" "$capability" >"$scratch/issue.sql"
  podman cp "$scratch/issue.sql" "$container:/tmp/sessions-issue.sql"
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 --username postgres \
    --dbname automation_data_control --file /tmp/sessions-issue.sql || {
    local result="$?"
    echo "issuance of $name failed at $(date -u +%T); sweeper heartbeat: $(query "SELECT
      concat_ws(' ', completed_at, clock_timestamp(), revoked_count, failed_count)
      FROM platform_operations.access_session_sweeps")" >&2
    return "$result"
  }
}
# expect_issue_error CODE NAME SECONDS [VERIFIER] [CAPABILITY]
expect_issue_error() {
  local code="$1"
  shift
  if issue "$@" >"$scratch/expect.out" 2>"$scratch/expect.err"; then
    fail "issuance unexpectedly succeeded for $1"
  fi
  rg -q -- "$code" "$scratch/expect.err" || {
    cat "$scratch/expect.err" >&2
    fail "issuance expected $code"
  }
}
as_role() { query "SET ROLE $1; $2"; }
# as_login NAME DATABASE SQL authenticates over TCP with the login's password.
as_login() {
  podman exec --env-file "$scratch/$1.env" "$container" sh -c \
    'PGPASSWORD="$LOGIN_PASSWORD" exec psql --no-psqlrc --set=ON_ERROR_STOP=1 \
      --tuples-only --no-align --host 127.0.0.1 --username "$1" --dbname "$2" --command "$3"' \
    sh "$1" "$2" "$3"
}
expect_login_error() {
  if as_login "$@" >"$scratch/expect.out" 2>"$scratch/expect.err"; then
    fail "login $1 unexpectedly ran: $3"
  fi
}
sessions_of() { query "SELECT pg_stat_clear_snapshot(); SELECT count(*) FROM pg_stat_activity WHERE usename = '$1'" | tail -1; }
wait_for_session() {
  for _attempt in {1..50}; do
    [[ "$(sessions_of "$1")" -ge 1 ]] && return 0
    sleep 0.2
  done
  fail "no session appeared for $1"
}
revoked_by() { query "SELECT revoked_by FROM platform_operations.managed_dynamic_logins WHERE role_name = '$1'"; }
role_exists() { query "SELECT count(*) FROM pg_roles WHERE rolname = '$1'"; }

first="$(login_name)"
expect_issue_error reconciliation_unhealthy "$first" 600
as_role "$sweeper" 'SELECT platform_operations.sweep_session_logins()' >/dev/null

expect_issue_error invalid_session_login_name 'v-bad' 600
expect_issue_error invalid_session_login_verifier "$(login_name)" 600 'plaintext-password'
expect_issue_error invalid_session_login_expiration "$(login_name)" 700
expect_issue_error invalid_session_login_expiration "$(login_name)" -5
expect_issue_error unknown_access_capability "$(login_name)" 600 '' missing
dbquery session_fixture "GRANT INSERT ON read_api.present TO \"$cap\"" >/dev/null
expect_issue_error access_capability_invalid "$(login_name)" 600
dbquery session_fixture "REVOKE INSERT ON read_api.present FROM \"$cap\"" >/dev/null

# A CREATE ROLE failure must not echo the verifier to the client or the server log.
# An uncommitted role with the same name makes issuance wait until its timeout.
blocked="$(login_name)"
blocked_verifier="$(scram_verifier "$blocked")"
query "BEGIN; CREATE ROLE \"$blocked\"; SELECT pg_sleep(4); ROLLBACK" >/dev/null &
blocker=$!
sleep 1
# The issuer's login settings keep statements out of the log; emulate them here.
printf "SET log_min_error_statement = panic;\nSET statement_timeout = '2s';\nSET ROLE %s;\nSELECT platform_operations.issue_session_login('%s', '%s', '%s', 'session_fixture', 'read');\n" \
  "$issuer" "$blocked" "$blocked_verifier" "$(expiration_in 600)" >"$scratch/issue.sql"
podman cp "$scratch/issue.sql" "$container:/tmp/sessions-issue.sql"
if podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 --username postgres \
    --dbname automation_data_control --file /tmp/sessions-issue.sql \
    >"$scratch/expect.out" 2>"$scratch/expect.err"; then
  fail 'issuance must fail while a conflicting role creation is pending'
fi
wait "$blocker"
podman logs "$container" >"$scratch/server.log" 2>&1
for output in "$scratch/expect.err" "$scratch/server.log"; do
  if rg -qF -- "${blocked_verifier#*\$}" "$output"; then
    fail "a failed role creation exposed the verifier in $(basename "$output")"
  fi
done
rg -q session_login_create_failed "$scratch/expect.err" ||
  fail 'a failed role creation must report session_login_create_failed'
[[ "$(role_exists "$blocked")" == 0 ]] || fail 'the blocked login must not exist'

# An issued login inherits only the capability's read grants.
issue "$first" 600 >/dev/null
[[ "$(as_login "$first" session_fixture 'SELECT session_user')" == "$first" ]] ||
  fail 'the issued login must authenticate as itself'
cp "$scratch/$first.env" "$scratch/wrong.env"
printf 'LOGIN_PASSWORD=%s\n' "$(openssl rand -hex 24)" >"$scratch/$first.env"
expect_login_error "$first" session_fixture 'SELECT 1'
rg -q 'password authentication failed' "$scratch/expect.err" ||
  fail 'login checks must use password authentication, as in production'
mv "$scratch/wrong.env" "$scratch/$first.env"
[[ "$(as_login "$first" session_fixture "SELECT pg_has_role(session_user, '$cap', 'USAGE')::text
  || pg_has_role(session_user, '$cap', 'SET')::text || current_setting('transaction_read_only')")" == truefalseon ]] ||
  fail 'the login must inherit without SET and start read-only transactions'
[[ "$(as_login "$first" session_fixture 'SELECT count(*) FROM read_api.present')" == 1 ]] ||
  fail 'the login must read granted tables'
expect_login_error "$first" session_fixture 'SET transaction_read_only = off; INSERT INTO read_api.present VALUES (9)'
rg -q 'permission denied' "$scratch/expect.err" || fail 'direct writes must be denied by grants'
expect_login_error "$first" session_fixture "SET ROLE \"$cap\""
expect_login_error "$first" session_fixture 'CREATE TEMP TABLE scratch_table (id integer)'
expect_login_error "$first" automation_data_control 'SELECT 1'
[[ "$(query "SELECT platform_operations.validate_access_capability('session_fixture','read')->>'membersValid'")" == true ]] ||
  fail 'an issued login must be an accepted member'

# Revocation ends existing sessions, refuses new ones, and drops the role.
as_login "$first" session_fixture 'SELECT pg_sleep(30)' >/dev/null 2>&1 &
sleeper=$!
wait_for_session "$first"
as_role "$issuer" "SELECT platform_operations.revoke_session_login('$first')" >/dev/null
if wait "$sleeper"; then fail 'revocation must terminate an open session'; fi
expect_login_error "$first" session_fixture 'SELECT 1'
[[ "$(role_exists "$first")" == 0 ]] || fail 'revocation must drop the role'
[[ "$(revoked_by "$first")" == openbao ]] || fail 'OpenBao revocation must be recorded'
as_role "$issuer" "SELECT platform_operations.revoke_session_login('$first')" >/dev/null

# Large objects owned by the login do not block revocation.
owner="$(login_name)"
issue "$owner" 600 >/dev/null
as_login "$owner" session_fixture 'SET transaction_read_only = off; SELECT lo_create(0)' >/dev/null
as_role "$issuer" "SELECT platform_operations.revoke_session_login('$owner')" >/dev/null
[[ "$(role_exists "$owner")" == 0 ]] || fail 'a large-object owner must still be revoked'

# Revocation never drops an unregistered role and checks the recorded identity.
stray="$(login_name)"
query "CREATE ROLE \"$stray\" NOLOGIN" >/dev/null
expect_error unregistered_session_login automation_data_control \
  "SET ROLE $issuer; SELECT platform_operations.revoke_session_login('$stray')"
[[ "$(role_exists "$stray")" == 1 ]] || fail 'an unregistered role must remain'
as_role "$issuer" "SELECT platform_operations.revoke_session_login('$(login_name)')" >/dev/null
moved="$(login_name)"
issue "$moved" 600 >/dev/null
query "UPDATE platform_operations.managed_dynamic_logins SET role_oid = 1 WHERE role_name = '$moved'" >/dev/null
expect_error session_login_identity_mismatch automation_data_control \
  "SET ROLE $issuer; SELECT platform_operations.revoke_session_login('$moved')"
query "UPDATE platform_operations.managed_dynamic_logins SET role_oid =
  (SELECT oid FROM pg_roles WHERE rolname = '$moved') WHERE role_name = '$moved'" >/dev/null
as_role "$issuer" "SELECT platform_operations.revoke_session_login('$moved')" >/dev/null

# Expiry rejects new connections; the sweeper ends sessions that outlive it.
short="$(login_name)"
issue "$short" 3 >/dev/null
as_login "$short" session_fixture 'SELECT pg_sleep(30)' >/dev/null 2>&1 &
sleeper=$!
wait_for_session "$short"
sleep 4
expect_login_error "$short" session_fixture 'SELECT 1'
[[ "$(sessions_of "$short")" -ge 1 ]] || fail 'expiry alone must not be assumed to end sessions'
as_role "$sweeper" 'SELECT platform_operations.sweep_session_logins()' >/dev/null
if wait "$sleeper"; then fail 'the sweeper must terminate an expired session'; fi
[[ "$(revoked_by "$short")" == sweeper ]] || fail 'sweeper revocation must be recorded'

# A stale heartbeat stops issuance; suspension blocks issuance and the operator
# kill switch revokes active logins.
query "UPDATE platform_operations.access_session_sweeps SET completed_at = clock_timestamp() - interval '16 minutes'" >/dev/null
expect_issue_error reconciliation_unhealthy "$(login_name)" 600
as_role "$sweeper" 'SELECT platform_operations.sweep_session_logins()' >/dev/null
active="$(login_name)"
issue "$active" 600 >/dev/null
query "SELECT platform_operations.suspend_access_capability('session_fixture','read')" >/dev/null
expect_issue_error capability_suspended "$(login_name)" 600
[[ "$(query "SELECT platform_operations.revoke_access_capability_logins('session_fixture','read')->>'revoked'")" == 1 ]] ||
  fail 'the kill switch must revoke the active login'
[[ "$(revoked_by "$active")" == operator ]] || fail 'operator revocation must be recorded'
query "SELECT platform_operations.resume_access_capability('session_fixture','read')" >/dev/null
resumed="$(login_name)"
issue "$resumed" 600 >/dev/null
as_role "$issuer" "SELECT platform_operations.revoke_session_login('$resumed')" >/dev/null

# Each fixed identity can call only its own functions.
expect_error 'permission denied' automation_data_control \
  "SET ROLE $issuer; SELECT platform_operations.sweep_session_logins()"
expect_error 'permission denied' automation_data_control \
  "SET ROLE $issuer; SELECT count(*) FROM platform_operations.managed_dynamic_logins"
expect_error 'permission denied' automation_data_control \
  "SET ROLE $sweeper; SELECT platform_operations.revoke_session_login('$resumed')"
expect_error 'permission denied' automation_data_control \
  "SET ROLE $issuer; SELECT platform_operations.suspend_access_capability('session_fixture','read')"
query "SELECT platform_internal.assert_access_session_contract()" >/dev/null

# The guarded enable step gives the sweeper a password login from its Secret value.
# enable_sweeper ENV_FILE runs the packaged wrapper as the backup identity.
enable_sweeper() {
  podman exec --env-file "$1" "$container" sh -c 'SWEEPER_PASSWORD="$LOGIN_PASSWORD" \
    PGUSER=automation_data_backup PGDATABASE=automation_data_control \
    exec sh /scripts/enable-session-sweeper.sh'
}
# run_sweep ENV_FILE runs the CronJob script over TCP as the sweeper.
run_sweep() {
  podman exec --env-file "$1" "$container" sh -c 'PGPASSWORD="$LOGIN_PASSWORD" \
    PGHOST=127.0.0.1 PGUSER=automation_data_session_sweeper \
    PGDATABASE=automation_data_control exec sh /scripts/sweep-session-logins.sh'
}
new_password_file() {
  printf 'LOGIN_PASSWORD=%s\n' "$(openssl rand -hex "$2")" >"$scratch/$1"
  chmod 600 "$scratch/$1"
}
new_password_file short-sweeper.env 8
[[ "$(enable_sweeper "$scratch/short-sweeper.env" 2>&1)" == 'session_sweeper_login=failed' ]] ||
  fail 'enabling must refuse a short password with only a fixed marker'
new_password_file "$sweeper.env" 32
query "COMMENT ON ROLE $sweeper IS 'unrelated'" >/dev/null
[[ "$(enable_sweeper "$scratch/$sweeper.env" 2>&1)" == 'session_sweeper_login=failed' ]] ||
  fail 'enabling must refuse a sweeper role without the installation marker'
[[ "$(query "SELECT rolcanlogin FROM pg_roles WHERE rolname = '$sweeper'")" == f ]] ||
  fail 'a refused enable must leave the sweeper unable to log in'
query "COMMENT ON ROLE $sweeper IS 'homelab:access-sessions:v1'" >/dev/null
query "ALTER ROLE $sweeper BYPASSRLS" >/dev/null
[[ "$(enable_sweeper "$scratch/$sweeper.env" 2>&1)" == 'session_sweeper_login=failed' ]] ||
  fail 'enabling must refuse a sweeper role that drifted from the installed contract'
query "ALTER ROLE $sweeper NOBYPASSRLS" >/dev/null
[[ "$(enable_sweeper "$scratch/$sweeper.env" 2>&1)" == 'session_sweeper_login=enabled' ]] ||
  fail 'enabling must report only the fixed success marker'
[[ "$(as_login "$sweeper" automation_data_control 'SELECT session_user')" == "$sweeper" ]] ||
  fail 'the enabled sweeper must authenticate with its password'
expect_login_error "$sweeper" automation_data_control \
  'SELECT count(*) FROM platform_operations.managed_dynamic_logins'
expect_login_error "$sweeper" session_fixture 'SELECT 1'

# Exporter metrics count temporary logins from the catalog without new grants.
exporter_config=kubernetes/apps/automation-data/postgresql/app/sql-exporter.yml
metric() {
  local sql
  sql="$(NAME="$1" yq -r '.collectors[].metrics[] | select(.metric_name == strenv(NAME)) | .query' \
    "$exporter_config")"
  [[ -n "$sql" ]] || fail "SQL Exporter does not define $1"
  query "SET ROLE automation_data_exporter; $sql" | tail -1
}
metered="$(login_name)"
issue "$metered" 600 >/dev/null
[[ "$(metric automation_data_postgresql_session_logins_active)" == 1 &&
  "$(metric automation_data_postgresql_session_logins_overdue)" == 0 ]] ||
  fail "metrics must count one active and no overdue temporary login, got $(metric automation_data_postgresql_session_logins_active)/$(metric automation_data_postgresql_session_logins_overdue)"
expiring="$(login_name)"
issue "$expiring" 3 >/dev/null
sleep 4
[[ "$(metric automation_data_postgresql_session_logins_active)" == 1 &&
  "$(metric automation_data_postgresql_session_logins_overdue)" == 1 ]] ||
  fail 'metrics must count an expired, unrevoked login as overdue'

# The CronJob script sweeps as the sweeper login and prints only counts.
[[ "$(run_sweep "$scratch/$sweeper.env" 2>&1)" == 'session_sweep revoked=1 failed=0' ]] ||
  fail 'the sweep script must report the revoked overdue login'
[[ "$(metric automation_data_postgresql_session_logins_overdue)" == 0 ]] ||
  fail 'the sweep must clear the overdue login'
new_password_file wrong-sweeper.env 32
if run_sweep "$scratch/wrong-sweeper.env" >"$scratch/sweep.out" 2>&1; then
  fail 'the sweep script must fail when it cannot authenticate'
fi
[[ "$(cat "$scratch/sweep.out")" == 'session_sweep=failed' ]] ||
  fail 'a failed sweep must print only the fixed failure marker'

# Reapplying with a new Secret value rotates the password.
cp "$scratch/$sweeper.env" "$scratch/previous-sweeper.env"
new_password_file "$sweeper.env" 32
[[ "$(enable_sweeper "$scratch/$sweeper.env" 2>&1)" == 'session_sweeper_login=enabled' ]] ||
  fail 'enabling again must rotate the password'
[[ "$(run_sweep "$scratch/$sweeper.env" 2>&1)" == 'session_sweep revoked=0 failed=0' ]] ||
  fail 'the sweeper must authenticate with the rotated password'
if run_sweep "$scratch/previous-sweeper.env" >/dev/null 2>&1; then
  fail 'the previous sweeper password must stop working'
fi
podman logs "$container" >"$scratch/server.log" 2>&1
for password_file in previous-sweeper.env "$sweeper.env" short-sweeper.env; do
  if rg -qF -- "$(cut -d= -f2 "$scratch/$password_file")" "$scratch/server.log"; then
    fail 'a sweeper password reached the server log'
  fi
done
as_role "$issuer" "SELECT platform_operations.revoke_session_login('$metered')" >/dev/null

# A restore recreates temporary logins with new OIDs, so normal revocation refuses
# them. The restore cleanup rebinds only logins with the issued shape and revokes them.
query "DROP ROLE \"$stray\"" >/dev/null
restore_cleanup() {
  podman exec "$container" sh -c 'PGUSER=automation_data_backup \
    PGDATABASE=automation_data_control exec sh /scripts/restore-session-logins.sh'
}
# recreate NAME [ATTRIBUTE] imitates a restored role: same name, new OID.
recreate() {
  query "DROP ROLE \"$1\"; CREATE ROLE \"$1\" LOGIN ${2:-} VALID UNTIL 'infinity';
    GRANT \"$cap\" TO \"$1\" WITH INHERIT TRUE, SET FALSE, ADMIN FALSE" >/dev/null
}
restored="$(login_name)"
odd="$(login_name)"
issue "$restored" 600 >/dev/null
issue "$odd" 600 >/dev/null
recreate "$restored"
recreate "$odd" CREATEDB
expect_error session_login_identity_mismatch automation_data_control \
  "SET ROLE $issuer; SELECT platform_operations.revoke_session_login('$restored')"
if restore_cleanup >"$scratch/restore.out" 2>&1; then
  fail 'restore cleanup must fail while a login cannot be revoked'
fi
[[ "$(cat "$scratch/restore.out")" == 'session_restore_cleanup revoked=1 failed=1 remaining=1' ]] ||
  fail "restore cleanup must revoke the restored login and report the other: $(cat "$scratch/restore.out")"
[[ "$(revoked_by "$restored")" == restore && "$(role_exists "$restored")" == 0 ]] ||
  fail 'the restored login must be revoked by restore'
[[ "$(role_exists "$odd")" == 1 ]] || fail 'a role without the issued shape must not be dropped'
query "ALTER ROLE \"$odd\" NOCREATEDB" >/dev/null
[[ "$(restore_cleanup 2>&1)" == 'session_restore_cleanup revoked=1 failed=0 remaining=0' ]] ||
  fail 'restore cleanup must finish once every login has the issued shape'

# The registration wrapper runs as the provisioner, takes values only from the
# environment, and prints the validated capability or a known error code.
register_capability() {
  podman exec --env CAPABILITY_DOMAIN="$1" --env CAPABILITY_NAME="$2" \
    --env CAPABILITY_SCHEMAS="$3" --env CAPABILITY_MAX_TTL="$4" \
    --env PGUSER=automation_data_provisioner --env PGDATABASE=automation_data_control \
    "$container" sh /scripts/register-access-capability.sh
}
audit_cap="cap_$(printf 'session_fixture:audit' | md5sum | cut -d' ' -f1)_access"
register_capability session_fixture audit read_api 300 >"$scratch/register.out" ||
  fail "registration failed: $(cat "$scratch/register.out")"
jq -e --arg role "$audit_cap" '.role == $role and .state == "ready" and
  .maxTtlSeconds == 300 and .schemas == ["read_api"] and .valid == false' \
  "$scratch/register.out" >/dev/null || fail 'registration must report the new, not yet valid capability'
dbquery session_fixture "
  GRANT CONNECT ON DATABASE session_fixture TO \"$audit_cap\";
  GRANT USAGE ON SCHEMA read_api TO \"$audit_cap\";
  GRANT SELECT ON read_api.present TO \"$audit_cap\";" >/dev/null
register_capability session_fixture audit read_api 300 >"$scratch/register.out" ||
  fail 'repeated registration must succeed'
jq -e '.valid == true and .objectPrivilegesValid == true' "$scratch/register.out" >/dev/null ||
  fail 'repeated registration must report validity after the reviewed grants'
for case in 'invalid_access_capability_ttl|audit|read_api|900' \
    'access_capability_binding_conflict|audit|read_api,other_api|300' \
    "invalid_access_capability_schemas|other|read_api');--|300"; do
  IFS='|' read -r code name schemas ttl <<<"$case"
  if register_capability session_fixture "$name" "$schemas" "$ttl" >"$scratch/register.out" 2>&1; then
    fail "registration must refuse with $code"
  fi
  [[ "$(cat "$scratch/register.out")" == "access_capability_registration=failed reason=$code" ]] ||
    fail "registration must report only $code, got: $(cat "$scratch/register.out")"
done

# Reinstallation leaves roles, settings, memberships, and registries unchanged.
state_digest() {
  query "SELECT md5(concat_ws('|',
    (SELECT string_agg(concat_ws(':', rolname, rolcanlogin, rolinherit, rolconnlimit,
      rolvaliduntil, rolpassword IS NULL), ',' ORDER BY rolname) FROM pg_authid),
    (SELECT string_agg(concat_ws(':', setrole, setdatabase, setconfig::text), ','
      ORDER BY setrole, setdatabase) FROM pg_db_role_setting),
    (SELECT string_agg(concat_ws(':', roleid, member, inherit_option, set_option), ','
      ORDER BY roleid, member) FROM pg_auth_members),
    (SELECT string_agg(to_jsonb(c)::text, ',' ORDER BY domain, capability)
      FROM platform_operations.managed_access_capabilities AS c),
    (SELECT string_agg(to_jsonb(l)::text, ',' ORDER BY role_name)
      FROM platform_operations.managed_dynamic_logins AS l)))"
}
before="$(state_digest)"
install_sessions
[[ "$(state_digest)" == "$before" ]] || fail 'reinstallation must not change installed state'

echo 'automation-data sessions SQL test passed'
