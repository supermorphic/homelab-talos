#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 || "$#" -gt 4 ]]; then
  echo 'usage: external-dns-provider-revisions.sh <ca> <secret> <values> [rendered-manifest]' >&2
  exit 64
fi

ca_file="$1"
secret_file="$2"
values_file="$3"
rendered_file="${4:-}"

ca_revision="$(git hash-object "$ca_file")"
secret_revision="$(git hash-object "$secret_file")"
configured_ca_revision="$(yq -r '.podAnnotations."pihole-ca-hash" // ""' "$values_file")"
configured_secret_revision="$(yq -r '.podAnnotations."sops-hash" // ""' "$values_file")"

[[ "$configured_ca_revision" == "$ca_revision" ]] || {
  echo "Pi-hole CA rollout stamp must equal the tracked CA Git blob revision." >&2
  exit 1
}
[[ "$configured_secret_revision" == "$secret_revision" ]] || {
  echo "Pi-hole Secret rollout stamp must equal the encrypted Secret Git blob revision." >&2
  exit 1
}

if [[ -n "$rendered_file" ]]; then
  rendered_ca_revision="$(yq ea -r '
    select(.kind == "Deployment" and .metadata.name == "external-dns-internal")
    | .spec.template.metadata.annotations."pihole-ca-hash" // ""
  ' "$rendered_file")"
  rendered_secret_revision="$(yq ea -r '
    select(.kind == "Deployment" and .metadata.name == "external-dns-internal")
    | .spec.template.metadata.annotations."sops-hash" // ""
  ' "$rendered_file")"
  [[ "$rendered_ca_revision" == "$ca_revision" ]] || {
    echo 'Rendered ExternalDNS Deployment does not carry the Pi-hole CA rollout stamp.' >&2
    exit 1
  }
  [[ "$rendered_secret_revision" == "$secret_revision" ]] || {
    echo 'Rendered ExternalDNS Deployment does not carry the Pi-hole Secret rollout stamp.' >&2
    exit 1
  }
fi
