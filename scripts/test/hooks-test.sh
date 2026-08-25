#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
pre_tool_use="$repo_root/scripts/hooks/pre-tool-use.sh"
session_start="$repo_root/scripts/hooks/session-start.sh"
pre_commit_hook="$repo_root/scripts/hooks/pre-commit.sh"
claude_settings="$repo_root/.claude/settings.json"
codex_hooks="$repo_root/.codex/hooks.json"
pre_commit_config="$repo_root/.pre-commit-config.yaml"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-hooks-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
minimal_path="$fixture/minimal-path"
mkdir -p "$minimal_path"
ln -s "$(command -v mise)" "$minimal_path/mise"
ln -s "$(command -v bash)" "$minimal_path/bash"

verify_recipe="$(mise exec -- just --dry-run repo verify 2>&1)"
rg -Fq 'scripts/test/hooks-test.sh' <<<"$verify_recipe" || {
  echo 'repo verify must run the agent and pre-commit hook regression suite.' >&2
  exit 1
}

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

registered_command() {
  local client="$1"
  local config="$2"
  local event="$3"
  local matcher="$4"
  local script="$5"
  local count

  [[ -f "$config" ]] || {
    echo "Missing $client hook registration: $config" >&2
    return 1
  }
  count="$(EVENT="$event" MATCHER="$matcher" SCRIPT="$script" yq -r '
    [.hooks[strenv(EVENT)][] |
      select((.matcher // "") == strenv(MATCHER)) |
      .hooks[] | select(
        .type == "command" and (.command | contains(strenv(SCRIPT)))
      )] | length
  ' "$config")"
  [[ "$count" == '1' ]] || {
    echo "$client must register exactly one $event command hook." >&2
    return 1
  }
  EVENT="$event" MATCHER="$matcher" SCRIPT="$script" yq -r '
    .hooks[strenv(EVENT)][] |
    select((.matcher // "") == strenv(MATCHER)) |
    .hooks[] | select(
      .type == "command" and (.command | contains(strenv(SCRIPT)))
    ) | .command
  ' "$config"
}

claude_pre_tool_command="$(
  registered_command Claude "$claude_settings" PreToolUse Bash \
    'scripts/hooks/pre-tool-use.sh'
)"
claude_session_command="$(
  registered_command Claude "$claude_settings" SessionStart '' \
    'scripts/hooks/session-start.sh'
)"
codex_pre_tool_command="$(
  registered_command Codex "$codex_hooks" PreToolUse Bash \
    'scripts/hooks/pre-tool-use.sh'
)"
codex_session_command="$(
  registered_command Codex "$codex_hooks" SessionStart '' \
    'scripts/hooks/session-start.sh'
)"

registered_hook_commands=(
  "$claude_pre_tool_command"
  "$claude_session_command"
  "$codex_pre_tool_command"
  "$codex_session_command"
)
for hook_command in "${registered_hook_commands[@]}"; do
  [[ "$hook_command" == 'mise exec -- '* ]] || {
    echo 'Registered agent hooks must enter the pinned mise environment.' >&2
    exit 1
  }
done

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

blocked=(
  'git reset --hard'
  'git reset --hard;'
  'git reset --hard && true'
  'mise exec -- git reset --hard'
  'git clean -fd'
  'git clean -df'
  'git clean -f -d'
  'git clean -xdf'
  'git clean -fd;'
  'git clean -xdf&&'
  'git clean -fx||'
  'git clean -df|'
  'git checkout .'
  'git checkout .;'
  'git checkout . | true'
  'git checkout . # discard changes'
  'git restore .'
  'git restore .;'
  'git restore . || true'
  'git push --force origin HEAD'
  'git push --force;'
  'git push --force && true'
  'git push -f origin HEAD'
  'git push -f'
  'git push -f;'
  'git push --force-with-lease --force origin HEAD'
)
allowed=(
  'git reset --soft HEAD^'
  'git clean -nfd'
  'git checkout -- AGENTS.md'
  'git restore AGENTS.md'
  'git push --force-with-lease origin HEAD'
  'mise exec -- git status --short'
  'git clean -f --exclude=-d'
  'git clean -f; git status -d'
  'git clean -f && git status -d'
  'git clean -f || git status -d'
  'git clean -f | git status -d'
  'git clean -f --exclude=foo; git status -d'
  'echo git reset --hard'
)

