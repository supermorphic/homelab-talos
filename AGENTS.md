# Agent Instructions

Canonical, vendor-neutral rules for agents and contributors. `CLAUDE.md` imports
this file.

## Repository purpose

`homelab-talos` manages a three-node Talos Linux + Flux GitOps Kubernetes cluster.
Git is the source of truth, and `main` is the Flux production deployment boundary.

## Git and worktrees

- Never commit or push directly to `main`; work on the assigned feature branch.
- Stay within the assigned worktree and branch. Preserve unrelated user changes.
- Immediately before every push, fetch `origin` and, when needed, safely rebase a
  clean branch onto `origin/main`.
- Never merge or enable auto-merge without explicit operator authorization for that
  specific merge. General or stale approval does not count.
- Keep commits scoped and reviewable.
- Report changed files, validation actually performed, and remaining risks or
  deferred work.

## Tools and cluster access

- Run repository workflows through the pinned toolchain with `mise exec -- just …`.
  Use `mise exec -- <tool> …` for pinned ad hoc inspection when no recipe exists.
  Never use unpinned or system tools.
- All cluster mutations and health checks use guarded `just` recipes. Never run raw
  `kubectl`, `talosctl`, `helm`, or `flux` against the live cluster.
- If a needed cluster operation has no recipe, add an appropriately guarded recipe.
- Cluster-mutating `bootstrap …` recipes require an explicit `*_CONFIRM` value and
  are operator-run. Agents stage and validate source, then hand off the rollout.
- Guarded rollouts must verify their implementation and rollout-specific sources
  match the current remote `origin/main` commit.
- GitHub protection checks and plans are read-only. Any protection mutation requires
  explicit authorization for that invocation and must use the guarded
  `mise exec -- just repo github-protection-apply` recipe; never use ad-hoc API calls.

## Validation

- Commit-time pre-commit hooks are staged-file fast feedback. Run the same hooks
  repository-wide with `mise exec -- just repo lint` when useful.
- `mise exec -- just ci` is the canonical full, cluster-independent, secret-free
  validation command used by the required GitHub pull-request check.
- Keep cluster-dependent `*-verify`, `*-status`, `*-preflight`, and diagnostics out
  of `just ci`; they remain operator-only.

## Secrets

- All secrets are SOPS-encrypted (`*.sops.yaml`); the age private key remains only
  with the operator.
- Never handle the age key, decrypt or rewrite encrypted manifests, expose secret
  values, copy legacy ciphertext, or commit plaintext credentials.
- Secrets are created under this repository's age key through guarded,
  operator-run `*-secrets` recipes.

## Talos and Flux invariants

- Do not edit generated files under `clusterconfig/`. Change `talos/talconfig.yaml`
  and `talos/patches/`, then run the `just talos generate` flow. Preserve
  Talos/Kubernetes/Cilium compatibility.
- Follow `kubernetes/apps/<domain>/<app>/{ks.yaml, app/, config/}` and existing
  Flux source, HelmRelease, Kustomization, and `dependsOn` patterns.
- New apps begin suspended, roll out through guarded `just bootstrap <app>`, then
  persist the unsuspended state. Do not suspend Flux resources without approval.
- A Deployment mounting a `ReadWriteOnce` PVC uses `Recreate` (or a StatefulSet),
  never `RollingUpdate`.
