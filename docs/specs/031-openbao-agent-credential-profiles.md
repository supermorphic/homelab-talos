# OpenBao agent credential profiles

## Intent and delivery boundary

[Issue 450](https://github.com/supermorphic/homelab-talos/issues/450) adds unattended
workstation authentication, named Kubernetes profiles, standard exec credentials,
and direct lifetime/revocation/outage proof. It extends
[the broker](030-openbao-kubernetes-credential-broker.md) without changing its recovery roots.
The additive broker and workstation lifecycle are deployed and accepted. Source now
implements the four-context exec caller flow and separate Talos reader installation.
Final deployment and deployed-main acceptance of caller retirement remain pending;
[additive acceptance](https://tests.lab.supermorphic.com/reports/20261002T011416Z-431b7b32799e-operator-3c0b3142/awesome/)
does not establish that final gate.

An authorized checkout requests the same profiles regardless of branch/location.
Git/Flux defines permissions; OpenBao authenticates the workstation and issues temporary
credentials. Source/evidence authority retains separate checks. This needs one local
credential path and existing operator/config/test infrastructure, not a fleet registry,
generic auth framework, shared cache, renewal daemon, or reporting service.

## Current scoped access and isolation limits

Approved Kubernetes access uses `mise exec -- just kube kubeconfig` after workstation
enrollment. It installs four checkout-bound standard exec contexts with observer as the
default and no bearer tokens in the ignored kubeconfig. The shared canonical validator
checks the exact helper, profile mapping, and verified cluster metadata; scoped callers
reject the retired embedded-token representation and arbitrary exec programs. Kubernetes
setup uses the same issuer flow in primary and linked checkouts and does not inspect or
copy another checkout's administrative credentials.

When approved node inspection needs Talos access, run
`mise exec -- just talos readerconfig` separately in the linked worktree. Its installer
uses the existing primary-checkout Talos signing workflow and atomically replaces only
that worktree's ignored Talos reader file. Failed staging or publication preserves the
prior destination; there is no paired Kubernetes/Talos publication. Reader authority and
finite lifetime remain separate from Kubernetes profiles. `mise exec -- just talos kubeconfig`
is explicitly operator-run administrator download and no longer changes authority by
checkout location.

The observer supports approved reads; diagnostic adds only named-workflow exec/port-forward
capabilities; publisher is restricted to report publication and its named Lease, never
suite execution. The coordinator can only get/update the existing named campaign Lease,
not create/delete Leases, perform diagnostics, or execute suites. A technical capability
does not authorize ad-hoc use. Scoped denial stops
work at that boundary rather than permitting administrator fallback or live RBAC repair.
Reviewed necessary permission changes go through Git with catalog/verifier/policy updates.

Worktree separation prevents accidental credential adoption but is not OS/process isolation.
Hooks are accident guards; credential custody and actual RBAC enforce effects. Denied Secret
API reads do not prove logs/status or permitted exec cannot expose sensitive data. Named
workflows and runtime-data boundaries remain necessary, including for privileged diagnostics.
[Root policy](../../AGENTS.md) owns authorization; the
[Kubernetes helper](../../scripts/openbao/credentials.py),
[Talos installer](../../scripts/repository/install-worktree-credentials.sh), [RBAC](../../kubernetes/apps/kube-system/agent-access/app/rbac.yaml), and
[access verifier](../../scripts/verify/agent-access.sh) own current implementation.

## Authentication choice and workstation trust

Use AppRole through verified private HTTPS. Interactive OIDC does not satisfy unattended
work, a separate JWT issuer adds scope, and client-certificate auth needs transport changes
because the current Gateway terminates TLS. Each workstation has its own AppRole and
identity entity, with protected authentication outside all checkouts.

Anyone able to use that workstation SecretID can request all four profiles. Contexts select
intended authority; they do not isolate agents sharing an OS user. File permissions separate
users, not local processes using the same user. Only trusted repository code may consume the
workstation credential. No hardware binding or process-isolation service is added.

Ordinary agents receive no administrator Kubernetes identity, OpenBao root/operator token,
or issuer credential. Available profiles do not authorize arbitrary diagnostic/test actions.

## Three credential lifecycles

### Workstation SecretID

A reusable, expiring SecretID avoids parallel-command consumption races. The operator enrolls
and rotates it; the workstation cannot create its own authentication. Retain authentication,
expiry/entity binding, and operator accessors privately in owned regular `0600` files under
`0700` directories outside repositories. Reject symlinks/unsafe ownership/modes and install
atomically. Cluster endpoint/CA and broker metadata come from explicitly operator-verified
input, never another checkout's kubeconfig. TLS verification is mandatory.

Rotate before expiry: issue and validate a replacement, install it atomically, then destroy
old SecretIDs by retained accessor. Interrupted validation keeps the previous usable file;
failed old-ID cleanup leaves the new file usable but the operation incomplete. Do not blindly
repeat ambiguous writes. Lost/expired/invalid material fails closed for operator re-enrollment,
without unattended credential searches/recovery or distributing old SecretID copies to worktrees.
Exact role lifetime settings are owned by
[desired configuration](../../kubernetes/apps/security/openbao/config/desired.json).

### OpenBao login token

Each exec invocation independently logs in with a hard 60-second session bound, no default
policy, and only the four exact issuance paths plus self-revocation. It requests one profile
and revokes its session before returning a credential. Keep that token in memory only;
no renewal, shared cache, background process, identity/role management, or generic secret
access is granted. Attempt bounded cleanup on failure but never retry ambiguous issuance/
revocation writes blindly. Failed cleanup returns no successful credential; an orphaned
session remains bounded by its explicit maximum.

### Kubernetes profile token

Profiles select exact pre-existing accounts/namespaces with the API audience and a ten-minute
maximum. Validate account, namespace, audience, actual expiration, and response consistency;
reject excessive/missing/expired lifetime. Decoded claims are checks, not proof of API acceptance.
Use SelfSubjectReview and real positive/negative operations in acceptance.

Token values pass only through the exec-protocol pipe to client memory, never kubeconfig,
cache files, traces, or evidence. Process exit releases the client cache without promising
secure memory erasure. Independent new processes issue independently.

## Workstation revocation

SecretID destruction alone leaves already-issued OpenBao sessions able to request profiles.
Enrollment must bind the exact role alias to a dedicated entity without additional entity/
group policies and verify the entity returned by login. Ambiguous mappings stop enrollment.

The guarded operator workflow resolves exact role/alias/entity, disables and reads back the
entity as the immediate session-use barrier, destroys all role SecretIDs, verifies empty
inventory, and retains disabled state/private lifecycle history. Entity disablement makes
associated tokens unusable; it is not token deletion. Verify an unexpired pre-disable session
is denied. Requests already authorized may finish; the barrier cannot recall their responses.

Ordinary config apply never re-enables entities or regenerates authentication. Re-enrollment
requires no old SecretIDs and expiry of old bounded sessions before enabling the same entity:
wait at least 90 seconds from confirmed disable (60-second lifetime plus clock margin).
Unproved history/bounds or unexpected mapping keeps the entity disabled for attended recovery
or a new reviewed role slot.

Previously issued Kubernetes tokens remain valid until expiration, including API leeway.
Existing watch/exec/port-forward streams may last longer. OpenBao revocation neither individually
revokes those JWTs nor promises to terminate upgraded connections.

## Profiles and Kubernetes authority

| Profile | Authority |
| --- | --- |
| `observer` | Existing view and explicit reads. |
| `diagnostic` | Observer plus approved namespace/subresource diagnostics. |
| `publisher` | Existing report-publication and named publication-Lease permissions. |
| `campaign-coordinator` | Only get/update on the existing campaign Lease. |

Preserve observer/diagnostic/publisher grants; do not widen them for easier issuance.
The issuer gains only exact account reads and named TokenRequests, never account/RBAC mutation.
Git owns the campaign Lease without reconciling mutable holder/timestamps. Coordinator uses
existing-only acquisition and resource-version guards, cannot create/delete Leases or touch
other objects, and never executes suites. Its availability does not authorize selecting it
for a whole campaign; runner credential separation is follow-on work.

## Local exec-plugin contract

`mise exec -- just kube kubeconfig` installs scoped contexts in this checkout's ignored
configuration; installation stores connection metadata and canonical exec commands, not tokens.
Use the Kubernetes v1 exec protocol, noninteractive operation, actual `expirationTimestamp`,
and one selected approved profile. The absolute checkout-bound helper uses pinned tooling
independently of client cwd; credential-bearing stdout is reserved for the client protocol.
There is no token-print interface or arbitrary exec program acceptance.

Stage/validate private output and replace atomically. Preserve administrator or unknown configs
until an operator explicitly migrates them to operator-only storage; recognized scoped legacy
configs can be replaced. Remove only owned staging files and keep no routine credential backup.
After setup, invocation does not modify kubeconfig or shared mutable worktree state.

The Kubernetes installer must not inspect branch/common Git directory, primary checkout,
ambient OpenBao token, default user kubeconfig, or another checkout's credentials. Unknown
profiles, wrong cluster, redirects, unsafe files, missing auth, or failed issuance fail closed.
Repository scoped callers use the shared canonical validator and explicit diagnostic/
publisher selection. Database-tunnel and scoped-campaign preflight also require observer
as the current context; publication selects its context without changing that default.
Source/evidence workflows may inspect Git topology for their independent authority checks.

## Caller compatibility and outage behavior

An existing client process may use its in-memory Kubernetes token through a broker outage
until expiry/HTTP 401/process exit. A new command has no shared cache and may fail immediately;
expired clients need broker recovery before refresh succeeds. Do not extend lifetime, replay
writes, or silently fall back to explicit operator credentials. Preserve operator-only inputs
where a workflow actually requires them.

A long-running task refreshes later requests through its client, but an open stream is not
proof of refresh. Acceptance separately exercises new reads/watch reconnections, diagnostic
connections, publication transport, and Lease renewal across expiry. Measure real request counts/
latency during those runs before introducing later performance changes. Promise tested caller
behavior, not uninterrupted operation or zero failed commands.

## Operator lifecycle and independent recovery

The reviewed AppRole mount/slots, issuance roles, and configuration remain Git-owned. Runtime
entity bindings, disablement, and SecretIDs are managed only by guarded enrollment/rotation/
revocation, never reconciled active by config apply. Keep runtime identifiers and hardware details
private. Readback proves exact bindings/effective policy without putting those IDs in reports.

From clean deployed source with an explicitly authorized operator kubeconfig, use
`mise exec -- just bootstrap openbao-agent <operator-kubeconfig>` to apply config, enroll,
and record acceptance. Each child retains source/target/Lease/confirmation guards and uses
the retained operator password through private prompts. It saves no operator credential.
Resume at `enroll` or `test` only after inspecting the first unfinished phase; completed
enrollment need not be repeated for source-parity or publication failures.
Individual `openbao-workstation` actions use the same explicit credential and reviewed slot.

Missing workstation material requires separately attended recovery using independent operator
login/cluster access under [spec 030](030-openbao-kubernetes-credential-broker.md#seal-and-recovery-ownership).
Do not make operator recovery depend on an expired/revoked broker-issued profile.
Rotate by validated atomic replacement before old-ID destruction. Ambiguous role/entity
creation needs private identity inspection, never invented/adopted mappings. Revoke to preserve
the disabled barrier when interrupted enrollment/rotation cannot be completed safely.

An interrupted acceptance retains private run-owned journals outside repositories. New
acceptance refuses pending journals. Use
`mise exec -- just bootstrap openbao-agent <operator-kubeconfig> recover <failed-run-id>`
for separately authorized recovery: verify current deployed main, same cluster and exact
owned identities, exclude concurrent recovery, and repeat disable/SecretID destruction/
full session-expiry cleanup. Never reuse a previous process's monotonic timestamp as elapsed
proof. Failure retains records; success removes only that run's private state and starts fresh
recorded acceptance without re-enrolling the normal workstation. Do not remove another Lease
holder. If only evidence publication failed, resume the retained record rather than rerun tests.

## Talos and caller cutover

The Talos installer now handles only `os:reader` generation and one atomic file replacement;
Kubernetes TokenRequests, kubeconfig parsing, and paired publication are removed. The retained
Talos administrative signing dependency does not grant Kubernetes issuance authority.

Existing recognized scoped token configs migrate through `kube kubeconfig`; administrator
or unknown configurations require deliberate operator migration and cannot be overwritten
automatically. Reinstall the checkout-bound exec configuration before running updated scoped
callers. Broker outage or missing enrollment is a stop boundary, not permission to restore
the retired minting path or use broader credentials.

Source implementation, deployment, and final caller acceptance remain distinct. Final
acceptance must exercise the merged caller representation on clean deployed main before
closing the initiative. Design approval and additive acceptance alone do not authorize a
merge, privileged activation, or completion claim.

## Validation and acceptance limits

Offline checks protect mapping/RBAC, auth/session bounds, config drift, canonical exec protocol,
actual expiry validation, atomic private files, parallel calls, and sanitized failures. Use
synthetic secret sentinels and hostile ambient credentials; task-owned standalone/linked fixtures
must issue identically without primary-checkout access. Keep Talos proof separate.

Registered live acceptance proves all four API identities and permissions in both checkout forms,
independent parallel issuance/files, real expiry/new issuance, representative refresh/streams,
revocation of unexpired sessions for every profile, unaffected second workstation, rotation,
and cached/new-command outage behavior. Reuse existing caller/auth-matrix tests; do not multiply
shared cases into a new benchmark/framework. Client-side outage injection does not disrupt the
production broker or establish HA. Test enrollment is isolated from normal workstation auth.

Coordinator acceptance checks acquire/renew/contention/release and denies unrelated objects,
respecting every current holder. Cleanup disables owned entities, destroys their SecretIDs,
waits the session bound, and removes only owned aliases/entities/roles. Retain sanitized
assertions/counts/timing, never credentials. Source checks and candidate tests do not establish
final deployed-main caller acceptance.
