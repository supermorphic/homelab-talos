# GitHub CI Authority and Lean Agent Instructions

Status: ready-for-agent

## Problem Statement

The repository currently describes local full validation as a mandatory agent
lifecycle gate, permits emergency direct updates to `main`, runs duplicate full CI
after changes land on `main`, and does not actively enforce the intended pull-request
boundary in GitHub. Detailed lifecycle and worktree procedures also make the agent
instructions longer and more subjective than necessary.

Because `main` is the Flux production deployment boundary, protection cannot depend
on documentation, local hooks, or an agent remembering a procedure. GitHub must be
the authoritative merge gate, while local staged-file hooks remain fast feedback and
the agent instructions retain only durable agent-specific safety boundaries.

## Solution

Keep the existing command model: staged pre-commit hooks provide the only automatic
local gate, `just repo lint` runs those hooks repository-wide, and `just ci` remains
the single canonical full, cluster-independent, secret-free validation command.

Make the pull-request GitHub Actions `ci` job the authoritative validation result.
Protect `main` with an active GitHub ruleset that requires a current pull request, the
GitHub Actions `ci` check, squash-only merging, and linear history, with no bypass
actors. Disable repository-level merge commits and rebase merges. Do not rerun the
same full CI workflow after the approved revision lands on `main`.

Reduce the agent instructions to a lean set of agent-specific safety boundaries.
Explain the concise human lifecycle in the normal repository workflow documentation,
document what GitHub protection was applied and where an operator can inspect it,
and track a deterministic check/plan/guarded-apply mechanism for repeatable drift
detection and recovery.

## User Stories

1. As a repository operator, I want GitHub to reject direct updates to `main`, so
   that every production revision enters through a pull request.
2. As a repository operator, I want the `ci` status check required on `main`, so
   that Flux only observes changes that passed the complete validation contract.
3. As a repository operator, I want no ruleset bypass actors, so that administrators,
   users, agents, and automation follow the same production boundary.
4. As a repository operator, I want urgent changes to use the normal pull-request
   path, so that emergency work does not create an unvalidated escape hatch.
5. As a repository operator, I want pull-request branches current with `main`, so
   that the validated tree includes the latest production changes.
6. As a repository operator, I want squash to be the only merge method, so that
   `main` retains a linear and intentional history.
7. As a repository operator, I want force pushes and branch deletion blocked on
   `main`, so that the production boundary cannot be rewritten or removed.
8. As a repository operator, I want zero required approvals unless a separate review
   policy is adopted, so that CI authority is not confused with review policy.
9. As a contributor, I want staged-file hooks to run automatically at commit time, so
   that cheap formatting, syntax, and secret errors are caught quickly.
10. As a contributor, I want formatter changes to block the current commit, so that
    I can review and stage the resulting edits before retrying.
11. As a contributor, I want no mandatory pre-push or post-commit full validation, so
    that local Git flow remains predictable and responsive.
12. As a contributor, I want to run the staged hook suite repository-wide on demand,
    so that I can check the whole tree without invoking full CI.
13. As a contributor, I want one canonical full validation command, so that local and
    GitHub behavior cannot drift between wrappers.
14. As a contributor, I want GitHub CI to start whenever a pull request targeting
    `main` is opened, reopened, or updated, so that every candidate revision reports
    the required result.
15. As a contributor, I want every pull request to report `ci` regardless of changed
    paths, so that path filters cannot leave the required check absent.
16. As a contributor, I want superseded runs for the same pull request cancelled, so
    that obsolete validation does not consume time or confuse the current result.
17. As a contributor, I want the full repository history available to CI, so that the
    existing repository-history secret scan retains its behavior.
18. As a contributor, I want CI to use repository-pinned tools, so that validation is
    reproducible across local and hosted environments.
19. As a contributor, I want CI to require no repository secrets, kubeconfig, age
    key, cluster access, or live service access, so that pull requests can be
    validated safely and consistently.
20. As a contributor, I want post-validation reports and artifacts to remain
    available, so that failures retain useful evidence without becoming alternate
    merge gates.
21. As a repository operator, I want no duplicate full-CI run after a squash merge,
    so that the already approved tree is not needlessly validated again.
