# Repository Rules

Canonical, vendor-neutral rules for agents and contributors. `CLAUDE.md` imports
this file.

- [Authoritative — branch protection] Never push to `main`.
- [Operator policy — operator] Never commit on a checked-out `main` branch.
- [Operator policy — operator] Never merge or enable auto-merge without per-merge authorization.
- [Operator policy — operator] Work on the assigned branch in the current worktree; preserve unrelated changes.
- [Operator policy — operator] Worktree lifecycle (`wt switch --create`, `wt remove`) is operator-run.
- [Operator policy — operator] Keep commits scoped and reviewable.
- [Operator policy — operator] Report changed files, validation performed, and remaining risk.
- [Operator policy — operator] Fetch and rebase before every push.
- [Authoritative — PreToolUse hook (bypassable)] Never use `git reset --hard`, `git clean -fd`, unqualified `git checkout .` or `git restore .`, or force-push without a lease.
- [Authoritative — credential tiers] Reads are direct; changes to Flux-managed state go through Git.
- [Gotcha] A worktree has no cluster credentials until asked for; stop and ask the operator to mint them.
- [Authoritative — admin credential custody] Platform rollouts, break-glass, recovery, secrets, and protection changes are operator-run under `*_CONFIRM`.
- [Authoritative — guarded recipe and token scope] GitHub protection mutation needs per-invocation authorization; use `mise exec -- just repo github-protection-apply`.
- [Authoritative — key custody, gitleaks, and staged-blob check] Secrets are SOPS-encrypted; the age key stays with the operator.
- [Authoritative — required GitHub check] `just ci` is the authoritative cluster-independent gate.
- [Authoritative — validation.test-harness] Cluster-dependent suites never enter `just ci`.
- [Authoritative — mise.lock] Run workflows through `mise exec -- just`; do not use unpinned tools.
- [Gotcha] Never hand-edit `clusterconfig/`; regenerate it from `talos/talconfig.yaml`.
- [Authoritative — source-layer policy] Follow the `apps/<domain>/<app>/` layout.
- [Authoritative — rendered-layer policy] A Deployment mounting an RWO PVC uses `Recreate` or a StatefulSet.
- [Operator policy — operator] Portainer must not become a deployment authority.
- [Authoritative — validation.decisions] Design decisions go in `docs/decisions/`; plans are not committed.
- [Authoritative — validation.decisions] An `Accepted` record is superseded, never revised.
- [Operator policy — operator] An assertion must have an independent oracle or encode an invariant.
