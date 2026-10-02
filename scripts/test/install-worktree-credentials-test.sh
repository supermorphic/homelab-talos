#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
installer="$repo_root/scripts/repository/install-worktree-credentials.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/install-worktree-credentials-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

fake_bin="$fixture/bin"
mkdir -p "$fake_bin"
real_mktemp_bin="$(command -v mktemp)"
real_mv_bin="$(command -v mv)"

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

[[ "$*" == *' config view '* && "$*" == *'jsonpath={.clusters[0].cluster.server}'* ]] || exit 64
printf '%s\n' 'https://192.168.90.20:6443'
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
    talosconfig=''
    args=("$@")
    for ((index = 0; index < ${#args[@]}; index++)); do
      if [[ "${args[$index]}" == '--talosconfig' ]]; then
        talosconfig="${args[$((index + 1))]}"
      fi
    done
    [[ "$talosconfig" == "$EXPECTED_MAIN_TALOSCONFIG" ]] || {
      echo "Talos generation used wrong talosconfig: $talosconfig" >&2
      exit 66
    }
    output="$3"
    [[ ! -e "$output" ]] || {
      echo "talosconfig file already exists: $output" >&2
      exit 79
    }
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

cat >"$fake_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_FAIL_STAGE:-}" != mktemp ]] || exit 74
exec "$REAL_MKTEMP_BIN" "$@"
EOF

cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_FAIL_STAGE:-}" != publish-talos ]] || exit 75
exec "$REAL_MV_BIN" "$@"
EOF

chmod +x \
  "$fake_bin/git" \
  "$fake_bin/kubectl" \
  "$fake_bin/talosctl" \
  "$fake_bin/mktemp" \
  "$fake_bin/mv"

file_mode() {
  local mode
  mode="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)" ||
    return 1
  [[ "$mode" =~ ^0?[0-7]{3}$ ]] || return 1
  printf '%s\n' "${mode#0}"
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
  local main_root_physical
  shift 2
  main_root_physical="$(cd -- "$main_root" && pwd -P)"
  env \
    GIT_BIN="$fake_bin/git" \
    KUBECTL_BIN="$fake_bin/kubectl" \
    TALOSCTL_BIN="$fake_bin/talosctl" \
    MKTEMP_BIN="$fake_bin/mktemp" \
    MV_BIN="$fake_bin/mv" \
    FAKE_WORKTREE_ROOT="$worktree_root" \
    FAKE_GIT_COMMON_DIR="$main_root/.git" \
    FAKE_CALL_LOG="$worktree_root/calls.log" \
    REAL_MKTEMP_BIN="$real_mktemp_bin" \
    REAL_MV_BIN="$real_mv_bin" \
    EXPECTED_MAIN_KUBECONFIG="$main_root_physical/.kube/config" \
    EXPECTED_MAIN_TALOSCONFIG="$main_root_physical/.talos/config" \
    "$@" \
    "$installer"
}

# The main-clone recipe must retain the Talos-admin kubeconfig download behavior.
main_case="$fixture/main-path"
make_main_credentials "$main_case"
main_case_physical="$(cd -- "$main_case" && pwd -P)"
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
cp "$repo_root/.just/node.just" "$main_case/.just/node.just"
cp "$repo_root/.just/cluster.just" "$main_case/.just/cluster.just"
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
  EXPECTED_MAIN_KUBECONFIG="$main_case_physical/.kube/config" \
  EXPECTED_MAIN_TALOSCONFIG="$main_case_physical/.talos/config" \
  just --justfile "$main_case/.justfile" talos kubeconfig >/dev/null
[[ "$(yq -r '.current-context' "$main_case/.kube/config")" == 'homelab-admin' ]]
rg -q '^kubeconfig ' "$main_case/calls.log"
if rg -q '^config new ' "$main_case/calls.log"; then
  echo 'Main-clone recipe minted scoped worktree credentials.' >&2
  exit 1
fi

