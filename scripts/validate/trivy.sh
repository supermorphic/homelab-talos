#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/security/trivy-operator'
ks="$base/ks.yaml"
values="$base/app/values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
temp_dir="$(mktemp -d /tmp/homelab-talos-trivy-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$values" "$hr" "$repo" "$base/app/namespace.yaml" "$base/app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing Trivy source: $f" >&2; exit 1; }
done
rg -qx '  - ./trivy-operator/ks.yaml' kubernetes/apps/security/kustomization.yaml || {
  echo 'Refusing: ./trivy-operator/ks.yaml is not listed in the security kustomization.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium' ]]
chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]
[[ "$(yq -r '.spec.url' "$repo")" == 'https://aquasecurity.github.io/helm-charts' ]]
[[ "$(yq -r '.operator.sbomGenerationEnabled' "$values")" == 'false' ]]
[[ "$(yq -r '.operator.clusterComplianceEnabled' "$values")" == 'false' ]]
# infra-assessment cannot run on Talos (read-only host); keep it disabled.
[[ "$(yq -r '.operator.infraAssessmentScannerEnabled' "$values")" == 'false' ]]
[[ "$(yq -r '.trivy.ignoreUnfixed' "$values")" == 'true' ]]
[[ "$(yq -r '.serviceMonitor.enabled' "$values")" == 'true' ]]

kustomize build "$base/app" >/dev/null
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template trivy-operator trivy-operator --repo https://aquasecurity.github.io/helm-charts --version "$chart_version" --namespace trivy-system --values "$values" >"$temp_dir/trivy.yaml"
[[ "$(yq ea 'select(.kind == "ConfigMap" and .metadata.name == "trivy-operator-config") | .data.OPERATOR_SBOM_GENERATION_ENABLED' "$temp_dir/trivy.yaml")" == 'false' ]]

echo 'Trivy Operator source, wiring, dependency, pinned chart, scanner settings, and render passed validation.'
