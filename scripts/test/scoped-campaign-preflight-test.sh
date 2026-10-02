#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
preflight="$repo_root/scripts/test/scoped-campaign-preflight.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/scoped-preflight-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
real_stat="$(command -v stat)"
worktree="$fixture/worktree"
mkdir -p "$fixture/bin" "$fixture/common/worktrees/scoped" \
  "$worktree/.kube" "$worktree/.talos"
touch "$worktree/.kube/config" "$worktree/.talos/config"
chmod 600 "$worktree/.kube/config" "$worktree/.talos/config"

cat >"$fixture/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -C && "$2" == "$FAKE_WORKTREE" && "$3" == rev-parse ]] || exit 64
case "$4" in
  --show-toplevel) printf '%s\n' "$FAKE_WORKTREE" ;;
  --path-format=absolute)
    case "$5" in
      --git-dir)
        if [[ "${FAKE_GIT_LAYOUT:-linked}" == linked ]]; then
          printf '%s\n' "$FAKE_COMMON_DIR/worktrees/scoped"
        else
          printf '%s\n' "$FAKE_WORKTREE/.git"
        fi
        ;;
      --git-common-dir)
        if [[ "${FAKE_GIT_LAYOUT:-linked}" == linked ]]; then
          printf '%s\n' "$FAKE_COMMON_DIR"
        else
          printf '%s\n' "$FAKE_WORKTREE/.git"
        fi
        ;;
      *) exit 64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
EOF

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "--kubeconfig $FAKE_WORKTREE/.kube/config config view --raw --output json" ]] || {
  echo "Unexpected fake kubectl invocation: $*" >&2
  exit 64
}
cat "$FAKE_KUBECONFIG_VIEW"
EOF

cat >"$fixture/bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "config info --talosconfig $FAKE_WORKTREE/.talos/config --output json" ]] || {
  echo "Unexpected fake talosctl invocation: $*" >&2
  exit 64
}
printf '{"Context":"homelab","Roles":["%s"]}\n' "${FAKE_TALOS_ROLE:-os:reader}"
EOF

cat >"$fixture/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 3 ]] || exit 64
case "$1 $2" in
  '-f %Lp')
    # GNU stat accepts -f but interprets it as filesystem output, so a
    # BSD-first fallback can succeed without returning the file mode.
    printf 'gnu-filesystem-output\n'
    ;;
  '-c %a')
    if "$REAL_STAT" -c '%a' "$3" >/dev/null 2>&1; then
      exec "$REAL_STAT" -c '%a' "$3"
    fi
    exec "$REAL_STAT" -f '%Lp' "$3"
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$fixture/bin/git" "$fixture/bin/kubectl" "$fixture/bin/talosctl" \
  "$fixture/bin/stat"

# The canonical validator has its own file/layout tests. This fixture proves
# preflight invokes it and stops when it rejects a credential.
cat >"$fixture/bin/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "run --locked --no-dev python -m scripts.openbao.credentials validate $FAKE_WORKTREE/.kube/config" ]] || exit 64
printf 'validated\n' >"$FAKE_WORKTREE/validation-called"
[[ "${FAKE_CREDENTIAL_VALID:-true}" == true ]]
EOF
chmod +x "$fixture/bin/uv"
write_kubeconfig_view() {
  printf '{"current-context":"%s"}\n' "$1" >"$fixture/kubeconfig-view.json"
}

run_preflight() {
  PATH="$fixture/bin:$PATH" \
  REAL_STAT="$real_stat" \
  FAKE_WORKTREE="$worktree" \
  FAKE_COMMON_DIR="$fixture/common" \
  FAKE_KUBECONFIG_VIEW="$fixture/kubeconfig-view.json" \
    "$preflight" "$worktree" "$worktree/.kube/config" "$worktree/.talos/config"
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  if "$@" >"$fixture/$name.out" 2>&1; then
    echo "$name preflight unexpectedly passed." >&2
    exit 1
  fi
  rg -q "$expected" "$fixture/$name.out"
}

write_kubeconfig_view homelab-observer
run_preflight

expect_failure main-clone 'linked Git worktree' env FAKE_GIT_LAYOUT=main \
  PATH="$fixture/bin:$PATH" REAL_STAT="$real_stat" FAKE_WORKTREE="$worktree" \
  FAKE_COMMON_DIR="$fixture/common" FAKE_KUBECONFIG_VIEW="$fixture/kubeconfig-view.json" \
  "$preflight" "$worktree" "$worktree/.kube/config" "$worktree/.talos/config"

[[ -f "$worktree/validation-called" ]]
expect_failure invalid-credential 'canonical scoped Kubernetes credential' env \
  FAKE_CREDENTIAL_VALID=false PATH="$fixture/bin:$PATH" REAL_STAT="$real_stat" \
  FAKE_WORKTREE="$worktree" FAKE_COMMON_DIR="$fixture/common" \
  FAKE_KUBECONFIG_VIEW="$fixture/kubeconfig-view.json" \
  "$preflight" "$worktree" "$worktree/.kube/config" "$worktree/.talos/config"
write_kubeconfig_view homelab-diagnostic
expect_failure wrong-current 'current context must be homelab-observer' run_preflight
write_kubeconfig_view homelab-observer
expect_failure wrong-reader 'Talos credential must have exactly the os:reader role' env \
  FAKE_TALOS_ROLE=os:admin PATH="$fixture/bin:$PATH" REAL_STAT="$real_stat" \
  FAKE_WORKTREE="$worktree" \
  FAKE_COMMON_DIR="$fixture/common" FAKE_KUBECONFIG_VIEW="$fixture/kubeconfig-view.json" \
  "$preflight" "$worktree" "$worktree/.kube/config" "$worktree/.talos/config"

chmod 644 "$worktree/.kube/config"
expect_failure kube-mode 'mode 0600' run_preflight
chmod 600 "$worktree/.kube/config"
chmod 644 "$worktree/.talos/config"
expect_failure talos-mode 'mode 0600' run_preflight

echo 'Scoped campaign credential and worktree preflight tests passed.'
