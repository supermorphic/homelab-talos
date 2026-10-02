# NocoDB Operator UI for Automation Data

## Purpose and authority boundaries

Provide an optional private UI for automation-domain facts and small human decisions.
PostgreSQL enforces authority; n8n remains the workflow/bulk-change interface and reviewed
migrations own DDL. NocoDB flags mirror grants but cannot authorize a database-denied
operation. Removing NocoDB must leave domains, core credentials, and direct/n8n consumers
usable. Business state cannot depend solely on NocoDB comments, views, or application metadata.

Separate workflow-produced facts from human decisions, notes, corrections, and overrides.
A reader source exposes its mapped read schema; a separate operator source exposes only
its controlled-edit schema. Human corrections are records consumed by workflows, not
updates to source facts. Both surfaces can appear in one base without combining authority.
Human UI membership, source logins, and application/CLI logins are different identities.

NocoDB receives only dedicated reader/operator domain logins and its distinct metadata
identity. It never receives runtime, migrator, owner, provisioner, or backup credentials.
The selected Community API credential has broader authority than ideal source-only scope;
containment depends on private access, fixed operations, and PostgreSQL privileges.

## Deployment and ownership

The [NocoDB package](../../kubernetes/apps/automation-data/nocodb/ks.yaml) owns one
private application pod, route, scoped policy, metadata bootstrap, and Secret references.
The [database platform](026-automation-data-postgresql-platform.md) owns optional roles,
registry, fixed SQL, and backups; n8n owns the secret-free source workflow.
Chart/image pins and runtime configuration live in
[values](../../kubernetes/apps/automation-data/nocodb/app/values.yaml) and source references.
Use reviewed upgrades, not application self-updates.

Use one `Recreate` application instance with disposable scratch and external PostgreSQL.
Workers, Redis, application HA, and native persistent attachments are outside this design.
Source creation uses the Community fallback queue: queue history is not assumed durable,
and accepted creation must be distinguished from a ready source.
Private routing and Cilium admit only the internal Gateway, fixed n8n API calls, designated
health checks, DNS, and automation-data PostgreSQL. Namespace co-location grants no broad
access. No general Internet ingress/egress is needed.

The metadata database is separate from managed domains. Its login owns/migrates only
metadata and cannot connect to domain/control databases; source roles cannot connect to
metadata. Catalog-derived backup includes metadata even though it is not a managed domain.

## Domain opt-in and grants

Ordinary provisioning adds no NocoDB dependency. Explicit preparation creates restricted
`NOLOGIN` grant candidates without creating a base/source. Sync activates eligible access;
operator access waits for reviewed grants. Per-domain adoption changes runtime state,
not infrastructure manifests or Secrets.

Default reader access uses `read_model`; operator access uses `operator`. Custom immutable
mappings select one reader schema and an optional distinct operator schema. Configure
before preparation/registration. Identical retries verify the mapping; changed mappings
or lifecycle overrides are rejected. Consumer migrations supply custom schemas, CONNECT,
object/default grants, and required PUBLIC restrictions. Preparation validates those
grants without rewriting them; the platform does not invent application authority.

Neither login may acquire ownership, role assumption, DDL, grant options, replication,
RLS bypass, cross-database access, or privileges outside its mapped schema. Check effective
PUBLIC/inherited, table/column, sequence, routine, and default authority. Maintenance
and connectable template databases must not bypass isolation. Do not restore PUBLIC
CONNECT as a connectivity workaround.

The standard reader has read-only access and defaults for future read objects; explicitly
mapped readers can expose a useful subset without broad defaults. Operators receive only
reviewed controlled DML, exact update columns, sequences, and row policies. Source logins
cannot call application routines directly; reviewed views and consumer-owned triggers
remain consumer responsibilities. UI data editing is disabled for readers and enabled for
operators; schema editing stays disabled for both. Real database denials are the oracle.

## Independently scoped source pairs

Multiple independent pairs may share one managed database. The reserved `default` pair
preserves existing domain-only behavior and role/credential/source/view identities.
Named pairs register explicit non-overlapping reader/operator schemas and collision-checked
`NOLOGIN` roles; registration supplies no automatic grants. Each pair owns a distinct base
with independent views. Immutable mappings and full bindings, not digest/title equality,
establish identity. [Extension SQL](../../kubernetes/apps/automation-data/postgresql/app/scripts/nocodb-extension.sql)
owns naming and compatibility details.

The reader establishes the canonical base ID shared with that pair's operator. Display
names are editable labels; after registration resolve only retained workspace/base,
integration, and source IDs. A renamed base or another base using the old title cannot
select/recreate the registered source. Before registration, title collisions block creation
without permitting adoption. Sync/rotation preserve unrelated pairs and grants.

