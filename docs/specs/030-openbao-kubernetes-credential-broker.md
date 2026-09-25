# OpenBao Kubernetes credential broker

## Status and purpose

Design for [issue 449](https://github.com/supermorphic/homelab-talos/issues/449).
The operator approved automatic unseal and three voting replicas, one per physical
node, after reviewing the existing cluster. This written specification is proposed
for review; implementation and live acceptance are not complete.

Deploy OpenBao inside the Talos cluster to issue short-lived credentials for
pre-existing Kubernetes ServiceAccounts. Git and Flux own every ServiceAccount,
Role, ClusterRole, and binding. OpenBao cannot create or broaden that authority.

[Issue 450](https://github.com/supermorphic/homelab-talos/issues/450) owns agent
authentication, real worktree credential profiles, CLI integration, and retirement
of the existing credential installer. This issue proves issuance with a dedicated
acceptance identity. Existing SOPS secrets and Talos recovery remain independent
of OpenBao. Static-secret migration, external databases, PKI issuance, and an
off-cluster broker are outside this design.

## Existing platform and availability decision

Read-only inspection on 2026-09-25 found three Ready control-plane nodes and three
healthy etcd members. DNS, Cilium's operator, cert-manager, Envoy gateways, and
Tailscale access each use two replicas. Longhorn CSI controllers use three.
Most applications, both PostgreSQL databases, and the monitoring databases use
one instance. All 20 Longhorn volumes had two copies on distinct nodes.

This inventory describes observed topology, not a completed failure test. The
durable precedent is selective service redundancy plus two-copy persistent
storage. OpenBao follows the quorum model already used by etcd:

| Decision | Selected design | Reason |
| --- | --- | --- |
| OpenBao members | Three voting replicas | Two members remain available after one node fails. |
| Placement | Required pod anti-affinity by `kubernetes.io/hostname` | Each voter occupies a different physical node. |
| Persistent storage | One Longhorn RWO claim per voter | Independent Raft state, using the existing storage platform. |
| Storage replication | Existing two-copy Longhorn StorageClass | Preserve current storage and recovery conventions. |
| Voluntary disruption | `minAvailable: 2` | Prevent a second eviction while one replica is unavailable. |
| Restart | Automatic unseal using a SOPS-managed static key | Ordinary restarts require no operator key entry. |
| Upgrade strategy | StatefulSet `OnDelete` | Upgrade standbys before the leader under an explicit workflow. |

A single instance requires process and volume recovery before issuance resumes.
Two Raft voters tolerate no voter failure. Five voters on three physical nodes
do not tolerate arbitrary loss of two physical nodes. Three voters therefore
provide a concrete availability benefit at the cluster's existing failure boundary.

Leader election can briefly interrupt requests. A disruption budget guards
voluntary eviction; it does not prevent hardware failure or direct pod deletion.
After one failure, restore all three healthy voters before another planned
disruption. Loss of two nodes or the shared cluster/network foundation is outside
the service's availability guarantee. Raft and Longhorn replication are not backups.

## Package and release ownership

Add the package under `kubernetes/apps/security/openbao/`, with a dedicated
`openbao` namespace and the standard app-local Flux entrypoints. Use the official
OpenBao Helm chart, explicit values, and native ancillary resources.

The release baseline reviewed for this design is chart `0.29.6` and server
`2.7.0`, both released on 2026-09-23. Override the chart's `2.6.3` application
default explicitly. Version 2.7.0 supplies automatic listener certificate reload,
avoiding a separate controller or process supervisor for certificate renewal.
Pin the image digest during implementation after verifying the registry manifest.
Track chart and image updates through the repository's Renovate conventions.
These are design inputs; chart rendering and runtime compatibility remain
implementation gates.

The server values must explicitly configure:

- three replicas, integrated Raft storage, stable pod-based Raft IDs, and
  required node separation;
- `Parallel` pod management so initial unready pods do not prevent peers from
  starting, with readiness requiring an initialized, unsealed instance;
- `OnDelete` updates, a native disruption budget retaining two replicas, and
  retained PVCs on StatefulSet removal or scale-down; disable the chart's own
  disruption budget so only the explicit native budget applies;
- the shared static seal file, TLS listener, automatic certificate reload, and
  explicit retry-join addresses for the three stable peer DNS names;
- a 10 GiB data claim per voter using the existing `longhorn` StorageClass;
- non-root execution, no privilege escalation, and dropped Linux capabilities;
- `disable_mlock = true` for integrated Raft, without granting `IPC_LOCK`;
- disabled injector, CSI provider, chart snapshot agent, authentication-delegator
  binding, Kubernetes service registration, and permanent ServiceAccount token
  Secret creation.

Use a Git-owned server ServiceAccount. Omit chart-generated pod-registration RBAC
and active/standby label-based routing. A Service selects Ready servers; OpenBao
handles forwarding to the leader. A headless Service provides peer discovery.
Mount only the projected, rotating Kubernetes API token needed by the issuer.

Start with requests of 100m CPU and 256 MiB memory per server, and limits of one
CPU and 1 GiB memory. These are provisional reservations, not measured capacity.
Measure idle, issuance, snapshot, restart, and restore peaks during acceptance,
then reconcile values and this specification before completion.

## Flux activation and readiness

Separate the namespace and TLS prerequisites, server package, and operational
integrations. Dependencies include Longhorn and cert-manager; access integration
also depends on the internal Gateway. Monitoring is never a server dependency.

Stage the package suspended until the operator has supplied the encrypted seal
Secret and selected the recovery destination. The `prepare` phase of bootstrap
resumes only the reviewed staged resources through the existing guarded
application-bootstrap pattern. It deploys uninitialized servers and reports their
identities; it never initializes OpenBao. The separate `initialize` phase can then
bind confirmation to the actual claims and server identities. Durable activation
is subsequently committed to Git.

OpenBao cannot become Ready before initialization. Configure Helm installation
not to wait for workload readiness during this initial transaction; do not change
the readiness probe to classify sealed or uninitialized instances as healthy.
The bootstrap workflow checks these states directly through its private tunnel.
Normal upgrade readiness remains enabled. Helm installation success alone is
never OpenBao acceptance.

Keep the private HTTPRoute, issuance acceptance workload, and backup schedule
inactive until initialization, access configuration, and audit setup succeed.
Failure preserves all storage and suspends owned reconciliation where appropriate;
suspension is not treated as stopping a running server or rolling back initialization.

## Seal and recovery ownership

Use OpenBao's static seal with a cryptographically random 32-byte key. An
operator-run `mise exec -- just repo openbao-secrets` workflow creates the
SOPS-encrypted Secret and an encrypted recovery copy without printing key values.
The writer follows the existing repository recipient and staged-blob checks.
All three servers mount the same key read-only, with a stable non-secret key ID.
The agent does not handle the operator's age private key.

After initialization, a replacement process reads the key and unlocks its retained
Raft state automatically. A new peer uses that same seal to join the established
cluster. Only the first member is initialized; peers must never initialize
independently.

The accepted trust boundary is the existing SOPS/Kubernetes bootstrap root. The
seal key is protected independently of the Raft snapshots. Recovery requires
both the matching seal key and a usable snapshot; recovery shares authorize
recovery operations but cannot decrypt data without the seal key. Losing that
key permanently can make every associated backup unusable.

Retain the operator's age identity, encrypted seal artifacts, OpenBao recovery
material, and backup access independently of this cluster. Do not make their
retrieval depend on an OpenBao-issued credential. Retain older seal keys for as
long as a retained backup requires them. Seal-key rotation is an attended,
separate operation using the supported current/previous-key mechanism; it is
never an incidental result of regenerating a Secret.

## Guarded initialization

Public commands:

```text
mise exec -- just bootstrap openbao prepare
mise exec -- just bootstrap openbao initialize
```

Preparation requires
`OPENBAO_BOOTSTRAP_CONFIRM=prepare:openbao:<main-sha>:<package-digest>`.
The package digest binds the reviewed namespace/server/TLS manifests and chart
values. Preparation validates the existing encrypted seal artifact and recovery
destination, acquires the repository disruption lock, and resumes only owned,
staged Flux units. It refuses an existing initialized server or an unrelated
release. It does not use Helm rollback or uninstall as failure cleanup. An
unconfirmed preparation invocation performs no mutation. This phase avoids
requiring nonexistent pod or claim UIDs in the first confirmation.

Initialization requires a second, distinct confirmation:

```text
OPENBAO_BOOTSTRAP_CONFIRM=initialize:openbao:<main-sha>:<target-digest>
```

The SHA identifies clean, published and deployed main. The SHA-256 target digest
binds the Kubernetes cluster identity, namespace and StatefulSet UIDs, all three
PVC UIDs, server configuration digest, seal key ID, and recovery recipient.
An unconfirmed invocation performs observation only and reports the required
confirmation. Changed target identity invalidates it. Secrets are excluded from
the digest input and routine output.

Bootstrap is operator-run and uses explicitly selected operator credentials.
The workflow obtains the repository disruption lock, validates source and target,
and repeats safety-critical checks immediately before initialization:

1. Prove the staged package, image/configuration, node placement, TLS certificate,
   seal mount references, and three retained claims match the reviewed source.
   Establish a bounded loopback-only port-forward to the exact first server.
   Verify its TLS identity using the service certificate name.
2. Validate a user-selected absolute recovery directory outside all repository
   roots and ordinary test-output paths. Reject symlinks, unsafe permissions,
   existing output collisions, or an invalid public encryption recipient.
   Verify that encrypted output can be installed and durably flushed before
   contacting the initialization endpoint.
3. Query all three pod-specific endpoints. Require an unambiguous
   `initialized: false` result from each. Refuse
   mixed state, inaccessible state, or any previously initialized member.
4. Recheck the exact target, confirmation, and initialization state. Send one
   initialization request to the first member with automatic HTTP retries
   disabled. Create one recovery share with threshold one for this single-operator
   homelab; multiple copies of that share provide retention, not split custody.
5. Keep the returned root token and recovery share in process memory. Immediately
   encrypt and atomically retain the response to the approved destination using
   the public age recipient. Never write plaintext intermediate files, command
   arguments, shell tracing, routine stdout/stderr, or test evidence.
6. Wait for automatic unseal and peer joining. Verify one cluster identity,
   three healthy voting peers, and exactly one leader. Configure the Git-owned
   authentication, policy, audit, and issuance inputs using the initial token.
7. Generate a separate operator login credential, retain it encrypted in the
   operator recovery bundle, and prove that login works before revoking the
   initial root token. Verify root-token rejection without displaying its value.
8. Verify initialized, unsealed, healthy state and the installed configuration.
   Release the owned lock and tunnel. Report only non-secret results and
   operator-local output locations; locations are not retained in test reports.

There is no automatic retry after a lost initialization response, no automatic
PVC reset, and no fallback to initializing another member. If the result or
recovery-material delivery is ambiguous, stop and preserve state for attended
recovery. A rerun against an initialized cluster refuses reinitialization even
when later configuration failed. Configuration repair uses a separate command
with an existing authorized OpenBao identity.

## Authentication and declarative issuance

Bootstrap enables only the authentication needed for operator access, backup,
and the acceptance workload. Operator access uses a dedicated `userpass` login
with a repository-defined operational policy and short-lived session tokens.
Its password belongs in the encrypted operator recovery bundle and the
operator's password manager. The initial root token is not the normal login.
Administrative policy is explicit; routine workloads receive no administrative
OpenBao policy.

In-cluster backup and acceptance jobs authenticate using projected Kubernetes
JWTs with a dedicated OpenBao audience and a ten-minute lifetime. Use OpenBao's
JWT method with the Kubernetes provider, bound issuer, exact namespace and
ServiceAccount subject, and the dedicated audience. It discovers verification
keys using the server's ordinary projected identity. This avoids granting
`TokenReview` or `SubjectAccessReview` permissions to the issuer.

JWT verification does not immediately observe deletion of a Pod or ServiceAccount;
an otherwise valid token can authenticate until it expires. Bound the issued
OpenBao session to a short lifetime as well. A Kubernetes token minted by the
secrets engine is not a backup or acceptance-job login token.

Git contains the desired mounts, policies, auth roles, and Kubernetes secrets-engine
role. Bootstrap applies them; subsequent changes use an operator-run
`mise exec -- just kube openbao-config-apply` against clean deployed source,
with target/revision confirmation, drift review, and sanitized read-back.
Do not add a permanent privileged configuration controller. API writes outside
these source-owned procedures are recovery actions, not a second configuration
source.

The acceptance boundary consists of:

- a dedicated `openbao-acceptance` namespace;
- an `openbao-issued-reader` ServiceAccount with `get` permission for one
  synthetic ConfigMap, plus a second ServiceAccount with no issuance grant;
- a namespaced RoleBinding granting the OpenBao server ServiceAccount only
  `create` on `serviceaccounts/token`, restricted by `resourceNames` to
  `openbao-issued-reader`;
- one OpenBao issuance role with the exact namespace and ServiceAccount, a
  ten-minute default and maximum TTL, and the Kubernetes API audience;
- one acceptance-job auth role permitted to request only that issuance role.

Do not grant wildcard token creation, ServiceAccount management, RBAC management,
impersonation, binding, escalation, or Secret reads to the issuer. The server's
ordinary Kubernetes discovery permissions are not an issuance grant. Disable
chart resources that would add permissions beyond the explicit design.

The test must prove actual API enforcement of the named token subresource;
static inspection or `can-i` alone is insufficient. Check the returned token's
actual expiry, audience, and authenticated identity. Kubernetes determines the
effective expiration. Reject excessive lifetime. An OpenBao lease revocation
does not independently revoke an existing ServiceAccount JWT: expiration and
Kubernetes object lifecycle remain the effective invalidation mechanisms.

## Private networking and TLS

Expose the authenticated UI/API at `openbao.lab.supermorphic.com` through the
existing private Gateway and DNS conventions. The Gateway keeps ownership of
its wildcard key. OpenBao receives its own cert-manager Certificate from the
existing production issuer for the exact OpenBao hostname; no wildcard private
key is copied into the application namespace.

Use TLS on the server API listener and a BackendTLSPolicy that validates the
service certificate using system trust and that hostname. Internal clients and
Raft join requests use the same verified server name when connecting through
Service or peer DNS. Enable OpenBao's built-in certificate auto-reload and mount
the complete Secret directory so projected certificate renewal is observed.
Peer traffic uses OpenBao's native cluster TLS. Acceptance includes certificate
renewal/reload without losing quorum.

Cilium policy permits only:

- API access from the private Gateway, explicitly labeled backup/acceptance jobs,
  health monitoring, and the bounded bootstrap/diagnostic path;
- server-to-server API/join and cluster traffic between the three OpenBao pods;
- server egress to cluster DNS and the Kubernetes API;
- backup access to OpenBao and its mounted backup claim;
- Prometheus access to a separate internal metrics listener.

The separate listener permits unauthenticated metrics/health for observation;
all administrative endpoints still require OpenBao authentication. Its network
port is accessible only to the designated monitoring workloads.
No public ingress or general Internet egress is required. Unauthenticated health
responses are permitted; administrative requests require OpenBao authentication.
Initialization is reachable only through the guarded bootstrap path before the
normal route is activated.

## Snapshots and isolated recovery

Create an application-owned daily snapshot CronJob using a snapshot-read-only
OpenBao policy and short-lived projected authentication. Save snapshots to a
separate retained Longhorn backup PVC. Run it before the existing Longhorn
off-cluster backup window. Retain seven successful snapshots, publish each
atomically after checksum and archive validation, and never prune the last
usable snapshot on a failed run.

The snapshot client identifies the active member through peer-specific health
checks and addresses that member directly with verified TLS. It does not depend
on Kubernetes pod registration or repeatedly follow redirects through a Service
that can select a standby. Re-resolve leadership after a bounded failed attempt.

For each snapshot, retain non-secret metadata: application version, creation time,
Raft index, seal key ID, recovery-material generation, and checksum. Do not retain
login credentials, JWTs, seal bytes, or recovery shares with snapshots. Longhorn
backs this claim up to the existing off-cluster target. Report local snapshot
freshness and off-cluster transfer freshness separately. An ordinary successful
daily schedule targets approximately 24 hours of data loss; missed jobs or
transfers increase that interval and must alert. Measure recovery duration in the
restore drill before making an RTO claim.

`mise exec -- just kube openbao-restore-drill` is an attended, registered test.
It selects an exact retained snapshot and associated recovery material, binds
confirmation to the snapshot checksum and run ID, and creates a unique isolated
namespace with deny-by-default policy before creating any workload.

The scratch server has no production issuer RoleBinding, no mounted Kubernetes
API token, no route, no production PVC, and no egress to the production API or
OpenBao peers. It uses fresh storage and the snapshot's OpenBao version. The
operator supplies the matching seal material directly through the guarded test
workflow; it never enters evidence. The restore must remain isolated even though
the restored database contains production configuration.

Initialize only the new scratch storage, restore the selected snapshot through
the upstream Raft restore procedure, and discard scratch bootstrap credentials.
Use the snapshot's associated operator/recovery material to authenticate after
restore. Force-restore, if required because scratch initialization used a different
recovery configuration, is permitted only after rechecking the scratch namespace,
PVC ownership, network isolation, and snapshot checksum. There is no production
force-restore path in this test.

Prove automatic unseal, the restored non-secret configuration/canary and cluster
state, and a second scratch process restart. Prove that Kubernetes issuance
cannot reach production from the restored copy. Clean up only run-owned resources;
report cleanup failure separately. A checksum check alone is not restore evidence.

Extend the existing [platform recovery runbook](../runbooks/platform-disaster-recovery.md)
and add an OpenBao-specific runbook during implementation. Coordinate the recovery
dependency chain with [issue 294](https://github.com/supermorphic/homelab-talos/issues/294):
operator SOPS/Talos recovery, Kubernetes/Flux/network/storage restoration, seal
material and snapshot restoration, OpenBao verification, then credential consumers.

## Observability and upgrades

Add a Homepage Platform tile, Gatus health evaluation that distinguishes
unavailable/uninitialized/sealed states, a ServiceMonitor, and alerts for missing
voters, lost quorum, sealed members, snapshot/transfer freshness, storage pressure,
and certificate expiration. Monitor each member as well as the client route.
Retain upstream health semantics; do not mask sealed or uninitialized status as
success. Monitoring failure must not prevent issuance.

Enable OpenBao audit logging with secret fields protected by its audit hashing;
never enable raw audit logging. Send bounded operational/audit output through the
existing container-log collection. Validate with synthetic credential canaries
that logs and test output contain no credential values. Avoid query strings and
debug response dumps containing tokens. An audit-device write failure can block
requests and needs a distinct alert.

Before an upgrade, review release compatibility, confirm all three voters and
their placement, retain a fresh snapshot, and acquire the existing disruption
lock. Update Git first; `OnDelete` prevents uncontrolled pod replacement. An
operator-run upgrade workflow replaces one standby at a time and checks that it
has rejoined and caught up. Transfer leadership to an upgraded member before
replacing the old leader. Recheck live health immediately before every eviction.
Refuse concurrent node maintenance or a second unavailable voter. Version
rollback requires a compatible retained snapshot; downgrading only the image is
not the recovery procedure.

## Validation, evidence, and completion

Implement commands using the [repository command lifecycle](../reference/repository-command-lifecycle.md)
and register assurance in the [test catalog](../../tests/catalog.yaml).

| Workflow | Authority and evidence |
| --- | --- |
| `just kube openbao-validate` | Offline chart render, schema, policy, source, and command-contract validation; no live credentials. |
| `just kube openbao-verify` | Scoped observation of workload, placement, health, route, monitoring, and backup metadata; no deliberate target mutation. |
| `just bootstrap openbao prepare` | Operator-owned deployment of the staged uninitialized servers. |
| `just bootstrap openbao initialize` | Operator-owned initialization and configuration with independent recovery output. |
| `just kube openbao-config-apply` | Operator-owned application of reviewed configuration and sanitized read-back. |
| `just kube openbao-issuance-test` | Authorized bounded issuance, privilege-boundary, expiry, and redaction acceptance. |
| `just kube openbao-ha-test` | Authorized sequential follower/leader replacement and auto-unseal acceptance under disruption coordination. |
| `just kube openbao-restore-drill` | Operator-owned isolated snapshot recovery and cleanup. |
| `just kube openbao-upgrade` | Operator-owned, version-aware standby-first replacement after the Git update. |

Offline tests use independent invariants and synthetic fixtures. Cover named
TokenRequest RBAC, disabled chart permissions, three voters, placement/PDB/PVC
retention, network isolation, TLS verification, and no plaintext secret outputs.
Bootstrap tests exercise already-initialized, mixed, malformed, inaccessible,
changed-target, lost-response, recovery-write failure, and partial-configuration
states. None may trigger a second initialization request or data deletion.

Live acceptance must prove:

1. Three healthy voters on distinct nodes, one leader, automatic joining, and
   private trusted TLS on client and peer-join paths.
2. Successful bootstrap plus refusal of destructive re-entry; encrypted recovery
   handoff, functioning non-root operator login, and initial root-token revocation.
3. A ten-minute token for the exact acceptance identity can read its canary and
   cannot read other protected resources; the token fails after actual expiry.
4. OpenBao rejects an unapproved issuance request, and the issuer's Kubernetes
   identity independently cannot request another ServiceAccount's token or
   create/change RBAC, ServiceAccounts, or impersonation grants. Use narrowly
   controlled real requests where safe, preserve no returned credentials, and
   stop if an unexpected mutation succeeds. Do not create a cluster-admin test
   binding to demonstrate the negative boundary.
5. Sequential follower and leader loss preserves quorum; the replacement rejoins
   and unseals automatically. Measure the client-visible interruption. Existing
   node-lifecycle tests remain the separately authorized physical-node proof.
6. A selected snapshot transferred through the backup path restores usable state
   into an isolated instance, which cannot issue production credentials.
7. Certificate renewal, audit redaction, health-state distinctions, alerts, and
   measured resource use meet the design.

Normal iteration stays local. Before opening/updating a PR, commit the candidate
and run `mise exec -- just test ci-publish` from the clean feature worktree.
Intentional live acceptance uses `mise exec -- just test record <suite-id>`;
publication does not grant permission for a suite's mutation. Retained evidence
contains only sanitized assertions and measurements. No live acceptance is claimed
until its independently authorized run passes.

Reconcile this specification with implemented behavior, exact release pins,
measured resources, recovery evidence, and remaining operator actions before merge
or issue closure. A design commit does not mean issue 449 is deployed or complete.

## Upstream design references

- [OpenBao integrated storage and quorum](https://openbao.org/docs/internals/integrated-storage/)
- [Official Helm chart 0.29.6 values](https://github.com/openbao/openbao-helm/blob/openbao-0.29.6/charts/openbao/values.yaml)
- [OpenBao 2.7.0 release](https://github.com/openbao/openbao/releases/tag/v2.7.0)
- [Static automatic seal](https://openbao.org/docs/configuration/seal/static/)
- [Initialization API](https://openbao.org/docs/api/system/init/)
- [Kubernetes secrets engine](https://openbao.org/docs/secrets/kubernetes/)
- [Kubernetes JWT authentication provider](https://openbao.org/docs/auth/jwt/oidc-providers/kubernetes/)
- [TLS listener and automatic certificate reload](https://openbao.org/docs/configuration/listener/tcp/)
- [Gateway backend TLS](https://gateway.envoyproxy.io/docs/tasks/security/backend-tls/)
- [Raft snapshot operations](https://openbao.org/docs/commands/operator/raft/)
- [Health API](https://openbao.org/docs/api/system/health/)
- [Telemetry](https://openbao.org/docs/configuration/telemetry/)
- [Kubernetes upgrade procedure](https://openbao.org/docs/platform/k8s/helm/run/)
