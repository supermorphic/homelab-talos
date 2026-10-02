# Agent Instructions

This repository manages a three-node Talos Linux and Flux GitOps Kubernetes cluster.
Git is the source of truth; merges to `main` can affect the live environment.
This root file owns repository execution policy. Necessary tool adapters, such as
`CLAUDE.md`, import or adapt it without duplicating policy. Do not add nested policy.

## Scope and documentation

- Start with the task, applicable policy, relevant source, and tests. Read only needed
  sections of owning specs; expand for actual cross-component constraints or uncertainty.
  Do not preload documentation trees or prescribe a README/guide/spec reading bundle.
- Documentation is not a default deliverable. Most fixes, refactors, dependency changes,
  and implementation-only schema changes need no prose update. General documentation
  belongs only in root `README.md` and `docs/specs/`: no nested READMEs, documentation
  index, guides, references, runbooks, contribution manuals, archives, or substitutes.
  Functional prompts, executable skills, machine-consumed Markdown, fixtures, and required
  third-party notices are narrow exceptions based on actual function, not relabeling.
- Source, schemas, migrations, configuration, and command help own exact implementation
  facts. Do not duplicate field catalogs, defaults, versions, or command inventories in
  prose. Preserve durable compatibility and migration reasoning that changes the contract.
- Specs preserve the original design, its rationale and alternatives, and essential
  changes over time, including completed or superseded designs. Keep existing specs and
  their supporting assets as design history; do not replace them with compressed outcome
  summaries. Trim later repeated PR execution detail, not original design reasoning.
  Retained design-time examples and measurements are historical context, not a second
  inventory of current source values or a requirement to synchronize them on every PR.
  Mark superseded decisions clearly and retain the current boundaries and guarantees. Investigate
  discrepancies between implementation and specs; do not silently rewrite requirements
  to match code. Update the existing owner when its contract changes. Create a new spec
  only for an explicitly agreed distinct durable subject, not for each issue or PR.
  Reconcile changed contracts with the implemented and validated result before merge.
- Use monotonically increasing three-digit spec identifiers, taking the next number after
  the highest assigned identifier, including retired specs in Git history. Never reuse or
  renumber merged identifiers. Git history retains detailed execution history; specs
  retain design history. Preserve minimal independent
  recovery prerequisites, authority boundaries, failure interpretation, and steps that
  cannot be discovered from source or help in the owning spec.
