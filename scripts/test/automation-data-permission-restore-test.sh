#!/usr/bin/env bash
set -euo pipefail

fail() {
	echo "automation-data permission restore test failed: $*" >&2
	exit 1
}

helper_library='scripts/test/lib/automation-data-permission-restore.sh'
[[ -f "$helper_library" ]] || fail 'restore permission comparison helper is missing'
# shellcheck source=scripts/test/lib/automation-data-permission-restore.sh
source "$helper_library"
declare -F automation_data_permission_restore_helpers >/dev/null ||
	fail 'restore permission comparison helper emitter is missing'

test_root="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-permission-restore-test.XXXXXX")"
chmod 700 "$test_root"
run_marker="permission-restore-${test_root##*.}-$$"
container="automation-data-permission-restore-$$"
image='postgres:17.11-alpine3.24'

podman_command() {
	mise exec -- podman "$@"
}

cleanup() {
	local original_exit="$?" cleanup_failed=false owner=''
	trap - EXIT
	set +e
	if podman_command container exists "$container" >/dev/null 2>&1; then
		owner="$(podman_command inspect --format '{{ index .Config.Labels "homelab-talos.test-run" }}' \
			"$container" 2>/dev/null)"
		if [[ "$owner" == "$run_marker" ]]; then
			podman_command rm --force "$container" >/dev/null 2>&1 || cleanup_failed=true
		else
			echo 'automation-data permission restore test refused to remove an unowned container' >&2
			cleanup_failed=true
		fi
	fi
	rm -rf -- "$test_root" || cleanup_failed=true
	set -e
	[[ "$cleanup_failed" == false ]] || exit 1
	exit "$original_exit"
}
trap cleanup EXIT

podman_command container exists "$container" >/dev/null 2>&1 &&
	fail 'disposable PostgreSQL container name already exists'
podman_command run --detach --name "$container" \
	--label "homelab-talos.test-run=$run_marker" \
	--env POSTGRES_HOST_AUTH_METHOD=trust \
	--env POSTGRES_DB=postgres \
	"$image" >"$test_root/container-start.log"
for _attempt in {1..60}; do
	if podman_command exec "$container" pg_isready --username postgres >/dev/null 2>&1; then
		break
	fi
	sleep 1
done
podman_command exec "$container" pg_isready --username postgres >/dev/null 2>&1 ||
	fail 'disposable PostgreSQL container did not become ready'

psql_query() { # <database> <SQL>
	podman_command exec "$container" psql --no-psqlrc --set=ON_ERROR_STOP=1 \
		--tuples-only --no-align --username postgres --dbname "$1" --command "$2"
}

psql_query postgres '
CREATE ROLE permission_owner NOLOGIN;
CREATE ROLE permission_runtime NOLOGIN;
CREATE ROLE alternate_owner NOLOGIN;
' >/dev/null
psql_query postgres 'CREATE DATABASE permission_fixture OWNER permission_owner;' >/dev/null
# shellcheck disable=SC2016 # PostgreSQL function argument, not a shell parameter.
psql_query permission_fixture '
CREATE EXTENSION postgres_fdw;
CREATE SERVER fixture_server FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '\''127.0.0.1'\'', dbname '\''postgres'\'');
GRANT USAGE ON FOREIGN SERVER fixture_server TO permission_owner;
SET ROLE permission_owner;
CREATE SCHEMA app AUTHORIZATION permission_owner;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO permission_runtime;

CREATE TABLE app.records (
  id bigint PRIMARY KEY,
  value text NOT NULL,
  private_value text NOT NULL DEFAULT '\''secret-marker-never-print'\''
);
REVOKE ALL ON TABLE app.records FROM PUBLIC, permission_runtime;
GRANT SELECT ON TABLE app.records TO permission_runtime;
GRANT UPDATE (value) ON TABLE app.records TO permission_runtime;

CREATE VIEW app.visible_records AS SELECT id, value FROM app.records;
REVOKE ALL ON TABLE app.visible_records FROM PUBLIC, permission_runtime;
GRANT SELECT ON TABLE app.visible_records TO permission_runtime;

CREATE MATERIALIZED VIEW app.record_snapshot AS SELECT id, value FROM app.records;
REVOKE ALL ON TABLE app.record_snapshot FROM PUBLIC, permission_runtime;

