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

if [[ "$*" == *'--namespace flux-system'* ]] &&
  [[ "$*" == *'get kustomization kube-prometheus-stack --output jsonpath='* ||
    "$*" == *'get kustomization kube-prometheus-stack-config --output jsonpath='* ]]; then
  printf 'True\n'
  exit 0
fi
if [[ "$*" == *'--namespace monitoring'* ]] &&
  [[ "$*" == *'get helmrelease kube-prometheus-stack --output jsonpath='* ]]; then
  printf 'True\n'
  exit 0
fi
if [[ "$*" == *'--namespace monitoring'* ]] &&
  [[ "$*" == *'rollout status deployment/kube-prometheus-stack-kube-state-metrics --timeout=5m'* ]]; then
  exit 0
fi

case " $* " in
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
  *'query=kube_node_info{'*)
    case "${FAKE_STANDARD_METRIC_MODE:-healthy}" in
      missing-node) printf '%s\n' '{"status":"success","data":{"result":[]}}' ;;
      api-error) printf '%s\n' '{"status":"error","errorType":"bad_data","error":"fixture standard metric error"}' ;;
      *) printf '%s\n' '{"status":"success","data":{"result":[{"metric":{"node":"node-a"},"value":[1,"1"]}]}}' ;;
    esac
    ;;
  *'query=kube_pod_info{'*)
    case "${FAKE_STANDARD_METRIC_MODE:-healthy}" in
      missing-pod) printf '%s\n' '{"status":"success","data":{"result":[]}}' ;;
      api-error) printf '%s\n' '{"status":"error","errorType":"bad_data","error":"fixture standard metric error"}' ;;
      *) printf '%s\n' '{"status":"success","data":{"result":[{"metric":{"pod":"kube-state-metrics-a"},"value":[1,"1"]}]}}' ;;
    esac
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
  local output standard_mode="${1:-healthy}"
  output="$(cd "$tree" && PATH="$stub_bin:$PATH" FAKE_STANDARD_METRIC_MODE="$standard_mode" \
    bash scripts/verify/monitoring.sh "$fixture/kubeconfig")"
  rg -Fq 'Monitoring acceptance passed' <<<"$output" || {
    echo 'Bundled-only monitoring verification did not report success.' >&2
    echo "$output" >&2
    exit 1
  }
}

expect_rejected() {
  local label="$1" expected="$2" standard_mode="${3:-healthy}" output exit_code
  set +e
  output="$(cd "$tree" && PATH="$stub_bin:$PATH" FAKE_STANDARD_METRIC_MODE="$standard_mode" \
    bash scripts/verify/monitoring.sh "$fixture/kubeconfig" 2>&1)"
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

reset_tree
expect_rejected 'missing bundled node metric' \
  'Prometheus returned no kube_node_info series from the bundled collector' missing-node

reset_tree
expect_rejected 'missing bundled pod metric' \
  'Prometheus returned no kube_pod_info series from the bundled collector' missing-pod

reset_tree
expect_rejected 'failed bundled standard-metric API query' \
  'Prometheus kube_node_info query did not return status=success' api-error

reset_tree
perl -0pi -e "s/flux_alerts_release='kube-prometheus-stack'/flux_alerts_release='flux-kube-state-metrics'/" \
  "$tree/scripts/lib/flux-alerts.sh"
expect_rejected 'old dedicated HelmRelease identity' 'kube-prometheus-stack HelmRelease is not Ready.'

reset_tree
perl -0pi -e "s/flux_alerts_service='kube-prometheus-stack-kube-state-metrics'/flux_alerts_service='flux-kube-state-metrics'/" \
  "$tree/scripts/lib/flux-alerts.sh"
expect_rejected 'old dedicated deployment identity' 'Unexpected kubectl request'

echo 'Bundled-only monitoring verifier regression tests passed.'
