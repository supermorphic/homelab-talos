#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/storage/longhorn'
ks="$base/ks.yaml"
secret="$base/config/nas-credentials.sops.yaml"
values="$base/app/values.yaml"
hr="$base/app/helmrelease.yaml"
repo="$base/app/helmrepository.yaml"
jobs="$base/config/recurring-jobs.yaml"
backuptarget="$base/config/backup-target.yaml"
expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
temp_dir="$(mktemp -d /tmp/homelab-talos-storage-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$secret" "$values" "$hr" "$repo" "$jobs" "$backuptarget" \
  "$base/app/namespace.yaml" "$base/app/kustomization.yaml" \
  "$base/config/kustomization.yaml" kubernetes/apps/storage/kustomization.yaml; do
  [[ -f "$f" ]] || {
    echo "Missing Longhorn storage source: $f" >&2
    echo 'Run just repo storage-secrets if the CIFS Secret is missing.' >&2
    exit 1
  }
done

rg -qx '  - ./storage' kubernetes/apps/kustomization.yaml || {
  echo 'Refusing: ./storage is not wired into kubernetes/apps/kustomization.yaml.' >&2
  exit 1
}

[[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
[[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
[[ "$(yq -r '.metadata.name' "$secret")" == 'nas-credentials' ]]
[[ "$(yq -r '.metadata.namespace' "$secret")" == 'longhorn-system' ]]

suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "$ks" | sort -u)"
[[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
  echo 'Both storage Kustomizations must be staged together: all suspended or all active.' >&2
  exit 1
}

[[ "$(yq ea -r 'select(.metadata.name == "longhorn") | .spec.dependsOn[].name' "$ks")" == 'cilium' ]]
[[ "$(yq ea -r 'select(.metadata.name == "longhorn-config") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,longhorn' ]]

chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
[[ -n "$chart_version" && "$chart_version" != 'null' ]]
[[ "$(yq -r '.spec.url' "$repo")" == 'https://charts.longhorn.io' ]]
[[ "$(yq -r '.defaultSettings.defaultDataPath' "$values")" == '/var/mnt/longhorn' ]]
[[ "$(yq -r '.defaultSettings.replicaSoftAntiAffinity' "$values")" == 'false' ]]
[[ "$(yq -r '.persistence.defaultClassReplicaCount' "$values")" == '2' ]]
[[ "$(yq -r '.kind' "$backuptarget")" == 'BackupTarget' ]]
[[ "$(yq -r '.metadata.name' "$backuptarget")" == 'default' ]]
[[ "$(yq -r '.spec.backupTargetURL' "$backuptarget")" == 'cifs://192.168.0.3/Longhorn' ]]
[[ "$(yq -r '.spec.credentialSecret' "$backuptarget")" == 'nas-credentials' ]]
[[ "$(yq ea -r '[select(.kind == "RecurringJob") | .spec.task] | .[]' "$jobs" | sort | tr '\n' ' ')" == 'backup snapshot ' ]]

kustomize build "$base/app" >/dev/null
kustomize build "$base/config" >/dev/null

printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template longhorn longhorn --repo https://charts.longhorn.io --version "$chart_version" --namespace longhorn-system --values "$values" >"$temp_dir/longhorn.yaml"
rg -q '^  name: longhorn-manager$' "$temp_dir/longhorn.yaml"

echo 'Longhorn storage source, encrypted CIFS Secret, dependency graph, values, and pinned render passed validation.'
