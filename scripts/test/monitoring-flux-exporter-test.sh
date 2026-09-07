#!/usr/bin/env bash
# Focused mutation tests for the bundled Flux resource-state collector.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/test/lib/monitoring-fixtures.sh"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-monitoring-flux-exporter-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
template="$fixture/template"
tree="$fixture/tree"
validator=(scripts/validate/monitoring.sh flux-exporter)

monitoring_fixture_prepare "$repo_root" "$template" "$tree"

[[ "$(yq -r '."kube-state-metrics".prometheus.monitor.http.metricRelabelings | length' \
  "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml")" == '0' ]] || {
  echo 'bundled production metrics must retain the canonical gotk_resource_info name.' >&2
  exit 1
}
for rule in FluxReconciliationFailure FluxResourceMetricsMissing; do
  yq -r ".spec.groups[].rules[] | select(.alert == \"$rule\") | .expr" \
    "$tree/kubernetes/apps/monitoring/alerts/app/flux.yaml" |
    rg -Fq 'service="kube-prometheus-stack-kube-state-metrics"' || {
      echo "$rule must select the bundled production source." >&2
      exit 1
    }
done

reset_tree() {
  rm -rf -- "$tree"
  cp -R "$template/." "$tree"
}

expect_rejected() {
	local label="$1" expected="$2" output status
  set +e
  output="$(cd "$tree" && bash "${validator[@]}" 2>&1)"
  status="$?"
  set -e
	[[ "$status" -ne 0 ]] || {
    echo "$label: expected monitoring validator rejection." >&2
		exit 1
	}
	rg -Fq -- "$expected" <<<"$output" || {
		echo "$label: validator did not reject its intended invariant: $expected" >&2
		echo "$output" >&2
		exit 1
	}
}

reset_tree
# The final production state has only the bundled kube-state-metrics collector.
# Before Task 5 removes the dedicated package, this is expected to fail because the
# validator still requires that package; after the cleanup it must validate.
if [[ -e "$tree/kubernetes/apps/monitoring/flux-kube-state-metrics" ]]; then
  mv "$tree/kubernetes/apps/monitoring/flux-kube-state-metrics" "$fixture/removed-flux-kube-state-metrics"
fi
yq -i 'del(.resources[] | select(. == "./flux-kube-state-metrics/ks.yaml"))' \
  "$tree/kubernetes/apps/monitoring/kustomization.yaml"
(cd "$tree" && bash "${validator[@]}")

reset_tree
yq -i 'del(."kube-state-metrics".customResourceState)' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'missing bundled Flux collector configuration' 'bundled kube-state-metrics must enable customResourceState'

reset_tree
yq -i 'del(."kube-state-metrics".customResourceState.config.spec.resources[] | select(.groupVersionKind.kind == "OCIRepository"))' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'missing OCIRepository metric family' 'must configure exactly the five expected Flux resource kinds'

reset_tree
yq -i '."kube-state-metrics".customResourceState.config.spec.resources[0].groupVersionKind.kind = "Bucket"' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'wrong Flux resource kind' 'must configure exactly the five expected Flux resource kinds'

reset_tree
yq -i 'del(."kube-state-metrics".rbac.extraRules[] | select(.apiGroups[0] == "apiextensions.k8s.io"))' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'missing bundled CRD discovery permission' 'must grant only Flux list/watch and CRD discovery permissions'

reset_tree
yq -i '."kube-state-metrics".rbac.extraRules[0].resources = ["*"]' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'bundled wildcard permission' 'extraRules must not use wildcards'

reset_tree
yq -i '."kube-state-metrics".collectors = []' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'disabled bundled standard collectors' 'standard collectors must remain enabled'

reset_tree
yq -i '."kube-state-metrics".prometheus.monitor.http.metricRelabelings = [{"action":"replace", "sourceLabels":["__name__"], "regex":"gotk_resource_info", "targetLabel":"__name__", "replacement":"gotk_candidate_resource_info"}]' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'candidate metric rename remains configured' 'must not rename gotk_resource_info'

reset_tree
yq -i '(.spec.groups[].rules[] | select(.alert == "FluxReconciliationFailure").expr) |= sub("kube-prometheus-stack-kube-state-metrics"; "flux-kube-state-metrics")' "$tree/kubernetes/apps/monitoring/alerts/app/flux.yaml"
expect_rejected 'wrong Flux alert source' 'FluxReconciliationFailure must select the bundled production source'

reset_tree
yq -i '.grafana.deploymentStrategy.type = "RollingUpdate"' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'changed Grafana strategy' 'rendered Grafana Deployment must use Recreate'

reset_tree
yq -i '.spec.upgrade.serverSideApply = "enabled"' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/helmrelease.yaml"
expect_rejected 'changed Helm client-side upgrade mode' 'upgrades must use client-side apply'

echo 'Monitoring Flux exporter mutation tests passed.'
