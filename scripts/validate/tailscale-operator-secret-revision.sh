#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 3 ]] || {
  echo 'Usage: tailscale-operator-secret-revision.sh <encrypted-secret> <values> <rendered>' >&2
  exit 2
}

secret="$1"
values="$2"
rendered="$3"
expected="$(git hash-object "$secret")"
configured="$(yq -r '.operatorConfig.podAnnotations."sops-hash" // ""' "$values")"
deployed="$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "operator") | .spec.template.metadata.annotations."sops-hash" // ""' "$rendered")"

[[ "$configured" == "$expected" ]] || {
  echo "Tailscale Operator OAuth Secret rollout stamp is '$configured'; expected '$expected'." >&2
  exit 1
}
[[ "$deployed" == "$expected" ]] || {
  echo "Rendered Tailscale Operator Deployment rollout stamp is '$deployed'; expected '$expected'." >&2
  exit 1
}
