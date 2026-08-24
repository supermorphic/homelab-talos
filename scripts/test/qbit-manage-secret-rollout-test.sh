#!/usr/bin/env bash
set -euo pipefail

# Regression: rotating qbit-manage-secret must change the qbit_manage Pod template so
# credentials loaded through envFrom are re-read by a replacement Pod.
root="$(git rev-parse --show-toplevel)"
helper="$root/scripts/repository/stamp-qbit-manage-secret.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/qbit-manage-secret-rollout-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

secret="$fixture/qbit-manage-secret.sops.yaml"
values="$fixture/values.yaml"
candidate="$fixture/candidate-values.yaml"

printf '%s\n' \
  'apiVersion: v1' \
  'kind: Secret' \
  'metadata:' \
  '  name: qbit-manage-secret' \
  >"$secret"

printf '%s\n' \
  'controllers:' \
  '  qbit-manage:' \
  '    pod:' \
  '      annotations:' \
  '        config-hash: config-revision' \
  >"$values"

"$helper" "$secret" "$values" "$candidate"

[[ "$(yq -r '.controllers."qbit-manage".pod.annotations."sops-hash"' "$candidate")" == \
  'fb2c37cd37165fbba6092d34015cd53b0c6e2b22' ]]
[[ "$(yq -r '.controllers."qbit-manage".pod.annotations."config-hash"' "$candidate")" == \
  'config-revision' ]]
[[ "$(yq -r '.controllers."qbit-manage".pod.annotations."sops-hash" // ""' "$values")" == '' ]]

echo 'qbit_manage Secret rollout stamp test passed.'
