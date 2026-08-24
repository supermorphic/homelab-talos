#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 3 ]] || {
  echo 'Usage: stamp-qbit-manage-secret.sh <encrypted-secret> <values> <output>' >&2
  exit 2
}

secret="$1"
values="$2"
output="$3"
revision="$(git hash-object "$secret")"

REVISION="$revision" yq \
  '.controllers."qbit-manage".pod.annotations."sops-hash" = strenv(REVISION)' \
  "$values" >"$output"

[[ "$(yq -r '.controllers."qbit-manage".pod.annotations."sops-hash"' "$output")" == \
  "$revision" ]]
