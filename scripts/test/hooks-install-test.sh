#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
repository_justfile="$repo_root/.just/repository.just"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/hooks-install-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

main_clone="$fixture/main-clone"
linked_worktree="$fixture/linked-worktree"

git init --quiet --initial-branch main "$main_clone"
git -C "$main_clone" config user.email 'hooks-install-test@example.invalid'
git -C "$main_clone" config user.name 'hooks-install-test'
printf '%s\n' 'repos: []' >"$main_clone/.pre-commit-config.yaml"
git -C "$main_clone" add .pre-commit-config.yaml
git -C "$main_clone" commit --quiet -m 'test fixture'
git -C "$main_clone" worktree add --quiet -b linked "$linked_worktree"

install_hooks() {
  local location="$1"
  local git_dir

  git_dir="$(git -C "$location" rev-parse --git-dir)"
  GIT_DIR="$git_dir" GIT_WORK_TREE="$location" \
    mise exec -- just --justfile "$repository_justfile" hooks
}

common_dir="$(git -C "$main_clone" rev-parse --path-format=absolute --git-common-dir)"
expected_hooks_dir="$common_dir/hooks"
expected_hook="$common_dir/hooks/pre-commit"

assert_shared_hook_path() {
  local location="$1"
  local actual_hook

  actual_hook="$(git -C "$location" rev-parse --path-format=absolute \
    --git-path hooks/pre-commit)"
  [[ "$actual_hook" == "$expected_hook" ]] || {
    echo "Expected $location to resolve $expected_hook, got $actual_hook" >&2
    exit 1
  }
}

install_hooks "$main_clone"
install_hooks "$linked_worktree"

[[ "$(git -C "$main_clone" config --get core.hooksPath)" == "$expected_hooks_dir" ]] || {
  echo "Expected core.hooksPath to be $expected_hooks_dir" >&2
  exit 1
}
assert_shared_hook_path "$main_clone"
assert_shared_hook_path "$linked_worktree"
[[ -f "$expected_hook" && -x "$expected_hook" ]] || {
  echo "Expected executable hook at $expected_hook" >&2
  exit 1
}

install_hooks "$linked_worktree"
[[ "$(find "$common_dir/hooks" -maxdepth 1 -type f -name pre-commit | wc -l | tr -d ' ')" == '1' ]] || {
  echo 'Expected exactly one shared pre-commit hook after a second installation.' >&2
  exit 1
}
git -C "$linked_worktree" commit --allow-empty --quiet -m 'verify shared hook'

echo 'Shared pre-commit hook installation test passed.'
