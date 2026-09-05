#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
pre_commit_hook="$repo_root/scripts/hooks/pre-commit.sh"
pre_commit_config="$repo_root/.pre-commit-config.yaml"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-hooks-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
minimal_path="$fixture/minimal-path"
mkdir -p "$minimal_path"
ln -s "$(command -v mise)" "$minimal_path/mise"
ln -s "$(command -v bash)" "$minimal_path/bash"

validate_recipe="$(mise exec -- just --dry-run repo validate 2>&1)"
rg -Fq 'scripts/test/hooks-test.sh' <<<"$validate_recipe" || {
  echo 'repo validate must run the repository hook and policy regression suite.' >&2
  exit 1
}
if mise exec -- just --dry-run repo verify >/dev/null 2>&1; then
  echo 'Deprecated repo verify command still exists.' >&2
  exit 1
fi
if mise exec -- just --dry-run repo verify-files >/dev/null 2>&1; then
  echo 'Deprecated repo verify-files command still exists.' >&2
  exit 1
fi

unsupported_agent_hooks=(
  "$repo_root/.claude/settings.json"
  "$repo_root/.codex/hooks.json"
  "$repo_root/scripts/hooks/pre-tool-use.sh"
  "$repo_root/scripts/hooks/session-start.sh"
)
for unsupported_agent_hook in "${unsupported_agent_hooks[@]}"; do
  [[ ! -e "$unsupported_agent_hook" ]] || {
    echo "Ambient agent runtime hook must not be tracked: $unsupported_agent_hook" >&2
    exit 1
  }
done

[[ -x "$pre_commit_hook" ]] || {
  echo 'The tracked pre-commit launcher must exist and be executable.' >&2
  exit 1
}
hooks_recipe="$(mise exec -- just --dry-run repo hooks 2>&1)"
rg -Fq 'install -m 0755 scripts/hooks/pre-commit.sh "$hooks_dir/pre-commit"' \
  <<<"$hooks_recipe" || {
  echo 'repo hooks must install the tracked mise-backed pre-commit launcher.' >&2
  exit 1
}

registered_pre_commit_entry() {
  local hook_id="$1"
  local count
  local entry
  count="$(HOOK_ID="$hook_id" yq -r '
    [.repos[].hooks[] | select(.id == strenv(HOOK_ID))] | length
  ' "$pre_commit_config")"
  [[ "$count" == '1' ]] || {
    echo "pre-commit must register exactly one $hook_id hook." >&2
    return 1
  }
  entry="$(HOOK_ID="$hook_id" yq -r '
    .repos[].hooks[] | select(.id == strenv(HOOK_ID)) | .entry
  ' "$pre_commit_config")"
  printf '%s\n' "$entry"
}

gitleaks_entry="$(registered_pre_commit_entry gitleaks-staged)"
sops_entry="$(registered_pre_commit_entry sops-encrypted)"
for pre_commit_entry in "$gitleaks_entry" "$sops_entry"; do
  [[ "$pre_commit_entry" == 'mise exec -- '* ]] || {
    echo 'Local pre-commit hooks must enter the pinned mise environment.' >&2
    exit 1
  }
done

run_pre_commit_entry_with_minimal_path() {
  local entry="$1"
  (
    cd "$repo_root"
    PATH="$minimal_path:/usr/bin:/bin" /bin/bash -c "$entry"
  )
}

run_pre_commit_hook_with_minimal_path() {
  local test_index="$fixture/pre-commit-index"
  GIT_INDEX_FILE="$test_index" git read-tree HEAD
  GIT_INDEX_FILE="$test_index" git add -A
  (
    cd "$repo_root"
    GIT_INDEX_FILE="$test_index" PATH="$minimal_path:/usr/bin:/bin" \
      "$pre_commit_hook"
  )
}

run_pre_commit_entry_with_minimal_path "$gitleaks_entry"
run_pre_commit_entry_with_minimal_path "$sops_entry"
run_pre_commit_hook_with_minimal_path

