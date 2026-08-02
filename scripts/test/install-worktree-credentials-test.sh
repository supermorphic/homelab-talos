#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
installer="$repo_root/scripts/repository/install-worktree-credentials.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/install-worktree-credentials-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

fake_bin="$fixture/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'rev-parse --show-toplevel') printf '%s\n' "$FAKE_WORKTREE_ROOT" ;;
  'rev-parse --path-format=absolute --git-common-dir') printf '%s\n' "$FAKE_GIT_COMMON_DIR" ;;
  *) echo "unexpected fake git arguments: $*" >&2; exit 64 ;;
esac
EOF

cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

kubeconfig=''
args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
  if [[ "${args[$index]}" == '--kubeconfig' ]]; then
    kubeconfig="${args[$((index + 1))]}"
  fi
done

if [[ " $* " == *' create token homelab-observer '* ]]; then
  [[ "${FAKE_FAIL_STAGE:-}" != 'observer-token' ]] || exit 71
  printf '%s\n' 'fake-observer-token'
  exit 0
fi
if [[ " $* " == *' create token homelab-diagnostic '* ]]; then
  [[ "${FAKE_FAIL_STAGE:-}" != 'diagnostic-token' ]] || exit 72
  printf '%s\n' 'fake-diagnostic-token'
  exit 0
fi

if [[ " $* " == *' config view '* ]]; then
  case "$*" in
    *'jsonpath={.clusters[0].cluster.server}'*)
      yq -r '.clusters[0].cluster.server' "$kubeconfig"
      ;;
    *'jsonpath={.clusters[0].cluster.certificate-authority-data}'*)
      yq -r '.clusters[0].cluster.certificate-authority-data' "$kubeconfig"
      ;;
    *'jsonpath={.current-context}'*)
      yq -r '.current-context' "$kubeconfig"
      ;;
    *'jsonpath={range .contexts[*]}{.name}{"\n"}{end}'*)
      yq -r '.contexts[].name' "$kubeconfig"
      ;;
    *'jsonpath={range .users[*]}{.name}{"\n"}{end}'*)
      yq -r '.users[].name' "$kubeconfig"
      ;;
    *'jsonpath={.users[?(@.name == "homelab-observer")].user.token}'*)
      yq -r '.users[] | select(.name == "homelab-observer") | .user.token' "$kubeconfig"
      ;;
    *'jsonpath={.users[?(@.name == "homelab-diagnostic")].user.token}'*)
      yq -r '.users[] | select(.name == "homelab-diagnostic") | .user.token' "$kubeconfig"
      ;;
    *)
      echo "unexpected fake kubectl config query: $*" >&2
      exit 65
      ;;
  esac
  exit 0
fi

echo "unexpected fake kubectl arguments: $*" >&2
exit 64
EOF

cat >"$fake_bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

case "${1:-} ${2:-}" in
  'kubeconfig '*)
    output="$2"
    cat >"$output" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: https://192.168.90.20:6443
      certificate-authority-data: ZmFrZS1jYQ==
contexts:
  - name: homelab-admin
    context:
      cluster: homelab
      user: homelab-admin
current-context: homelab-admin
users:
  - name: homelab-admin
    user:
      token: fake-admin-token
YAML
    ;;
  'config new')
    [[ "${FAKE_FAIL_STAGE:-}" != 'talos-new' ]] || exit 73
    output="$3"
    cat >"$output" <<'YAML'
context: homelab-reader
contexts:
  homelab-reader:
    endpoints:
      - 192.168.90.10
      - 192.168.90.11
      - 192.168.90.12
    ca: ZmFrZS1jYQ==
    crt: ZmFrZQ==
    key: ZmFrZQ==
YAML
    ;;
  *)
    echo "unexpected fake talosctl arguments: $*" >&2
    exit 64
    ;;
esac
EOF

chmod +x "$fake_bin/git" "$fake_bin/kubectl" "$fake_bin/talosctl"

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

