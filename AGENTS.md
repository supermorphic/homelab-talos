# Agent Instructions

Canonical, vendor-neutral operating rules for AI agents and contributors working in
this repository. (Claude Code loads `CLAUDE.md`, which imports this file.)

## Repository purpose

`homelab-talos` manages a three-node Talos Linux + Flux GitOps Kubernetes cluster.
**Git is the source of truth and `main` is the Flux production deployment
boundary** — Flux continuously reconciles `main` onto the live cluster.

## Required workflow

- **Never commit or push directly to `main`.** Create a branch (`feat/…`, `fix/…`),
  make the change, and open a pull request.
- Before opening or updating a PR, **`just ci` must pass locally** — the single
  cluster-independent, secret-free validation contract.
- Open PRs with `gh pr create`; **squash-merge** after the `ci` status check is
  green. Flux then reconciles the merged `main` commit.
- Direct commits to `main` or rule bypasses are for **emergency recovery only** and
  must be followed by `just ci` on `main`.
- Keep commits scoped and reviewable. Report which validation ran versus was
  skipped, and why.

## Git worktrees

Development may happen in a **reusable agent worktree slot** — a persistent linked
worktree the operator provisions once, in which the agent works one feature branch
at a time. **First determine whether the current checkout is a worktree**, then
apply the rules below only if it is.

- Detect by comparing:

  ```
  git rev-parse --git-dir          # e.g. .../.git/worktrees/<name> in a worktree
  git rev-parse --git-common-dir   # the shared repo .git
  ```

  If the two differ, this is a **linked worktree slot** — abide by these rules. If
  they are equal, this is the primary checkout — the normal `Required workflow`
  applies (which already forbids committing/pushing to `main`).

The operator owns worktree lifecycle. The agent **never** runs
`git worktree add|remove|move|prune|lock|unlock|repair`, and never modifies the
primary checkout or any other worktree slot.

**Starting a task in a slot** — bring it onto the assigned branch off fresh remote
state:

1. Confirm the tree is clean with `git status --short`. If it is not clean, or the
   slot is still parked on a prior feature branch whose PR has not merged, stop and
   hand back to the operator — do not switch away from unreleased work.
2. Refresh remote state with `git fetch origin`.
3. Move onto the assigned branch off `origin/main`:
   - new branch: `git switch -c <assigned-branch> origin/main`
   - resuming an existing branch (e.g. addressing PR review):
     `git switch <assigned-branch>` — do not `reset --hard` onto `origin/main`
     without explicit approval.
4. Confirm the active branch with `git branch --show-current` before modifying files.

**During a task:**

- Stay on the assigned feature branch; confirm it again with
  `git branch --show-current` before committing or pushing. Never switch the slot to
  local `main`.
- Do not create additional branches unless the task explicitly requires it, and do
  not rename or delete branches.
- Push only the assigned feature branch; open pull requests against `main` and never
  merge directly into it.
- Do not use `git reset --hard`, `git clean -fd`, or force-push without explicit
  approval.

**After a task:** do not switch branches or delete the feature branch until its pull
request has merged or the operator explicitly releases the slot. Before releasing,
confirm there are no staged, unstaged, or untracked files (`git status --short`).

## Interface: `mise` + `just`

- Run every tool through the pinned toolchain: `mise exec -- just …`. Do not use
  unpinned or system tools.
- **All cluster mutations and health checks are guarded `just` recipes — never run
  raw `kubectl`, `talosctl`, `helm`, or `flux` against the live cluster.** If a
  needed operation has no recipe, add a guarded recipe rather than an ad-hoc command.
- Cluster-mutating `bootstrap …` recipes require an explicit `*_CONFIRM` value and
  are **operator-run**. Agents stage the source, validate, commit, and hand off the
  rollout — they do not run live rollouts.

## Validation

`just ci` is authoritative and cluster-independent (no kubeconfig, no age key, no
cluster/DNS access; it does need network egress to pull public Helm charts). It
aggregates `just repo lint`, `just repo verify`, and the per-app `just kube
*-validate` recipes. The cluster-dependent `*-verify`, `*-status`, `*-preflight`,
and diagnostic recipes are **local/operator-only** and must not be added to `just
ci`.

## Secrets

- All secrets are **SOPS-encrypted** (`*.sops.yaml`). The age **private** key lives
  only with the operator (password manager + their shell).
- Never handle the age key, decrypt or rewrite `*.sops.yaml`, or print secret values
  in output, diffs, plans, or summaries.
- Never copy legacy ciphertext from other repositories — recreate secrets under this
  repo's age key via the guarded, operator-run `*-secrets` recipes.
- Never commit plaintext credentials.

## Talos

- Do not hand-edit generated files under `clusterconfig/` (gitignored). Change Talos
  config via `talos/talconfig.yaml` + `talos/patches/` and the `just talos generate`
  flow.
- Preserve Talos / Kubernetes / Cilium version compatibility.

## Flux and app layout

- Follow the existing layout: `kubernetes/apps/<domain>/<app>/{ks.yaml, app/,
  config/}`. New apps stage `suspend: true`, roll out via a guarded `just bootstrap
  <app>`, then flip to `suspend: false` durably.
- Reuse existing HelmRelease / Kustomization / OCIRepository patterns; preserve
  `dependsOn` ordering; do not suspend Flux resources unless explicitly authorized.
- A `Deployment` mounting a `ReadWriteOnce` PVC must use `strategy: Recreate` (or a
  StatefulSet), never RollingUpdate — see README "ReadWriteOnce volumes".

## Completion criteria

Review the final diff, run `just ci` (and any relevant local `*-verify` if you have
cluster access), and summarize changed files, validation performed, and remaining
risks or deferred work.

See `README.md` for the human workflow and `docs/` for phase runbooks. Detailed
procedures live in `just` recipes and `docs/`, not in this file.
