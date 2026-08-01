# Agent Instruction Information Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every repository rule and procedure one clear owner, introduce scoped agent instructions and a live-versus-history documentation split, and make every repository-local documentation reference mechanically verifiable.

**Architecture:** Land the change as four ordered pull requests. First add a tracked-reference validator so later moves are provable; then establish the root/nested instruction hierarchy and extract Talos procedures; then move the existing documentation and repair every reference; finally remove duplicated agent policy from the human-facing root README. Each pull request starts from the `origin/main` that contains its predecessor and leaves the repository coherent on its own.

**Tech Stack:** Markdown, Bash 5+, ripgrep (`rg`), Git, Just, mise, ShellCheck, YAML test catalog

## Global Constraints

- The approved design is `docs/superpowers/specs/2026-07-31-agents-md-information-architecture-design.md`; it is descriptive and never overrides a repository instruction.
- Deliver exactly four ordered pull requests: link validator and superseded-plan removal; constitution and nested layer; documentation split; root README de-duplication.
- Do not start a later task until the preceding pull request is merged and the assigned branch is based on the resulting `origin/main`.
- Never merge or enable auto-merge. The operator reviews and merges each pull request and owns every rollout.
- Run repository workflows through `mise exec -- just ...` and pinned ad hoc tools through `mise exec -- <tool> ...`.
- Do not run live cluster commands. This work is documentation and cluster-independent validation only.
- Do not add `.agents/`, `.claude/`, or `.codex/` content.
- Do not change classification, review gates, model routing, Talos, Flux, Kubernetes applications, or cluster state.
- Root admission requires both universality and constraint status. Procedures belong in `docs/runbooks/`; until PR 3 moves an existing procedure, its current `docs/*.md` path remains the sole canonical owner and must be routed directly. Scoped constraints belong in nested `AGENTS.md` files. A scoped file may bind a cross-tree domain only when its header declares that domain and root routes readers to it explicitly.
- Nested instructions are additive: they may narrow or strengthen root constraints, never relax or override them.
- Normative content moves; it is not copied into both an `AGENTS.md` and a README.
- The link validator is Bash plus `rg`, executable, and ShellCheck-clean. It checks tracked content only, rejects absolute filesystem paths and `file:` URLs in Markdown links, does not fetch HTTP(S) URLs, and validates both Markdown links and bare repository-path references.
- The validator skips exactly one tracked subtree: `docs/superpowers/*`. Design specs and implementation plans deliberately name paths before they exist (a spec forward-references PR 2's files) and after they move (this plan's own mapping table names every PR 3 destination). Scanning them would make PR 1 unachievable. Nothing else is excluded, and the exclusion is never widened to make a later pull request pass.
- The validator does **not** skip fenced or inline code. This is deliberate: a path printed by a recipe or shown in an operator command example must resolve, which is the exact failure mode class 2 exists to catch. A path used purely as notation belongs in the excluded spec subtree or must be written so it does not parse as a repository path.
- Neither `scripts/validate/links.sh` nor `scripts/validate/links-test.sh` may contain a literal repository path that does not resolve; the validator scans itself and its own test. Assemble every such path in the test from a variable.
- `mise exec -- just ci` must pass before each pull request is handed off. Cluster-dependent `*-verify`, `*-status`, `*-preflight`, diagnostics, bootstrap, and rollout recipes remain operator-only and are not run for this work.
- Immediately before each push, fetch `origin`; safely rebase a clean branch onto the current `origin/main` when needed. If a force update is required after rebase, use only `--force-with-lease`; a failed lease is a full stop.
- Every pull-request handoff reports changed files, validation actually run, remaining risks, and deferred work.

---

## File Structure

### PR 1 — validator baseline

- Create `scripts/validate/links.sh`: validate relative Markdown targets and bare repository path references in tracked text.
- Create `scripts/validate/links-test.sh`: build isolated temporary Git fixtures and prove both reference classes fail closed.
- Create `tests/fixtures/links/dead-markdown.md.in`: source for a tracked Markdown file with a missing relative link.
- Create `tests/fixtures/links/dead-bare-path.txt.in`: source for a tracked non-Markdown file with a missing `docs/**.md` path.
- Modify `.just/repository.just`: expose the combined self-test and repository scan as `just repo links-validate`.
- Modify `tests/catalog.yaml`: register `validation.links` and include it in `executions.ci`.
- Modify `README.md`: document the new recipe in the command table.
- Modify `kubernetes/apps/monitoring/flux-kube-state-metrics/app/values.yaml`: repair a dead relative reference the validator finds on the pre-move tree.
- Modify `plans/talos-validation-refactor-plan.md`: remove a dead reference to a plan that does not exist.
- Delete `plans/agent-instructions-and-skills-architecture-plan.md`: remove the superseded plan before link-moving work.

### PR 2 — instruction ownership

- Rewrite `AGENTS.md`: universal constitution, restored worktree constraints, precedence, required reading, and scoped index.
- Create `kubernetes/AGENTS.md`: Kubernetes/Flux-scoped constraints.
- Create `talos/AGENTS.md`: constraints for `talos/` and generated root `clusterconfig/`.
- Create `tests/AGENTS.md`: constraints for `tests/` and test result/guard machinery under `scripts/test/`.
- Create `docs/runbooks/talos-generate.md`: canonical Talos generation and source-validation procedure.
- Create `docs/runbooks/talos-install.md`: canonical guarded one-node Talos installation procedure.
- Modify `kubernetes/README.md`: retain explanation and recipe orientation, remove migrated rules, point to `AGENTS.md`, and route the SOPS procedure to current `docs/sops.md`.
- Modify `docs/sops.md`: own the exact operator-only Kubernetes Secret editing and repository-verification sequence removed from the Kubernetes README.
- Modify `talos/README.md`: retain source-versus-generated orientation, remove procedures and migrated rules, and link to the two runbooks and `AGENTS.md`.
- Modify `tests/README.md`: remove the four migrated constraints and point to `AGENTS.md`.
- Modify `CLAUDE.md`: identify `MEMORY.md` as external persistent memory, not a repository path.
- Modify the approved design and this plan: keep cross-tree scope and PR 2/PR 3 transition ownership synchronized with the implementation.

### PR 3 — documentation topology

- Move 13 existing procedural documents into `docs/runbooks/`.
- Move `docs/phase-0-preflight.md` through `docs/phase-14-media.md` into `docs/phases/`.
- Change root's completed-history route to `docs/phases/`, the Kubernetes SOPS route to `docs/runbooks/sops.md`, and the Talos installation-evidence link to its moved phase path.
- Modify every tracked source reported by `just repo links-validate` until all Markdown and bare references resolve to the new paths.

### PR 4 — human README boundary

- Modify `README.md`: replace duplicated agent policy with links to the owning root or nested instruction file while retaining operator onboarding, the recipe reference, confirmation safety, and the repository-boundary explanation. The approved design also lists "slot creation" and "VS Code setup" as retained material; the current `README.md` contains neither, so there is nothing to retain and none is invented here. See Task 4, Step 7.

---

### Task 1: PR 1 — Add the reference validator and remove the superseded plan

**Files:**

