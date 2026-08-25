#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo 'usage: stamp-external-dns-provider.sh <ca> <secret> <values> <output>' >&2
  exit 64
fi

ca_file="$1"
secret_file="$2"
values_file="$3"
output_file="$4"

for source_file in "$ca_file" "$secret_file" "$values_file"; do
  [[ -f "$source_file" ]] || {
    echo "Missing ExternalDNS provider source: $source_file" >&2
    exit 1
  }
done

ca_revision="$(git hash-object "$ca_file")"
secret_revision="$(git hash-object "$secret_file")"

cp -- "$values_file" "$output_file"
CA_REVISION="$ca_revision" SECRET_REVISION="$secret_revision" yq -i \
  '.podAnnotations."pihole-ca-hash" = strenv(CA_REVISION) |
   .podAnnotations."sops-hash" = strenv(SECRET_REVISION)' \
  "$output_file"

[[ "$(yq -r '.podAnnotations."pihole-ca-hash"' "$output_file")" == "$ca_revision" ]]
[[ "$(yq -r '.podAnnotations."sops-hash"' "$output_file")" == "$secret_revision" ]]
