#!/usr/bin/env bash
# Offline checks; enrollment, deployment and native acceptance remain separate.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
uv run --locked python -m unittest scripts.test.core.test_application_boundary scripts.test.core.test_admission_compile
platform='kubernetes/apps/applications/career-ops/platform'
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-application-boundary.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
kustomize build "$platform" >"$temp_dir/platform.yaml"
printf '\n---\n' >>"$temp_dir/platform.yaml"
kustomize build kubernetes/apps/applications/career-ops/fixture-storage >>"$temp_dir/platform.yaml"
kustomize build kubernetes/apps/applications/career-ops/connection >"$temp_dir/connection.yaml"
kustomize build kubernetes/flux/clusters/prod/flux-system >/dev/null
kubernetes_version="$(yq -r '.kubernetesVersion' talos/talconfig.yaml)"
kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${kubernetes_version#v}" "$temp_dir/platform.yaml"
yq -N 'select(.kind == "PrometheusRule") | .spec' "$platform/monitoring.yaml" >"$temp_dir/career-ops.yaml"
promtool check rules "$temp_dir/career-ops.yaml"
cp tests/prometheus/career-ops-bootstrap_test.yaml "$temp_dir/bootstrap_test.yaml"
promtool test rules "$temp_dir/bootstrap_test.yaml"
cp tests/prometheus/career-ops-alerts_test.yaml "$temp_dir/alerts_test.yaml"
promtool test rules "$temp_dir/alerts_test.yaml"
echo 'Application boundary offline checks passed; native acceptance remains separate.'
