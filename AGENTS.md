# Agent Instructions

Canonical, vendor-neutral rules for agents and contributors. `CLAUDE.md` imports
this file.

## Repository context

This repository manages a three-node Talos Linux and Flux GitOps Kubernetes cluster.
Git is the source of truth, and merged changes to `main` can affect the live environment.

Before changing a subsystem, start with the task, this policy, relevant
implementation, and associated tests. Read only needed sections of owning
specifications; expand into callers, dependencies, and related specifications
for actual cross-component constraints or uncertainty. Do not preload whole
documentation trees or a README/guide/spec bundle. This root file is the sole
repository-policy surface; supporting documents provide procedures, not
competing instructions. Current
repository policy, documentation, and source state take precedence over
historical specifications, transient plans, prior conversation context, and
assumptions.

Repository artifact and communication rules override agent-skill defaults and
older issue/spec instructions. Preserve real requirements, not obsolete demands
for guides, committed plans, or exhaustive status reports. Investigate
implementation/spec discrepancies instead of silently changing requirements to
match code.

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

Apply these communication rules to issue bodies, PR descriptions, and comments.

Post comments only when they add a material finding, decision, changed blocker,
requested answer, or acceptance outcome. Skip routine progress, duplicate
information, and session-end recaps.

Write for readers without the agent conversation. Explain the problem, outcome,
and necessary rationale; link retrievable evidence instead of repeating it.
Preserve important decisions and authorization history.

## Git and worktrees

- Never commit or push directly to `main`. Published implementation work must use an
  appropriate feature branch. A runtime-managed worktree may start and operate at
  detached `HEAD`, including making local commits; detached state alone is not unsafe.
  Preserve useful work on an appropriate feature branch before publication or removal
  of the worktree.
- Never merge or enable auto-merge without explicit operator authorization for that
  specific merge. General or stale approval does not count.
- Perform implementation work in an isolated worktree unless the operator explicitly
  authorizes work in the primary checkout. A worktree supplied by the operator or
  supported agent runtime satisfies this requirement. Agents and supported agent
  runtimes may create and manage task-owned worktrees when useful for filesystem
  isolation or safe parallelism.
- Treat the assigned or task-owned worktree as the filesystem boundary for repository
  implementation files and inputs. Established pinned-toolchain workflows may access
  their configured user-level installations, caches, and state when permitted by the
  execution sandbox; this does not make the workflow operator-run. Do not use files from
  another worktree or the primary checkout as implementation inputs, and do not modify
  them unless explicitly authorized. Read-only inspection of committed Git objects,
  refs, and history is allowed.
- Do not modify, remove, repurpose, or prune a worktree owned by another active task or
  whose ownership or preservation state is uncertain. Before removing a task-owned
  worktree, preserve its useful work or intentionally discard it with appropriate
  authority.
- Preserve unrelated changes. Stop when repository or worktree state is unsafe
  or ownership is unclear.
- Keep each commit limited to one coherent, independently reviewable change.
- Before each push, fetch `origin` and inspect `origin/main` and, when it exists, the
  remote feature branch. If the remote feature branch contains unexpected commits absent
  locally, stop rather than overwriting or automatically reconciling it. Otherwise, if
  `origin/main` advanced, rebase the clean feature branch onto it and rerun relevant
  focused checks as needed. Require fresh hosted validation for the updated candidate
  and required base before merge.
- Never rebase with uncommitted changes. If unrelated changes prevent a required rebase,
  stop and ask the operator. When pushing rebased commits requires rewriting the assigned
  remote feature branch, use only `--force-with-lease`; a failed lease is a hard stop.
- Do not use `git reset --hard`, `git clean -fd`, repository-wide `git checkout .` or
  `git restore .`, or an unconditional force-push. Hooks may enforce these rules, but
  the rules remain mandatory independently of hooks.

## Authority boundaries

- Use Git for repository content. Use the configured `teacli` client for issues,
  pull requests, reviews, comments, labels, and other forge metadata.
- Do not manipulate Forgejo's database or invoke its server-side CLI directly.
- Use the Forgejo REST API only when `teacli` does not expose the
  required operation. Use configured client credentials within the task's
  authorization; do not expose secrets or broaden access.
