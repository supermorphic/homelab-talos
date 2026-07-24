#!/usr/bin/env bash

# Allow an operator to run a guarded rollout from any clean branch/worktree while
# proving that the guard and rollout-specific sources are already published on
# origin/main. Callers still reconcile and verify the live Flux artifact afterward.
# This is an operational drift check for trusted local code, not tamper-resistant
# attestation; PR review and branch protection remain the source-integrity boundary.
require_deployed_source() {
  [[ "$#" -ge 2 ]] || {
    echo 'Refusing cluster rollout: expected a label and at least one source path.' >&2
    return 1
  }

  local label="$1"
  shift

  [[ -z "$(git status --porcelain)" ]] || {
    echo "Refusing $label: commit or stash all worktree changes first." >&2
    return 1
  }

  local remote_head remote_ref
  if ! remote_ref="$(git ls-remote --exit-code origin refs/heads/main 2>/dev/null)"; then
    echo "Refusing $label: unable to query origin/main." >&2
    echo 'Check network access and confirm the remote main branch exists, then retry.' >&2
    return 1
  fi
  read -r remote_head _ <<<"$remote_ref"
  [[ -n "$remote_head" ]] || {
    echo "Refusing $label: origin/main returned no commit." >&2
    return 1
  }

  git cat-file -e "${remote_head}^{commit}" 2>/dev/null || {
    echo "Refusing $label: origin/main at $remote_head is not available locally." >&2
    echo "Run 'git fetch origin main' and retry from this worktree." >&2
    return 1
  }

  local -a guard_paths=(scripts/lib/rollout.sh "$@")
  if ! git diff --quiet "$remote_head" -- "${guard_paths[@]}"; then
    echo "Refusing $label: the rollout source below differs from deployed origin/main at $remote_head:" >&2
    git diff --name-only "$remote_head" -- "${guard_paths[@]}" >&2
    echo "Merge those paths to main, then run 'git fetch origin main' and retry from any clean branch/worktree." >&2
    return 1
  fi
}
