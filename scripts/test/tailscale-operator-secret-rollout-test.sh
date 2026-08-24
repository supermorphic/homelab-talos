#!/usr/bin/env bash
set -euo pipefail

# Regression: replacing operator-oauth must change the Operator Pod template so the
# process reloads the static OAuth client ID and secret that it reads at startup.
root="$(git rev-parse --show-toplevel)"
helper="$root/scripts/repository/stamp-tailscale-operator-secret.sh"
validator="$root/scripts/validate/tailscale-operator-secret-revision.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/tailscale-operator-secret-rollout-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

secret="$fixture/operator-oauth.sops.yaml"
values="$fixture/values.yaml"
candidate="$fixture/candidate-values.yaml"
rendered="$fixture/rendered.yaml"

printf '%s\n' \
  'apiVersion: v1' \
  'kind: Secret' \
  'metadata:' \
  '  name: operator-oauth' \
  >"$secret"

printf '%s\n' \
  'operatorConfig:' \
  '  hostname: tailscale-operator' \
  '  podAnnotations:' \
  '    retained.example.com/value: retained' \
  >"$values"
cp "$values" "$fixture/original-values.yaml"

[[ -x "$helper" ]] || {
  echo 'Missing executable Tailscale Operator Secret rollout helper.' >&2
  exit 1
}
"$helper" "$secret" "$values" "$candidate"

[[ "$(yq -r '.operatorConfig.podAnnotations."sops-hash"' "$candidate")" == \
  '8c52c9f2d2a3f1fc1586c54a5ff2ab8487b1ae17' ]]
[[ "$(yq -r '.operatorConfig.podAnnotations."retained.example.com/value"' "$candidate")" == \
  'retained' ]]
[[ "$(yq -r '.operatorConfig.hostname' "$candidate")" == 'tailscale-operator' ]]
cmp -s "$values" "$fixture/original-values.yaml"

cat >"$rendered" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: operator
spec:
  template:
    metadata:
      annotations:
        sops-hash: 8c52c9f2d2a3f1fc1586c54a5ff2ab8487b1ae17
YAML

[[ -x "$validator" ]] || {
  echo 'Missing executable Tailscale Operator Secret rollout validator.' >&2
  exit 1
}
"$validator" "$secret" "$candidate" "$rendered"

cp "$candidate" "$fixture/stale-values.yaml"
yq -i '.operatorConfig.podAnnotations."sops-hash" = "stale"' "$fixture/stale-values.yaml"
if "$validator" "$secret" "$fixture/stale-values.yaml" "$rendered" \
  >"$fixture/stale.out" 2>"$fixture/stale.err"; then
  echo 'The Tailscale Operator revision validator accepted a stale Secret stamp.' >&2
  exit 1
fi
rg -Fq 'OAuth Secret rollout stamp' "$fixture/stale.err"

dry_run="$(mise exec -- just --dry-run repo tailscale-operator-secrets 2>&1)"
rg -Fq 'scripts/repository/stamp-tailscale-operator-secret.sh' <<<"$dry_run"

echo 'Tailscale Operator Secret rollout stamp test passed.'
