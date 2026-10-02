# Automation Data PostgreSQL Platform

## Purpose and governing invariants

Provide durable relational state for automation domains, separately from n8n's own
runtime database. After bootstrap, domain databases, roles, schemas, grants, and
credentials are runtime state created by one private n8n provisioning workflow.
Adding a domain or private application integration requires no per-domain infrastructure,
SOPS Secret, or policy change. New public webhook exposure still requires a reviewed
Git-managed route under the [n8n contract](023-n8n-workflow-automation-platform.md).

Use one private PostgreSQL StatefulSet with retained Longhorn data/backup claims.
It supplies stable identity and rescheduling, not automatic database failover. There is
no external database endpoint, pooler, operator, or cross-domain transaction guarantee.
The off-cluster recovery-point objective is 24 hours; recovery remains manual without
an RTO promise. PostgreSQL major upgrades need an explicit migration design.

The [platform package](../../kubernetes/apps/automation-data/postgresql/ks.yaml)
owns infrastructure, bootstrap/control SQL, logical backup, scoped policy, and monitoring.
Its [SQL](../../kubernetes/apps/automation-data/postgresql/app/scripts/platform-control.sql)
and the [provisioner template](../../kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json)
own exact identifiers, function signatures, fields, and lifecycle implementation.
Versions, capacity, schedules, and artifact layouts belong in source rather than prose.

## Authority model

The provisioner has no general superuser, role-creation, or database-creation attributes.
Its authority is a fixed `SECURITY DEFINER` function boundary on the control database.
Revoke PUBLIC execution and expose no arbitrary platform SQL, caller-supplied grants,
or database/role deletion. Normal workflows receive only their domain identity.

The selected n8n Community API key has the full authority of its owning account;
credential-only scope is a workflow contract, not an enforceable key boundary.
The PostgreSQL provisioning credential can operate across managed domains; compromise
of the n8n API key affects the full account. This is an accepted tradeoff of direct
n8n provisioning. Private access, fixed local API calls, isolated bindings, encrypted
storage, and disabled execution persistence reduce exposure without reducing key authority.
The design does not claim cryptographic isolation between credentials available to the
same authorized n8n project operator.

Each domain separates stable `NOLOGIN` ownership, a DDL migrator, and a runtime login.
Migrators explicitly assume their owner for reviewed DDL in their own database;
runtime identities cannot assume that role, change schema, manage roles, or access
another domain or the control database. Stable ownership survives login rotation.
Reserved/colliding identifiers cannot adopt unrelated databases or roles.

Provisioning supplies initial CRUD grants; applications may narrow object/default grants
or use controlled functions. Platform validation enforces an authority ceiling rather
than requiring access to every application object. It covers effective PUBLIC,
inherited, column, routine, sequence, default, and grant-option authority. Behavioral
probes use their own temporary objects. Applications own exact grants and business tests.
Do not use ordinary provision/reconcile to repair intentionally narrowed application grants.

Optional [NocoDB access](028-nocodb-operator-ui.md) adds distinct reader/operator roles
and runtime registry state without changing ordinary domain readiness. NocoDB never
receives core runtime, migrator, provisioner, owner, or backup credentials.

## Provisioning and rotation

The private workflow takes structured targets and supported operations, never arbitrary
SQL or destinations. It reserves ownership durably before separate database changes,
checks actual catalogs, reconciles structure, establishes encrypted n8n credentials,
tests authentication and authority, and marks `ready` only after all checks succeed.
It enumerates the complete credential inventory before checking duplicate names.

Generated domain passwords exist transiently only while delivered to PostgreSQL and n8n.
Their retained pair is a PostgreSQL password verifier and an n8n-encrypted credential.
Disable manual/success/failure/progress execution persistence; outputs and logs contain
only bounded non-secret identity/state evidence. No domain plaintext-password escrow exists.

