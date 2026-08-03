# Agent Rules Runtime Contract Amendment

Status: Accepted (2026-08-03)

## Relationship to the accepted audit

This record amends
[`2026-08-02-agent-rules-audit.md`](2026-08-02-agent-rules-audit.md). The operator
approved this amendment and its exact root contract on 2026-08-03 after reviewing two
rounds of critique. The earlier accepted record is not edited.

This is a partial amendment rather than a full-file supersession. Both records remain
Accepted. Where they conflict, this later and narrower record controls only these parts
of the audit:

- the admission-test requirement that category and control provenance appear inline in
  every runtime rule;
- the audit's “Final `AGENTS.md` rule set” table;
- Task 6's exact-24-rule structural test and categorized prose contract;
- the unconditional fetch-and-rebase wording;
- the temporary placement of the Portainer deployment-authority invariant in root
  `AGENTS.md`.

The audit's rejection of nested `AGENTS.md` files is reaffirmed. Its credential tiers,
effect-based cluster boundary, application-rollout simplification, policy architecture,
documentation lifecycle, operator-run worktree lifecycle, destructive-command hooks,
and all other unaffected decisions remain Accepted.

A full `Superseded by` status is deliberately not applied to the audit because that
would incorrectly retire those unaffected decisions. Accepted text remains immutable;
later, explicitly scoped records amend or supersede decisions without rewriting their
history.

## Problem

PR #185 implemented the audit's runtime inventory as 24 bracket-prefixed bullets. That
format compressed the file but mixed three different concerns:

1. runtime instructions an agent must act on;
2. evidence and control-strength traceability for reviewers; and
3. mechanical enforcement supplied by hooks, CI, credentials, recipes, or GitHub.

The compression removed task-entry context and important stop conditions while making
design-time provenance the most visually prominent part of every rule. It also encoded
the inventory size and labels in a shell test, so adding or clarifying a legitimate rule
would fail for the wrong reason.

The review also found specific semantic gaps: remote feature-branch divergence was not
checked; the worktree boundary could be read as forbidding committed Git history; the
compatibility rule named no procedure; privileged-operation ownership was ambiguous;
and the newly merged public-repository policy described disclosure and residual risk too
absolutely.

## Decision

### One repository-policy surface

Root `AGENTS.md` remains the sole repository-policy surface. No nested
`kubernetes/AGENTS.md`, `talos/AGENTS.md`, `tests/AGENTS.md`, or app-local `AGENTS.md`
files are created.

This reaffirms the audit's original rationale:

- the root remains far below the 150–200-line split trigger;
- nearest-wins instruction precedence could relax a parent policy; and
- additional files would add policy surfaces without reducing the amount of policy.

Subsystem READMEs, runbooks, accepted decisions, hooks, CI, and recipes provide
procedure and enforcement. They do not compete with or override root repository policy.
An agent beginning a subsystem change must inspect the relevant supporting documentation.

`CLAUDE.md` remains a thin vendor shim: it imports `AGENTS.md` and contains only Claude
Code operating guidance.

### Semantic runtime organization

Runtime rules use these headings:

- Repository context
- Git and worktrees
- Authority boundaries
- Secrets and credentials
- Public repository
- Repository invariants
- Validation
- Completion

The order follows the agent's execution flow: establish context and boundaries, apply
repository constraints, validate the result, and report completion. It is not a ranking
of authority; every mandatory rule applies regardless of its position.

Bracketed labels such as `[Authoritative — …]`, `[Operator policy — …]`, and `[Gotcha]`
are design-time traceability metadata and do not appear in runtime instructions. The
rule-disposition matrix in this record preserves that traceability.

Hooks, CI, credentials, RBAC, branch protection, and recipes may enforce or detect a
rule, but they are not its source of authority. Mandatory policy is stated directly.

### Git and worktree boundary

Branch and merge authority appears first in the runtime section: agents work on the
assigned feature branch, never commit or push to `main`, and never merge or enable
auto-merge without authorization for that specific merge.

The assigned worktree remains the filesystem boundary for implementation work. Agents
do not use files from another worktree or the primary checkout as implementation inputs
and never modify them. Read-only inspection of committed objects, refs, and history is
allowed because it does not cross the filesystem implementation boundary.

Worktree lifecycle is operator-run. Agents do not create, remove, move, prune, repair,
or otherwise manage worktrees. An inconsistent or unsafe assigned worktree is a
stop condition, and unrelated changes are preserved.

Before each push, the agent fetches `origin` and inspects both `origin/main` and the
remote feature branch. Unexpected commits on the remote feature branch are a hard stop;
the agent does not overwrite or automatically reconcile them. If only `origin/main`
advanced, the agent rebases the clean assigned branch and reruns required validation.
A dirty branch is never rebased. When pushing rebased commits requires rewriting the
assigned remote feature branch, the agent uses only `--force-with-lease`; a failed lease
is a hard stop.

