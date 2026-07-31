<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: hand-maintained; keep sections and order, edit content -->
<!-- Last updated: 2026-07-31 -->

# Agent Instructions

Canonical, vendor-neutral rules for agents and contributors. `CLAUDE.md` imports
this file.

**Precedence:** the closest `AGENTS.md` to the files you are changing wins, and an
explicit user prompt overrides both. Scoped files add procedure; they never relax
the safety, approval, or merge boundaries below.

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

## Platform invariants

Talos, Flux, and Kubernetes procedure lives in the scoped files below — read the
one for the directory you are editing before you change anything in it. Two
boundaries apply everywhere and are not delegated: never suspend a Flux resource
without approval, and cluster rollouts stay operator-run.

## Scoped AGENTS.md (MUST read when working in these directories)

| Directory | File | Covers |
|-----------|------|--------|
| `kubernetes/` | [kubernetes/AGENTS.md](./kubernetes/AGENTS.md) | Flux app layout, `ks.yaml`, gateway label, RWO rule |
| `scripts/` | [scripts/AGENTS.md](./scripts/AGENTS.md) | Which subdirectory may run in `just ci`; shared `lib/` helpers |
| `talos/` | [talos/AGENTS.md](./talos/AGENTS.md) | `talconfig.yaml` → `clusterconfig/` generation; version matrix |
| `tests/` | [tests/AGENTS.md](./tests/AGENTS.md) | Test layer taxonomy; `catalog.yaml` registration |

The invariants above are the boundary and always apply; the scoped file tells you
how to satisfy them in that directory. `docs/`, `plans/`, and `.github/` have no
scoped file — they are covered here and by the engineering skills.

## Repository guidance

Engineering skills use tracked Markdown under `plans/` and the context in
`docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`, and
`docs/agents/domain.md`. See `README.md` for the human workflow and `docs/` for
runbooks.
Skills cannot override these safety, approval, or merge boundaries.
