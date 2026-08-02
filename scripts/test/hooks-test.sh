#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
pre_tool_use="$repo_root/scripts/hooks/pre-tool-use.sh"
session_start="$repo_root/scripts/hooks/session-start.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-hooks-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

blocked=(
  'git reset --hard'
  'git reset --hard;'
  'git reset --hard && true'
  'mise exec -- git reset --hard'
  'git clean -fd'
  'git clean -df'
  'git clean -f -d'
  'git clean -xdf'
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
  'echo git reset --hard'
)

run_pre_tool_use() {
  COMMAND="$1" yq --null-input --output-format json \
    '{"tool_name":"Bash","tool_input":{"command":strenv(COMMAND)}}' \
    | "$pre_tool_use"
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

echo 'Claude hook command and session visibility checks passed.'
