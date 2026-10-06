#!/bin/sh
# Bootstrap only on a new database volume or an attended isolated recovery target.
set -eu

: "${POSTGRES_USER:=postgres}" "${POSTGRES_DB:=postgres}"
: "${FRESHRSS_PASSWORD:?required}" "${BACKUP_PASSWORD:?required}" "${MONITORING_PASSWORD:?required}"

if ! psql -X --quiet --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
	>/dev/null 2>&1 <<'EOSQL'; then
-- Never put password-bearing generated statements into server error logs.
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
\getenv freshrss_password FRESHRSS_PASSWORD
\getenv backup_password BACKUP_PASSWORD
\getenv monitoring_password MONITORING_PASSWORD
SELECT format('CREATE ROLE %I', name)
FROM (VALUES ('freshrss'), ('news_backup'), ('news_monitoring')) AS roles(name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = name) \gexec
SELECT format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', name, password)
FROM (VALUES ('freshrss', :'freshrss_password'),
             ('news_backup', :'backup_password'),
             ('news_monitoring', :'monitoring_password')) AS roles(name, password) \gexec
GRANT pg_read_all_data TO news_backup;
GRANT pg_monitor TO news_monitoring;
SELECT 'CREATE DATABASE freshrss OWNER freshrss'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'freshrss') \gexec
ALTER DATABASE freshrss OWNER TO freshrss;
REVOKE ALL ON DATABASE freshrss FROM PUBLIC;
GRANT CONNECT ON DATABASE freshrss TO freshrss, news_backup, news_monitoring;
REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC;
EOSQL
	echo 'News database role bootstrap failed; credentials withheld.' >&2
	exit 1
fi

if ! psql -X --quiet --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname freshrss \
	>/dev/null 2>&1 <<'EOSQL'; then
ALTER SCHEMA public OWNER TO freshrss;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO freshrss;
EOSQL
	echo 'News database schema bootstrap failed.' >&2
	exit 1
fi