run_pre_tool_use() {
  COMMAND="$1" yq --null-input --output-format json \
    '{"tool_name":"Bash","tool_input":{"command":strenv(COMMAND)}}' \
    | "$pre_tool_use"
}

run_registered_pre_tool_use() {
  local hook_command="$1"
  local requested_command="$2"
  local working_directory="$3"
  COMMAND="$requested_command" yq --null-input --output-format json \
    '{"tool_name":"Bash","tool_input":{"command":strenv(COMMAND)}}' \
    | (cd "$working_directory" && bash -c "$hook_command")
}

run_registered_pre_tool_use_with_minimal_path() {
  local hook_command="$1"
  local requested_command="$2"
  local working_directory="$3"
  local payload
  payload="$(COMMAND="$requested_command" yq --null-input --output-format json \
    '{"tool_name":"Bash","tool_input":{"command":strenv(COMMAND)}}')"
  printf '%s\n' "$payload" \
    | (cd "$working_directory" && \
      PATH="$minimal_path:/usr/bin:/bin" /bin/bash -c "$hook_command")
}

run_registered_session_with_minimal_path() {
  local hook_command="$1"
  local working_directory="$2"
  (
    cd "$working_directory"
    PATH="$minimal_path:/usr/bin:/bin" /bin/bash -c "$hook_command"
  )
}

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

for command in "${blocked[@]}"; do
  output="$fixture/blocked-${RANDOM}.log"
  if run_pre_tool_use "$command" >"$output" 2>&1; then
    echo "Expected blocked command to exit 2: $command" >&2
    exit 1
  else
    status=$?
  fi
  if [[ "$status" -ne 2 ]]; then
    echo "Blocked command exited $status instead of 2: $command" >&2
    exit 1
  fi
  rg -q 'Denied irreversible git command' "$output" || {
    echo "Blocked command did not report a denial: $command" >&2
    exit 1
  }
done

for command in "${allowed[@]}"; do
  output="$fixture/allowed-${RANDOM}.log"
  if ! run_pre_tool_use "$command" >"$output" 2>&1; then
    echo "Allowed command was denied: $command" >&2
    exit 1
  fi
done

codex_nested_output="$fixture/codex-nested-denial.log"
if run_registered_pre_tool_use "$codex_pre_tool_command" 'git reset --hard' \
  "$repo_root/scripts/test" >"$codex_nested_output" 2>&1; then
  echo 'Codex hook did not block an irreversible command from a nested directory.' >&2
  exit 1
else
  status=$?
fi
[[ "$status" -eq 2 ]] || {
  echo "Codex nested-directory hook exited $status instead of 2." >&2
  exit 1
}
rg -q 'Denied irreversible git command' "$codex_nested_output"
run_registered_pre_tool_use "$codex_pre_tool_command" 'git status --short' \
  "$repo_root/scripts/test" >/dev/null

for registered_pre_tool_command in \
  "$claude_pre_tool_command" "$codex_pre_tool_command"; do
  run_registered_pre_tool_use_with_minimal_path "$registered_pre_tool_command" \
    'git status --short' "$repo_root/scripts/test" >/dev/null
done

for registered_session_command in \
  "$claude_session_command" "$codex_session_command"; do
  run_registered_session_with_minimal_path "$registered_session_command" \
    "$repo_root/scripts/test" | rg -q '^(worktree|main clone) · branch .+ · '
done


