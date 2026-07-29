#!/usr/bin/env bash
set -euo pipefail

# Offline unit tests for the Tailscale PrometheusRule alerts. Extracts the live rule `.spec`
# (single source of truth) into a plain Prometheus rules file and runs promtool against the
# tracked test fixture, so the alert PromQL is never duplicated in the test.
rule='kubernetes/apps/networking/tailscale-operator/monitoring/prometheusrule.yaml'
test_src='tests/prometheus/tailscale-alerts_test.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-tailscale-alerts-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$rule" "$test_src"; do
  [[ -f "$f" ]] || { echo "Missing Tailscale alerts source: $f" >&2; exit 1; }
done
[[ "$(yq -r '.kind' "$rule")" == 'PrometheusRule' ]] || {
  echo "Refusing: $rule is not a PrometheusRule." >&2
  exit 1
}

# `.spec` (groups/rules) is a valid Prometheus rule_files document; the test's
# `rule_files: [rules.yaml]` resolves within the temp dir where both are placed.
yq -o=yaml '.spec' "$rule" >"$temp_dir/rules.yaml"
cp "$test_src" "$temp_dir/tailscale-alerts_test.yaml"

promtool check rules "$temp_dir/rules.yaml"
promtool test rules "$temp_dir/tailscale-alerts_test.yaml"

echo 'Tailscale alert rules: promtool check + unit tests (7 alerts, three temporal states, absent() matcher cases) passed.'
