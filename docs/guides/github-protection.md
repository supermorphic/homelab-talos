# GitHub Main Protection

GitHub protects `main`, the Flux production deployment boundary. The repository
tracks a deterministic checker and guarded repair mechanism; GitHub's effective
repository settings and active rules remain the enforcement authority.

The control objective is:

> `refs/heads/main` can be updated only by GitHub completing a current, successful
> pull-request merge.

## Required state

`.github/workflows/ci.yml` publishes the `ci` check but cannot create repository
rulesets or change merge settings. The live GitHub repository must have:

- repository merge methods: squash enabled, merge commits and rebase disabled;
- one active repository ruleset named `Protect main`;
- target: only `refs/heads/main`, with no excluded refs and no bypass actors;
- required pull request: zero approvals and squash as its only merge method;
- optional review gates: all off;
- required status check: `ci` from GitHub Actions, with the branch required to be up
  to date;
- linear history required; and
- deletion and force pushes blocked.

The tracked implementation is
[`scripts/repository/github_protection.py`](../../scripts/repository/github_protection.py).
It dynamically obtains the GitHub Actions integration ID from a recent successful
`ci` check rather than retaining `15368` as a global constant.

## Where to inspect it in GitHub

Use these GitHub pages for a visual inspection:

1. **Settings → General → Pull Requests** shows the repository merge methods.
   **Allow squash merging** should be on; merge commits and rebase merging should be
   off.
2. **Settings → Rules → Rulesets → Protect main** shows the ruleset target, bypass
   list, enforcement state, and individual rules.
3. **Actions → CI** shows workflow runs that produce the required `ci` check.
4. A pull request targeting `main` shows the effective merge gate: `ci` must pass,
   the branch must be current, and squash must be the only offered merge method.

The ruleset's visible top-level settings should be:

| Rule | Setting |
| --- | --- |
| Restrict creations | Off |
| Restrict updates | Off |
| Restrict deletions | On |
| Require linear history | On |
| Require deployments to succeed | Off |
| Require signed commits | Off |
| Require a pull request before merging | On |
| Require status checks to pass | On |
| Block force pushes | On |
| Require code scanning results | Off |
| Require code quality results | Off |
| Restrict code coverage | Off |
| Automatically request Copilot code review | Off |

Keep **Restrict updates** off. The pull-request rule rejects direct pushes. An
update restriction with no bypass actors would also prevent GitHub from completing
valid pull-request merges.

Under **Require a pull request before merging**, verify:

- required approvals: `0`;
- stale-review dismissal, Code Owner review, restricted review dismissal,
  last-push approval, and conversation resolution: off;
- required reviewers: none; and
- allowed merge methods: squash only.

Under **Require status checks to pass**, verify:

- required check: `ci`;
- expected source: GitHub Actions;
- require branches to be up to date before merging: on; and
- do not require status checks on creation: off.

## Check the complete live state

From a checkout with an authenticated GitHub CLI and repository Administration
access, run:

```bash
mise exec -- just repo github-protection-check
```

This is read-only. It reads repository merge settings, finds the repository-owned
`Protect main` ruleset, reads its complete definition, resolves the expected GitHub
Actions source from a recent successful `ci` run, and reads every effective rule on
`main`. Administration access is needed because GitHub omits the bypass list from
ruleset read-back for less-privileged callers. The command exits nonzero and reports
drift if any part differs.

For this repository, a passing result resembles:

```text
Repository: supermorphic/homelab-talos
GitHub Actions source: integration 15368 from successful commit <sha>
Ruleset: Protect main (ID <current-id>)
GitHub protection check: PASS
main accepts squash-merged pull requests only after strict GitHub Actions ci.
```

Run the check after changes to repository ownership, GitHub plans, merge settings,
rulesets, or the `ci` workflow. It deliberately stays outside `just ci`: live GitHub
state requires authentication and is not part of the cluster-independent,
secret-free repository validation contract.

## Preview and repair drift

Preview is also read-only:

```bash
mise exec -- just repo github-protection-plan
```

The plan reports whether it would change repository merge methods and create or
update `Protect main`. It makes no GitHub changes.

Applying a plan is a live repository-administration mutation. An operator may run
it or explicitly authorize an agent to run it for that invocation. After reviewing
the plan, use the exact repository-scoped guard:

```bash
GITHUB_PROTECTION_CONFIRM='apply:github-protection:supermorphic/homelab-talos' \
  mise exec -- just repo github-protection-apply
```

Apply is idempotent:

- when everything matches, it performs no mutation;
- when merge methods drift, it restores squash-only merging;
- when `Protect main` drifts, it updates that ruleset;
- when `Protect main` was deleted, it recreates it and accepts GitHub's new ID; and
- after a mutation, it performs the same complete read-back as `check`.

For safety, apply refuses to guess when duplicate `Protect main` rulesets exist or
when another ruleset already contributes effective rules to `main`. Inspect and
resolve those cases deliberately in **Settings → Rules → Rulesets**, then rerun the
plan. The confirmation value authorizes only this guarded GitHub-protection action;
it does not authorize merging a pull request or any other repository mutation.

## Safe functional verification

Use a normal implementation pull request rather than probing the production branch
with a direct push:

1. Confirm the pull request starts `ci` and cannot merge while it is pending or
   failing.
2. Confirm a real follow-up commit starts `ci` for the new candidate and supersedes
   the older run.
3. Confirm GitHub requires the branch to be current with `main` and offers only
   squash merge.
4. After the operator authorizes and performs that specific merge, confirm no
   push-to-`main` workflow reruns the same full validation.
5. Confirm Flux observes the approved revision with
   `mise exec -- just kube flux-status`.

Do not intentionally test a direct push against this production repository. If the
rule were broken, Flux could deploy the pushed commit. The complete API read-back,
ruleset insights, and normal pull-request behavior are the safe verification seams.

GitHub ruleset history supports recent inspection and rollback only; it is not
permanent audit storage. The tracked checker and guarded apply path provide the
repeatable verification and recovery mechanism if the live ruleset is later changed
or deleted.
