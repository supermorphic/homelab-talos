# OpenBao capability-scoped test execution

## Status and scope

Approved design for [issue 451](https://forgejo.infra.supermorphic.com/supermorphic/homelab-talos/issues/451),
2026-10-02. Approval includes the dedicated test profiles and the credential
distinctions below, while retaining attended steps for sensitive OpenBao operator
or recovery credentials. The operator subsequently authorized native implementation.
The feature branch implements catalog routing, isolated exec configs, RBAC and
admission fixtures, campaign separation, and the acceptance extension described
below. Deployment and live acceptance remain separately gated. Offline checks
establish source behavior; they do not establish live admission or client refresh.

This extends the deployed [credential broker](030-openbao-kubernetes-credential-broker.md)
and [workstation authentication](031-openbao-agent-credential-profiles.md).
Keep their AppRole authentication, protected machine enrollment, revocation,
verified TLS, exec credential protocol, and independent recovery root. Do not add
a controller, CRD, remote executor, daemon, or separate credential service.

Every Kubernetes-automatable catalog test must execute locally from an authorized
linked worktree using its declared profile. Keep canonical assertions, required
application credentials, exact confirmations, source checks, and cleanup. Physical
power removal and separately scoped Talos authority remain operator boundaries.
OpenBao restore, HA, and workstation lifecycle acceptance additionally retain the
approved attended OpenBao credential boundary. That attendance does not require
an administrator Kubernetes kubeconfig.

## Chosen execution model

Extend the existing exec credential helper with per-invocation, single-profile
kubeconfigs. The catalog selects a profile before the backend starts. The helper
authenticates through the existing workstation enrollment and requests only that
profile. Kubernetes clients refresh it through the same helper when necessary.

| Considered representation | Decision |
| --- | --- |
| Private single-profile config per invocation | Selected. Clear ownership and cleanup; parallel campaigns never rewrite one another's active config. |
| Reusable immutable profile configs in each checkout | Suitable for manual base-profile access, but not selected for suite sessions because run binding and cleanup are less explicit. |
| Materialized bearer token in a temporary config | Rejected. Adds token-at-rest and a separate refresh mechanism for long-running clients. |

```text
canonical catalog entry
    -> validate intent, source, and prerequisites
    -> create one suite-bound exec kubeconfig
    -> existing local test backend
    -> same-profile refresh, if required
    -> owned cleanup and result finalization
    -> remove invocation config

campaign source/admission reads -> observer
campaign Lease operations     -> campaign-coordinator
each child backend            -> child's declared profile
retained report publication   -> report-publisher
```

The caller must not select credentials from checkout topology, an ambient
KUBECONFIG, execution ownership, mutation metadata, or a permission error.
An existing broader credential is never a fallback.

## Catalog contract

Catalog schema version 3 requires an explicit `access` declaration on every suite:

```yaml
access:
  profile: test-runner
  prerequisites: []
```

`profile` replaces verifier-only `access.tier`. A null profile means no Kubernetes
credential is issued. Offline validation and the two host-local integration suites
use null with no operator boundary. The physical-loss suite uses null plus
`operator_boundary: physical-power-and-talos`. Attended OpenBao suites still name
their Kubernetes profile and declare their non-Kubernetes prerequisites.

The physical-loss exception does not issue a Kubernetes test credential. Its
existing node containment and recovery operations remain operator-run and require
an explicitly supplied `NODE_OPERATOR_KUBECONFIG`. The dispatcher does not discover
that credential, inherit it from another test, or remove it. This operator input
also performs the manual workflow's Lease and node admission checks, without
issuing auxiliary test credentials. Other null-profile suites run without
Kubernetes credentials.

Use a small validated prerequisite vocabulary: `talos-reader`, `talos-operator`,
`physical-power`, `application-credential`, `openbao-operator`, and
`openbao-recovery`. Only declare prerequisites reached by the selected scenario,
including transitive helpers. A prerequisite does not authorize credential
discovery or recovery. Missing application or OpenBao inputs stop at that boundary.

Keep `execution_owner`, `mutates_cluster`, and confirmation metadata independent:

- Kubernetes-automatable suites are shared execution, unless their declared
  attended prerequisite requires human ownership. This does not add schedules.
- An observer or debugger profile can accompany `mutates_cluster: true` when
  the test changes application state through HTTPS or an allowed exec operation.
  The mutation flag still requires coordination and cleanup.
- Correct the VPN leak probe to mutating: its temporary WAN-reference Pod is
  an actual Kubernetes mutation.
- Keep exact confirmation values. Credential availability does not satisfy them.
- Preserve existing deployed-source requirements and candidate versus authoritative
  evidence rules; credential selection cannot relax either.

An optional scenario with different Kubernetes permissions gets an explicit
catalog variant, resolved before issuance. In particular, keep default
`test.nocodb-access` on observer and register its source-pair extension on debugger.
An environment variable cannot silently broaden the default entry's profile.
Register the optional NocoDB restore extension explicitly as well, preserving its
extra confirmation and private application credential prerequisite.

Extend the existing profile definitions in `scripts/openbao/credentials.py` with
exact dedicated-suite bindings. Catalog validation compares these bindings with
the Git-managed identity and OpenBao role definitions. Do not introduce a second
generic registry framework. Reject unknown profiles, missing declarations,
dedicated profiles mapped to unrelated suites, unsupported variants, ordinary
suite use of coordinator/publisher, and contradictory attendance metadata.

The canonical catalog is the runtime authority. Fixture catalogs used by offline
tests cannot reach production credential issuance. Bind each invocation to its
suite ID, run ID, selected profile, and catalog digest; verify the binding again
on credential refresh. A changed binding ends the invocation rather than changing
its authority.

## Base profiles

| Public profile | Kubernetes authority |
| --- | --- |
| `observer` | Existing observation and explicitly required read APIs. Default profile. |
| `debugger` | Existing observation plus the bounded interactive paths required by named diagnostic workflows. Public successor to `diagnostic`. |
| `test-runner` | Ordinary admitted test resources, designated workload disruption, and only the interactive paths required by those tests. |
| `report-publisher` | Existing report namespace publication and named publication Lease. Public successor to `publisher`. |
| `campaign-coordinator` | Only get/update of the pre-created campaign Lease. |

Keep existing ServiceAccount names when renaming public profiles; a public name
change does not require replacing the Kubernetes identity. The generalized runner
uses a new Git-managed `homelab-test-runner` account. It does not inherit debugger
as a whole. Publisher and coordinator never inherit observer or test mutation.

Flux-alert diagnostics use the same observer profile. Observer and debugger have
separate Git-managed grants to create `SubjectAccessReview` queries and GET the
named monitoring Service proxy
`kube-prometheus-stack-kube-state-metrics:http`. Authorization reviews return
permission decisions for a requested user; they do not authenticate or execute
as that user. Their query authority is not limited to the exporter identity.
The diagnostic submits the configured exporter ServiceAccount and its standard
groups for the five Flux kinds and CRD list/watch checks. It fails on denied,
malformed, or ambiguous responses. The Service proxy grant permits only the
named HTTP port; missing Flux metrics remain a failed stage. No Pod proxy or
impersonation grant is added. These separate grants are bound only to observer
and debugger, not to test identities, coordinator, or report publisher. They
need no attended OpenBao password or workstation enrollment change.

### Generalized runner boundary

Grant enumerated groups, resources, and verbs through namespace Roles wherever
possible. Reuse observational grants for required inventory. No wildcard rules,
RBAC writes, impersonation, bind/escalate, ServiceAccount token requests, namespace
creation, Node mutation, or unrestricted platform-controller mutation belong here.

The following are explicit categories of test authority, not blanket namespace
CRUD grants:

| Resources and locations | Intended operations and limits |
| --- | --- |
| PVCs in the storage test's namespace | Create/read/delete fresh run claims; observe Longhorn placement. Retain fresh provisioning proof. |
| Jobs, application workloads, Services, PVCs, ConfigMaps and CiliumNetworkPolicies in `automation`, `automation-data`, `gatus`, and `media`, as required per fixture | Create/read/delete registered run fixtures. Allow update/patch only where a canonical backend requires it. Preserve isolated restore targets, network selectors, and cleanup. |
| Designated application Pods in `automation`, `media`, `portainer`, `test-reports`, and `tailscale` | Read/delete only the registered disruption targets. Do not grant general Deployment modification for Pod-recreation tests. |
| Required Pod exec/attach paths in `media` and `test-reports` | Support actual policy, persistence and network probes; both supported transport verbs where required. No automatic grant in other namespaces. |
| `flux-system/flux-canary` Secret | Named get/delete only. Preserve encrypted-Git/SOPS recreation and new-UID assertion. Do not replace this test with a ConfigMap. |
| Named Flux source/canary reconciliation resources | Read and request reconciliation through the approved annotation change only. No arbitrary spec modification. |
| Run-owned Flux alert fixture | Create/read/delete only the canonical deliberately missing-source fixture, preserving firing and resolved delivery assertions. |
| Designated temporary NocoDB extension credential fixture | Named read/update and bounded clearing only; no namespace-wide Secret reads or generic Secret creation. |

Use a Git-created empty, named credential fixture for the optional NocoDB restore
extension, serialized by the campaign Lease. The operator/application workflow
supplies its run credential through the existing protected path. Check that the
fixture is empty or owned by the same run before writing; clear the value and run
ownership during checked cleanup. Do not retain the credential in Git, logs, or
reports. The non-extension path never inspects that Secret.

The fixture is `automation-data/nocodb-restore-application-credential`. Flux
creates it with `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`, so reconciliation
does not reset a credential during the probe. Fill and clear requests use atomic
UID and resourceVersion checks; cleanup refuses a replacement fixture.

### Enforce resource shape as well as RBAC

Kubernetes RBAC alone does not restrict a created workload's service account,
volumes, or executable specification. Use the built-in validating admission policy
facility for these concrete constraints; do not add an admission server. Scope
rules to the new issued identities and the registered resources, with denial on
evaluation failure. Git/Flux manages policies before the identities receive grants.

For generalized runner requests, enforce:

1. The declared resource families, namespace, fixture name, and ownership metadata.
2. Approved workload service accounts, token mounting, security settings, images,
   volume/Secret references, command structure, and validated runtime arguments.
3. Fixed executable test helpers in Git-owned ConfigMaps where credential-bearing
   Jobs require executable content. The runner cannot replace those scripts or
   their mounts. Preserve the existing scripts' assertions and cleanup behavior.
4. Service selectors, restore host mappings, and policy selectors that address only
   the appropriate test resources; no production Service capture or broader policy.
   Validate restored application host mappings against the allocated scratch
   database Service through a native admission parameter. Bind the parameter
   lookup to the family's mandatory admitted labels and namespace; deny creation
   when the Service is absent or belongs to another run. Apply the IP check to
   parent creation and updates. Owned-parent deletion must remain possible after
   Service removal. Retained Services from another run of the same family block
   new acceptance until checked cleanup removes them.
5. Immutable ownership and protected object fields on update; designation and
   ownership checks on deletion. Cleanup uses explicit object names and recorded
   UIDs rather than granting collection deletion.
6. Only the intended reconciliation annotation or deliberate failure-fixture shape
   for Flux requests. Name-scoped patch permission alone is insufficient.
7. For report-persistence exec, admit only the canonical direct `readlink`,
   `sha256sum`, and `cat` argument vectors against the fixed generation/catalog
   paths and validated canonical report paths, in the `caddy` container, without
   stdin or a TTY. Apply this CONNECT policy to both supported exec transports.
   Reject shells, alternate commands/containers, and write operations. The
   publisher remains the only ordinary identity with report installation access.

Controller-created children are covered by the admitted parent template and the
existing controller identity. Validate every parent write path that can change a
Pod template, including updates; do not rely on a run label alone. Validate
interactive target names separately from resource-creation rules. Admission
matching uses the authenticated identity, not an optional client-supplied label
that could skip the check. RBAC does not impose these command/shape restrictions;
the admission policies do, and their absence must block profile activation.
Other approved production exec paths represent access to that application's
runtime and data. Do not claim that Kubernetes RBAC constrains SQL/file operations
inside them.

Use fixed Git fixtures only where they remove otherwise broader authority. Do not
replace real consumer checks with synthetic consumers, replace fresh provisioning
with an existing claim, or reduce conformance/connectivity coverage. Fixture
allocation changes must preserve the test's independently checked outcome.

## Dedicated profiles

Each profile below represents materially different authority. Bind it only to
the listed canonical entry or entries. Each uses an existing Git-managed account
issued through the same OpenBao interface; none is a default or an error fallback.

| Profile | Catalog binding | Required distinction |
| --- | --- | --- |
| `test-flux-restart` | `test.flux-restart` | Restart the four named Flux controller Deployments and request named source/application reconciliation. Restrict patch shape to the intended restart/reconcile fields. Wait up to five minutes for all active source consumers to report their current generation and main revision before the unchanged final Flux verifier. |
| `test-cilium-connectivity` | `test.cilium-connectivity` | Canonical privileged connectivity workloads, test namespace/account lifecycle, cluster policy fixtures, Cilium runtime access, and canonical failure diagnostics. |
| `test-node-reschedule` | `chainsaw.resilience.plex-cross-node-reschedule` | Named cluster Node scheduling changes plus the required Plex/media disruption and storage observations. No unrelated Node-field changes. |
| `test-conformance` | `conformance.quick`, `conformance.certified` | Exceptional Kubernetes administrator authority required by the current Sonobuoy/conformance workload and RBAC lifecycle. Both modes share the profile. |
| `test-openbao-issuance` | `test.openbao-issuance` | The acceptance and issuer-boundary probe resources and required runtime transports. This does not belong in ordinary application testing. |
| `test-openbao-ha` | `test.openbao-ha` | Sequential exact OpenBao member eviction, acceptance workload, and named member tunnels. Retain attended OpenBao operator authentication. |
| `test-openbao-restore` | `test.openbao-restore-drill` | Isolated scratch resources, scratch Secret, storage observations and scratch runtime access. Retain attended snapshot/recovery inputs. |
| `test-openbao-lifecycle` | `test.agent-credentials` | Observer reads and exact OpenBao member tunnels for attended workstation identity lifecycle acceptance. No member eviction or issuer-probe capability. |

Member-tunnel authority covers runtime ports on the three named OpenBao Pods.
The canonical test helpers use port `8200`. The enforced Kubernetes boundary is
the Pod target; it does not provide a per-port permission boundary. OpenBao
password and recovery steps remain attended as described below.

The conformance profile must be described honestly as privileged. Bind its
pre-existing account through Git; allow the pinned backend's ephemeral workload
and RBAC lifecycle. Its token can exercise that authority during its lifetime.
Neither the catalog guard nor token expiry confines an already-created workload.
Retain checked cleanup and the separate authorization required for live execution.

Keep Cilium's successful path and failure diagnostics in the same selected
connectivity profile. Enumerate the pinned client's API groups/resources and
feature-dependent fixtures; do not switch profiles when diagnostics encounter a
denial. Remove cleanup of unrelated failed production Pods: that housekeeping is
not part of connectivity proof. Preserve the canonical test selection and report
diagnostic or cleanup failures separately. Validate enabled feature coverage at
acceptance; a client upgrade requires renewed permission review.

The three Cilium fixture namespaces are temporary and remain test-owned. Git
defines two unbound ClusterRoles for their fixed namespaced capabilities; it does
not install resources into namespaces that do not yet exist. The canonical wrapper
creates the namespaces and records each UID and run annotation. It then creates a
fixed temporary RoleBinding in each namespace. The dedicated profile can bind only
those two ClusterRoles. Admission requires the correct role for the namespace,
the dedicated Cilium account as the sole subject, the fixed binding name, and run
ownership metadata. The wrapper checks the namespace UID before binding or cleanup.
The bindings disappear with the canonical namespace cleanup. No fixture role is
bound cluster-wide, and the profile cannot create or escalate roles.

For OpenBao scratch restore, pre-create a dedicated empty fixture namespace,
ServiceAccount, and fixed isolation policy through Git. Allocate the scratch
instance to one run under the campaign Lease. Remove its owned workloads, scratch
Secret/configuration and volumes on completion; verify both storage deletion and
return to the empty fixture baseline. Keep production unchanged and retain all
snapshot/configuration/issuance-denial assertions. This avoids issuing arbitrary
namespace or RBAC creation solely to obtain an isolated restore environment.
The live drill requires a healthy credential broker; it does not replace the
independent operator disaster-recovery procedure when that broker is unavailable.

OpenBao's issuer allowlist expands to these explicitly registered accounts.
Update its desired configuration, TokenRequest permissions, verification and
negative acceptance together. The earlier broker-only permission boundary must
not be described as unchanged after privileged test profiles are introduced.

## Automatic Kubernetes credentials and attended OpenBao credentials

The `test-openbao-*` profiles are Kubernetes test identities. OpenBao
issues their short-lived Kubernetes tokens through the workstation credential
helper. These tokens authorize the declared Kubernetes operations; they do not
replace an OpenBao operator password or recovery material.

| Test | Automatic access through OpenBao-issued Kubernetes credentials | Inputs that remain person-supplied |
| --- | --- | --- |
| `test.openbao-issuance` | Acceptance workloads and the dedicated issuer-boundary test. See the separate issuer authority decision below. | No OpenBao operator password is used by the current test. Retain its exact execution confirmation and source checks. |
| `test.openbao-ha` | Named member eviction, acceptance workload, and named member tunnels. | Retained OpenBao operator password for authenticated OpenBao operations. |
| `test.openbao-restore-drill` | Isolated scratch resources, storage checks, and scratch runtime access. | Snapshot and matching recovery metadata, matching static seal key, and the operator password retained with the snapshot. |
| `test.agent-credentials` | Observer reads and named member tunnels for workstation lifecycle acceptance. | Retained OpenBao operator password for creating, rotating, and revoking the test's OpenBao workstation identities. |

Issuance's real ordinary-debugger denial control additionally requires an
explicit `OPENBAO_DIAGNOSTIC_KUBECONFIG`. Install the separate base config with
`mise exec -- just kube kubeconfig debugger`, then supply its absolute path.
The test checks its actual identity and cluster before using it for the existing
OpenBao exec denial assertions. It cannot issue an unbound debugger child.
The server issuer credential remains inside the issuer workload.

The restore drill uses Git-created `openbao-restore-test` isolation: Namespace,
tokenless scratch ServiceAccount, deny-all network policy, and a RoleBinding for
the dedicated test driver. The scratch workload gets no Kubernetes authority.
The test checks these objects and retains their UIDs before requesting sensitive
inputs. It creates only its bounded StatefulSet, PVC, Secret and ConfigMap;
cleanup deletes individual owned resources with fresh UID/resourceVersion checks.
It preserves the Namespace and Git baseline, then verifies empty scratch state
and removal of its observed storage objects. Retained failed-run cleanup remains
an attended, explicitly confirmed operator command.

All rows retain their required confirmations and preconditions. A person supplies
the sensitive OpenBao inputs through the existing attended workflow; automatic
Kubernetes token issuance does not make those steps unattended. OpenBao bootstrap,
administrative configuration, and independent disaster recovery remain
operator-owned.

The same separation applies to application credentials outside OpenBao.
`test.n8n-persistence` uses the `test-runner` Kubernetes profile, but a person still
supplies `N8N_CANARY_TOKEN` for its authenticated canary request. Its catalog entry
declares `application-credential` and retains human execution ownership. The
Kubernetes issuer does not supply or replace that application token.
`test.e2e.flux-alert-delivery` likewise retains the protected
`NTFY_FLUX_ALERT_TOKEN_FILE` supplied through the ntfy operator workflow. Its
Kubernetes profile is `test-runner`, and its catalog entry declares
`application-credential` with human execution ownership.
`test.automation-data-provisioning` keeps its person-supplied
`AUTOMATION_DATA_PROVISIONING_TOKEN` for the private provisioning webhook. Its
Kubernetes access uses `test-runner`; its catalog entry remains human-owned with
the `application-credential` prerequisite. Fixed application test Jobs continue
to use their existing Git-managed Secret references. Kubernetes credential
issuance does not create or replace those application passwords.

The OpenBao server's own Kubernetes **issuer credential** is a third, distinct
credential. It is not a workstation test token and must not be distributed in a
workstation kubeconfig. Ordinary diagnostic credentials continue to exclude
OpenBao exec and port-forward access. The dedicated profiles introduce
test-specific exceptions to that access boundary.

In particular, `test.openbao-issuance` exercises the actual issuer identity.
Automating its Kubernetes access therefore involves sensitive issuer authority,
even without distributing the issuer credential in a kubeconfig. The design
approval includes this separate authority expansion; the earlier agreement to
retain attended passwords and recovery inputs alone did not authorize it.
Enabling the profile still requires the deployment controls below, and privileged
live execution requires separate authorization.

## Credential lifecycle and local state

Keep the 600-second default and maximum Kubernetes token lifetime. The pinned
Kubernetes TokenRequest implementation rejects requests below 600 seconds. Keep
the 60-second OpenBao login-token bound and revoke the login token after issuance.
Validate returned account, namespace, audience and actual expiry as today.

Use an owner-checked private invocation directory below the assigned checkout's
`.kube/` tree, separate from `.test-results` and report archives. Directories are
0700 and configs are 0600 regular files; reject symlinks and unsafe ownership.
Each config contains one cluster, user, context, and exact exec invocation. Token
bytes remain in the exec pipe/client memory. Do not put them in argv, environment,
config files, caches, exceptions, or evidence.

Clients obtain a fresh credential for the same profile when their cached token
expires. Long conformance, Cilium, and campaign operations must prove refresh
through the actual pinned client. No session daemon or cross-process token cache
is needed. An OpenBao outage may leave a cached token usable until expiry; it does
not authorize retaining it longer or switching credentials. Existing streams or
workloads can outlive the token; cleanup remains a separate obligation.

On issuance failure, RBAC denial, loss of coordination, or failed refresh, stop new
test actions and enter checked cleanup using the same declared authority. Record
primary assertion, cleanup, and recovery separately. If that authority cannot
clean up, retain sanitized object identities and mark the run broken. Do not retry
with an operator credential. Release the Lease only while still its holder; then
remove private configs, including on signals and failed setup.

The shared workstation enrollment remains a trusted-process boundary. Any process
able to use it can request endpoints granted to that enrollment. Suite binding is
enforced by the normal repository issuance path, not by OS isolation or proof of
which source code made an HTTP request. Do not claim stronger isolation. Keep
exact endpoint policies, explicit catalog routing, short tokens, and auditability.

## Runner and campaign integration

Use one small shared routing implementation across catalog, Chainsaw, probe,
direct-dispatch, and Sonobuoy entrypoints. Existing backend scripts remain the
canonical tests. Thread the resolved config through Just variables, positional
arguments, environment and Python subprocesses; do not leave literal
`.kube/config` paths that bypass the selected invocation.

Nested verification within a test retains the parent's suite identity for backend
operations. It cannot acquire a different test profile implicitly. Each parent
declares the prerequisites used by its nested verifiers. The ntfy
publication test declares Talos reader access for its foundation preflight.
Separate orchestration source/admission reads may use observer. Refactor explicit diagnostic
context selection to validate and use the declared config rather than search a
multi-context file. Missing or mismatched authority fails before mutation.

The campaign coordinator owns only the named, Git-created
`flux-system/homelab-test-run-lock` Lease. Use `existing-only` acquisition and
preserve resourceVersion contention, duration/renewal, holder validation, loss
markers, and release semantics. Children may read that named Lease to recheck
ownership; they never receive its write authority. A standalone mutating suite
uses the same separate coordinator path. Keep node admission checks and repeat
relevant live preconditions immediately before consequential mutation.

Keep the publisher's identity, named publication Lease, source checks, secret
scans, atomic install, and candidate-evidence rules. Publication receives a
publisher-only config. It neither reuses the suite credential nor bootstraps Talos
access. A finalized run can still be published without rerunning its suite.

Record eligibility uses explicit catalog access and prerequisites instead of
inferring authority from a linked checkout or human/shared metadata. The normal
published campaign retains its exact deployed-main source checks. A candidate
record session remains candidate evidence and never updates authoritative latest
links, Homepage status or last-run metrics. Preserve each suite's stronger source
guard, particularly attended OpenBao operations and physical node testing.

For a standalone recorded report-persistence test, set `TEST_REPORT_RUN_ID` to
one existing published canonical run. The resolver validates its identifier;
the native backend checks the selected report, catalog entry, and PVC before
and after Pod replacement. Without that input, a campaign selects its latest
child with successful or idempotent publication. Missing or invalid references
fail before the child starts. The test retains its mapped `test-runner` identity.

### Identity-audit exceptions

`verification.agent-access` and `test.agent-credentials` intentionally test several
base identities. Declare a finite `access.profile_checks` list for these two
entries only. Issue a separate config for each checked base identity; never combine
them into an administrator config or use impersonation to simulate issuance.
Reject this field on ordinary suites and reject dedicated-profile probes through
it. Dedicated acceptance occurs through each dedicated profile's mapped test.

Keep workstation-lifecycle acceptance standalone. It releases its operator section
of the campaign Lease before exercising coordinator contention/expiry and then
reacquires checked sections for cleanup. A parent campaign must not hold the same
Lease continuously around that test.

## Deployment and compatibility

Use one attended maintenance transition for the existing workstation. Updating a
checkout to this revision immediately changes its catalog callers to isolated
invocation configs. Those callers, including observer verification and recorded
campaigns, cannot run with the earlier enrollment metadata. There is no separate
caller activation switch. Legacy issuance endpoints preserve only the explicit
legacy base routes; they do not keep the new catalog callers working during the
transition.

1. Finish active tests and campaigns, including their cleanup and publication,
   before updating their checkouts. Pause scheduled use of the affected callers.
   The operator must have independent Kubernetes access and the retained OpenBao
   operator password available for the maintenance interval.
2. Merge the reviewed Git changes and let Flux deploy the identities, RBAC,
   admission rules, immutable helpers and fixed fixtures. Update the operator's
   checkout to clean deployed `main`. Catalog verification remains unavailable
   until the enrollment upgrade; use the guarded operator workflow for setup.
3. Apply the OpenBao roles and exact endpoint policies using the guarded operator
   configuration workflow. Before any configuration write it compares deployed
   identities, permissions, admission policies and bindings, helper programs, and
   the restore fixture baseline against Git. Admission policies must have current
   type-checking status with no expression warnings. Known API defaults are
   allowed; extra grants and admission bypass selectors are rejected. Confirmation
   binds the source digest and object UIDs. The NocoDB credential fixture is checked
   through metadata and type only.
4. Upgrade an active workstation enrollment with the attended `rotate` action.
   It validates a replacement, writes the current cluster metadata, then destroys
   the old SecretID. Use `enroll` only for a new workstation or after the guarded
   revocation/re-enrollment procedure; it rejects an already active enrollment.
   Never edit or copy private enrollment material by hand.
5. Install the separate base configs and run the recorded lifecycle acceptance.
   Resume ordinary callers only after that acceptance passes. Keep the initiative
   open while the full catalog and native-client acceptance below run. Retire the
   old public `diagnostic`/`publisher` endpoints and multi-context paths only after
   new-name acceptance, then repeat the affected checks.

If prerequisite deployment or configuration validation fails, leave the affected
callers paused and correct the Git/deployment mismatch before retrying. If
workstation rotation is interrupted, use the
[guarded lifecycle recovery](031-openbao-agent-credential-profiles.md#operator-lifecycle-and-independent-recovery)
with independent operator access; do not restore old private metadata or switch a
failed catalog test to operator credentials. Broker unavailability uses the
[independent OpenBao recovery procedure](030-openbao-kubernetes-credential-broker.md#seal-and-recovery-ownership).
Keep the maintenance interval open until configuration, enrollment, and lifecycle
acceptance succeed. Publication-only failure resumes the retained record without
repeating a successful test.

The public base-profile installer remains `mise exec -- just kube kubeconfig`,
defaulting to observer. Explicit base-profile requests produce their own config
without rewriting another active invocation. Dedicated test credentials are
selected through canonical catalog dispatch, not a general profile override.
Request Talos reader credentials separately, only for suites that need them.
The dispatcher prepares the assigned `.talos/config` with
`mise exec -- just talos readerconfig` when required and checks exactly `os:reader`.
It clears undeclared ambient Talos input. The physical-loss workflow retains its
explicit operator boundary.

For an existing active enrollment, the operator runs these commands from clean
deployed `main`, supplying the existing absolute operator kubeconfig path. Each
command prompts privately for the OpenBao password and requires its exact
source/target confirmation:

```sh
OPENBAO_RECOVERY_RECIPIENT="$(mise exec -- yq -er '.sops.age[0].recipient' kubernetes/apps/security/openbao/app/openbao-seal.sops.yaml)" \
OPENBAO_OPERATOR_KUBECONFIG=/absolute/path/to/operator-kubeconfig \
  OPENBAO_CONFIG_AUTH=userpass mise exec -- just kube openbao-config-apply
OPENBAO_OPERATOR_KUBECONFIG=/absolute/path/to/operator-kubeconfig \
  mise exec -- just kube openbao-workstation rotate
```

The recipient comes from public SOPS metadata; this step does not decrypt the seal
artifact or read the age private key.

The combined `just bootstrap openbao-agent <absolute-operator-config>` command
applies configuration and uses `enroll`, so reserve that path for new enrollment.
After an existing enrollment has been rotated, its `test` starting step can run
recorded lifecycle acceptance without repeating enrollment. The wrapper ends
operator kubeconfig inputs before canonical dispatch; the test still prompts for
its attended OpenBao password. Do not use a failed test's operator recovery command
as an automatic retry.

After enrollment, install separate base configs with
`mise exec -- just kube kubeconfig <profile>` for `observer`, `debugger`,
`test-runner`, `report-publisher`, and `campaign-coordinator` as needed. Observer
uses `.kube/config`; other current base profiles use `.kube/<profile>.config`.
An invocation remains separate under `.kube/invocations/`. Enrollment schema 1
supports only finite legacy base routes; current invocation and dedicated issuance
require the attended schema 2 enrollment. No metadata file is edited by hand.

Changes to the cluster still require the repository's feature-branch workflow,
the applicable CI validation gate, and explicit merge authorization. Design
approval is not merge approval, authorization for privileged live acceptance, or
permission to supply operator secrets to an agent.

## Validation and completion

Use focused offline tests for the new catalog schema, every dedicated binding,
all direct dispatch paths, nested credential propagation, private config
validation, parallel run isolation, same-profile refresh, no fallback, and token
redaction. Exercise campaign coordinator/child/publisher separation, contention,
Lease loss, signals, publication resume, and cleanup failures. Preserve existing
source-binding and evidence-authority regression tests.

Validate rendered RBAC and admission policies with independent positive and
negative invariants. Include unrelated workload deletion, alternate service
accounts, forbidden volumes/Secret references, changed executable fixtures,
broader network selectors, unauthorized Flux fields, Node writes, RBAC changes,
and attempts to choose dedicated profiles through unrelated suites. Policy-source
inspection and `auth can-i` alone do not prove admission behavior.

The core offline suite also compiles the rendered admission expressions with the
Kubernetes 1.35 CEL compiler, pinned to the cluster's Kubernetes patch version.
It also runs Kubernetes' schema-aware policy type checker against built-in resource
and parameter schemas extracted from that release's OpenAPI document. These checks
catch static type errors that the Python CEL request evaluator does not check.
Mixed-type map and list literals use `dyn()` on their values. Policies that iterate
over fields of typed resources explicitly convert those resources with `dyn()`.
Both retain the exact permitted field comparisons. Offline checks complement the
request allow/deny tests and deployed policy type-checking status; custom resources
and subresources still rely on the deployed status guard for schema checks.

Kubernetes omits empty optional admission request fields. Main-resource checks
accept either an absent or empty `request.subResource`; cluster-scoped checks
accept either an absent or empty `request.namespace`. Named namespace and
subresource checks retain exact comparisons. The dedicated request fixtures
verify that omitting either or both empty fields preserves every allow/deny
decision, including forbidden workload shapes and nonempty field values.

For a registered mapped test whose ordinary run is too short, set
`TEST_ACCESS_ACCEPTANCE_CONFIRM=verify:scoped-access:ttl-and-denials` when invoking
its existing `mise exec -- just test record <suite-id>` workflow. Retain the suite's
own confirmation and attended prerequisites. This option is accepted only for
catalog test, Chainsaw, probe and Sonobuoy families with a declared Kubernetes
profile. Verification and null-profile workflows reject it. The option is removed
from the backend environment so nested verifiers cannot request the extension.

The original backend must pass first. Its assertions and JUnit evidence remain.
The extension then keeps one real pinned `kubectl proxy` client alive using the
same bound config. It checks the Kubernetes-reported identity before and after
600 seconds plus skew and API-expiry allowance (about 695 seconds total).
A separate original bearer remains only in memory and must receive API 401 after
expiry; a new authenticated reply from the same cached client proves refresh.
An open stream or surviving process alone is insufficient.

All non-administrator profiles must also receive API 403 for an unrelated
server-dry-run Secret create. Write-capable profiles separately require a denial
that names their validating admission policy for a forbidden dry-run request:
Flux replica change, Node label change, foreign Cilium Namespace, unrelated probe
Pod, or wrong restore ConfigMap. JSON patches use fresh observed UID and
resourceVersion tests. Admission may return `Invalid` with HTTP 422 (Kubernetes'
default validation reason) or `Forbidden` with HTTP 403. The assertion requires
the exact policy, binding and intended validation message. Pod probes provide
the fields read by the policy so a missing-field evaluation error cannot pass.
Protocol errors, unrelated schema errors and RBAC-only denials cannot pass the
admission assertion. Conformance keeps its approved administrator exception and
proves expiry/refresh without claiming a narrowed write boundary. The extension
creates no persistent API object and writes only fixed labels/classifications into
the existing diagnostics and JUnit artifacts. A failed extension fails the run
while retaining the original backend's evidence.

These checks supplement the required actual native Cilium, Sonobuoy and campaign
lifetime checks. Their implementation and offline fixtures are not live evidence.

Quick Sonobuoy usually finishes before one token lifetime. A successful quick
result plus the `kubectl` extension alone does not prove native Sonobuoy refresh.
With the same opt-in acceptance guard, the canonical quick backend generates its
normal native manifest and adds one fixed 695-second init container to the E2E
plugin Pod. It uses the existing pinned Python probe image and a sleep command.
All E2E commands, environment, selection, permissions and other resources remain
unchanged. Sonobuoy's own `run --wait` process continues making authenticated API
status requests across expiry. The quick aggregator timeout becomes 1595 seconds
and CLI wait becomes 32 minutes, preserving the original execution time budgets
after the delay. Default quick and certified commands remain unchanged.

After native completion, retain the original E2E JUnit and require at least
695 seconds in that same native command. Record this check in the existing
Sonobuoy diagnostics and JUnit fragments. A premature completion fails acceptance
while preserving E2E results and performing normal cleanup. The later `kubectl`
extension still proves original-bearer rejection and authenticated refresh.

After deployment and separate authorization, retain canonical live evidence for:

- Every dedicated profile, including both Sonobuoy modes and actual client refresh
  across a token lifetime. Use no standing administrator Kubernetes kubeconfig.
- Ordinary runner creation, application disruption, restore fixtures and cleanup;
  actual permitted API operations plus safe negative requests against unrelated
  resources. Prefer server dry-run denials where it proves the intended boundary.
- Observer/debugger suites, application-state tests with observational Kubernetes
  profiles, optional scenario variants, and independent worktrees/campaigns.
- Loss/expiry/outage behavior, cleanup failure reporting, source drift and distinct
  coordinator/publication permissions. No broader-credential recovery.
- Attended OpenBao suites with operator-supplied OpenBao credentials and the
  dedicated Kubernetes profiles; the agent does not handle retained secret values.

Run relevant repository checks, commit-time secret/staged-blob checks, independent
final review, and fresh validation for the exact candidate/base under the applicable
repository CI gate.
The optional full local CI run is not automatic. Reconcile this specification with
the implemented and validated result before merge of completed work. Keep the
issue open until the full runnable catalog and required live acceptance are proven.

## Catalog mapping at the audited baseline

The implementation audit includes Forgejo `main` at `e04de75a4a`: 143 entries,
of which 49 are offline validation and 94 are listed below. All offline validation
entries receive `profile: null`; the two host-local tests and physical-loss test
also retain null profiles. The table specifies Kubernetes profiles; prerequisite
and execution ownership metadata remain separate. Optional variants are separate
entries and do not change the default scenario's authority.

| Catalog entry | Profile |
| --- | --- |
| `verification.metrics-server` | observer |
| `verification.cilium` | debugger |
| `verification.openbao` | observer |
| `verification.flux` | observer |
| `verification.foundation` | observer |
| `verification.n8n` | observer |
| `verification.automation-data` | observer |
| `verification.nocodb` | observer |
| `verification.storage` | observer |
| `verification.csi-driver-smb` | observer |
| `verification.media-storage` | observer |
| `verification.plex` | debugger |
| `verification.intel-gpu-plugin` | observer |
| `verification.qbittorrent` | observer |
| `verification.prowlarr` | observer |
| `verification.sonarr` | observer |
| `verification.radarr` | observer |
| `verification.lidarr` | observer |
| `verification.seerr` | observer |
| `verification.tautulli` | debugger |
| `verification.flaresolverr` | debugger |
| `verification.qbit-manage` | observer |
| `verification.monitoring` | observer |
| `verification.logging` | debugger |
| `verification.security-alerts` | observer |
| `verification.gatus` | observer |
| `verification.portainer` | observer |
| `verification.test-reports` | observer |
| `verification.homepage` | debugger |
| `verification.trivy` | observer |
| `verification.tailscale-operator` | observer |
| `verification.tailscale-subnet-router` | observer |
| `verification.ntfy` | debugger |
| `verification.alertmanager-ntfy` | observer |
| `verification.mylar3` | observer |
| `verification.komga` | observer |
| `verification.agent-access` | observer; explicit base-profile checks |
| `test.cilium-connectivity` | test-cilium-connectivity |
| `test.storage-provisioning` | test-runner |
| `test.flux-canary` | test-runner |
| `test.n8n-restore-drill` | test-runner |
| `test.automation-data-provisioning` | test-runner |
| `test.nocodb-access` | observer |
| `test.nocodb-local-integration` | null (host-local) |
| `test.web-research-local-integration` | null (host-local) |
| `test.web-research-live-contract` | debugger |
| `test.nocodb-restore-drill` | test-runner |
| `test.automation-data-restore-drill` | test-runner |
| `test.ntfy-publish` | debugger |
| `test.flux-restart` | test-flux-restart |
| `test.portainer-persistence` | test-runner |
| `test.n8n-persistence` | test-runner |
| `chainsaw.smoke.cluster.default` | observer |
| `chainsaw.smoke.cluster.flux-ready` | observer |
| `chainsaw.smoke.cluster.diagnostics-self-test` | observer |
| `chainsaw.smoke.media.qbittorrent` | observer |
| `chainsaw.smoke.media.qbit-manage` | observer |
| `chainsaw.smoke.platform.all` | observer |
| `chainsaw.smoke.platform.cluster` | observer |
| `chainsaw.smoke.platform.flux` | observer |
| `chainsaw.smoke.platform.gateway` | observer |
| `chainsaw.smoke.platform.dns` | observer |
| `chainsaw.smoke.platform.cilium` | observer |
| `chainsaw.smoke.platform.longhorn` | observer |
| `chainsaw.smoke.platform.n8n` | observer |
| `chainsaw.smoke.platform.portainer` | observer |
| `chainsaw.smoke.platform.smb` | observer |
| `chainsaw.smoke.platform.tailscale` | observer |
| `diagnostics.cluster` | observer |
| `diagnostics.flux-alerts` | observer |
| `test.integration.media-hardlink` | debugger |
| `test.plex-network-policy` | test-runner |
| `test.e2e.qbit-manage-policy` | test-runner |
| `test.e2e.flux-alert-delivery` | test-runner |
| `chainsaw.resilience.qbittorrent-vpn-disconnect` | test-runner |
| `chainsaw.resilience.qbittorrent-pod-recreation` | test-runner |
| `chainsaw.resilience.plex-cross-node-reschedule` | test-node-reschedule |
| `chainsaw.resilience.test-reports-persistence` | test-runner |
| `chainsaw.resilience.tailscale-subnet-router-replica-recovery` | test-runner |
| `test.resilience.node-abrupt-loss` | null (physical/Talos operator boundary) |
| `probe.qbittorrent` | test-runner |
| `probe.vpn-leak` | test-runner |
| `probe.dns-isolation` | debugger |
| `conformance.quick` | test-conformance |
| `conformance.certified` | test-conformance |
| `test.openbao-restore-drill` | test-openbao-restore |
| `test.openbao-issuance` | test-openbao-issuance |
| `test.openbao-ha` | test-openbao-ha |
| `test.agent-credentials` | test-openbao-lifecycle |
| `test.mylar3-integrity` | debugger |
| `test.mylar3-acceptance` | test-runner |
| `test.komga-acceptance` | observer; attended application credential |
| `test.nocodb-access-source-pair` | debugger; attended application credential |
| `test.nocodb-restore-drill-extension` | test-runner; attended application credential |

## Primary references

- [Kubernetes RBAC and named-resource limitations](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Workload creation and effective namespace authority](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [Kubernetes 1.35 validating admission policies](https://v1-35.docs.kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Kubernetes 1.35.6 minimum TokenRequest duration](https://github.com/kubernetes/kubernetes/blob/v1.35.6/pkg/apis/authentication/validation/validation.go)
- [Pinned Sonobuoy execution](https://github.com/vmware-tanzu/sonobuoy/blob/v0.57.5/pkg/client/run.go)
- [Pinned Cilium connectivity lifecycle](https://github.com/cilium/cilium-cli/blob/v0.19.6/vendor/github.com/cilium/cilium/cilium-cli/connectivity/check/deployment.go)
