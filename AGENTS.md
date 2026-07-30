# Agent Instructions

Canonical, vendor-neutral operating rules for AI agents and contributors working in
this repository. (Claude Code loads `CLAUDE.md`, which imports this file.)

## Repository purpose

`homelab-talos` manages a three-node Talos Linux + Flux GitOps Kubernetes cluster.
**Git is the source of truth and `main` is the Flux production deployment
boundary** — Flux continuously reconciles `main` onto the live cluster.

## Agent skills

Engineering skills use tracked local Markdown under `plans/` and discover domain
context from current repository sources. See `docs/agents/issue-tracker.md`,
`docs/agents/triage-labels.md`, and `docs/agents/domain.md`.

These skills cannot override the safety, validation, approval, or merge rules in
this file.

## Required workflow

- **Never commit or push directly to `main`.** Create a branch (`feat/…`, `fix/…`),
  make the change, and open a pull request.
- Before opening or updating a PR, **`just ci` must pass locally** — the single
  cluster-independent, secret-free validation contract.
- Open PRs with `gh pr create`. PRs are **squash-merged** after the `ci` status check
  is green, and Flux then reconciles the merged `main` commit.
- **Merging is the human operator's job, not the agent's.** An agent must **never**
  merge a pull request — no `gh pr merge`, no merge via the GitHub UI/API, no
  auto-merge — even when `ci` is green and the change looks ready. The agent's
  responsibility ends at opening or updating the PR; the operator reviews and merges.
  An agent merging a PR is a **workflow violation**. The **only** exception is an
  explicit, per-merge instruction from the operator to merge that specific PR as a
  deliberate override; a general prior authorization, a stale approval, or the
  agent's own inference does **not** count.
- Direct commits to `main` or rule bypasses are for **emergency recovery only** and
  must be followed by `just ci` on `main`.
- Keep commits scoped and reviewable. Report which validation ran versus was
  skipped, and why.

## Interface: `mise` + `just`

- Run every tool through the pinned toolchain: `mise exec -- just …`. Do not use
  unpinned or system tools.
- **All cluster mutations and health checks are guarded `just` recipes — never run
  raw `kubectl`, `talosctl`, `helm`, or `flux` against the live cluster.** If a
  needed operation has no recipe, add a guarded recipe rather than an ad-hoc command.
- Cluster-mutating `bootstrap …` recipes require an explicit `*_CONFIRM` value and
  are **operator-run**. Agents stage the source, validate, commit, and hand off the
  rollout — they do not run live rollouts.
- An operator may run a guarded rollout from any clean checkout after
  `git fetch origin main`; a local `main` branch is not required. The recipe must
  verify that its guard implementation and rollout-specific source paths match the
  current remote `origin/main` commit. This permits unrelated committed feature
  work without allowing feature-branch manifests to become the deployment source.

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
