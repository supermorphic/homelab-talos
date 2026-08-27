#!/bin/sh
set -eu

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
\getenv n8n_password N8N_PASSWORD
\getenv backup_password BACKUP_PASSWORD
\getenv exporter_password EXPORTER_PASSWORD
CREATE ROLE n8n LOGIN PASSWORD :'n8n_password';
CREATE ROLE n8n_backup LOGIN PASSWORD :'backup_password';
CREATE ROLE n8n_exporter LOGIN PASSWORD :'exporter_password';
GRANT pg_read_all_data TO n8n_backup;
GRANT pg_monitor TO n8n_exporter;
CREATE DATABASE n8n OWNER n8n;
REVOKE CONNECT ON DATABASE n8n FROM PUBLIC;
GRANT CONNECT ON DATABASE n8n TO n8n, n8n_backup, n8n_exporter;
EOSQL

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname n8n <<'EOSQL'
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA platform_operations AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA platform_operations FROM PUBLIC;

CREATE TABLE platform_operations.logical_backup_status (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  completed_at timestamp with time zone NOT NULL,
  filename text NOT NULL CHECK (filename <> ''),
  checksum character(64) NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$')
);
REVOKE ALL ON platform_operations.logical_backup_status FROM PUBLIC;
GRANT USAGE ON SCHEMA platform_operations TO n8n_backup, n8n_exporter;
GRANT SELECT, INSERT, UPDATE ON platform_operations.logical_backup_status TO n8n_backup;
GRANT SELECT ON platform_operations.logical_backup_status TO n8n_exporter;
EOSQL
