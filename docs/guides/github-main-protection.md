# GitHub Main Protection

GitHub protects `main`, the Flux production deployment boundary. The repository
tracks a deterministic checker and guarded repair mechanism; GitHub's effective
repository settings and active rules remain the enforcement authority.

The intended path into production is:

```text
feature branch
  ↓
pull request
  ↓
branch is current with main
  ↓
ci succeeds for that candidate
  ↓
GitHub performs the allowed pull-request merge
  ↓
main
  ↓
Flux production
```

Direct pushes, force pushes, deletion of `main`, and merge methods other than squash
are not valid paths into production.

The control objective is:

> `refs/heads/main` can be updated only by GitHub completing a current, successful
> pull-request merge.

## GitHub plan and repository visibility

This repository is user-owned, currently public, and uses GitHub Rulesets to enforce the
`Protect main` contract. On the current GitHub account plan, Rulesets are available for
this repository only while it remains public. Public visibility is therefore a protection
prerequisite for the current environment, not a universal requirement for GitHub
repositories.

Moving the repository to a GitHub plan that supports Rulesets for private repositories
would also satisfy this prerequisite. Without that plan change, making the repository
private produces this failure when the checker requests the required Rulesets state:

```text
GitHub protection error: gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)
```

The two relevant cases are:

```text
current plan + public repository
  → Rulesets available
  → Protect main can be enforced
  → github-protection-check can verify it

current plan + private repository
  → Rulesets unavailable
  → GitHub returns HTTP 403
  → Protect main cannot be enforced through this mechanism
```

Treat that `403` as a failed protection prerequisite, not merely as a checker limitation.
Restore public visibility or move the repository to a plan that supports Rulesets for
private repositories before relying on this protection model.

## Required state

Two GitHub configuration layers work together:

- **Repository merge settings** control which merge buttons GitHub can offer for pull
  requests throughout the repository. This repository enables squash merge and disables
  merge commits and rebase merge.
- The **`Protect main` ruleset** controls how `main` may be updated. It requires a pull
  request, limits that pull request to squash merge, requires the current candidate to
  pass `ci`, and protects the branch history.

Both layers must allow squash and reject the other merge methods. A mismatch can either
offer a merge method that policy does not allow or block every valid merge method.

`.github/workflows/ci.yml` publishes the `ci` check. A workflow cannot create repository
rulesets or change repository merge settings, so the live GitHub repository must also
have:

- repository merge methods: squash enabled, merge commits and rebase disabled;
- one active repository ruleset named `Protect main`;
- target: only `refs/heads/main`, with no excluded refs and no bypass actors;
- required pull request: zero approvals and squash as its only merge method;
- stale-review dismissal, Code Owner review, last-push approval, conversation resolution,
  and required reviewers: off or empty;
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
3. **Settings → Branches → Branch protection rules** should have no legacy branch
   protection rule targeting `main`. GitHub layers legacy branch protection with
   rulesets, so an old rule could add requirements not represented by `Protect main`.
4. **Actions → CI** shows workflow runs that produce the required `ci` check.
5. A pull request targeting `main` shows the effective merge gate: `ci` must pass,
   the branch must be current, and squash must be the only offered merge method.

On **Settings → Rules → Rulesets → Protect main**, confirm that the enforcement
status is **Active**, the target includes only `main`, the bypass list is empty, and the
branch rules have these values:

| Rule | Setting |
| --- | --- |
| Restrict creations | Off |
| Restrict updates | Off |
| Restrict deletions | On |
| Require linear history | On |
| Require deployments to succeed before merging | Off |
| Require signed commits | Off |
| Require a pull request before merging | On |
| Require status checks to pass before merging | On |
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

GitHub currently shows **Require additional approval for unattributed Copilot pull
requests** as enabled by default. GitHub documents that it has no effect when required
approvals are `0`. The checker therefore does not treat that setting as part of this
repository's merge gate.

Under **Require status checks to pass before merging**, verify:

- required check: `ci`;
- expected source: GitHub Actions;
- require branches to be up to date before merging: on; and
- do not require status checks on creation: off.

## Check the enforced contract

### `check`: read-only comparison; no changes are made

From a checkout with an authenticated GitHub CLI and repository Administration
access, run:

```bash
mise exec -- just repo github-protection-check
```

The command reads repository merge settings, finds the repository-owned `Protect main`
ruleset, reads its complete definition, and resolves the expected GitHub Actions source
from a recent successful `ci` run. It also asks GitHub for every active ruleset rule that
applies to `main`, including rules inherited from an organization, and verifies that each
one comes from the expected `Protect main` ruleset.

Administration access is needed because GitHub omits the bypass list unless the caller
can write the ruleset. The command exits nonzero and reports drift when the managed state
differs. It also reports drift when an additional repository or organization ruleset
applies to `main`.

GitHub exposes legacy branch protection through a separate API. The checker does not read
that API, so also confirm the absence of a legacy rule under **Settings → Branches** as
described above.

For this repository, a passing result resembles:

```text
Repository: supermorphic/homelab-talos
GitHub Actions source: integration 15368 from successful commit <sha>
Ruleset: Protect main (ID <current-id>)
GitHub protection check: PASS
main accepts squash-merged pull requests only after strict GitHub Actions ci.
```

A pass means that the repository merge methods, the complete managed ruleset, and all
active ruleset rules applying to `main` match the repository contract.

Run the check after changes to repository ownership, GitHub plan, repository visibility,
merge settings, rulesets, or the `ci` workflow. In particular, changing the repository
from public to private can invalidate this protection model unless the account plan also
changes to one that supports Rulesets for private repositories. The check deliberately
stays outside `just ci`: live GitHub state requires authentication and is not part of the
cluster-independent, secret-free repository validation contract.

## Preview and repair drift

The three commands have different authority:

```text
check  → read-only comparison of live state
plan   → read-only preview of a proposed repair
apply  → mutation of live GitHub repository settings
```

### `plan`: read-only repair preview

```bash
mise exec -- just repo github-protection-plan
```

The plan reports whether it would change repository merge methods and create or
update `Protect main`. It makes no GitHub changes. Running or reviewing the plan does
not authorize apply.

### `apply`: live repository-administration mutation

Applying the proposed repair changes live GitHub administration settings. An operator may
run it. An agent may run it only when the operator explicitly authorizes that specific
invocation and the required administrative credential. After reviewing the plan, use the
exact repository-scoped guard:

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
2. Push a real follow-up commit to the feature branch. That commit creates a new
   candidate revision. Confirm it starts a new `ci` run and that a successful check on
   the older revision does not authorize the newer revision.
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
