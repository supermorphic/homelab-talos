#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/flux-alerts.sh
source scripts/lib/network.sh
source scripts/lib/n8n-verification.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: n8n.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
mode="${N8N_VERIFY_MODE:-full}"
namespace='automation'
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
kc=(kubectl --kubeconfig "$kubeconfig")

[[ "$mode" == 'private' || "$mode" == 'full' ]] || {
  echo 'N8N_VERIFY_MODE must be private or full.' >&2
  exit 2
}
[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

require_ready_kustomization() {
  local name="$1" state
  state="$("${kc[@]}" --namespace flux-system get kustomization "$name" --output json)"
  n8n_flux_resource_current_ready <(printf '%s\n' "$state") || {
    echo "Flux Kustomization $name is suspended, stale, or not Ready." >&2
    exit 1
  }
}

for name in public-webhook-gateway n8n-postgresql n8n monitoring-alerts \
  security-alerts kube-prometheus-stack-config; do
  require_ready_kustomization "$name"
done

route_kustomization="$(
  "${kc[@]}" --namespace flux-system get kustomization public-webhook-route --output json
)"
if [[ "$mode" == 'private' ]]; then
  [[ "$(yq -r '.spec.suspend // false' - <<<"$route_kustomization")" == 'true' ]] || {
    echo 'Private verification requires public-webhook-route to remain suspended.' >&2
    exit 1
  }
  public_route_resource="$(
    "${kc[@]}" --namespace networking-public get httproute n8n-platform-canary \
      --ignore-not-found --output name
  )"
  [[ -z "$public_route_resource" ]] || {
    echo 'Private verification refuses an existing public n8n HTTPRoute.' >&2
    exit 1
  }
else
  require_ready_kustomization public-webhook-route
fi

deployment_state="$(
  "${kc[@]}" --namespace "$namespace" get deployment n8n --output json
)"
n8n_deployment_current_ready <(printf '%s\n' "$deployment_state") || {
  echo 'The n8n Deployment has not completed its current-generation rollout.' >&2
  exit 1
}
statefulset_state="$(
  "${kc[@]}" --namespace "$namespace" get statefulset n8n-postgresql --output json
)"
n8n_statefulset_current_ready <(printf '%s\n' "$statefulset_state") || {
  echo 'The n8n PostgreSQL StatefulSet has not completed its current revision.' >&2
  exit 1
}

helm_release="$(
  "${kc[@]}" --namespace "$namespace" get helmrelease.helm.toolkit.fluxcd.io n8n \
    --output json
)"
n8n_flux_resource_current_ready <(printf '%s\n' "$helm_release") || {
  echo 'The n8n HelmRelease is suspended, stale, or not Ready.' >&2
  exit 1
}

pvc_json="$(
  "${kc[@]}" --namespace "$namespace" get persistentvolumeclaims \
    n8n-data n8n-postgresql-data n8n-postgresql-backups --output json
)"
[[ "$(yq -r '[.items[].metadata.name] | sort | join(",")' - <<<"$pvc_json")" == \
  'n8n-data,n8n-postgresql-backups,n8n-postgresql-data' && \
  "$(yq -r '[.items[].metadata.uid | select(. != "")] | length' - <<<"$pvc_json")" == '3' && \
  "$(yq -r '[.items[].status.phase] | unique | join(",")' - <<<"$pvc_json")" == \
    'Bound' ]] || {
  echo 'The three retained n8n claims are not all present, identified, and Bound.' >&2
  exit 1
}

routes_json="$("${kc[@]}" get httproutes.gateway.networking.k8s.io --all-namespaces --output json)"
n8n_routes_match_contract "$mode" <(printf '%s\n' "$routes_json") || {
  echo 'Live accepted routes to automation/n8n differ from the exact private/public contract.' >&2
  exit 1
}

internal_dns_endpoints="$(
  "${kc[@]}" get dnsendpoints.externaldns.k8s.io --all-namespaces --output json
)"
n8n_internal_dns_endpoints_match_contract <(printf '%s\n' "$internal_dns_endpoints") || {
  echo 'The live internally published DNSEndpoint inventory is not the one observed public-webhook contract.' >&2
  exit 1
}
internal_dns_answer="$(
  dig +short @"$HOMELAB_DNS_RESOLVER" hooks.lab.supermorphic.com A | sort -u
)"
[[ "$internal_dns_answer" == "$HOMELAB_PUBLIC_GATEWAY_VIP" ]] || {
  echo "Pi-hole does not resolve hooks.lab.supermorphic.com to $HOMELAB_PUBLIC_GATEWAY_VIP." >&2
  exit 1
}

grant="$(
  "${kc[@]}" --namespace "$namespace" get referencegrant n8n-public-webhooks --output json
)"
[[ "$(yq -r '[.spec.from | length, .spec.to | length] | join(",")' - <<<"$grant")" == \
  '1,1' && \
  "$(yq -r '.spec.from[0] | [.group, .kind, .namespace] | join(",")' - <<<"$grant")" == \
    'gateway.networking.k8s.io,HTTPRoute,networking-public' && \
  "$(yq -r '.spec.to[0] | [.group, .kind, .name] | join(",")' - <<<"$grant")" == \
    ',Service,n8n' ]] || {
  echo 'The live n8n ReferenceGrant differs from the single-Service grant.' >&2
  exit 1
}