CREATE FOREIGN TABLE app.remote_records (id bigint, value text)
SERVER fixture_server OPTIONS (schema_name '\''public'\'', table_name '\''remote_records'\'');
REVOKE ALL ON TABLE app.remote_records FROM PUBLIC, permission_runtime;

CREATE SEQUENCE app.ticket_seq;
REVOKE ALL ON SEQUENCE app.ticket_seq FROM PUBLIC, permission_runtime;
GRANT USAGE ON SEQUENCE app.ticket_seq TO permission_runtime;

CREATE FUNCTION app.lookup(bigint) RETURNS text
LANGUAGE sql STABLE
AS '\''SELECT value FROM app.records WHERE id = $1'\'';
REVOKE EXECUTE ON FUNCTION app.lookup(bigint) FROM PUBLIC, permission_runtime;
GRANT EXECUTE ON FUNCTION app.lookup(bigint) TO permission_runtime;

CREATE PROCEDURE app.refresh_records()
LANGUAGE sql AS '\''SELECT NULL::text'\'';
REVOKE EXECUTE ON PROCEDURE app.refresh_records() FROM PUBLIC, permission_runtime;
GRANT EXECUTE ON PROCEDURE app.refresh_records() TO permission_runtime;

CREATE AGGREGATE app.total_bigint(bigint) (
  SFUNC = pg_catalog.int8pl,
  STYPE = bigint,
  INITCOND = '\''0'\''
);

CREATE TABLE app.restricted_records (id bigint PRIMARY KEY);
REVOKE ALL ON TABLE app.restricted_records FROM PUBLIC, permission_runtime;
CREATE SEQUENCE app.restricted_seq;
REVOKE ALL ON SEQUENCE app.restricted_seq FROM PUBLIC, permission_runtime;
CREATE FUNCTION app.restricted_lookup() RETURNS bigint
LANGUAGE sql IMMUTABLE AS '\''SELECT 1::bigint'\'';
REVOKE EXECUTE ON FUNCTION app.restricted_lookup() FROM PUBLIC, permission_runtime;

ALTER DEFAULT PRIVILEGES FOR ROLE permission_owner IN SCHEMA app
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE permission_owner IN SCHEMA app
  GRANT SELECT ON TABLES TO permission_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE permission_owner IN SCHEMA app
  GRANT USAGE ON SEQUENCES TO permission_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE permission_owner IN SCHEMA app
  GRANT EXECUTE ON FUNCTIONS TO permission_runtime;
RESET ROLE;
' >/dev/null

absence_result="$(psql_query permission_fixture "
SELECT
  NOT has_table_privilege('permission_runtime', 'app.restricted_records',
    'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') AND
  NOT has_sequence_privilege('permission_runtime', 'app.restricted_seq',
    'USAGE,SELECT,UPDATE') AND
  NOT has_function_privilege('permission_runtime', 'app.restricted_lookup()', 'EXECUTE');
")"
[[ "$absence_result" == t ]] || fail 'restricted fixture unexpectedly grants runtime access'

podman_command exec "$container" pg_dump --format=custom --compress=0 \
	--username postgres --dbname permission_fixture --file /tmp/original.dump
psql_query postgres 'DROP DATABASE permission_fixture;' >/dev/null
psql_query postgres 'CREATE DATABASE permission_fixture OWNER permission_owner;' >/dev/null
podman_command exec "$container" pg_restore --exit-on-error --username postgres \
	--dbname permission_fixture /tmp/original.dump >/dev/null

automation_data_permission_restore_helpers >"$test_root/helper-runtime.sh"
chmod 600 "$test_root/helper-runtime.sh"
podman_command cp "$test_root/helper-runtime.sh" "$container:/tmp/helper-runtime.sh"

compare_permissions() {
	# shellcheck disable=SC2016 # Positional parameters belong to the container shell.
	podman_command exec --env PGUSER=postgres "$container" /bin/sh -ceu \
		'. /tmp/helper-runtime.sh; automation_data_compare_restored_permissions "$1" "$2"' \
		sh /tmp/original.dump permission_fixture
}

compare_permissions >"$test_root/valid.log" 2>&1 ||
	fail 'unchanged restored permissions and ownership did not match the archive'
