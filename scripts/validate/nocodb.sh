#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/automation-data/nocodb'
app="$base/app"
temp_dir="$(mktemp -d /tmp/homelab-talos-nocodb-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for file in \
  "$base/ks.yaml" \
  "$app/kustomization.yaml" \
  "$app/ocirepository.yaml" \
  "$app/helmrelease.yaml" \
  "$app/values.yaml" \
  "$app/persistentvolumeclaim.yaml" \
  "$app/httproute.yaml" \
  "$app/ciliumnetworkpolicy.yaml" \
  "$app/metadata-bootstrap-job.yaml"; do
  [[ -f "$file" ]] || { echo "Missing NocoDB source: $file" >&2; exit 1; }
done

rg -qx '  - ./nocodb/ks.yaml' kubernetes/apps/automation-data/kustomization.yaml || {
  echo 'NocoDB is not wired into the automation-data applications graph.' >&2
  exit 1
}

kustomize build "$app" >"$temp_dir/source.yaml"
helm template nocodb oci://ghcr.io/nocodb/charts/nocodb \
  --version 1.0.0 \
  --namespace automation-data \
  --values "$app/values.yaml" >"$temp_dir/helm.yaml"

scripts/test/nocodb-manifest-contract-test.sh "$temp_dir/source.yaml" "$temp_dir/helm.yaml"

echo 'NocoDB source, pinned chart render, and manifest contract passed validation.'
