#!/bin/sh
set -eu

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
\getenv provisioner_password PROVISIONER_PASSWORD
\getenv backup_password BACKUP_PASSWORD
\getenv exporter_password EXPORTER_PASSWORD

CREATE ROLE automation_data_provisioner
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
  PASSWORD :'provisioner_password';
CREATE ROLE automation_data_backup
  LOGIN SUPERUSER NOINHERIT
  PASSWORD :'backup_password';
CREATE ROLE automation_data_exporter
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
  PASSWORD :'exporter_password';

REVOKE CONNECT ON DATABASE automation_data_control FROM PUBLIC;
GRANT CONNECT ON DATABASE automation_data_control TO
  automation_data_provisioner,
  automation_data_backup,
  automation_data_exporter;
EOSQL

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --file=/scripts/platform-control.sql
