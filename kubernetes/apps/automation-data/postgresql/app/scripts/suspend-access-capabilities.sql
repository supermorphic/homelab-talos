-- First phase of workstation revocation: suspend every ready specification 036
-- capability and print the ones this run suspended, so only those are resumed.
\set ON_ERROR_STOP on
SELECT 'session_revocation_suspended=' || COALESCE(string_agg(
    ready.domain || ':' || ready.capability, ',' ORDER BY ready.domain, ready.capability), '')
FROM (SELECT domain, capability FROM platform_operations.managed_access_capabilities
    WHERE state = 'ready' FOR UPDATE) AS ready
CROSS JOIN LATERAL platform_operations.suspend_access_capability(ready.domain,
  ready.capability) AS suspended;
