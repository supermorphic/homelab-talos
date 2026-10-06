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
docs_dir='docs'
missing_bare_name='missing-runbook'
missing_bare_target="$docs_dir/$missing_bare_name.md"
live_dir='docs/specs'
dollar='$'
interpolated="${dollar}base/README.md"
specs_dir="$docs_dir/specs"
planned_spec_name='001-example.md'
planned_spec_path="$specs_dir/$planned_spec_name"

new_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init --quiet
  git -C "$path" config user.email 'test@example.invalid'
  git -C "$path" config user.name 'Test'
  git -C "$path" commit --quiet --allow-empty -m baseline
  git -C "$path" update-ref refs/remotes/origin/main HEAD
}

toolchain_repo="$temp_root/toolchain"
new_repo "$toolchain_repo"
printf 'tracked\n' >"$toolchain_repo/README.md"
git -C "$toolchain_repo" add README.md

toolchain_bin="$temp_root/toolchain-bin"
mkdir -p "$toolchain_bin"
for tool in bash basename cat dirname git mise mktemp readlink rg rm; do
  ln -s "$(command -v "$tool")" "$toolchain_bin/$tool"
done

if ! PATH="$toolchain_bin" "$validator" "$toolchain_repo" \
  >"$temp_root/toolchain.out" 2>&1; then
  cat "$temp_root/toolchain.out" >&2
  echo 'Expected the validator to resolve pinned tools from its repository root.' >&2
  exit 1
fi

planned_spec_repo="$temp_root/planned-spec"
new_repo "$planned_spec_repo"
mkdir -p "$planned_spec_repo/$specs_dir"
printf '# Example\n\nImplement %s.\n' "$missing_bare_target" \
  >"$planned_spec_repo/$planned_spec_path"
git -C "$planned_spec_repo" add -A
if ! "$validator" "$planned_spec_repo" >"$temp_root/planned-spec.out" 2>&1; then
  cat "$temp_root/planned-spec.out" >&2
  echo 'Expected a planned spec bare path to be ignored.' >&2
  exit 1
fi

spec_link_repo="$temp_root/spec-link"
new_repo "$spec_link_repo"
mkdir -p "$spec_link_repo/$specs_dir"
printf '# Example\n\n[missing](missing.md)\n' \
  >"$spec_link_repo/$planned_spec_path"
git -C "$spec_link_repo" add -A
if "$validator" "$spec_link_repo" >"$temp_root/spec-link.out" 2>&1; then
  echo 'Expected a broken Markdown link in a spec to fail.' >&2
  exit 1
fi
rg -q "$planned_spec_path:3: missing Markdown link target 'missing.md'" \
  "$temp_root/spec-link.out"

no_origin_repo="$temp_root/no-origin"
new_repo "$no_origin_repo"
printf 'tracked\n' >"$no_origin_repo/README.md"
git -C "$no_origin_repo" add README.md
git -C "$no_origin_repo" update-ref -d refs/remotes/origin/main
if ! "$validator" "$no_origin_repo" >"$temp_root/no-origin.out" 2>&1; then
  cat "$temp_root/no-origin.out" >&2
  echo 'Expected validation to work without origin/main.' >&2
  exit 1
fi

markdown_repo="$temp_root/markdown"
new_repo "$markdown_repo"
cp "$fixture_root/dead-markdown.md.in" "$markdown_repo/README.md"
git -C "$markdown_repo" add README.md
if "$validator" "$markdown_repo" >"$temp_root/markdown.out" 2>&1; then
  echo 'Expected a missing Markdown target to fail.' >&2
  exit 1
fi
rg -q "README.md:1: missing Markdown link target 'missing-target.md'" \
  "$temp_root/markdown.out"

