#!/usr/bin/env bash
# Prove that a scoped-local campaign is running from a linked worktree with only scoped credentials.
set -euo pipefail

[[ "$#" -eq 3 ]] || {
  echo 'Usage: scoped-campaign-preflight.sh <repo-root> <kubeconfig> <talosconfig>' >&2
  exit 2
}

repo_root="$1"
kubeconfig="$2"
talosconfig="$3"

fail() {
  echo "Scoped campaign preflight failed: $*" >&2
  exit 1
}

top_level="$(git -C "$repo_root" rev-parse --show-toplevel)" ||
  fail 'repository root is not a Git checkout.'
[[ "$top_level" == "$repo_root" ]] ||
  fail 'repository root does not match the current Git checkout.'
git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-dir)" ||
  fail 'cannot resolve the Git directory.'
common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)" ||
  fail 'cannot resolve the Git common directory.'
[[ "$git_dir" != "$common_dir" && "$git_dir" == "$common_dir"/worktrees/* ]] ||
  fail 'scoped campaigns require a linked Git worktree, not the main clone.'

[[ "$kubeconfig" == "$repo_root/.kube/config" ]] ||
  fail 'Kubernetes credential must use the worktree .kube/config path.'
[[ "$talosconfig" == "$repo_root/.talos/config" ]] ||
  fail 'Talos credential must use the worktree .talos/config path.'

credential_mode() {
  local path="$1"
  local mode
  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)" ||
    return 1
  [[ "$mode" =~ ^0?[0-7]{3}$ ]] || return 1
  printf '%s\n' "${mode#0}"
}

for credential in "$kubeconfig" "$talosconfig"; do
  [[ -f "$credential" ]] || fail "missing scoped credential: $credential."
  [[ "$(credential_mode "$credential")" == '600' ]] ||
    fail "scoped credential must have mode 0600: $credential."
done

uv run --locked --no-dev python -m scripts.openbao.credentials validate "$kubeconfig" ||
  fail 'expected a canonical scoped Kubernetes credential; run just kube kubeconfig.'

kube_view="$(
  kubectl --kubeconfig "$kubeconfig" config view --raw --output json
)" || fail 'cannot inspect the scoped Kubernetes credential.'
[[ "$(yq -r '."current-context" // ""' - <<<"$kube_view")" == \
  'homelab-observer' ]] ||
  fail 'Kubernetes current context must be homelab-observer.'
talos_info="$(
  talosctl config info --talosconfig "$talosconfig" --output json
)" || fail 'cannot inspect the scoped Talos credential.'
[[ "$(yq -r '[(.roles // .Roles // .certificate.roles // .identity.roles // [])[]] |
  sort | join(",")' - <<<"$talos_info")" == 'os:reader' ]] ||
  fail 'Talos credential must have exactly the os:reader role.'

echo 'Scoped campaign credential and worktree preflight passed.'
