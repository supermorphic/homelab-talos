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

secret="$app/nocodb-credentials.sops.yaml"
secret_resource='  - ./nocodb-credentials.sops.yaml'
secret_listed=false
rg -Fxq -- "$secret_resource" "$app/kustomization.yaml" && secret_listed=true
if [[ -e "$secret" || "$secret_listed" == true ]]; then
  [[ -f "$secret" && "$secret_listed" == true ]] || {
    echo 'The optional NocoDB Secret and its Kustomization resource must appear together.' >&2
    exit 1
  }
  # shellcheck disable=SC2016 # yq expression intentionally uses its own variables.
  mapfile -t expected_recipients < <(
    target="$secret" yq -r \
      '.creation_rules[] | select(.path_regex as $rule | env(target) | test($rule)) | .age' \
      .sops.yaml
  )
  [[ "${#expected_recipients[@]}" -eq 1 && -n "${expected_recipients[0]}" && \
    "${expected_recipients[0]}" != null ]] || {
    echo 'Unable to select exactly one SOPS age recipient for the NocoDB credentials Secret.' >&2
    exit 1
  }
  [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == true ]] || {
    echo 'The NocoDB credentials manifest must be SOPS encrypted.' >&2
    exit 1
  }
  [[ "$(yq -r '.metadata | [.name, .namespace] | join(",")' "$secret")" == \
    'nocodb-credentials,automation-data' ]] || {
    echo 'The NocoDB credentials Secret has an unexpected identity.' >&2
    exit 1
  }
  [[ "$(yq -r '.stringData | keys | sort | join(",")' "$secret")" == \
    'DATABASE_URL,NC_ADMIN_EMAIL,NC_ADMIN_PASSWORD,NC_AUTH_JWT_SECRET,NC_CONNECTION_ENCRYPT_KEY,metadata-password,source-provisioning-header' ]] || {
    echo 'The NocoDB credentials Secret has an unexpected key set.' >&2
    exit 1
  }
  mapfile -t candidate_recipients < <(yq -r '.sops.age[].recipient' "$secret" | sort -u)
  [[ "${#candidate_recipients[@]}" -eq 1 && \
    "${candidate_recipients[0]}" == "${expected_recipients[0]}" ]] || {
    echo 'The NocoDB credentials Secret has an unexpected SOPS age recipient.' >&2
    exit 1
  }
fi

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
scripts/test/nocodb-workflow-contract-test.sh
scripts/test/nocodb-source-operation-test.sh

echo 'NocoDB source, pinned chart render, manifest, and workflow contracts passed validation.'
