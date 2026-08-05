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
  git -C "$path" config user.email 'test@example.invalid'
  git -C "$path" config user.name 'Test'
  git -C "$path" commit --quiet --allow-empty -m baseline
  git -C "$path" update-ref refs/remotes/origin/main HEAD
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

balanced_repo="$temp_root/balanced"
new_repo "$balanced_repo"
balanced_target='missing(target).md'
printf 'See [broken](%s).\n' "$balanced_target" >"$balanced_repo/source.md"
git -C "$balanced_repo" add source.md
if "$validator" "$balanced_repo" >"$temp_root/balanced.out" 2>&1; then
  echo 'Expected a missing balanced Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "source.md:1: missing Markdown link target '$balanced_target'" \
  "$temp_root/balanced.out"

escaped_repo="$temp_root/escaped"
new_repo "$escaped_repo"
escaped_target='missing\\(escaped\\).md'
printf 'See [escaped](%s).\n' "$escaped_target" >"$escaped_repo/source.md"
git -C "$escaped_repo" add source.md
if "$validator" "$escaped_repo" >"$temp_root/escaped.out" 2>&1; then
  echo 'Expected a missing escaped Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "source.md:1: missing Markdown link target '$escaped_target'" \
  "$temp_root/escaped.out"

title_repo="$temp_root/title"
new_repo "$title_repo"
title_target='file:/etc/passwd'
printf 'See [forbidden](%s (title)).\n' "$title_target" >"$title_repo/source.md"
git -C "$title_repo" add source.md
if "$validator" "$title_repo" >"$temp_root/title.out" 2>&1; then
  echo 'Expected a parenthesized title with a file target to fail.' >&2
  exit 1
fi
rg -F -q "source.md:1: forbidden Markdown link target '$title_target'" \
  "$temp_root/title.out"

escaped_fragment_repo="$temp_root/escaped-fragment"
new_repo "$escaped_fragment_repo"
escaped_fragment_target='target#name.md'
escaped_fragment_link='target\#name.md'
printf 'present\n' >"$escaped_fragment_repo/$escaped_fragment_target"
printf 'See [escaped](%s).\n' "$escaped_fragment_link" \
  >"$escaped_fragment_repo/source.md"
git -C "$escaped_fragment_repo" add -A
if ! "$validator" "$escaped_fragment_repo" >"$temp_root/escaped-fragment.out" 2>&1; then
  cat "$temp_root/escaped-fragment.out" >&2
  echo 'Expected an escaped fragment marker to resolve as a filename character.' >&2
  exit 1
fi

escaped_title_repo="$temp_root/escaped-title"
new_repo "$escaped_title_repo"
escaped_title_target='file:/etc/passwd'
printf 'See [forbidden](%s (title\\))).\n' "$escaped_title_target" \
  >"$escaped_title_repo/source.md"
git -C "$escaped_title_repo" add source.md
if "$validator" "$escaped_title_repo" >"$temp_root/escaped-title.out" 2>&1; then
  echo 'Expected a file target with an escaped title delimiter to fail.' >&2
  exit 1
fi
rg -F -q "source.md:1: forbidden Markdown link target '$escaped_title_target'" \
  "$temp_root/escaped-title.out"

outside_name='outside.md'
outside_path="$temp_root/$outside_name"
printf 'external\n' >"$outside_path"
up_dir='..'
markdown_traversal_target="$up_dir/$up_dir/$outside_name"
markdown_traversal_repo="$temp_root/markdown-parent/markdown-traversal"
new_repo "$markdown_traversal_repo"
printf 'See [outside](%s).\n' "$markdown_traversal_target" \
  >"$markdown_traversal_repo/source.md"
git -C "$markdown_traversal_repo" add source.md
if "$validator" "$markdown_traversal_repo" >"$temp_root/markdown-traversal.out" 2>&1; then
  echo 'Expected an existing external Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "source.md:1: non-local Markdown link target '$markdown_traversal_target'" \
  "$temp_root/markdown-traversal.out"

bare_traversal_repo="$temp_root/bare-traversal"
new_repo "$bare_traversal_repo"
traversal_docs_dir='docs'
bare_traversal_target="$traversal_docs_dir/$up_dir/$up_dir/$outside_name"
mkdir -p "$bare_traversal_repo/$traversal_docs_dir"
printf 'See %s.\n' "$bare_traversal_target" >"$bare_traversal_repo/source.txt"
git -C "$bare_traversal_repo" add source.txt
if "$validator" "$bare_traversal_repo" >"$temp_root/bare-traversal.out" 2>&1; then
  echo 'Expected an existing external bare path target to fail.' >&2
  exit 1
fi
rg -F -q "source.txt:1: non-local bare path target '$bare_traversal_target'" \
  "$temp_root/bare-traversal.out"

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

decision_repo="$temp_root/decision"
new_repo "$decision_repo"
decision_dir='docs/decisions'
decision_name='2026-08-02-example.md'
mkdir -p "$decision_repo/$decision_dir"
printf '# Decision\n\n- **Status: Accepted.**\n\n[missing](missing.md)\n' \
  >"$decision_repo/$decision_dir/$decision_name"
git -C "$decision_repo" add -A
git -C "$decision_repo" commit --quiet -m 'add accepted decision'
git -C "$decision_repo" update-ref refs/remotes/origin/main HEAD
if ! "$validator" "$decision_repo" >"$temp_root/decision-frozen.out" 2>&1; then
  cat "$temp_root/decision-frozen.out" >&2
  echo 'Expected an unchanged Accepted decision to remain outside link validation.' >&2
  exit 1
fi
printf '\nChanged body.\n' >>"$decision_repo/$decision_dir/$decision_name"
git -C "$decision_repo" add "$decision_dir/$decision_name"
git -C "$decision_repo" commit --quiet -m 'revise decision'
if "$validator" "$decision_repo" >"$temp_root/decision-changed.out" 2>&1; then
  echo 'Expected a changed decision body to be link-validated.' >&2
  exit 1
fi
rg -F -q "$decision_dir/$decision_name:5: missing Markdown link target 'missing.md'" \
  "$temp_root/decision-changed.out"

decision_bare_repo="$temp_root/decision-bare"
new_repo "$decision_bare_repo"
decision_bare_name='2026-08-02-bare-example.md'
mkdir -p "$decision_bare_repo/$decision_dir"
printf '# Decision\n\n- **Status: Accepted.**\n\nSee docs/missing-runbook.md.\n' \
  >"$decision_bare_repo/$decision_dir/$decision_bare_name"
git -C "$decision_bare_repo" add -A
git -C "$decision_bare_repo" commit --quiet -m 'add accepted decision'
git -C "$decision_bare_repo" update-ref refs/remotes/origin/main HEAD
if ! "$validator" "$decision_bare_repo" >"$temp_root/decision-bare-frozen.out" 2>&1; then
  cat "$temp_root/decision-bare-frozen.out" >&2
  echo 'Expected an unchanged Accepted decision to remain outside bare-path validation.' >&2
  exit 1
fi
printf '\nChanged body.\n' >>"$decision_bare_repo/$decision_dir/$decision_bare_name"
git -C "$decision_bare_repo" add "$decision_dir/$decision_bare_name"
git -C "$decision_bare_repo" commit --quiet -m 'revise decision'
if "$validator" "$decision_bare_repo" >"$temp_root/decision-bare-changed.out" 2>&1; then
  echo 'Expected a changed decision bare path to be link-validated.' >&2
  exit 1
fi
rg -F -q "$decision_dir/$decision_bare_name:5: missing bare path target 'docs/missing-runbook.md'" \
  "$temp_root/decision-bare-changed.out"

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
