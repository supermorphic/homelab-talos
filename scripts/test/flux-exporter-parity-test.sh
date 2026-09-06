#!/usr/bin/env bash
# Behavioral tests for independent Flux exporter parity acceptance.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# Deliberately absent until the RED phase implementation is added.
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/flux-exporter-parity.sh"

dedicated_json='{
  "status":"success","data":{"result":[
    {"metric":{"__name__":"gotk_resource_info","job":"dedicated","instance":"192.0.2.1:8080","pod":"dedicated-a","service":"flux-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"kustomize.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"Kustomization","exported_namespace":"flux-system","name":"cluster-apps","ready":"True","suspended":"false"},"value":[1,"1"]},
    {"metric":{"__name__":"gotk_resource_info","job":"dedicated","instance":"192.0.2.1:8080","pod":"dedicated-a","service":"flux-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"helm.toolkit.fluxcd.io","customresource_version":"v2","customresource_kind":"HelmRelease","exported_namespace":"monitoring","name":"kube-prometheus-stack","ready":"True","suspended":"false"},"value":[1,"1"]},
    {"metric":{"__name__":"gotk_resource_info","job":"dedicated","instance":"192.0.2.1:8080","pod":"dedicated-a","service":"flux-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"GitRepository","exported_namespace":"flux-system","name":"flux-system","ready":"True","suspended":"false"},"value":[1,"1"]},
    {"metric":{"__name__":"gotk_resource_info","job":"dedicated","instance":"192.0.2.1:8080","pod":"dedicated-a","service":"flux-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"OCIRepository","exported_namespace":"monitoring","name":"grafana","ready":"True","suspended":"false"},"value":[1,"1"]},
    {"metric":{"__name__":"gotk_resource_info","job":"dedicated","instance":"192.0.2.1:8080","pod":"dedicated-a","service":"flux-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"HelmRepository","exported_namespace":"monitoring","name":"prometheus-community","ready":"False","suspended":"true"},"value":[1,"1"]}
  ]}}
'

candidate_json='{
  "status":"success","data":{"result":[
    {"metric":{"__name__":"gotk_candidate_resource_info","job":"bundled","instance":"192.0.2.2:8080","pod":"kube-prometheus-stack-kube-state-metrics-a","service":"kube-prometheus-stack-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"kustomize.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"Kustomization","exported_namespace":"flux-system","name":"cluster-apps","ready":"True","suspended":"false"},"value":[1,"1"]},
    {"metric":{"__name__":"gotk_candidate_resource_info","job":"bundled","instance":"192.0.2.2:8080","pod":"kube-prometheus-stack-kube-state-metrics-a","service":"kube-prometheus-stack-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"helm.toolkit.fluxcd.io","customresource_version":"v2","customresource_kind":"HelmRelease","exported_namespace":"monitoring","name":"kube-prometheus-stack","ready":"True","suspended":"false"},"value":[1,"1"]},
    {"metric":{"__name__":"gotk_candidate_resource_info","job":"bundled","instance":"192.0.2.2:8080","pod":"kube-prometheus-stack-kube-state-metrics-a","service":"kube-prometheus-stack-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"GitRepository","exported_namespace":"flux-system","name":"flux-system","ready":"True","suspended":"false"},"value":[1,"1"]},
    {"metric":{"__name__":"gotk_candidate_resource_info","job":"bundled","instance":"192.0.2.2:8080","pod":"kube-prometheus-stack-kube-state-metrics-a","service":"kube-prometheus-stack-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"OCIRepository","exported_namespace":"monitoring","name":"grafana","ready":"True","suspended":"false"},"value":[1,"1"]},
    {"metric":{"__name__":"gotk_candidate_resource_info","job":"bundled","instance":"192.0.2.2:8080","pod":"kube-prometheus-stack-kube-state-metrics-a","service":"kube-prometheus-stack-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics","customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"HelmRepository","exported_namespace":"monitoring","name":"prometheus-community","ready":"False","suspended":"true"},"value":[1,"1"]}
  ]}}
'

inventory_json='{
  "apiVersion":"v1","kind":"List","items":[
    {"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"namespace":"flux-system","name":"cluster-apps"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
    {"apiVersion":"helm.toolkit.fluxcd.io/v2","kind":"HelmRelease","metadata":{"namespace":"monitoring","name":"kube-prometheus-stack"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
    {"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"GitRepository","metadata":{"namespace":"flux-system","name":"flux-system"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
    {"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"OCIRepository","metadata":{"namespace":"monitoring","name":"grafana"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
    {"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"HelmRepository","metadata":{"namespace":"monitoring","name":"prometheus-community"},"spec":{"suspend":true},"status":{"conditions":[{"type":"Ready","status":"False"}]}}
  ]}
'

assert_rejected() {
  local label="$1" dedicated="$2" candidate="$3" inventory="$4" output
  if output="$(flux_exporter_compare "$dedicated" "$candidate" "$inventory" 2>&1)"; then
    echo "$label: comparator unexpectedly accepted mismatched resources." >&2
    exit 1
  fi
  rg -q '^[a-z-]+:' <<<"$output" || {
    echo "$label: comparator did not print a bounded identity-only difference." >&2
    exit 1
  }
}

flux_exporter_compare "$dedicated_json" "$candidate_json" "$inventory_json"

shared_extra_label_json="$(yq -o=json '(.data.result[].metric.exporter_generation) = "candidate-shared"' <<<"$dedicated_json")"
shared_extra_candidate_json="$(yq -o=json '(.data.result[].metric.exporter_generation) = "candidate-shared"' <<<"$candidate_json")"
assert_rejected 'shared non-transport label missing from inventory' "$shared_extra_label_json" "$shared_extra_candidate_json" "$inventory_json"

missing_dedicated_json="$(yq -o=json 'del(.data.result[] | select(.metric.customresource_kind == "OCIRepository"))' <<<"$dedicated_json")"
assert_rejected 'one missing resource' "$missing_dedicated_json" "$candidate_json" "$inventory_json"

# This fixture is literal and ensures API inventory, not exporter agreement, is the oracle.
both_missing_json='{"status":"success","data":{"result":[{"metric":{"customresource_group":"helm.toolkit.fluxcd.io","customresource_version":"v2","customresource_kind":"HelmRelease","exported_namespace":"monitoring","name":"kube-prometheus-stack","ready":"True","suspended":"false"},"value":[1,"1"]},{"metric":{"customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"GitRepository","exported_namespace":"flux-system","name":"flux-system","ready":"True","suspended":"false"},"value":[1,"1"]},{"metric":{"customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"OCIRepository","exported_namespace":"monitoring","name":"grafana","ready":"True","suspended":"false"},"value":[1,"1"]},{"metric":{"customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"HelmRepository","exported_namespace":"monitoring","name":"prometheus-community","ready":"False","suspended":"true"},"value":[1,"1"]}]}}'
if flux_exporter_compare "$both_missing_json" "$both_missing_json" "$inventory_json"; then
  echo 'Both exporters omitted an API resource, but parity passed.' >&2
  exit 1
fi

extra_json="$(yq -o=json '.data.result += [.data.result[0] | .metric.name = "unexpected"]' <<<"$candidate_json")"
assert_rejected 'extra resource' "$dedicated_json" "$extra_json" "$inventory_json"
duplicate_json="$(yq -o=json '.data.result += [.data.result[0]]' <<<"$candidate_json")"
assert_rejected 'duplicate series' "$dedicated_json" "$duplicate_json" "$inventory_json"
ready_mismatch_json="$(yq -o=json '(.data.result[] | select(.metric.customresource_kind == "GitRepository") | .metric.ready) = "False"' <<<"$candidate_json")"
assert_rejected 'Ready mismatch' "$dedicated_json" "$ready_mismatch_json" "$inventory_json"
suspension_mismatch_json="$(yq -o=json '(.data.result[] | select(.metric.customresource_kind == "OCIRepository") | .metric.suspended) = "true"' <<<"$candidate_json")"
assert_rejected 'suspension mismatch' "$dedicated_json" "$suspension_mismatch_json" "$inventory_json"
missing_suspension_json="$(yq -o=json 'del(.data.result[] | select(.metric.customresource_kind == "OCIRepository") | .metric.suspended)' <<<"$candidate_json")"
flux_exporter_compare "$dedicated_json" "$missing_suspension_json" "$inventory_json"
missing_ready_json="$(yq -o=json 'del(.data.result[] | select(.metric.customresource_kind == "GitRepository") | .metric.ready)' <<<"$candidate_json")"
assert_rejected 'missing Ready is not True' "$dedicated_json" "$missing_ready_json" "$inventory_json"
invalid_value_json="$(yq -o=json '(.data.result[] | select(.metric.customresource_kind == "OCIRepository") | .value[1]) = "zero"' <<<"$candidate_json")"
assert_rejected 'invalid sample value' "$dedicated_json" "$invalid_value_json" "$inventory_json"
wrong_gvk_json="$(yq -o=json '(.data.result[] | select(.metric.customresource_kind == "OCIRepository") | .metric.customresource_version) = "v2"' <<<"$candidate_json")"
assert_rejected 'wrong GVK' "$dedicated_json" "$wrong_gvk_json" "$inventory_json"
assert_rejected 'malformed API response' '{"status":"error"}' "$candidate_json" "$inventory_json"
assert_rejected 'empty inventory' "$dedicated_json" "$candidate_json" '{"apiVersion":"v1","kind":"List","items":[]}'

# Scrape transport labels differ, but semantic resource labels do not.
transport_only_json="$(yq -o=json '(.data.result[].metric.job) = "different-job" | (.data.result[].metric.instance) = "10.0.0.99:8080" | (.data.result[].metric.pod) = "different-pod" | (.data.result[].metric.service) = "different-service"' <<<"$candidate_json")"
flux_exporter_compare "$dedicated_json" "$transport_only_json" "$inventory_json"

echo 'Flux exporter parity comparator tests passed.'