bare_repo="$temp_root/bare"
new_repo "$bare_repo"
bare_fixture="$(<"$fixture_root/dead-bare-path.txt.in")"
printf '%s\n' "${bare_fixture//@MISSING@/$missing_name}" >"$bare_repo/source.sh"
git -C "$bare_repo" add source.sh
if "$validator" "$bare_repo" >"$temp_root/bare.out" 2>&1; then
  echo 'Expected a missing bare path to fail.' >&2
  exit 1
fi
rg -q "source.sh:1: missing bare path target 'docs/$missing_name.md'" \
  "$temp_root/bare.out"

angle_repo="$temp_root/angle"
new_repo "$angle_repo"
angle_target='docs/(missing) runbook.md'
printf 'See [missing](<%s>).\n' "$angle_target" >"$angle_repo/README.md"
git -C "$angle_repo" add README.md
if "$validator" "$angle_repo" >"$temp_root/angle.out" 2>&1; then
  echo 'Expected a missing angle-bracket Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "README.md:1: missing Markdown link target '$angle_target'" \
  "$temp_root/angle.out"

absolute_repo="$temp_root/absolute"
new_repo "$absolute_repo"
absolute_target='/tmp/missing file'
printf 'See [absolute](<%s>).\n' "$absolute_target" >"$absolute_repo/README.md"
git -C "$absolute_repo" add README.md
if "$validator" "$absolute_repo" >"$temp_root/absolute.out" 2>&1; then
  echo 'Expected an absolute Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "README.md:1: forbidden Markdown link target '$absolute_target'" \
  "$temp_root/absolute.out"

file_repo="$temp_root/file"
new_repo "$file_repo"
file_target='file:/tmp/missing-file'
printf 'See [file](%s).\n' "$file_target" >"$file_repo/README.md"
git -C "$file_repo" add README.md
if "$validator" "$file_repo" >"$temp_root/file.out" 2>&1; then
  echo 'Expected a file Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "README.md:1: forbidden Markdown link target '$file_target'" \
  "$temp_root/file.out"

balanced_repo="$temp_root/balanced"
new_repo "$balanced_repo"
balanced_target='missing(target).md'
printf 'See [broken](%s).\n' "$balanced_target" >"$balanced_repo/README.md"
git -C "$balanced_repo" add README.md
if "$validator" "$balanced_repo" >"$temp_root/balanced.out" 2>&1; then
  echo 'Expected a missing balanced Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "README.md:1: missing Markdown link target '$balanced_target'" \
  "$temp_root/balanced.out"

escaped_repo="$temp_root/escaped"
new_repo "$escaped_repo"
escaped_target='missing\\(escaped\\).md'
printf 'See [escaped](%s).\n' "$escaped_target" >"$escaped_repo/README.md"
git -C "$escaped_repo" add README.md
if "$validator" "$escaped_repo" >"$temp_root/escaped.out" 2>&1; then
  echo 'Expected a missing escaped Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "README.md:1: missing Markdown link target '$escaped_target'" \
  "$temp_root/escaped.out"

title_repo="$temp_root/title"
new_repo "$title_repo"
title_target='file:/etc/passwd'
printf 'See [forbidden](%s (title)).\n' "$title_target" >"$title_repo/README.md"
git -C "$title_repo" add README.md
if "$validator" "$title_repo" >"$temp_root/title.out" 2>&1; then
  echo 'Expected a parenthesized title with a file target to fail.' >&2
  exit 1
fi
rg -F -q "README.md:1: forbidden Markdown link target '$title_target'" \
  "$temp_root/title.out"

escaped_fragment_repo="$temp_root/escaped-fragment"
new_repo "$escaped_fragment_repo"
escaped_fragment_target='target#name.svg'
escaped_fragment_link='target\#name.svg'
printf 'present\n' >"$escaped_fragment_repo/$escaped_fragment_target"
printf 'See [escaped](%s).\n' "$escaped_fragment_link" \
  >"$escaped_fragment_repo/README.md"
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
  >"$escaped_title_repo/README.md"
git -C "$escaped_title_repo" add README.md
if "$validator" "$escaped_title_repo" >"$temp_root/escaped-title.out" 2>&1; then
  echo 'Expected a file target with an escaped title delimiter to fail.' >&2
  exit 1
