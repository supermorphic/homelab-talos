#!/usr/bin/env bash
# Prove scoped authority through real PostgreSQL sessions in a disposable database.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-scoped-permissions.XXXXXX")"
chmod 700 "$scratch"
marker="automation-data-scoped-permissions-$$-$RANDOM"
container="${marker:0:63}"
stage=init
on_error() {
  echo "Scoped permissions fixture failed during $stage." >&2
  if [[ "$stage" == sessions ]]; then
    echo "Failed command: $BASH_COMMAND" >&2
  fi
  if [[ "$stage" == init ]]; then
    podman logs "$container" 2>&1 | tail -n 20 >&2 || true
  fi
}
trap on_error ERR
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
  if podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
      --tuples-only --no-align --username postgres --dbname automation_data_control \
      --command='SELECT platform_operations.read_platform_revision()' 2>/dev/null \
      | rg -qx '026-nocodb-v3'; then break; fi
  sleep 1
done
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --tuples-only --no-align --username postgres --dbname automation_data_control \
  --command='SELECT platform_operations.read_platform_revision()' | rg -qx '026-nocodb-v3'
stage=setup

cat >"$scratch/setup.sql" <<'SQL'
\getenv migrator_password FIXTURE_MIGRATOR_PASSWORD
\getenv runtime_password FIXTURE_RUNTIME_PASSWORD
SELECT platform_operations.provision_domain('scoped_fixture', :'migrator_password', :'runtime_password');
SELECT platform_operations.record_domain_credentials(
  'scoped_fixture', 'fixture-migrator-id', 'fixture-runtime-id',
  '2026-09-01T00:00:00Z'::timestamptz, '2026-09-01T00:00:00Z'::timestamptz
);
SELECT platform_operations.configure_nocodb_pair(
  'scoped_fixture', 'extra', 'extra_read', 'extra_edit'
);
SELECT platform_operations.configure_nocodb_pair(
  'scoped_fixture', 'sibling', 'sibling_read', NULL
);
INSERT INTO platform_operations.managed_application_logins
  (domain, application, schema_name, role_name, state)
VALUES (
  'scoped_fixture', 'interview', 'extra_read',
  'app_' || md5('scoped_fixture:interview') || '_integration', 'awaiting_grants'
);
CREATE ROLE app_9e942634ee3972203506a80f29a68ca5_integration
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
SQL
# Compute the literal app role separately from the server to detect role-name drift.
app_role="app_$(printf 'scoped_fixture:interview' | md5sum | cut -d' ' -f1)_integration"
sed -i.bak "s/app_9e942634ee3972203506a80f29a68ca5_integration/$app_role/" "$scratch/setup.sql"
rm -f "$scratch/setup.sql.bak"
podman cp "$scratch/setup.sql" "$container:/tmp/scoped-setup.sql"
podman exec --env-file "$scratch/postgresql.env" "$container" psql --no-psqlrc \
  --set=ON_ERROR_STOP=1 --tuples-only --no-align --username postgres \
  --dbname automation_data_control --file /tmp/scoped-setup.sql >"$scratch/setup.out"
stage=grants