22. As a repository operator, I want Flux to reconcile only after GitHub permits the
    approved squash merge, so that deployment follows the protected Git boundary.
23. As an agent, I want concise and observable Git rules, so that I can comply without
    interpreting subjective lifecycle language.
24. As an agent, I want to remain within my assigned worktree and branch, so that
    concurrent workstreams do not collide.
25. As an agent, I want to fetch and safely rebase immediately before every push, so
    that my branch incorporates concurrently merged work at the relevant boundary.
26. As an agent, I want merge authorization to apply to one specific merge, so that
    a stale or general approval cannot be mistaken for permission.
27. As an agent, I want to report changed files, validation actually performed, and
    remaining risks, so that the operator receives an accurate handoff.
28. As a repository operator, I want a concise lifecycle in normal workflow
    documentation, so that humans can understand how local feedback, GitHub CI, and
    Flux reconciliation connect.
29. As a repository administrator, I want a GitHub-protection guide, so that I can
    understand what was configured, where to inspect it, and how to verify it.
30. As a repository administrator, I want complete API read-back instructions, so
    that I can verify the effective rules rather than trusting an input form.
31. As a repository administrator, I want a safe functional verification procedure,
    so that protection can be tested without intentionally pushing an unreviewed
    commit to `main`.
32. As a repository administrator, I want the limits of ruleset history documented,
    so that recent rollback support is not mistaken for permanent external auditing.
33. As a future maintainer, I want an idempotent, guarded recovery command, so that a
    deleted or drifted ruleset can be repaired without reconstructing API payloads
    from prose.

## Implementation Decisions

- Do not introduce `ci-fast`, `ci-full`, or aliases for the existing full validation
  command.
- Retain the current staged-file hook membership and exclusions exactly. The hooks
  remain the only automatic local CI gate and operate only on staged files.
- Retain the repository-wide hook command and the canonical full validation command
  without changing their validation membership or behavior.
- Do not add a pre-push hook, post-commit hook, full-tree schema validation,
  per-application validation, repository-history scanning, or cluster-dependent work
  to the automatic commit gate.
- Run the authoritative workflow for pull requests targeting `main` and for manual
  dispatch only. Do not run the same workflow on pushes to `main`.
- Keep one stable required job and check name: `ci`.
- The workflow installs repository-pinned tools, checks out full history, and invokes
  only `mise exec -- just ci` as its validation entry point.
- Retain post-validation summaries and artifacts as evidence. They must not become
  alternate validation commands or required checks.
- Use concurrency cancellation for superseded runs belonging to the same pull
  request.
- Configure repository merge settings with merge commits disabled, rebase merges
  disabled, and squash merges enabled.
- Create one active branch ruleset named `Protect main`, targeting
  `refs/heads/main`, with an empty bypass list.
- Require a pull request with zero approvals, no stale-approval dismissal, no Code
  Owner review, no last-push approval, and no conversation-resolution requirement.
- Allow squash as the only merge method.
- Require the `ci` check from GitHub Actions and enable the strict up-to-date policy.
- Require linear history and block force pushes and branch deletion.
- Do not enable update restrictions, merge queue, required deployments, or required
  signed commits.
- GitHub's active repository settings and active ruleset are the enforcement
  authority. Track the intended contract as executable comparison and payload logic,
  not as an exported API response.
- Explain that pull-request Actions validates GitHub's merge candidate. A later
  squash produces a different commit identity but, with the strict up-to-date
  requirement, represents the equivalent source tree.
- Keep the agent instructions under approximately 80 lines. Retain the repository
  purpose, five concise Git/worktree boundaries, pinned tool and guarded-cluster
  requirements, secrets safety, Talos generation rules, critical Flux/storage
  invariants, and links to detailed documentation.
- The five Git/worktree boundaries are: never commit or push directly to `main`;
  never merge without explicit authorization for that specific merge; stay within
  the assigned worktree and branch; immediately before every push, fetch `origin`
  and safely rebase a clean branch onto `origin/main` when needed; and report changed
  files, validation performed, and remaining risks.
