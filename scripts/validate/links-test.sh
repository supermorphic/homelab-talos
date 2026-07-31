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

angle_repo="$temp_root/angle"
new_repo "$angle_repo"
angle_target='docs/(missing) runbook.md'
printf 'See [missing](<%s>).\n' "$angle_target" >"$angle_repo/source.md"
git -C "$angle_repo" add source.md
if "$validator" "$angle_repo" >"$temp_root/angle.out" 2>&1; then
  echo 'Expected a missing angle-bracket Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "source.md:1: missing Markdown link target '$angle_target'" \
  "$temp_root/angle.out"

absolute_repo="$temp_root/absolute"
new_repo "$absolute_repo"
absolute_target='/tmp/missing file'
printf 'See [absolute](<%s>).\n' "$absolute_target" >"$absolute_repo/source.md"
git -C "$absolute_repo" add source.md
if "$validator" "$absolute_repo" >"$temp_root/absolute.out" 2>&1; then
  echo 'Expected an absolute Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "source.md:1: forbidden Markdown link target '$absolute_target'" \
  "$temp_root/absolute.out"

file_repo="$temp_root/file"
new_repo "$file_repo"
file_target='file:/tmp/missing-file'
printf 'See [file](%s).\n' "$file_target" >"$file_repo/source.md"
git -C "$file_repo" add source.md
if "$validator" "$file_repo" >"$temp_root/file.out" 2>&1; then
  echo 'Expected a file Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "source.md:1: forbidden Markdown link target '$file_target'" \
  "$temp_root/file.out"

untracked_repo="$temp_root/untracked"
new_repo "$untracked_repo"
printf 'tracked\n' >"$untracked_repo/tracked.md"
untracked_target='missing-untracked.md'
printf 'See [broken](%s).\n' "$untracked_target" >"$untracked_repo/source.md"
git -C "$untracked_repo" add tracked.md
if ! "$validator" "$untracked_repo" >"$temp_root/untracked.out" 2>&1; then
  cat "$temp_root/untracked.out" >&2
  echo 'Expected an untracked broken Markdown target to be ignored.' >&2
  exit 1
fi

excluded_repo="$temp_root/excluded"
new_repo "$excluded_repo"
docs_dir='docs'
superpowers_dir='superpowers'
excluded_target='missing-excluded.md'
mkdir -p "$excluded_repo/$docs_dir/$superpowers_dir"
printf 'See [excluded](%s).\n' "$excluded_target" \
  >"$excluded_repo/$docs_dir/$superpowers_dir/source.md"
git -C "$excluded_repo" add -A
if ! "$validator" "$excluded_repo" >"$temp_root/excluded.out" 2>&1; then
  cat "$temp_root/excluded.out" >&2
  echo 'Expected docs/superpowers to be excluded.' >&2
  exit 1
fi

neighbor_repo="$temp_root/neighbor"
new_repo "$neighbor_repo"
neighbor_dir='neighbor'
neighbor_target='missing-neighbor.md'
mkdir -p "$neighbor_repo/$docs_dir/$neighbor_dir"
printf 'See [neighbor](%s).\n' "$neighbor_target" \
  >"$neighbor_repo/$docs_dir/$neighbor_dir/source.md"
git -C "$neighbor_repo" add -A
if "$validator" "$neighbor_repo" >"$temp_root/neighbor.out" 2>&1; then
  echo 'Expected a neighboring tracked subtree to remain scanned.' >&2
  exit 1
fi
rg -F -q "docs/$neighbor_dir/source.md:1: missing Markdown link target '$neighbor_target'" \
  "$temp_root/neighbor.out"

boundary_repo="$temp_root/boundary"
new_repo "$boundary_repo"
boundary_docs_name='example.md.in'
boundary_child_dir='child'
boundary_readme_name='README.md.old'
printf 'See %s/%s and %s/%s.\n' \
  "$docs_dir" "$boundary_docs_name" "$boundary_child_dir" "$boundary_readme_name" \
  >"$boundary_repo/source.txt"
git -C "$boundary_repo" add source.txt
if ! "$validator" "$boundary_repo" >"$temp_root/boundary.out" 2>&1; then
  cat "$temp_root/boundary.out" >&2
  echo 'Expected bare-path suffixes to be ignored.' >&2
  exit 1
fi

scanner_repo="$temp_root/scanner"
new_repo "$scanner_repo"
printf 'tracked\n' >"$scanner_repo/source.md"
git -C "$scanner_repo" add source.md
scanner_bin="$temp_root/scanner-bin"
mkdir -p "$scanner_bin"
printf '#!/usr/bin/env bash\nexit 2\n' >"$scanner_bin/rg"
chmod +x "$scanner_bin/rg"
if PATH="$scanner_bin:$PATH" "$validator" "$scanner_repo" >"$temp_root/scanner.out" 2>&1; then
  echo 'Expected a scanner failure to fail the validator.' >&2
  exit 1
fi

non_git_root="$temp_root/not-git"
mkdir -p "$non_git_root"
if "$validator" "$non_git_root" >"$temp_root/not-git.out" 2>&1; then
  echo 'Expected a non-Git root to fail the validator.' >&2
  exit 1
fi

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
