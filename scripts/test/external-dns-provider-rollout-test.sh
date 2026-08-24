#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
helper="$repo_root/scripts/repository/stamp-external-dns-provider.sh"
validator="$repo_root/scripts/validate/external-dns-provider-revisions.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/external-dns-provider-rollout-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

ca="$fixture/pihole-ca.crt"
secret="$fixture/pihole-password.sops.yaml"
values="$fixture/values.yaml"
candidate="$fixture/candidate.yaml"
rendered="$fixture/rendered.yaml"

printf 'public ca\n' >"$ca"
printf 'encrypted secret\n' >"$secret"
cat >"$values" <<'YAML'
provider:
  name: pihole
podAnnotations:
  retained.example.com/value: retained
YAML
cp "$values" "$fixture/original-values.yaml"

"$helper" "$ca" "$secret" "$values" "$candidate"

[[ "$(yq -r '.podAnnotations."pihole-ca-hash"' "$candidate")" == \
  '88d2d5508b9fa9ba8e0d8820c7a1a971a5bd4e6c' ]]
[[ "$(yq -r '.podAnnotations."sops-hash"' "$candidate")" == \
  '63e9b88dca722795449d3fd899dcbec25c0bcdbc' ]]
[[ "$(yq -r '.podAnnotations."retained.example.com/value"' "$candidate")" == 'retained' ]]
[[ "$(yq -r '.provider.name' "$candidate")" == 'pihole' ]]
cmp -s "$values" "$fixture/original-values.yaml"

cat >"$rendered" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns-internal
spec:
  template:
    metadata:
      annotations:
        pihole-ca-hash: 88d2d5508b9fa9ba8e0d8820c7a1a971a5bd4e6c
        sops-hash: 63e9b88dca722795449d3fd899dcbec25c0bcdbc
YAML
"$validator" "$ca" "$secret" "$candidate" "$rendered"

cp "$candidate" "$fixture/stale-values.yaml"
yq -i '.podAnnotations."sops-hash" = "stale"' "$fixture/stale-values.yaml"
if "$validator" "$ca" "$secret" "$fixture/stale-values.yaml" "$rendered" \
  >"$fixture/stale.out" 2>"$fixture/stale.err"; then
  echo 'The provider revision validator accepted a stale Secret stamp.' >&2
  exit 1
fi
rg -Fq 'Pi-hole Secret rollout stamp' "$fixture/stale.err"

recipes="$(mise exec -- just --list repo)"
rg -q '^[[:space:]]+foundation-provider-secrets([[:space:]]|$)' <<<"$recipes"
if rg -q '^[[:space:]]+phase[[:digit:]]+-secrets([[:space:]]|$)' <<<"$recipes"; then
  echo 'A retired phase-era provider-secret recipe remains available.' >&2
  exit 1
fi

dry_run="$(mise exec -- just --dry-run repo foundation-provider-secrets 2>&1)"
rg -Fq 'FOUNDATION_PROVIDER_SECRETS_CONFIRM' <<<"$dry_run"
rg -Fq "expected_confirmation='write:foundation-providers:cloudflare-and-pihole:sops'" \
  <<<"$dry_run"

bootstrap_dry_run="$(mise exec -- just --dry-run bootstrap foundation 2>&1)"
rg -Fq 'FOUNDATION_NETWORK_CONFIRM' <<<"$bootstrap_dry_run"
rg -Fq 'FOUNDATION_BOOTSTRAP_CONFIRM' <<<"$bootstrap_dry_run"
rg -Fq "expected_bootstrap_confirmation='bootstrap:foundation:internal-gateway:192.168.90.30'" \
  <<<"$bootstrap_dry_run"
if rg -qi 'phase[[:digit:]]' <<<"$bootstrap_dry_run"; then
  echo 'The foundation bootstrap interface still exposes phase-era language.' >&2
  exit 1
fi

echo 'ExternalDNS provider rollout stamp and generic provider-secret interface tests passed.'
