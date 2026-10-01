#!/bin/sh
# Fixed run-owned installer Job entrypoint; raw SQL errors stay in its memory volume.
set -eu
set +x
umask 077
trap 'rm -f /tmp/discovery-*' EXIT
fail() {
	echo 'discovery_installation=failed' >&2
	exit 1
}
reader_candidate="$(cat /candidates/candidate)"
export reader_candidate
case "$DISCOVERY_SOURCE:$PGDATABASE:$DISCOVERY_READER" in
platform:automation_data_control:automation_data_inventory) denied_table=platform_operations.managed_domains ;;
nocodb:nocodb:nocodb_inventory) denied_table=public.nc_integrations_v2 ;;
n8n:n8n:n8n_inventory) denied_table=public.credentials_entity ;;
*) fail ;;
esac
# The schema/role preconditions and all grants run in the shared SQL transaction.
# An already active reader must authenticate with the retained candidate before any DDL.
psql -X -v ON_ERROR_STOP=1 -v reader="$DISCOVERY_READER" -At >/tmp/discovery-existing 2>/tmp/discovery-errors <<'SQL' || fail
SELECT COALESCE((SELECT rolcanlogin::text FROM pg_catalog.pg_roles WHERE rolname=:'reader'),'absent');
SQL
existing="$(cat /tmp/discovery-existing)"
if [ "$existing" = true ]; then
	PGPASSWORD="$reader_candidate" PGUSER="$DISCOVERY_READER" psql -X -v ON_ERROR_STOP=1 -At \
		-c 'SELECT current_database(),session_user,current_user;' >/tmp/discovery-auth 2>/tmp/discovery-errors || fail
	[ "$(cat /tmp/discovery-auth)" = "$PGDATABASE|$DISCOVERY_READER|$DISCOVERY_READER" ] || fail
elif [ "$existing" != false ] && [ "$existing" != absent ]; then
	fail
fi
psql -X -v ON_ERROR_STOP=1 -f /scripts/projection.sql >/tmp/discovery-admin 2>/tmp/discovery-errors || fail
if [ "$existing" != true ]; then
	# Do not include candidate values in process arguments or statement/error logs.
	psql -X -v ON_ERROR_STOP=1 -v reader="$DISCOVERY_READER" >/tmp/discovery-admin 2>/tmp/discovery-errors <<'SQL' || fail
SET log_statement='none';
SET log_min_error_statement='panic';
\getenv candidate reader_candidate
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'reader', :'candidate') \gexec
SQL
fi
PGPASSWORD="$reader_candidate" PGUSER="$DISCOVERY_READER" psql -X -v ON_ERROR_STOP=1 -At \
	-c "SELECT platform_discovery.read_snapshot()->>'complete';" >/tmp/discovery-reader 2>/tmp/discovery-errors || fail
[ "$(cat /tmp/discovery-reader)" = true ] || fail
# Independently reject a server that admits this login without checking its password.
if PGPASSWORD=synthetic-invalid-authentication-probe PGUSER="$DISCOVERY_READER" psql -X -v ON_ERROR_STOP=1 \
	-c 'SELECT current_user;' >/tmp/discovery-auth-denial 2>/tmp/discovery-errors; then fail; fi
# Runtime acceptance reads privilege metadata only. Real forbidden-query denials are
# exercised against synthetic records in the disposable SQL suite.
PGPASSWORD="$reader_candidate" PGUSER="$DISCOVERY_READER" psql -X -v ON_ERROR_STOP=1 -At \
	-c "SELECT has_any_column_privilege(session_user,'pg_catalog.pg_authid','SELECT') OR has_table_privilege(session_user,'platform_discovery.objects','SELECT') OR has_any_column_privilege(session_user,'$denied_table','SELECT');" >/tmp/discovery-denial 2>/tmp/discovery-errors || fail
[ "$(cat /tmp/discovery-denial)" = f ] || fail
PGPASSWORD="$reader_candidate" PGUSER="$DISCOVERY_READER" psql -X -v ON_ERROR_STOP=1 -At \
	-c 'SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname=session_user;' >/tmp/discovery-role 2>/tmp/discovery-errors || fail
[ "$(cat /tmp/discovery-role)" = f ] || fail
unset reader_candidate
echo 'discovery_installation=applied'