Partial creation retains its ownership reservation and error state; it never compensates
by deleting resources. Retry before a domain has ever become ready may replace incomplete
credentials. Active interrupted reservations require the guarded stale-operation interval;
failed operations can retry under their own lifecycle. Matching names alone do not prove
ownership. Once ready, ordinary provision/reconcile preserves role passwords, credential
IDs, and ciphertext. Missing ready-side roles or credentials require reviewed recovery.

Rotation is explicit and affects one selected login and its existing n8n credential.
The two updates converge but are not a distributed transaction; interruption may break
authentication. A target-bound retry creates a new password and converges both sides only
while the retained login/credential identities still exist. The provisioning authority
can recover that pair without retrieving the previous plaintext password.

Domain migrations may perform reviewed destructive DDL within their database. Database
and role decommissioning remains separately attended: establish exact ownership and
consumers, protect a fresh complete backup, and repeat preconditions before deletion.
No self-service database/role deletion is exposed.

## Backup and recovery

Pre-created claims resist routine Flux pruning, not intentional PVC/namespace deletion
or storage loss. Off-cluster copies remain essential. Backup discovers all actual
non-template databases from PostgreSQL catalogs, including unregistered/partial databases
and NocoDB metadata; no Git-maintained database list is authoritative.

A logical bundle contains globals with memberships and password verifiers, the control
registry, and every captured database with ownership, ACLs, and data. Its backup identity
is isolated from workflows because protected global catalogs require broader authority.
Never omit role passwords. Treat globals and database artifacts as sensitive even when
no plaintext password is present; do not publish their contents.

Publication validates every archive/checksum and atomically finalizes the whole bundle
before freshness advances. Capture the database set and platform generation before and
after dumping; concurrent changes cause bounded retry. Stable incomplete registry rows
remain recoverable metadata and do not discard otherwise complete database backups.
Unknown/partial compatibility state blocks publication. Separate database dumps do not
form a distributed transaction snapshot. Job success, checksum verification, and archive
listing each supply weaker evidence than an authenticated restore.

### Recovery roots and independent sequence

Retain the operator age identity, access to off-cluster backup copies, encrypted Secrets
in remote Git history, the stable `N8N_ENCRYPTION_KEY`, and complete n8n/automation-data
artifacts independently of the running services. Registered client profiles below are
an additional root; a globals dump contains verifiers, not recoverable client passwords.

With healthy claims and a pod failure, preserve state and let the StatefulSet recover.
Unavailable storage follows [platform recovery](010-talos-flux-platform.md). Logical
replacement first uses an isolated empty destination; production replacement requires
separate operator authority. Preserve the damaged state and all recovery roots.

The guarded full-chain restore follows this order:

1. Select and checksum-validate a complete automation-data bundle and compatible n8n dump.
   Default selection is independent; both must contain the same credential generation.
   An invalid explicit selection fails instead of silently choosing another pair.
2. Restore globals into isolated PostgreSQL before databases. The empty destination's
   existing `postgres` role requires omitting only its one `CREATE ROLE postgres;`
   declaration; preserve all its restored attributes/verifier and fail other SQL errors.
3. Restore the control database and every manifest database with original ownership/grants.
   Validate catalog/registry agreement and optional source/application role boundaries.
4. Restore n8n separately with its unchanged encryption key. Redirect only the isolated
   n8n instance's automation-data hostname to the isolated database.
5. Execute the restored authenticated Automation Data Canary using its existing runtime
   credential. Prove database/session identity without revealing the password. Check
   restored migrator/runtime separation and compare application permissions with the archive,
   preserving deliberately absent grants as well as present ones.
6. Produce and validate a fresh post-recovery bundle, then prove all run-owned workloads,
   policy, Services, and scratch claims removed. The drill creates no HTTPRoute.

Use `mise exec -- just kube automation-data-restore-drill` only with its approved mutation
credentials, selected artifact inputs, and exact confirmation. Detailed mechanics and
input validation live in [the scenario](../../scripts/test/scenarios/automation-data-restore-drill.sh).
Any permission, authentication, or cleanup failure stops acceptance. An isolated drill
proves its selected pair, not production replacement or application business behavior.

