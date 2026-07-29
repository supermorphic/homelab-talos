#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

rule_source='kubernetes/apps/monitoring/kube-prometheus-stack/config/flux-alerts.yaml'
test_source='tests/prometheus/flux-alerts.test.yaml'
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-flux-alerts-promql.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

[[ -f "$rule_source" && -f "$test_source" ]]
yq -r '.spec' "$rule_source" >"$temp_dir/flux-alerts.rules.yaml"
cp "$test_source" "$temp_dir/flux-alerts.test.yaml"

promtool check rules "$temp_dir/flux-alerts.rules.yaml"
promtool test rules "$temp_dir/flux-alerts.test.yaml"

echo 'Flux alert PromQL behavior passed: reconciliation failures respect readiness/suspension and missing resource metrics trigger the watchdog.'