reader_role="nocodb_$(printf 'scoped_fixture:extra' | md5sum | cut -d' ' -f1)_reader"
operator_role="nocodb_$(printf 'scoped_fixture:extra' | md5sum | cut -d' ' -f1)_operator"
sibling_role="nocodb_$(printf 'scoped_fixture:sibling' | md5sum | cut -d' ' -f1)_reader"
cat >"$scratch/grants.sql" <<SQL
CREATE SCHEMA extra_read AUTHORIZATION scoped_fixture_owner;
CREATE SCHEMA extra_edit AUTHORIZATION scoped_fixture_owner;
CREATE SCHEMA sibling_read AUTHORIZATION scoped_fixture_owner;
REVOKE ALL ON SCHEMA extra_read, extra_edit, sibling_read FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE scoped_fixture_owner
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
SET ROLE scoped_fixture_owner;
CREATE TABLE extra_read.present (id integer PRIMARY KEY, value text NOT NULL);
CREATE TABLE extra_read.bookkeeping (id integer PRIMARY KEY, value text NOT NULL);
CREATE SEQUENCE extra_read.private_sequence;
CREATE TABLE extra_edit.decision (id integer PRIMARY KEY, status text NOT NULL, internal text NOT NULL);
CREATE TABLE extra_edit.private_note (id integer PRIMARY KEY, value text NOT NULL);
CREATE TABLE sibling_read.present (id integer PRIMARY KEY, value text NOT NULL);
INSERT INTO extra_read.present VALUES (1, 'synthetic');
INSERT INTO extra_read.bookkeeping VALUES (1, 'withheld');
INSERT INTO extra_edit.decision VALUES (1, 'open', 'withheld');
INSERT INTO extra_edit.private_note VALUES (1, 'withheld');
INSERT INTO sibling_read.present VALUES (1, 'sibling');
CREATE FUNCTION extra_read.read_record() RETURNS integer
  LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
  AS 'SELECT 1';
CREATE FUNCTION extra_read.privileged_reset() RETURNS integer
  LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
  AS 'SELECT 2';
RESET ROLE;
GRANT CONNECT ON DATABASE scoped_fixture TO "$reader_role", "$operator_role", "$app_role", "$sibling_role";
GRANT USAGE ON SCHEMA extra_read TO "$reader_role", "$app_role";
GRANT USAGE ON SCHEMA extra_edit TO "$operator_role";
GRANT USAGE ON SCHEMA sibling_read TO "$sibling_role";
GRANT SELECT ON extra_read.present TO "$reader_role", "$app_role";
GRANT SELECT ON extra_edit.decision TO "$operator_role";
GRANT UPDATE (status) ON extra_edit.decision TO "$operator_role";
GRANT SELECT ON sibling_read.present TO "$sibling_role";
GRANT EXECUTE ON FUNCTION extra_read.read_record() TO "$app_role";
SQL
podman cp "$scratch/grants.sql" "$container:/tmp/scoped-grants.sql"
podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --username postgres --dbname scoped_fixture --file /tmp/scoped-grants.sql >"$scratch/grants.out"
stage=sessions

run_as() { # <role> <SQL>
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --set=VERBOSITY=verbose --tuples-only --no-align --username postgres \
    --dbname scoped_fixture \
    --command="SET SESSION AUTHORIZATION \"$1\"; $2"
}
assert_denied() { # <role> <SQL>
  if run_as "$1" "$2" >"$scratch/session.out" 2>"$scratch/session.err"; then
    echo "Unexpected allowed SQL operation for $1." >&2
    return 1
  fi
  rg -q '42501' "$scratch/session.err" || {
    echo "Expected PostgreSQL permission denial for $1." >&2
    return 1
  }
}

# Reader subset and withheld objects in its selected schema.
run_as "$reader_role" 'SELECT value FROM extra_read.present WHERE id = 1' \
  >"$scratch/reader.out"
rg -qx 'synthetic' "$scratch/reader.out"
assert_denied "$reader_role" 'SELECT value FROM extra_read.bookkeeping WHERE id = 1'
assert_denied "$reader_role" 'SELECT extra_read.privileged_reset()'
assert_denied "$reader_role" 'SELECT value FROM extra_edit.decision WHERE id = 1'
assert_denied "$reader_role" 'SELECT value FROM sibling_read.present WHERE id = 1'
assert_denied "$reader_role" 'CREATE TEMP TABLE unwanted (id integer)'

# Operator can change only a declared column. The same schema keeps a withheld column.
run_as "$operator_role" "UPDATE extra_edit.decision SET status = 'closed' WHERE id = 1" \
  >"$scratch/operator.out"
assert_denied "$operator_role" "UPDATE extra_edit.decision SET internal = 'changed' WHERE id = 1"
assert_denied "$operator_role" 'SELECT value FROM extra_read.present WHERE id = 1'
assert_denied "$operator_role" 'SELECT value FROM extra_edit.private_note WHERE id = 1'
run_as "$sibling_role" 'SELECT value FROM sibling_read.present WHERE id = 1' \
  | rg -qx 'sibling'