## Platform updates and bootstrap ordering

PostgreSQL initialization runs only on an empty data directory. Merge reviewed function
changes and wait for deployed-source parity; pause the live provisioner and drain
executions before the guarded `automation-data-control-migrate` workflow. It takes a
fresh backup, applies shared initialization/upgrade SQL transactionally under the existing
mutation Lease, and preserves application grants, identities, data, and credentials.
Keep provisioning paused if the update fails. After success, reconcile the imported graph
and bindings, publish it, and obtain fresh provisioning, backup, and paired restore evidence.

First bootstrap establishes PostgreSQL and private n8n provisioning/restore acceptance
before NocoDB initialization. Bind **Automation Data Provisioner** to SQL nodes,
**Automation Data n8n API** to credential API nodes, and **Automation Data Provisioning
Header** to the webhook. Initially disable **Observe Mutation Inventory** because discovery
cannot initialize until NocoDB exists. This bootstrap exception returns unavailable
readback and does not establish discovery acceptance.

## Registered application logins

A ready domain may register a distinct application login for explicit schema reads and
reviewed function calls. Registration freezes its target mapping and creates a collision-
checked `NOLOGIN` grant candidate. Consumer migrations grant intended reads and `EXECUTE`;
activation validates effective permissions. No automatic object grants, direct DML,
ownership, role assumption, schema/database/role creation, RLS bypass, grant options,
or cross-schema/database authority are permitted. Consumers review definer function
safety and own business acceptance. This is not a general SQL API.

### Protected credential installation and recovery

Register the exact application target, use the separate migrator to apply reviewed grants,
then activate through the guarded application-login lifecycle. Activation and rotation
save a candidate and operation record in protected storage outside checkouts before
submitting it, bind the request to target/operation/prior generation, authenticate over
the fixed tunnel, acknowledge the generation, then atomically install the profile.

Retain owned `0700` directories and regular `0600` service/pass/binding files, including
`pending/` and versioned generations. Reject symlinks, unsafe ownership/modes, mismatched
targets, inline passwords, and implicit overwrite. Ambiguous failure reuses the same
command and directory with its retained candidate; never delete `pending/` to force a new
operation. Missing candidate material needs separately confirmed new rotation. Credentials
cannot enter arguments, output, errors, saved executions, or repository artifacts.

### Private connection and migration boundary

`mise exec -- just kube automation-data-connect <domain> application/<application>`
selects an enrolled protected profile, repeats metadata/file checks, validates session
identity, and holds a loopback-only tunnel to the fixed PostgreSQL Pod. It supports no
arbitrary target, address, SQL, Secret read, exec, workload mutation, public exposure,
or administrator fallback. Tunnel teardown is required on interruption, child exit,
or target replacement. Connectivity does not authorize consumer queries or migrations.

Migration uses the distinct `<domain> migrator` identity and an explicitly retained
migrator profile. Missing material requires separately authorized targeted domain rotation,
backup/binding checks, and protected delivery; onboarding neither exports it from n8n
nor rotates it automatically. Enroll an existing profile with the guarded
`automation-data-login-enroll-migrator` helper; an old/lost binding cannot simply be
relabeled current. Client files and generation markers are recovery roots separate from
PostgreSQL verifiers. [Lifecycle source](../../scripts/operations/automation-data-login.py)
and [connection source](../../scripts/operations/automation-data-connect.py) own exact inputs.

## Credential discovery for approved work

Discovery is the primary task-access interface; credential availability and task authority
remain separate. Authorized routine agents use supported helpers with enrolled access
without password handoffs. UI accounts, database sources, application/runtime/migrator
roles, API/header credentials, and recovery identities retain distinct purposes.

Start with `mise exec -- just kube automation-data-credentials list` or `resolve` for
the intended domain and purpose. `ready` permits using the typed helper/binding under
existing authority; `setup_required` names enrollment/grants, `recovery_required` preserves
pending material for lifecycle recovery, `unavailable` means observation failed, and
`inconsistent` blocks automatic selection. Never execute remote text as shell code,
search for another credential, or broaden authority. Missing access follows its named
prerequisite. The [CLI](../../scripts/operations/automation-data-credentials.py) owns syntax.

