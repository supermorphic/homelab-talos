#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 3 ]] || {
  echo 'Usage: stamp-tailscale-operator-secret.sh <encrypted-secret> <values> <output>' >&2
  exit 2
}

secret="$1"
values="$2"
output="$3"
revision="$(git hash-object "$secret")"

REVISION="$revision" yq \
  '.operatorConfig.podAnnotations."sops-hash" = strenv(REVISION)' \
  "$values" >"$output"

[[ "$(yq -r '.operatorConfig.podAnnotations."sops-hash"' "$output")" == "$revision" ]]