The following remain prohibited regardless of hook coverage:

- `git reset --hard`;
- `git clean -fd`;
- repository-wide `git checkout .`;
- repository-wide `git restore .`; and
- unconditional force-push.

### Cluster and privileged-operation ownership

Repository and cluster reads may use established read-only workflows with scoped
worktree credentials. Agents may execute established scoped verification with the
credentials provided to their assigned worktree. Flux-managed changes are made in Git.

If scoped credentials are absent, the agent stops and asks the operator to mint or
provide them. Agents do not retrieve, copy, expose, or manage operator credentials.
Per-invocation authorization permits the named action only; it does not transfer
credential custody or operator ownership.

Platform rollouts, break-glass actions, recovery, secret custody, branch-protection
mutation, and similar privileged operations remain operator-run. Agents prepare,
review, and validate the associated source changes. The exact
`github-protection-apply` command remains in `docs/github-protection.md`; root policy
states the ownership boundary rather than instructing agents to execute it.

### Secrets

Secret values are SOPS-encrypted in Git. The age private key remains with the operator.
Agents do not print, copy, decrypt, re-encrypt, rewrite, or commit plaintext credentials.
They may work with templates, schemas, references, non-secret metadata, and unchanged
operator-supplied encrypted artifacts without exposing underlying values. Gitleaks and
the staged-blob check remain required controls.

### Public repository

All repository and review surfaces are treated as public and permanently recoverable,
including branch names, commit messages, generated artifacts, and CI logs. Deletion and
history rewriting are not treated as reliable retraction mechanisms.

New and modified content does not publish actionable unresolved security gaps, exploit
paths, or remediation schedules. Sensitive unimplemented controls are handed to the
operator privately. Residual risk is described publicly as mitigated or accepted only
when that status is accurate and authorized.

New and modified content does not contain live public IPv4 or IPv6 addresses, hardware
serials, MAC addresses, credentials, or other unique infrastructure identifiers. Test
fixtures use RFC 5737 IPv4 or RFC 3849 IPv6 documentation ranges and synthetic values;
documentation uses clear placeholders.

Ordinary non-secret historical records are not rewritten solely to adopt the new
writing rule. Exposed credentials or materially sensitive information are incidents,
not protected history, and require operator-led containment and remediation.

### Validation and completion

Before opening or updating a pull request, the agent runs
`mise exec -- just ci`. It remains the canonical cluster-independent, secret-free gate.
Cluster-dependent workflows remain outside it. After a required rebase, the agent reruns
affected validation, including `just ci`.

Completion reports name changed files, validation performed and results, validation not
performed and why, non-sensitive remaining risks, and required operator actions.
Actionable security-sensitive risks are reported directly to the operator outside
repository artifacts.

### Repository-specific Superpowers adaptation

Durable approved architectural decisions become records in `docs/decisions/`.
Brainstorming specifications and implementation plans remain session-local, ignored, or
otherwise uncommitted. Agents do not create committed `docs/superpowers/specs/` or
`docs/superpowers/plans/` artifacts unless the operator explicitly changes repository
policy.

This amendment itself is the durable approved architectural decision. Its implementation
plan is intentionally not committed.

### Portainer disposition

Portainer remains an observability interface and must not become a deployment authority.
This accepted record now preserves that app-specific architectural decision. It is not a
root runtime rule that every agent must load.

## Exact runtime contract

The `AGENTS.md` committed with this record is the normative runtime text. It contains the
approved contract under the semantic headings above, without provenance prefixes. The
runtime file must remain concise enough to load every session; this record holds the
rationale, traceability, and scenario evidence that would otherwise bloat it.

## Supporting-file disposition

No scoped instruction files are proposed.

| Exact path | Disposition |
|---|---|
| `AGENTS.md` | Replace the categorized inventory with the approved semantic runtime contract. |
| `CLAUDE.md` | Retain unchanged as the thin vendor shim importing `AGENTS.md`. |
| `README.md` | Retain the agent/operator responsibility table introduced by PR #185. |
| `kubernetes/README.md` | Retain the scoped-read and Git-managed mutation guidance introduced by PR #185. |
| `talos/README.md` | Retain detailed Talos source, generation, and operator application procedure. |
| `tests/README.md` | Retain detailed test-selection and live-test ownership guidance. |
| `docs/runbooks/agent-cluster-access.md` | Retain credential tiers, minting, and scoped-verifier procedure. |
| `docs/github-protection.md` | Retain the exact guarded protection command and operator procedure. |
| `docs/sops.md` | Retain encryption and key-handling procedure. |
| `scripts/test/hooks-test.sh` | Replace the exact-24 inventory assertion with structural instruction-architecture tests. |
| `kubernetes/apps/kube-system/agent-access/ks.yaml` | Retain `suspend: false` after the completed live authorization proof. |

