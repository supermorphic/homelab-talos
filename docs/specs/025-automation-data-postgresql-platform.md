# Automation Data PostgreSQL Platform

## Purpose

Implement the reusable PostgreSQL service requested by
[issue 317](https://github.com/supermorphic/homelab-talos/issues/317). The service stores
durable relational state owned by n8n automation domains. It is separate from the
dedicated PostgreSQL instance that stores n8n runtime state.

This specification defines the platform once. After initial bootstrap, adding an
automation-data domain, private repository integration, or workflow-owned database and
schema state does not require a `homelab-talos` change. n8n creates domain databases,
roles, grants, and credentials dynamically through one private provisioning workflow.

The recovery capability described here does not exist until issue 317 is implemented and
the complete restore drill passes.

## Existing platform context

The cluster already runs a dedicated native PostgreSQL StatefulSet for n8n. That package
establishes the repository baseline for a pinned PostgreSQL image, retained Longhorn data
and logical-backup claims, a private ClusterIP Service, a daily validated `pg_dump`, SQL
Exporter, a ServiceMonitor, Prometheus alerts, a Grafana dashboard, scoped Cilium policy,
and an isolated restore drill.

The n8n database remains dedicated to n8n workflows, users, credential ciphertext,
settings, and execution history. It is not a shared application database. The new
`automation-data` service generalizes the operational PostgreSQL pattern without sharing
the n8n database, volume, credentials, backup artifacts, or restore lifecycle.

Longhorn supplies replicated `ReadWriteOnce` storage with daily snapshots and off-cluster
NAS backups. SOPS-encrypted Secret manifests remain recoverable only with the
operator-held age identity. The operator also retains access to the off-cluster backup
target.

## Goals

- Reconcile one private automation-data PostgreSQL service through Flux.
- Let a dedicated n8n workflow create and reconcile domain databases, schemas, roles,
  grants, and encrypted n8n credentials without repository changes.
- Give each domain a stable ownership role, a DDL-capable migration login, and a separate
  CRUD-only runtime login.
- Keep the platform provisioning credential and n8n credential-management API key away
  from normal workflows.
- Preserve all dynamically created databases, database objects, grants, global roles,
  memberships, and role password verifiers in validated logical backup bundles.
- Prove that restored n8n credentials can authenticate to a separately restored
  automation-data instance without plaintext domain-password escrow.
- Reuse the established n8n PostgreSQL deployment, storage, backup, monitoring, policy,
  and testing patterns where the multi-database platform does not require a difference.
- Keep merge-gating validation fast, cluster-independent, non-duplicated, and
  proportional to the unique pre-merge evidence it provides.

## Non-goals

- Moving n8n runtime state into automation-data PostgreSQL.
- Declaring domain databases, schemas, roles, grants, or credentials through Flux, SOPS,
  or a Git-managed domain list.
- A PostgreSQL operator, database replica, automatic failover, connection pooler, or
  externally reachable database endpoint.
- Redis, Valkey, Supabase, TimescaleDB, InfluxDB, MongoDB, or another data service.
- Automatic destructive database or role decommissioning.
- Zero recovery-point loss, a fixed recovery-time objective, or transactionally
  synchronized snapshots across independent domain databases.
- Running PostgreSQL, n8n, containerized integration environments, logical dumps, or
  restore drills in merge-gating CI.

## Governing invariants

### No per-domain infrastructure change

Adding an automation-data domain, private repository integration, or workflow-owned
database and schema state **must not** require a `homelab-talos` change. Domain instances
are runtime data created through the provisioning workflow. `homelab-talos` changes are
reserved for automation-data platform changes and other cluster-level changes, including
public network exposure.

This qualification preserves the existing n8n public-edge contract. A workflow that
needs a new Internet webhook route still requires a reviewed Git-managed HTTPRoute even
though its database state does not require an infrastructure change.

### Recovery roots, not plaintext domain passwords

Individual domain plaintext passwords are not operator-held recovery roots. Recovery
depends on:

- the operator-held SOPS age private key;
- access to the off-cluster Longhorn backup target;
- Git history containing the encrypted bootstrap and recovery Secrets;
- the retained `N8N_ENCRYPTION_KEY`; and
- validated n8n and automation-data backup artifacts.

The n8n logical backup preserves encrypted PostgreSQL credentials. The retained n8n
encryption key makes those credentials readable after n8n restore. The automation-data
globals dump preserves the matching PostgreSQL role password verifiers. A successful
restore must prove that these two restored sides authenticate without recovering or
displaying a domain plaintext password.

### CI runtime

Issue 317 follows the CI-runtime objectives of
[issue 303](https://github.com/supermorphic/homelab-talos/issues/303) and
[specification 024](024-ci-runtime-and-merge-throughput-optimization.md). Merge-gating CI
adds only the minimum validation needed to detect repository or configuration regressions
before merge. A new check must provide unique, essential pre-merge evidence that cannot
be obtained more cheaply.

New checks reuse existing repository-wide manifest, Flux, security, Secret-handling,
ShellCheck, formatting, and gitleaks validation. They avoid duplicate evidence and remain
path-aware where correctness permits. Expensive behavioral proofs remain attended live
acceptance unless later evidence shows that they are necessary as merge gates.

The decisive issue-317 proof is the attended full-chain restore drill. `mise exec -- just
ci` proves that the candidate repository is safe and internally coherent enough to
deploy; it does not reproduce the restore drill.

## Selected architecture

The implementation adds an `automation-data` namespace and Flux domain:

```text
private operator
      |
      v
dedicated n8n provisioning workflow
      |-- automation-data provisioner credential
      |-- full-access Community-edition n8n API key
      |
      +--> automation-data-postgresql.automation-data.svc.cluster.local
      |       |-- platform control database
      |       |-- dynamically created domain databases
      |       |-- stable ownership and privilege roles
      |       `-- versioned backup bundles
      |
      `--> local n8n credential API
              `-- encrypted migrator and runtime credentials

normal n8n workflow
      `-- one domain runtime credential --> one domain database
```

The Flux package owns only platform resources:

- the namespace and Flux Kustomizations;
- one PostgreSQL StatefulSet and private Service;
- retained data and logical-backup claims;
- bootstrap SQL and the platform control schema;
- SOPS-encrypted platform credentials;
- the backup CronJob and scripts;
- SQL Exporter and ServiceMonitor;
- workload-scoped Cilium policy; and
- one secret-free provisioning workflow template.

The established monitoring packages own the related PrometheusRule and dashboard.
Domain-specific objects never appear in these resources.

## PostgreSQL runtime

PostgreSQL runs as one StatefulSet replica. The initial implementation uses the same
`postgres:17.11-alpine3.24` and `burningalchemist/sql_exporter:0.24.6` pins as the current
n8n PostgreSQL service. It also reuses the n8n baseline for probes, non-root security
contexts, read-only root filesystems, resource requests and limits, stable service
identity, and pre-created prune-protected Longhorn claims.

The StatefulSet supplies stable identity and ordered startup, not database high
availability. Longhorn handles ordinary pod and single-node failure. Logical bundles and
off-cluster Longhorn backups handle loss of the volume set. Recovery remains manual and
has a 24-hour off-cluster recovery-point objective with no fixed recovery-time objective.

The service has no HTTPRoute, LoadBalancer, or NodePort. PostgreSQL major-version changes
require an explicit migration design and restore evidence. They are not ordinary image
updates.

The platform bootstrap creates a control database containing the
`platform_operations.managed_domains` registry and operational backup state. This
database is platform runtime state and is included in every logical backup bundle.

## Authority model

The platform has three operator-visible authority levels.

### Platform provisioning

The dedicated provisioning workflow uses a PostgreSQL login with the create-database and
role-management authority needed to create and reconcile domains. It also uses an n8n API
key to create, find, update, and test n8n PostgreSQL credentials.

The deployed chart has `license.enabled: false` and runs the self-hosted Community
edition. n8n 2.36.7 supports API-key authentication and credential API operations, but
n8n's documented narrow API-key scopes are an Enterprise feature. A Community-edition
API key has the full resources and capabilities of its owning account. The implementation
therefore treats this as a full-access n8n API key, not a credential-only key. The
workflow uses only credential create, list, read, update, and test behavior, but that is a
workflow contract rather than an enforceable key boundary.

The PostgreSQL provisioner and full-access n8n API credentials are referenced only by the
dedicated private provisioning workflow. Normal domain workflows are configured only
with their domain migrator or runtime credential. The design does not claim that n8n
supplies a workflow-level cryptographic boundary around credentials available to the
same authorized n8n project operator. A compromise of the n8n API key can affect the
complete n8n account as well as automation-data credentials. Private UI access, encrypted
credential storage, local-only API calls, disabled execution persistence, and key
rotation reduce exposure but do not reduce that authority.

PostgreSQL cannot grant general database and role creation while cryptographically
preventing every destructive statement available through related ownership authority.
The platform therefore does not claim that the underlying provisioner credential is
non-destructive. Its safety boundary combines a fixed workflow operation contract,
private n8n access, no arbitrary platform SQL input, credential isolation, strict target
validation, disabled execution-data persistence, network policy, audit metadata, and a
separate attended decommission boundary.

Compromise of the PostgreSQL provisioning credential can affect every automation-data
domain, and compromise of the n8n API key can affect the full n8n account. These are
accepted residual risks of using the direct n8n provisioning approach instead of a
separate broker or PostgreSQL operator. If a later licensed n8n edition enables scoped
keys, the key should be reduced to the exact credential scopes after live verification.

### Domain migration

Each domain has a scoped migration login for reviewed schema changes. A migration
workflow may create, alter, or drop objects inside its own database. It cannot manage
cluster roles or connect to another domain database.

### Domain runtime

Each normal workflow uses a CRUD-only login for one database. It cannot change schema,
assume the owner role, manage roles, or connect to another domain database.

## Domain role and grant model

A valid domain identifier uses a strict lowercase PostgreSQL-safe format and leaves room
for deterministic suffixes within PostgreSQL's identifier limit. One provisioning
request creates or reconciles:

| Object | Form | Purpose |
| --- | --- | --- |
| database | `<domain>` | Isolate one automation domain |
| owner role | `<domain>_owner` | Stable `NOLOGIN` owner for database and schema objects |
| migrator role | `<domain>_migrator` | Scoped `LOGIN` for reviewed DDL |
| runtime role | `<domain>_runtime` | Scoped `LOGIN` for application CRUD |
| initial schema | `app` | Stable application schema owned by the owner role |
| migrator credential | `automation-data/<domain>/migrator` | Encrypted n8n PostgreSQL credential |
| runtime credential | `automation-data/<domain>/runtime` | Encrypted n8n PostgreSQL credential |

The migrator may explicitly `SET ROLE <domain>_owner` for a migration, but does not
inherit owner authority automatically. Objects created during migrations remain owned by
the stable `NOLOGIN` role across login-password rotation.

The runtime role receives `CONNECT` only to its database, `USAGE` on approved application
schemas, CRUD privileges on current tables and sequences, and matching default
privileges for later owner-created objects. `PUBLIC` does not retain database-connect or
schema-create authority that bypasses this model. `PUBLIC` also has no `CONNECT` authority
on the platform control database. Domain owner, migrator, and runtime roles cannot connect
to that database.

The platform creates both n8n credentials automatically. It never returns a generated
password to the operator. Domain credentials are stored only as PostgreSQL password
verifiers and n8n ciphertext.

## Provisioning workflow

The secret-free workflow template is imported into the private n8n instance during
platform bootstrap. Flux does not manage the live workflow or later domain workflows.
The operator binds the PostgreSQL provisioning credential and full-access n8n API key
once.

The workflow accepts structured domain identifiers and supported operations. It does not
accept arbitrary platform SQL. Provisioning follows an idempotent state machine:

1. Validate and canonicalize the domain identifier and requested operation.
2. Create or reconcile a registry row in `provisioning` state.
3. Compare the registry record with PostgreSQL catalogs.
4. Create or reconcile the owner, migrator, and runtime roles.
5. Create or reconcile the database, initial schema, grants, and default privileges.
6. For initial creation only, generate migrator and runtime passwords and create the
   corresponding encrypted n8n credentials through n8n's local API.
7. For an existing `ready` domain, retain both PostgreSQL password verifiers and both n8n
   credential objects unchanged.
8. Test authentication and verify the expected privilege matrix.
9. Mark the registry record `ready` only after every required check succeeds.
10. Return only non-secret object identifiers and validation results.

Generated passwords necessarily exist transiently in workflow memory while PostgreSQL
and n8n receive them. The workflow disables saved manual, successful, and failed
execution data. Secret-bearing intermediate values do not appear in final outputs or
logs.

Provisioning never compensates for failure by dropping resources. A partial initial
creation remains visible as `provisioning` or `error`. Its retry may generate replacement
credentials while the domain has never reached `ready`, because no completed credential
contract exists yet. Once a domain reaches `ready`, ordinary provisioning and structural
reconciliation never alter role passwords, rotate credentials, replace credential IDs,
or update credential ciphertext. Missing login roles or n8n credentials on a `ready`
domain are errors that require the explicit credential-repair or rotation operation;
ordinary reconciliation does not silently replace them.

Credential rotation is an explicit operation separate from provision or reconcile. It
changes one scoped login and its existing n8n credential, tests the result, and records
completion. Rotation is convergent but not a distributed transaction. An interruption
between the PostgreSQL and n8n updates can temporarily break that credential. Retrying
generates another password and brings both sides back into agreement. The provisioning
credential remains the recovery authority, so the absent plaintext password does not
strand the domain.

## Destructive operations

The provisioning workflow does not expose `DROP DATABASE`, `DROP ROLE`, destructive
schema replacement, or bulk data deletion. A domain migration workflow may perform
reviewed destructive DDL, including `DROP TABLE`, inside its own database.

Database and role deletion remains an attended administrative/decommission action. A
future decommission workflow must require an explicit target, current existence and
ownership validation, a fresh validated backup, and attended execution. It is not part
of normal self-service provisioning.

## Network policy

Cilium policy is workload-scoped, not domain-scoped:

- PostgreSQL accepts database connections from the n8n workload and backup workload.
- Prometheus reaches only SQL Exporter's metrics port.
- SQL Exporter reaches PostgreSQL through localhost.
- The backup workload reaches cluster DNS and PostgreSQL but has no general Internet
  access.
- Temporary restore workloads receive exact run-labeled policies only for the drill.

The existing n8n policy gains one stable egress path to the automation-data Service.
PostgreSQL roles enforce per-domain isolation because Cilium cannot distinguish workflows
inside one n8n pod. Adding a domain does not require a NetworkPolicy change.

## Persistence and logical backup

The initial retained Longhorn claims follow the n8n PostgreSQL baseline:

| Purpose | Size | Access | Protection |
| --- | ---: | --- | --- |
| PostgreSQL data | 20 GiB | Longhorn `ReadWriteOnce` | Flux prune disabled |
| logical backup bundles | 20 GiB | Longhorn `ReadWriteOnce` | Flux prune disabled |

The established 70% warning and 85% critical storage alerts drive expansion from
measured use. Routine Flux pruning does not delete either claim, but deliberate namespace
or PVC deletion and storage-system loss remain destructive operations covered by the
off-cluster backups and recovery procedure.

The daily backup CronJob runs before the established Longhorn snapshot and off-cluster
backup windows. It uses a dedicated SOPS-managed credential isolated to the Job.
Preserving global roles and password verifiers requires broader protected-catalog access
than the n8n single-database backup role; that authority is never available to n8n
workflows.

At the start of one run, the backup job reads the PostgreSQL database catalog and the
runtime managed-domain registry. The PostgreSQL catalog is the fail-safe source for the
set of actual non-template databases: an unregistered or partially registered database
is still included rather than silently omitted. The captured manifest also records every
registry row and its state. The set is never read from Git.

Active provisioning coordinates with backup through platform operation state and a
bounded stability check. The backup captures the catalog and registry generation before
dumping and checks them again before publication. A concurrent set change causes a
bounded retry rather than publication against an ambiguous set. The backup waits only a
bounded interval for a currently progressing operation; after that interval it captures
the recoverable state that actually exists. A stable `error`, stale `provisioning`, or
other incomplete registry record does not indefinitely block backup publication for
healthy domains. If that record has a database, the database is dumped with the captured
set; if it has no database yet, its recoverable metadata is preserved in the platform
control database and any created roles are preserved in the globals dump.
Registry/catalog disagreement remains an alerting and repair condition, not an automatic
reason to discard an otherwise complete recoverable bundle.

One successful backup performs these steps:

1. Create a temporary bundle directory on the backup claim.
2. Run `pg_dumpall --globals-only` for cluster-global roles, memberships, role password
   verifiers, tablespaces, and related global state.
3. Never pass `--no-role-passwords`.
4. Run one custom-format `pg_dump` for the platform control database and every domain
   database in the captured set.
5. Preserve each database's schema, ownership, ACLs and grants, and data in its individual
   dump.
6. Inspect every database archive with `pg_restore`, calculate checksums for every
   artifact, and write a manifest containing the captured set and artifact metadata.
7. Re-read the catalog and registry generation; retry the run when the captured database
   set changed during backup.
8. Rename the complete bundle to its final name on the same filesystem.
9. Recheck the published artifacts and update the operational freshness row only after
   final validation.
10. Retain the newest seven complete bundles and remove incomplete temporary artifacts.

The bundle is the retention and recovery unit. Individual files are never considered
healthy or pruned independently. A Kubernetes Job success is diagnostic evidence, not
the backup-freshness oracle.

Separate `pg_dump` snapshots are not transactionally synchronized across databases. The
manifest records their times. This is acceptable because domains do not share
transactions and the off-cluster recovery-point objective is 24 hours.

## Recovery

The recovery runbook distinguishes routine pod rescheduling, Longhorn volume recovery,
logical bundle restore, and full cluster reconstruction. Logical restoration uses an
isolated destination first and never overwrites the running service as its first step.

The attended full-chain restore drill:

1. Selects a complete bundle and validates every checksum.
2. Starts an isolated empty automation-data PostgreSQL instance using the pinned image.
3. Restores globals first, including role memberships and password verifiers.
4. Restores the platform control database and every domain database from the manifest.
5. Verifies that the registry, PostgreSQL catalog, ownership, grants, and restored
   database set agree.
6. Restores the n8n database into an isolated n8n recovery instance with the retained
   `N8N_ENCRYPTION_KEY`.
7. Redirects only that temporary n8n instance's automation-data hostname to the isolated
   restored PostgreSQL Service.
8. Uses n8n's credential-testing path to prove that restored migrator and runtime
   credentials authenticate without revealing their passwords.
9. Proves that migrator and runtime permissions remain separated.
10. Creates and validates a fresh logical bundle from the restored instance.
11. Removes and proves absence of all run-owned workloads, policies, Services, and
    storage.

This drill is the independent recovery oracle. Artifact creation, `pg_restore --list`,
checksums, Longhorn replica health, and retained Secrets do not independently prove the
complete chain.

The globals dump contains password verifiers and remains sensitive even though it does
not contain plaintext passwords. Repository files, CI output, test evidence, logs, and
metrics never publish its contents.

## Monitoring and alerts

Monitoring copies the current n8n PostgreSQL pattern and adds only evidence required by
dynamic provisioning.

SQL Exporter reports the existing PostgreSQL signals with a database label where needed:

- connections;
- committed and rolled-back transactions;
- database size; and
- last successful logical-backup time.

It adds two platform-health signals:

- registry/catalog consistency; and
- age of the oldest incomplete provisioning operation.

PrometheusRules cover unavailable scrape and StatefulSet targets, repeated restarts and
OOM kills, stale or absent logical backups, failed or overdue backup Jobs, the two
platform-health signals, and the established PVC warning and critical thresholds. The
initial design does not add speculative connection-pressure alerts or redundant
domain-count and bundle-count metrics.

The Grafana dashboard generalizes the n8n PostgreSQL panels for database-labeled resource
use, transactions, connections, storage growth, backup freshness, and provisioning
health.

## Capacity

The initial workload reuses the measured n8n PostgreSQL resource baseline:

| Workload | CPU request / limit | Memory request / limit |
| --- | ---: | ---: |
| PostgreSQL | 50m / none | 256 MiB / 1 GiB |
| SQL Exporter | 10m / none | 32 MiB / 128 MiB |
| logical-backup Job | 50m / none | 64 MiB / 512 MiB |

The absence of CPU limits lets dumps, maintenance, and migrations finish without
artificial throttling. Database growth, dump growth, memory use, and connection counts are
reviewed after representative automation traffic. Measurements and alerts determine
later resizing or topology changes.

## Rollout

Rollout follows dependency order:

1. Add the namespace, PostgreSQL package, retained claims, Service, policy, backup
   workflow, exporter, monitoring, guarded Secret workflow, and secret-free provisioning
   template.
2. Run cluster-independent validation through `mise exec -- just ci`.
3. Have the operator create the separate SOPS-encrypted automation-data credentials
   through the guarded repository workflow.
4. Reconcile PostgreSQL through Flux and verify storage, workload, exporter, and backup
   target health.
5. Import the provisioning template into private n8n and bind its PostgreSQL provisioner
   and full-access Community-edition n8n API credentials.
6. Provision a runtime acceptance domain through the workflow. It is not declared in
   Git.
7. Run provisioning, permission, rotation, persistence, backup, and recovery acceptance.
8. Reconcile this specification and the recovery runbook with the validated result.

Credential creation, initial workflow bootstrap, and live mutation that requires
operator authority remain attended operator actions. Agent-owned repository work and
approved scoped verification proceed through the repository workflows without asking the
operator to perform them.

## Validation strategy

### Cluster-independent merge gate

`mise exec -- just ci` remains the canonical cluster-independent, secret-free gate. Issue
317 does not materially expand its runtime unless a measured new check supplies unique,
essential pre-merge evidence that cannot be supplied more cheaply.

The candidate reuses existing checks for YAML and Kustomize structure, Flux wiring,
Kubernetes schemas, security contexts, Secret shape and ciphertext, shell quality,
repository policy, links, and gitleaks. Focused issue-317 validation is limited to new
contracts that those checks do not cover:

- the absence of domain-specific Git configuration;
- deterministic role and grant templates;
- the provisioning workflow's fixed operation surface and absence of destructive
  database or role operations;
- ordinary reconciliation's prohibition on password or n8n credential changes;
- runtime backup discovery rather than a Git-managed database list;
- recoverable backup publication when a stable incomplete or error record exists;
- exact `pg_dumpall --globals-only` use and absence of `--no-role-passwords`;
- atomic bundle publication and freshness ordering; and
- the two approved monitoring signals.

New provisioning and backup logic is tested at the cheapest layer that provides an
independent oracle. For example, a synthetic filesystem fixture proves that an incomplete
bundle cannot advance freshness without starting PostgreSQL or executing a dump. Tests do
not repeat an existing repository-wide assertion under an issue-specific name.

Merge-gating CI does not start PostgreSQL or n8n, create containers, provision a domain,
test live database privileges, rotate credentials, generate real dumps, or perform a
restore. Those behaviors belong to attended live acceptance.

### Read-only live verification

The read-only verifier observes Flux readiness, current workload rollouts, Services,
workload-scoped policies, Prometheus targets and rules, backup freshness, and Longhorn
claim health. It does not read Secrets, inspect database contents, invoke n8n credentials,
or mutate workloads.

### Attended live acceptance

Registered attended workflows prove:

1. Flux reconciles the private PostgreSQL service and monitoring resources.
2. n8n provisions a new domain without a repository, SOPS, Flux, or NetworkPolicy
   change.
3. Repeating an unchanged request reconciles the domain without duplication and without
   changing role password verifiers, n8n credential IDs, or n8n credential update state.
4. The owner is `NOLOGIN`, and the migrator can explicitly assume it for reviewed DDL.
5. The migrator can create, alter, and drop a test table only inside its database.
6. The runtime credential performs expected CRUD but cannot perform DDL, assume the owner
   role, manage roles, or access another domain database.
7. Neither the migrator nor runtime role can connect to the platform control database.
8. Credential rotation restores a working n8n connection without operator knowledge of
   the generated password.
9. A stable incomplete or error provisioning record does not prevent a complete backup
   of every actual database in the captured catalog set.
10. A logical backup publishes one complete globals-plus-databases bundle and advances
   freshness only after final validation.
11. The isolated full-chain drill restores n8n with its encryption key, restores
   automation-data globals and databases, and proves restored n8n credentials authenticate
   against restored role password verifiers.
12. The restored instance creates and validates a fresh post-recovery backup.
13. All temporary resources are removed and their absence is verified.

Provisioning, rotation, privilege enforcement, backup generation, and the restore drill
remain live acceptance because static or synthetic CI checks cannot reproduce their
essential evidence. Conversely, live acceptance does not justify duplicating cheap
repository contracts already proved by CI.

## Rejected alternatives

### Internal provisioning service

A private broker could keep generated passwords outside n8n workflow memory and perform
both PostgreSQL and n8n API calls. It would add a custom security-critical API,
authentication protocol, workload, monitoring surface, release lifecycle, and recovery
dependency. The direct dedicated n8n workflow is smaller and meets the accepted trust
model.

### PostgreSQL operator and custom resources

An operator could model databases and roles as Kubernetes resources. It adds another
controller and tends to make consumer creation a Kubernetes or Git control-plane action.
That conflicts with the required self-service data-plane boundary and is not justified by
the current scale.

### Per-domain Git and SOPS resources

Git-managed domain databases, passwords, or NetworkPolicies would give Flux a declarative
record but would require an infrastructure change for every consumer. That directly
violates the primary platform invariant.

### One shared runtime login

One login across domains would simplify credential management but permit broader database
access and make independent rotation impossible. Separate domain credentials are required.

### Self-service database and role deletion

Adding drop operations to the ordinary provisioning workflow would turn input mistakes
or workflow misuse into destructive cluster-wide actions. Decommissioning remains a
separate attended administrative boundary.

## Review triggers

Revisit this design when measured load requires connection pooling, automatic failover,
replicas, point-in-time recovery, a shorter recovery point, or larger claims; when the
number of domains makes direct workflow provisioning or per-database dumps operationally
unwieldy; when n8n credential API behavior changes; or when a dedicated provisioning
broker or PostgreSQL operator becomes simpler than the retained custom lifecycle.

Before merge, reconcile this specification with the implemented PostgreSQL and exporter
versions, actual n8n API scopes and workflow settings, backup artifact format, recovery
runbook, validation commands, and observed live acceptance result.

## External references

- [PostgreSQL 17 `pg_dumpall`](https://www.postgresql.org/docs/17/app-pg-dumpall.html)
- [PostgreSQL 17 SQL dump backup](https://www.postgresql.org/docs/17/backup-dump.html)
- [PostgreSQL 17 database roles](https://www.postgresql.org/docs/17/database-roles.html)
- [n8n API authentication and edition-specific scopes](https://docs.n8n.io/api/authentication/)
- [n8n 2.36.7 credential API](https://github.com/n8n-io/n8n/blob/n8n%402.36.7/packages/cli/src/public-api/v1/handlers/credentials/credentials.handler.ts)
- [n8n workflow automation platform specification](023-n8n-workflow-automation-platform.md)
- [CI runtime and merge-throughput specification](024-ci-runtime-and-merge-throughput-optimization.md)

## Pull request linkage

Every pull request produced by this initiative links
[GitHub issue 317](https://github.com/supermorphic/homelab-talos/issues/317) in its
description. Partial pull requests use `Related to #317`. Only the pull request that
finishes the accepted issue scope uses `Closes #317`.
