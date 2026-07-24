#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/kube-prometheus-stack'
ks="$base/ks.yaml"
secret="$base/app/grafana-admin.sops.yaml"
values="$base/app/values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
routes="$base/config/httproutes.yaml"
expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
temp_dir="$(mktemp -d /tmp/homelab-talos-monitoring-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$secret" "$values" "$hr" "$repo" "$routes" \
  "$base/app/namespace.yaml" "$base/app/kustomization.yaml" \
  "$base/config/kustomization.yaml" kubernetes/apps/monitoring/kustomization.yaml; do
  [[ -f "$f" ]] || {
    echo "Missing Phase 10 monitoring source: $f" >&2
    echo 'Run just repo monitoring-secrets if the Grafana Secret is missing.' >&2
    exit 1
  }
done

rg -qx '  - ./monitoring' kubernetes/apps/kustomization.yaml || {
  echo 'Refusing: ./monitoring is not wired into kubernetes/apps/kustomization.yaml.' >&2
  exit 1
}

[[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
[[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
[[ "$(yq -r '.metadata.name' "$secret")" == 'grafana-admin-secret' ]]
[[ "$(yq -r '.metadata.namespace' "$secret")" == 'monitoring' ]]

suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "$ks" | sort -u)"
[[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
  echo 'Both monitoring Kustomizations must be staged together: all suspended or all active.' >&2
  exit 1
}

[[ "$(yq ea -r 'select(.metadata.name == "kube-prometheus-stack") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,longhorn' ]]
[[ "$(yq ea -r 'select(.metadata.name == "kube-prometheus-stack-config") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,kube-prometheus-stack' ]]

chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]
[[ "$(yq -r '.spec.url' "$repo")" == 'https://prometheus-community.github.io/helm-charts' ]]
[[ "$(yq -r '.prometheus.prometheusSpec.retention' "$values")" == '30d' ]]
[[ "$(yq -r '.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage' "$values")" == '50Gi' ]]
[[ "$(yq -r '.grafana.persistence.enabled' "$values")" == 'true' ]]
for c in kubeProxy kubeControllerManager kubeScheduler kubeEtcd; do
  [[ "$(yq -r ".${c}.enabled" "$values")" == 'false' ]]
done
[[ "$(yq ea -r '[select(.kind == "HTTPRoute") | .spec.hostnames[0]] | sort | join(" ")' "$routes")" == 'alertmanager.lab.supermorphic.com grafana.lab.supermorphic.com prometheus.lab.supermorphic.com' ]]
[[ "$(yq ea -r '[select(.kind == "HTTPRoute") | .spec.parentRefs[].name] | unique | .[]' "$routes")" == 'internal' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$base/app/namespace.yaml")" == 'internal' ]]

kustomize build "$base/app" >/dev/null
kustomize build "$base/config" >/dev/null

printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version "$chart_version" --namespace monitoring --values "$values" >"$temp_dir/kps.yaml"
render_kinds="$(yq ea -r '[select(.kind == "Prometheus" or .kind == "Alertmanager") | .kind] | .[]' "$temp_dir/kps.yaml" | sort -u | tr '\n' ' ')"
[[ "$render_kinds" == 'Alertmanager Prometheus ' ]]

echo 'Phase 10 monitoring source, encrypted Grafana Secret, dependency graph, values, HTTPRoutes, and pinned kube-prometheus-stack render passed validation.'
