# 03 — Prove the protected PR-to-Flux handoff

**What to build:** Use the normal implementation pull request and operator-owned
squash merge as the functional proof that GitHub admits only the current,
successfully validated source tree to the Flux production boundary, without
running duplicate full CI after merge.

**Blocked by:** 02 — Align repository workflows and guidance with GitHub CI
authority.

**Status:** ready-for-human

- [ ] The implementation pull request starts the `ci` check automatically and
      cannot merge while that check is pending or failing.
- [ ] If an additional implementation commit is naturally required, its push
      supersedes the obsolete run and starts `ci` for the updated candidate; no
      artificial commit is created only to exercise this behavior.
- [ ] GitHub requires the branch to be current with `main` and exposes squash as
      the only merge method.
- [ ] The operator reviews and explicitly authorizes the specific squash merge;
      no agent merges, enables auto-merge, or treats prior authorization as current
      permission.
- [ ] After the operator merges, Actions history shows no duplicate full-CI run
      caused by the resulting push to `main`.
- [ ] Flux observes the approved merged revision after GitHub permits it across the
      protected boundary.
- [ ] Repository merge settings and the complete active ruleset are read back again
      if functional behavior differs from the documented configuration.
- [ ] Intentional-failure, stale-branch, and direct-push scenarios remain documented
      procedures rather than destructive implementation-time experiments.
- [ ] The final handoff reports the changed files, validation actually performed,
      observed GitHub and Flux evidence, and any remaining risks or deferred work.
