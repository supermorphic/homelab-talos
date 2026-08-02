#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
preflight="$repo_root/scripts/test/scoped-campaign-preflight.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/scoped-preflight-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
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
chmod +x "$fixture/bin/git" "$fixture/bin/kubectl" "$fixture/bin/talosctl"

write_kubeconfig_view() {
  local variant="$1"
  yq --null-input --output-format json -I=0 '
    {
      "current-context": "homelab-observer",
      "clusters": [{"name": "homelab", "cluster": {"server": "https://cluster"}}],
      "contexts": [
        {"name": "homelab-observer", "context": {"cluster": "homelab", "user": "homelab-observer"}},
        {"name": "homelab-diagnostic", "context": {"cluster": "homelab", "user": "homelab-diagnostic"}}
      ],
      "users": [
        {"name": "homelab-observer", "user": {"token": "observer-token"}},
        {"name": "homelab-diagnostic", "user": {"token": "diagnostic-token"}}
      ]
    }
  ' >"$fixture/kubeconfig-view.json"
  case "$variant" in
    valid) ;;
    admin)
      yq -i '.contexts += [{"name": "homelab-admin", "context": {"cluster": "homelab", "user": "homelab-admin"}}] |
        .users += [{"name": "homelab-admin", "user": {"client-certificate-data": "admin"}}]' \
        "$fixture/kubeconfig-view.json"
      ;;
    missing-diagnostic)
      yq -i '.contexts = [.contexts[] | select(.name != "homelab-diagnostic")] |
        .users = [.users[] | select(.name != "homelab-diagnostic")]' \
        "$fixture/kubeconfig-view.json"
      ;;
    wrong-current)
      yq -i '."current-context" = "homelab-diagnostic"' \
        "$fixture/kubeconfig-view.json"
      ;;
  esac
}

run_preflight() {
  PATH="$fixture/bin:$PATH" \
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

write_kubeconfig_view valid
run_preflight

expect_failure main-clone 'linked Git worktree' env FAKE_GIT_LAYOUT=main \
  PATH="$fixture/bin:$PATH" FAKE_WORKTREE="$worktree" \
  FAKE_COMMON_DIR="$fixture/common" FAKE_KUBECONFIG_VIEW="$fixture/kubeconfig-view.json" \
  "$preflight" "$worktree" "$worktree/.kube/config" "$worktree/.talos/config"

write_kubeconfig_view admin
expect_failure admin-kubeconfig 'exactly the scoped observer and diagnostic' run_preflight
write_kubeconfig_view missing-diagnostic
expect_failure missing-diagnostic 'exactly the scoped observer and diagnostic' run_preflight
write_kubeconfig_view wrong-current
expect_failure wrong-current 'current context must be homelab-observer' run_preflight
write_kubeconfig_view valid
expect_failure wrong-reader 'Talos credential must have exactly the os:reader role' env \
  FAKE_TALOS_ROLE=os:admin PATH="$fixture/bin:$PATH" FAKE_WORKTREE="$worktree" \
  FAKE_COMMON_DIR="$fixture/common" FAKE_KUBECONFIG_VIEW="$fixture/kubeconfig-view.json" \
  "$preflight" "$worktree" "$worktree/.kube/config" "$worktree/.talos/config"

chmod 644 "$worktree/.kube/config"
expect_failure kube-mode 'mode 0600' run_preflight
chmod 600 "$worktree/.kube/config"
chmod 644 "$worktree/.talos/config"
expect_failure talos-mode 'mode 0600' run_preflight

echo 'Scoped campaign credential and worktree preflight tests passed.'