# The separate reader recipe must leave Kubernetes credentials untouched.
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
  EXPECTED_MAIN_KUBECONFIG="$main_case_physical/.kube/config" \
  EXPECTED_MAIN_TALOSCONFIG="$main_case_physical/.talos/config" \
  just --justfile "$main_case/.justfile" talos readerconfig >/dev/null
[[ ! -e "$recipe_worktree/.kube/config" ]]
rg -q '^config new ' "$recipe_worktree/calls.log"

# Missing Talos source fails; Kubernetes admin credentials are never needed.
main_root="$fixture/missing/main"
worktree_root="$fixture/missing/worktree"
make_main_credentials "$main_root"
mkdir -p "$worktree_root"
rm "$main_root/.talos/config"
if run_installer "$worktree_root" "$main_root" >"$fixture/missing.log" 2>&1; then
  echo 'Installer accepted a missing Talos config.' >&2
  exit 1
fi
rg -q 'Missing main-clone .talos/config' "$fixture/missing.log"
[[ ! -e "$worktree_root/.talos/config" ]]

for prior in existing absent; do
  main_root="$fixture/success-$prior/main"
  worktree_root="$fixture/success-$prior/worktree"
  make_main_credentials "$main_root"
  rm -r "$main_root/.kube"
  mkdir -p "$worktree_root"
  if [[ "$prior" == existing ]]; then
    mkdir -p "$worktree_root/.kube"
    printf '%s\n' 'existing-kubeconfig-preserved' >"$worktree_root/.kube/config"
  fi
  run_installer "$worktree_root" "$main_root" >/dev/null
  if [[ "$prior" == existing ]]; then
    [[ "$(<"$worktree_root/.kube/config")" == existing-kubeconfig-preserved ]]
  else
    [[ ! -e "$worktree_root/.kube" ]]
  fi
  [[ "$(file_mode "$worktree_root/.talos/config")" == 600 ]]
  [[ "$(file_mode "$worktree_root/.talos")" == 700 ]]
  rg -Fq -- '--roles os:reader --crt-ttl 2160h --talosconfig ' "$worktree_root/calls.log"
  if rg -q 'kubectl|create token|--kubeconfig' "$worktree_root/calls.log"; then
    echo 'Talos reader installation used Kubernetes authority.' >&2
    exit 1
  fi
done

# One atomic Talos rename needs no two-file rollback. Failures retain originals.
for failed_stage in mktemp talos-new publish-talos; do
  for prior in existing absent; do
    main_root="$fixture/failure-$failed_stage-$prior/main"
    worktree_root="$fixture/failure-$failed_stage-$prior/worktree"
    make_main_credentials "$main_root"
    mkdir -p "$worktree_root/.talos" "$worktree_root/.kube"
    printf '%s\n' original-kubeconfig >"$worktree_root/.kube/config"
    if [[ "$prior" == existing ]]; then
      printf '%s\n' original-talosconfig >"$worktree_root/.talos/config"
    fi
    if run_installer "$worktree_root" "$main_root" FAKE_FAIL_STAGE="$failed_stage" >/dev/null 2>&1; then
      echo "Installer accepted failed stage: $failed_stage" >&2
      exit 1
    fi
    [[ "$(<"$worktree_root/.kube/config")" == original-kubeconfig ]]
    if [[ "$prior" == existing ]]; then
      [[ "$(<"$worktree_root/.talos/config")" == original-talosconfig ]]
    else
      [[ ! -e "$worktree_root/.talos/config" ]]
    fi
    [[ -z "$(find "$worktree_root/.talos" -type f ! -name config -print -quit)" ]]
  done
done

if run_installer "$main_case" "$main_case" >"$fixture/main-refusal.log" 2>&1; then
  echo 'Reader installation accepted the main clone.' >&2
  exit 1
fi
rg -q 'main clone' "$fixture/main-refusal.log"
echo 'Separate Talos reader installation tests passed.'
