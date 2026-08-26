# Agent cluster access

## Purpose and scope

This guide explains how an agent gets limited cluster access from a linked worktree and
where that access stops. It describes the current operating model; it does not define
repository policy or executable behavior.

[`AGENTS.md`](../../AGENTS.md) defines the authority boundary. Agents may use approved
repository workflows to create task-scoped credentials and perform scoped verification
without asking the operator to run those workflows for them. An agent must not adopt or
use a write, administrator, elevated, or break-glass credential unless the operator
explicitly authorizes that credential for the specific task.

Linked worktrees start without cluster credentials. This prevents credentials from being
copied into every checkout and makes the authority available to a task explicit. Most
source-only work needs no live access. When approved live verification does need it, the
agent normally installs its own scoped credentials from inside its assigned worktree:

```bash
mise exec -- just talos kubeconfig
```

This is normally an agent-owned action, not an operator handoff.

## Mental model

The repository workflow, the credential, and Kubernetes role-based access control
(RBAC) have different jobs:

```text
linked worktree
  ↓
normal repository work
  ↓
live cluster access becomes necessary
  ↓
mise exec -- just talos kubeconfig
  ↓
worktree-local scoped credentials
  ↓
approved verifier or read-oriented workflow
  ↓
Kubernetes authentication identifies the scoped user
  ↓
RBAC allows or denies each requested verb and resource
```

Agent worktrees start without cluster credentials, and most repository work does not
require them. When an approved task needs live cluster inspection or scoped
verification, the agent runs `mise exec -- just talos kubeconfig` from that worktree to
create the scoped credentials locally. Credential creation is demand-driven; it is not
part of worktree initialization.

`mise exec -- just ...` is the required interface for established repository workflows.
It selects the pinned tools and repository recipe. It does not grant authority by itself.
Authority comes from repository policy, the approved workflow, and the permissions of the
credential used by that workflow.

## What the installer creates

**Location matters.** The recipe selects one of two credential paths from the checkout
location:

- In a linked worktree, it creates only `homelab-observer`, `homelab-diagnostic`, and a
  Talos `os:reader` identity.
- In the main clone, it uses the existing Talos `os:admin` identity to download and
  replace the ignored Kubernetes administrator kubeconfig. Its current context is
  `homelab-admin`; the client certificate authenticates the Kubernetes user `admin` in
  the `system:masters` superuser group.

The main-clone path refreshes `.kube/config`; it does not create scoped worktree
credentials or replace the main clone's Talos identity. It is outside this guide's
scoped agent-access model. Thus, the same `mise exec -- just talos kubeconfig` command
produces different Kubernetes authority depending on where it runs.

In a linked worktree, `mise exec -- just talos kubeconfig` creates two ignored files with
mode `0600`:

- `.kube/config` contains 30-day Kubernetes token credentials for exactly two contexts:
  `homelab-observer` and `homelab-diagnostic`. `homelab-observer` is the current context.
- `.talos/config` contains a 90-day Talos credential with exactly the `os:reader` role.

The installer uses the approved repository workflow to mint the scoped credentials. It
does not copy the administrator kubeconfig or Talos identity into the worktree. Do not
copy, symlink, or commit either credential file. Re-run the installer from the worktree
when a scoped credential expires. Keep SOPS key material out of agent sessions.

## How RBAC enforces the boundary

Kubernetes first authenticates the token in the selected kubeconfig context. It then
uses RBAC to decide whether that identity may perform the requested verb on the requested
resource. For example, a rule can allow `get` on Pods while denying `delete` on
Deployments. An operation is denied when no applicable RBAC rule grants it.

Both scoped Kubernetes identities inherit the built-in `view` role and the explicit
read permissions listed in the reference section below. Neither identity can read
Kubernetes Secret bodies or use ordinary mutation verbs. The diagnostic identity adds
only `create` on the `pods/exec` and `pods/portforward` subresources.

RBAC is a hard technical boundary, but it is not the complete authority model. A
credential can have a capability that repository policy permits only through a narrower
workflow. In particular, possession of `homelab-diagnostic` does not authorize general
use of `exec` or `port-forward`.

## Observer and diagnostic

The two Kubernetes identities separate routine inspection from the interactive
capabilities needed by a small number of approved verifiers:

```text
observer
  → agent discretion within approved read-oriented workflows

diagnostic
  → agent discretion only through approved named verifier workflows

anything broader or ad hoc
  → operator boundary
```

`homelab-observer` is the default scoped identity. It supports allowed resource reads,
logs, metrics, and observer-tier verification. It cannot open an exec session or a port
forward.

`homelab-diagnostic` is reduced privilege, not read-only. It inherits observer access and
adds `pods/exec` and `pods/portforward`. Approved verifiers select this context explicitly
when their designed oracle needs one of those operations. Outside those named verifier
paths, the agent must not use those capabilities without specific operator authorization.

## What an agent may do autonomously

Within an approved task, an agent may:

- Run `mise exec -- just talos kubeconfig` from its linked worktree.
- Use the worktree-local `homelab-observer` context for approved read-oriented
  verification and diagnosis.
