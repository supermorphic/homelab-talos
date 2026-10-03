#!/usr/bin/env bash
# Operator-run: requires the operator's age identity and privately supplied API key.
set -euo pipefail

expected_confirmation='write:monitoring:homepage-komga:sops'
[[ "${HOMEPAGE_KOMGA_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
	echo 'Refusing to write the Homepage Komga Secret.' >&2
	echo "Set HOMEPAGE_KOMGA_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
	exit 1
}
[[ -n "${KOMGA_API_KEY:-}" ]] || {
	echo 'Set KOMGA_API_KEY privately from Komga account settings.' >&2
	exit 1
}

base='kubernetes/apps/monitoring/homepage/app'
target="$base/homepage-komga.sops.yaml"
deployment="$base/deployment.yaml"
kustomization="$base/kustomization.yaml"
[[ -f "$deployment" && -f "$kustomization" ]]
just repo secrets
umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homepage-komga-secrets.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

export KOMGA_API_KEY
yq -n \
	'.apiVersion = "v1" |
   .kind = "Secret" |
   .metadata.name = "homepage-komga" |
   .metadata.namespace = "homepage" |
   .type = "Opaque" |
   .stringData.apiKey = strenv(KOMGA_API_KEY)' >"$temp_dir/secret.yaml"
sops --encrypt --filename-override "$target" "$temp_dir/secret.yaml" \
	>"$temp_dir/secret.sops.yaml"
[[ "$(sops filestatus "$temp_dir/secret.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.sops.age[].recipient' "$temp_dir/secret.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
if rg -Fq -- "$KOMGA_API_KEY" "$temp_dir/secret.sops.yaml"; then
	echo 'Refusing: API key is present in the encrypted output.' >&2
	exit 1
fi

# Prepare all Git changes before installing the encrypted artifact. The resource
# is absent until credentials exist, so an initial merge cannot break Flux.
cp -- "$kustomization" "$temp_dir/kustomization.yaml"
if [[ "$(yq -r '.resources | contains(["./homepage-komga.sops.yaml"])' \
	"$temp_dir/kustomization.yaml")" != 'true' ]]; then
	yq -i '.resources += ["./homepage-komga.sops.yaml"]' "$temp_dir/kustomization.yaml"
fi
cp -- "$deployment" "$temp_dir/deployment.yaml"
REVISION="$(git hash-object "$temp_dir/secret.sops.yaml")" yq -i \
	'.spec.template.metadata.annotations."homepage-komga-sops-hash" = strenv(REVISION)' \
	"$temp_dir/deployment.yaml"

mv -- "$temp_dir/secret.sops.yaml" "$target"
mv -- "$temp_dir/kustomization.yaml" "$kustomization"
mv -- "$temp_dir/deployment.yaml" "$deployment"
echo 'Wrote the encrypted Homepage Komga Secret, Flux resource and rollout revision. Commit these three files together.'
