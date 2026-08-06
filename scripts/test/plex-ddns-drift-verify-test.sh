#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/verify/plex-ddns-drift.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/plex-ddns-drift-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_KUBECTL_LOG"
case " $* " in
  *' --namespace flux-system get kustomization plex-ddns-drift --output json '*)
    if [[ "$FAKE_LAYOUT" == suspended ]]; then
      printf '{"spec":{"suspend":true},"status":{"conditions":[{"type":"Ready","status":"True"}]}}\n'
    else
      printf '{"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}\n'
    fi
    ;;
  *' --namespace monitoring rollout status deployment/plex-ddns-drift --timeout=5m '*)
    printf 'deployment "plex-ddns-drift" successfully rolled out\n'
    ;;
  *' --namespace monitoring get deployment plex-ddns-drift --output json '*)
    if [[ "$FAKE_LAYOUT" == not-available ]]; then
      printf '{"spec":{"replicas":1},"status":{"availableReplicas":0}}\n'
    else
      printf '{"spec":{"replicas":1},"status":{"availableReplicas":1}}\n'
    fi
    ;;
  *' --namespace monitoring get servicemonitor plex-ddns-drift '*|*' --namespace monitoring get prometheusrule plex-ddns-drift '*)
    ;;
  *' --namespace monitoring logs deployment/plex-ddns-drift --container collector --since=10m '*)
    case "$FAKE_LAYOUT" in
      # The collector must never print either address. A regression that logged the
      # comparison would look exactly like this.
      leaked-address) printf 'success\nmismatch 203.0.113.42\n' ;;
      *) printf 'success\nsuccess\nmismatch\n' ;;
    esac
    ;;
  *)
    echo "Unexpected kubectl invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
case " $* " in
  *'/api/v1/targets?state=active'*)
    printf '{"data":{"activeTargets":[{"labels":{"job":"plex-ddns-drift"},"health":"up","scrapePool":"serviceMonitor/monitoring/plex-ddns-drift/0"}]}}\n'
    ;;
  *'/api/v1/query'*)
    printf '{"status":"success","data":{"result":[{"value":[0,"1"]}]}}\n'
    ;;
  *'/api/v1/rules?type=alert'*)
    # Prometheus reports every loaded rule; the verifier must require each alert the
    # deployed PrometheusRule declares, not a list frozen into the script.
    if [[ "$FAKE_LAYOUT" == missing-stale-rule ]]; then
      printf '{"data":{"groups":[{"rules":[{"name":"PlexDdnsAddressMismatch","health":"ok"},{"name":"PlexDdnsCheckFailed","health":"ok"},{"name":"PlexDdnsMetricsMissing","health":"ok"}]}]}}\n'
    elif [[ "$FAKE_LAYOUT" == unhealthy-rule ]]; then
      printf '{"data":{"groups":[{"rules":[{"name":"PlexDdnsAddressMismatch","health":"ok"},{"name":"PlexDdnsCheckFailed","health":"ok"},{"name":"PlexDdnsCheckStale","health":"err","lastError":"parse error"},{"name":"PlexDdnsMetricsMissing","health":"ok"}]}]}}\n'
    else
      printf '{"data":{"groups":[{"rules":[{"name":"PlexDdnsAddressMismatch","health":"ok"},{"name":"PlexDdnsCheckFailed","health":"ok"},{"name":"PlexDdnsCheckStale","health":"ok"},{"name":"PlexDdnsMetricsMissing","health":"ok"}]}]}}\n'
    fi
    ;;
  *'/api/v2/status'*)
    if [[ "$FAKE_LAYOUT" == no-ntfy-route ]]; then
      printf '{"config":{"original":"route:\\n  routes:\\n    - receiver: ntfy\\n      matchers:\\n        - severity=~\\"critical\\"\\n"}}\n'
    else
      printf '{"config":{"original":"route:\\n  routes:\\n    - receiver: ntfy\\n      matchers:\\n        - severity=~\\"critical|warning\\"\\n"}}\n'
    fi
    ;;
  *)
    echo "Unexpected curl invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/curl"

run_layout() {
  local layout="$1"
  : >"$fixture/kubectl.log"
  : >"$fixture/curl.log"
  set +e
  (
    cd "$repo_root" || exit 64
    PATH="$fixture/bin:$PATH" \
      FAKE_LAYOUT="$layout" \
      FAKE_KUBECTL_LOG="$fixture/kubectl.log" \
      FAKE_CURL_LOG="$fixture/curl.log" \
      bash "$verifier" "$fixture/kubeconfig"
  ) >"$fixture/output" 2>&1
  local status="$?"
  set -e
  return "$status"
}

expect_failure() {
  local layout="$1" message="$2"
  if run_layout "$layout"; then
    echo "Verifier passed for layout $layout." >&2
    cat "$fixture/output" >&2
    exit 1
  fi
  rg -F -q -- "$message" "$fixture/output" || {
    echo "Layout $layout: missing expected message: $message" >&2
    cat "$fixture/output" >&2
    exit 1
  }
}

echo '1. The healthy live state passes.'
run_layout healthy || {
  cat "$fixture/output" >&2
  exit 1
}
rg -F -q 'Plex DDNS drift verification passed' "$fixture/output"

echo '2. A suspended Kustomization is not accepted as verified.'
if run_layout suspended; then
  echo 'Verifier passed while the Kustomization was suspended.' >&2
  exit 1
fi

echo '3. An unavailable Deployment fails.'
expect_failure not-available 'plex-ddns-drift Deployment is not 1/1 available.'

echo '4. An address in the collector logs fails.'
expect_failure leaked-address 'Plex DDNS collector logs contain address-shaped text.'

echo '5. An alert declared in source but absent from Prometheus fails.'
expect_failure missing-stale-rule 'Prometheus has not loaded a healthy PlexDdnsCheckStale alert rule.'

echo '6. A loaded but unhealthy alert rule fails.'
expect_failure unhealthy-rule 'Prometheus has not loaded a healthy PlexDdnsCheckStale alert rule.'

echo '7. A warning route that does not reach ntfy fails.'
expect_failure no-ntfy-route 'Alertmanager has not loaded the warning route to ntfy.'

echo 'Plex DDNS drift verifier tests passed.'