fi
rg -F -q "README.md:1: forbidden Markdown link target '$escaped_title_target'" \
  "$temp_root/escaped-title.out"

outside_name='outside.md'
outside_path="$temp_root/$outside_name"
printf 'external\n' >"$outside_path"
up_dir='..'
markdown_traversal_target="$up_dir/$up_dir/$outside_name"
markdown_traversal_repo="$temp_root/markdown-parent/markdown-traversal"
new_repo "$markdown_traversal_repo"
printf 'See [outside](%s).\n' "$markdown_traversal_target" \
  >"$markdown_traversal_repo/README.md"
git -C "$markdown_traversal_repo" add README.md
if "$validator" "$markdown_traversal_repo" >"$temp_root/markdown-traversal.out" 2>&1; then
  echo 'Expected an existing external Markdown target to fail.' >&2
  exit 1
fi
rg -F -q "README.md:1: non-local Markdown link target '$markdown_traversal_target'" \
  "$temp_root/markdown-traversal.out"

bare_traversal_repo="$temp_root/bare-traversal"
new_repo "$bare_traversal_repo"
traversal_docs_dir='docs'
bare_traversal_target="$traversal_docs_dir/$up_dir/$up_dir/$outside_name"
mkdir -p "$bare_traversal_repo/$traversal_docs_dir"
printf 'See %s.\n' "$bare_traversal_target" >"$bare_traversal_repo/source.sh"
git -C "$bare_traversal_repo" add source.sh
if "$validator" "$bare_traversal_repo" >"$temp_root/bare-traversal.out" 2>&1; then
  echo 'Expected an existing external bare path target to fail.' >&2
  exit 1
fi
rg -F -q "source.sh:1: non-local bare path target '$bare_traversal_target'" \
  "$temp_root/bare-traversal.out"

untracked_repo="$temp_root/untracked"
new_repo "$untracked_repo"
printf 'tracked\n' >"$untracked_repo/AGENTS.md"
untracked_target='missing-unAGENTS.md'
printf 'See [broken](%s).\n' "$untracked_target" >"$untracked_repo/README.md"
git -C "$untracked_repo" add AGENTS.md
if ! "$validator" "$untracked_repo" >"$temp_root/untracked.out" 2>&1; then
  cat "$temp_root/untracked.out" >&2
  echo 'Expected an untracked broken Markdown target to be ignored.' >&2
  exit 1
fi

deleted_repo="$temp_root/deleted"
new_repo "$deleted_repo"
printf 'tracked\n' >"$deleted_repo/README.md"
git -C "$deleted_repo" add README.md
rm "$deleted_repo/README.md"
if ! "$validator" "$deleted_repo" >"$temp_root/deleted.out" 2>&1; then
  cat "$temp_root/deleted.out" >&2
  echo 'Expected a deleted tracked file to be ignored.' >&2
  exit 1
fi

neighbor_repo="$temp_root/neighbor"
new_repo "$neighbor_repo"
neighbor_dir='neighbor'
neighbor_target='missing-neighbor.md'
mkdir -p "$neighbor_repo/$docs_dir/$neighbor_dir"
printf 'See [neighbor](%s).\n' "$neighbor_target" \
  >"$neighbor_repo/$docs_dir/$neighbor_dir/README.md"
git -C "$neighbor_repo" add -A
if "$validator" "$neighbor_repo" >"$temp_root/neighbor.out" 2>&1; then
  echo 'Expected a neighboring tracked subtree to remain scanned.' >&2
  exit 1
fi
rg -F -q "docs/$neighbor_dir/README.md:1: missing Markdown link target '$neighbor_target'" \
  "$temp_root/neighbor.out"