- Create: `scripts/validate/links.sh`
- Create: `scripts/validate/links-test.sh`
- Create: `tests/fixtures/links/dead-markdown.md.in`
- Create: `tests/fixtures/links/dead-bare-path.txt.in`
- Modify: `.just/repository.just:1106-1141`
- Modify: `tests/catalog.yaml:6-40,179-195`
- Modify: `README.md:195-286`
- Modify: `kubernetes/apps/monitoring/flux-kube-state-metrics/app/values.yaml:6`
- Modify: `plans/talos-validation-refactor-plan.md:179-180`
- Delete: `plans/agent-instructions-and-skills-architecture-plan.md`

**Interfaces:**

- Consumes: tracked paths from `git ls-files`; Bash 5+; `rg` with PCRE2; the existing `validation.<name>` catalog schema.
- Produces: executable `scripts/validate/links.sh [repository-root]`, which exits `0` only when both reference classes are valid; `mise exec -- just repo links-validate`; catalog suite `validation.links` in `executions.ci`.

`.just/repository.just:1136-1141` already requires every `scripts/validate/*.sh` to be executable and already runs `bash -n` plus ShellCheck over both `scripts/validate/` and `scripts/test/`, and `just repo verify` is already in `just ci`. Both new scripts inherit those gates the moment they land, which is why they belong in `scripts/validate/` even though the repository's other test entrypoints live in `scripts/test/`.

- [ ] **Step 1: Add the two inert fixture templates**

Create `tests/fixtures/links/dead-markdown.md.in` with this exact content. Its `.in` suffix keeps it out of the normal Markdown-link scan:

```markdown
[broken](missing-target.md)
```

Create `tests/fixtures/links/dead-bare-path.txt.in` with this exact content. The token prevents the checked-in template itself from matching the bare-path expression:

```text
See docs/@MISSING@.md for recovery.
```

- [ ] **Step 2: Add the failing validator contract test**

Create executable `scripts/validate/links-test.sh` with this content. It proves missing Markdown and bare targets, angle-bracket targets with spaces, absolute and `file:` Markdown targets, scanner/root failures, tracked-only behavior, the exact exclusion boundary, and bare-path suffix handling. It also proves a Markdown directory target, a shell-interpolated path such as `"$base/README.md"`, and a live bare path are accepted. Every repository path is assembled from a variable, because this file is itself scanned by the validator it tests:

```bash
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
```

Mark it executable:

```bash
chmod +x scripts/validate/links-test.sh
```

- [ ] **Step 3: Run the contract test and confirm it fails before implementation**

Run:

```bash
mise exec -- scripts/validate/links-test.sh
```

Expected: non-zero because `scripts/validate/links.sh` does not exist yet.

- [ ] **Step 4: Implement both reference classes**

Create executable `scripts/validate/links.sh` with this content:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(git rev-parse --show-toplevel)}"
cd "$repo_root"
repo_root="$(pwd -P)"

if ! git_root="$(git rev-parse --show-toplevel)"; then
  echo "Validator root must be a Git worktree: $repo_root" >&2
  exit 1
fi
if [[ "$repo_root" != "$git_root" ]]; then
  echo "Validator root must be the Git worktree root: $repo_root" >&2
  exit 1
fi

# Design specs and implementation plans deliberately name paths that do not exist
# yet, so they are the one tracked subtree this validator does not scan.
exclude_spec=':(exclude)docs/superpowers/*'

failed=0

report_failure() {
  local source="$1"
  local line="$2"
  local class="$3"
  local target="$4"
  printf "%s:%s: %s '%s'\n" "$source" "$line" "$class" "$target" >&2
  failed=1
}