### Creation, reconciliation, and interruption

The private workflow takes a registered target and supported operation, not arbitrary
SQL, hosts, credentials, schema overrides, or grants. Preparation stops before password
generation or NocoDB API access. Creating both access kinds completes reader creation
before operator creation. Queue acceptance is not readiness.

Persist operation identity before observing asynchronous creation. Ready requires bound
job completion and independent unique identity, reflection, flags, access, and grant
validation. Timeouts retain `waiting_for_source`; retry the same confirmed sync to resume
observation rather than creating a new generation. Missing historical jobs after readiness
do not invalidate the source; missing jobs before readiness do not authorize replacements.
Lost responses require observation or attended reconciliation. Never adopt/delete/recreate
ambiguous partial objects or clear registry state as automatic compensation.

Ordinary ready sync preserves PostgreSQL verifiers, encrypted source credentials,
generations, and IDs. Missing/mismatched ready-side objects require explicit repair.
Transient passwords cannot enter saved manual/success/failure/progress execution data,
wait state, logs, or outputs. Resumption uses non-secret registry/application evidence.

A persistent claim binds domain, pair, operation, access kind, and generation across
external calls. Competing callers observe it and stale completions fail. Rotation changes
only one selected login and its existing integration, then proves authentication, denials,
and convergence. The two-system change is convergent, not transactional.

### Targeted rotation and attended retry

Use the selected target's status helper to inspect its retained claim and identities.
A partial rotation blocks ordinary sync and the other access kind. Before retry,
independently establish that the predecessor workflow ended and external requests completed
or were cancelled. Timeout, an `uncertain` phase, a stopped client, or elapsed wait is
insufficient. If outcome remains unknown, preserve the claim and stop.

The guarded retry binds the same target to the exact `quiescedOperationId` and its
attended confirmation. Stale IDs, active claims, wrong targets, or missing durable IDs
are rejected. Default pairs follow the same rules. Status grants no mutation authority.
[Command help](../../kubernetes/mod.just) and
[workflow source](../../kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json)
own exact register/prepare/sync/rotate/status/retry inputs and confirmations.

### Domain schema evolution

Reviewed migrations own DDL. After additive changes, validate grants, explicitly refresh
NocoDB metadata, and sync the affected pair. Preserve credentials, IDs, and saved views
whose referenced objects still exist. Incompatible renames/removals require attended review;
refresh cannot silently recreate sources, discard views, or widen grants. In the affected
base, use **Data Sources** → the exact source → **Meta Sync** → **Reload**; inspect the
additive changes before **Sync Now**. Require synchronized table metadata, then rerun
the same source/pair sync and check unchanged identities, generation, flags, and views.
Unexpected renames/removals stop the procedure; confirm labels against the deployed UI.

## Platform upgrade and bootstrap

Empty-directory initialization is not an upgrade for a populated database. Use the reviewed
additive control extension shared with initialization. Validate prior state and installed
function bodies, not only a revision label; reject unknown or partial state. Serialize
changes transactionally and preserve domains, roles, verifiers, IDs, views, and explicit
grants. Deploy backup compatibility first, reject captures spanning changes, retain
prior-format restores, and obtain a new complete backup after upgrade/acceptance.

Before first bootstrap, require accepted automation-data provisioning/restore, a compatible
backup, clean deployed-main parity, private n8n/NocoDB access, authorized administration,
operator age material, and retained connection encryption material. Keep monitoring staged
until activation; a confirmation is an execution guard, not authority.

