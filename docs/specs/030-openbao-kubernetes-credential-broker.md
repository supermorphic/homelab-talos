# OpenBao Kubernetes credential broker

## Purpose and trust boundary

Issue [449](https://github.com/supermorphic/homelab-talos/issues/449) establishes OpenBao
issuance of short-lived tokens for pre-existing Kubernetes ServiceAccounts. Git/Flux owns
the accounts, roles, and bindings; OpenBao cannot create or broaden their authority.
[Agent profiles](031-openbao-agent-credential-profiles.md) extend this platform separately.
SOPS and Talos recovery remain independent. Static-secret migration, external databases,
PKI issuance, and an off-cluster broker are outside this design.

The operator accepted automatic unseal using a SOPS-managed static seal key. Kubernetes
administrators, seal-Secret readers, node control, and OpenBao process compromise are inside
that trust boundary. SOPS protects Git/recovery ciphertext, not the usable live key from
those principals. Possession of the matching seal key and Raft snapshot permits decryption.
An off-cluster encrypted copy protects recovery availability without changing live authority.

Kubernetes Secret encryption and Talos system-volume encryption protect their respective
at-rest layers, not authorized API reads or the dedicated Longhorn data volume. OpenBao's
storage barrier protects Raft data there. Do not store the seal key on data/snapshot claims.
This design does not rotate cluster encryption keys or assert an audit of historical etcd data.

## Availability and deployment

Use three voting Raft members, one per physical node under required hostname anti-affinity,
with independent retained Longhorn claims. Two voters remain after one node fails;
a two-member cluster tolerates no voter failure and five voters on three nodes do not
solve arbitrary two-node loss. Keep two available during voluntary disruption and restore
all three before another planned disruption. Leader election can briefly interrupt requests.
The budget does not protect direct deletion/hardware failure; shared foundation/two-node
loss is outside availability guarantees. Raft and volume replicas are not backups.

Use the official chart, explicit values, stable pod-based Raft IDs, parallel startup,
initialized/unsealed readiness, automatic certificate reload, and `OnDelete` upgrades.
Disable extra injector/CSI/snapshot/controller privileges and chart-created token/RBAC
resources. One explicit disruption budget and retained claims own lifecycle protections.
Non-root servers require no extra locking capability. Chart/image pins, allocations, and
exact rendering live in [values](../../kubernetes/apps/security/openbao/app/values.yaml)
and [the package](../../kubernetes/apps/security/openbao/ks.yaml).

The Git-owned server ServiceAccount has only exact issuance grants. Disable ordinary
token automount and mount the reviewed issuer credential explicitly. Ready servers share
client routing; OpenBao forwards to its leader without Kubernetes pod-registration RBAC.
TLS/namespace prerequisites, servers, access, backup, acceptance, and monitoring have
separate dependency units. Monitoring is never an issuance dependency.

## Seal and recovery ownership

Retain outside this cluster, without relying on OpenBao-issued access:

- The operator age identity and encrypted Git/off-cluster seal artifacts, including each
  older seal generation still needed by retained snapshots.
- The encrypted initialization recovery bundle and privately usable non-root operator
  login/recovery material associated with each selected snapshot.
- Backup-target access, selected Raft snapshots, and matching recovery records.

Initialization uses single-operator recovery custody: one share with threshold one.
Retaining multiple copies improves recovery retention without creating split custody.
A recovery share authorizes recovery operations but cannot replace a lost seal key.
Keep these materials separate from snapshots and out of arguments, logs, reports, and
repository plaintext. Only the first member is initialized; peers join using the same
seal. Normal replacement unseals retained state automatically. Seal rotation is a separate
attended current/previous-key operation, never incidental Secret regeneration.

## Guarded initialization and repair

For a new installation, create encrypted seal material with the existing guarded writer,
retain its independent encrypted copy, and publish it through review. Stage integrations
inactive and choose a private operator-owned recovery destination outside repositories and
test output. Use clean published/deployed main and explicit operator kubeconfig, public
recovery recipient, and protected credentials. The implementation validates destination
ownership/permissions, rejects collisions/symlinks, and proves durable encrypted delivery.

1. Run `mise exec -- just bootstrap openbao prepare` to review the source/target-bound
   confirmation, then execute with that exact confirmation. It resumes only owned staged
   prerequisites/servers and reports identities; it never initializes.
2. Run `mise exec -- just bootstrap openbao initialize` to review the distinct live-target
   confirmation, then execute it once. Recheck all three endpoints uninitialized, exact
   workload/claim/seal/TLS identities, and recovery delivery immediately before the request.
3. Encrypt/atomically retain the initialization response directly without plaintext files,
   wait for one cluster/leader and three voters, and install source-owned configuration
   with declarative audit enabled. Prove a separate retained operator login works before
   revoking the initial root token and verifying rejection.
4. Complete issuance, HA, selected-snapshot restore/cleanup, and observer acceptance before
   durable Git activation of routing/monitoring.

Initialization sends one bounded POST without automatic HTTP retries. A lost response or
ambiguous recovery delivery stops; preserve Pods, claims, and material. Do not retry
initialization, initialize another member, uninstall, reset claims, or regenerate the seal
as repair. Initialization success is distinct from Helm installation/readiness.

With a retained initialization bundle but incomplete configuration, use the guarded
`openbao-config-apply` repair with its retained root-token path, then
`bootstrap openbao finalize`. Finalize verifies configuration/audit and independent operator
login/policy before revoking root. It performs no initialization/reset/config writes;
lost revocation acknowledgement is resolved by denied lookup, not blind repeated writes.

A reviewed staged server correction can use `bootstrap openbao restart-staged` before
integrations activate. It replaces one standby at a time before the leader using current
identity/eviction/quorum guards. An unused staged installation with no retained recovery
bundle can be reset only through separately authorized `bootstrap openbao-reset-staged`:
all units suspended, exact server/claim identities, no extra workload/route, and empty
recovery destination. It waits for servers gone before deleting exact claims. This is
neither a production restore nor permission to retry uncertain initialization.

## Authentication and declarative issuance

The retained non-root operator uses a source-owned operational policy and short-lived
session, not routine root access. In-cluster backup/acceptance/reader identities use
bounded audience-specific projected JWTs and exact namespace/ServiceAccount subjects.
JWT verification can outlive Pod/account deletion until expiry, so bound OpenBao sessions
as well. The JWT issuer, login audience, and issued Kubernetes API audience are distinct;
service DNS is transport, not proof of the API audience.

[Desired configuration](../../kubernetes/apps/security/openbao/config/desired.json)
and policy source define exact mounts, roles, audiences, TTLs, and issuer permissions.
Changes are reviewed Git inputs applied through attended `openbao-config-apply` after
source parity and drift review. Established apply privately logs in with the operator
password (`OPENBAO_CONFIG_AUTH=userpass`), checks its policy, and revokes the session on exit.
Bootstrap repair uses the retained root path only while needed. No privileged reconciler
or second configuration source is added.

The issuer may create tokens only for exact named ServiceAccounts in their namespaces.
It receives no account/RBAC management, wildcard TokenRequests, impersonation, binding,
escalation, or Secret reads. Acceptance must perform real negative TokenRequests;
static policy or `can-i` alone cannot prove named-subresource enforcement.
Consumer issuance has a ten-minute maximum. Validate actual identity, audience, and
expiration. Kubernetes determines effective lifetime;
OpenBao lease revocation does not individually revoke an existing ServiceAccount JWT.

### Read-only configuration drift detection

A healthy endpoint or stored source hash does not prove live API configuration matches Git.
A separate restricted reader independently compares actual read/list responses against
source-owned inventories, including its own policy/auth role, operator policy assignment,
mount tuning, JWT constraints, issuer settings, and issuance roles. Missing objects and
unexpected additions fail; built-ins are explicit exceptions, not prefix-wide ignores.
No secret/password values unavailable through APIs can be claimed comparable.

The reader has no Kubernetes grants/default token, server filesystem, seal/issuer mount,
issuance, snapshot, or configuration-write permission. Verified peer TLS and short-lived
self-revoked sessions deliver only fixed sanitized Prometheus observations. Source/config
changes replace its hashed inputs. It reports failure but never repairs configuration,
seals servers, or disables issuance.

The local observer verifier independently checks clean/deployed revision parity, desired
configuration/reader digest, complete single-scrape inventory, and bounded scrape/collection
freshness. Old successful observations cannot be refreshed by scraping them again. Missing,
duplicate, stale, inaccessible, malformed, or mismatched evidence fails. Normalize only
reviewed defaults, durations, set order, and volatile metadata; malformed policy syntax or
unknown security fields cannot be skipped. Output only source-known identifiers, field
names, and fixed difference classes; unexpected names become counts, never raw server
strings/policy bodies/errors/credentials.

Scoped diagnostic bindings do not admit OpenBao exec or port-forward. This does not promise
host isolation from privileged diagnostic workflows; named-workflow policy still applies.
Actual scoped POST/GET exec denials belong in attended acceptance.

### Stable issuer credential lifecycle

The reviewed official Kubernetes secrets engine caches an issuer client with its bearer
value before rereading the projected token file. Projected-token expiry can therefore break
issuance; a longer projection lifetime only postpones failure. Reapplying identical
`kubernetes/config` clears that cache temporarily, while ordinary no-difference apply skips
it. Do not report that temporary repair as sustained recovery or downgrade to an unproved fix.

The operator-approved compatibility exception is a manually declared ServiceAccount token
Secret generated by Kubernetes, mounted read-only for the existing issuer. It has no automatic
expiry and must not be added to `ServiceAccount.secrets`, which would expose it to legacy
idle-token cleanup. The longer lifetime is an accepted trust-boundary tradeoff; consumer
credentials stay short-lived and other jobs keep bounded projections. Agents cannot read
or exec to obtain this token. The attended probe emits only bounded claims/API results.

For planned rotation, add a new numbered Secret generation and update its mount through Git;
retain the old generation until adoption and issuance acceptance pass. Do not replace token
bytes in place because cached clients can retain them. After Secret/account loss or signing-
key changes, publish a new generation even if the old name was recreated. It is not a
recovery root or Raft-restored credential. Suspected compromise requires an operator-approved
containment/revocation decision; availability does not justify preserving a compromised token.

Run `mise exec -- just kube openbao-issuer-rollout` from clean deployed main with the explicit
operator kubeconfig, retained operator password, and exact reviewed confirmation. It validates
the new credential, serially replaces standbys then leader under the disruption Lease,
checks Raft catch-up and ownership, and requires working issuance/config afterward. Old
issuance need not work before repair. Stop further disruption if member recovery fails.
A partial rollout can resume under fresh confirmation without changing images/claims.

Acceptance proves selected issuer generation/API identity, no expiry claim, positive/negative
TokenRequests, real consumer expiry/rejection, and fresh issuance with unchanged server
processes. Do not add periodic privileged config writes/restarts. Revisit projections only
when an official fix proves issuance after original issuer expiry without restart/config rewrite.
[Upstream cached-client source](https://github.com/openbao/openbao/blob/ca305a02daa68b203325daa1b25c18d7a252d4b3/internal/builtin/logical/kubernetes/path_creds.go)
records the compatibility reason.

## Private TLS, audit, and monitoring

Expose authenticated UI/API only through private Gateway/DNS. The server has its own
single-host certificate; never copy the gateway wildcard private key. Backend TLS/join
validates that hostname with system trust; mount the certificate directory for native
reload. Peer traffic uses native cluster TLS.

Cilium permits designated private gateway/jobs/monitoring, peer traffic, DNS, and the
Kubernetes API. Account for backend port translation; API Service transport does not
identify the endpoint port policy must allow. Preflight matches live source/policy/port
before credential or config writes. A separate health/metrics listener never grants
administrative access and is reachable only by designated observers. No public exposure
or general Internet egress is needed.

Declare hashed, non-raw audit output in server source; apply/bootstrap verify rather than
create a separate API-owned audit device. Audit failure can block requests and needs distinct
alerting. Synthetic secret canaries verify logs/output remain safe. Monitor each voter,
quorum, seal/readiness, route/TLS, storage, local snapshot, and off-cluster transfer separately.
Unauthenticated health preserves native sealed/uninitialized status; do not mask it as success.

## Snapshots and independent recovery

A bounded snapshot-read-only job targets the active peer directly with verified TLS,
rediscovers leadership on bounded failure, and atomically publishes checksum/archive-valid
snapshots to a separate retained backup claim. Never prune the last usable snapshot after
failure. Longhorn detached-volume recurring backup supports off-cluster transfer after
jobs exit. Local snapshot freshness and off-cluster transfer freshness are different signals;
missed jobs/transfers extend the roughly daily recovery point. No fixed RTO is promised.

Snapshot records retain version, time, Raft index, seal ID/generation, and checksum, never
login/seal/recovery bytes. For selected local retrieval, the guarded
`openbao-backup-retrieve` uses a completed backup Job/time window rather than moving latest,
validates the private snapshot/metadata pair, refuses overwrite, and cleans only its isolated
reader. During cluster loss, retrieve the retained off-cluster copy using independently held
backup access; the live retrieval helper is not the only recovery root.

### Isolated restore assurance

1. Select private `raft.snap` and sibling `metadata.json`. Match its recorded version,
   seal ID/generation, and retained operator/recovery material before proceeding.
2. With explicit authorized operator kubeconfig and clean deployed source, set
   `OPENBAO_RESTORE_SNAPSHOT`, `OPENBAO_RESTORE_SEAL_ID`, and `OPENBAO_RESTORE_GENERATION`.
   Run `mise exec -- just test record test.openbao-restore-drill`; review its exact
   checksum/run-bound confirmation and provide matching seal/password only at private prompts.
3. Restore into a unique deny-by-default scratch namespace/fresh storage using the snapshot
   version. It has no production issuer RBAC, API token, route, PVC, or peer/API egress.
   Initialize only scratch, restore through the native Raft procedure, and discard scratch
   bootstrap credentials. Authenticate with the snapshot's retained recovery material.
4. Force restore, if needed for differing scratch recovery configuration, repeats isolation,
   ownership, and checksum checks; no production force-restore path exists here. Prove
   automatic unseal, restored config/state, restart, and blocked production issuance.
5. Require both assertions and owned cleanup to pass. If cleanup fails, stop before another
   drill and use the guarded `openbao-restore-cleanup <failed-run-id>` after failure review;
   retain the failed report and record a fresh drill after cleanup.

The scratch JWT provider cannot perform its normal config read without a production token.
Require that specific unavailability and compare only its source-owned stored entry over
loopback raw storage using the retained operator login. Other config uses ordinary reads;
unexpected errors/fields fail. Do not grant scratch production authority to make checks pass.

A restore drill needs production healthy for isolation checks and proves only the selected
isolated snapshot. During an actual outage, recover Kubernetes/storage/TLS independently
under [platform recovery](010-talos-flux-platform.md), then use an explicitly reviewed
production restore procedure. Raft/PVC replacement and production force restore require
operator authorization. Missing seal/material is a hard stop, not permission to reinitialize.

## Upgrades and evidence limits

Before upgrade, require all three healthy placed voters, a fresh compatible recoverable
snapshot, source parity, and the disruption Lease. Publish reviewed image/config first;
`OnDelete` prevents uncontrolled replacement. The guarded `openbao-upgrade` replaces and
checks standbys one at a time, transfers leadership before the old leader, and repeats live
health/ownership immediately before eviction. Refuse concurrent node maintenance or a second
unavailable voter. A stopped rollout preserves state for review; image downgrade alone is
not recovery and needs a compatible snapshot.

Source tests protect authority/configuration, but native acceptance separately proves
issuance/real expiry/denials, HA and automatic unseal, selected restore, cleanup, and fresh
observer evidence. Reports and [issue 449](https://github.com/supermorphic/homelab-talos/issues/449)
retain dated acceptance; measured runs do not promise zero downtime or production RTO.
[Kubernetes commands](../../kubernetes/mod.just), [operator workflows](../../scripts/openbao/operator.py),
and the [test catalog](../../tests/catalog.yaml) own exact execution inputs and suite membership.
