#!/usr/bin/env bash
# Regression tests for bundled-only monitoring verification without cluster access.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/test/lib/monitoring-fixtures.sh"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-monitoring-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
template="$fixture/template"
tree="$fixture/tree"
stub_bin="$fixture/bin"
mkdir -p "$stub_bin"
touch "$fixture/kubeconfig"

monitoring_fixture_prepare "$repo_root" "$template" "$tree"

cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case " $* " in
  *' get kustomization '* | *' get helmrelease '*) printf 'True\n' ;;
  *' rollout status '*) ;;
  *' get pvc '*) printf '%s\n' '{"items":[{"status":{"phase":"Bound"}},{"status":{"phase":"Bound"}},{"status":{"phase":"Bound"}}]}' ;;
  *' get httproute '*) printf '%s\n' '{"status":{"parents":[{"conditions":[{"type":"Accepted","status":"True"}]}]}}' ;;
  *) echo "Unexpected kubectl request: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$stub_bin/kubectl"

cat >"$stub_bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '192.168.90.30'
EOF
chmod +x "$stub_bin/dig"

cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == 'kube foundation-verify' ]] || {
  echo "Unexpected just request: $*" >&2
  exit 64
}
printf '%s\n' 'Foundation verification passed.'
EOF
chmod +x "$stub_bin/just"

cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case " $* " in
  *'/api/health'*)
    printf '%s\n' '{"database":"ok"}'
    ;;
  *'/-/healthy'*)
    ;;
  *'/api/v1/targets?state=active'*)
    printf '%s\n' '{"status":"success","data":{"activeTargets":[{"health":"up","discoveredLabels":{"__meta_kubernetes_service_name":"kube-prometheus-stack-kube-state-metrics","__meta_kubernetes_namespace":"monitoring"}}]}}'
    ;;
  *'/api/v1/rules?type=alert'*)
    printf '%s\n' '{"status":"success","data":{"groups":[{"rules":[{"name":"FluxReconciliationFailure","state":"inactive","health":"ok","lastError":"","query":"gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\"}"},{"name":"FluxResourceMetricsMissing","state":"inactive","health":"ok","lastError":"","query":"absent(gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\",customresource_kind=\"Kustomization\"}) or absent(gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\",customresource_kind=\"HelmRelease\"}) or absent(gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\",customresource_kind=\"GitRepository\"}) or absent(gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\",customresource_kind=\"OCIRepository\"}) or absent(gotk_resource_info{service=\"kube-prometheus-stack-kube-state-metrics\",namespace=\"monitoring\",customresource_kind=\"HelmRepository\"})"}]}]}}'
    ;;
  *'/api/v1/alertmanagers'*)
    printf '%s\n' '{"status":"success","data":{"activeAlertmanagers":[{"url":"http://alertmanager"}]}}'
    ;;
  *'/api/v2/status'*)
    printf '%s\n' '{"config":{"original":"route:\n  routes:\n    - receiver: ntfy\n      matchers:\n        - severity=~\\\"critical|warning\\\"\nreceivers:\n  - name: ntfy\n    webhook_configs:\n      - url: http://example.invalid/hook"}}'
    ;;
  *'/api/v1/query'*)
    printf '%s\n' '{"status":"success","data":{"result":[{"metric":{"customresource_kind":"Kustomization"},"value":[1,"1"]},{"metric":{"customresource_kind":"HelmRelease"},"value":[1,"1"]},{"metric":{"customresource_kind":"GitRepository"},"value":[1,"1"]},{"metric":{"customresource_kind":"OCIRepository"},"value":[1,"1"]},{"metric":{"customresource_kind":"HelmRepository"},"value":[1,"1"]}]}}'
    ;;
  *) ;;
esac
EOF
chmod +x "$stub_bin/curl"

reset_tree() {
  rm -rf -- "$tree"
  cp -R "$template/." "$tree"
  if [[ -e "$tree/kubernetes/apps/monitoring/flux-kube-state-metrics" ]]; then
    mv "$tree/kubernetes/apps/monitoring/flux-kube-state-metrics" \
      "$fixture/removed-flux-kube-state-metrics-$RANDOM"
  fi
  yq -i 'del(.resources[] | select(. == "./flux-kube-state-metrics/ks.yaml"))' \
    "$tree/kubernetes/apps/monitoring/kustomization.yaml"
}

expect_success() {
  local output
  output="$(cd "$tree" && PATH="$stub_bin:$PATH" bash scripts/verify/monitoring.sh "$fixture/kubeconfig")"
  rg -Fq 'Monitoring acceptance passed' <<<"$output" || {
    echo 'Bundled-only monitoring verification did not report success.' >&2
    echo "$output" >&2
    exit 1
  }
}

expect_rejected() {
  local label="$1" expected="$2" output exit_code
  set +e
  output="$(cd "$tree" && PATH="$stub_bin:$PATH" bash scripts/verify/monitoring.sh "$fixture/kubeconfig" 2>&1)"
  exit_code="$?"
  set -e
  [[ "$exit_code" -ne 0 ]] || {
    echo "$label: verifier unexpectedly accepted invalid bundled configuration." >&2
    exit 1
  }
  rg -Fq -- "$expected" <<<"$output" || {
    echo "$label: verifier omitted its expected failure: $expected" >&2
    echo "$output" >&2
    exit 1
  }
}

reset_tree
expect_success

reset_tree
yq -i 'del(."kube-state-metrics".customResourceState)' \
  "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'missing custom-resource configuration' \
  'Bundled kube-state-metrics must configure exactly the five expected Flux resource kinds'

reset_tree
yq -i 'del(."kube-state-metrics".customResourceState.config.spec.resources[] | select(.groupVersionKind.kind == "OCIRepository"))' \
  "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'missing OCIRepository metric family' \
  'Bundled kube-state-metrics must configure exactly the five expected Flux resource kinds'

echo 'Bundled-only monitoring verifier regression tests passed.'
