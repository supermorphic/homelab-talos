#!/usr/bin/env bash
# Focused mutation tests for the parallel Flux resource-state exporters.
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
(cd "$tree" && bash "${validator[@]}")

reset_tree
yq -i 'del(."kube-state-metrics".customResourceState.config.spec.resources[] | select(.groupVersionKind.kind == "OCIRepository"))' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'missing bundled Flux collector' 'bundled Flux customResourceState must exactly match'

reset_tree
yq -i '."kube-state-metrics".customResourceState.config.spec.resources[0].metrics[0].help = "changed"' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'altered bundled collector help' 'bundled Flux customResourceState content must match'

reset_tree
yq -i '."kube-state-metrics".customResourceState.config.spec.resources[0].metrics[0].labelsFromPath.ready = ["status", "phase"]' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'altered bundled collector labels' 'bundled Flux customResourceState content must match'

reset_tree
yq -i 'del(."kube-state-metrics".rbac.extraRules[] | select(.apiGroups[0] == "apiextensions.k8s.io"))' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'missing bundled CRD discovery permission' 'extraRules must contain only the four dedicated'

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
yq -i '.grafana.deploymentStrategy.type = "RollingUpdate"' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml"
expect_rejected 'changed Grafana strategy' 'rendered Grafana Deployment must use Recreate'

reset_tree
yq -i '.spec.upgrade.serverSideApply = "enabled"' "$tree/kubernetes/apps/monitoring/kube-prometheus-stack/app/helmrelease.yaml"
expect_rejected 'changed Helm client-side upgrade mode' 'upgrades must use client-side apply'

echo 'Monitoring Flux exporter mutation tests passed.'
