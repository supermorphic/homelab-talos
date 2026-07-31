# 03 — Prove the protected PR-to-Flux handoff

**What to build:** Use the normal implementation pull request and operator-owned
squash merge as the functional proof that GitHub admits only the current,
successfully validated source tree to the Flux production boundary, without
running duplicate full CI after merge.

**Blocked by:** 02 — Align repository workflows and guidance with GitHub CI
authority.

**Status:** needs-triage

- [x] The implementation pull request starts the `ci` check automatically and
      cannot merge while that check is pending or failing.
- [x] If an additional implementation commit is naturally required, its push
      supersedes the obsolete run and starts `ci` for the updated candidate; no
      artificial commit is created only to exercise this behavior.
- [x] GitHub requires the branch to be current with `main` and exposes squash as
      the only merge method.
- [x] The operator reviews and explicitly authorizes the specific squash merge;
      no agent merges, enables auto-merge, or treats prior authorization as current
      permission.
- [x] After the operator merges, Actions history shows no duplicate full-CI run
      caused by the resulting push to `main`.
- [x] Flux observes the approved merged revision after GitHub permits it across the
      protected boundary.
- [x] Repository merge settings and the complete active ruleset are read back again
      if functional behavior differs from the documented configuration.
- [x] Intentional-failure, stale-branch, and direct-push scenarios remain documented
      procedures rather than destructive implementation-time experiments.
- [x] The final handoff reports the changed files, validation actually performed,
      observed GitHub and Flux evidence, and any remaining risks or deferred work.

## Comments

2026-07-31: PR #165 passed the required pull-request `ci` check and remained blocked
while that check was pending. The operator squash-merged it as
`11d200680d29c148882f94bc4190b8a14e126483`. Actions history contained no
push-to-`main` full-CI run for the merge. Complete GitHub protection read-back passed
afterward with active ruleset `Protect main` (ID `20116777`), no bypass actors, and
strict GitHub Actions `ci`. The operator ran the guarded Flux status check and
confirmed the merged revision reconciled successfully. The GitHub CI authority
effort is complete; destructive negative scenarios remain documented rather than
executed against production.
