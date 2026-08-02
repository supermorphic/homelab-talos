#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/metrics-server.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/metrics-server-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case " $* " in
  *' get kustomization metrics-server '*) printf 'True' ;;
  *' rollout status deployment/metrics-server '*) ;;
  *' get apiservice v1beta1.metrics.k8s.io '*) printf 'True' ;;
  *' top nodes '*)
    echo 'fake metrics authorization denied' >&2
    exit 1
    ;;
  *)
    echo "Unexpected kubectl call: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

output="$fixture/verifier.out"
if PATH="$fixture/bin:$PATH" "$verifier" "$fixture/kubeconfig" >"$output" 2>&1; then
  echo 'metrics-server verifier unexpectedly accepted a failed metrics query.' >&2
  exit 1
fi
rg -q 'fake metrics authorization denied' "$output" || {
  echo 'metrics-server verifier discarded the API failure reason.' >&2
  exit 1
}

echo 'metrics-server verifier diagnostic test passed.'
