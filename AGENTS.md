# Agent Instructions

Canonical, vendor-neutral rules for agents and contributors. `CLAUDE.md` imports
this file.

## Repository context

This repository manages a three-node Talos Linux and Flux GitOps Kubernetes cluster.
Git is the source of truth, and merged changes to `main` can affect the live environment.
Before changing a subsystem, inspect its relevant README or runbook and the current
accepted decisions. This root file is the sole repository-policy surface; supporting
documentation supplies procedure, not competing instructions. Use the current repository
state and accepted decisions as the implementation baseline. Repository policy and
accepted decisions take precedence over stale plans, prior conversation context, and
assumptions.

## Communication style

Communicate with the operator in clear, concrete English.

Apply principles inspired by ASD-STE100 Simplified Technical English:

- Use plain language when doing so preserves the same meaning.
- Avoid unnecessary jargon and abstract terminology.
- Prefer concrete descriptions of behavior over abstract labels.
- Reuse terminology already established in the conversation or task.
- Provide relevant context when needed to explain an implementation or recommendation.
- Briefly explain specialized or project-specific terms when their meaning may not be
  obvious from context.
- Prefer concrete examples when they help explain an abstract concept.
- Present sequential steps in their logical order.
- Break up long or complex sentences when doing so improves clarity.
- Prefer active voice.
- Be concise and direct. Avoid unnecessary verbosity while keeping important details.
- Lead with the outcome. Omit repetition and incidental process detail. Expand only when
  requested or necessary.
- Simplify the wording, not the technical content.

Write for a software engineer who may be unfamiliar with the specific tool, subsystem, or
domain.

Do not rewrite literal APIs, identifiers, commands, configuration fields, or quoted text
solely to satisfy these style rules.

## Git and worktrees

- Never commit or push directly to `main`; work on the assigned feature branch.
- Never merge or enable auto-merge without explicit operator authorization for that
  specific merge. General or stale approval does not count.
- The assigned worktree is the filesystem boundary for repository implementation files
  and inputs. Established pinned-toolchain workflows may access their configured
  user-level installations, caches, and state when permitted by the execution sandbox;
  this does not make the workflow operator-run. Do not use files from another worktree
  or the primary checkout as implementation inputs, and never modify them. Read-only
  inspection of committed Git objects, refs, and history is allowed.
- Do not create, remove, move, prune, repair, or otherwise manage worktrees. Worktree
  lifecycle is operator-run.
- Stop if the assigned branch or worktree is inconsistent or unsafe. Preserve unrelated
  changes.
- Keep each commit limited to one coherent change. Do not include unrelated edits, and
  split changes when they can be independently reviewed or reverted.
- Before each push, fetch `origin` and inspect both `origin/main` and the remote feature
  branch. If the remote feature branch contains unexpected commits absent locally, stop
  rather than overwriting or automatically reconciling it. Otherwise, if `origin/main`
  advanced, rebase the clean assigned branch onto it and rerun required validation.
- Never rebase with uncommitted changes. If unrelated changes prevent a required rebase,
  stop and ask the operator. When pushing rebased commits requires rewriting the assigned
  remote feature branch, use only `--force-with-lease`; a failed lease is a hard stop.
- Do not use `git reset --hard`, `git clean -fd`, repository-wide `git checkout .` or
  `git restore .`, or an unconditional force-push. Hooks may enforce these rules, but
  the rules remain mandatory independently of hooks.

## Authority boundaries

- Run repository workflows through the pinned toolchain with `mise exec -- just …`.
  Use `mise exec -- <tool> …` for pinned ad hoc inspection when no recipe exists. Do not
  substitute unpinned local tools.
- Sandbox approval required solely for an established agent-owned workflow to access
  approved toolchain installations, caches, or state does not make the workflow
  operator-run. Sandbox approval does not authorize any action otherwise prohibited or
  assigned to the operator by this file.
- Normal repository and cluster reads may use established read-only workflows with
  scoped worktree credentials. Changes to Flux-managed state go through Git.
- If the assigned worktree lacks required cluster credentials, stop and ask the operator
  to mint or provide the scoped access. Do not retrieve, copy, expose, or manage operator
  credentials.
- Agents may run established scoped verification with credentials provided to the
  assigned worktree. Per-invocation authorization does not transfer credential custody
  or operator ownership.
- Platform rollouts, break-glass actions, recovery, secret custody, branch-protection
  mutation, and similar privileged operations remain operator-run. Agents may prepare,
  review, and validate their source changes.
- GitHub protection checks and plans are read-only. The operator performs any authorized
  protection mutation through the guarded workflow documented in the relevant runbook.

## Agent orchestration

