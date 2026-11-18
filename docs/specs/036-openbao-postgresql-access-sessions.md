# OpenBao PostgreSQL access sessions

## Status and scope

Design for [issue 513](https://github.com/supermorphic/homelab-talos/issues/513).
Implementation has not started.

Approved local agent tasks obtain a temporary PostgreSQL login from OpenBao for one
command, with authority set by a stable, migration-granted permission role. The
first consumer is Career Ops. Its `read` capability ships first. The attended
`correct` capability follows after `read` passes live acceptance; this
specification fixes its required boundaries, and its implementation is a later
stage.

This specification owns the session boundary: OpenBao issuance objects, the
session token, capability and temporary-login registries, the issuer and sweeper
identities, the local session runner, failure and revocation behavior, discovery,
audit, recovery, and acceptance. It extends, without replacing:

- [Specification 030](030-openbao-kubernetes-credential-broker.md): OpenBao
  deployment, configuration apply, drift detection, audit, and recovery.
- [Specification 031](031-openbao-agent-credential-profiles.md): workstation
  AppRole enrollment, the 60-second login token, and workstation revocation.
- [Specification 032](032-openbao-scoped-test-execution.md): per-invocation
  Kubernetes credentials.
- [Specification 026](026-automation-data-postgresql-platform.md): the
  automation-data PostgreSQL platform, its registries, validators, backup, and
  credential discovery.

Career Ops owns its grants, query entry point, wrapper, and application
acceptance. NocoDB, n8n runtime, migrator, and administrative identities are out of
scope. Migration logins are a later consumer
([career-ops#533](https://github.com/supermorphic/career-ops/issues/533)).

## Problem

Agents read Career Ops production data through n8n helper workflows bound to the
migrator credential, which switch to `career_ops_owner`. Each readback takes three
to five tool calls, and every readback holds full DDL and DML authority in an agent
session that also reads untrusted job-posting text. n8n holds that credential
permanently; the only boundary is who may run workflows.

The goal is one command per readback, run with a short-lived login that can only
read, without any person or agent handling a password.

## Architecture

```text
career-ops: just db read …
    -> homelab-talos: just kube automation-data-session career_ops read -- <child>
         1. AppRole login (spec 031)            -> 60-second login token
         2. token role                          -> session token, same identity
         3. automation-data/creds/career-ops-read -> temporary login, 10 minutes
              OpenBao -> issue_session_login() in PostgreSQL
         4. private tunnel, service file, passfile; run child; deadline
         5. revoke session token -> OpenBao -> revoke_session_login()
    sweeper CronJob, every 5 minutes -> sweep_session_logins()
```

| Component | Decides |
| --- | --- |
| OpenBao | Who may obtain a login: an enrolled workstation, for capabilities its policy names. |
| PostgreSQL capability role | What a login may do. Consumer migrations own the grants; the platform enforces a ceiling. |
| Session runner | How one session runs: issuance, tunnel, deadline, cleanup. Consumers never handle OpenBao. |
| Operator | Configuration, registration, kill switch, and recovery, including when OpenBao is unavailable. |

File permissions and private paths are not a security boundary between processes
of the same operating-system user. Any such process can read the session passfile
while the session runs, and can use the workstation enrollment itself, as
specification 031 states. The boundary is the OpenBao policy, the PostgreSQL role,
the short lifetime, and the audit trail.

## Decisions and rejected alternatives

| Considered | Decision |
| --- | --- |
| Dynamic login per command, through a session token | Selected. Concurrent sessions get distinct usernames; nothing needs rotation; #450 authentication is unchanged. |
| OpenBao-managed static roles | Rejected for agent sessions: concurrent sessions would share one login, and rotation breaks other sessions' new connections. |
| Longer workstation login tokens, or a second AppRole | Rejected: widens the Kubernetes issuance path or duplicates enrollment. |
| OpenBao Agent or Proxy | Rejected: auto-auth and templates assume a background process and renewable tokens; with 60-second login tokens they would issue a new login every minute. |
| Session spanning several commands | Rejected: requires a session token and passfile at rest between commands and separate crash recovery. |
| Temporary logins inherit `career_ops_reader` | Rejected: NocoDB validators require that role to have no members. A dedicated capability role keeps those checks intact. |
| Local PostgreSQL proxy without a passfile | Rejected: custom wire-protocol code the session boundary does not need. |
| Persistent registered application profile (issue 491) | Retained for its existing consumers; not used for agent read sessions. |

## OpenBao configuration

Add these objects to `kubernetes/apps/security/openbao/config/desired.json`, with
new configuration kinds covered by the existing exact-inventory apply and read-only
drift checks:

- A `database` secrets mount at `automation-data/`, with a maximum lease of 600
  seconds and `audit_non_hmac_response_keys=["username"]`. Passwords stay hashed in
  audit output.
- Connection `automation-data` to the automation-data PostgreSQL Service, as the
  issuer login, with `password_authentication=scram-sha-256` and `allowed_roles`
  listing exactly the registered OpenBao roles. Only SCRAM verifiers leave OpenBao.
  The connection password is not in Git and is excluded from drift comparison.
- One OpenBao role per capability, for example `career-ops-read`:
  - `creation_statements`: `SELECT platform_operations.issue_session_login('{{name}}', '{{password}}', '{{expiration}}', 'career_ops', 'read')`.
  - `revocation_statements`: `SELECT platform_operations.revoke_session_login('{{name}}')`.
  - Default and maximum TTL equal to the capability's registered maximum, so
    renewal cannot extend it.
- Connection `username_template` uses only `.RoleName` and `random`, for example
  `v-<role name>-<20 random characters>`, lowercased. OpenBao substitutes the
  username into SQL text before execution, so the template must not include a
  caller-influenced field such as `.DisplayName`. The function's format check is a
  second layer.
- Policy `db-<capability role>` with `read` on that capability's `creds` path and
  `update` on `auth/token/revoke-self`. It has no lease renewal, token creation, or
  other access.
- One token role per capability and workstation slot, for example
  `db-career-ops-read-<slot>`: `orphan=true`, `renewable=false`,
  `token_explicit_max_ttl` equal to the capability maximum,
  `token_no_default_policy=true`, `token_type=service`, exactly one allowed policy,
  and exactly one allowed entity alias, the slot's.
- The workstation policy gains `update` on `auth/token/create/<that token role>`
  for read capabilities only. Its Kubernetes endpoints are unchanged. No
  workstation policy grants an attended capability.

The issuer password has one rotation owner. A guarded operator step sets an initial
password, writes the connection, and runs `rotate-root`; afterwards only OpenBao
knows it. Only the operator triggers `rotate-root`; it has no schedule. Any
`rotate-root` error leaves the credential state unknown and requires the trusted
reset procedure in [Recovery](#recovery).

## Session token and identity binding

A database lease belongs to the token that requested it and is revoked when that
token expires or is revoked. The 60-second workstation login token therefore
cannot hold a 10-minute login. The login token instead creates one orphan session
token through the capability's token role, and the session token requests the
login.

An orphan token does not inherit its creator's identity entity. Without an explicit
alias, OpenBao creates a new, enabled entity for it, and disabling the workstation
would not block it. Enrollment therefore also creates an alias for the workstation
entity on the token auth mount, named for the slot, and the token role allows
exactly that alias. For the workstation enrolled before this change, a guarded
operator action adds the alias.

The runner passes that alias when creating the session token and compares the
returned `entity_id` with the expected entity recorded at enrollment. On mismatch
it revokes the token and fails with `session_identity_mismatch`. Acceptance proves
that disabling the workstation entity blocks an existing session token.

Per command:

1. Log in with AppRole and check the entity, as specification 031 requires.
2. Create the session token and check its entity. Revoke the login token.
3. Read the login with the session token.
4. Run the session.
5. Revoke the session token. OpenBao revokes the lease and runs
   `revoke_session_login`.

Login and session tokens stay in process memory. Requests carry the OpenBao
consistency headers that specification 031 defines. Ambiguous writes are not
retried.

## Capability roles

`platform_operations.managed_access_capabilities` registers each
`(domain, capability)`. A capability identifier matches `^[a-z][a-z0-9_]{0,23}$`.
Each row records:

- the role `cap_<md5(domain || ':' || capability)>_access`;
- the schemas it may read;
- `max_ttl_seconds` (600 for `read`, 300 for `correct`);
- whether it is read-only or function-only; and
- state `ready` or `suspended`.

The role is `NOLOGIN NOINHERIT` with no special attributes and no membership in any
other role. Registration is a guarded operator operation through the existing
provisioner, like application-login registration. It creates the role and grants
nothing:

```sh
AUTOMATION_DATA_CAPABILITY_REGISTER_CONFIRM=register:automation-data:career_ops:read \
  mise exec -- just kube automation-data-capability-register career_ops read <schemas> 600
```

`<schemas>` is a comma-separated list. The command prints the capability and its
validation as one JSON line. Rerun it with the same values after the consumer's
grant migration; `valid` must be `true` before issuance can succeed. A different
schema list or lifetime for an existing capability is refused with
`access_capability_binding_conflict`.

The consumer grants authority through a reviewed migration. For Career Ops `read`,
the grants are SELECT on the tables and views that readbacks, diagnostics, and
reviews need, as listed by Career Ops. They are not a copy of `career_ops_reader`,
so NocoDB changes cannot alter agent read access.

The capability validator reuses the effective-privilege checks of
`platform_internal.application_login_checks`, generalized to a role and a schema
list. Effective privileges include grants received through PUBLIC and through
inheritance. The ceiling is:

- `CONNECT` to the domain database only; no `CREATE` or `TEMP`;
- no DML, `TRUNCATE`, `REFERENCES`, `TRIGGER`, or `MAINTAIN` on any relation, and no
  sequence `UPDATE` or `USAGE`;
- no ownership, grant options, or default privileges;
- for read-only capabilities, no EXECUTE on any `SECURITY DEFINER` function outside
  `pg_catalog`, since such a function is the only way a login without write grants
  can write;
- for function-only capabilities, EXECUTE only on the registered function list;
- members only registered temporary logins, granted `WITH INHERIT TRUE, SET FALSE,
  ADMIN FALSE`.

Existing NocoDB, application-login, and discovery-role validators are unchanged.
They continue to require no members on their roles.

## Issuer, sweeper, and lifecycle functions

The issuer login `automation_data_openbao_issuer` can log in, has `CONNECT` only on
`automation_data_control`, and has EXECUTE only on `issue_session_login` and
`revoke_session_login`. The sweeper login `automation_data_session_sweeper` has
EXECUTE only on `sweep_session_logins`. Both have `log_statement=none` and
`log_min_error_statement=panic` set by the platform, so neither statement text nor
SCRAM verifiers reach PostgreSQL logs, including on error.

All lifecycle functions follow the existing provisioner pattern: owned by
`postgres`, `SECURITY DEFINER`, `SET search_path = pg_catalog,
platform_operations, pg_temp`, EXECUTE revoked from PUBLIC, and dynamic SQL built
only with `format()` and `%I`/`%L`.

`platform_operations.managed_dynamic_logins` records, without secrets: role name,
role OID, domain, capability, issue time, expiry, revocation time, and
`revoked_by` (`openbao`, `sweeper`, `operator`, or `restore`).

`issue_session_login(name, verifier, expiration, domain, capability)` runs in
OpenBao's single creation transaction:

1. Take `FOR SHARE` on the capability row. Refuse unless it is `ready` and valid.
2. Refuse with `reconciliation_unhealthy` when the sweeper heartbeat is older than
   15 minutes.
3. Check the name format, that the verifier is a SCRAM-SHA-256 verifier, and that
   the expiry is no later than now plus `max_ttl_seconds`.
4. Remove registered logins already past expiry, as described for revocation.
5. Create the login: `LOGIN INHERIT`, no special attributes, `VALID UNTIL` the
   expiry, a small `CONNECTION LIMIT`, and role defaults for `statement_timeout`,
   `idle_session_timeout`, and `idle_in_transaction_session_timeout`. Read-only
   capabilities also set `default_transaction_read_only=on`. A login can change
   these defaults; they limit accidents, not deliberate misuse.
6. Grant the capability role `WITH INHERIT TRUE, SET FALSE, ADMIN FALSE`.
7. Record the login and its OID.

`revoke_session_login(name)` acts only on a registered name whose OID matches:

1. Set the role `NOLOGIN` in its own committed transaction through the existing
   `dblink` helper, so no new session can start.
2. Terminate the role's backends, wait, and verify none remain.
3. Run `DROP OWNED BY` in the domain database. A read login can still own large
   objects created with `lo_create()`.
4. Drop the role and verify by OID that it no longer exists.
5. Record the revocation.

Any failed step raises an error. The role stays `NOLOGIN`, and OpenBao or the
sweeper retries. Revoking an already-removed login succeeds.

`sweep_session_logins()` applies the revocation steps to every registered login
past expiry, records `revoked_by='sweeper'`, and writes a heartbeat row.

Operator-only kill-switch functions, run with the platform superuser credential
and independent of OpenBao:

- `suspend_access_capability(domain, capability)` updates the capability row to
  `suspended` and commits, which serializes with issuance through the row lock.
- `revoke_access_capability_logins(domain, capability)` revokes all of its registered
  logins with `revoked_by='operator'`.
- `resume_access_capability(domain, capability)` is a separate, explicitly confirmed step.

## Sweeper and monitoring

Normal sessions are removed by the runner when the command ends, or by OpenBao at
lease expiry. The sweeper is the independent backstop when both fail, for example
when OpenBao is unavailable or exhausts its revocation retries. An expired login
cannot open new connections, but an existing connection persists until something
terminates it.

The sweeper is a CronJob in the automation-data PostgreSQL package, following the
automation-data backup job: pinned `postgres` image, `timeZone: Etc/UTC`, schedule
every 5 minutes, `concurrencyPolicy: Forbid`, a short `activeDeadlineSeconds`, no
retries, history limits of one, and `ttlSecondsAfterFinished` so finished pods are
removed. Its credential is an operator-created SOPS Secret. A Job succeeds only when
every revocation in its sweep succeeded, and the script prints only the counts.

Alternatives considered: a sidecar in the PostgreSQL pod could take the database
off its Service when crash-looping and restarts the database on every change;
`pg_cron` requires a custom image; an n8n or Gatus trigger would make the backstop
depend on n8n; SQL Exporter must remain read-only.

SQL Exporter counts active and overdue temporary logins from `pg_roles`, so the
counts do not depend on the registry that the sweeper maintains and need no new
grants. The heartbeat alert uses the CronJob's last successful run, as the backup
alerts do. It fires when no clean sweep has completed for 15 minutes, or when a new
CronJob has never succeeded within 20 minutes, and it stays silent while the CronJob
is suspended. A second alert fires when a temporary login stays past its expiry for
10 minutes.

The sweeper is delivered suspended, without its Secret. To enable it, the operator:

1. On a branch, runs
   `AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM=write:automation-data:session-sweeper:sops mise exec -- just repo automation-data-session-sweeper-secret`.
   It generates the password, writes the encrypted Secret, and selects it in the
   PostgreSQL kustomization. Commit both files and merge.
2. After Flux applies the Secret, runs
   `AUTOMATION_DATA_SESSION_SWEEPER_ENABLE_CONFIRM=enable:automation-data:session-sweeper mise exec -- just kube automation-data-session-sweeper-enable`.
   It sets the sweeper's password login from the deployed Secret. Expected final
   line: `session_sweeper_login=enabled run=<run-id>`.
3. Sets `suspend: false` on the CronJob through Git.

To rotate the password, repeat steps 1 and 2. Sweeps fail between the Flux apply and
step 2, so run step 2 promptly: issuance stops 15 minutes after the last successful
sweep, and the heartbeat alert fires about 5 minutes later.

With the sweeper healthy, a connection left by failed revocation lasts at most the
capability lifetime plus one sweep interval: about 15 minutes for `read`. When the
heartbeat is stale, new issuance stops, so the bound holds for every login issued.

## Local session runner

`mise exec -- just kube automation-data-session <domain> <capability> [--timeout SECONDS] -- <command…>`

Only pairs in a homelab-talos catalog that matches the OpenBao roles are accepted.
`--timeout` can only shorten the deadline. Arguments keep their boundaries through
`just` (`positional-arguments`), `mise exec --`, and Python `subprocess` with an
argument list; no shell interpolates them.

A run:

1. Removes stale sessions: for each earlier session directory whose recorded
   expiry has passed and whose runner has exited, stop its recorded child and
   tunnel processes only when both PID and process start time match, then delete
   the directory. `just kube automation-data-session-cleanup` runs the same step.
2. Creates a `0700` session directory with `mkdtemp` under
   `~/.local/state/homelab-talos/automation-data-sessions/`, outside every
   checkout, using the existing private-file helpers. Files are `0600`, owner-checked,
   and never symlinks. `session.json` records non-secret metadata: process IDs,
   process start times, username, and expiry.
3. Issues the login as described in [Session token and identity binding](#session-token-and-identity-binding).
4. Writes a per-invocation `debugger` kubeconfig as specification 032 defines, and
   runs `kubectl port-forward --address 127.0.0.1 <pod> :5432`, reading the
   assigned local port from kubectl's output. It keeps checking tunnel readiness
   and liveness.
5. Writes `pg_service.conf` (`host=127.0.0.1`, the port, `dbname`, `user`,
   `passfile`, `connect_timeout=10`, `application_name=automation-data-session`,
   `sslmode=disable`) and `credential.pgpass` with `\` and `:` escaped. Traffic
   uses loopback and the Kubernetes API's TLS port-forward, and authentication
   uses SCRAM.
6. Connects once and requires: `session_user` is the issued username,
   `current_database()` is the domain, `pg_has_role(user, cap, 'USAGE')` is true,
   `pg_has_role(user, cap, 'SET')` is false, and read-only capabilities start
   read-only transactions. It closes this connection before starting the child.
7. Starts the child in a new process group with `PGSERVICEFILE`, `PGSERVICE`,
   `AUTOMATION_DATA_SESSION_USER`, and `AUTOMATION_DATA_SESSION_EXPIRES_AT`. It
   removes inherited `PG*`, `PGSYSCONFDIR`, `KUBECONFIG`, `BAO_*`, and `VAULT_*`
   variables.
8. Enforces a deadline measured on a monotonic clock: the earlier of the session
   token expiry and the lease expiry, as reported by OpenBao and measured from
   just before each request, minus a 120-second cleanup margin. At the deadline it
   sends SIGTERM to the process group, waits 10 seconds, then sends SIGKILL. Setup
   steps have their own HTTP, tunnel-readiness, and connection timeouts.
9. On every exit path and on SIGINT, SIGTERM, and SIGHUP, runs each cleanup step
   independently, recording each result even when another fails: stop the child's
   process group, close the tunnel, revoke the session token, and delete the
   session directory.
10. Prints one sanitized status line to stderr with the username, expiry, child
    exit code, and each cleanup result. The child's own output passes through.

Exit codes: the child's code when cleanup completes, `124` for the deadline, `70`
for a setup failure, `69` when the tunnel is lost during the session, and `75`
when cleanup is incomplete, which replaces any other code.

Each run has its own tokens, login, port, directory, and kubeconfig. The only
shared input is the read-only workstation enrollment. If the runner itself is
killed, the next run or the cleanup command stops leftover processes. Meanwhile the
login expires and is removed, so a leftover tunnel reaches only a database port
with no valid login.

The tunnel uses the existing `debugger` profile, which any enrolled agent can
already install. It grants diagnostic access beyond the database Pod, so the runner
adds no Kubernetes authority but does not narrow it either. A dedicated
port-forward-only profile is a possible later refinement.

## Career Ops consumer boundary

Career Ops implements, through a reviewed Career Ops change:

- A public `just db read …` that requires an absolute `HOMELAB_TALOS_WORKTREE`,
  checks that it is a homelab-talos checkout, and runs
  `mise -C "$HOMELAB_TALOS_WORKTREE" exec -- just kube automation-data-session career_ops read -- mise -C <career-ops> exec -- uv run career-ops-db-read …`.
  The agent obtains the worktree as Career Ops already requires: a task-owned
  linked homelab-talos worktree.
- An internal `career-ops-db-read` entry point that refuses to run unless
  `PGSERVICEFILE` is inside the session root and the connected `session_user`
  equals `AUTOMATION_DATA_SESSION_USER`, and never invokes `db read`. A test
  covers recursion.
- Arbitrary SQL under the read-only capability, with optional named queries for
  convenience. The database enforces authority.
- A check that its mise configuration sets no `PG*` variables, so persistent
  database credentials cannot re-enter the child.
- The capability migration and a test that compares the granted objects with the
  readback list.

## Failure behavior

The runner never falls back to a static profile or broader credential.

| Failure | Behavior |
| --- | --- |
| Workstation enrollment missing, expired, unsafe, or revoked | Fail before any tunnel opens; report the re-enrollment prerequisite. |
| Session token creation fails or entity mismatches | Revoke known tokens; `issuance_unavailable` or `session_identity_mismatch`. |
| Login request fails or times out | Revoke the session token. The result is indeterminate: PostgreSQL may have committed a login before OpenBao recorded its lease. The registry and sweeper remove such a login after expiry. `issuance_unavailable`. |
| Capability suspended, or sweeper unhealthy | `capability_suspended` or `reconciliation_unhealthy`. |
| Tunnel or identity check fails | Clean up; `connection_unavailable` or `identity_mismatch`. |
| Tunnel drops during the session | Stop the child, clean up, and exit `69`; no silent reconnect. |
| OpenBao unavailable during or after the session | The child is unaffected. Revocation fails; report `revoke_failed` with the expiry. |
| Task outlives the credential | The deadline stops the child before the lease ends. More work requires a new command. Nothing is renewed. |

Worst cases when revocation does not happen: new connections fail once
`VALID UNTIL` passes, and existing connections end within one sweep interval
after expiry. Acceptance tests these separately.

## Revocation and the kill switch

Workstation revocation in specification 031 gains these steps after the entity is
disabled and its SecretIDs are destroyed:

1. Record which capabilities are `ready`, and suspend them.
2. Revoke all database leases with `sys/leases/revoke-prefix/automation-data/creds/`
   using `sync=true`. `revoke-force` is not part of this workflow.
3. Verify that `managed_dynamic_logins` and the PostgreSQL role catalog contain no
   unrevoked temporary login. Revoke any remainder through the sweeper path and
   report it.
4. Resume only the capabilities recorded in step 1.

This revokes every workstation's active sessions, each lasting at most its
capability lifetime. Remaining session tokens are unusable while their entity is
disabled and expire within the longest capability lifetime.

Re-enabling a disabled entity requires waiting the longest session-token lifetime
(600 seconds) after disablement, in addition to the conditions in specification
031; otherwise enroll a fresh logical workstation. A lost workstation is treated
as compromised: revoke it before re-enrollment.

Routine SecretID rotation does not affect active sessions. The operator kill switch
in [Issuer, sweeper, and lifecycle functions](#issuer-sweeper-and-lifecycle-functions)
works without OpenBao.

## Discovery

`mise exec -- just kube automation-data-credentials resolve career_ops session --capability read`
reports, as metadata only:

- issuer `openbao` and the capability;
- workstation enrollment presence and validity, through the specification 031
  status check;
- capability registration, validity, and state;
- sweeper health;
- the number of active sessions.

A ready result names the fixed `automation-data-session` recipe with validated
arguments. Otherwise it names the missing prerequisite. It never returns credential
file paths. Existing purposes and exit codes are unchanged.

Credential discovery joins observed `v-…` roles with `managed_dynamic_logins`.
Registered ones are reported as active sessions, never as selectable credentials;
an unregistered one is `inconsistent`.

## Audit and log safety

Attribution from requester to database identity, with no secret values:

1. OpenBao audit: session-token creation with the entity and hashed accessor.
2. OpenBao audit: the login read with the same hashed accessor, the lease ID, and
   the username in clear text.
3. `managed_dynamic_logins`: username, OID, capability, times, and `revoked_by`.
4. PostgreSQL `log_connections` and `log_disconnections`, enabled for this
   instance and collected by Loki.
5. The runner's status line in the agent transcript.

Acceptance scans OpenBao audit output, PostgreSQL logs, runner output, and retained
evidence for test passwords, tokens, and SCRAM verifiers.

## Network

Add one path: OpenBao server pods to automation-data PostgreSQL port 5432, in both
namespaces' Cilium policies, plus the sweeper Job's path following the backup Job.
Workstations still reach PostgreSQL only through the scoped port-forward tunnel.
The tunnel credential and the PostgreSQL login are separate credentials with
separate checks.

## Recovery

| Event | Action |
| --- | --- |
| Workstation lost | Treat as compromised: revoke, then re-enroll (specification 031). |
| Workstation compromised | Run workstation revocation with the steps above. |
| OpenBao unavailable | No new sessions. Use the kill switch if needed. Operator recovery paths remain: platform superuser, migrator profile, and n8n credentials. |
| OpenBao or PostgreSQL restored | Revoke all registered temporary logins with `revoked_by='restore'` and verify none remain (below). Then run the issuer reset. Restored leases whose roles are gone revoke cleanly. |
| Issuer credential state unknown | Issuer reset. |

Issuer reset: with the platform superuser credential, set a new issuer password;
rewrite the OpenBao connection; run `rotate-root`; issue and revoke one test login
through the runner.

Capability roles and registries are in logical backups. Temporary logins are not
recoverable credentials. A restore brings them back with new OIDs, which normal
revocation and the sweeper refuse as identity mismatches. They cannot log in after
their expiry, but run the restore cleanup immediately after a PostgreSQL restore:

```sh
AUTOMATION_DATA_SESSIONS_RESTORE_CLEANUP_CONFIRM=cleanup:automation-data:restored-sessions \
  mise exec -- just kube automation-data-sessions-restore-cleanup
```

It rebinds each registered login to its restored role only when the role has the
shape issuance creates, then revokes every registered login. Expected result line:
`session_restore_cleanup revoked=<n> failed=0 remaining=0 run=<run-id>`, followed by
the command's own cleanup line.

If the Job prints only `session_restore_cleanup=failed`, the restored control
database may predate the cleanup function. Run `automation-data-sessions-install`,
which reapplies the access-session SQL after a fresh backup, then run the cleanup
again.

A non-zero `failed` or `remaining` leaves at least one temporary-login role in
place. Inspect each `v-…` role and its registry row before acting. Causes include a
role without the issued shape, an unregistered role, a registry row already marked
revoked while its role still exists, sessions that do not end, and objects the role
owns outside its domain database. Rerun the cleanup after correcting the cause.

## Delivery and cutover

1. homelab-talos: registries, functions, validators, sweeper and alerts, network
   policy, OpenBao objects, runner, discovery, revocation workflow, and the alias
   action. Update specification 031's revocation, re-enable, and lost-workstation
   rules in the same change. Offline validation.
2. Operator: apply the control-database migration, create the issuer and sweeper
   Secrets, apply OpenBao configuration and run `rotate-root`, add the alias for
   the existing workstation, and register `career_ops read`.
3. Career Ops: capability migration, wrapper, entry point, and tests.
4. Separately authorized live acceptance.
5. Read cutover: Career Ops readbacks move to `db read`, and helper workflows stop
   being used for reads. Verify that agent instructions and skills route readbacks
   only to `db read`.
6. `correct` capability: design its attended authorization, implement, and accept.
7. Repair cutover: retire the owner-privileged helper workflows and verify they are
   unpublished and archived.

The migrator credential stays in n8n for reviewed migrations until
career-ops#533. n8n Community Edition cannot restrict an API key to specific
credentials, so cutover verification proves the readback and repair paths are
retired, not that agents cannot reach the migrator credential.

## Correct capability constraints

- Function-only: EXECUTE on a registered list of guarded Career Ops repair
  functions; no direct table writes.
- 300-second lifetime, with separate preview and apply steps.
- Issued only to a credential a person holds, such as a separate OpenBao userpass
  identity, never through the workstation policy. A terminal prompt is not
  sufficient, because an agent running as the same user can answer it.
- Before implementation, review whether `correct` needs a separate issuer login
  and connection. Today the issuer can mint a login for any registered capability.

## Validation and acceptance

Offline, in `just ci`:

- Runner: argument preservation, deadlines with a fake monotonic clock,
  independent cleanup steps, exit codes, signal handling, stale-session cleanup by
  PID and start time, environment scrubbing, private file modes, and secret
  sentinels in output.
- OpenBao configuration: new kinds, exact inventories, drift, and pinned responses.
- PostgreSQL functions and validators against a disposable PostgreSQL 17 instance,
  following existing automation-data test patterns: issuance checks, ceiling
  violations including PUBLIC and `SECURITY DEFINER` grants, revocation ordering,
  large-object cleanup, OID mismatch, suspension, sweeper, and heartbeat refusal.

Registered live suite `test.automation-data-sessions`, published with
`just test record`:

- Real issuance and attribution from audit to registry.
- Two concurrent sessions from independent checkouts with distinct logins and no
  shared mutable state.
- Allowed reads; denied writes, other databases, role creation, `SET ROLE`,
  ownership, and privilege escalation; large-object cleanup at revocation.
- Renewal denied.
- Revocation ends an existing connection and rejects new ones.
- With OpenBao revocation blocked: new connections rejected after expiry, and the
  existing connection ended by the sweeper.
- Issuance refused while the heartbeat is stale.
- Workstation revocation with a test workstation identity, following
  `test.agent-credentials`: the session-token barrier, global lease revocation with
  suspension, and the re-enable wait.
- Missing or revoked enrollment fails closed.
- No secrets in logs or retained evidence; discovery and connection work without a
  manually selected password file.

Candidate evidence does not replace the merge check or deployed-main acceptance.

## Residual risks

- Processes running as the workstation user can read an active session's passfile
  and use the workstation enrollment.
- The issuer can mint a login for any registered capability.
- Arbitrary read SQL can raise its own statement timeout and consume resources
  until the session ends.
- Query results can bring untrusted text into the agent's context, as readbacks do
  today.
- Global lease revocation also ends other workstations' sessions.
- The cleanup bound depends on a healthy sweeper; issuance stops when it is not.

## References

- [OpenBao database secrets engine](https://openbao.org/docs/secrets/databases/)
- [OpenBao PostgreSQL plugin](https://openbao.org/docs/secrets/databases/postgresql/)
- [OpenBao token roles](https://openbao.org/docs/auth/token/)
- [OpenBao lease, renew, and revoke](https://openbao.org/docs/concepts/lease/)
- [PostgreSQL 17 role membership](https://www.postgresql.org/docs/17/role-membership.html)