secret_scan_repo="$fixture/secret-scan-repository"
secret_scan_output="$fixture/secret-scan-output.log"
mkdir -p "$secret_scan_repo/invoke"
git -C "$secret_scan_repo" init --quiet --initial-branch=candidate
git -C "$secret_scan_repo" config user.email tests@example.invalid
git -C "$secret_scan_repo" config user.name 'Repository Secret Scan Test'
printf '%s\n' safe >"$secret_scan_repo/candidate.txt"
git -C "$secret_scan_repo" add candidate.txt
git -C "$secret_scan_repo" commit --quiet -m candidate
candidate_commit="$(git -C "$secret_scan_repo" rev-parse HEAD)"
git -C "$secret_scan_repo" switch --quiet --orphan unrelated
fixture_credential="$(printf '\147\154\160\141\164\055%s%s' 'A1b2C3d4E5' 'f6G7h8I9j0')"
printf '%s\n' "$fixture_credential" >"$secret_scan_repo/unrelated.txt"
git -C "$secret_scan_repo" add unrelated.txt
git -C "$secret_scan_repo" commit --quiet -m unrelated
git -C "$secret_scan_repo" switch --quiet --detach "$candidate_commit"

run_repository_secret_scan() {
  mise exec -- just --justfile "$repo_root/.just/repository.just" \
    --working-directory "$secret_scan_repo/invoke" secret-scan
}

if ! run_repository_secret_scan >"$secret_scan_output" 2>&1; then
  echo 'Repository secret scan must ignore findings reachable only from unrelated refs.' >&2
  sed -n '1,80p' "$secret_scan_output" >&2
  exit 1
fi

printf '%s\n' "$fixture_credential" >"$secret_scan_repo/reachable.txt"
git -C "$secret_scan_repo" add reachable.txt
git -C "$secret_scan_repo" commit --quiet -m reachable
if run_repository_secret_scan >"$secret_scan_output" 2>&1; then
  echo 'Repository secret scan accepted a finding in HEAD ancestry.' >&2
  exit 1
fi
rg -q 'leaks found: 1' "$secret_scan_output" || {
  echo 'Repository secret scan did not report the reachable synthetic finding.' >&2
  sed -n '1,80p' "$secret_scan_output" >&2
  exit 1
}

tracked_agent_files="$(
  mise exec -- git -C "$repo_root" ls-files -- 'AGENTS.md' '**/AGENTS.md'
)"
if [[ "$tracked_agent_files" != 'AGENTS.md' ]]; then
  echo 'AGENTS.md must remain the sole tracked repository-rule surface.' >&2
  printf '%s\n' "$tracked_agent_files" >&2
  exit 1
fi

required_agent_headings=(
  'Repository context'
  'Communication style'
  'Git and worktrees'
  'Authority boundaries'
  'Agent orchestration'
  'Secrets and credentials'
  'Public repository'
  'Repository invariants'
  'Design lifecycle'
  'Validation'
  'Completion'
)
mapfile -t actual_agent_headings < <(sed -n 's/^## //p' "$repo_root/AGENTS.md")
previous_heading_index=-1
for required_heading in "${required_agent_headings[@]}"; do
  heading_count=0
  heading_index=-1
  for index in "${!actual_agent_headings[@]}"; do
    if [[ "${actual_agent_headings[$index]}" == "$required_heading" ]]; then
      ((heading_count += 1))
      heading_index="$index"
    fi
  done
  if ((heading_count != 1 || heading_index <= previous_heading_index)); then
    echo 'AGENTS.md canonical semantic sections must each appear once and in order.' >&2
    printf 'Required sections:\n' >&2
    printf '  %s\n' "${required_agent_headings[@]}" >&2
    printf 'Actual sections:\n' >&2
    printf '  %s\n' "${actual_agent_headings[@]}" >&2
    exit 1
  fi
  previous_heading_index="$heading_index"
done

if rg -q '\[(Authoritative —|Operator policy — operator|Gotcha)\]' "$repo_root/AGENTS.md"; then
  echo 'AGENTS.md must not expose design-time provenance labels.' >&2
  exit 1
fi

rg -qx '@AGENTS.md' "$repo_root/CLAUDE.md" || {
  echo 'CLAUDE.md must import AGENTS.md.' >&2
  exit 1
}
rg -q '^## Claude Code specifics$' "$repo_root/CLAUDE.md" || {
  echo 'CLAUDE.md must retain the Claude-specific operating heading.' >&2
  exit 1
}
if rg -q 'SOPS-encrypted|Never push|ReadWriteOnce' "$repo_root/CLAUDE.md"; then
  echo 'CLAUDE.md must not repeat repository rules from AGENTS.md.' >&2
  exit 1
fi

echo 'Git hook and agent policy checks passed.'