- Use an economical model appropriate for each delegated role. Do not inherit the
  coordinator's high-capability model by default when a lower-cost model can
  reliably perform the task.
- Freshly spawned delegated agents must use isolated task context when the runtime
  supports it. Resuming an existing task-local agent for a scoped fix or clarification
  is allowed when retaining that agent's task context is useful. Provide requirements,
  reports, diffs, and other substantial handoffs through files rather than inherited
  conversation history.
- Use a capable model for architecture, cross-cutting judgment, difficult debugging,
  and reviews that genuinely require that level of reasoning. Use a standard model for
  normal implementation, integration, and task review. Use a fast model for mechanical,
  tightly scoped work. Do not escalate a review model solely because it is a review.
- If the same implementation approach fails twice, stop repeating it. Diagnose the
  failure and change the approach, provide missing context, split the task, or escalate
  to a more capable model.
- Delegation must provide useful context isolation, independent judgment,
  specialization, or safe parallelism. Do not spawn additional agents merely to obtain
  more opinions or repeat completed analysis.
- Prefer focused tests, diffs, queries, and bounded logs over broad command output when
  they provide the required evidence.
- Treat repeated context compaction, excessive retries, or rapidly growing delegated
  work as signals to reassess the task rather than continuing mechanically.

## Secrets and credentials

- Secret values committed to Git are SOPS-encrypted, and the age private key remains
  with the operator.
- Do not print, copy, decrypt, re-encrypt, rewrite, or commit plaintext credentials.
- Secret-related implementation may manipulate templates, schemas, references,
  non-secret metadata, or unchanged operator-supplied encrypted artifacts without
  exposing the underlying values.
- Use the repository's gitleaks and staged-blob checks. Never handle the age private key
  or reuse legacy ciphertext as a substitute for operator-managed secret creation.

## Public repository

- Treat every committed file, branch name, commit message, pull request, review comment,
  generated artifact, and CI log as public and permanently recoverable. Do not rely on
  deletion or Git history rewriting to retract disclosed information.
- Do not publish actionable descriptions of unresolved security gaps, exploit paths, or
  remediation schedules. Track sensitive unimplemented controls privately. Public
  documentation may describe residual risk as mitigated or accepted only when that
  status is accurate and authorized.
- Never commit live public IPv4 or IPv6 addresses, hardware serial numbers, MAC
  addresses, credentials, or other unique infrastructure identifiers. Use RFC 5737 IPv4
  documentation addresses, RFC 3849 IPv6 documentation addresses, synthetic identifiers
  in test fixtures, and clearly marked placeholders in documentation.
- Apply these rules to new and modified content. Do not rewrite history solely to
  sanitize ordinary non-secret historical records. Treat exposed credentials or
  materially sensitive information as an operator-led security incident requiring
  containment and remediation.

## Repository invariants

- Do not edit generated files under `clusterconfig/`. Change `talos/talconfig.yaml` and
  `talos/patches/`, then run `mise exec -- just talos source-validate`. Generation or
  application requiring the age key or admin credentials remains operator-run.
- Follow the pinned version and compatibility constraints documented in
  `talos/README.md`, `kubernetes/README.md`, and relevant approved upgrade documentation.
  Do not independently upgrade Talos, Kubernetes, or Cilium outside an approved upgrade
  workflow.
- Follow `kubernetes/apps/<domain>/<app>/` and the Flux patterns documented in
  `kubernetes/README.md`.
- A Deployment mounting a `ReadWriteOnce` PVC uses `Recreate`, or uses a StatefulSet; it
  must not use `RollingUpdate`.
- Durable architectural decisions belong in `docs/decisions/`. Accepted decisions are
  superseded, never revised.
- Brainstorming specifications and implementation plans remain session-local or
  otherwise uncommitted. Do not create committed `docs/superpowers/specs/` or
  `docs/superpowers/plans/` artifacts unless the operator explicitly changes this
  policy.
- A validation assertion must use an independent oracle or encode a genuine invariant.

## Validation

- Before opening or updating a pull request, run `mise exec -- just ci`.
- `just ci` is the canonical full, cluster-independent, secret-free validation gate.
  Cluster-dependent verification, status, preflight, and diagnostic workflows remain
  outside it.
- After a required rebase, rerun affected validation, including `mise exec -- just ci`.
- Commit-time hooks provide staged-file feedback. Use `mise exec -- just repo lint` when
  repository-wide hook coverage is useful.
- Follow the relevant testing documentation for additional task-specific or scoped live
  validation.

## Completion

Report changed files, validation performed and its results, validation not performed and
why, remaining non-sensitive risks, and required operator actions. Report actionable
security-sensitive risks to the operator outside repository artifacts rather than
publishing them.
