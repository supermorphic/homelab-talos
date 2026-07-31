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
  local value="$1"
  local index character
  local backslash='\'
  local result=''

  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    if [[ "$character" == "$backslash" && $((index + 1)) -lt ${#value} ]]; then
      ((index += 1))
      character="${value:index:1}"
    elif [[ "$character" == '#' || "$character" == '?' ]]; then
      break
    fi
    result+="$character"
  done
  printf '%s' "$result"
}

canonical_path() {
  local path="$1"
  local link parent

  while [[ -L "$path" ]]; do
    link="$(readlink "$path")"
    if [[ "$link" == /* ]]; then
      path="$link"
    else
      path="$(dirname "$path")/$link"
    fi
  done
  parent="$(cd "$(dirname "$path")" && pwd -P)"
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}

is_local_path() {
  local path="$1"
  local canonical

  canonical="$(canonical_path "$path")"
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

    path="$(unescape_destination "$target")"
    [[ -n "$path" ]] || continue
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

markdown_pattern="!?\\[[^\\]\\[]*\\]\\((<[^<>]*>|(?<destination>(?:\\\\.|[^()[:space:]>]|\\((?&destination)\\))+))(?:[[:space:]]+(\"[^\"]*\"|'[^']*'|\\((?:\\\\.|[^()])*\\)))?\\)"
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
