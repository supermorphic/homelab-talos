#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
helper="$repo_root/scripts/repository/stamp-homepage-portainer.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/homepage-portainer-rollout-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

secret="$fixture/homepage-portainer.sops.yaml"
deployment="$fixture/deployment.yaml"
candidate="$fixture/candidate.yaml"

cat >"$secret" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: homepage-portainer
  namespace: homepage
stringData:
  apiKey: ENC[AES256_GCM,data:first,iv:fixture,tag:fixture,type:str]
EOF

cat >"$deployment" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homepage
  namespace: homepage
spec:
  template:
    metadata:
      annotations:
        sops-hash: ntfy-revision
EOF

"$helper" "$secret" "$deployment" "$candidate"
first_revision="$(git hash-object "$secret")"
[[ "$(yq -r '.spec.template.metadata.annotations."homepage-portainer-sops-hash"' "$candidate")" == "$first_revision" ]]
[[ "$(yq -r '.spec.template.metadata.annotations."sops-hash"' "$candidate")" == 'ntfy-revision' ]]
[[ "$(yq -r '.spec.template.metadata.annotations."homepage-portainer-sops-hash" // ""' "$deployment")" == '' ]]

yq -i '.stringData.apiKey = "ENC[AES256_GCM,data:second,iv:fixture,tag:fixture,type:str]"' \
	"$secret"
"$helper" "$secret" "$deployment" "$candidate"
second_revision="$(git hash-object "$secret")"
[[ "$second_revision" != "$first_revision" ]]
[[ "$(yq -r '.spec.template.metadata.annotations."homepage-portainer-sops-hash"' "$candidate")" == "$second_revision" ]]

echo 'Homepage Portainer token rollout tests passed.'