boundary_repo="$temp_root/boundary"
new_repo "$boundary_repo"
boundary_docs_name='example.md.in'
boundary_child_dir='child'
boundary_readme_name='README.md.old'
printf 'See %s/%s and %s/%s.\n' \
  "$docs_dir" "$boundary_docs_name" "$boundary_child_dir" "$boundary_readme_name" \
  >"$boundary_repo/source.sh"
git -C "$boundary_repo" add source.sh
if ! "$validator" "$boundary_repo" >"$temp_root/boundary.out" 2>&1; then
  cat "$temp_root/boundary.out" >&2
  echo 'Expected bare-path suffixes to be ignored.' >&2
  exit 1
fi

scanner_repo="$temp_root/scanner"
new_repo "$scanner_repo"
printf 'tracked\n' >"$scanner_repo/README.md"
git -C "$scanner_repo" add README.md
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
printf 'placeholder\n' >"$accept_repo/$live_dir/001-live.md"
printf 'See [dir](%s/), "%s", and %s/001-live.md.\n' \
  "$live_dir" "$interpolated" "$live_dir" >"$accept_repo/README.md"
git -C "$accept_repo" add -A
if ! "$validator" "$accept_repo" >"$temp_root/accept.out" 2>&1; then
  cat "$temp_root/accept.out" >&2
  echo 'Expected a directory target, an interpolated path, and a live path to pass.' >&2
  exit 1
fi

# Documentation placement is a path contract; contents remain unconstrained.
allowed_repo="$temp_root/allowed-documents"
new_repo "$allowed_repo"
for allowed in README.md AGENTS.md CLAUDE.md \
  ${planned_spec_path} \
  kubernetes/apps/monitoring/homepage/app/icons/NOTICE.md \
  scripts/test/core/fixtures/PROVENANCE.md \
  tests/fixtures/links/dead-markdown.md.in \
  tests/fixtures/links/dead-bare-path.txt.in \
  tests/fixtures/new-case.md tests/fixtures/new-case.txt \
  tests/fixtures/new-suite/nested/input.md \
  tests/fixtures/new-suite/nested/input.txt.in \
  tests/fixtures/news/article.html tests/fixtures/news/restricted.html; do
  mkdir -p "$allowed_repo/$(dirname "$allowed")"
  printf 'arbitrary content\n' >"$allowed_repo/$allowed"
done
git -C "$allowed_repo" add -A
"$validator" "$allowed_repo" >"$temp_root/allowed-documents.out" 2>&1 || {
  cat "$temp_root/allowed-documents.out" >&2
  exit 1
}

for rejected in ${docs_dir}/README.md ${docs_dir}/guides/example.md ${neighbor_dir}/README.md \
  ${neighbor_dir}/AGENTS.md notes.MD notes.mdx notes.markdown notes.rst notes.adoc \
  notes.asciidoc notes.txt notes.text notes.html notes.htm notes.org \
  ${specs_dir}/archive/001-example.md ${specs_dir}/README.md \
  tests/guide.md tests/fixtures/guide.rst tests/fixtures/guide.html \
  tests/fixtures/news/guide.html \
  src/tests/fixtures/example.md \
  scripts/test/core/fixtures/guide.md \
  kubernetes/apps/monitoring/homepage/app/icons/guide.md; do
  rejected_repo="$temp_root/rejected-documents"
  mkdir -p "$rejected_repo"
  new_repo "$rejected_repo"
  mkdir -p "$rejected_repo/$(dirname "$rejected")"
  printf 'arbitrary content\n' >"$rejected_repo/$rejected"
  git -C "$rejected_repo" add -A
  if "$validator" "$rejected_repo" >"$temp_root/rejected-documents.out" 2>&1; then
    echo "Expected unsanctioned documentation path to fail: $rejected" >&2
    exit 1
  fi
  rg -Fq "unsanctioned documentation path '$rejected'" "$temp_root/rejected-documents.out"
  rm -rf "$rejected_repo"
done

echo 'Focused link validator fixture cases passed.'
"$validator" "$repo_root"
echo 'Link validator tests passed.'