## Rule-disposition matrix

Each rule from the `origin/main` baseline and each additional PR #185 candidate rule has
one primary disposition. These labels remain in design traceability only.

| Source rule | Disposition | Destination or reason |
|---|---|---|
| Repository purpose and `main` as production boundary | Retained in root | Expanded to state live impact and documentation routing. |
| Never commit or push to `main` | Retained in root | Direct repository-wide safety policy. |
| Stay within the assigned worktree and preserve unrelated changes | Retained in root | Expanded into a filesystem boundary, committed-ref exception, and stop condition. |
| Fetch and rebase before a push | Retained in root | Corrected to inspect both remote branches and rebase only when `origin/main` advanced. |
| Never merge or auto-merge without specific authorization | Retained in root | Operator authority boundary. |
| Keep commits scoped and reviewable | Retained in root | Clarified as one coherent change per commit, split when independently reviewable or revertible. |
| Report files, validation, and remaining risk | Retained in root | Expanded into the completion contract and public/private risk boundary. |
| Run pinned tools through mise | Retained in root | One statement under Authority boundaries; not repeated under Validation. |
| All cluster mutations and health checks use guarded recipes | Retained in root | Reframed by effect: scoped reads and verification are allowed; privileged mutations remain operator-run. |
| Add a guarded recipe whenever an operation lacks one | Intentionally removed as redundant or obsolete | Too broad; accepted audit decision 2 limits platform recipes and removes app rollout wrappers. |
| Confirmed bootstrap recipes are operator-run | Retained in root | Generalized to privileged-operation ownership. |
| Rollout sources must match remote `origin/main` | Enforced mechanically by hook, CI, or recipe | Existing rollout guards own this procedural check. |
| GitHub protection mutation uses its guarded command | Moved to README or runbook | Exact command remains in `docs/github-protection.md`; root retains operator ownership. |
| Commit-time hooks and repository-wide lint | Retained in root | Kept as validation guidance without claiming hooks are authority. |
| `just ci` is the canonical offline gate | Retained in root | Adds the explicit before-open-or-update execution point. |
| Cluster-dependent suites stay outside `just ci` | Retained in root | Operator or scoped-agent ownership is determined by effect and credentials. |
| Secrets are SOPS-encrypted and the age key is operator-held | Retained in root | Repository-wide credential boundary. |
| Do not expose, decrypt, rewrite, or commit plaintext secrets | Retained in root | Clarified allowed work on non-secret structures and unchanged encrypted artifacts. |
| Secret creation uses operator-run recipes | Retained in root | Generalized under secret custody and privileged operations. |
| Public content cannot be retracted | Retained in root | Corrected to “public and permanently recoverable.” |
| State residual risk as mitigated or accepted | Retained in root | Corrected to require accurate authorization and prohibit actionable gap roadmaps. |
| Do not commit live public IPs or hardware identifiers | Retained in root | Adds IPv6, credentials, synthetic fixtures, and unique identifiers. |
| Existing records are not rewritten | Retained in root | Adds the security-incident carve-out. |
| Do not edit generated `clusterconfig/` | Retained in root | Source-only validation is agent-safe; key- or admin-dependent work is operator-run. |
| Preserve Talos/Kubernetes/Cilium compatibility | Retained in root | Replaced by documented pinned constraints and an approved-upgrade boundary. |
| Follow the application layout | Retained in root | Corrected to root-relative `kubernetes/apps/<domain>/<app>/`; procedure stays in `kubernetes/README.md`. |
| New apps begin suspended and use app bootstrap recipes | Intentionally removed as redundant or obsolete | Superseded by accepted audit decision 2's normal Flux rollout model. |
| RWO Deployment uses `Recreate` or StatefulSet | Retained in root | Repository-wide rendered workload invariant. |
| Inline provenance category on every rule | Intentionally removed as redundant or obsolete | Traceability lives in this matrix, not runtime prose. |
| Worktree lifecycle is operator-run | Retained in root | Expanded to all create/remove/move/prune/repair actions. |
| Destructive Git operations and unconditional force-push are prohibited | Retained in root | Direct policy independent of hook coverage. |
| Reads are direct; Flux-managed changes go through Git | Retained in root | Clarified as established scoped read workflows. |
| Missing worktree credentials require an operator handoff | Retained in root | Adds custody and per-invocation authorization semantics. |
| Portainer must not become deployment authority | Moved to README or runbook | Preserved as an app-specific accepted decision in this record, not root runtime policy. |
| Decisions are durable; plans remain uncommitted | Retained in root | Includes the repository-specific Superpowers adaptation. |
| Accepted decisions are superseded, never revised | Retained in root | This amendment demonstrates scoped later-record precedence without editing accepted text. |
| Assertions need an independent oracle or genuine invariant | Retained in root | Repository-wide validation quality rule. |

