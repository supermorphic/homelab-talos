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

scan_markdown() {
  local source="$1"
  local line target path matches status

  if matches="$(
    rg --line-number --no-heading --only-matching \
      --replace '$1' \
      '!?\[[^\]\[]*\]\((<[^<>]*>|[^()[:space:]>]+)(?:[[:space:]]+"[^"]*")?\)' \
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
    if [[ ! -e "$(dirname "$source")/$path" ]]; then
      report_failure "$source" "$line" 'missing Markdown link target' "$target"
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
    fi
  done <<<"$matches"
}

markdown_paths="$(mktemp)"
bare_paths="$(mktemp)"
trap 'rm -f "$markdown_paths" "$bare_paths"' EXIT

git ls-files -z '*.md' "$exclude_spec" >"$markdown_paths"
while IFS= read -r -d '' source; do
  scan_markdown "$source"
done <"$markdown_paths"

bare_pattern='(?<![\w$/{}.-])(?:(?:docs|plans)/[A-Za-z0-9._/-]+\.md|(?:[A-Za-z0-9._-]+/)+(?:README|AGENTS)\.md)(?![A-Za-z0-9._/-])'
git ls-files -z "$exclude_spec" >"$bare_paths"
while IFS= read -r -d '' source; do
  scan_bare_path "$source"
done <"$bare_paths"

if ((failed != 0)); then
  exit 1
fi

echo 'Tracked Markdown links and bare repository paths resolve.'
