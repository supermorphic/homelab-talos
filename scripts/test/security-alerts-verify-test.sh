#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/verify/security-alerts.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/security-alerts-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case " $* " in
  *' --namespace flux-system get kustomization cert-manager-monitoring '*) printf 'True\n' ;;
  *' --namespace flux-system get kustomization security-alerts '*) printf 'True\n' ;;
  *' --namespace networking get certificate.cert-manager.io/wildcard-lab-supermorphic-com-staging '*) ;;
  *' get clusterissuer.cert-manager.io/letsencrypt-staging '*) ;;
  *) echo "Unexpected kubectl request: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case " $* " in
  *'/api/v1/targets?state=active'*)
    printf '%s\n' '{"status":"success","data":{"activeTargets":[{"discoveredLabels":{"__meta_kubernetes_service_name":"cert-manager"},"scrapePool":"serviceMonitor/cert-manager","health":"up"}]}}'
    ;;
  *'/api/v1/query'*)
    printf '{"status":"success","data":{"result":[{"metric":{"namespace":"networking","name":"wildcard-lab-supermorphic-com"},"value":[0,"%s"]}]}}\n' "$FAKE_CERTIFICATE_EXPIRY"
    ;;
  *'/api/v1/rules?type=alert'*)
    printf '%s\n' '{"status":"success","data":{"groups":[{"rules":[{"name":"WildcardCertificateExpiringSoon","health":"ok","lastError":""},{"name":"WildcardCertificateExpiryCritical","health":"ok","lastError":""},{"name":"WildcardCertificateExpiryMetricMissing","health":"ok","lastError":""}]}]}}'
    ;;
  *) echo "Unexpected curl request: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$fixture/bin/curl"

run_verifier() {
  PATH="$fixture/bin:$PATH" \
    FAKE_CERTIFICATE_EXPIRY="$1" \
    "$verifier" "$fixture/kubeconfig"
}

future_expiry=4102444800
run_verifier "$future_expiry" >"$fixture/future.out"

past_expiry=1
if run_verifier "$past_expiry" >"$fixture/past.out" 2>&1; then
  echo 'security-alerts verifier accepted an expired certificate metric.' >&2
  exit 1
fi

echo 'security-alerts verifier accepts a future expiry and rejects a past expiry.'
