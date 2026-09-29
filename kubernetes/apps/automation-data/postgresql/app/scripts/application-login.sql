-- Registration state for optional application logins in an existing managed database.
-- Fixed lifecycle functions are added with the complete v3 control upgrade.
SET ROLE postgres;

CREATE TABLE IF NOT EXISTS platform_operations.managed_application_logins (
  domain text NOT NULL REFERENCES platform_operations.managed_domains(domain),
  application text NOT NULL CHECK (application ~ '^[a-z][a-z0-9_]{0,23}$'),
  schema_name text NOT NULL CHECK (schema_name ~ '^[a-z][a-z0-9_]{0,47}$'),
  role_name text NOT NULL,
  state text NOT NULL CHECK (state IN (
    'awaiting_grants', 'activating', 'ready', 'rotating', 'error'
  )),
  operation_id uuid,
  credential_generation bigint NOT NULL DEFAULT 0 CHECK (credential_generation >= 0),
  operation_started_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z][a-z0-9_]{0,63}$'),
  PRIMARY KEY (domain, application),
  UNIQUE (role_name),
  CHECK (role_name = 'app_' || md5(domain || ':' || application) || '_integration')
);
REVOKE ALL ON platform_operations.managed_application_logins FROM PUBLIC;
