# Agent Instructions

Canonical, vendor-neutral rules for agents and contributors. `CLAUDE.md` imports
this file.

## Repository purpose

`homelab-talos` manages a three-node Talos Linux + Flux GitOps Kubernetes cluster.
Git is the source of truth, and `main` is the Flux production deployment boundary.

## Precedence

1. A constraint in this file is a floor. A scoped `AGENTS.md` may narrow or
   strengthen it, never relax or override it. A scoped file that appears to
   permit what this file prohibits is defective — obey this file and report it.
2. Runbooks and skills carry procedure only. They never grant permission.
3. Deterministic enforcement outranks every instruction. If a guard refuses,
   the answer is no.
4. On any unresolved conflict, stop and ask the operator. Never take the
   permissive reading.

## Scoped instructions are required reading

Before modifying any file under a directory that has its own `AGENTS.md`, read
that file. Do not assume your client loaded it automatically — verify. If a
scoped file cannot be read, stop and report rather than proceeding under root
rules alone.

## Git and approval authority

- Never commit or push directly to `main`; work on the assigned feature branch.
- Keep commits scoped and reviewable. Preserve unrelated user changes.
- Report changed files, validation actually performed, and remaining risks or
  deferred work.
- Never merge or enable auto-merge without explicit operator authorization for
  that specific merge. General or stale approval does not count.
- The operator owns merge and rollout.

## Worktrees and concurrency

- The assigned worktree is an absolute filesystem boundary. Stay on the assigned
  branch. Never read or write another slot.
- Never run `git worktree add`, `remove`, `move`, `prune`, `lock`, `unlock`, or
  `repair`.
- Never begin work in a slot parked on an unmerged branch.
- Immediately before every push, fetch `origin` and, when needed, safely rebase a
  clean branch onto `origin/main`.
- If rewriting a remote branch is necessary, use only `--force-with-lease`. A
  failed lease is a full stop.
- Never use `git reset --hard`, `git clean -fd`, or an unconditional force-push.

## Tools and cluster access

- Run repository workflows through the pinned toolchain with `mise exec -- just …`.
  Use `mise exec -- <tool> …` for pinned ad hoc inspection when no recipe exists.
  Never use unpinned or system tools.
- All cluster mutations and health checks use guarded `just` recipes. Never run raw
  `kubectl`, `talosctl`, `helm`, or `flux` against the live cluster.
- If a needed cluster operation has no recipe, add an appropriately guarded recipe.
- Cluster-mutating `bootstrap …` recipes require an explicit `*_CONFIRM` value and
  are operator-run. Agents never invent a `*_CONFIRM` value. Agents stage and
  validate source, then hand off the rollout.
- Guarded rollouts must verify their implementation and rollout-specific sources
  match the current remote `origin/main` commit.
- GitHub protection checks and plans are read-only. Any protection mutation requires
  explicit authorization for that invocation and must use the guarded
  `mise exec -- just repo github-protection-apply` recipe; never use ad-hoc API calls.

## Secrets

- All secrets are SOPS-encrypted (`*.sops.yaml`); the age private key remains only
  with the operator.
- Never handle the age key, decrypt or rewrite encrypted manifests, expose secret
  values, copy legacy ciphertext, or commit plaintext credentials.
- Secrets are created under this repository's age key through guarded,
  operator-run `*-secrets` recipes.

## Validation

- `mise exec -- just ci` is the authoritative, cluster-independent, secret-free
  validation command used by the required GitHub pull-request check.
- Cluster-dependent `*-verify`, `*-status`, `*-preflight`, and diagnostic families
  are operator-only and never enter `just ci`.

## Scoped instruction index

- Read `kubernetes/AGENTS.md` before changing Kubernetes or Flux sources.
- Read `talos/AGENTS.md` before changing Talos sources, generation inputs, or root
  `clusterconfig/`.
- Read `tests/AGENTS.md` before changing the test catalog, suites, fixtures, or
  test result and guard machinery, including `scripts/test/`.
- Read the relevant file under `docs/runbooks/` before following a repository procedure.
- Current `docs/phase-*.md` files are completed rollout history, not live procedure.
- `docs/superpowers/specs/` records design rationale and is descriptive, never normative.
