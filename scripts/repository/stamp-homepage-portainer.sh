#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 3 ]] || {
	echo 'Usage: stamp-homepage-portainer.sh <encrypted-secret> <deployment> <output>' >&2
	exit 2
}

secret_file="$1"
deployment_file="$2"
output_file="$3"

[[ -f "$secret_file" ]] || {
	echo "Missing encrypted Homepage Portainer Secret: $secret_file" >&2
	exit 1
}
[[ -f "$deployment_file" ]] || {
	echo "Missing Homepage Deployment: $deployment_file" >&2
	exit 1
}

revision="$(git hash-object "$secret_file")"
cp -- "$deployment_file" "$output_file"
REVISION="$revision" yq -i \
	'.spec.template.metadata.annotations."homepage-portainer-sops-hash" = strenv(REVISION)' \
	"$output_file"

[[ "$(yq -r '.spec.template.metadata.annotations."homepage-portainer-sops-hash"' \
	"$output_file")" == "$revision" ]]