# Application integration sees one read and one explicitly granted routine.
run_as "$app_role" 'SELECT extra_read.read_record()' >"$scratch/application.out"
rg -qx '1' "$scratch/application.out"
assert_denied "$app_role" "UPDATE extra_read.present SET value = 'changed' WHERE id = 1"
assert_denied "$app_role" 'SELECT extra_read.privileged_reset()'
assert_denied "$app_role" 'CREATE TEMP TABLE unwanted (id integer)'
assert_denied "$app_role" 'SET ROLE scoped_fixture_owner'
assert_denied "$app_role" 'CREATE TABLE extra_read.unwanted (id integer)'

reader_authority="$(podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --tuples-only --no-align --username postgres --dbname automation_data_control \
  --command="SELECT platform_internal.validate_nocodb_access_authority(
    'scoped_fixture', 'extra', 'reader', '$reader_role', false)->>'valid'")"
[[ "$reader_authority" == true ]] || {
  echo 'Named reader authority rejected a permitted subset.' >&2
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --username postgres --dbname automation_data_control \
    --command="SELECT platform_internal.validate_nocodb_access_authority(
      'scoped_fixture', 'extra', 'reader', '$reader_role', false)" >&2
  exit 1
}
operator_authority="$(podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --tuples-only --no-align --username postgres --dbname automation_data_control \
  --command="SELECT platform_internal.validate_nocodb_access_authority(
    'scoped_fixture', 'extra', 'operator', '$operator_role', false)->>'valid'")"
[[ "$operator_authority" == true ]] || {
  echo 'Named operator authority rejected a controlled column update.' >&2
  exit 1
}
app_authority="$(podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
  --tuples-only --no-align --username postgres --dbname automation_data_control \
  --command="SELECT platform_operations.validate_application_login(
    'scoped_fixture', 'interview')->>'valid'")"
[[ "$app_authority" == true ]] || {
  echo 'Application authority rejected the declared read/function boundary.' >&2
  exit 1
}

admin_sql() {
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --username postgres --dbname scoped_fixture \
    --command="$1" >/dev/null
}
control_value() {
  podman exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --username postgres --dbname automation_data_control \
    --command="$1"
}
assert_invalid() {
  local actual
  actual="$(control_value "$1")"
  [[ "$actual" == false ]] || {
    echo "Effective authority accepted forbidden $2." >&2
    exit 1
  }
}
reader_check="SELECT platform_internal.validate_nocodb_access_authority(
  'scoped_fixture', 'extra', 'reader', '$reader_role', false)->>'valid'"
app_check="SELECT platform_operations.validate_application_login(
  'scoped_fixture', 'interview')->>'valid'"

# PUBLIC SELECT is usable by both logins even without a direct role grant.
admin_sql 'GRANT SELECT ON extra_read.bookkeeping TO PUBLIC'
run_as "$reader_role" 'SELECT value FROM extra_read.bookkeeping WHERE id = 1' \
  | rg -qx 'withheld'
assert_invalid "$reader_check" 'PUBLIC table SELECT for the reader'
assert_invalid "$app_check" 'PUBLIC table SELECT for the application'
admin_sql 'REVOKE SELECT ON extra_read.bookkeeping FROM PUBLIC'

# Function EXECUTE defaults to PUBLIC unless the owner explicitly revokes it.
admin_sql 'GRANT EXECUTE ON FUNCTION extra_read.privileged_reset() TO PUBLIC'
run_as "$reader_role" 'SELECT extra_read.privileged_reset()' | rg -qx '2'
assert_invalid "$reader_check" 'PUBLIC routine EXECUTE for the reader'
assert_invalid "$app_check" 'PUBLIC routine EXECUTE for the application'
admin_sql 'REVOKE EXECUTE ON FUNCTION extra_read.privileged_reset() FROM PUBLIC'

