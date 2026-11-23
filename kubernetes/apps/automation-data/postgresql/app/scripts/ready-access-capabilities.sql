-- First phase of workstation revocation: print the ready specification 036
-- capabilities. The caller records them before any is suspended, so a lost result
-- of the suspend phase cannot hide which ones to resume.
\set ON_ERROR_STOP on
SELECT 'session_revocation_ready=' || COALESCE(string_agg(domain || ':' || capability, ','
    ORDER BY domain, capability), '')
FROM platform_operations.managed_access_capabilities WHERE state = 'ready';