make_main_credentials() {
  local main_root="$1"
  mkdir -p "$main_root/.git" "$main_root/.kube" "$main_root/.talos"
  cat >"$main_root/.kube/config" <<'YAML'
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: https://192.168.90.20:6443
      certificate-authority-data: bWFpbi1jYS1kYXRh
contexts:
  - name: homelab-admin
    context:
      cluster: homelab
      user: homelab-admin
current-context: homelab-admin
users:
  - name: homelab-admin
    user:
      token: main-admin-token-must-not-be-copied
YAML
  printf '%s\n' 'main-admin-talosconfig' >"$main_root/.talos/config"
}

run_installer() {
  local worktree_root="$1"
  local main_root="$2"
  shift 2
  env \
    GIT_BIN="$fake_bin/git" \
    KUBECTL_BIN="$fake_bin/kubectl" \
    TALOSCTL_BIN="$fake_bin/talosctl" \
    FAKE_WORKTREE_ROOT="$worktree_root" \
    FAKE_GIT_COMMON_DIR="$main_root/.git" \
    FAKE_CALL_LOG="$worktree_root/calls.log" \
    "$@" \
    "$installer"
}

# The main-clone recipe must retain the Talos-admin kubeconfig download behavior.
main_case="$fixture/main-path"
make_main_credentials "$main_case"
mkdir -p \
  "$main_case/talos" \
  "$main_case/.just" \
  "$main_case/kubernetes" \
  "$main_case/tests" \
  "$main_case/scripts/lib" \
  "$main_case/scripts/repository"
cp "$repo_root/.justfile" "$main_case/.justfile"
cp "$repo_root/talos/mod.just" "$main_case/talos/mod.just"
cp "$repo_root/.just/repository.just" "$main_case/.just/repository.just"
cp "$repo_root/.just/bootstrap.just" "$main_case/.just/bootstrap.just"
cp "$repo_root/kubernetes/mod.just" "$main_case/kubernetes/mod.just"
cp "$repo_root/tests/mod.just" "$main_case/tests/mod.just"
cp "$repo_root/scripts/lib/common.sh" "$main_case/scripts/lib/common.sh"
[[ ! -e "$installer" ]] || cp "$installer" "$main_case/scripts/repository/install-worktree-credentials.sh"
: >"$main_case/calls.log"
main_case_alias="$fixture/main-path-alias"
ln -s "$main_case" "$main_case_alias"
env \
  GIT_BIN="$fake_bin/git" \
  KUBECTL_BIN="$fake_bin/kubectl" \
  TALOSCTL_BIN="$fake_bin/talosctl" \
  FAKE_WORKTREE_ROOT="$main_case_alias" \
  FAKE_GIT_COMMON_DIR="$main_case/.git" \
  FAKE_CALL_LOG="$main_case/calls.log" \
  just --justfile "$main_case/.justfile" talos kubeconfig >/dev/null
[[ "$(yq -r '.current-context' "$main_case/.kube/config")" == 'homelab-admin' ]]
rg -q '^kubeconfig ' "$main_case/calls.log"
if rg -q '^config new ' "$main_case/calls.log"; then
  echo 'Main-clone recipe minted scoped worktree credentials.' >&2
  exit 1
fi

# The same recipe must delegate linked worktrees to the scoped installer.
recipe_worktree="$fixture/recipe-worktree"
mkdir -p "$recipe_worktree"
: >"$recipe_worktree/calls.log"
env \
  GIT_BIN="$fake_bin/git" \
  KUBECTL_BIN="$fake_bin/kubectl" \
  TALOSCTL_BIN="$fake_bin/talosctl" \
  FAKE_WORKTREE_ROOT="$recipe_worktree" \
  FAKE_GIT_COMMON_DIR="$main_case/.git" \
  FAKE_CALL_LOG="$recipe_worktree/calls.log" \
  just --justfile "$main_case/.justfile" talos kubeconfig >/dev/null
[[ "$(yq -r '.current-context' "$recipe_worktree/.kube/config")" == 'homelab-observer' ]]
rg -q '^config new ' "$recipe_worktree/calls.log"

