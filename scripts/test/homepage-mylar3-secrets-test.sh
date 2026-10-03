#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
helper="$repo_root/scripts/repository/homepage-mylar3-secrets.sh"
[[ -x "$helper" ]] || {
	echo 'Missing Homepage Mylar3 Secret writer.' >&2
	exit 1
}
fixture="$(mktemp -d "${TMPDIR:-/tmp}/homepage-mylar3-secrets-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/kubernetes/apps/monitoring/homepage/app"
app="$fixture/kubernetes/apps/monitoring/homepage/app"
cp "$repo_root/.sops.yaml" "$fixture/.sops.yaml"
cp "$repo_root/kubernetes/apps/monitoring/homepage/app/"{deployment,kustomization}.yaml "$app/"
printf '#!/usr/bin/env bash\n[[ "$*" == "repo secrets" ]]\n' >"$fixture/bin/just"
# Model only the encryption boundary; registration and rollout edits use real
# yq/Git and the production writer. No age private key is created or loaded.
cat >"$fixture/bin/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == filestatus ]]; then
  [[ "$#" == 2 ]]
  echo '{"encrypted":true}'
else
  [[ "$#" == 4 && "$1" == --encrypt && "$2" == --filename-override ]]
  [[ "$3" == 'kubernetes/apps/monitoring/homepage/app/homepage-mylar3.sops.yaml' ]]
  [[ "${TEST_SOPS_FAIL:-false}" != true ]] || exit 1
  recipient="$(yq -r '.creation_rules[1].age' .sops.yaml)"
  if [[ "${TEST_SOPS_PLAINTEXT:-false}" == true ]]; then
    RECIPIENT="$recipient" yq '.sops.age[0].recipient = strenv(RECIPIENT)' "${@: -1}"
    exit 0
  fi
  RECIPIENT="$recipient" yq \
    '.stringData.apiKey = "ENC[AES256_GCM,data:synthetic,iv:fixture,tag:fixture,type:str]" |
     .sops.age[0].recipient = strenv(RECIPIENT)' "${@: -1}"
fi
EOF
chmod +x "$fixture/bin/just" "$fixture/bin/sops"
export PATH="$fixture/bin:$PATH"
cd "$fixture"
export MYLAR3_API_KEY='fixture-key'
unset HOMEPAGE_MYLAR3_SECRETS_CONFIRM

before="$(git hash-object "$app/deployment.yaml" "$app/kustomization.yaml")"
if "$helper" >"$fixture/stdout" 2>"$fixture/stderr"; then
	echo 'Secret writer accepted missing intent confirmation.' >&2
	exit 1
fi
[[ ! -e "$app/homepage-mylar3.sops.yaml" ]]
[[ "$(git hash-object "$app/deployment.yaml" "$app/kustomization.yaml")" == "$before" ]]

export HOMEPAGE_MYLAR3_SECRETS_CONFIRM='write:monitoring:homepage-mylar3:sops'
if MYLAR3_API_KEY='' "$helper" >"$fixture/stdout" 2>"$fixture/stderr"; then
	echo 'Secret writer accepted an empty API key.' >&2
	exit 1
fi
[[ ! -e "$app/homepage-mylar3.sops.yaml" ]]
[[ "$(git hash-object "$app/deployment.yaml" "$app/kustomization.yaml")" == "$before" ]]
"$helper" >"$fixture/stdout" 2>"$fixture/stderr"
secret="$app/homepage-mylar3.sops.yaml"
[[ "$(yq -r '[.metadata.name, .metadata.namespace] | join(",")' "$secret")" == 'homepage-mylar3,homepage' ]]
[[ "$(yq -r '[.resources[] | select(. == "./homepage-mylar3.sops.yaml")] | length' \
	"$app/kustomization.yaml")" == '1' ]]
first_revision="$(git hash-object "$secret")"
[[ "$(yq -r '.spec.template.metadata.annotations."homepage-mylar3-sops-hash"' \
	"$app/deployment.yaml")" == "$first_revision" ]]
[[ "$(yq -r '.spec.template.metadata.annotations."sops-hash"' "$app/deployment.yaml")" == "$(yq -r '.spec.template.metadata.annotations."sops-hash"' \
	"$repo_root/kubernetes/apps/monitoring/homepage/app/deployment.yaml")" ]]
if rg -Fq -- "$MYLAR3_API_KEY" "$secret" "$fixture/stdout" "$fixture/stderr"; then
	echo 'Secret writer exposed the supplied key.' >&2
	exit 1
fi

# Failed encryption or plaintext output must preserve the previous credential
# and both Flux inputs, rather than installing any part of a new revision.
before="$(git hash-object "$secret" "$app/deployment.yaml" "$app/kustomization.yaml")"
for failure in TEST_SOPS_FAIL TEST_SOPS_PLAINTEXT; do
	if env "$failure=true" "$helper" >"$fixture/stdout" 2>"$fixture/stderr"; then
		echo "Secret writer accepted $failure." >&2
		exit 1
	fi
	[[ "$(git hash-object "$secret" "$app/deployment.yaml" "$app/kustomization.yaml")" == "$before" ]]
	if rg -Fq -- "$MYLAR3_API_KEY" "$fixture/stdout" "$fixture/stderr"; then
		echo 'Secret writer exposed the supplied key on failure.' >&2
		exit 1
	fi
done

# A second write must register the resource once and stamp the new ciphertext.
sed 's/data:synthetic/data:rotated/' "$fixture/bin/sops" >"$fixture/bin/sops.next"
mv "$fixture/bin/sops.next" "$fixture/bin/sops"
chmod +x "$fixture/bin/sops"
"$helper" >"$fixture/stdout" 2>"$fixture/stderr"
[[ "$(yq -r '[.resources[] | select(. == "./homepage-mylar3.sops.yaml")] | length' \
	"$app/kustomization.yaml")" == '1' ]]
[[ "$(git hash-object "$secret")" != "$first_revision" ]]
[[ "$(yq -r '.spec.template.metadata.annotations."homepage-mylar3-sops-hash"' \
	"$app/deployment.yaml")" == "$(git hash-object "$secret")" ]]

echo 'Homepage Mylar3 intent guard, Secret registration and rotation rollout passed.'
