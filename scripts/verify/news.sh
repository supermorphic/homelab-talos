#!/usr/bin/env bash
# Read-only deployed observations. Staging success is not service acceptance.
set -euo pipefail
source scripts/lib/common.sh
source scripts/lib/network.sh
source scripts/lib/flux-alerts.sh
require_bash
[[ "$#" -eq 1 ]] || { echo 'Usage: news.sh <task-scoped-kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
kc=(kubectl --kubeconfig "$kubeconfig")
fail() { echo "News verification failed: $*" >&2; exit 1; }
[[ -f "$kubeconfig" ]] || fail 'Generate the task-scoped kubeconfig first.'
base='kubernetes/apps/news'
staged=$(yq -r '.spec.suspend' "$base/freshrss/ks.yaml")
for unit in namespace postgresql freshrss alerts; do
  [[ "$(yq -r '.spec.suspend' "$base/$unit/ks.yaml")" == "$staged" ]] || fail 'News Flux units have mixed activation intent.'
done
[[ "$staged" == true || "$staged" == false ]] || fail 'News suspension intent is invalid.'
selected=$(yq -r '[.resources[] | select(. == "./news")] | length' kubernetes/apps/kustomization.yaml)
if [[ "$staged" == true ]]; then
  [[ "$selected" == 0 ]] || fail 'Suspended news is selected by the root application list.'
  for name in news news-postgresql freshrss news-alerts news-graby; do
    live=$("${kc[@]}" --namespace flux-system get kustomization "$name" --ignore-not-found --output json)
    if [[ -n "$live" ]]; then
      yq -p=json -e '.spec.suspend == true' - >/dev/null <<<"$live" || fail 'A staged news Flux unit is live and active.'
    fi
  done
  for resource in deployment/freshrss statefulset/news-postgresql deployment/news-graby; do
    live=$("${kc[@]}" --namespace news get "$resource" --ignore-not-found --output name) || fail 'Cannot read staged news workload state.'
    [[ -z "$live" ]] || fail 'A staged news workload exists.'
  done
  echo 'News verification passed: phase=staged-absent; no runtime, backup, network, or native acceptance claimed.'
  exit 0
fi
[[ "$selected" == 1 ]] || fail 'Active news is absent from the root application list.'
for name in news news-postgresql freshrss news-alerts; do
  live=$("${kc[@]}" --namespace flux-system get kustomization "$name" --output json)
  # shellcheck disable=SC2016 # yq owns this literal expression and its variable.
  yq -p=json -e '
    .metadata.generation as $g |
    [(.spec.suspend == false), (.status.observedGeneration == $g),
     ([.status.conditions[]? | select(.type == "Ready" and .status == "True" and .observedGeneration == $g)] | length == 1)] | all
  ' - >/dev/null <<<"$live" || fail 'A news Flux unit is not current and Ready.'
done
live=$("${kc[@]}" --namespace news get deployment freshrss --output json)
yq -p=json -e '.spec.replicas == 1 and .status.observedGeneration == .metadata.generation and .status.availableReplicas == 1' - >/dev/null <<<"$live" || fail 'FreshRSS Deployment is unavailable.'
live=$("${kc[@]}" --namespace news get statefulset news-postgresql --output json)
yq -p=json -e '.spec.replicas == 1 and .status.observedGeneration == .metadata.generation and .status.readyReplicas == 1' - >/dev/null <<<"$live" || fail 'News database StatefulSet is unavailable.'
"${kc[@]}" --namespace news get servicemonitor freshrss --output name >/dev/null
"${kc[@]}" --namespace monitoring get prometheusrule news --output name >/dev/null
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
require_signal() {
  local query="$1" result
  result=$(flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" "$query")
  yq -p=json -e '.status == "success" and (.data.result | length == 1)' - >/dev/null <<<"$result" || fail 'A required news observation is missing or unhealthy.'
}
require_signal 'max(up{namespace="news",service="freshrss"}) == 1'
require_signal 'max(news_database_up{namespace="news",service="freshrss"}) == 1'
require_signal 'max(news_feeds_failed{namespace="news",service="freshrss"}) == 0'
require_signal 'max(news_feeds_stale{namespace="news",service="freshrss"}) == 0'
require_signal 'max(gatus_results_endpoint_success{group="Media",name="freshrss"}) == 1'
require_signal 'max(news_refresh_last_completed_timestamp_seconds{namespace="news",service="freshrss"}) > 0 and time() - max(news_refresh_last_completed_timestamp_seconds{namespace="news",service="freshrss"}) < 3600'
require_signal 'max(news_backup_last_success_timestamp_seconds{namespace="news",service="freshrss"}) > 0 and time() - max(news_backup_last_success_timestamp_seconds{namespace="news",service="freshrss"}) < 36 * 60 * 60'
require_signal 'max(longhorn_volume_last_backup_at{pvc_namespace="news",pvc="news-backups"}) > 0 and time() - max(longhorn_volume_last_backup_at{pvc_namespace="news",pvc="news-backups"}) < 48 * 60 * 60'
worker=$("${kc[@]}" --namespace news get deployment news-graby --ignore-not-found --output json)
if [[ -n "$worker" ]]; then
  yq -p=json -e '.status.availableReplicas == 1 and .status.observedGeneration == .metadata.generation' - >/dev/null <<<"$worker" && echo 'Extraction worker observation: available.' || echo 'Extraction worker observation: unavailable; FreshRSS acceptance is independent.'
else
  echo 'Extraction worker observation: absent; FreshRSS acceptance is independent.'
fi
echo 'News read-only observations passed: phase=active; readiness, refresh, feed health, local backup, and Longhorn transfer are current.'
echo 'Paired-set off-cluster contents, isolated restore, publisher quality, network denial, and native-client acceptance require separate evidence.'
