#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(git rev-parse --show-toplevel)}"
cd "$repo_root"

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

while IFS= read -r -d '' source; do
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
  done < <(
    rg --line-number --no-heading --only-matching \
      --replace '$1' \
      '!?\[[^\]\[]*\]\((<?[^()[:space:]>]+>?)(?:[[:space:]]+"[^"]*")?\)' \
      "$source" || true
  )
done < <(git ls-files -z '*.md' "$exclude_spec")

bare_pattern='(?<![\w$/{}.-])(?:(?:docs|plans)/[A-Za-z0-9._/-]+\.md|(?:[A-Za-z0-9._-]+/)+(?:README|AGENTS)\.md)'
while IFS= read -r -d '' source; do
  while IFS=: read -r line target; do
    [[ -n "$target" ]] || continue
    resolved="$target"
    case "$target" in
      ./*|../*) resolved="$(dirname "$source")/$target" ;;
    esac
    if [[ ! -f "$resolved" ]]; then
      report_failure "$source" "$line" 'missing bare path target' "$target"
    fi
  done < <(
    rg --line-number --no-heading --only-matching --pcre2 \
      "$bare_pattern" "$source" 2>/dev/null || true
  )
done < <(git ls-files -z "$exclude_spec")

if ((failed != 0)); then
  exit 1
fi

echo 'Tracked Markdown links and bare repository paths resolve.'