run_pre_commit_entry_with_minimal_path "$gitleaks_entry"
run_pre_commit_entry_with_minimal_path "$sops_entry"
run_pre_commit_hook_with_minimal_path

codex_session_output="$fixture/codex-session.log"
(
  cd "$repo_root/scripts/test"
  bash -c "$codex_session_command"
) >"$codex_session_output" 2>&1
rg -q '^(worktree|main clone) · branch .+ · ' "$codex_session_output" || {
  echo 'Codex SessionStart registration did not resolve from a nested directory.' >&2
  exit 1
}

main_clone="$fixture/main-clone"
worktree="$fixture/worktree"
git init --quiet --initial-branch challenge-agent-rules "$main_clone"
mkdir -p "$worktree/.kube"

run_session_start() {
  (
    cd "$worktree"
    GIT_DIR="$main_clone/.git" GIT_WORK_TREE="$worktree" "$session_start"
  )
}

session_output="$fixture/session-none.log"
run_session_start >"$session_output" 2>&1
rg -q 'worktree · branch challenge-agent-rules · no cluster credentials' "$session_output"

printf '%s\n' \
  'apiVersion: v1' \
  'contexts:' \
  '  - name: homelab-observer' \
  'current-context: homelab-observer' >"$worktree/.kube/config"
session_output="$fixture/session-observer.log"
run_session_start >"$session_output" 2>&1
rg -q 'observer credentials' "$session_output"

printf '%s\n' \
  'apiVersion: v1' \
  'contexts:' \
  '  - name: homelab-diagnostic' \
  'current-context: homelab-diagnostic' >"$worktree/.kube/config"
session_output="$fixture/session-diagnostic.log"
run_session_start >"$session_output" 2>&1
rg -q 'diagnostic credentials' "$session_output"

printf '%s\n' \
  'apiVersion: v1' \
  'contexts:' \
  '  - name: homelab-observer' \
  '  - name: homelab-diagnostic' \
  'current-context: homelab-observer' >"$worktree/.kube/config"
session_output="$fixture/session-both-contexts.log"
run_session_start >"$session_output" 2>&1
rg -q 'observer credentials · diagnostic credentials' "$session_output" || {
  echo 'Session hook did not report both recognized credential contexts.' >&2
  exit 1
}

printf '%s\n' 'contexts: [' >"$worktree/.kube/config"
session_output="$fixture/session-unreadable.log"
if ! run_session_start >"$session_output" 2>&1; then
  echo 'Session hook blocked on an unreadable kubeconfig.' >&2
  exit 1
fi
rg -q 'cluster credentials with unreadable contexts' "$session_output"

main_session="$fixture/session-main-absent.log"
(
  cd "$main_clone"
  "$session_start"
) >"$main_session" 2>&1
rg -q 'main clone · branch challenge-agent-rules · admin credentials unavailable' "$main_session" || {
  echo 'Main clone reported admin credentials without a Talos config.' >&2
  exit 1
}

mkdir -p "$main_clone/.talos"
printf '%s\n' 'contexts: {}' >"$main_clone/.talos/config"
main_session="$fixture/session-main-present.log"
(
  cd "$main_clone"
  "$session_start"
) >"$main_session" 2>&1
rg -q 'admin credentials in effect' "$main_session"

fake_age_key='FAKE-AGE-KEY-MUST-NOT-APPEAR'
fake_age_key_file='FAKE-AGE-KEY-FILE-MUST-NOT-APPEAR'
sops_session="$fixture/session-sops.log"
SOPS_AGE_KEY="$fake_age_key" SOPS_AGE_KEY_FILE="$fake_age_key_file" \
  run_session_start >"$sops_session" 2>&1
rg -q 'WARNING: SOPS key material is present in the session environment' "$sops_session"
if rg -q "$fake_age_key|$fake_age_key_file" "$sops_session"; then
  echo 'Session hook exposed a SOPS environment value.' >&2
  exit 1
fi

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

echo 'Claude and Codex hook command and session visibility checks passed.'
