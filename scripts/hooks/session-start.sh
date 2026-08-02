#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
git_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
branch="$(git branch --show-current)"
main_clone_root="$(dirname "$git_common_dir")"

if [[ -z "$branch" ]]; then
  branch='detached HEAD'
fi

if [[ "$repo_root" == "$main_clone_root" ]]; then
  location='main clone'
  credentials='admin credentials in effect'
else
  location='worktree'
  kubeconfig="$repo_root/.kube/config"
  credentials='no cluster credentials'

  if [[ -f "$kubeconfig" ]]; then
    if context_names="$(yq -r '.contexts[]?.name // ""' "$kubeconfig" 2>/dev/null)"; then
      credential_labels=()

      if printf '%s\n' "$context_names" | rg -qx 'homelab-observer'; then
        credential_labels+=('observer credentials')
      fi
      if printf '%s\n' "$context_names" | rg -qx 'homelab-diagnostic'; then
        credential_labels+=('diagnostic credentials')
      fi

      if [[ "${#credential_labels[@]}" -gt 0 ]]; then
        credentials="${credential_labels[0]}"
        for credential_label in "${credential_labels[@]:1}"; do
          credentials+=" · $credential_label"
        done
      else
        credentials='cluster credentials with unrecognized contexts'
      fi
    else
      credentials='cluster credentials with unreadable contexts'
    fi
  fi
fi

printf '%s · branch %s · %s\n' "$location" "$branch" "$credentials"

if [[ "$location" == 'main clone' && "$branch" == 'main' ]]; then
  echo 'WARNING: repository work belongs on a feature branch in a worktree.' >&2
fi

if [[ -v SOPS_AGE_KEY || -v SOPS_AGE_KEY_FILE ]]; then
  echo 'WARNING: SOPS key material is present in the session environment.' >&2
fi