The guarded bootstrap requires invite-only signup and restricted workspace creation,
then establishes metadata and the NocoDB API credential directly
in n8n without displaying values. A lost API-token response resumes the same bootstrap;
do not create a replacement manually. If bounded retry reports an orphan token ID, verify
the retained n8n credential first, then revoke only that orphan through attended NocoDB
administration. Multiple matching orphans stop bootstrap for review. Preserve metadata
and recovery roots on failure,
reversing only temporary activation owned by that attempt. Never regenerate the encryption
key as compensation. Import the reviewed source graph, bind its named SQL/API/webhook
credentials, verify disabled persistence, and publish privately. Initial discovery-readback
ordering and later graph rebinding follow [spec 026](026-automation-data-postgresql-platform.md#platform-updates-and-bootstrap-ordering).

For adoption, configure any custom mapping first, prepare access, apply consumer-reviewed
grants, sync, and require source/browser acceptance. Default operator adoption needs a
second sync after granting its `NOLOGIN` candidate. Register additional pairs before
applying their grants and syncing. Durable Git activation enrolls private routing,
Homepage, Gatus, alerts, and recurring verification together. Restore acceptance uses
post-acceptance backup state; component/access success alone does not prove recovery.

## External artifacts and recovery

Files belong to workflow/storage owners. PostgreSQL holds durable metadata/references;
NocoDB links to them without ingesting or owning bytes. References cannot depend on
expiring signed URLs or embed reusable credentials. Storage owners control authorization,
retention, recovery, and reference consistency. There is no universal artifact schema.
Local application scratch is not a supported durable-file store; omitting native
attachments does not claim every upload API is disabled.

### Recovery roots and sequence

Retain outside the cluster the operator age identity, exact `NC_CONNECTION_ENCRYPT_KEY`,
encrypted Secret in remote Git history, complete automation-data bundles, backup access,
and private operator accounts. Registered application clients also retain their protected
profiles under [spec 026](026-automation-data-postgresql-platform.md#protected-credential-installation-and-recovery).
Metadata without its matching encryption key cannot recover source passwords; missing
or unreadable key material stops ordinary recovery and needs a separately reviewed design.

1. For an application-only failure with healthy PostgreSQL, allow pod replacement and
   run `mise exec -- just kube nocodb-verify`; disposable scratch needs no restore.
2. For lost/corrupt metadata, preserve state and select a complete compatible bundle.
   Restore globals, control/metadata, and domains into isolated PostgreSQL first.
3. Start isolated NocoDB with retained encryption material and fresh scratch. Redirect
   restored sources only to the isolated database; never connect them to live domains.
4. Prove identity/registry/grant agreement, actual decrypted source authentication and
   denials, retained decisions, views, and artifact references. Revalidate authority;
   saved UI flags do not establish it. Recover external bytes separately with their owner.
5. Generate a fresh validated bundle and prove run-owned cleanup before acceptance.

Use the guarded `mise exec -- just kube nocodb-restore-drill` with approved mutation
credentials and exact confirmation. Source owns selectors/assertions. This proves selected
isolated recovery, not production replacement or Longhorn recovery. Production-state
replacement remains separately authorized. Native attachment support would require a new
decision covering ownership, authority, portability, and full recovery.

## Credential discovery and source evidence

[Shared discovery](026-automation-data-postgresql-platform.md#credential-discovery-for-approved-work)
owns the task interface, installation, observation/access boundary, and readiness decisions.
NocoDB independently enumerates base/integration/source objects and checks retained full
bindings, workspace, editing flags, and enabled/deleted state. Matching titles never prove
ownership; unclassified objects cannot be adopted automatically.

Exclude connection configuration, encrypted payloads, hashes, tokens, personal details,
and free-form descriptions. UI membership is distinct from database grants; a Secret locator
does not prove its content or recovery retention. Off-cluster roots remain `not_observed`.
Legitimate awaiting-grants roles can have no source and stay `NOLOGIN`; the intrinsic local
NocoDB source is not an orphan external integration. Legacy default mappings may be implicit;
named pairs require registration. Completed sync claim generations and retained credential
or source generations are different; active/uncertain claims block readiness.
Published n8n bindings, not drafts, provide consumer evidence. Metadata consistency cannot
prove password equality, authentication, enforcement, or restore success.

## Validation and destructive administration

Source/render checks protect fixed authority, lifecycle, and secret handling. Disposable
pinned-component integration proves interoperability independently of the deployed Gateway,
Cilium, publication, or browser path. Scoped verification observes health, activation, and
backup freshness without Secrets or positive source-authentication probes.
Attended tests prove actual reads/denials, targeted rotation, decision consumption,
reflection, and isolated recovery. Browser tests establish usability, not database security.
Retain only bounded canaries needed for later recovery and prove current-run cleanup.

NocoDB outage does not justify broader database grants. No lifecycle operation deletes
sources, bases, registry rows, domains, or roles. Decommissioning requires a separate reviewed
attended procedure for an exact target, fresh complete backup and matching n8n material,
current owners/consumers, and repeated identity/dependency/concurrency checks before each
step. If interrupted, preserve completed-step evidence and surviving objects; freeze further
deletion for review. One missing object does not establish completion. Validate a fresh
bundle after authorized decommission and keep actionable private details out of public evidence.

Revisit this design for demonstrated HA, attachment, identity, scale, licensing, or
Community-feature needs. Changes to source lifecycle/queue behavior and metadata schemas
require fresh affected evidence. Service and acceptance details are owned by source,
[the catalog](../../tests/catalog.yaml), and retained reports, not historical spec diaries.