# Missing either main-clone credential refuses before creating worktree outputs.
for missing in kube talos; do
  case_root="$fixture/missing-$missing"
  main_root="$case_root/main"
  worktree_root="$case_root/worktree"
  make_main_credentials "$main_root"
  mkdir -p "$worktree_root"
  rm -f -- "$main_root/.$missing/config"
  output="$case_root/output.log"
  if run_installer "$worktree_root" "$main_root" >"$output" 2>&1; then
    echo "Installer accepted a missing main-clone $missing config." >&2
    exit 1
  fi
  rg -q "Missing main-clone .$missing/config" "$output"
  [[ ! -e "$worktree_root/.kube/config" ]]
  [[ ! -e "$worktree_root/.talos/config" ]]
done

# A successful worktree install emits only scoped credentials with fixed lifetimes.
success_root="$fixture/success"
success_main="$success_root/main"
success_worktree="$success_root/worktree"
make_main_credentials "$success_main"
mkdir -p "$success_worktree"
run_installer "$success_worktree" "$success_main" >/dev/null

kubeconfig="$success_worktree/.kube/config"
talosconfig="$success_worktree/.talos/config"
[[ "$(yq -r '.clusters[0].cluster.server' "$kubeconfig")" == 'https://192.168.90.20:6443' ]]
[[ "$(yq -r '.clusters[0].cluster."certificate-authority-data"' "$kubeconfig")" == 'bWFpbi1jYS1kYXRh' ]]
[[ "$(yq -r '.current-context' "$kubeconfig")" == 'homelab-observer' ]]
[[ "$(yq -r '.contexts[].name' "$kubeconfig" | sort)" == $'homelab-diagnostic\nhomelab-observer' ]]
[[ "$(yq -r '.users[].name' "$kubeconfig" | sort)" == $'homelab-diagnostic\nhomelab-observer' ]]
[[ "$(yq -r '.users[] | select(.name == "homelab-observer") | .user.token' "$kubeconfig")" == 'fake-observer-token' ]]
[[ "$(yq -r '.users[] | select(.name == "homelab-diagnostic") | .user.token' "$kubeconfig")" == 'fake-diagnostic-token' ]]
if rg -q 'main-admin-token-must-not-be-copied|homelab-admin' "$kubeconfig"; then
  echo 'Worktree kubeconfig copied a main-clone admin identity.' >&2
  exit 1
fi
[[ "$(file_mode "$kubeconfig")" == '600' ]]
[[ "$(file_mode "$talosconfig")" == '600' ]]
rg -q '^--kubeconfig .* --namespace kube-system create token homelab-observer --duration=720h ' "$success_worktree/calls.log"
rg -q '^--kubeconfig .* --namespace kube-system create token homelab-diagnostic --duration=720h ' "$success_worktree/calls.log"
rg -Fq -- '--roles os:reader --crt-ttl 2160h --talosconfig ' "$success_worktree/calls.log"
rg -Fq -- '--nodes 192.168.90.10 --endpoints 192.168.90.10\,192.168.90.11\,192.168.90.12 ' "$success_worktree/calls.log"

# Every external staging failure preserves both originals and removes temp files.
for failed_stage in observer-token diagnostic-token talos-new; do
  case_root="$fixture/failure-$failed_stage"
  main_root="$case_root/main"
  worktree_root="$case_root/worktree"
  make_main_credentials "$main_root"
  mkdir -p "$worktree_root/.kube" "$worktree_root/.talos"
  printf '%s\n' 'original-kubeconfig' >"$worktree_root/.kube/config"
  printf '%s\n' 'original-talosconfig' >"$worktree_root/.talos/config"
  if run_installer "$worktree_root" "$main_root" FAKE_FAIL_STAGE="$failed_stage" >/dev/null 2>&1; then
    echo "Installer accepted failed stage: $failed_stage" >&2
    exit 1
  fi
  [[ "$(<"$worktree_root/.kube/config")" == 'original-kubeconfig' ]]
  [[ "$(<"$worktree_root/.talos/config")" == 'original-talosconfig' ]]
  [[ -z "$(find "$worktree_root/.kube" "$worktree_root/.talos" -type f ! -name config -print -quit)" ]]
done

echo 'Worktree credential installation contract passed.'