[[ ! -s "$test_root/valid.log" ]] || fail 'successful comparison produced output'

assert_mismatch() { # <name> <mutation SQL> <repair SQL>
	local name="$1" mutation="$2" repair="$3"
	psql_query permission_fixture "$mutation" >/dev/null
	if compare_permissions >"$test_root/$name.log" 2>&1; then
		fail "$name mutation was accepted"
	fi
	[[ ! -s "$test_root/$name.log" ]] || fail "$name mismatch exposed archive or SQL content"
	psql_query permission_fixture "$repair" >/dev/null
	compare_permissions >"$test_root/$name-repaired.log" 2>&1 ||
		fail "$name repair did not restore archive equivalence"
}

assert_mismatch table-grant \
	'REVOKE SELECT ON TABLE app.records FROM permission_runtime;' \
	'GRANT SELECT ON TABLE app.records TO permission_runtime;'
assert_mismatch view-grant \
	'REVOKE SELECT ON TABLE app.visible_records FROM permission_runtime;' \
	'GRANT SELECT ON TABLE app.visible_records TO permission_runtime;'
assert_mismatch sequence-grant \
	'REVOKE USAGE ON SEQUENCE app.ticket_seq FROM permission_runtime;' \
	'GRANT USAGE ON SEQUENCE app.ticket_seq TO permission_runtime;'
assert_mismatch default-grant \
	'ALTER DEFAULT PRIVILEGES FOR ROLE permission_owner IN SCHEMA app REVOKE SELECT ON TABLES FROM permission_runtime;' \
	'ALTER DEFAULT PRIVILEGES FOR ROLE permission_owner IN SCHEMA app GRANT SELECT ON TABLES TO permission_runtime;'
assert_mismatch function-execute-grant \
	'REVOKE EXECUTE ON FUNCTION app.lookup(bigint) FROM permission_runtime;' \
	'GRANT EXECUTE ON FUNCTION app.lookup(bigint) TO permission_runtime;'
assert_mismatch table-owner \
	'ALTER TABLE app.records OWNER TO alternate_owner;' \
	'ALTER TABLE app.records OWNER TO permission_owner;'
assert_mismatch procedure-owner \
	'ALTER PROCEDURE app.refresh_records() OWNER TO alternate_owner;' \
	'ALTER PROCEDURE app.refresh_records() OWNER TO permission_owner;'
assert_mismatch aggregate-owner \
	'ALTER AGGREGATE app.total_bigint(bigint) OWNER TO alternate_owner;' \
	'ALTER AGGREGATE app.total_bigint(bigint) OWNER TO permission_owner;'
assert_mismatch foreign-table-owner \
	'ALTER FOREIGN TABLE app.remote_records OWNER TO alternate_owner;' \
	'ALTER FOREIGN TABLE app.remote_records OWNER TO permission_owner;'
assert_mismatch column-grant \
	'REVOKE UPDATE (value) ON TABLE app.records FROM permission_runtime;' \
	'GRANT UPDATE (value) ON TABLE app.records TO permission_runtime;'

# shellcheck disable=SC2016 # Positional parameters belong to the container shell.
if podman_command exec --env PGUSER=postgres "$container" /bin/sh -ceu \
	'. /tmp/helper-runtime.sh; automation_data_compare_restored_permissions "$1" "$2"' \
	sh /tmp/original.dump missing_database >"$test_root/dump-error.log" 2>&1; then
	fail 'candidate pg_dump error was accepted'
fi
[[ ! -s "$test_root/dump-error.log" ]] || fail 'candidate pg_dump error exposed details'

podman_command exec "$container" /bin/sh -ceu \
	"printf '%s\\n' 'secret-marker-never-print invalid archive' >/tmp/invalid.dump"
# shellcheck disable=SC2016 # Positional parameters belong to the container shell.
if podman_command exec --env PGUSER=postgres "$container" /bin/sh -ceu \
	'. /tmp/helper-runtime.sh; automation_data_compare_restored_permissions "$1" "$2"' \
	sh /tmp/invalid.dump permission_fixture >"$test_root/archive-error.log" 2>&1; then
	fail 'invalid source archive was accepted'
fi
[[ ! -s "$test_root/archive-error.log" ]] || fail 'archive inspection error exposed details'

echo 'automation-data restored permission fidelity passed.'
