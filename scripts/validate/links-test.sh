#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
validator="$repo_root/scripts/validate/links.sh"
fixture_root="$repo_root/tests/fixtures/links"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

# Every repository path named here is assembled from a variable. A literal dead
# path in this file would itself be reported by the bare-path scan.
missing_name='absent-runbook'
live_dir='docs/runbooks'
dollar='$'
interpolated="${dollar}base/README.md"

new_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init --quiet
}

markdown_repo="$temp_root/markdown"
new_repo "$markdown_repo"
cp "$fixture_root/dead-markdown.md.in" "$markdown_repo/source.md"
git -C "$markdown_repo" add source.md
if "$validator" "$markdown_repo" >"$temp_root/markdown.out" 2>&1; then
  echo 'Expected a missing Markdown target to fail.' >&2
  exit 1
fi
rg -q "source.md:1: missing Markdown link target 'missing-target.md'" \
  "$temp_root/markdown.out"

bare_repo="$temp_root/bare"
new_repo "$bare_repo"
bare_fixture="$(<"$fixture_root/dead-bare-path.txt.in")"
printf '%s\n' "${bare_fixture//@MISSING@/$missing_name}" >"$bare_repo/source.txt"
git -C "$bare_repo" add source.txt
if "$validator" "$bare_repo" >"$temp_root/bare.out" 2>&1; then
  echo 'Expected a missing bare path to fail.' >&2
  exit 1
fi
rg -q "source.txt:1: missing bare path target 'docs/$missing_name.md'" \
  "$temp_root/bare.out"

accept_repo="$temp_root/accept"
new_repo "$accept_repo"
mkdir -p "$accept_repo/$live_dir"
printf 'placeholder\n' >"$accept_repo/$live_dir/live.md"
printf 'See [dir](%s/), "%s", and %s/live.md.\n' \
  "$live_dir" "$interpolated" "$live_dir" >"$accept_repo/source.md"
git -C "$accept_repo" add -A
if ! "$validator" "$accept_repo" >"$temp_root/accept.out" 2>&1; then
  cat "$temp_root/accept.out" >&2
  echo 'Expected a directory target, an interpolated path, and a live path to pass.' >&2
  exit 1
fi

"$validator" "$repo_root"
echo 'Link validator tests passed.'
