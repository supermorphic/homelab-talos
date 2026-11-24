-- Last phase of workstation revocation, after OpenBao revoked its database leases:
-- revoke every remaining registered temporary login, count what remains, and resume
-- the listed capabilities only when resumption is allowed and nothing remains.
\set ON_ERROR_STOP on
\getenv capabilities REVOCATION_CAPABILITIES
\getenv resume REVOCATION_RESUME
SELECT result->>'revoked' AS revoked, result->>'failed' AS failed
FROM platform_internal.revoke_session_logins(false, NULL, NULL, 'operator') AS result \gset
SELECT count(*) AS remaining FROM (
  SELECT rolname FROM pg_roles WHERE rolname ~ '^v-[a-z0-9-]{1,40}-[a-z0-9]{20}$'
  UNION
  SELECT role_name FROM platform_operations.managed_dynamic_logins WHERE revoked_at IS NULL
) AS unresolved \gset
SELECT format('session_revocation revoked=%s failed=%s remaining=%s resumed=%s',
  :'revoked', :'failed', :'remaining', COALESCE(string_agg(
    listed.domain || ':' || listed.capability, ',' ORDER BY listed.domain, listed.capability), ''))
FROM (SELECT domain, capability FROM platform_operations.managed_access_capabilities
    WHERE :'resume' = 'true' AND :'failed' = '0' AND :'remaining' = '0'
      AND state = 'suspended'
      AND domain || ':' || capability = ANY (string_to_array(NULLIF(:'capabilities', ''), ','))
    FOR UPDATE) AS listed
CROSS JOIN LATERAL platform_operations.resume_access_capability(listed.domain,
  listed.capability) AS resumed;