A private authenticated inventory workflow uses independent restricted SQL projections
of registry/role, NocoDB identity, and published n8n binding metadata. Readers cannot
access business records, credential payloads, password verifiers, or mutation functions.
Fixed projections reject arbitrary SQL/destinations and fail on unsupported schemas,
without raw-table/API fallback. Disable persistence and keep the webhook private.

Enumerate independently of registration before joining retained identities. Detect missing,
duplicate, unregistered, and inconsistent objects without adopting or repairing them.
Bound time, objects, and bytes; overflow never reports complete truncated data. Read-only
repeatable-read observations with statement deadlines and double fingerprints establish
metadata stability, not a distributed snapshot. Partial, stale, future, changing, or
unavailable observations cannot establish readiness or absence. Unknown facts stay unknown.
Metrics expose bounded counts/freshness, not identifiers or credential paths.

Local selection reads binding metadata/file properties without opening consumer passwords.
Automatic access requires a current acknowledged application generation or migrator
credential ID/update marker. Unbound, stale, and pending profiles cannot be selected.
Only the connection helper consumes the selected password and proves authentication.
Lifecycle readback is independent of mutation success: retry observation after readback
failure, never repeat a successful mutation. Removal receipts alone do not prove absence.

### Private credential-discovery installation

Installation is separately authorized administration on clean deployed main after both
n8n and NocoDB initialize. The guarded `automation-data-discovery-install` workflow
preserves existing access/profiles, creates restricted readers and retained discovery
credentials using cluster-held encryption, and imports one unpublished inventory graph.
Select the native project using the existing provisioner's owner-project metadata;
colliding names/IDs stop rather than overwrite. Publish the returned workflow privately,
then run its `finalize` phase for independent acceptance. Existing consumers are not
implicitly enrolled and their passwords are never exported.

Retain protected installer `pending/` records until acceptance. Reruns retain reader
passwords; uncertain creation needs attended reconciliation rather than receipt deletion
or repeated imports. Remove any enrollment-only API-key file afterward.

### Upgrade existing mutation workflows

Upgrade mutation graphs on their same retained IDs: save protected rollback graph/bindings,
unpublish, drain executions, replace from the reviewed template, and rebind original SQL,
API, and webhook credentials. Bind **Automation Data Inventory Header** only to
**Observe Mutation Inventory**, enable that node, verify disabled persistence, and publish.
Require target-specific observed readback during authorized lifecycle acceptance.
A ConfigMap/template update does not update a live graph. Rollback restores retained
bindings on that same workflow rather than publishing duplicate webhook paths.

For header/reader replacement, deactivate and drain inventory, confirm retained targets,
revoke only the selected identity, prepare protected replacement material, update bindings
and local access, and repeat acceptance before republishing. For service outage, restore
n8n/key and database/verifier state first; lost private installer records require attended
reconciliation. Do not widen readers or extract unrelated consumer credentials.

## Monitoring and validation boundaries

The stable Automation Data Canary performs only a bounded identity read using its dedicated
runtime credential through authenticated n8n. Gatus has no direct PostgreSQL credential
or policy path. This proves one n8n-to-database chain, not all consumer behavior.
Prometheus/Grafana cover storage, resources, backups, catalog consistency, and stuck
operations. Terminal errors remain diagnosable without running active-operation timers.
Detached idle backup volumes can have unknown robustness; verify claim identity and
scheduling rather than equating that state with active-data loss.

CI protects source/function contracts and secret-safe backup publication without launching
live databases. Scoped verification observes service, storage, monitoring, and discovery
evidence separately. Registered live tests prove authentication, permission denials,
unchanged reconciliation, targeted rotation, recovery fidelity, and cleanup.
Local/disposable evidence cannot establish deployed access or replace hosted validation.
Revisit the topology for measured load, scale, failover needs, or tighter recovery goals.
