# GitHub Protection Operator Runbook

This runbook is **non-authoritative operational guidance**. GitHub's effective
repository settings and active ruleset are the authority. This file is neither
desired state nor a reconciliation mechanism.

## Purpose and prerequisites

The `main` branch is the Flux production deployment boundary. GitHub must admit only
a current pull-request candidate that passed the repository's canonical `ci` check.

Maintenance requires:

- repository Administration permission;
- an authenticated, mise-pinned GitHub CLI;
- a recent successful `ci` check from GitHub Actions so its expected source can be
  selected; and
- the current GitHub REST API documentation for repository and ruleset endpoints.

Never store an exported ruleset, REST request payload, or apply script in the
repository. If durable reconciliation is needed, adopt a reviewed controller such
as Terraform as a separate architectural change.

## Required effective state

Repository merge settings allow squash merging and disable merge commits and rebase
merging. One active repository branch ruleset named `Protect main`:

- targets only `refs/heads/main`;
- has no bypass actors;
- requires a pull request with zero approvals and none of the optional review gates;
- permits only squash merging;
- requires the `ci` check from GitHub Actions with strict up-to-date enforcement;
- requires linear history; and
- blocks force pushes and branch deletion.

Do not enable update restrictions, merge queue, required deployments, required
signatures, or other rules unless a later decision explicitly adds them.

## Configure through GitHub

In **Settings → General → Pull Requests**, enable squash merging and disable merge
commits and rebase merging.

In **Settings → Rules → Rulesets**, create or edit the repository branch ruleset:

1. Name it `Protect main`, set enforcement to **Active**, and leave bypass actors
   empty.
2. Include `refs/heads/main` and no other ref.
3. Require pull requests with zero approvals, no stale-review dismissal, no Code
   Owner review, no last-push approval, and no conversation-resolution requirement.
4. Permit only squash merging.
5. Require status check `ci`, select **GitHub Actions** as its source, and require
   branches to be up to date before merging.
6. Require linear history, block force pushes, and restrict deletion.

The REST API can configure the same state without committing an apply mechanism.
Update merge methods with `PATCH /repos/{owner}/{repo}` and the boolean fields
`allow_squash_merge`, `allow_merge_commit`, and `allow_rebase_merge`. Create the
ruleset with `POST /repos/{owner}/{repo}/rulesets`; update an existing one with
`PUT /repos/{owner}/{repo}/rulesets/<ruleset-id>`.

For a one-time ruleset request, create a temporary file outside the checkout, edit
it from GitHub's current API schema using the required-effective-state list above,
submit it, then remove it:

```bash
ruleset_request="$(mktemp)"
${EDITOR:?Set EDITOR to prepare the one-time ruleset request} "$ruleset_request"
mise exec -- gh api --method POST repos/{owner}/{repo}/rulesets \
  --input "$ruleset_request"
rm -- "$ruleset_request"
```

The request must set the branch target, active enforcement, empty bypass array,
exact `main` ref condition, and only the five rules listed above. Select the
integration ID from a recent GitHub Actions `ci` check rather than assuming a
global constant. Do not create the temporary file inside the repository or retain
it as desired state. Read back the complete effective state after either UI or API
submission.

## Complete API read-back

Run these read-only commands from a checkout of this repository:

```bash
mise exec -- gh api repos/{owner}/{repo} \
  --jq '{allow_squash_merge,allow_merge_commit,allow_rebase_merge}'

mise exec -- gh api repos/{owner}/{repo}/rulesets \
  --jq '[.[] | {id,name,target,enforcement,source_type}]'

mise exec -- gh api repos/{owner}/{repo}/rulesets/<ruleset-id>

mise exec -- gh api repos/{owner}/{repo}/rules/branches/main
```

Inspect the complete ruleset, not only its list summary. Confirm the ref condition,
empty bypass list, all pull-request parameters, squash-only merge method, strict
required check, and GitHub Actions integration ID. The effective-branch response
must contain only the intended deletion, linear-history, pull-request,
required-status-check, and non-fast-forward rules from `Protect main`.

Ruleset history supports recent inspection and rollback only; it is retained for a
limited period and is not permanent audit storage. Downloaded ruleset JSON may omit
the bypass list, so it is not a substitute for authenticated API read-back.

## Safe functional verification

Use the normal implementation pull request rather than manufacturing destructive
tests:

1. Confirm the pull request automatically starts the `ci` check and cannot merge
   while it is pending or failing.
2. If a real follow-up commit is needed, confirm its push cancels the superseded run
   and starts `ci` for the new candidate.
3. Confirm GitHub requires the branch to be current with `main` and offers only
   squash merge.
4. After the operator explicitly authorizes and performs that specific merge,
   confirm no push-to-`main` workflow reruns the same full validation.
5. Confirm Flux observes the approved revision using the repository's guarded,
   read-only status recipe.

Do not intentionally push to `main`, introduce a failing commit, or open a second
test pull request solely to probe protection. Those scenarios should remain review
procedures, not production experiments.

### Documented negative scenarios

Use these only when the operator deliberately schedules protection testing; they
are not implementation prerequisites:

- **Intentional failure:** On a disposable pull-request branch, introduce a
  harmless validation failure, open a draft pull request targeting `main`, and
  confirm `ci` fails and the merge control remains blocked. Close the pull request
  and delete the branch without merging. Never place the failing commit on `main`.
- **Stale branch:** Prefer a naturally concurrent pull request. After another pull
  request changes `main`, confirm the older pull request reports that its branch
  must be updated and cannot merge despite its previous `ci` result. Update it from
  current `main` and confirm a new `ci` result is required.
- **Direct push:** Do not test this against the production repository because a
  misconfigured rule would deploy the pushed commit through Flux. Exercise a direct
  push only against a disposable repository with the same ruleset, where GitHub
  should reject it with a repository-rule violation. On production, use complete
  API read-back and ruleset insights as the safe verification seam.

## Periodic audit and recovery

Periodically repeat the full read-back, particularly after ownership, GitHub plan,
workflow, or ruleset changes. If observed behavior differs from the intended state,
inspect the complete repository settings, active ruleset, rules applying to `main`,
recent ruleset history, and the source of the latest `ci` check before editing
anything. Re-read the API state after every correction.