- Keep plans and temporary handoffs ignored under `.tmp/` (`.tmp/plans/` for plans; reuse
  the owning spec's identifier where practical). Detailed evidence belongs in established
  evidence stores. Neither specs nor comments are completion diaries.
- Current repository policy and source are the implementation baseline. These artifact
  and communication rules override skill defaults and older issue/spec instructions.
  Preserve real requirements, not obsolete demands for guides, committed plans, or
  exhaustive reports.

## Communication and completion

Use clear, concrete English for a software engineer who may not know the subsystem.
Lead with the outcome, explain unfamiliar terms when needed, and omit repeated process
detail. Preserve literal APIs, identifiers, commands, configuration fields, and quotes.

- Post issue/PR comments only for a new decision and rationale, material finding, changed
  blocker/dependency, answer or operator request, or meaningful acceptance/closure outcome.
  Skip routine activity, unchanged status, and recaps available in the PR or CI. No comment
  is required merely because a session ended.
- Normally use 3–6 short sentences and fewer than 150 words; this is a default, not a cap
  or template. Longer technical discussions must answer a real question and lead with a
  summary. Include blocker, next action/responsible actor, and evidence links when relevant.
- Keep exact versions, IDs, errors, and measurements only when needed to identify evidence,
  reproduce failure, explain a decision, or act safely. Distinguish implementation,
  deployment, and native acceptance; a CI pass alone does not establish completion.
- Link retrievable evidence and procedures instead of copying inventories or transcripts.
  A vanished `.tmp/` file is not a durable handoff. If no retained artifact exists, keep
  the smallest irreplaceable evidence in the comment. Preserve private evidence boundaries;
  do not create documents or reporting services to accommodate verbosity.
- Keep issue bodies focused on current scope and acceptance. Refresh owned status-only text
  when useful; preserve decision history, authorization provenance, and material outcome
  changes. Do not move walls of text into bodies, specs, or collapsed blocks. Read current
  scope and latest relevant status first; retrieve older discussion only as needed.
- At completion, report the result and relevant validation or acceptance limits, remaining
  non-sensitive risks, and required operator actions. Distinguish local checks from hosted
  CI; pending validation stays pending. Omitted optional local CI is not a policy exception.
  Report actionable security-sensitive risks privately, outside repository artifacts.

## Git and worktrees

- Never commit or push directly to `main`. Publish implementation on a feature branch.
  Runtime-managed detached worktrees may operate and commit locally; preserve useful
  work on a feature branch before publication or removal.
- Never merge or enable auto-merge without explicit operator authorization for that
  specific merge. General or stale approval does not count.
- Work in an isolated assigned or task-owned worktree unless the operator explicitly
  authorizes the primary checkout. Treat that worktree as the boundary for implementation
  files and inputs. Do not use or modify another checkout's files without authorization.
  Read-only Git objects, refs, and history are allowed. Pinned workflows may use their
  configured user installations, caches, and state within the execution sandbox.
- Do not modify, remove, repurpose, or prune worktrees owned by other tasks or of uncertain
  ownership/preservation state. Preserve useful work before removing your own worktree,
  or obtain authority to discard it. Stop on inconsistent or unsafe Git/worktree state;
  preserve unrelated changes. Keep commits coherent and independently reviewable.
- Before every push, fetch `origin` and inspect `origin/main` and any remote feature
  branch. Stop if that branch has unexpected commits absent locally. If main advanced,
  rebase the clean feature branch and rerun relevant focused checks. Never rebase with
  uncommitted changes; ask the operator if unrelated changes prevent a required rebase.
  Rewrite the assigned remote branch only with `--force-with-lease`; a failed lease stops
  the task. Require fresh hosted validation for the updated candidate and required base.
- Never use `git reset --hard`, `git clean -fd`, repository-wide `git checkout .` or
  `git restore .`, or unconditional force-push, regardless of hook enforcement.

## Authority and credentials

- Run established workflows with `mise exec -- just …`; where no recipe exists, use
  `mise exec -- <tool> …` for tools whose pinned version matters. Ordinary read-only
  filesystem and Git inspection may use standard commands. Do not substitute unpinned
  tools for established workflows.
- Execute permitted agent-owned workflows autonomously; sandbox/runtime approval does not
  make them operator-run. Finish independent safe work before stopping at an authority
  boundary. Confirmation guards execution intent; it does not grant operator authority.
- `verify` and `check` are observational toward their targets. Deliberate temporary
  mutation belongs in a registered `test` workflow. Persistent Flux-managed changes go
  through Git. Approved task-scoped testing, benchmarking, verification, diagnostics, and
  cleanup may use reversible ephemeral cluster actions. Other privileged, destructive,
  or persistent live mutations remain operator-run, except approved evidence publication.
- For approved scoped cluster work, run `mise exec -- just kube kubeconfig` from the
  assigned linked worktree and use its task-scoped credentials. Request Talos reader
  credentials separately with `mise exec -- just talos readerconfig` only when needed.
  Do not hand this bootstrap to the operator merely because credentials are involved.
  Never seek, copy, adopt, or use elevated, write, administrative, or break-glass credentials
  without explicit authorization for that credential and task.
- Stop when scoped authority is insufficient. Do not broaden credentials, change RBAC,
  or use ad-hoc privileged workarounds. Identify the specific operator action needed for
  new authority, live mutation, ad-hoc exec/port-forward, sensitive runtime access, or
  other work outside the approved workflow.
- Use `mise exec -- just test record <suite-id|scoped-verification>` for intentional
  initiative completion, bootstrap, setup, initialization, recovery, and other infrequent
  assurance evidence; it publishes each canonical child automatically. Resume eligible
  publication failures with `just test record-resume <session-id>`, or retain a finalized
  canonical run without rerunning via `just test publish <run-id>`, through mise.
  Ordinary CI, iterative verification, and diagnostics stay local.
- In linked worktrees, approved publication may use the scoped `homelab-report-publisher`
  without operator confirmation. Elsewhere, manual publication needs exact run-scoped
  confirmation. This identity is limited to the report namespace and named publication
  Lease; it must not execute suites. Publication grants neither suite mutation authority
  nor broader credentials. Feature evidence remains candidate evidence; only clean
  deployed-main evidence may drive authoritative latest links, Homepage, and last-run metrics.
- Commit secret values only as SOPS ciphertext; the age private key stays with the
  operator. Never expose plaintext credentials in output, artifacts, or commits. Handle
  task credentials only through approved workflows. Secret implementation may use
  templates, schemas, references, non-secret metadata, and unchanged operator-supplied
  ciphertext. Use gitleaks and staged-blob checks; never handle the age private key or
  reuse legacy ciphertext instead of operator-managed secret creation.

## Public repository

- Treat all committed files, branch names, messages, PRs, reviews, artifacts, and CI logs
  as public and permanently recoverable. Deletion or history rewriting cannot retract
  disclosure. Never publish actionable unresolved security gaps, exploit paths, or
  remediation schedules. Keep sensitive unimplemented controls private; describe risk as
  mitigated or accepted only when accurate and authorized.
- Never commit live public IP addresses, hardware serials, MAC addresses, credentials, or
  unique infrastructure identifiers. Use RFC 5737 IPv4 and RFC 3849 IPv6 documentation
  addresses, synthetic fixtures, and clearly marked placeholders. Apply this to new and
  modified content; do not rewrite history for ordinary non-secret historical records.
  Exposed credentials or materially sensitive information require operator-led containment
  and remediation.

## Execution and invariants

- Scale process to behavior, uncertainty, and risk. Bounded configuration, bug, documentation,
  test, and small refactor changes use short in-context reasoning, direct execution,
  focused checks, and one fresh final review when behavior, configuration, or policy
  warrants it. No durable spec or formal plan is required by default. Architectural work
  needs explicit design, a durable spec when valuable, an implementation plan, and an
  independent final review. Spikes retain useful findings; classify production work anew.
- Prefer inline execution. Add abstractions, registries, report mechanisms, persistent test
  layers, or subagents only for a concrete benefit. Delegation may provide specialization,
  isolated context, independent review, or safe parallelism; use fresh isolated contexts
  and economical models appropriate to each role. Resume task-local agents when useful.
  Do not escalate solely for review or spawn agents to repeat completed analysis.
- If an approach fails twice, diagnose and change it rather than repeat it. Reassess on
  excessive retries, repeated context compaction, or growing delegation. Prefer focused
  queries, logs, diffs, and tests. Proportionality never reduces safety protections.
- Never edit generated `clusterconfig/` files. Change `talos/talconfig.yaml` and
  `talos/patches/`, then run `mise exec -- just talos source-validate`. Generation or
  application needing the age key or admin credentials remains operator-run.
- Preserve pinned version and compatibility constraints in configuration and the owning
  platform/upgrade specs. Do not independently upgrade Talos, Kubernetes, or Cilium outside
  an approved upgrade workflow. Follow `kubernetes/apps/<domain>/<app>/` and existing Flux
  patterns. Deployments mounting `ReadWriteOnce` PVCs use `Recreate`, or use StatefulSets.
- Validation assertions need independent oracles or genuine invariants. Repeat safety-critical
  live preconditions immediately before consequential mutation; earlier preflight is not proof.

## Validation

- Before pushing, run applicable focused checks and pass commit-time checks. Documentation
  changes may then push without asking to omit optional local CI. Use
  `mise exec -- just repo lint` when repository-wide hook coverage is useful.
- Hosted `merge-gate` for the exact candidate and required base is the authoritative
  pre-merge gate. Never replace missing/failed hosted evidence with local results or
  manually reduce required groups. Rerun focused checks as needed after edits/rebases and
  require fresh hosted evidence. Passing checks never replace specific merge authorization.
- `mise exec -- just ci` is the full cluster-independent, secret-free local gate; live
  verification, status, preflight, and diagnostics remain outside it. Local CI and
  `just test ci-publish` / `ci-publish-full` are optional for failure reproduction,
  CI/harness/selection work, or explicit requests, not automatic PR deliverables. Keep
  the committed feature worktree clean and untouched during either publication workflow.
