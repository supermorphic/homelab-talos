#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
just_bin="$(command -v just)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/plex-public-rollout-guard-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GIT_LOG"
case " $* " in
  ' remote get-url origin ')
    printf 'https://github.com/supermorphic/homelab-talos.git\n'
    ;;
  ' status --porcelain ')
    ;;
  ' ls-remote --exit-code origin refs/heads/main ')
    printf 'fixture-head\trefs/heads/main\n'
    ;;
  ' cat-file -e fixture-head^{commit} '|' diff --quiet fixture-head -- '*)
    ;;
  *)
    echo "Unexpected git invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/git"

cat >"$fixture/bin/flux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_FLUX_LOG"
case " $* " in
  ' reconcile source git flux-system '*|' reconcile kustomization cluster-apps '*|' resume kustomization public-gateway '*|' reconcile kustomization public-gateway '*|' suspend kustomization public-gateway '*)
    ;;
  *)
    echo "Unexpected flux invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/flux"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_KUBECTL_LOG"
case " $* " in
  *' --namespace flux-system get kustomization public-gateway --output jsonpath={.spec.suspend} '*)
    printf 'true'
    ;;
  *' get services --all-namespaces --output json '*)
    printf '{"apiVersion":"v1","kind":"List","items":[]}\n'
    ;;
  *' --namespace flux-system wait --for=condition=Ready kustomization/public-gateway '*)
    ;;
  *' --namespace envoy-gateway-system get deployments --selector gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public --output json '*)
    if [[ "$FAKE_LAYOUT" == flush-ambiguous ]]; then
      printf '{"apiVersion":"v1","kind":"List","items":[{"metadata":{"name":"envoy-public-a"}},{"metadata":{"name":"envoy-public-b"}}]}\n'
    else
      printf '{"apiVersion":"v1","kind":"List","items":[{"metadata":{"name":"envoy-public"}}]}\n'
    fi
    ;;
  *' --namespace envoy-gateway-system rollout restart deployment/envoy-public '|*' --namespace envoy-gateway-system rollout status deployment/envoy-public --timeout=10m ')
    ;;
  *)
    echo "Unexpected kubectl invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_JUST_LOG"
case " $* " in
  ' kube plex-public-validate '|' kube flux-verify '|' kube plex-public-probe-test ')
    ;;
  ' kube plex-public-verify ')
    [[ "$FAKE_LAYOUT" != bootstrap-verify-fails ]]
    ;;
  *)
    echo "Unexpected nested just invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/just"

run_recipe() {
  local layout="$1"
  shift
  : >"$fixture/git.log"
  : >"$fixture/flux.log"
  : >"$fixture/kubectl.log"
  : >"$fixture/just.log"
  case "$1" in
    bootstrap)
      "$just_bin" --justfile "$repo_root/.justfile" --working-directory "$repo_root" \
        --dry-run "$@" >"$fixture/rendered-recipe.sh" 2>&1
      ;;
    kube)
      "$just_bin" --justfile "$repo_root/.justfile" --working-directory "$repo_root" \
        --dry-run "$@" 2>&1 |
        awk '/^#!\/usr\/bin\/env bash$/ { count++; if (count == 2) emit=1 } emit' \
          >"$fixture/rendered-recipe.sh"
      ;;
    *)
      echo "Unexpected recipe module: $1" >&2
      exit 64
      ;;
  esac
  sed "s|kubeconfig='.kube/config'|kubeconfig='$fixture/kubeconfig'|" \
    "$fixture/rendered-recipe.sh" >"$fixture/executable-recipe.sh"
  set +e
  PATH="$fixture/bin:$PATH" \
    FAKE_LAYOUT="$layout" \
    FAKE_GIT_LOG="$fixture/git.log" \
    FAKE_FLUX_LOG="$fixture/flux.log" \
    FAKE_KUBECTL_LOG="$fixture/kubectl.log" \
    FAKE_JUST_LOG="$fixture/just.log" \
    bash "$fixture/executable-recipe.sh" >"$fixture/output" 2>&1
  local status="$?"
  set -e
  return "$status"
}

echo '1. Bootstrap cannot resume the public child without exact confirmation.'
if KUBECONFIG="$fixture/kubeconfig" run_recipe bootstrap-no-confirm bootstrap plex-public-gateway; then
  echo 'Bootstrap ran without confirmation.' >&2
  exit 1
fi
if rg -q '^resume kustomization ' "$fixture/flux.log"; then
  echo 'Bootstrap resumed Flux without confirmation.' >&2
  exit 1
fi

echo '2. A post-resume verifier failure re-suspends only public-gateway.'
if KUBECONFIG="$fixture/kubeconfig" \
  PLEX_PUBLIC_GATEWAY_BOOTSTRAP_CONFIRM='bootstrap:plex-public-gateway:192.168.90.39' \
  run_recipe bootstrap-verify-fails bootstrap plex-public-gateway; then
  echo 'Bootstrap passed although public verification failed.' >&2
  exit 1
fi
rg -F -q 'resume kustomization public-gateway' "$fixture/flux.log" || {
  cat "$fixture/output" >&2
  cat "$fixture/flux.log" >&2
  exit 1
}
rg -F -q 'suspend kustomization public-gateway' "$fixture/flux.log"
if rg '^suspend kustomization ' "$fixture/flux.log" | rg -v -q '^suspend kustomization public-gateway '; then
  echo 'Bootstrap suspended a Kustomization outside its ownership.' >&2
  exit 1
fi

echo '3. Connection flush refuses mutation without exact post-DNAT confirmation.'
if KUBECONFIG="$fixture/kubeconfig" run_recipe flush-no-confirm kube plex-public-connection-flush; then
  echo 'Connection flush ran without confirmation.' >&2
  exit 1
fi
[[ ! -s "$fixture/git.log" && ! -s "$fixture/kubectl.log" ]]

echo '4. Connection flush refuses an ambiguous public Deployment set.'
if KUBECONFIG="$fixture/kubeconfig" \
  PLEX_PUBLIC_CONNECTION_FLUSH_CONFIRM='flush:plex-public:dnat-removed' \
  run_recipe flush-ambiguous kube plex-public-connection-flush; then
  echo 'Connection flush ran with multiple public Deployments.' >&2
  exit 1
fi
if rg -q 'rollout restart' "$fixture/kubectl.log"; then
  echo 'Connection flush restarted a Deployment after ambiguous selection.' >&2
  exit 1
fi

echo '5. Connection flush restarts only the exact selected Deployment and verifies.'
KUBECONFIG="$fixture/kubeconfig" \
  PLEX_PUBLIC_CONNECTION_FLUSH_CONFIRM='flush:plex-public:dnat-removed' \
  run_recipe flush-success kube plex-public-connection-flush
rg -F -q -- '--selector gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public' "$fixture/kubectl.log"
rg -F -q -- 'rollout restart deployment/envoy-public' "$fixture/kubectl.log"
rg -F -q -- 'rollout status deployment/envoy-public --timeout=10m' "$fixture/kubectl.log"
rg -F -q -- 'kube plex-public-verify' "$fixture/just.log"

echo 'Plex public bootstrap and connection-flush guard tests passed.'
