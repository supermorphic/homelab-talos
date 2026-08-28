#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/flux-alerts.sh
source scripts/lib/network.sh
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
  [[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' && \
    "$(yq -r '[.status.conditions[]? | select(.type == "Ready") | .status][0] // ""' \
      - <<<"$state")" == 'True' ]] || {
    echo "Flux Kustomization $name is suspended or not Ready." >&2
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

"${kc[@]}" --namespace "$namespace" rollout status deployment/n8n --timeout=10m
"${kc[@]}" --namespace "$namespace" rollout status statefulset/n8n-postgresql --timeout=10m

helm_release="$(
  "${kc[@]}" --namespace "$namespace" get helmrelease.helm.toolkit.fluxcd.io n8n \
    --output json
)"
[[ "$(yq -r '.spec.suspend // false' - <<<"$helm_release")" == 'false' && \
  "$(yq -r '[.status.conditions[]? | select(.type == "Ready") | .status][0] // ""' \
    - <<<"$helm_release")" == 'True' ]] || {
  echo 'The n8n HelmRelease is suspended or not Ready.' >&2
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
# shellcheck disable=SC2016 # yq evaluates its own $route variable.
n8n_route_rows="$(yq -r '
  [
    .items[] as $route |
    $route.spec.rules[]? as $rule |
    $rule.backendRefs[]? |
    select(.kind == "Service" and .name == "n8n" and
      ((.namespace // $route.metadata.namespace) == "automation")) |
    [
      ($route.metadata.namespace + "/" + $route.metadata.name),
      ($route.spec.hostnames | join(",")),
      ($route.spec.parentRefs | map(
        ((.namespace // $route.metadata.namespace) + "/" + .name + "/" + (.sectionName // ""))
      ) | sort | join(",")),
      ($rule.matches[0].path.type // ""),
      ($rule.matches[0].path.value // ""),
      (.namespace // $route.metadata.namespace),
      (.port | tostring),
      ([
        $route.status.parents[]?.conditions[]? |
        select(.type == "Accepted" or .type == "ResolvedRefs") |
        (.type + "=" + .status)
      ] | sort | join(","))
    ] | join("|")
  ] | sort | .[]
' - <<<"$routes_json")"
expected_private_route='automation/n8n|n8n.lab.supermorphic.com|networking/internal/https|PathPrefix|/|automation|5678|Accepted=True,ResolvedRefs=True'
expected_public_route='networking-public/n8n-platform-canary|hooks.lab.supermorphic.com|networking-public/public-webhooks/https|Exact|/webhook/platform-canary|automation|5678|Accepted=True,ResolvedRefs=True'
expected_route_rows="$expected_private_route"
[[ "$mode" != 'full' ]] || expected_route_rows+=$'\n'"$expected_public_route"
[[ "$n8n_route_rows" == "$expected_route_rows" ]] || {
  echo 'Live accepted routes to automation/n8n differ from the exact private/public contract.' >&2
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

targets_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/targets?state=active'
)"
[[ "$(yq -r '.status // ""' <<<"$targets_response")" == 'success' ]] || {
  echo 'Prometheus targets API did not return success.' >&2
  exit 1
}
for service in n8n n8n-postgresql; do
  [[ "$(flux_alerts_target_count "$service" <<<"$targets_response")" -gt 0 && \
    "$(flux_alerts_target_healths "$service" <<<"$targets_response")" == 'up' ]] || {
    echo "Prometheus target $service is absent or unhealthy." >&2
    exit 1
  }
done

rules_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/rules?type=alert'
)"
[[ "$(yq -r '.status // ""' <<<"$rules_response")" == 'success' ]] || {
  echo 'Prometheus rules API did not return success.' >&2
  exit 1
}
expected_rules=(
  N8nCanaryDown
  N8nCanaryProbeMissing
  N8nContainerOomKilled
  N8nContainerRestarting
  N8nExecutionFailures
  N8nPersistentVolumeClaimNotBound
  N8nPersistentVolumeUsageCritical
  N8nPersistentVolumeUsageWarning
  N8nPostgresqlBackupJobFailed
  N8nPostgresqlBackupJobOverdue
  N8nPostgresqlBackupStale
  N8nPostgresqlUnavailable
  N8nPostgresqlWorkloadUnavailable
  N8nUnavailable
  N8nWorkloadUnavailable
)
loaded_rules="$(yq -r '
  [.data.groups[]? | select(.name == "n8n-platform") | .rules[]?.name] |
  sort | .[]
' <<<"$rules_response")"
expected_loaded_rules="$(printf '%s\n' "${expected_rules[@]}" | LC_ALL=C sort)"
[[ "$loaded_rules" == "$expected_loaded_rules" ]] || {
  echo 'The loaded n8n-platform rule group differs from the exact 15-rule contract.' >&2
  exit 1
}
for rule in "${expected_rules[@]}"; do
  rule_row="$(RULE="$rule" yq -r '
    [
      .data.groups[]?.rules[]? |
      select(.name == strenv(RULE)) |
      [(.health // ""), (.lastError // "")] | join("|")
    ] | join(",")
  ' <<<"$rules_response")"
  [[ "$rule_row" == 'ok|' ]] || {
    echo "Prometheus rule $rule is absent, duplicated, or unhealthy." >&2
    exit 1
  }
done

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

  token="${N8N_CANARY_TOKEN:-}"
  [[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* && "$token" != *'"'* ]] || {
    echo 'Set N8N_CANARY_TOKEN to the operator-held canary token without line breaks.' >&2
    exit 1
  }
  umask 077
  canary_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-n8n-verify.XXXXXX")"
  cleanup_canary_dir() {
    local original_exit="$?"
    trap - EXIT
    rm -rf -- "$canary_dir" && [[ ! -e "$canary_dir" ]] || {
      echo 'Failed to remove the permission-restricted n8n canary workspace.' >&2
      exit 1
    }
    exit "$original_exit"
  }
  trap cleanup_canary_dir EXIT
  correlation="n8n-verify-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  curl_config="$canary_dir/canary.curl"
  response_file="$canary_dir/response.json"
  {
    printf '%s\n' 'silent' 'show-error' 'fail' 'max-time = 30' 'request = "POST"'
    printf 'resolve = "hooks.lab.supermorphic.com:443:%s"\n' "$HOMELAB_PUBLIC_GATEWAY_VIP"
    printf '%s\n' 'header = "Content-Type: application/json"'
    printf 'header = "X-Platform-Canary: %s"\n' "$token"
    printf 'data = "{\\"correlation\\":\\"%s\\"}"\n' "$correlation"
    printf '%s\n' 'url = "https://hooks.lab.supermorphic.com/webhook/platform-canary"'
    printf 'output = "%s"\n' "$response_file"
  } >"$curl_config"
  curl --config "$curl_config"
  [[ "$(yq -r '.status // ""' "$response_file")" == 'ok' && \
    "$(yq -r '.correlation // ""' "$response_file")" == "$correlation" && \
    -n "$(yq -r '.executionId // ""' "$response_file")" ]] || {
    echo 'The authenticated Platform Canary response failed its correlation contract.' >&2
    exit 1
  }
  negative_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --max-time 30 --resolve "hooks.lab.supermorphic.com:443:${HOMELAB_PUBLIC_GATEWAY_VIP}" \
    --header 'Content-Type: application/json' \
    --data '{"correlation":"n8n-negative-auth-check"}' \
    https://hooks.lab.supermorphic.com/webhook/platform-canary)"
  [[ "$negative_status" =~ ^(400|401|403|404)$ ]] || {
    echo "Unauthenticated Platform Canary request returned HTTP $negative_status." >&2
    exit 1
  }
fi

echo "n8n $mode acceptance passed: Flux and workloads are Ready, all claims are Bound, routes and grants are exact, Prometheus targets/rules/backup metrics are healthy, and the dashboard and certificate are loaded."
if [[ "$mode" == 'full' ]]; then
  echo 'The authenticated canary and Gatus series are green, and an unauthenticated request is denied.'
else
  echo 'The public route remains suspended and absent; no canary credential was required.'
fi
