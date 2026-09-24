#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-cluster-verification-boundary.XXXXXX")"
fixture_root="$(cd "$fixture_root" && pwd -P)"
trap 'rm -rf -- "$fixture_root"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

checkout="$fixture_root/checkout"
outside="$fixture_root/outside"
mkdir -p "$checkout/kubernetes" "$checkout/scripts/lib" \
  "$checkout/scripts/validate" "$checkout/scripts/test" "$outside"
cp "$repo_root/kubernetes/mod.just" "$checkout/kubernetes/mod.just"
cp "$repo_root/.mise.toml" "$repo_root/mise.lock" "$checkout/"
cat >"$checkout/.justfile" <<'EOF'
#!/usr/bin/env -S just --justfile

mod kube "kubernetes"
EOF
cat >"$checkout/scripts/lib/common.sh" <<'EOF'
#!/usr/bin/env bash
require_bash() { :; }
EOF
cat >"$checkout/scripts/validate/foundation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'validate|%s|%s\n' "$PWD" "$*" >>"${BOUNDARY_CALLS:?}"
EOF
cat >"$checkout/scripts/test/run-catalog-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'catalog|%s|%s|%s|%s\n' "$PWD" "$*" "${KUBECONFIG:-<unset>}" \
  "${TEST_KUBECONFIG:-<unset>}" >>"${BOUNDARY_CALLS:?}"
EOF
chmod +x "$checkout/scripts/validate/foundation.sh" \
  "$checkout/scripts/test/run-catalog-suite.sh"

(
  cd "$checkout"
  mise exec -- just --dry-run kube foundation-verify >"$fixture_root/dry-run.log" 2>&1
)
rg -Fq 'scripts/validate/foundation.sh' "$fixture_root/dry-run.log" ||
  fail 'The public dry-run omitted foundation source validation.'
rg -Fq "scripts/test/run-catalog-suite.sh verification.foundation -- scripts/verify/foundation.sh '.kube/config'" \
  "$fixture_root/dry-run.log" ||
  fail 'The public dry-run omitted the canonical foundation runner boundary.'

calls="$fixture_root/boundary.calls"
ambient_kubeconfig="$fixture_root/ambient-kubeconfig"
touch "$ambient_kubeconfig"
(
  cd "$outside"
  unset TEST_KUBECONFIG
  BOUNDARY_CALLS="$calls" KUBECONFIG="$ambient_kubeconfig" \
    mise -C "$checkout" exec -- \
      just --justfile "$checkout/.justfile" kube foundation-verify
)
expected_calls="$(printf 'validate|%s|\ncatalog|%s|verification.foundation -- scripts/verify/foundation.sh .kube/config|%s|<unset>' \
  "$checkout" "$checkout" "$ambient_kubeconfig")"
[[ "$(cat "$calls")" == "$expected_calls" ]] || {
  echo 'The executable foundation boundary used unexpected order, arguments, or directory.' >&2
  cat "$calls" >&2
  exit 1
}

stub_bin="$fixture_root/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FOUNDATION_JUST_CALLS:?}"
[[ "$*" == 'kube flux-verify' ]]
EOF
cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FOUNDATION_KUBECTL_CALLS:?}"
exit 71
EOF
chmod +x "$stub_bin/just" "$stub_bin/kubectl"
fake_kubeconfig="$fixture_root/foundation-kubeconfig"
touch "$fake_kubeconfig"
foundation_just_calls="$fixture_root/foundation-just.calls"
foundation_kubectl_calls="$fixture_root/foundation-kubectl.calls"
set +e
PATH="$stub_bin:$PATH" \
FOUNDATION_JUST_CALLS="$foundation_just_calls" \
FOUNDATION_KUBECTL_CALLS="$foundation_kubectl_calls" \
  scripts/verify/foundation.sh "$fake_kubeconfig" \
  >"$fixture_root/foundation.out" 2>&1
foundation_status="$?"
set -e
[[ "$foundation_status" -ne 0 ]] ||
  fail 'Foundation verification accepted a failed Kubernetes observation.'
[[ "$(cat "$foundation_just_calls")" == 'kube flux-verify' ]] ||
  fail 'Foundation verification did not invoke the public Flux verifier.'
[[ "$(wc -l <"$foundation_kubectl_calls" | tr -d ' ')" == 1 ]] ||
  fail 'Foundation verification continued after the first Kubernetes failure.'
rg -Fq -- "--kubeconfig $fake_kubeconfig " "$foundation_kubectl_calls" ||
  fail 'Foundation verification did not pass its explicit kubeconfig.'

# Foundation and Flux verification both reach Cilium postflight. Exercise that
# public recipe with fake clients to prove which checkout credential it uses.
mkdir -p "$checkout/.talos" "$checkout/.kube"
printf 'synthetic-talos-context\n' >"$checkout/.talos/config"
touch "$checkout/.kube/config"
cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'kube cilium-diagnostics' ]]
EOF
cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *'get namespaces --output json'* ]] || exit 64
printf '{"items":[]}\n'
EOF
cat >"$stub_bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *'--talosconfig .talos/config'* ]] || exit 64
[[ -f .talos/config ]] || exit 65
[[ "$(cat .talos/config)" == synthetic-talos-context ]] || exit 66
printf '%s\n' "$*" >>"${BOUNDARY_TALOS_CALLS:?}"
if [[ "$1 $2" == 'etcd status' ]]; then
  printf 'NODE STATUS\nnode-a healthy\nnode-b healthy\nnode-c healthy\n'
elif [[ "$1 $2 $3" == 'etcd alarm list' ]]; then
  printf 'NODE ALARM\n'
else
  exit 64
fi
EOF
chmod +x "$stub_bin/just" "$stub_bin/kubectl" "$stub_bin/talosctl"
talos_calls="$fixture_root/talos.calls"
ambient_talosconfig="$fixture_root/ambient-talosconfig"
touch "$ambient_talosconfig"
real_just="$(mise exec -- which just)"
(
  cd "$outside"
  # shellcheck disable=SC2016  # Variables expand in the child shell.
  BOUNDARY_BIN="$stub_bin" BOUNDARY_CHECKOUT="$checkout" \
  BOUNDARY_TALOS_CALLS="$talos_calls" REAL_JUST="$real_just" \
  TALOSCONFIG="$ambient_talosconfig" \
    mise -C "$checkout" exec -- bash -c '
      PATH="$BOUNDARY_BIN:$PATH" \
        "$REAL_JUST" --justfile "$BOUNDARY_CHECKOUT/.justfile" kube cilium-postflight
    '
)
[[ "$(wc -l <"$talos_calls" | tr -d ' ')" == 2 ]] ||
  fail 'Cilium postflight did not use the prepared Talos credential for both etcd checks.'

echo 'Cluster verification boundary tests passed.'
