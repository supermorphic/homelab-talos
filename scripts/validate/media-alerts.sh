#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/alerts'
ks="$base/ks.yaml"
app_kustomization="$base/app/kustomization.yaml"
rule="$base/app/prometheusrule.yaml"
test_src='tests/prometheus/media-alerts_test.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-media-alerts-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$app_kustomization" "$rule" "$test_src"; do
  [[ -f "$f" ]] || { echo "Missing media alerts source: $f" >&2; exit 1; }
done
rg -qx '  - ./alerts/ks.yaml' kubernetes/apps/media/kustomization.yaml
[[ "$(yq -r '.metadata.name' "$ks")" == 'media-alerts' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'kube-prometheus-stack' ]]
[[ "$(yq -r '.spec.suspend // false' "$ks")" == 'false' ]]
[[ "$(yq -r '.kind' "$rule")" == 'PrometheusRule' ]]
[[ "$(yq -r '.metadata.namespace' "$rule")" == 'media' ]]

mapfile -t media_rule_files < <(rg --files kubernetes/apps/media | rg '/app/prometheusrule\.yaml$' | sort)
expected_rule_files=(
  'kubernetes/apps/media/alerts/app/prometheusrule.yaml'
  'kubernetes/apps/media/qbittorrent/app/prometheusrule.yaml'
)
[[ "${media_rule_files[*]}" == "${expected_rule_files[*]}" ]] || {
  echo 'Media PrometheusRules must live in media/alerts; qbittorrent is the only named legacy exception.' >&2
  printf 'Found: %s\n' "${media_rule_files[@]}" >&2
  exit 1
}

kustomize build "$base/app" >/dev/null
yq -o=yaml '.spec' "$rule" >"$temp_dir/rules.yaml"
cp "$test_src" "$temp_dir/media-alerts_test.yaml"
promtool check rules "$temp_dir/rules.yaml"
promtool test rules "$temp_dir/media-alerts_test.yaml"
echo 'Media alert placement, Prometheus syntax, and temporal/matcher tests passed.'