- Remove general CI lifecycle policy, implementation-plan checkpoints, intermediate
  handoff requirements, hook-bypass policy, and emergency direct-to-main procedures
  from the agent instructions.
- Put one concise lifecycle in the normal repository workflow documentation:
  commit-time staged hooks, feature-branch push, pull-request `ci`, protected squash
  merge, then Flux reconciliation.
- Add a human-facing guide that records what was configured, where to inspect it in
  GitHub, the exact effective state, read-only verification, guarded recovery, and
  safe functional verification.
- Provide read-only `github-protection-check` and `github-protection-plan` recipes.
  Provide an idempotent `github-protection-apply` recipe guarded by an exact,
  repository-scoped confirmation value and explicit authorization for each use.
- The apply implementation updates squash-only merge settings and creates or updates
  `Protect main`; it refuses ambiguous duplicate rulesets or unexpected effective
  rules, dynamically resolves the GitHub Actions integration ID from a recent
  successful `ci` check, and performs complete post-write read-back.
- Correct existing documentation only where it contradicts this authority model.
  Do not create another general CI-policy document.
- Initial protection may be applied by an operator or by an agent acting under
  explicit authorization for that operation. Historical approval never authorizes a
  later mutation.

## Testing Decisions

- Favor external behavior over implementation details. The live seam is GitHub's
  effective repository and branch-rule state; offline unit tests cover payload
  construction, semantic comparison, missing-ruleset recovery planning, source
  resolution, and confirmation safety.
- Read repository merge settings back through the GitHub API and confirm only squash
  merging is enabled.
- List and inspect the complete active `Protect main` ruleset and check the rules
  applying to `main`.
- Verify the active enforcement state, exact ref target, empty bypass list, pull
  request rule, zero approvals, squash-only method, GitHub Actions source for `ci`,
  strict required-status policy, linear history, force-push block, and deletion
  block.
- Use the normal implementation pull request as the functional seam. Confirm that
  `ci` starts automatically, blocks merge while pending, and permits only squash
  merge after passing.
- Push a subsequent implementation commit if one is naturally required and confirm
  that `ci` reruns. Do not manufacture an unnecessary commit solely for this test.
- After the operator merges, confirm that no duplicate push-to-`main` CI workflow
  runs and that Flux observes the approved revision.
- Document intentional-failure, stale-branch, and direct-push verification scenarios,
  but do not inject a failing commit, create a second concurrent test pull request,
  or intentionally push an unreviewed commit to `main` during implementation.
- Run the unchanged canonical full validation command as the repository regression
  seam.
- Let the existing staged hooks exercise their normal commit-time behavior.
- Inspect the workflow structurally to confirm its triggers, lack of path filters,
  canonical command, pinned tools, full checkout, and absence of cluster or secret
  dependencies.
- Exercise the protection unit tests through the existing Python test-harness suite;
  do not add live authenticated GitHub state to `just ci`.

## Out of Scope

- Changing the membership, order, assertions, fail-fast behavior, or implementation
  of `just ci`.
- Introducing `ci-fast`, `ci-full`, parallel CI jobs, change-aware skipping, or a new
  local validation lifecycle.
- Adding pre-push or post-commit hooks.
- Adding required approvals, Code Owner review, conversation resolution, merge
  queue, signed commits, required deployments, or update restrictions.
- Creating a permanent emergency direct-to-main path.
- Introducing Terraform or another GitHub-settings controller.
- Optimizing catalog validation, Helm rendering, chart downloads, or any other
  validation runtime.
- Merging the implementation pull request; merge remains an operator action unless
  separately authorized for that specific merge.

## Further Notes

- Repository merge settings were moved to squash-only and `Protect main` was
  activated on 2026-07-31 during implementation.
- The authoritative required check already exists as `ci` from GitHub Actions.
- The active ruleset and repository settings must be read back after creation;
  successful submission alone is not sufficient evidence.
- GitHub ruleset history is useful for recent inspection and rollback but is retained
  for a limited period. Downloaded ruleset JSON does not include the bypass list.
- Initial `Protect main` activation was performed through the API with explicit
  operator approval. That historical approval does not authorize future settings
  mutations; each guarded apply requires a new, explicit authorization.
