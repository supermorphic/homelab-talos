<!-- FOR AI AGENTS - Human readability is a side effect, not a goal -->
<!-- Managed by agent: hand-maintained; keep sections and order, edit content -->
<!-- Last updated: 2026-07-31 -->

# Shell and helper scripts

Scope: `scripts/`. The root `AGENTS.md` safety, approval, and merge boundaries
still apply — this file adds the directory contract, not exceptions.

## Overview

The subdirectory a script lives in declares whether it may run in CI. This is the
single most important rule here:

| Directory | Needs a cluster? | In `just ci`? |
|-----------|------------------|---------------|
| `validate/` | No — reads repo sources only | **Yes** |
| `test/` | No — harness, catalog, and result plumbing | **Yes** |
| `repository/` | No, but needs GitHub API auth | No — `just repo` recipes only |
| `verify/` | Yes | Never |
| `diagnose/` | Yes | Never |
| `secrets/` | Yes, plus the age key | Never — operator-run |
| `lib/` | n/a — sourced helpers | n/a |

A `validate/` script that grows a cluster dependency has broken the PR gate for
everyone. Move it to `verify/` instead.

## Prerequisites

`scripts/test/run-ci.sh` is the CI coordinator: it reads `tests/catalog.yaml`,
runs each listed suite, and collects JUnit fragments under `.test-results/`. A new
check is not run by CI until it is registered in that catalog — writing the script
is only half the change. See `tests/AGENTS.md`.

## Commands

| Task | Command |
|------|---------|
| Full PR gate | `mise exec -- just ci` |
| Repo-wide lint (same hooks as pre-commit) | `mise exec -- just repo lint` |
| One validation script | `mise exec -- just kube <app>-validate` |

Invoke scripts through their `just` recipe, not directly — the recipes set the
guards and the pinned toolchain.

## Conventions

- `#!/usr/bin/env bash` and `set -euo pipefail`.
- `source scripts/lib/common.sh` and call `require_bash` before anything else;
  macOS ships bash 3.2 and these scripts assume bash 4+.
- `cd "$(git rev-parse --show-toplevel)"` before touching relative paths.
- Accept overrides via `${VAR:-default}` so CI can redirect paths (see
  `TEST_CATALOG_PATH`, `TEST_RESULTS_ROOT`, `TEST_JUST_BIN` in `test/run-ci.sh`).

## Patterns to Follow

Check `lib/` before writing a helper — there are five shared libraries against
twenty-plus consumers:

| Need | Use |
|------|-----|
| Bash version guard, empty-result assertions | `lib/common.sh` — `require_bash`, `assert_empty`, `assert_command_finds_nothing` |
| Confirm deployed source matches `origin/main` | `lib/rollout.sh` — `require_deployed_source` |
| Flux alert/metric queries | `lib/flux-alerts.sh` |
| Tailscale route status | `lib/tailscale-routes.sh` |
| Network probing | `lib/network.sh` |

`validate/cilium.sh` is a representative source-only validator;
`test/run-ci.sh` is the reference for catalog-driven suite execution.

## Security

- Never read, write, or echo the age private key. `secrets/` scripts are
  operator-run and stage material the agent must not handle.
- `check-sops-encrypted.sh` is the pre-commit guard that fails on a staged
  `*.sops.yaml` that is not encrypted. It reads the staged blob from the git
  index, not the working tree, so partial staging cannot slip plaintext through.
  Do not weaken or bypass it.
- Never print secret values, even in debug output — CI logs are retained.
- `repository/github_protection.py` checks and plans are read-only; applying a
  protection change requires explicit per-invocation authorization and the
  guarded `mise exec -- just repo github-protection-apply` recipe.

## Checklist

- [ ] Script is in the subdirectory matching its cluster dependency
- [ ] Sources `lib/common.sh` and calls `require_bash`
- [ ] Reachable through a `just` recipe, not only by path
- [ ] Registered in `tests/catalog.yaml` if it should gate PRs
- [ ] `mise exec -- just repo lint` and `mise exec -- just ci` pass

## Troubleshooting

- **Script passes locally, fails in CI** — usually an unpinned tool; run it under
  `mise exec --`.
- **`just ci` newly needs a kubeconfig** — a cluster-dependent check leaked into
  `validate/` or into the catalog's `ci` execution list.
- **Bash syntax errors only on macOS** — missing `require_bash`.
