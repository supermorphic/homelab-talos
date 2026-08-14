#!/usr/bin/env bash
set -euo pipefail

# Offline checks for one domain's alerts application. Extracts every rule file's `.spec`
# (the single source of truth) into plain Prometheus rule files and runs promtool against
# the tracked fixture, so alert PromQL is never duplicated in a test. Replaces the three
# near-identical per-subject validators this repository accumulated.
[[ "$#" -eq 1 ]] || { echo 'Usage: alerts.sh <media|monitoring|networking>' >&2; exit 2; }
domain="$1"
case "$domain" in
  media|monitoring|networking) ;;
  *) echo "Unknown alerts domain: $domain" >&2; exit 2 ;;
esac

base="kubernetes/apps/$domain/alerts"
ks="$base/ks.yaml"
app_kustomization="$base/app/kustomization.yaml"
test_src="tests/prometheus/$domain-alerts_test.yaml"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-alerts-validate.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$app_kustomization" "$test_src"; do
  [[ -f "$f" ]] || { echo "Missing $domain alerts source: $f" >&2; exit 1; }
done

rg -qx "  - ./alerts/ks.yaml" "kubernetes/apps/$domain/kustomization.yaml" || {
  echo "Refusing: ./alerts/ks.yaml is not wired into kubernetes/apps/$domain/kustomization.yaml." >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$ks")" == "$domain-alerts" ]]
[[ "$(yq -r '.metadata.namespace' "$ks")" == 'flux-system' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'kube-prometheus-stack' ]]
[[ "$(yq -r '.spec.suspend // false' "$ks")" == 'false' ]]
[[ "$(yq -r '.spec.path' "$ks")" == "./kubernetes/apps/$domain/alerts/app" ]]

# Every rule file in the app directory must be a PrometheusRule in the monitoring
# namespace, and must be wired into the kustomization. A rule present on disk but absent
# from kustomization.yaml would never reach the cluster and would still pass promtool.
mapfile -t rule_files < <(rg --files "$base/app" | rg '\.yaml$' | rg -v '/kustomization\.yaml$' | sort)
[[ "${#rule_files[@]}" -gt 0 ]] || { echo "No rule files under $base/app." >&2; exit 1; }
extracted=()
for rule in "${rule_files[@]}"; do
  [[ "$(yq -r '.kind' "$rule")" == 'PrometheusRule' ]] || {
    echo "Refusing: $rule is not a PrometheusRule." >&2
    exit 1
  }
  [[ "$(yq -r '.metadata.namespace' "$rule")" == 'monitoring' ]] || {
    echo "Refusing: $rule must set namespace: monitoring." >&2
    exit 1
  }
  rg -qx "  - ./$(basename "$rule")" "$app_kustomization" || {
    echo "Refusing: $(basename "$rule") is not wired into $app_kustomization." >&2
    exit 1
  }
  yq -o=yaml '.spec' "$rule" >"$temp_dir/$(basename "$rule")"
  extracted+=("$temp_dir/$(basename "$rule")")
done

# No PrometheusRule may live outside a domain alerts application. This is the invariant
# the refactor exists to hold; without it the tree silently re-fragments.
mapfile -t stray < <(rg --files kubernetes/apps | rg '\.yaml$' \
  | xargs rg -l '^kind: PrometheusRule' 2>/dev/null \
  | rg -v '/alerts/app/' | sort)
[[ "${#stray[@]}" -eq 0 ]] || {
  echo 'PrometheusRule files must live in kubernetes/apps/<domain>/alerts/app/:' >&2
  printf '  %s\n' "${stray[@]}" >&2
  exit 1
}

kustomize build "$base/app" >/dev/null
# Check only the extracted rule files by name. A `"$temp_dir"/*.yaml` glob would also
# feed the copied fixture to `promtool check rules`, which rejects a unit-test file.
promtool check rules "${extracted[@]}"
cp "$test_src" "$temp_dir/$domain-alerts_test.yaml"
promtool test rules "$temp_dir/$domain-alerts_test.yaml"

echo "$domain alerts: placement, wiring, Prometheus syntax, and unit tests passed."