- For n8n workflow work, use established repository workflows where provided and
  the configured n8n MCP tools for other supported operations within task authority.
  For database credential selection, start with
  [credential discovery](docs/specs/026-automation-data-postgresql-platform.md#credential-discovery-for-approved-work).
  For migration discovery, inspect the intended execution context; its exit code
  describes local connection readiness and does not determine n8n credential availability.
- Before binding an n8n credential, confirm that the discovered credential ID is
  accessible through the configured n8n connection. Do not request its password or
  substitute a broader credential. Distinguish saved drafts, published versions,
  and verified execution results when reporting workflow readiness.
- Run established repository workflows through the pinned toolchain with
  `mise exec -- just …`. When no recipe exists, use `mise exec -- <tool> …`
  for repository-dependent tools whose pinned version matters. Ordinary
  read-only filesystem and Git inspection may use standard shell commands.
  Do not substitute unpinned tools for established pinned repository workflows.
- Agent-owned workflows must proceed autonomously when permitted by repository policy.
  Runtime or sandbox approval does not change whether an operation is agent-owned or
  operator-run. Complete all independent safe work before stopping for required operator
  action. Do not ask the operator to perform an agent-owned workflow that the agent can
  run itself.
- Treat confirmation as an execution-intent guard, not as operator authorization.
- Treat repository `verify` and `check` workflows as observational toward their target. Use a
  registered `test` workflow when evidence requires deliberate temporary mutation.
- Use `mise exec -- just test record <suite-id|scoped-verification>` for intentional
  initiative completion, bootstrap, setup, initialization, recovery, and other infrequent
  assurance evidence. This orchestration publishes each canonical child automatically.
  Use `mise exec -- just test record-resume <session-id>` after an eligible publication
  failure, or `mise exec -- just test publish <run-id>` to retain one already-finalized
  canonical run without rerunning it. In a linked worktree, agents may use the scoped
  `homelab-report-publisher` identity for approved publication without operator
  confirmation; outside that context, manual publication requires exact run-scoped
  confirmation. Publication authority does not authorize the selected suite's mutations
  or broader credentials. Ordinary CI, iterative verification, and diagnostics remain
  local. Feature-branch evidence remains candidate evidence; only clean deployed-main
  evidence may drive authoritative latest links, Homepage status, and last-run metrics.
- When an approved task needs scoped cluster access, agents must run
  `mise exec -- just kube kubeconfig` themselves from their assigned linked worktree
  and use the resulting task-scoped credentials. Request Talos reader credentials
  separately with `mise exec -- just talos readerconfig` only when needed. Do not hand
  this credential bootstrap off to the operator merely because credentials are involved. Agents may perform
  approved scoped verification with those credentials without operator intervention.
  Agents may not seek out, copy, adopt, or use elevated, write, administrative, or
  break-glass credentials unless the operator explicitly authorizes that credential
  for the specific task.
- If an approved scoped workflow cannot proceed because it lacks required authority, stop
  at that boundary. Do not retry with broader credentials, modify RBAC, or perform an
  ad-hoc privileged operation as a workaround. Surface the specific required action to the
  operator when it would require broader credentials, new authorization, live mutation,
  ad-hoc exec or port-forward, sensitive runtime access, or another operation outside the
  approved scoped workflow.
- Persistent changes to Flux-managed state must go through Git. Agents may
  perform task-scoped, reversible ephemeral cluster actions needed for approved
  testing, benchmarking, verification, diagnostics, and cleanup of resources
  they create for those purposes. Privileged, destructive, or persistent
  live-state changes outside Git remain operator-run, except retained test evidence written
  through the approved report publisher. That identity is limited to the
  report namespace and the named publication Lease; it must not execute test suites.

## Agent orchestration

- Scale design and execution to the change's behavior, uncertainty, and risk; reassess
  when its scope grows. Use supported skill workflows with these repository defaults:
  - **Bounded change:** a known configuration adjustment, understood bug fix,
    documentation or narrow test correction, or small refactor without architectural
    change. Use short in-context reasoning/design, focused tests, and repository-required
    validation. No durable specification or formal implementation plan is required by
    default; use a transient plan only when sequencing adds value. Use one fresh final
    review when substantive changes to behavior, configuration, or repository policy
    warrant it.
  - **Architectural change:** a new platform or service, security or credential boundary,
    cross-component interface, migration/recovery architecture, or substantial operational
    lifecycle. Use explicit brainstorming/design, a durable specification when the design
    has lasting value, an implementation plan, and an independent final review.
  - **Exploratory/spike work:** investigate a bounded question, retain only useful
    conclusions and evidence, and treat production implementation as a new task that
    must be classified before implementation.
- Execute bounded changes directly in the current implementation context. When an
  implementation plan exists, prefer native/inline execution in one implementation
  context. Use subagent-driven execution only when context isolation, specialization,
  per-task independent review, or safe parallelism provides a concrete benefit.
- Add an abstraction, registry, report mechanism, persistent test layer, or subagent
  stage only when it provides a concrete benefit. Process proportionality does not reduce
  worktree, authority, credential, testing, or merge protections.
- Use an economical model appropriate for each subagent role. Do not inherit the
  coordinator's high-capability model by default when a lower-cost model can
  reliably perform the task.
- Freshly spawned subagents should use isolated task context when the runtime
  supports it. Resuming an existing task-local subagent for a scoped fix or
  clarification is allowed when retaining its context is useful. Use files for
  substantial cross-agent handoffs when they improve context isolation or
  durability.
- Use a capable model for architecture, cross-cutting judgment, difficult
  debugging, and reviews that genuinely require that level of reasoning. Use a
  standard model for normal implementation, integration, and task review. Use a
  fast model for mechanical, tightly scoped work. Do not escalate a review
  model solely because it is a review.
- If the same implementation approach fails twice, diagnose the cause and
  change the approach instead of repeating it.
- Do not spawn additional subagents merely to obtain more opinions or repeat completed
  analysis.
- Prefer focused tests, diffs, queries, and bounded logs over broad output.
- Treat repeated context compaction, excessive retries, or rapidly growing
  delegated work as signals to reassess the task rather than continuing
  mechanically.

## Secrets and credentials

- Secret values committed to Git are SOPS-encrypted, and the age private key remains
  with the operator.
- Do not expose plaintext credential values in agent output, repository artifacts, or
  commits. Handle task-scoped credentials only through approved repository workflows.
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
  configuration, the owning platform specification, and relevant approved upgrade designs.
  Do not independently upgrade Talos, Kubernetes, or Cilium outside an approved upgrade
  workflow.
- Follow `kubernetes/apps/<domain>/<app>/` and the Flux patterns documented in
  `docs/specs/010-talos-flux-platform.md`.
- A Deployment mounting a `ReadWriteOnce` PVC uses `Recreate`, or uses a StatefulSet; it
  must not use `RollingUpdate`.
- A validation assertion must use an independent oracle or encode a genuine invariant.
- Repeat safety-critical live preconditions immediately before consequential mutation.
  Do not rely on an earlier plan or preflight as proof that target state is unchanged.

## Design lifecycle

- Documentation is not a default deliverable. Most fixes, refactors, dependency
  changes, and implementation-only schema changes need no prose update.
- General documentation belongs only in root `README.md` and `docs/specs/`.
  Do not create nested READMEs, a documentation index, guides, references, runbooks,
  contribution manuals, archives, or substitute documentation categories.
  Root `AGENTS.md` is the policy exception; do not add nested policy files.
  Necessary thin tool adapters, functional skills/prompts/policies,
  machine-consumed Markdown fixtures, and required provenance/licensing records
  are distinct assets. Do not relabel general documentation to evade this rule.
- Durable design specifications belong in `docs/specs/` and use consecutive
  three-digit identifiers, such as `001-<name>.md`. Assign the next number after the highest existing specification.
  After merge, do not reuse or renumber an identifier.
- Keep the README to purpose, current scope, bootstrap commands, and navigation.
  Keep repository policy here; tool-specific instruction files adapt tools
  without duplicating policy.
- Give each documented contract or procedure one canonical home. Specifications
  own intended behavior, rationale, boundaries, and acceptance requirements.
  Link to the owning specification instead of repeating its contract elsewhere.
  Code, schemas, configuration, and command help define exact implementation
  details; explain only what those sources do not make clear.
  Do not copy current schema revisions, field catalogs, defaults, provider/model
  versions, or command inventories into prose. Preserve executable versioning
  and immutable migration history.
- Keep needed operating knowledge in the owning specification: attended steps,
  cross-system sequencing, recovery, and interpretation of results that supported
  code or command help cannot supply. Recovery must remain usable independently
  of working services.
  Include commands, prerequisites, and expected results where needed to act.
  Add UI walkthroughs only for a demonstrated use.
- Update documentation when a change affects its contract, procedure, or meaning.
  A fix that restores behavior already described in a specification normally
  needs no spec edit. When an edit is needed, limit it to the affected content
  and preserve the surrounding design intent and rationale.
  Internal refactoring alone does not require prose updates. Preserve useful
  knowledge before removing duplicated text, and repair affected links.
  As a routine procedure becomes a guarded command, keep only the instructions
  and judgment that the command does not provide. Prompts, Markdown fixtures,
  and provenance or licensing records are not expendable documentation.
- Keep specifications current with the implemented and validated design across
  staged delivery. Update them in place as the design evolves, including after
  merge; do not split a specification solely because a delivery stage merged.
  Do not add change logs or approval histories to specifications.
  Keep completed implementation plans and acceptance diaries out of specs.
- Store transient implementation plans under ignored `.tmp/plans/`.
  Temporary handoffs remain ignored under `.tmp/`; required detailed evidence
  stays in established evidence stores.
- Prefer updating an existing specification for iterative work on the same subject. Create
  a new numbered specification when the work introduces a distinct design subject, not
  merely because the earlier specification merged.
- When a transient implementation plan corresponds to a numbered specification, use the
  same numeric identifier and descriptive name where practical.
- Repository-defined artifact locations override tool or skill defaults. Do not create
  implementation plans under `docs/` unless the operator explicitly requests it.

## Validation

- Do not test documentation prose, headings, required phrases, or prescribed
  cross-links. Review documentation content; allow mechanical Markdown lint and
  generic link and structural path checks. Test machine-consumed examples only
  against an independent parser or executable behavior. Functional Markdown
  remains subject to its actual consumer checks.
- Before pushing or opening or updating a pull request, run relevant focused
  checks and ensure commit-time checks pass. Ordinary documentation changes use
  applicable mechanical checks. Omitting optional full local CI does not
  require an operator exception.
- A successful hosted `merge-gate` for the exact candidate and required base is the
  authoritative validation gate before merge. Missing or failed hosted validation must
  not fall back to a local passing result. Do not manually reduce required validation
  groups. Passing validation does not replace explicit operator authorization for that
  specific merge.
- Use full local `mise exec -- just ci` to reproduce failures, check broad or
  shared changes when useful, validate CI/harness changes, or satisfy an explicit
  operator request. Do not run it automatically for every PR creation or update.
  Hosted `merge-gate` must pass the checks required by the repository’s trusted CI policy
  for the current candidate and base.
- Local `mise exec -- just test ci-publish` and `mise exec -- just test ci-publish-full`
  are optional under the same conditions. Keep the committed feature worktree clean and
  untouched while either command runs.
- `just ci` is the canonical full, cluster-independent, secret-free validation command.
  Cluster-dependent verification, status, preflight, and diagnostic workflows remain
  outside it.
- After edits or rebases, rerun affected local checks and require fresh hosted
  validation for the updated candidate and applicable base before merge. Do not
  present earlier results as proof of the changed candidate.
- Commit-time hooks provide staged-file feedback. Use `mise exec -- just repo lint` when
  repository-wide hook coverage is useful.
- Preserve required native or attended acceptance for affected integration and
  deployment boundaries. Hosted offline CI does not prove deployed cluster behavior
  or authorize live operations. A passing check does not authorize broader credentials
  or live mutations outside the approved task; use the established guarded procedures
  and authority.

## Completion

Report changed files, validation performed and its result, validation not
performed and why, remaining non-sensitive risks, and required operator actions.
Distinguish focused local results, hosted CI status, and native or attended
acceptance. Report pending validation as pending. An intentionally omitted
optional full local CI run is not a policy violation.

Report actionable security-sensitive risks to the operator outside repository artifacts
rather than publishing them.
