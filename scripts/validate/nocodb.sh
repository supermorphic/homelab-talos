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
chart_url="$(yq -r '.spec.url' "$app/ocirepository.yaml")"
chart_digest="$(yq -r '.spec.ref.digest' "$app/ocirepository.yaml")"
chart_pull_output="$(helm pull "${chart_url}@${chart_digest}" \
  --destination "$temp_dir" \
  --untar)"
rg -Fq "Digest: ${chart_digest}" <<<"$chart_pull_output" || {
  echo 'The downloaded NocoDB chart does not match the pinned OCI digest.' >&2
  exit 1
}
[[ "$(yq -r '.version' "$temp_dir/nocodb/Chart.yaml")" == '1.0.0' ]] || {
  echo 'The downloaded NocoDB chart is not version 1.0.0.' >&2
  exit 1
}
helm template nocodb "$temp_dir/nocodb" \
  --namespace automation-data \
  --values "$app/values.yaml" >"$temp_dir/helm.yaml"

scripts/test/nocodb-manifest-contract-test.sh "$temp_dir/source.yaml" "$temp_dir/helm.yaml"

echo 'NocoDB source, pinned chart render, and manifest contract passed validation.'