- Read the resources, logs, and metrics granted by observer RBAC.
- Use the worktree-local Talos `os:reader` credential for approved read-only node
  inspection.
- Run approved observer-tier verifiers.
- Run approved named diagnostic verifiers that deliberately select
  `homelab-diagnostic`.
- Run the approved scoped verification campaign directly after its required preflight;
  the separate plan is an optional preview.

If an approved verifier fails because its scoped identity lacks permission, stop at that
boundary. Do not switch to an administrator credential or expand RBAC to make the check
pass.

## When the agent must involve the operator

The autonomous cases above include approved observer reads as well as approved scoped
verifiers. Before performing any other scoped cluster operation, the agent must stop and
surface the proposed action to the operator when it would:

- Mutate live cluster state through these scoped credentials or verification workflows.
- Perform an ad-hoc `kubectl exec`.
- Perform an ad-hoc `kubectl port-forward`.
- Expose or inspect sensitive runtime or process data outside an approved verifier.
- Read Kubernetes Secret bodies.
- Use a broader, write, administrator, elevated, or break-glass credential.
- Copy or adopt credentials from another worktree or the primary checkout.
- Expand RBAC or otherwise increase the agent's authority.

Runtime or sandbox permission does not move this boundary. Using `mise`, `just`, or a
repository recipe also does not make an otherwise operator-owned action agent-owned.
`AGENTS.md` separately permits explicitly approved, task-scoped, reversible ephemeral
actions for testing, benchmarking, verification, diagnostics, and cleanup. This guide
does not grant that approval or extend it to the scoped verification campaign, which is
declared non-mutating.

## When scoped access is insufficient

A permission denial in an approved verifier is not a reason to retry with
`homelab-admin`, patch live RBAC, or add a broad grant until the check passes. Treat a
real permission gap as a repository design change:

1. Decide whether the operation belongs in scoped access. A bounded resource read can
   justify an observer grant. Keep `exec` and port-forward limited to named diagnostic
   verifiers designed around those operations. Do not silently add Secret reads, broad
   mutation, impersonation, `bind`, `escalate`, or similar authority.
2. In the normal feature-worktree workflow, update the affected verifier and its
   `access.tier` in [`tests/catalog.yaml`](../../tests/catalog.yaml). For a new read,
   update the scoped campaign's `access.required_core_read_resources` or
   `access.required_read_rules`, the complete matrix in
   [`scripts/verify/agent-access.sh`](../../scripts/verify/agent-access.sh), the policy
   under [`tests/policy/agent-access/`](../../tests/policy/agent-access/), and
   [`rbac.yaml`](../../kubernetes/apps/kube-system/agent-access/app/rbac.yaml) together.
3. Run `mise exec -- just test catalog-validate` to compare catalog requirements with
   the exact observer grants, `mise exec -- just kube validator-tests` for the RBAC
   policy tests, the affected verifier's focused tests, and `mise exec -- just ci`.
   These checks reject wildcard resources, extra verbs, Secret reads, unintended
   mutations, and diagnostic verifiers that do not select `homelab-diagnostic`.
4. Submit the Git change for review. After it is merged and the Flux `agent-access`
   Kustomization has reconciled it, rerun `mise exec -- just kube agent-access-verify`
   and then the affected verifier.

The permission change must be necessary, narrow, reviewed, and deployed through Git.
Do not use broader credentials as a runtime workaround while that process is pending.

## Observer example

An allowed observer read follows this path:

```text
Agent
  ↓
kubectl --context homelab-observer get kustomizations ...
  ↓
Kubernetes authenticates homelab-observer
  ↓
RBAC finds an allowed get rule
  ↓
read succeeds
```

The same identity cannot start an exec session. This read-only authorization query shows
the expected denial without attempting an exec:

```bash
mise exec -- kubectl --kubeconfig .kube/config \
  --context homelab-observer --namespace kube-system \
  auth can-i create pods --subresource=exec
```

Expected result: `no`.

## Diagnostic example

An approved diagnostic verifier can use its deliberately granted subresource capability:

```text
Agent
  ↓
mise exec -- just kube cilium-verify
  ↓
verifier selects homelab-diagnostic
  ↓
kubectl exec ... cilium status
  ↓
Kubernetes authenticates the scoped identity
  ↓
RBAC evaluates the requested operation
  ↓
allowed
```

That does not permit normal cluster mutation. For example, this proposed operation is
outside the approved verifier path and RBAC does not grant it:

```text
kubectl --context homelab-diagnostic delete deployment ...
  ↓
denied
```

The agent must not treat a technical ability to exec or port-forward as permission to use
it ad hoc.

## Verify the access boundary

The agent-access verifier checks both named Kubernetes contexts and the Talos reader
credential without mutating the cluster:

```bash
mise exec -- just kube agent-access-verify
```

It requires observer workload, custom-resource, and log reads to succeed. It requires
observer Secret, exec, port-forward, create, patch, and delete requests to be denied. It
requires diagnostic exec and port-forward authorization while Secret and Flux mutations
remain denied. It also requires read-only Talos version and service inspection to
succeed.