monitors="$(
  "${kc[@]}" --namespace "$namespace" get servicemonitors.monitoring.coreos.com \
    n8n n8n-postgresql --output json
)"
monitor_rows="$(yq -r '
  [.items[] | [.metadata.name, .spec.endpoints[0].port, .spec.endpoints[0].path] |
    join("|")] | sort | .[]
' - <<<"$monitors")"
[[ "$monitor_rows" == $'n8n-postgresql|metrics|/metrics\nn8n|http|/metrics' ]] || {
  echo 'Live n8n ServiceMonitor endpoints differ from the two exact scrape contracts.' >&2
  exit 1
}

prometheus_targets_ready=false
prometheus_targets_api_success=false
targets_response=''
# A reconcile can leave the previous target visible while Prometheus discovers its
# replacement. Keep the exact uniqueness and health contract, but allow that stale target
# to age out before rejecting the private platform.
for _attempt in {1..18}; do
  if targets_response="$(
    flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
      '/api/v1/targets?state=active'
  )" && [[ "$(yq -r '.status // ""' <<<"$targets_response")" == 'success' ]]; then
    prometheus_targets_api_success=true
    if n8n_prometheus_targets_match_contract <(printf '%s\n' "$targets_response"); then
      prometheus_targets_ready=true
      break
    fi
  fi
  if (( _attempt < 18 )); then
    sleep 10
  fi
done
[[ "$prometheus_targets_api_success" == 'true' ]] || {
  echo 'Prometheus targets API did not return success.' >&2
  exit 1
}
[[ "$prometheus_targets_ready" == 'true' ]] || {
  echo 'The exact n8n and n8n-postgresql Prometheus targets are absent, duplicated, or unhealthy.' >&2
  exit 1
}

rules_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/rules?type=alert'
)"
[[ "$(yq -r '.status // ""' <<<"$rules_response")" == 'success' ]] || {
  echo 'Prometheus rules API did not return success.' >&2
  exit 1
}
n8n_prometheus_rule_group_matches_contract "$mode" <(printf '%s\n' "$rules_response") || {
  if [[ "$mode" == 'private' ]]; then
    echo 'Private verification found a stale or early n8n-platform Prometheus rule group.' >&2
  else
    echo 'The loaded n8n-platform rule group differs from the exact healthy 15-rule contract.' >&2
  fi
  exit 1
}

certificate="$(
  "${kc[@]}" --namespace networking-public get certificate.cert-manager.io \
    hooks-lab-supermorphic-com --output json
)"
[[ "$(yq -r '.spec.dnsNames | join(",")' - <<<"$certificate")" == \
  'hooks.lab.supermorphic.com' && \
  "$(yq -r '[.status.conditions[]? | select(.type == "Ready") | .status][0] // ""' \
    - <<<"$certificate")" == 'True' ]] || {
  echo 'The dedicated public webhook Certificate is not Ready for its exact hostname.' >&2
  exit 1
}

dashboard_configmaps="$(
  "${kc[@]}" --namespace monitoring get configmaps \
    --selector grafana_dashboard=1 --output json
)"
[[ "$(yq -r '[.items[] | select(.data."n8n-postgresql.json" != null)] | length' \
  - <<<"$dashboard_configmaps")" == '1' ]] || {
  echo 'Grafana has not loaded exactly one n8n-postgresql dashboard ConfigMap.' >&2
  exit 1
}

backup_fresh=false
for _attempt in {1..18}; do
  # shellcheck disable=SC2016 # yq evaluates $value.
  if backup_response="$(
    flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" \
      'n8n_postgresql_backup_last_success_timestamp_seconds{namespace="automation",service="n8n-postgresql"}'
  )" && \
    [[ "$(yq -r '.status // ""' <<<"$backup_response")" == 'success' && \
      "$(yq -r '.data.result | length' <<<"$backup_response")" == '1' && \
      "$(yq -r '.data.result[0].value[1] | tonumber as $value |
        ($value >= (now | to_unix) - 129600 and $value <= (now | to_unix))' \
        <<<"$backup_response")" == 'true' ]]; then
    backup_fresh=true
    break
  fi
  sleep 10
done
[[ "$backup_fresh" == 'true' ]] || {
  echo 'The validated n8n PostgreSQL backup freshness series is absent or older than 36 hours.' >&2
  exit 1
}

if [[ "$mode" == 'full' ]]; then
  gatus_response="$(
    flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" \
      'gatus_results_endpoint_success{group="Platform",name="n8n-platform-canary"}'
  )"
  [[ "$(yq -r '.status // ""' <<<"$gatus_response")" == 'success' && \
    "$(yq -r '.data.result | length' <<<"$gatus_response")" == '1' && \
    "$(yq -r '.data.result[0].value[1]' <<<"$gatus_response")" == '1' ]] || {
    echo 'The authenticated Gatus n8n canary series is absent or not green.' >&2
    exit 1
  }

fi

echo "n8n $mode acceptance passed: Flux and workloads are Ready, all claims are Bound, routes and grants are exact, Prometheus targets and backup metrics are healthy, and the dashboard and certificate are loaded."
if [[ "$mode" == 'full' ]]; then
  echo 'The exact 15-alert n8n rule group is healthy and the observational Gatus canary series is green; this verifier sent no canary request.'
else
  echo 'The n8n rule group and public route remain absent; no canary credential was required.'
fi
