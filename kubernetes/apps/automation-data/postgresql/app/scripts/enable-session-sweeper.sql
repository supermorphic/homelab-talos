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
-- pg_monitor members can read pg_stat_activity; keep the statement out of it.
SET LOCAL track_activities = off;

-- Refuse unless the access-session objects and both fixed roles match the installed
-- contract, including the marker, attributes, and absence of memberships.
DO $guard$
BEGIN
  IF current_database() <> 'automation_data_control' OR
      to_regprocedure('platform_internal.assert_access_session_contract()') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'session_sweeper_not_installed';
  END IF;
  PERFORM platform_internal.assert_access_session_contract();
END;
$guard$;

ALTER ROLE automation_data_session_sweeper LOGIN PASSWORD :'sweeper_password';
COMMIT;
SELECT 'session_sweeper_login=enabled';