When both scoped contexts exist, the verifier exercises them directly. In an authorized
administrator environment without either named context, the same verifier can evaluate
the scoped ServiceAccount identities through impersonation. A partial one-context layout
is rejected.

## Plan and run scoped verification

Run the current executable campaign directly:

```bash
mise exec -- just test scoped-campaign
```

The run repeats scoped preflight, freezes and displays the campaign membership, source
revision, plan digest, and effects, then starts the first verifier. To inspect those
inputs without starting the campaign, use the optional read-only preview:

```bash
mise exec -- just test scoped-campaign-plan
```

The plan and run fail closed unless all of these conditions hold:

- The checkout is a clean linked Git worktree.
- `.kube/config` and `.talos/config` are inside that worktree and have mode `0600`.
- The kubeconfig contains exactly the `homelab-observer` and `homelab-diagnostic`
  contexts and token users, with `homelab-observer` current and no administrator
  identity.
- The Talos credential has exactly the `os:reader` role.

The scoped campaign runs every catalog member assigned to the observer or diagnostic
tier. Observer is the default identity. A verifier that needs exec or port-forward must
explicitly select `homelab-diagnostic`. The campaign records and validates canonical
results locally. It does not acquire the cluster test Lease, publish reports, or run as
part of the cluster-independent `just ci` gate.

The catalog's `execution_owner: human` metadata distinguishes these interactive live
suites from shared automation. It does not require the operator to type the command when
`AGENTS.md` authorizes an agent to run scoped verification.

## Authoritative implementation sources

Use these executable and policy sources when behavior changes or the guide appears to
disagree with the repository:

- [`AGENTS.md`](../../AGENTS.md) defines agent authority and repository policy.
- [`tests/catalog.yaml`](../../tests/catalog.yaml) defines current campaign membership,
  suite commands, and access-tier assignments.
- [`kubernetes/apps/kube-system/agent-access/app/rbac.yaml`](../../kubernetes/apps/kube-system/agent-access/app/rbac.yaml)
  defines the deployed Kubernetes permissions.
- [`talos/mod.just`](../../talos/mod.just) and
  [`scripts/repository/install-worktree-credentials.sh`](../../scripts/repository/install-worktree-credentials.sh)
  implement credential installation.
- [`scripts/test/scoped-campaign-preflight.sh`](../../scripts/test/scoped-campaign-preflight.sh)
  and [`scripts/test/run-campaign.sh`](../../scripts/test/run-campaign.sh) implement the
  scoped campaign boundary.
- Verifier behavior lives under [`scripts/verify/`](../../scripts/verify/).

Current campaign membership is intentionally not duplicated in this guide. Use the
optional `mise exec -- just test scoped-campaign-plan` preview to inspect it.

## RBAC resource reference

The observer and diagnostic identities inherit Kubernetes `view`. The supplemental
ClusterRole adds only these campaign-required resources, each with `get`, `list`, and
`watch`, plus core `pods/log` with `get`:

| API group | Resources |
|---|---|
| core | `nodes` |
| `apiextensions.k8s.io` | `customresourcedefinitions` |
| `apiregistration.k8s.io` | `apiservices` |
| `aquasecurity.github.io` | `vulnerabilityreports` |
| `cert-manager.io` | `certificates`, `clusterissuers` |
| `cilium.io` | `ciliumclusterwidenetworkpolicies`, `ciliumendpoints`, `ciliumidentities`, `ciliumnetworkpolicies`, `ciliumnodes` |
| `gateway.networking.k8s.io` | `gatewayclasses`, `gateways`, `httproutes` |
| `helm.toolkit.fluxcd.io` | `helmreleases` |
| `kustomize.toolkit.fluxcd.io` | `kustomizations` |
| `longhorn.io` | `backuptargets`, `nodes`, `recurringjobs`, `volumes` |
| `metallb.io` | `ipaddresspools` |
| `metrics.k8s.io` | `nodes`, `pods` |
| `monitoring.coreos.com` | `prometheusrules`, `servicemonitors` |
| `notification.toolkit.fluxcd.io` | `alerts`, `providers`, `receivers` |
| `rbac.authorization.k8s.io` | `clusterrolebindings`, `clusterroles`, `rolebindings`, `roles` |
| `scheduling.k8s.io` | `priorityclasses` |
| `source.toolkit.fluxcd.io` | `buckets`, `gitrepositories`, `helmcharts`, `helmrepositories`, `ocirepositories` |
| `storage.k8s.io` | `csidrivers`, `storageclasses` |
| `tailscale.com` | `connectors`, `dnsconfigs`, `proxyclasses`, `proxygroups` |

Catalog validation compares this RBAC contract with the scoped campaign's static
requirements. It rejects wildcard resources, missing groups, extra verbs, Secret reads,
mutations, and undeclared calls reached through nested Kubernetes Just recipes. RBAC
object reads remain limited to roles and bindings. They expose policy metadata, not
Secret bodies, and grant no impersonation, `bind`, `escalate`, or write verb.
