#!/usr/bin/env bash
# Observe dedicated and bundled Flux exporter parity without changing cluster state.
set -euo pipefail

source scripts/lib/network.sh
source scripts/lib/flux-alerts.sh
source scripts/lib/flux-exporter-parity.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: flux-exporter-parity.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

flux_alerts_source
readonly namespace='monitoring'
readonly dedicated_service="$flux_alerts_service"
readonly candidate_service='kube-prometheus-stack-kube-state-metrics'
readonly prometheus_base_url='https://prometheus.lab.supermorphic.com'
readonly prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"

write_summary() {
  local message="$1"
  printf '%s\n' "$message"
  if [[ -n "${HOMELAB_TEST_RUN_DIR:-}" ]]; then
    printf '%s\n' "$message" >>"$HOMELAB_TEST_RUN_DIR/diagnostics/flux-exporter-parity.txt"
  fi
}

inventory_json() {
  local group="$1" version="$2" kind="$3" resource="$4" raw chunk
  raw="$(kubectl --kubeconfig "$kubeconfig" get "${resource}.${version}.${group}" --all-namespaces --output json)" || {
    echo "inventory-read-failed: ${group}/${version}/${kind}" >&2
    return 1
  }
  GROUP="$group" VERSION="$version" KIND="$kind" yq -o=json -I=0 '
    [.items[] |
      {
        "apiVersion": strenv(GROUP) + "/" + strenv(VERSION),
        "kind": strenv(KIND),
        "metadata": {"namespace": (.metadata.namespace // ""), "name": (.metadata.name // "")},
        "spec": {"suspend": (.spec.suspend // false)},
        "status": {"conditions": [(.status.conditions[]? | select(.type == "Ready") | {"type": "Ready", "status": .status})]}
      }
    ]
  ' <<<"$raw" || {
    echo "inventory-invalid-response: ${group}/${version}/${kind}" >&2
    return 1
  }
}

gather_inventory() {
  local items='' group version kind resource chunk
  while IFS=$'\t' read -r group version kind resource; do
    chunk="$(inventory_json "$group" "$version" "$kind" "$resource")" || return 1
    chunk="${chunk#[}"
    chunk="${chunk%]}"
    items+="${items:+,}${chunk}"
  done <<'EOF'
kustomize.toolkit.fluxcd.io	v1	Kustomization	kustomizations
helm.toolkit.fluxcd.io	v2	HelmRelease	helmreleases
source.toolkit.fluxcd.io	v1	GitRepository	gitrepositories
source.toolkit.fluxcd.io	v1	OCIRepository	ocirepositories
source.toolkit.fluxcd.io	v1	HelmRepository	helmrepositories
EOF
  printf '{"apiVersion":"v1","kind":"List","items":[%s]}\n' "$items"
}

consecutive_matches=0
for attempt in {1..12}; do
  targets_json="$(flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" '/api/v1/targets?state=active')" || {
    write_summary "attempt-${attempt}: targets-query-failed"
    consecutive_matches=0
    [[ "$attempt" -lt 12 ]] && sleep 10
    continue
  }
  dedicated_transport="$(SERVICE_NAME="$dedicated_service" NAMESPACE="$namespace" yq -r '[.data.activeTargets[] | select(.discoveredLabels.__meta_kubernetes_service_name == strenv(SERVICE_NAME) and .discoveredLabels.__meta_kubernetes_namespace == strenv(NAMESPACE)) | .labels | [has("job"), has("instance"), has("pod"), has("service"), has("endpoint"), has("namespace"), has("container")] | all] | all' <<<"$targets_json")"
  candidate_transport="$(SERVICE_NAME="$candidate_service" NAMESPACE="$namespace" yq -r '[.data.activeTargets[] | select(.discoveredLabels.__meta_kubernetes_service_name == strenv(SERVICE_NAME) and .discoveredLabels.__meta_kubernetes_namespace == strenv(NAMESPACE)) | .labels | [has("job"), has("instance"), has("pod"), has("service"), has("endpoint"), has("namespace"), has("container")] | all] | all' <<<"$targets_json")"
  if [[ "$(yq -r '.status // ""' <<<"$targets_json")" != 'success' ]] ||
    [[ "$(flux_alerts_target_count "$dedicated_service" "$namespace" <<<"$targets_json")" -le 0 ]] ||
    [[ "$(flux_alerts_target_healths "$dedicated_service" "$namespace" <<<"$targets_json")" != 'up' ]] ||
    [[ "$(flux_alerts_target_count "$candidate_service" "$namespace" <<<"$targets_json")" -le 0 ]] ||
    [[ "$(flux_alerts_target_healths "$candidate_service" "$namespace" <<<"$targets_json")" != 'up' ]] ||
    [[ "$dedicated_transport" != 'true' || "$candidate_transport" != 'true' ]]; then
    write_summary "attempt-${attempt}: target-acceptance-failed"
    consecutive_matches=0
  else
    dedicated_json="$(flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "gotk_resource_info{service=\"${dedicated_service}\",namespace=\"${namespace}\"}")" || dedicated_json=''
    candidate_json="$(flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "gotk_candidate_resource_info{service=\"${candidate_service}\",namespace=\"${namespace}\"}")" || candidate_json=''
    node_json="$(flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "kube_node_info{service=\"${candidate_service}\",namespace=\"${namespace}\"}")" || node_json=''
    pod_json="$(flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "kube_pod_info{service=\"${candidate_service}\",namespace=\"${namespace}\"}")" || pod_json=''
    inventory="$(gather_inventory)" || inventory=''
    if [[ -n "$dedicated_json" && -n "$candidate_json" && -n "$node_json" && -n "$pod_json" && -n "$inventory" &&
      "$(yq -r '.status // ""' <<<"$dedicated_json")" == 'success' && "$(yq -r '.data.result | length' <<<"$dedicated_json")" -gt 0 &&
      "$(yq -r '.status // ""' <<<"$candidate_json")" == 'success' && "$(yq -r '.data.result | length' <<<"$candidate_json")" -gt 0 &&
      "$(yq -r '.status // ""' <<<"$node_json")" == 'success' && "$(yq -r '.data.result | length' <<<"$node_json")" -gt 0 &&
      "$(yq -r '.status // ""' <<<"$pod_json")" == 'success' && "$(yq -r '.data.result | length' <<<"$pod_json")" -gt 0 ]] &&
      comparison="$(flux_exporter_compare "$dedicated_json" "$candidate_json" "$inventory" 2>&1)"; then
      consecutive_matches=$((consecutive_matches + 1))
      write_summary "attempt-${attempt}: parity-match-${consecutive_matches}-of-2"
      [[ "$consecutive_matches" -ge 2 ]] && {
        write_summary 'Flux exporter parity acceptance passed: two consecutive API-inventory matches; dedicated and bundled sources are healthy and bundled standard metrics are present.'
        exit 0
      }
    else
      [[ -z "${comparison:-}" ]] || printf '%s\n' "$comparison" >&2
      write_summary "attempt-${attempt}: parity-mismatch"
      consecutive_matches=0
    fi
  fi
  [[ "$attempt" -lt 12 ]] && sleep 10
done

echo 'Flux exporter parity acceptance failed after 12 attempts.' >&2
exit 1
