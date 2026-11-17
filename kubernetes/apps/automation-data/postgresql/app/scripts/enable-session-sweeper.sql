-- Give the specification 036 sweeper its password login from the deployed Secret.
-- Rerunning rotates the password. The caller supplies SWEEPER_PASSWORD.
\set ON_ERROR_STOP on
\getenv sweeper_password SWEEPER_PASSWORD
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
-- The ALTER ROLE text carries the password; keep it out of logs, including errors.
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';

DO $guard$
BEGIN
  IF current_database() <> 'automation_data_control' OR NOT EXISTS (
      SELECT FROM pg_catalog.pg_roles AS role
      WHERE role.rolname = 'automation_data_session_sweeper'
        AND NOT role.rolsuper AND NOT role.rolinherit AND NOT role.rolcreaterole
        AND pg_catalog.shobj_description(role.oid, 'pg_authid') = 'homelab:access-sessions:v1'
        AND NOT EXISTS (SELECT FROM pg_catalog.pg_auth_members AS member
          WHERE member.member = role.oid OR member.roleid = role.oid)) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'session_sweeper_not_installed';
  END IF;
END;
$guard$;

ALTER ROLE automation_data_session_sweeper LOGIN PASSWORD :'sweeper_password';
COMMIT;
SELECT 'session_sweeper_login=enabled';
