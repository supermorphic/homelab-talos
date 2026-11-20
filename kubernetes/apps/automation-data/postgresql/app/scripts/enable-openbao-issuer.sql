-- Give the specification 036 OpenBao issuer its initial password login. The issuer
-- reset command supplies ISSUER_PASSWORD as a SCRAM verifier, then has OpenBao rotate
-- the password with rotate-root.
\set ON_ERROR_STOP on
\getenv issuer_password ISSUER_PASSWORD
BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';
-- The ALTER ROLE text carries the password; keep it out of logs, including errors,
-- and out of pg_stat_activity.
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';
SET LOCAL track_activities = off;

-- Refuse unless the access-session objects and both fixed roles match the installed
-- contract, including the marker, attributes, memberships, and hidden activity.
DO $guard$
BEGIN
  IF current_database() <> 'automation_data_control' OR
      to_regprocedure('platform_internal.assert_access_session_contract()') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'openbao_issuer_not_installed';
  END IF;
  PERFORM platform_internal.assert_access_session_contract();
END;
$guard$;

ALTER ROLE automation_data_openbao_issuer LOGIN PASSWORD :'issuer_password';
COMMIT;
SELECT 'openbao_issuer_login=enabled';
