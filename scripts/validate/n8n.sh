#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/automation'
ns="$base/namespace/app/namespace.yaml"

for file in "$base/kustomization.yaml" "$base/namespace/ks.yaml" \
  "$base/namespace/app/kustomization.yaml" "$ns"; do
  [[ -f "$file" ]] || { echo "Missing n8n platform source: $file" >&2; exit 1; }
done
yq -e '.resources[] | select(. == "./automation")' kubernetes/apps/kustomization.yaml >/dev/null
[[ "$(yq -r '.metadata.name' "$ns")" == 'automation' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]] || {
  echo 'n8n automation namespace Gateway access must be internal.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$ns")" == 'restricted' ]]
[[ "$(yq -r '.spec.dependsOn[0].name' "$base/namespace/ks.yaml")" == 'cilium' ]]
kustomize build "$base/namespace/app" >/dev/null
echo 'n8n automation namespace source passed validation.'