admin_sql "GRANT EXECUTE ON FUNCTION extra_read.privileged_reset() TO \"$reader_role\""
run_as "$reader_role" 'SELECT extra_read.privileged_reset()' | rg -qx '2'
assert_invalid "$reader_check" 'direct routine EXECUTE for the reader'
admin_sql "REVOKE EXECUTE ON FUNCTION extra_read.privileged_reset() FROM \"$reader_role\""

admin_sql "GRANT SELECT ON extra_read.present TO \"$reader_role\" WITH GRANT OPTION"
assert_invalid "$reader_check" 'table grant option for the reader'
admin_sql "REVOKE GRANT OPTION FOR SELECT ON extra_read.present FROM \"$reader_role\""

admin_sql "GRANT TEMP ON DATABASE scoped_fixture TO \"$app_role\""
assert_invalid "$app_check" 'database TEMP for the application'
admin_sql "REVOKE TEMP ON DATABASE scoped_fixture FROM \"$app_role\""
admin_sql "GRANT CREATE ON DATABASE scoped_fixture TO \"$reader_role\""
assert_invalid "$reader_check" 'database CREATE for the reader'
admin_sql "REVOKE CREATE ON DATABASE scoped_fixture FROM \"$reader_role\""
admin_sql "GRANT CONNECT ON DATABASE postgres TO \"$app_role\""
assert_invalid "$app_check" 'cross-database CONNECT for the application'
admin_sql "REVOKE CONNECT ON DATABASE postgres FROM \"$app_role\""
admin_sql "GRANT CONNECT ON DATABASE scoped_fixture TO \"$app_role\" WITH GRANT OPTION"
assert_invalid "$app_check" 'database CONNECT grant option for the application'
admin_sql "REVOKE GRANT OPTION FOR CONNECT ON DATABASE scoped_fixture FROM \"$app_role\""

admin_sql "GRANT UPDATE (value) ON extra_read.present TO \"$app_role\""
run_as "$app_role" "UPDATE extra_read.present SET value = 'modified' WHERE id = 1" >/dev/null
assert_invalid "$app_check" 'column UPDATE for the application'
admin_sql "REVOKE UPDATE (value) ON extra_read.present FROM \"$app_role\""
admin_sql "GRANT USAGE ON SEQUENCE extra_read.private_sequence TO \"$app_role\""
assert_invalid "$app_check" 'sequence USAGE for the application'
admin_sql "REVOKE USAGE ON SEQUENCE extra_read.private_sequence FROM \"$app_role\""

admin_sql "GRANT scoped_fixture_owner TO \"$app_role\""
run_as "$app_role" 'SET ROLE scoped_fixture_owner' >/dev/null
assert_invalid "$app_check" 'role membership for the application'
admin_sql "REVOKE scoped_fixture_owner FROM \"$app_role\""

admin_sql "ALTER FUNCTION extra_read.read_record() OWNER TO \"$app_role\""
assert_invalid "$app_check" 'function ownership for the application'
admin_sql 'ALTER FUNCTION extra_read.read_record() OWNER TO scoped_fixture_owner'
admin_sql "GRANT EXECUTE ON FUNCTION extra_read.read_record() TO \"$app_role\""

admin_sql "ALTER DEFAULT PRIVILEGES FOR ROLE scoped_fixture_owner IN SCHEMA extra_read
  GRANT SELECT ON TABLES TO \"$app_role\""
assert_invalid "$app_check" 'future table SELECT for the application'
admin_sql "ALTER DEFAULT PRIVILEGES FOR ROLE scoped_fixture_owner IN SCHEMA extra_read
  REVOKE SELECT ON TABLES FROM \"$app_role\""

[[ "$(control_value "$reader_check")" == true ]]
[[ "$(control_value "$app_check")" == true ]] || {
  control_value "SELECT platform_operations.validate_application_login(
    'scoped_fixture', 'interview')" >&2
  exit 1
}
echo 'Automation-data scoped PostgreSQL permissions passed.'
