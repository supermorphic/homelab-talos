#!/usr/bin/env bash
# Operator-supplied API credentials; encryption uses only the public age recipient.
set -euo pipefail

fail() { echo "Homepage FreshRSS Secret write stopped: $*" >&2; exit 1; }
[[ "${HOMEPAGE_FRESHRSS_SECRETS_CONFIRM:-}" == 'write:monitoring:homepage-freshrss:sops' ]] ||
	fail 'set HOMEPAGE_FRESHRSS_SECRETS_CONFIRM to write:monitoring:homepage-freshrss:sops.'
[[ "${NEWS_OPERATOR_NAME:-}" =~ ^[A-Za-z][A-Za-z0-9_]{0,31}$ ]] ||
	fail 'supply NEWS_OPERATOR_NAME as the existing FreshRSS username.'
news_api_password="${NEWS_API_PASSWORD:-}"
[[ ${#news_api_password} -ge 32 && ${#news_api_password} -le 4096 && "$news_api_password" =~ ^[!-~]+$ ]] ||
	fail 'supply NEWS_API_PASSWORD as 32 to 4096 printable non-space characters.'

base='kubernetes/apps/monitoring/homepage/app'
target="$base/homepage-freshrss.sops.yaml"
deployment="$base/deployment.yaml"
kustomization="$base/kustomization.yaml"
for path in "$base" "$target" "$deployment" "$kustomization" .sops.yaml; do
	[[ ! -L "$path" ]] || fail 'target files must not be symlinks.'
done
[[ -f "$deployment" && -f "$kustomization" && -f .sops.yaml ]] ||
	fail 'run from the assigned repository worktree.'
originals="$(git hash-object "$deployment" "$kustomization" .sops.yaml)"
original_secret=''
[[ ! -f "$target" ]] || original_secret="$(git hash-object "$target")"
# shellcheck disable=SC2016 # yq owns the literal $rule expression.
recipient="$(TARGET="$target" yq -r \
	'[.creation_rules[] | select(.path_regex as $rule | strenv(TARGET) | test($rule))] |
   select(length == 1) | .[0] | select(.encrypted_regex == "^(data|stringData)$") | .age' \
	.sops.yaml)"
[[ "$recipient" =~ ^age1[0-9a-z]{58}$ ]] || fail 'exactly one public age recipient is required.'
umask 077
temp_dir="$(mktemp -d "$base/.homepage-freshrss.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
export NEWS_OPERATOR_NAME NEWS_API_PASSWORD
if ! yq -n \
	'.apiVersion = "v1" | .kind = "Secret" | .type = "Opaque" |
   .metadata.name = "homepage-freshrss" | .metadata.namespace = "homepage" |
   .stringData.username = strenv(NEWS_OPERATOR_NAME) |
   .stringData.password = strenv(NEWS_API_PASSWORD)' 2>/dev/null |
	sops --encrypt --input-type yaml --output-type yaml --filename-override "$target" \
	/dev/stdin >"$temp_dir/secret.sops.yaml" 2>/dev/null; then
	fail 'encryption failed; tool output withheld.'
fi
[[ "$(sops filestatus "$temp_dir/secret.sops.yaml" | yq -r '.encrypted')" == true ]]
[[ "$(yq -r '.sops.age[].recipient' "$temp_dir/secret.sops.yaml")" == "$recipient" ]]
[[ "$(yq -r '.stringData | keys | sort | join(",")' "$temp_dir/secret.sops.yaml")" == password,username ]]
[[ "$(yq -r '[.stringData[] | test("^ENC\\[AES256_GCM,")] | all' "$temp_dir/secret.sops.yaml")" == true ]]

# Register only real ciphertext and stamp a rollout for initial setup and rotation.
cp -- "$kustomization" "$temp_dir/kustomization.yaml"
if [[ "$(yq -r '.resources | contains(["./homepage-freshrss.sops.yaml"])' \
	"$temp_dir/kustomization.yaml")" != true ]]; then
	yq -i '.resources += ["./homepage-freshrss.sops.yaml"]' "$temp_dir/kustomization.yaml"
fi
cp -- "$deployment" "$temp_dir/deployment.yaml"
REVISION="$(git hash-object "$temp_dir/secret.sops.yaml")" yq -i \
	'.spec.template.metadata.annotations."homepage-freshrss-sops-hash" = strenv(REVISION)' \
	"$temp_dir/deployment.yaml"
[[ "$(git hash-object "$deployment" "$kustomization" .sops.yaml)" == "$originals" ]] ||
	fail 'repository inputs changed during encryption.'
current_secret=''
[[ ! -f "$target" ]] || current_secret="$(git hash-object "$target")"
[[ "$current_secret" == "$original_secret" ]] || fail 'encrypted target changed during encryption.'
mv -- "$temp_dir/secret.sops.yaml" "$target"
mv -- "$temp_dir/kustomization.yaml" "$kustomization"
mv -- "$temp_dir/deployment.yaml" "$deployment"
echo 'Wrote the encrypted Homepage FreshRSS Secret, resource selection and rollout revision. Commit these three files together.'
