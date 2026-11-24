-- Second phase of workstation revocation: suspend the listed capabilities that are
-- still ready and print the ones this run suspended.
\set ON_ERROR_STOP on
\getenv capabilities REVOCATION_CAPABILITIES
SELECT 'session_revocation_suspended=' || COALESCE(string_agg(
    listed.domain || ':' || listed.capability, ',' ORDER BY listed.domain, listed.capability), '')
FROM (SELECT domain, capability FROM platform_operations.managed_access_capabilities
    WHERE state = 'ready'
      AND domain || ':' || capability = ANY (string_to_array(NULLIF(:'capabilities', ''), ','))
    FOR UPDATE) AS listed
CROSS JOIN LATERAL platform_operations.suspend_access_capability(listed.domain,
  listed.capability) AS suspended;