unescape_destination() {
  local value="$1" index character backslash=$'\\' result=''
  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    if [[ "$character" == "$backslash" && $((index + 1)) -lt ${#value} ]]; then
      ((index += 1))
      character="${value:index:1}"
    fi
    result+="$character"
  done
  printf '%s' "$result"
}

canonical_path() {
  local path="$1" link parent
  while [[ -L "$path" ]]; do
    link="$(readlink "$path")"
    if [[ "$link" == /* ]]; then path="$link"; else path="$(dirname "$path")/$link"; fi
  done
  parent="$(cd "$(dirname "$path")" && pwd -P)"
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}

is_local_path() {
  local canonical
  canonical="$(canonical_path "$1")"
  [[ "$canonical" == "$repo_root" || "$canonical" == "$repo_root/"* ]]
}

scan_markdown() {
  local source="$1"
  local line target path matches status

  if matches="$(
    rg --line-number --no-heading --only-matching --pcre2 \
      --replace '$1' \
      "$markdown_pattern" \
      "$source"
  )"; then
    :
  else
    status=$?
    if ((status == 1)); then
      return 0
    fi
    printf 'Failed to scan Markdown links in %s (rg exit %s).\n' \
      "$source" "$status" >&2
    return "$status"
  fi

  while IFS=: read -r line target; do
    [[ -n "$target" ]] || continue
    target="${target#<}"
    target="${target%>}"

    case "$target" in
      \#*|http://*|https://*|mailto:*) continue ;;
      /*|file:*)
        report_failure "$source" "$line" 'forbidden Markdown link target' "$target"
        continue
        ;;
    esac

    path="${target%%#*}"
    path="${path%%\?*}"
    [[ -n "$path" ]] || continue
    path="$(unescape_destination "$path")"
    path="$(dirname "$source")/$path"
    if [[ ! -e "$path" ]]; then
      report_failure "$source" "$line" 'missing Markdown link target' "$target"
    elif ! is_local_path "$path"; then
      report_failure "$source" "$line" 'non-local Markdown link target' "$target"
    fi
  done <<<"$matches"
}

scan_bare_path() {
  local source="$1"
  local line target resolved matches status

  if matches="$(rg --line-number --no-heading --only-matching --pcre2 \
    "$bare_pattern" "$source")"; then
    :
  else
    status=$?
    if ((status == 1)); then
      return 0
    fi
    printf 'Failed to scan bare paths in %s (rg exit %s).\n' \
      "$source" "$status" >&2
    return "$status"
  fi

  while IFS=: read -r line target; do
    [[ -n "$target" ]] || continue
    resolved="$target"
    case "$target" in
      ./*|../*) resolved="$(dirname "$source")/$target" ;;
    esac
    if [[ ! -f "$resolved" ]]; then
      report_failure "$source" "$line" 'missing bare path target' "$target"
    elif ! is_local_path "$resolved"; then
      report_failure "$source" "$line" 'non-local bare path target' "$target"
    fi
  done <<<"$matches"
}

markdown_paths="$(mktemp)"
bare_paths="$(mktemp)"
trap 'rm -f "$markdown_paths" "$bare_paths"' EXIT

markdown_pattern="!?\\[[^\\]\\[]*\\]\\((<[^<>]*>|(?<destination>(?:\\\\.|[^()[:space:]>]|\\((?&destination)\\))+))(?:[[:space:]]+(\"[^\"]*\"|'[^']*'|\\([^()]*\\)))?\\)"
git ls-files -z '*.md' "$exclude_spec" >"$markdown_paths"
while IFS= read -r -d '' source; do
  scan_markdown "$source"
done <"$markdown_paths"

bare_pattern='(?<![\w$/{}.-])(?:(?:docs|plans)/[A-Za-z0-9._/-]+\.md|(?:[A-Za-z0-9._-]+/)+(?:README|AGENTS)\.md)(?![A-Za-z0-9_/-]|\.[A-Za-z0-9_-])'
git ls-files -z "$exclude_spec" >"$bare_paths"
while IFS= read -r -d '' source; do
  scan_bare_path "$source"
done <"$bare_paths"

if ((failed != 0)); then
  exit 1
fi

echo 'Tracked Markdown links and bare repository paths resolve.'
```

Mark it executable:

```bash
chmod +x scripts/validate/links.sh
```

The implementation intentionally validates relative inline Markdown links only. It supports recursively balanced and escaped ordinary destinations, angle-bracket destinations, and double-, single-, or parenthesized titles; fragment-only and HTTP(S) links are skipped, HTTP(S) is never fetched, absolute filesystem and `file:` targets are errors, and bare `docs/**.md`, `plans/**.md`, and subtree `README.md`/`AGENTS.md` paths resolve from repository root. Existing targets are canonicalized, including symlinks, and must remain inside the worktree root. The supplied root must itself be the Git worktree root.

Escaped destination characters are decoded while scanning left-to-right: an unescaped `#` or `?` starts fragment/query handling, while `\#` and `\?` remain literal filename characters. Parenthesized titles likewise permit escaped delimiters.

Four details in that code are load-bearing and are not stylistic:

- The Markdown destination capture has separate angle-bracket and ordinary branches. The angle branch permits spaces and punctuation while the ordinary branch remains whitespace- and parenthesis-free. The link-text character class is `[^\]\[]`, not `[^][]`; Ripgrep's default engine is Rust's `regex`, which does not treat a leading `]` inside a class as literal.
- The Markdown existence test is `-e`, not `-f`. A link target may legitimately be a directory — PR 4 links `docs/runbooks/` — and `-f` would reject it.
- Ripgrep exit status `1` means no matches and is accepted; any greater status is reported and fails the validator. The two tracked-file lists are materialized before scanning, so `git ls-files` failures cannot be lost in a process substitution.
- Markdown scanning uses PCRE2 recursion for ordinary destinations and supports all three valid title delimiters. Destinations are unescaped for filesystem resolution but reported as written.
- Existing Markdown and bare targets are canonicalized through symlinks and rejected when their canonical path leaves the worktree; an existing external file must never validate a repository reference.
- The bare pattern is wrapped in the negative lookbehind `(?<![\w$/{}.-])` and a trailing boundary that rejects a path character or a dot followed by one. This avoids false prefixes such as `.md.in` and `.md.old` without ignoring a sentence-final period.
- Both `git ls-files` calls pass `"$exclude_spec"`. Both classes must skip exactly `docs/superpowers/*`, not just one; tracked neighbors remain scanned.

- [ ] **Step 5: Run focused syntax, lint, and behavior checks**

Run:

```bash
mise exec -- bash -n scripts/validate/links.sh scripts/validate/links-test.sh
mise exec -- shellcheck --external-sources scripts/validate/links.sh scripts/validate/links-test.sh
mise exec -- scripts/validate/links.sh .
```

Expected: the first two exit `0`. The third exits `1` with **exactly** these four failures and no others:

```text
kubernetes/apps/monitoring/flux-kube-state-metrics/app/values.yaml:6: missing bare path target './README.md'
plans/agent-instructions-and-skills-architecture-plan.md:1168: missing bare path target 'kubernetes/AGENTS.md'
plans/agent-instructions-and-skills-architecture-plan.md:1168: missing bare path target 'talos/AGENTS.md'
plans/talos-validation-refactor-plan.md:180: missing bare path target 'plans/talos-media-stack.md'
```

These are pre-existing defects in the tree, not validator bugs. The two in the superseded plan disappear when Step 7 deletes that file; the other two are repaired in Step 6. If any *other* failure appears, stop — the validator is over-matching and must be fixed before proceeding, not worked around by widening the exclusion.

- [ ] **Step 6: Repair the two genuine dead references**

`kubernetes/apps/monitoring/flux-kube-state-metrics/app/values.yaml:6` points at `./README.md`, but the component's README is one level up at `kubernetes/apps/monitoring/flux-kube-state-metrics/README.md` — the values file lives in `app/`. Change that one comment line:

```yaml
# values are left untouched. See ../README.md for the future consolidation path.
```

`plans/talos-validation-refactor-plan.md:179-180` names `plans/talos-media-stack.md`, which has never existed in this repository; the plan it means is already named on the preceding line. Replace both lines with:

```markdown
  `kubernetes/apps/media/plex/**` (the app layout), `plans/media-stack-architecture-plan.md` (the documented invariants encoded above).
```

- [ ] **Step 7: Delete only the superseded plan**

Confirm that its only match is its self-reference, then delete it:

```bash
mise exec -- rg -n 'plans/agent-instructions-and-skills-architecture-plan.md' --glob '!plans/agent-instructions-and-skills-architecture-plan.md'
mise exec -- git rm plans/agent-instructions-and-skills-architecture-plan.md
```

Expected: the `rg` command returns no matches; `git rm` removes exactly that file. Do not clean up any of the other seven tracked plans.

- [ ] **Step 8: Run the contract test and confirm it now passes**

Run:

```bash
mise exec -- scripts/validate/links-test.sh
```

Expected: exit `0`, printing `Tracked Markdown links and bare repository paths resolve.` followed by `Link validator tests passed.` Missing, balanced, escaped, angle-bracket, absolute, and `file:` Markdown targets fail closed; scanner and root failures fail; existing Markdown and bare traversal targets outside the worktree fail; only tracked content is scanned; exactly `docs/superpowers/*` is skipped; bare-path suffixes are ignored; and the acceptance cases pass.

- [ ] **Step 9: Expose one repository recipe**

Add this public recipe immediately before `.just/repository.just`'s existing `verify` recipe:

```just
# Reject broken relative Markdown links and bare repository documentation paths.
links-validate:
    scripts/validate/links-test.sh
```

Run:

```bash
mise exec -- just repo links-validate
```

Expected: exit `0` with both success messages from Step 8.

- [ ] **Step 10: Register the validator in the CI catalog**

In `tests/catalog.yaml`, add `validation.links` immediately after `validation.repo-verify` in `executions.ci`:

```yaml
    - validation.links
```

Add this suite immediately after the `validation.repo-verify` suite:

```yaml
  - metadata: {id: validation.links, source: validation, framework: bash, suite: ci, tier: offline, target: documentation, scenario: links, scope: repository, intent: regression, mutates_cluster: false, execution_owner: shared}
    confirmation: {type: none, variable: null, expected: null}
    runner: {command: "mise exec -- just repo links-validate", implementation: scripts/validate/links.sh}
    native_results: {strategy: wrapper-junit}
```

Run:

```bash
mise exec -- just test catalog-validate
```

Expected: exit `0`; the validation-suite count and `executions.ci` count remain 1:1. `scripts/test/run-ci.sh` iterates `executions.ci` and dispatches each `runner.command`, so this entry is what actually puts the validator inside `just ci`; `repo links-validate` satisfies that script's command-safety pattern.

- [ ] **Step 11: Add the recipe-table entry**

Add this row beside `just repo lint` in the root `README.md` recipe table:

```markdown
| `just repo links-validate` | Reject broken relative Markdown links, absolute/file Markdown targets, and missing bare repository documentation paths | — | Cluster-independent; included in `just ci` |
```

- [ ] **Step 12: Prove the baseline before any documentation moves**

Run:

```bash
mise exec -- just repo links-validate
mise exec -- just ci
```

Expected: both pass against the pre-move documentation layout. This green baseline is PR 1's principal acceptance evidence.

- [ ] **Step 13: Commit and hand off PR 1**

```bash
mise exec -- git add .just/repository.just README.md scripts/validate/links.sh scripts/validate/links-test.sh tests/catalog.yaml tests/fixtures/links kubernetes/apps/monitoring/flux-kube-state-metrics/app/values.yaml plans/talos-validation-refactor-plan.md
mise exec -- git add -u plans/agent-instructions-and-skills-architecture-plan.md
mise exec -- git commit -m "test: validate repository documentation links"
```

Before pushing, follow the global fetch/rebase rule. Open a pull request titled `test: validate repository documentation links`. Its description must call out the two independently failing fixtures, the acceptance case, the two pre-existing dead references repaired to reach green, and the `docs/superpowers/*` exclusion with its justification. State that the validator passed before any file moves. Stop after handoff; Task 2 starts only after this pull request is merged.

---

### Task 2: PR 2 — Establish the constitution and scoped instruction layer

**Files:**

- Modify: `AGENTS.md:1-67`
- Create: `kubernetes/AGENTS.md`
- Create: `talos/AGENTS.md`
- Create: `tests/AGENTS.md`
- Create: `docs/runbooks/talos-generate.md`
- Create: `docs/runbooks/talos-install.md`
- Modify: `kubernetes/README.md:1-132`
- Modify: `docs/sops.md`
- Modify: `talos/README.md:1-79`
- Modify: `tests/README.md:1-189`
- Modify: `CLAUDE.md:9-10`
- Modify: `docs/superpowers/specs/2026-07-31-agents-md-information-architecture-design.md`
- Modify: `docs/superpowers/plans/2026-07-31-agents-md-information-architecture-implementation-plan.md`

**Interfaces:**

- Consumes: root constraints in the pre-PR `AGENTS.md`; normative rules in `kubernetes/README.md`, `talos/README.md`, and `tests/README.md`; the additive-inheritance model from the approved design.
- Produces: universal root constraints; required-reading contract; scoped constraints for Kubernetes/Flux, Talos plus root `clusterconfig/`, and tests plus result/guard machinery under `scripts/test/`; canonical Talos procedures at `docs/runbooks/talos-generate.md` and `docs/runbooks/talos-install.md`; the exact SOPS edit workflow owned at current `docs/sops.md`; current-path routes that PR 3 updates atomically with document moves.

- [ ] **Step 1: Start from PR 1's merged baseline**

Fetch `origin`, confirm PR 1's validator is present on `origin/main`, and create or switch to the assigned PR 2 branch without using any `git worktree` lifecycle subcommand.

Run:

```bash
mise exec -- just repo links-validate
```

Expected: pass before instruction text changes.

- [ ] **Step 2: Rewrite the root constitution**

Rewrite `AGENTS.md` so it contains only the following universal constraints and routing obligations:

1. Repository purpose and `main` as the Flux production deployment boundary.
2. The following two blocks verbatim:

```markdown
## Precedence

1. A constraint in this file is a floor. A scoped `AGENTS.md` may narrow or
   strengthen it, never relax or override it. A scoped file that appears to
   permit what this file prohibits is defective — obey this file and report it.
2. Runbooks and skills carry procedure only. They never grant permission.
3. Deterministic enforcement outranks every instruction. If a guard refuses,
   the answer is no.
4. On any unresolved conflict, stop and ask the operator. Never take the
   permissive reading.

## Scoped instructions are required reading

Before modifying any file under a directory that has its own `AGENTS.md`, read
that file. Do not assume your client loaded it automatically — verify. If a
scoped file cannot be read, stop and report rather than proceeding under root
rules alone.
```

3. Git and approval authority: never commit or push to `main`; commits remain scoped and reviewable; preserve unrelated changes; report files/validation/risks; never merge or enable auto-merge without authorization for that exact merge; the operator owns merge and rollout.
4. Worktree and concurrency: the assigned worktree is an absolute filesystem boundary; never read or write another slot; never run `git worktree add`, `remove`, `move`, `prune`, `lock`, `unlock`, or `repair`; never begin work in a slot parked on an unmerged branch; fetch before every push and rebase a clean branch when needed; use only `--force-with-lease`; stop on a failed lease; never use `reset --hard`, `clean -fd`, or unconditional force-push.
5. Tools and cluster access: retain every current pinned-tool, guarded-recipe, confirmation-authority, deployed-source, and GitHub-protection constraint. State explicitly that agents never invent a `*_CONFIRM` value.
6. Secrets: retain every current SOPS, age-key, ciphertext, plaintext, and guarded `*-secrets` constraint.
7. Validation: `mise exec -- just ci` is authoritative, cluster-independent, and secret-free; cluster-dependent `*-verify`, `*-status`, `*-preflight`, and diagnostic families are operator-only and never enter it. Delete the pre-commit/repo-lint explanation from `AGENTS.md`; it is descriptive rather than an agent constraint, and `README.md:35` already documents `mise exec -- just repo lint` and the hook suite. Nothing is added to `README.md` in this pull request — the design's "move" is satisfied by the existing README text, so `README.md` is not in this task's file list.
8. Scoped index with one concise entry for each destination:

```markdown
## Scoped instruction index

- Read `kubernetes/AGENTS.md` before changing Kubernetes or Flux sources.
- Read `talos/AGENTS.md` before changing Talos sources, generation inputs, or root
  `clusterconfig/`.
- Read `tests/AGENTS.md` before changing the test catalog, suites, fixtures, or
  test result and guard machinery, including `scripts/test/`.
- Read the relevant file under `docs/runbooks/` before following a repository procedure.
- Current `docs/phase-*.md` files are completed rollout history, not live procedure.
- `docs/superpowers/specs/` records design rationale and is descriptive, never normative.
```

Do not retain the old `## Talos and Flux invariants` section; its rules move to the two scoped files below.

- [ ] **Step 3: Create the Kubernetes scoped constraints**

Create `kubernetes/AGENTS.md` with a short purpose line and these binding rules, without workflow sequences:

```markdown
# Kubernetes Agent Instructions

Binding constraints for all files under `kubernetes/`. Root `AGENTS.md` remains the
floor and this file may only narrow or strengthen it.

## Source and reconciliation boundaries

- Flux cluster entrypoints belong under `flux/clusters/prod/`.
- Components live under `apps/<namespace>/<app>/` with an explicit `ks.yaml` and
  `app/`; a directory is not deployed merely because it exists.
- Use a `HelmRelease` for a healthy maintained chart and focused native resources
  otherwise. Never commit `helm template`, Kompose, or other generator output as
  declarative source.
- Express ordering with `dependsOn`, readiness waiting, and health checks, never
  implicit directory order or numeric sync waves. Native Kustomizations select
  children explicitly; Flux does not deploy directories recursively.
- Never manually apply `ks.yaml`, `ocirepository.yaml`, or `helmrelease.yaml`.
- After Flux bootstrap, steady-state Kubernetes changes are committed to Git and
  reconciled by Flux. Bootstrap and recovery applies use guarded `just` recipes,
  never raw `kubectl`.

## Networking and secrets

- The Gateway owns the single wildcard certificate. Application routes never copy
  TLS private keys.
- ExternalDNS publishes only routes carrying
  `external-dns.k8s.io/audience=internal`.
- Kubernetes Secret manifests use the `*.sops.yaml` suffix. Never commit a
  decrypted Secret or place the age identity in this tree.

## Rollout and storage invariants

- New apps begin suspended, activate through a guarded rollout, and then persist
  the unsuspended state in Git. Never suspend a Flux resource without approval.
- A Deployment mounting a `ReadWriteOnce` PVC uses `Recreate`, or use a StatefulSet;
  never use `RollingUpdate` for that workload.
```

- [ ] **Step 4: Create the Talos scoped constraints**

Create `talos/AGENTS.md` with this content:

```markdown
# Talos Agent Instructions

Binding constraints for all files under `talos/` and generated machine configs
under root `clusterconfig/`. Root `AGENTS.md` remains the floor and this file may
only narrow or strengthen it.

- Never hand-edit generated files under root `clusterconfig/`. Change
  `talconfig.yaml` and `patches/`, then regenerate.
- Preserve Talos, Kubernetes, and Cilium compatibility.
- Rendered machine configs contain credentials. Never move them into a trackable
  path.
- Applying a rendered config is a separate guarded operation. Never replace it
  with raw `talosctl apply-config`.
- Never reuse another node's confirmation value.
```

- [ ] **Step 5: Create the test scoped constraints**

Create `tests/AGENTS.md` with this content:

```markdown
# Test Agent Instructions

Binding constraints for all files under `tests/` and test result and guard
machinery under `scripts/test/`. Root `AGENTS.md` remains the floor and this file
may only narrow or strengthen it.

- Live and cluster-dependent suites never enter `executions.ci`.
- Validation-tier suite entries and `executions.ci` entries stay 1:1.
- Generated result artifacts record only a confirmation variable name, never its
  value.
- Guards fail closed.
- Sonobuoy is ephemeral, never scheduled or standing.
```

- [ ] **Step 6: Extract the Talos generation runbook**

Create `docs/runbooks/talos-generate.md` from the existing `talos/README.md` generation workflow. It must contain:

- Purpose: generate ignored machine configs from tracked Talhelper sources without mutating the cluster.
- Preconditions: repository root, Bash 5+, mise toolchain installed, operator-provided repository age identity available.
- Exact commands, all through the pinned interface:

```bash
mise exec -- just repo secrets
mise exec -- just talos generate
mise exec -- just talos validate
mise exec -- just repo verify
```

- Behavior: `talos generate` verifies the age identity, decrypts only inside Talhelper, replaces ignored `clusterconfig/`, invokes strict validation, and checks all three metal configs plus endpoint, network, Secure Boot installer, CNI, kube-proxy, encryption, and volume decisions.
- Focused path: `mise exec -- just talos source-validate` for trackable Talhelper-only edits.
- Boundary link: applying a rendered config is covered only by `talos-install.md`.

- [ ] **Step 7: Extract the guarded Talos installation runbook**

Create `docs/runbooks/talos-install.md` from `talos/README.md` lines 45-75. Preserve the full operator sequence and exact examples:

Add this prerequisite exactly:

```markdown
## Prerequisite

Current rendered machine configs must exist. If needed, generate and validate
them with [`talos-generate.md`](talos-generate.md) before continuing.
```

```bash
mise exec -- just talos apply nuc1
```

Explain that the first pass validates all rendered configs, verifies live Secure Boot and exact NVMe identity, rejects unexpected disks, performs Talos dry-run, refuses the wipe, and prints the serial-bound value. Then include:

```bash
TALOS_APPLY_CONFIRM='nuc1:/dev/nvme0n1:<live-serial>' \
  mise exec -- just talos apply nuc1
```

State that the confirmed invocation repeats every guard, wipes `/dev/nvme0n1`, installs the signed image, and reboots exactly one matching node; requires USB removal during reboot; and never runs `talosctl bootstrap`. Direct the operator to repeat independently for `nuc2` and `nuc3`, using the value printed for that node. In PR 2, link installation evidence at the currently valid `../phase-3-installation.md`; Task 3 changes it to `../phases/phase-3-installation.md` when the phase record moves.

- [ ] **Step 8: Remove migrated rules from the Kubernetes README**

Add this sentence directly after the opening paragraph:

```markdown
Binding rules for this directory are in [`AGENTS.md`](AGENTS.md); this file is explanatory.
```

Remove the rules now owned by `kubernetes/AGENTS.md`: entrypoint/layout requirements, generated-source prohibitions, HelmRelease/native selection, dependency ordering, recursive-deployment prohibition, manual apply prohibition, Gateway/TLS and ExternalDNS constraints, `*.sops.yaml` suffix, decrypted-secret prohibition, and steady-state deployment constraint.

Retain the explanatory statements that shared bases are deferred, `deletionPolicy: Orphan` prevents root deletion from cascading, and SOPS encrypts only `data`/`stringData`. Remove the ordered identity-loading and interactive-editing sequence from this README and route operator procedure to the currently valid `docs/sops.md`; Task 3 updates that link when the runbook moves. Add the exact removed three-command workflow to `docs/sops.md` so procedure ownership moves rather than disappears:

```bash
mise exec -- just repo secrets
mise exec -- sops kubernetes/path/to/secret.sops.yaml
mise exec -- just repo verify
```

Use this exact explanatory route in `kubernetes/README.md`:

```markdown
SOPS encrypts only Secret `data` and `stringData` fields so metadata remains
reviewable by Flux. Identity loading and interactive editing are operator-only
procedures documented in [`docs/sops.md`](../docs/sops.md).
```

Retain the Cilium bootstrap narrative, package tree, recipe tables, and phase/runbook links. Replace the old raw-`kubectl` exception with this non-relaxing explanation:

```markdown
Bootstrap and recovery applies are performed through documented guarded `just`
recipes, which invoke the required client internally; they are not direct agent
commands.
```

- [ ] **Step 9: Reduce the Talos README to orientation**

Add the same binding-rule pointer after its opening paragraph, retain the tracked-source list and the explanation that Talhelper writes ignored root `clusterconfig/`, and remove the migrated credential constraint plus both workflow sections. Replace them with links:

```markdown
Generate and validate machine configs with
[`docs/runbooks/talos-generate.md`](../docs/runbooks/talos-generate.md). Install one
node through the guarded workflow in
[`docs/runbooks/talos-install.md`](../docs/runbooks/talos-install.md).
```

Keep the root README and platform-plan links. The resulting README should be an orientation document of roughly 20 lines; exact size is not an acceptance gate.

- [ ] **Step 10: Remove migrated constraints from the test README**

Add this sentence after the opening paragraph:

```markdown
Binding rules for this directory are in [`AGENTS.md`](AGENTS.md); this file is explanatory.
```

Remove or rewrite the four normative statements so they exist only in `tests/AGENTS.md`: Sonobuoy is never standing, live commands never enter `just ci`, result artifacts never store confirmation values, and the persistence suite must not enter CI. Preserve the surrounding descriptive catalog, command, artifact, and report behavior. Do not remove complete confirmation examples from human documentation.

- [ ] **Step 11: Clarify Claude's external memory reference**

Replace `CLAUDE.md` lines 9-10 with:

```markdown
- Your external persistent memory index (`MEMORY.md`, outside this repository)
  records hard-won lessons; verify every repository path or recipe it names before acting.
```

- [ ] **Step 12: Work the rule-by-rule completeness gate**

Compare the resulting files against sections A-F of the approved design and explicitly check every group below in the PR description:

- Root current rules: purpose/production boundary; no direct main commit/push; per-merge authorization; scoped commits; reporting; worktree/branch preservation; fetch/rebase; pinned tools; guarded cluster access; missing-recipe rule; operator-only confirmations; deployed-source parity; protected-repository authorization; canonical CI; operator-only live checks; SOPS/age/secrets constraints.
- Kubernetes README migration: Flux entrypoints; app package; explicit entrypoint/deployment; Helm output; chart/native selection; generator prohibition; explicit dependency/health ordering; native selection/no recursion; no manual Flux-source apply; wildcard certificate; ExternalDNS audience; SOPS suffix; decrypted Secret; Git/Flux steady state; exact SOPS edit workflow moved to current `docs/sops.md` with only an operator route retained in the README.
- Talos README migration: rendered credentials; guarded apply; node-specific confirmation; generation procedure; install procedure; source-versus-generated explanation.
- Tests README migration: live suites excluded from CI; artifact confirmation-name-only; operator suites excluded from CI; Sonobuoy ephemeral; validation-suite and CI-entry 1:1.
- Restored rules: absolute worktree boundary; prohibited worktree lifecycle subcommands; no parked unmerged slot; lease-only force update/full stop; no hard reset, clean, or unconditional force.
- New rules: precedence/additive inheritance; scoped required reading; scoped destination index; explicit cross-tree routes for root `clusterconfig/` and test result/guard machinery under `scripts/test/`; current `docs/phase-*.md` history classification with a Task 3 transition to `docs/phases/`.

For each item, name exactly one owning file. If an item is absent, duplicated, or requires relaxing root, stop and resolve it before continuing.

- [ ] **Step 13: Validate PR 2**

Run:

```bash
mise exec -- just repo links-validate
mise exec -- just repo lint
mise exec -- just ci
```

Expected: all pass; no file moves have occurred, and all links remain valid.

- [ ] **Step 14: Commit and hand off PR 2**

```bash
mise exec -- git add AGENTS.md CLAUDE.md kubernetes/AGENTS.md kubernetes/README.md talos/AGENTS.md talos/README.md tests/AGENTS.md tests/README.md docs/sops.md docs/runbooks/talos-generate.md docs/runbooks/talos-install.md docs/superpowers/specs/2026-07-31-agents-md-information-architecture-design.md docs/superpowers/plans/2026-07-31-agents-md-information-architecture-implementation-plan.md
mise exec -- git commit -m "docs: define agent instruction ownership"
```

Open a pull request titled `docs: define agent instruction ownership`. Include the completed A-F checklist and explain the `kubectl apply` conflict resolution: guarded recipes preserve root's raw-client prohibition, so no scoped exception exists. Stop after handoff; Task 3 starts only after this pull request is merged.

---

### Task 3: PR 3 — Split live runbooks from completed phase history

**Files:**

- Move to `docs/runbooks/`: `sops.md`, `recovery.md`, `github-protection.md`, `pihole-integration.md`, `portainer.md`, `protonvpn-gluetun.md`, `tailscale-operator.md`, `tailscale-lab-domain.md`, `tailscale-single-user-setup.md`, `ntfy-startup-guide.md`, `arr-stack-startup.md`, `qbit-manage.md`, `qbit-manage-czteam.md`
- Move to `docs/phases/`: `phase-0-preflight.md`, `phase-1-repository.md`, `phase-2-talos.md`, `phase-3-installation.md`, `phase-4-bootstrap.md`, `phase-5-cilium.md`, `phase-6-flux.md`, `phase-7-foundation.md`, `phase-8-soak.md`, `phase-9-storage.md`, `phase-10-platform.md`, `phase-11-media.md`, `phase-12-media.md`, `phase-13-media.md`, `phase-14-media.md`
- Modify references in: `AGENTS.md`, `.just/bootstrap.just`, `.just/repository.just`, `README.md`, `kubernetes/README.md`, `talos/README.md`, `docs/runbooks/talos-install.md`, the moved docs, `docs/nuc-cluster.md`, affected app READMEs/YAML, `kubernetes/mod.just`, retained plans, affected scripts, and affected test YAML.
- Do **not** rewrite anything under `docs/superpowers/`. The design spec and this plan are dated records of what was decided against the pre-move layout; the validator excludes that subtree precisely so they can stay truthful to their date.

**Interfaces:**

- Consumes: `mise exec -- just repo links-validate` from Task 1; scoped instruction files from Task 2.
- Produces: `docs/runbooks/` as the only in-repository procedure surface, `docs/phases/` as finished history, and a zero-error tracked reference graph.

- [ ] **Step 1: Start from PR 2's merged baseline and read scoped rules**

Read root `AGENTS.md` plus `kubernetes/AGENTS.md`, `talos/AGENTS.md`, and `tests/AGENTS.md` before touching their subtrees. Fetch `origin`, base the assigned PR 3 branch on the `origin/main` containing PR 2, and run:

```bash
mise exec -- just repo links-validate
```

Expected: pass before moves.

- [ ] **Step 2: Move the 13 existing runbooks with Git history**

Create the destination if Task 2 did not already create it, then use pinned Git moves:

```bash
mkdir -p docs/runbooks
mise exec -- git mv docs/sops.md docs/recovery.md docs/github-protection.md docs/pihole-integration.md docs/portainer.md docs/protonvpn-gluetun.md docs/tailscale-operator.md docs/tailscale-lab-domain.md docs/tailscale-single-user-setup.md docs/ntfy-startup-guide.md docs/arr-stack-startup.md docs/qbit-manage.md docs/qbit-manage-czteam.md docs/runbooks/
```

Do not move `docs/nuc-cluster.md`, `docs/testing-layers.md`, `docs/test-campaigns.md`, or `docs/test-reports.md`; they remain descriptive root references.

- [ ] **Step 3: Move all 15 completed phase records with Git history**

```bash
mkdir -p docs/phases
mise exec -- git mv docs/phase-0-preflight.md docs/phase-1-repository.md docs/phase-2-talos.md docs/phase-3-installation.md docs/phase-4-bootstrap.md docs/phase-5-cilium.md docs/phase-6-flux.md docs/phase-7-foundation.md docs/phase-8-soak.md docs/phase-9-storage.md docs/phase-10-platform.md docs/phase-11-media.md docs/phase-12-media.md docs/phase-13-media.md docs/phase-14-media.md docs/phases/
```

Run:

```bash
mise exec -- git status --short
```

Expected: 28 renames plus link edits made in later steps; the two Talos runbooks already created by PR 2 remain ordinary files in `docs/runbooks/`.

- [ ] **Step 4: Apply the canonical path mapping to root-relative references**

Use this complete mapping for Markdown destinations, inline code, comments, recipe messages, shell output, YAML annotations, tests, and retained plans. It does not apply to `docs/superpowers/`:

```text
docs/sops.md                         -> docs/runbooks/sops.md
docs/recovery.md                     -> docs/runbooks/recovery.md
docs/github-protection.md            -> docs/runbooks/github-protection.md
docs/pihole-integration.md           -> docs/runbooks/pihole-integration.md
docs/portainer.md                    -> docs/runbooks/portainer.md
docs/protonvpn-gluetun.md            -> docs/runbooks/protonvpn-gluetun.md
docs/tailscale-operator.md           -> docs/runbooks/tailscale-operator.md
docs/tailscale-lab-domain.md         -> docs/runbooks/tailscale-lab-domain.md
docs/tailscale-single-user-setup.md  -> docs/runbooks/tailscale-single-user-setup.md
docs/ntfy-startup-guide.md           -> docs/runbooks/ntfy-startup-guide.md
docs/arr-stack-startup.md            -> docs/runbooks/arr-stack-startup.md
docs/qbit-manage.md                  -> docs/runbooks/qbit-manage.md
docs/qbit-manage-czteam.md           -> docs/runbooks/qbit-manage-czteam.md
docs/phase-0-preflight.md            -> docs/phases/phase-0-preflight.md
docs/phase-1-repository.md           -> docs/phases/phase-1-repository.md
docs/phase-2-talos.md                -> docs/phases/phase-2-talos.md
docs/phase-3-installation.md         -> docs/phases/phase-3-installation.md
docs/phase-4-bootstrap.md            -> docs/phases/phase-4-bootstrap.md
docs/phase-5-cilium.md               -> docs/phases/phase-5-cilium.md
docs/phase-6-flux.md                 -> docs/phases/phase-6-flux.md
docs/phase-7-foundation.md           -> docs/phases/phase-7-foundation.md
docs/phase-8-soak.md                 -> docs/phases/phase-8-soak.md
docs/phase-9-storage.md              -> docs/phases/phase-9-storage.md
docs/phase-10-platform.md            -> docs/phases/phase-10-platform.md
docs/phase-11-media.md               -> docs/phases/phase-11-media.md
docs/phase-12-media.md               -> docs/phases/phase-12-media.md
docs/phase-13-media.md               -> docs/phases/phase-13-media.md
docs/phase-14-media.md               -> docs/phases/phase-14-media.md
```

Apply the replacements with reviewable patches. Preserve prose and command behavior; only change path spelling in non-Markdown sources.

Apply the three explicit PR 2 transition updates in the same step:

- In root `AGENTS.md`, replace the current `docs/phase-*.md` history route with
  `` `docs/phases/` is completed rollout history, not live procedure. ``
- In `kubernetes/README.md`, change the SOPS procedure link from
  `../docs/sops.md` to `../docs/runbooks/sops.md`.
- In `docs/runbooks/talos-install.md`, change the installation-evidence link from
  `../phase-3-installation.md` to `../phases/phase-3-installation.md`.

- [ ] **Step 5: Repair relative links inside moved Markdown files**

For every moved file, recalculate links from its new directory:

- A runbook linking to another runbook uses the sibling basename, such as `tailscale-operator.md`.
- A runbook linking to phase history uses `../phases/<phase-file>.md`.
- A phase record linking to another phase record uses the sibling basename.
- A phase record linking to a runbook uses `../runbooks/<runbook-file>.md`.
- A moved file linking to a root descriptive document uses `../<document>.md`.
- Links from `docs/runbooks/` or `docs/phases/` to repository-root files or source trees gain one additional `../` compared with their old path.

Do not rewrite historical prose beyond the target path needed to keep it truthful and resolvable.

- [ ] **Step 6: Repair the known non-Markdown operator-facing references**

At minimum, inspect and patch these known bare-path consumers from the pre-move tree:

```text
.just/bootstrap.just
.just/repository.just
kubernetes/mod.just
kubernetes/apps/media/qbit-manage/app/config.yml
kubernetes/apps/media/qbit-manage/ks.yaml
kubernetes/apps/media/qbittorrent/app/prometheusrule.yaml
kubernetes/apps/media/qbittorrent/app/values.yaml
kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml
kubernetes/apps/networking/tailscale-operator/app/namespace.yaml
kubernetes/apps/networking/tailscale-operator/monitoring/prometheusrule.yaml
kubernetes/apps/networking/tailscale-operator/subnet-router/proxyclass.yaml
scripts/secrets/ntfy-consumer-sync.sh
scripts/secrets/ntfy-identity.sh
scripts/secrets/ntfy-subscriber-password.sh
scripts/test/scenarios/media-hardlink.sh
scripts/verify/media-storage.sh
scripts/verify/plex.sh
scripts/verify/tailscale-operator.sh
scripts/verify/tailscale-subnet-router.sh
tests/chainsaw/smoke/platform/tailscale/chainsaw-test.yaml
tests/prometheus/tailscale-alerts_test.yaml
```

Pay particular attention to the runtime echo in `.just/bootstrap.just` that names `docs/phases/phase-11-media.md` and the `.just/repository.just` comment that names `docs/runbooks/tailscale-operator.md`; these are why bare-path validation is mandatory.

- [ ] **Step 7: Let the validator enumerate the remaining exact edits**

Run:

```bash
mise exec -- just repo links-validate
```

Expected on the first run: non-zero with a finite list of remaining `file:line` failures. Patch every reported source, rerunning the same command until it exits `0`. Do not suppress, exclude, or weaken either reference class to make the move pass.

Then prove no old root path remains:

```bash
mise exec -- rg --hidden -n 'docs/(sops|recovery|github-protection|pihole-integration|portainer|protonvpn-gluetun|tailscale-operator|tailscale-lab-domain|tailscale-single-user-setup|ntfy-startup-guide|arr-stack-startup|qbit-manage|qbit-manage-czteam|phase-[0-9]+-[A-Za-z0-9-]+)\.md' --glob '!.git/**' --glob '!docs/superpowers/**'
```

Expected: no matches. The `docs/superpowers/**` exclusion mirrors the validator's own and is the only place old paths may legitimately survive; if you drop that glob you will see the design spec and this plan, and rewriting them is not the fix.

- [ ] **Step 8: Confirm the final topology and validate PR 3**

Run:

```bash
mise exec -- git ls-files docs/runbooks docs/phases | sort
mise exec -- just repo links-validate
mise exec -- just repo lint
mise exec -- just ci
```

Expected topology: 15 runbooks (13 moved plus 2 Talos runbooks), 15 phase records, four descriptive Markdown files at `docs/` root, and an unmodified `docs/superpowers/` subtree. Root routes completed history to `docs/phases/`; the Kubernetes SOPS link and Talos installation-evidence link use their moved destinations. All validation passes.

- [ ] **Step 9: Commit and hand off PR 3**

```bash
mise exec -- git add -A AGENTS.md docs .just README.md kubernetes plans scripts talos tests
mise exec -- git commit -m "docs: separate runbooks from phase history"
```

Open a pull request titled `docs: separate runbooks from phase history`. In the description, report the 28 Git moves, two pre-existing extracted Talos runbooks, the validator result, and the final counts. Stop after handoff; Task 4 starts only after this pull request is merged.

---

### Task 4: PR 4 — De-duplicate the human-facing root README

**Files:**

- Modify: `README.md:15-105,165-181,294-342,344-369,471-484,499-532`

**Interfaces:**

- Consumes: root `AGENTS.md`, `kubernetes/AGENTS.md`, `talos/AGENTS.md`, the final `docs/runbooks/` and `docs/phases/` paths, and the existing operator-facing recipe reference.
- Produces: a human onboarding README that links to agent constraints instead of restating them and retains operator procedures and repository orientation.

- [ ] **Step 1: Start from PR 3's merged baseline**

Fetch `origin`, base the assigned PR 4 branch on the `origin/main` containing PR 3, read the root and nested instruction files, and run:

```bash
mise exec -- just repo links-validate
```

Expected: pass before README edits.

- [ ] **Step 2: Replace duplicated development authority with an ownership pointer**

In `## Development workflow`, retain the human clone/branch/commit/push/PR example, hook installation explanation, CI description, and GitHub protection explanation. Remove prose that independently establishes agent authority already owned by `AGENTS.md`, including the duplicated no-self-merge and rollout-authority sentences. Replace the `### Agent-driven PR loop` policy prose with this pointer before the human/operator table:

```markdown
Binding agent authority, worktree, push, merge, validation, and rollout constraints
are defined in [`AGENTS.md`](AGENTS.md). The operator-facing division of labor is:
```

Keep the table because it is useful human onboarding, but word its rows descriptively and do not introduce a second source of agent permission.

- [ ] **Step 3: Remove raw-client and missing-recipe policy duplication**

In `## Mise Versus Just`, retain the explanation of mise versus Just and the command table. Replace the paragraph that permits direct `talosctl`, `kubectl`, `helm`, `flux`, or `sops` use with:

```markdown
Agents follow the pinned-tool and guarded-cluster boundaries in
[`AGENTS.md`](AGENTS.md). Operator procedures use the relevant guarded recipe or
the canonical file under [`docs/runbooks/`](docs/runbooks/).
```

The `docs/runbooks/` target is a directory, which the validator accepts because its Markdown existence test is `-e`. Task 1's acceptance case pins that behavior, so this link is safe to write as shown.

After the recipe table, remove the sentence that independently instructs agents to add a guarded workflow instead of an ad hoc apply; link to `AGENTS.md` if a transition sentence is needed.

- [ ] **Step 4: Replace the RWO rule with its scoped owner while preserving useful diagnosis**

Keep the symptom and cause explanation under `### ReadWriteOnce volumes require the Recreate deployment strategy`, because it is human troubleshooting context. Replace imperative source-policy wording with a direct ownership pointer:

```markdown
The binding workload rule is in
[`kubernetes/AGENTS.md`](kubernetes/AGENTS.md): a Deployment mounting a
`ReadWriteOnce` PVC uses `Recreate`, or the workload uses a StatefulSet.
```

Remove the raw `flux suspend`, `flux resume`, `kubectl`, deletion, and hand-reconciliation recovery paragraph. Point recovery work to the relevant guarded recipe/runbook; do not create a README exception to root's live-client constraint.

- [ ] **Step 5: Correct the immediate-post-push guidance**

Under `### Verifying right after a push`, remove the raw `flux reconcile` and `kubectl wait` commands. Retain the explanation that deployed-source verification can fail until Flux observes current `origin/main`, then direct the operator to guarded rollout/status procedures in `docs/runbooks/` and the recipe table. Keep links to Talos, Cilium, Flux, foundation, Pi-hole, and Portainer material, using their final `docs/runbooks/` or `docs/phases/` paths.

- [ ] **Step 6: De-duplicate normal-change policy**

In `## Normal Change Workflow`, retain the human sequence for choosing source files, running repository checks, inspecting status, committing, pushing, and opening a pull request. Replace universal secret, generated-file, guarded-command, main-boundary, and merge-authority statements with one link:

```markdown
Binding agent constraints for these steps are in [`AGENTS.md`](AGENTS.md), with
directory-specific constraints in the indexed nested instruction files.
```

- [ ] **Step 7: Preserve the explicitly human-facing material**

Confirm the README still contains all of the following after de-duplication:

- Prerequisites, first-clone steps, and shell setup.
- The full Just recipe reference.
- The confirmation safety model, including complete operator confirmation examples.
- Physical KVM notes and daily health orientation.
- Tool-version update procedure.
- Repository-boundary explanation, updated so `docs/runbooks/`, `docs/phases/`, root descriptive docs, `docs/superpowers/specs/`, and `plans/` have the ownership described by the approved design.
- Current-phase historical summary with links into `docs/phases/`.

The current README has no slot-creation, worktree-setup, or VS Code section. Do not
invent one in this PR. If one is added on `main` before PR 4 begins, preserve it as
operator-facing material. Do not remove operator material merely because it mentions
a command or constraint; remove only duplicated normative ownership.

- [ ] **Step 8: Scan for accidental normative duplication**

Run these focused searches and inspect every match:

```bash
mise exec -- rg -n 'never (merge|push|commit|run|apply|suspend)|must not|Do not bypass|Direct (kubectl|talosctl|helm|flux)|ReadWriteOnce.*(Recreate|RollingUpdate)' README.md
mise exec -- rg -n 'AGENTS\.md|docs/runbooks/|docs/phases/' README.md
```

Expected: remaining prohibitive language is operator safety explanation that does not compete with an `AGENTS.md`, and every removed agent rule has a resolvable ownership link.

- [ ] **Step 9: Validate PR 4**

Run:

```bash
mise exec -- just repo links-validate
mise exec -- just repo lint
mise exec -- just ci
```

Expected: all pass; no cluster-dependent command is run.

- [ ] **Step 10: Commit and hand off PR 4**

```bash
mise exec -- git add README.md
mise exec -- git commit -m "docs: separate agent rules from operator guidance"
```

Open a pull request titled `docs: separate agent rules from operator guidance`. Report which README sections were de-duplicated, which operator sections were deliberately retained, all validation actually run, and any remaining overlap that is explanatory rather than normative. Do not merge it.

---

## Final Acceptance

After the operator merges PR 4, a read-only verification from a clean `origin/main` checkout must establish:

```bash
mise exec -- just repo links-validate
mise exec -- just ci
mise exec -- git ls-files 'AGENTS.md' '*/AGENTS.md' docs/runbooks docs/phases docs/superpowers/specs | sort
```

Expected:

- Root plus exactly three scoped `AGENTS.md` files are tracked.
- `docs/runbooks/` contains 15 runbooks.
- `docs/phases/` contains 15 completed phase records.
- Root `docs/` retains `nuc-cluster.md`, `testing-layers.md`, `test-campaigns.md`, and `test-reports.md` as descriptive reference.
- The approved dated design spec remains under `docs/superpowers/specs/`.
- The superseded agent-instructions plan is absent; the other seven plans remain, with only the one dead reference in `plans/talos-validation-refactor-plan.md` repaired.
- Both validator failure fixtures remain tracked and the link suite remains in `executions.ci`.
- `docs/superpowers/` is the only excluded subtree, and it still names pre-move paths — that is expected, not a missed rewrite.
- `just ci` is green and no live cluster check or mutation was performed.
