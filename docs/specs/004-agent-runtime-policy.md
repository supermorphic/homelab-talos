# Agent Runtime Policy

## Purpose

Define the repository-wide safety and authority model for agents working on the Talos
and Flux platform. The policy makes risky effects, credential custody, publication, and
validation quality explicit without turning the runtime instructions into a catalog of
tools or enforcement metadata.

The normative runtime contract is [`AGENTS.md`](../../AGENTS.md). This specification
records why that contract has its present boundaries. Source, current documentation,
and the runtime contract remain authoritative when implementation details change.

## One policy surface

Root `AGENTS.md` is the sole vendor-neutral repository-policy surface. Subtree-specific
procedures and facts belong in source-adjacent README files, guides, references, and
runbooks. A client adapter such as [`CLAUDE.md`](../../CLAUDE.md) may import the root
contract and add only client-specific operating guidance; it must not create a second
repository policy.

This design avoids two failure modes:

- a nested instruction file can replace, rather than only strengthen, inherited policy;
  and
- duplicated rules drift and leave an agent to decide which copy controls.

Policy is organized by the order in which an agent needs it: repository context and
communication, Git and worktree boundaries, authority and agent orchestration, secrets,
public content, repository invariants, design lifecycle, validation, and completion. Its
test contract covers stable structure without freezing an exact rule count or exact
prose.

## Effect-based authority

Authority is based on what an operation can do, not which command spells it.

- Agents may inspect repository state, use approved scoped credentials for diagnosis and
  verification, and run task-scoped reversible live tests permitted by repository
  workflows.
- Persistent changes to Flux-managed Kubernetes state go through Git so the desired
  state, review record, and live reconciliation remain aligned.
- Agents may use approved workflows to mint task-scoped read-only cluster credentials.
  Seeking or using elevated, write, administrative, or break-glass credentials requires
  explicit operator authorization for the specific task. Secret creation, privileged
  platform rollout, and destructive or persistent out-of-band cluster changes remain
  operator-run.
- Merge and auto-merge always require explicit authorization for that specific merge.

This boundary permits useful read-only and reduced-privilege work without pretending
that every direct invocation of `kubectl`, `talosctl`, `flux`, or another client is
equally dangerous. Conversely, a guarded wrapper does not make an administrative effect
agent-safe merely because it uses an approved command name.

## Credential custody

Credentials are separated by scope and checkout location.

- The primary clone may hold the operator's administrative Kubernetes and Talos
  credentials for bootstrap and recovery.
- A feature worktree begins without cluster credentials. When scoped verification needs
  read-only access, the agent may use the approved repository workflow to mint
  task-scoped Kubernetes and Talos reader credentials into that worktree without
  operator intervention. Diagnostic subresources or any elevated, write,
  administrative, or break-glass credential require explicit authorization for the
  specific task.
- Observer access covers the bounded resource reads needed by registered verifiers and
  denies Secret reads and mutation. Diagnostic access adds the named pod subresources
  required by specific verifiers. It is reduced privilege, not a claim of read-only
  behavior, because pod execution can change container state.
- The age private key remains operator-held. Agent workflows may work with encrypted
  artifacts, templates, schemas, references, and non-secret metadata without obtaining
  the key or exposing plaintext.

Credential files stay ignored and repository-relative so a worktree never inherits the
primary clone's administrative identity by path. The session-start hook reports the
checkout kind and recognized credential tier and warns when key material is present in
the environment. This hook provides visibility; the credential and RBAC scopes provide
the actual authorization boundary.

## Git and worktree safety

Implementation work uses an isolated feature worktree unless the operator explicitly
authorizes the primary checkout. The assigned worktree is the filesystem boundary for
implementation inputs and edits. Agents preserve unrelated changes and do not modify or
remove worktrees owned by other tasks.

Each commit contains one coherent change. If two changes can be reviewed or reverted
independently, they belong in separate commits. Before publication, the agent fetches
and inspects both `origin/main` and the remote feature branch. A clean branch rebases
when `origin/main` advanced; unexpected feature-branch commits, uncommitted changes that
block the rebase, or a failed force-with-lease stop the workflow.

Destructive Git commands are prohibited independently of tool hooks. The pre-tool-use
hook blocks common irreversible forms such as hard reset, broad clean or restore, and
unleased force-push. The hook is an accident guard and can be bypassed, so it supplements
rather than replaces policy, preservation checks, and server-side branch protection.

## Public and secret boundaries

Every published repository surface is treated as public and permanently recoverable.
New or modified content excludes plaintext credentials, live public addresses, hardware
serials, MAC addresses, and other unique infrastructure identifiers. Documentation and
fixtures use placeholders, documentation address ranges, or synthetic identities.

SOPS encrypts secret values committed to Git. Pre-commit runs gitleaks against the
staged diff and rejects plaintext `*.sops.yaml` blobs. These checks provide fast
detection, while private-key custody remains the hard boundary. A disclosed credential
or material infrastructure detail is handled as an operator-led incident; history is
not rewritten casually in an attempt to retract public data.

## Pinned workflows and repository invariants

Repository workflows run through `mise exec -- just ...`. Mise owns the locked tool
versions and Just owns the supported task interfaces. When no recipe exists, a
repository-dependent command whose version matters still runs through `mise exec --`.

Source-specific invariants remain in the root policy because violating them can create
unsafe or misleading repository state. In particular, generated Talos configuration is
not edited directly, platform upgrades require an approved compatibility workflow,
Flux applications follow the documented package layout, and a Deployment using a
`ReadWriteOnce` claim uses `Recreate` or is modeled as a StatefulSet.

## Validation design

`mise exec -- just ci` is the canonical full, cluster-independent, secret-free gate.
Commit-time hooks provide staged-file feedback, and `mise exec -- just repo lint`
applies that hook suite to the whole tree. Live acceptance and diagnostics remain
separate because giving CI cluster credentials would violate the authority model.

A validation assertion must use an independent oracle or encode a genuine invariant.
Comparing a value from a file with a literal copied from that same file can be updated on
both sides in one change and therefore provides no independent signal. Effective checks
instead use schema validation, rendered output, policy applied across a class of inputs,
negative authorization tests, external state, or an invariant whose two sides do not
share the same editable source.

The hook-test design verifies stable architecture: one tracked `AGENTS.md`, the semantic
section order, a thin vendor shim, hook registration, credential visibility, and denial
of known irreversible Git command forms. It intentionally does not enforce a fixed
policy size or repeat the normative policy text.

## Consequences

Agents can complete ordinary implementation, offline validation, and authorized scoped
verification without ambient administrative access. The operator retains custody of
credentials and irreversible actions. Policy remains short enough to load at task entry,
while current procedures and enforcement details can evolve in their owning source
files without creating competing policy surfaces.
