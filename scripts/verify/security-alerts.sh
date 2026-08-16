#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/flux-alerts.sh
source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: security-alerts.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"

for name in cert-manager-monitoring security-alerts; do
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == 'True' ]]
done

prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
targets_response="$(flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" '/api/v1/targets?state=active')"
[[ "$(yq -r '.status // ""' <<<"$targets_response")" == 'success' ]]
[[ "$(flux_alerts_target_count 'cert-manager' <<<"$targets_response")" -gt 0 ]]
[[ "$(flux_alerts_target_healths 'cert-manager' <<<"$targets_response")" == 'up' ]]

metric_response="$(flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" 'certmanager_certificate_expiration_timestamp_seconds{namespace="networking",name="wildcard-lab-supermorphic-com"}')"
[[ "$(yq -r '.status // ""' <<<"$metric_response")" == 'success' ]]
[[ "$(yq -r '.data.result | length' <<<"$metric_response")" == '1' ]]
[[ "$(yq -r '.data.result[0].metric.namespace' <<<"$metric_response")" == 'networking' ]]
[[ "$(yq -r '.data.result[0].metric.name' <<<"$metric_response")" == 'wildcard-lab-supermorphic-com' ]]
[[ "$(yq -r '.data.result[0].value[1] | tonumber > (now | to_unix)' <<<"$metric_response")" == 'true' ]]

[[ -z "$(
  kubectl --kubeconfig "$kubeconfig" --namespace networking get \
    certificate.cert-manager.io/wildcard-lab-supermorphic-com-staging \
    --ignore-not-found --output name
)" ]]
[[ -z "$(
  kubectl --kubeconfig "$kubeconfig" get \
    clusterissuer.cert-manager.io/letsencrypt-staging \
    --ignore-not-found --output name
)" ]]

rules_response="$(
  flux_alerts_prometheus_get \
    "$prometheus_base_url" \
    "$prometheus_resolve" \
    '/api/v1/rules?type=alert'
)"
[[ "$(yq -r '.status // ""' <<<"$rules_response")" == 'success' ]]
security_rule_rows="$(yq -r '
  [
    .data.groups[]?.rules[]?
    | select(
        .name == "WildcardCertificateExpiringSoon"
        or .name == "WildcardCertificateExpiryCritical"
        or .name == "WildcardCertificateExpiryMetricMissing"
      )
    | {
        "name": .name,
        "health": (.health // ""),
        "last_error": (.lastError // "")
      }
  ]
  | sort_by(.name)
  | .[]
  | [.name, .health, .last_error]
  | @tsv
' <<<"$rules_response")"
expected_security_rule_rows=$'WildcardCertificateExpiringSoon\tok\t\nWildcardCertificateExpiryCritical\tok\t\nWildcardCertificateExpiryMetricMissing\tok\t'
[[ "$security_rule_rows" == "$expected_security_rule_rows" ]]
