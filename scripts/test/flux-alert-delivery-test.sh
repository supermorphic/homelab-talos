#!/usr/bin/env bash
set -euo pipefail

scenario='scripts/test/scenarios/flux-alert-delivery.sh'
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-flux-alert-delivery-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
kubeconfig="$temp_dir/kubeconfig"
stub_bin="$temp_dir/bin"
kubectl_marker="$temp_dir/kubectl-called"
mkdir -p "$stub_bin"
touch "$kubeconfig"

cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"$KUBECTL_MARKER"
exit 99
EOF
chmod +x "$stub_bin/kubectl"
cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod +x "$stub_bin/curl"

expect_guard_rejection() {
  local confirmation="${1:-}"
  local output exit_code
  rm -f -- "$kubectl_marker"
  set +e
  if [[ -n "$confirmation" ]]; then
    output="$(
      PATH="$stub_bin:$PATH" \
      KUBECTL_MARKER="$kubectl_marker" \
      FLUX_ALERT_E2E_CONFIRM="$confirmation" \
        "$scenario" "$kubeconfig" 2>&1
    )"
    exit_code="$?"
  else
    output="$(
      PATH="$stub_bin:$PATH" \
      KUBECTL_MARKER="$kubectl_marker" \
      env -u FLUX_ALERT_E2E_CONFIRM \
        "$scenario" "$kubeconfig" 2>&1
    )"
    exit_code="$?"
  fi
  set -e
  [[ "$exit_code" -eq 1 ]] || {
    echo "Expected guard rejection, got exit $exit_code." >&2
    exit 1
  }
  rg -q "FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved'" <<<"$output"
  [[ ! -e "$kubectl_marker" ]] || {
    echo 'Flux alert E2E touched Kubernetes before validating its confirmation.' >&2
    exit 1
  }
}

expect_guard_rejection
expect_guard_rejection 'test:flux-alert:wrong'

set +e
PATH="$stub_bin:$PATH" \
KUBECTL_MARKER="$kubectl_marker" \
FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved' \
  "$scenario" "$kubeconfig" >/dev/null 2>&1
confirmed_exit="$?"
set -e
[[ "$confirmed_exit" -ne 0 && -e "$kubectl_marker" ]] || {
  echo 'Exact confirmation did not pass control to the Kubernetes preflight.' >&2
  exit 1
}

rg -Fq 'source_name="${test_name}-source-does-not-exist"' "$scenario"
rg -Fq 'get gitrepository "$source_name"' "$scenario"
rg -q '\.homelab-talos-tests/' "$scenario"
rg -q 'homelab-talos/test.*flux-alert-delivery' "$scenario"
rg -q 'FluxReconciliationFailure' "$scenario"
rg -q 'alertmanager_notifications_total' "$scenario"
rg -q 'alertmanager_notifications_failed_total' "$scenario"
rg -q 'delete kustomization "\$test_name"' "$scenario"
rg -q 'created=false' "$scenario"

echo 'Flux alert delivery E2E guard and ownership assertions passed.'