## Scenario-based acceptance

The proposed hierarchy was evaluated as if a fresh agent began each task with only root
`AGENTS.md`, the current tree, and the named supporting documentation.

| Scenario | Governing files | Agent may do | Operator-owned | Required validation | Stop condition | Result |
|---|---|---|---|---|---|---|
| Routine application manifest change | `AGENTS.md`, `kubernetes/README.md`, app sources and local README | Edit Git sources and perform offline validation | Merge and any privileged rollout | App-specific validation plus `mise exec -- just ci` before PR update | Unsafe worktree, conflicting policy, or required unavailable input | Pass |
| PR update after `origin/main` advances | `AGENTS.md`, Git refs | Fetch, inspect refs, rebase a clean branch, rerun validation | Merge | Affected checks and `just ci` | Dirty branch, unexpected remote feature commit, failed lease | Pass |
| Worktree with unrelated changes | `AGENTS.md`, `git status` | Work around and preserve unrelated files | Resolution when safe isolation is impossible | Tests for files actually changed | Assigned state is inconsistent, unsafe, or overlaps irreconcilably | Pass |
| Live diagnostic without cluster credentials | `AGENTS.md`, `docs/runbooks/agent-cluster-access.md` | Inspect source and plan the named scoped read | Mint or provide scoped credentials | Named verifier after credentials exist | Credentials absent or operation exceeds scoped authority | Pass |
| SOPS-managed secret change | `AGENTS.md`, `docs/sops.md`, templates and encrypted artifact | Edit schemas, references, non-secret metadata, or stage unchanged operator ciphertext | Age key custody and secret creation | Gitleaks, staged-blob checks, and `just ci` | Plaintext or key access would be required | Pass |
| GitHub branch-protection change | `AGENTS.md`, `docs/github-protection.md` | Inspect and review the read-only plan or source | Authorized protection mutation | Read-only protection check and `just ci` for source changes | Mutation requested of agent or authorization is absent/stale | Pass |
| Deployment mounting an RWO PVC | `AGENTS.md`, `kubernetes/README.md`, rendered workload sources | Choose `Recreate` or StatefulSet and validate render | Merge and rollout | App render/policy validation and `just ci` | Rendered Deployment would use `RollingUpdate` | Pass |
| Talos configuration change | `AGENTS.md`, `talos/README.md`, approved upgrade documentation | Edit `talconfig.yaml` or patches and run source-only validation | Key-dependent generation, apply, rollout, or independent upgrade approval | `talos source-validate` and `just ci`; operator runs privileged gates | Generated file edit, missing approved upgrade, key/admin access required | Pass |
| New architectural decision | `AGENTS.md`, current decision conventions | Draft a new record and revise it before acceptance | Operator acceptance and merge | Available documentation checks and `just ci` | Proposed record conflicts with accepted policy without naming the relationship | Pass |
| Superseding an accepted decision | `AGENTS.md`, accepted record, successor record | Add a successor; for full supersession change only the old status line | Operator approval | Available documentation checks and `just ci` | Any accepted content edit or missing successor target | Pass |
| Completion with unavailable validation | `AGENTS.md`, relevant testing documentation | Report performed results, unavailable validation and why, non-sensitive risk, and handoff | Any privileged or unavailable follow-up | Every available required check | Claiming completion without disclosing missing validation; publishing a sensitive attack path | Pass |

## Mechanical acceptance

`scripts/test/hooks-test.sh` enforces only stable instruction-architecture invariants:

- `AGENTS.md` is the only tracked repository instruction file;
- all eight semantic headings exist in the approved order;
- design-time provenance labels are absent;
- `CLAUDE.md` imports root `AGENTS.md`; and
- the vendor shim does not duplicate representative repository rules.

It does not enforce an exact rule count or exact prose. Operational meaning is reviewed
through the scenario matrix and the repository's existing independent controls.

## Consequences

- Root `AGENTS.md` is longer than PR #185's compressed inventory but remains below the
  audit's split threshold.
- Runtime agents see task-entry context and explicit stop conditions without reading an
  evidence matrix.
- Reviewers retain a complete disposition ledger in an immutable decision record.
- A future rule may be added or clarified without changing an arbitrary inventory count.
- No nested instruction precedence is introduced.
- No implementation plan is committed.
