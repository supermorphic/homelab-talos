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

echo 'Cluster verification boundary tests passed.'
