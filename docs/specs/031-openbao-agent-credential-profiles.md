# OpenBao agent credential profiles

## Status and intent

Design for [issue 450](https://github.com/supermorphic/homelab-talos/issues/450).
The operator selected AppRole and requested explicit credential lifecycles,
revocation of existing issuance authority, standard Kubernetes exec credentials,
and caller-level lifetime and outage tests. This written specification awaits
operator review. Implementation and live acceptance have not started.

[Specification 030](030-openbao-kubernetes-credential-broker.md) records the
completed platform dependency, issue 449, including retained issuance, expiry,
HA, restore, and observer acceptance. This design extends that platform without
changing its deployment, recovery root, or pinned versions.

Any authorized checkout requests the same named Kubernetes profiles. Git/Flux
defines each identity's permissions. OpenBao authenticates the workstation and
issues temporary credentials. Checkout location and branch do not select
credential authority. Source and evidence authority retain their separate checks.

## Implementation scope and proportionality

Keep the implementation to the existing platform plus one local credential path:
a kubeconfig writer, a standard exec helper, the four role/RBAC definitions, and
the caller changes needed to use them. Reuse the existing OpenBao HTTP client,
operator guards, configuration checks, and test/report infrastructure. Small
functions in existing modules are sufficient where they keep those boundaries
clear; this design does not require a new framework or package per lifecycle.

Outage behavior and the workstation trust boundary are documented contracts,
not requests for outage-management or agent-isolation services. The three
credential lifecycles require explicit rules, not three separate managers.
Implement only the operator actions needed to enroll, rotate, and revoke the
workstation safely. Do not build a workstation fleet registry, generic auth
provider interface, background renewal, shared cache, or new reporting system.

Use representative caller acceptance and existing tests as described below.
Do not multiply every failure case across every profile, checkout, and caller.
The permission boundaries and revocation barrier still need direct proof;
reducing duplication must not remove those checks.

## Authentication choice and trust boundary

Use OpenBao AppRole over the existing verified HTTPS route. Each enrolled
workstation has its own AppRole and associated OpenBao identity entity. A
workstation credential is shared by authorized local processes through one
protected file outside all checkouts. It is never copied into worktrees.

| Considered mechanism | Decision |
| --- | --- |
| AppRole | Selected: unattended authentication, explicit SecretID lifecycle, existing HTTPS transport. |
| Client certificate | Excluded: the current HTTPRoute terminates TLS at the gateway; end-to-end client certificate authentication would require transport changes. |
| JWT/OIDC | Excluded: interactive OIDC does not satisfy unattended tasks; a separate JWT issuer or local signing lifecycle adds unnecessary scope. |

OpenBao documents [AppRole for automated machines and services](https://openbao.org/docs/auth/approle/),
[certificate authentication's TLS requirements](https://openbao.org/docs/auth/cert/),
and [JWT/OIDC authentication alternatives](https://openbao.org/docs/auth/jwt/).

The workstation AppRole may request all four profiles. Anyone who can use its
SecretID can obtain any of them. Kubernetes context separation helps callers
select the intended authority; it is not per-agent isolation. File permissions
separate operating-system users, not agents running as the same user. This issue
does not add hardware binding, process isolation, or another credential service.
Only trusted repository code may use the workstation credential.

No ordinary agent receives administrator Kubernetes credentials, an OpenBao root
or operator token, or the Kubernetes issuer credential. Profile availability does
not authorize arbitrary diagnostic operations or test mutations; repository
workflow policy still applies.

## Three credential lifecycles

### Workstation SecretID

Use `bind_secret_id=true`, `secret_id_ttl=2160h` (90 days), and
`secret_id_num_uses=0` (reusable). Reuse avoids consumption races between parallel
commands. The workstation cannot create or rotate its own SecretIDs.

Enrollment installs one `0600`, owner-checked, regular file under
`~/.config/homelab-talos/openbao/`, with private directories set to `0700`.
Reject symlinks and unsafe ownership or permissions. Store the RoleID, SecretID,
expiry, and expected entity identifier together in `workstation.json`, using
atomic replacement. Private operator records retain the SecretID accessor and
entity mapping for lifecycle actions. Do not put credentials in arguments,
environment variables, Git, logs, or test artifacts.

Enrollment also installs non-secret cluster connection metadata from an
operator-verified source: Kubernetes endpoint and CA, OpenBao endpoint, and
approved profile names. A normal checkout never discovers this information by
opening another checkout's kubeconfig. Server TLS verification is mandatory.

Routine rotation occurs before 90 days. The operator issues a replacement,
validates it without displaying it, atomically replaces the local file, and
destroys the previous SecretID by accessor. Commands already using the old file
can finish their short issuance transaction. This is scheduled replacement,
not emergency workstation revocation. On interruption, preserve a usable private
copy and report incomplete cleanup without printing either credential.

Lost, expired, or invalid local material fails closed and requires operator
re-enrollment. It must never trigger unattended credential recovery or a search
for a different identity. Recovery creates fresh material; do not restore copies
of an old SecretID into individual worktrees.

### OpenBao login token

Each exec-plugin invocation logs in independently. Set `token_ttl=60`,
`token_max_ttl=60`, `token_explicit_max_ttl=60`, `token_period=0`,
`token_type=service`, and `token_no_default_policy=true` on the workstation role.
Give it only `update` on the four exact Kubernetes credential endpoints and
`auth/token/revoke-self`. Grant no token creation, renewal, role editing,
SecretID management, identity management, or generic secret access.

Keep the login token only in plugin memory. Request one selected Kubernetes
profile, then revoke the login token before returning the credential. On failure,
attempt bounded cleanup when a login token is known. Do not retry ambiguous
issuance or revocation writes blindly. Report fixed sanitized errors; a failed
cleanup does not produce a successful credential response. An orphaned login
token is bounded by its 60-second explicit maximum.

The plugin does not renew sessions, run in the background, or share a login-token
cache. The [AppRole API](https://openbao.org/docs/api/auth/approle/) defines the
SecretID and token lifetime controls. The pinned API response and actual lifetime
must be checked in acceptance, including any secrets-engine lease interaction.

### Kubernetes profile token

All four roles use `token_default_ttl=600` and `token_max_ttl=600`, with the
existing API audience. Each role selects one pre-existing ServiceAccount and
exact namespace. No generated accounts, roles, bindings, or namespace selectors
are allowed. The existing secrets mount already has a 600-second maximum.

Validate returned account, namespace, audience, and token lifetime before use.
Use the credential's actual expiry to set `expirationTimestamp`; reject missing,
expired, inconsistent, or excessive lifetime responses. Decoded claims are
consistency checks, not proof that Kubernetes accepts the identity. Acceptance
uses Kubernetes SelfSubjectReview and positive/negative API operations.

Token values pass only through the exec-plugin pipe into the client process.
They are never written to kubeconfig, a token cache, shell traces, or evidence.
Client process exit releases its in-memory cache. This does not promise secure
memory erasure. A process restart obtains another independent token.

## Workstation revocation

Destroying a SecretID alone does not stop an existing OpenBao login token from
requesting another Kubernetes credential. Workstation revocation must cover both
paths without waiting for the session's maximum lifetime.

Enrollment binds the AppRole's RoleID alias to a dedicated identity entity and
checks the entity identifier returned by login. No workstation entity has extra
identity/group policies. Unexpected or ambiguous mappings stop enrollment.

The guarded operator revocation workflow must:

1. Resolve and verify the exact enrolled role, mount accessor, alias, and entity.
2. Disable that entity, then read back the disabled state. This is the barrier
   against further use of already-issued login tokens.
3. Destroy all SecretIDs for that workstation role and verify none remain.
4. Keep the entity disabled. Remove the local credential only on the machine
   being revoked, and retain private lifecycle metadata for recovery.

OpenBao's [identity API](https://openbao.org/docs/api/secret/identity/entity/)
states that tokens associated with a disabled entity cannot be used, although
they are not themselves revoked. Do not describe entity disablement as token
deletion. Verify denial with a retained pre-disable session during acceptance.
Requests already authorized before the barrier may complete; the workflow must
not claim to recall in-flight responses.

Configuration apply must never clear a disabled entity or regenerate SecretIDs.
Re-enrollment after revocation requires fresh credentials and proof that all old
SecretIDs are destroyed and old sessions have expired before any entity is
re-enabled. If the previous session bounds or identity mapping cannot be proved,
keep that entity disabled and enroll a fresh logical workstation role through
reviewed configuration.

Existing Kubernetes tokens for pre-existing ServiceAccounts may remain usable
until expiry, including the API server's validation leeway. Revoking an OpenBao
session does not individually revoke those Kubernetes tokens. Existing upgraded
connections may continue beyond token expiry; workstation revocation is not a
promise to terminate existing exec, port-forward, or watch connections.

## Profiles and Kubernetes authority

| Profile | ServiceAccount in `kube-system` | Authority |
| --- | --- | --- |
| `observer` | `homelab-observer` | Existing view and explicit read permissions. |
| `diagnostic` | `homelab-diagnostic` | Existing observer access and approved namespace/subresource diagnostic grants. |
| `publisher` | `homelab-report-publisher` | Existing test-report publication and named publication Lease permissions. |
| `campaign-coordinator` | `homelab-campaign-coordinator` | Only `get/update` on `flux-system/homelab-test-run-lock`. |

Preserve the current RBAC in the agent-access package and the publisher grant in
the test-reports package. Review those grants explicitly; add no observer reads,
diagnostic namespaces, or publisher writes merely to simplify issuance.

Git/Flux creates the campaign Lease, following the existing publication Lease
pattern. Keep mutable holder/timestamps out of the reconciled desired fields so
Flux does not reset an active holder. The existing Lease helper supports
`existing-only` acquisition and resourceVersion-guarded replacement. The new
coordinator cannot create/delete Leases, operate on other Lease names, or run
test suites. Its acceptance exercises acquisition, renewal, contention, release,
and denial of other objects. Campaign runner credential separation remains a
follow-on issue; do not select this identity for an entire campaign.

Extend OpenBao's issuer RBAC only with the exact named ServiceAccount reads and
`serviceaccounts/token` creation needed by these roles, retaining the acceptance
identity. Give it no ability to modify ServiceAccounts, roles, or bindings.

## Local command and exec-plugin contract

`mise exec -- just kube kubeconfig` installs the four scoped contexts into the
current checkout's ignored `.kube/config`, with observer as the default. An
optional profile argument selects the initial context. Installation is local
setup, not token issuance. Each context passes exactly one approved profile to
the same standard Kubernetes exec credential plugin.

Use `client.authentication.k8s.io/v1`, `interactiveMode: Never`, and a returned
`status.expirationTimestamp`. The helper uses an absolute checkout-bound path
and the pinned `mise` toolchain, independent of the client's working directory.
Its credential-bearing stdout is reserved for the client protocol. There is no
public token-print command. Unknown profiles, wrong cluster metadata, redirected
HTTP responses, unsafe local files, and missing authentication all fail closed.

Create `.kube` with mode `0700`; stage and validate a `0600` configuration before
atomic replacement. Remove only task-owned staging files after errors. Refuse
to overwrite an existing administrator or unknown configuration: report the
explicit operator migration action instead. Do not retain credential backups
as a normal part of installation. Once installed, execution does not modify the
kubeconfig or share mutable state between worktrees.

The Kubernetes installer must not inspect the current branch, common Git
directory, primary checkout, ambient OpenBao token, default user kubeconfig, or
another checkout's credential files. The source/evidence workflows may continue
to inspect Git topology for their own purpose.

Update strict credential validators to accept only the canonical helper,
arguments, context/account mapping, and cluster metadata. Do not replace the
token-only check with acceptance of arbitrary exec programs. Retain explicit
diagnostic selection and require publisher selection on the scoped path.

## Caller compatibility and outage behavior

The current caller inventory includes:

- `scripts/verify/{agent-access,cilium,flaresolverr,homepage,logging,ntfy,openbao,plex,tautulli}.sh`;
- `scripts/diagnose/{plex-network-observe,plex-relay-status}.sh`;
- `scripts/lib/automation_data_client.py`, `scripts/openbao/reader.py`, and
  `scripts/test/web_research/live_contract.py`;
- `scripts/test/scoped-campaign-preflight.sh`,
  `scripts/test/lib/report-publication.sh`, and `scripts/test/run-campaign.sh`;
- diagnostic selection in `scripts/test/scenarios/{ntfy-publish,plex-network-policy}.sh`
  and token-only validation in `scripts/test/scenarios/openbao_issuance.py`;
- catalog validation, compatibility checks, policy tests, and shell/Python tests
  that encode the three-context or embedded-token representation.

Inspect these callers and repeat the repository-wide search before changing the
representation. Update repository-owned messages, Just consumers, guides, and
policy together. Preserve explicit operator-only credential inputs where a
workflow requires greater authority. Never silently fall back from failed
profile issuance to those credentials.

[Kubernetes exec authentication](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#client-go-credential-plugins)
supports an in-process cache until expiry, HTTP 401, or process exit. Thus an
existing process may continue making requests with its cached valid token during
an OpenBao outage. A new command has no such cache and may fail immediately.
At refresh, unavailability fails the operation; it does not extend token life.

A task lasting more than ten minutes obtains fresh credentials for later
requests through client-go. A continuously open connection is not evidence of
refresh: watch reconnection, new requests, and new port-forward/exec connections
must be checked separately. Report actual caller behavior and failures. Do not
promise uninterrupted work, replay writes, or add a shared cache or daemon.
Measure issuance count and elapsed time with repeated real commands before
considering a later performance change.

## Platform configuration and operator lifecycle

Extend the existing desired configuration, apply, read-only drift verification,
and pinned response tests for a dedicated AppRole mount, reviewed workstation
role slots, and the four issuance roles. Use logical slot names in Git; hardware
identifiers, RoleIDs, SecretID accessors, and entity IDs stay private.

Keep exact configuration inventories. Do not ignore arbitrary role or policy
prefixes. Workstation enrollment is private runtime state: entity/alias binding,
disablement, and SecretIDs are managed through guarded operator enrollment,
rotation, and revocation commands. These are not reconciled back to an active
state by ordinary configuration apply. Their readback checks must verify exact
target bindings and effective policies without putting runtime identifiers in
public reports. Add no automatic privileged configuration controller.

Expose these attended actions through one thin
`kube openbao-workstation <enroll|rotate|revoke>` entrypoint, sharing the existing
operator authentication, source checks, target-bound confirmations, sanitized
transport, and repeated mutation preconditions. Keep one implementation of the
shared lifecycle steps. Do not give ordinary workstation roles any access to
these administrative operations.

## Talos and cutover

Retain existing linked-worktree Talos `os:reader` generation, lifetime, and
authority boundary. Give it a separate `mise exec -- just talos readerconfig`
entrypoint. After cutover, `install-worktree-credentials.sh` handles only Talos;
remove its Kubernetes TokenRequest, kubeconfig parsing, and paired publication.
Talos may still depend on the existing primary-checkout administrator workflow.
This exception must not leak into Kubernetes issuance.

Keep `talos kubeconfig` only as an explicitly operator-run Talos administrator
download command, without checkout-dependent scoped behavior. All agent-facing
Kubernetes setup references move to `kube kubeconfig`; Talos reader setup is
requested separately when needed. Existing administrator kubeconfigs require
deliberate operator migration and must not be overwritten automatically.

Cut over in reviewable stages: deploy the reviewed RBAC and OpenBao role
configuration; apply it through the operator workflow; enroll the workstation;
prove issuance; then activate the new caller representation and retire Kubernetes
minting in the old installer. No merge or privileged live step is implied by
design approval. Each published candidate needs its own hosted merge gate.

## Validation and completion

Offline validation must cover profile mapping, exact RBAC, forbidden authority,
AppRole/session lifetimes, configuration drift, exec protocol, expiry checks,
atomic file installation, permissions, parallel invocations, and sanitized
failures. Exercise missing/revoked/expired authentication, unexpected login
policies/entity, denied issuance, wrong account/audience, malformed responses,
timeouts, and ambiguous writes. Capture stdout, stderr, exceptions, and retained
artifacts using synthetic secrets and assert that no secret escapes its intended
protocol pipe or protected file.

Use task-owned standalone checkouts and linked worktrees to prove the same
issuer path and isolated files, including hostile ambient admin credentials and
no primary kubeconfig. These are candidate tests, not authoritative deployed-main
evidence. Preserve Talos reader coverage separately. Test the actual exec helper
with pinned clients, not only a mocked token response.

Separately authorized registered live acceptance must prove:

| Case | Required evidence |
| --- | --- |
| Four profiles, primary and linked checkout | Kubernetes-reported identity, positive bounded use, negative permission matrix, independent local state. |
| Repeated commands and parallel worktrees | Independent issuance, no file/cache collisions, measured request counts and latency. |
| Ten-minute lifetime | Real expiry/rejection within the pinned API leeway; fresh issuance succeeds after expiry. |
| Long-running callers | Representative read/watch, named diagnostic port-forward or exec, report publication, and Lease renewal across expiry; explicitly exercise new requests/reconnections. |
| Workstation revocation | Fresh login denied and a previously issued, still-unexpired OpenBao session denied for all four issuance paths; another workstation identity unaffected. |
| OpenBao outage | Existing process uses its cached valid token; new process and expired-token refresh fail; recovery permits fresh issuance. |
| Rotation and recovery | Replacement works; prior authentication fails. Interrupted operations preserve the revocation boundary. |

Keep this acceptance bounded. Check identity and permissions for all four
profiles from both checkout forms, as the issue requires. Test shared expiry,
outage, and client-cache behavior once through the common issuance path; repeat
only where a caller uses materially different client behavior. Exercise existing
read/watch, diagnostic, publisher, and Lease workflows rather than building a
new long-running test application. Reuse current authorization-matrix assertions
and the existing issuance scenario's expiry checks. Offline tests cover malformed
responses and partial-failure combinations; live tests establish actual API and
caller behavior. Collect issuance timing during these runs, without a separate
benchmark suite or performance monitoring subsystem.

Use controlled client-side transport failure to test broker unavailability
without disrupting the production platform. Do not present it as an HA test.
Use an isolated acceptance enrollment for revocation/rotation experiments. Retain
only sanitized timing, profile, assertion, and result data. Administrative test
credentials never enter the normal exec-helper path. Actual primary-checkout
access needs separate operator authorization; agents may use task-owned
standalone checkout fixtures without touching another task's checkout.

Register the acceptance with `tests/catalog.yaml` and retain intentional
completion evidence through `mise exec -- just test record <suite-id>`.
Coordinator tests must use the existing-only Lease protocol and respect any
current holder. The campaign runner's future multi-credential architecture,
test-specific write profiles, and privileged disruption remain outside scope.

Complete focused tests, staged secret checks, independent final implementation
review, and exact-candidate hosted validation before requesting merge. Reconcile
this specification with observed results. A passing local test or an approved
design does not establish live acceptance or authorize activation.
