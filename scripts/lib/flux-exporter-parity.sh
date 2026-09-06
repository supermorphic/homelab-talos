#!/usr/bin/env bash

# Compare the dedicated and bundled Flux resource-state vectors against Kubernetes
# API inventory. Output intentionally contains resource identities only.

source scripts/lib/common.sh

flux_exporter_parity_expected_gvks() {
  cat <<'EOF'
kustomize.toolkit.fluxcd.io	v1	Kustomization
helm.toolkit.fluxcd.io	v2	HelmRelease
source.toolkit.fluxcd.io	v1	GitRepository
source.toolkit.fluxcd.io	v1	OCIRepository
source.toolkit.fluxcd.io	v1	HelmRepository
EOF
}

flux_exporter_parity_identity() {
  local key="$1"
  local group version kind namespace name
  IFS=$'\t' read -r group version kind namespace name <<<"$key"
  printf '%s/%s/%s %s/%s' "$group" "$version" "$kind" "$namespace" "$name"
}

# Populate keyed label and semantic maps from one successful Prometheus instant-vector.
flux_exporter_parity_load_vector() {
  local source_name="$1" response="$2" labels_name="$3" semantic_name="$4"
  local -n labels_ref="$labels_name" semantic_ref="$semantic_name"
  local expected_count actual_count group version kind namespace name labels semantic key

  if ! yq -e '
    .status == "success" and
    (.data | tag) == "!!map" and
    (.data.result | tag) == "!!seq" and
    ([.data.result[] |
      [
        ((.metric | tag) == "!!map"),
        ((.value | tag) == "!!seq"),
        ((.value | length) == 2),
        ((.value[1] | tonumber) == 1)
      ] | all
    ] | all)
  ' <<<"$response" >/dev/null 2>&1; then
    echo "${source_name}-invalid-response:" >&2
    return 1
  fi

  expected_count="$(yq -r '.data.result | length' <<<"$response")"
  actual_count=0
  while IFS=$'\t' read -r group version kind namespace name; do
    [[ -n "$group" && -n "$version" && -n "$kind" && -n "$namespace" && -n "$name" ]] || {
      echo "${source_name}-invalid-identity:" >&2
      return 1
    }
    actual_count=$((actual_count + 1))
  done < <(yq -r '.data.result[] | [(.metric.customresource_group // ""), (.metric.customresource_version // ""), (.metric.customresource_kind // ""), (.metric.exported_namespace // ""), (.metric.name // "")] | @tsv' <<<"$response")
  [[ "$actual_count" -eq "$expected_count" ]] || return 1

  local index
  for ((index = 0; index < expected_count; index++)); do
    group="$(yq -r ".data.result[$index].metric.customresource_group // \"\"" <<<"$response")"
    version="$(yq -r ".data.result[$index].metric.customresource_version // \"\"" <<<"$response")"
    kind="$(yq -r ".data.result[$index].metric.customresource_kind // \"\"" <<<"$response")"
    namespace="$(yq -r ".data.result[$index].metric.exported_namespace // \"\"" <<<"$response")"
    name="$(yq -r ".data.result[$index].metric.name // \"\"" <<<"$response")"
    key="${group}"$'\t'"${version}"$'\t'"${kind}"$'\t'"${namespace}"$'\t'"${name}"
    labels="$(yq -o=json -I=0 ".data.result[$index] | .metric | del(.__name__, .job, .instance, .pod, .service, .endpoint, .namespace, .container) | .suspended = (.suspended // \"false\" | tostring) | sort_keys(..)" <<<"$response")"
    semantic="$(yq -o=json -I=0 '{"customresource_group": .customresource_group, "customresource_version": .customresource_version, "customresource_kind": .customresource_kind, "exported_namespace": .exported_namespace, "name": .name, "ready": .ready, "suspended": (.suspended // "false" | tostring)} | with_entries(select(.value != null)) | sort_keys(..)' <<<"$labels")"
    if [[ -v "labels_ref[$key]" ]]; then
      printf '%s-duplicate: ' "$source_name" >&2
      flux_exporter_parity_identity "$key" >&2
      printf '\n' >&2
      return 1
    fi
    labels_ref["$key"]="$labels"
    semantic_ref["$key"]="$semantic"
  done
}

flux_exporter_parity_load_inventory() {
  local inventory="$1" labels_name="$2"
  local -n labels_ref="$labels_name"
  local api_version kind namespace name ready suspended group version key expected rows expected_labels
  declare -A expected_gvks=() kind_counts=()

  while IFS=$'\t' read -r group version kind; do
    expected_gvks["${group}"$'\t'"${version}"$'\t'"${kind}"]=1
    kind_counts["${group}"$'\t'"${version}"$'\t'"${kind}"]=0
  done < <(flux_exporter_parity_expected_gvks)

  if ! yq -e '.kind == "List" and (.items | tag) == "!!seq"' <<<"$inventory" >/dev/null 2>&1; then
    echo 'inventory-invalid-response:' >&2
    return 1
  fi
  rows="$(yq -r '
    .items[] |
    [
      (.apiVersion // ""), .kind, (.metadata.namespace // ""), (.metadata.name // ""),
      ([.status.conditions[]? | select(.type == "Ready") | .status] | join("\u001f")),
      ((.spec.suspend // false) | tostring)
    ] | @tsv
  ' <<<"$inventory")" || {
    echo 'inventory-invalid-response:' >&2
    return 1
  }
  [[ -n "$rows" ]] || {
    echo 'inventory-empty:' >&2
    return 1
  }

  while IFS=$'\t' read -r api_version kind namespace name ready suspended; do
    group="${api_version%/*}"
    version="${api_version##*/}"
    [[ -n "$api_version" && "$group" != "$api_version" && -n "$version" && -n "$kind" && -n "$namespace" && -n "$name" && "$ready" != *$'\x1f'* ]] || {
      echo 'inventory-invalid-identity:' >&2
      return 1
    }
    expected="${group}"$'\t'"${version}"$'\t'"${kind}"
    [[ -v "expected_gvks[$expected]" ]] || {
      echo "inventory-unexpected: ${api_version}/${kind} ${namespace}/${name}" >&2
      return 1
    }
    key="${expected}"$'\t'"${namespace}"$'\t'"${name}"
    [[ ! -v "labels_ref[$key]" ]] || {
      printf 'inventory-duplicate: ' >&2
      flux_exporter_parity_identity "$key" >&2
      printf '\n' >&2
      return 1
    }
    expected_labels="$(GROUP="$group" VERSION="$version" KIND="$kind" NAMESPACE="$namespace" NAME="$name" SUSPENDED="$suspended" yq -n -o=json -I=0 '{"customresource_group": strenv(GROUP), "customresource_version": strenv(VERSION), "customresource_kind": strenv(KIND), "exported_namespace": strenv(NAMESPACE), "name": strenv(NAME), "suspended": strenv(SUSPENDED)} | sort_keys(..)')"
    if [[ -n "$ready" ]]; then
      expected_labels="$(READY="$ready" yq -o=json -I=0 '.ready = strenv(READY) | sort_keys(..)' <<<"$expected_labels")"
    fi
    labels_ref["$key"]="$expected_labels"
    kind_counts["$expected"]=$((kind_counts["$expected"] + 1))
  done <<<"$rows"

  for expected in "${!expected_gvks[@]}"; do
    [[ "${kind_counts[$expected]}" -gt 0 ]] || {
      IFS=$'\t' read -r group version kind <<<"$expected"
      echo "inventory-kind-empty: ${group}/${version}/${kind}" >&2
      return 1
    }
  done
}

flux_exporter_parity_compare_map() {
  local source_name="$1" expected_name="$2" actual_name="$3"
  local -n expected_ref="$expected_name" actual_ref="$actual_name"
  local key status=0
  for key in "${!expected_ref[@]}"; do
    if [[ ! -v "actual_ref[$key]" ]]; then
      printf '%s-missing: ' "$source_name" >&2
      flux_exporter_parity_identity "$key" >&2
      printf '\n' >&2
      status=1
    elif [[ "${expected_ref[$key]}" != "${actual_ref[$key]}" ]]; then
      printf '%s-semantic-mismatch: ' "$source_name" >&2
      flux_exporter_parity_identity "$key" >&2
      printf '\n' >&2
      status=1
    fi
  done
  for key in "${!actual_ref[@]}"; do
    [[ -v "expected_ref[$key]" ]] || {
      printf '%s-extra: ' "$source_name" >&2
      flux_exporter_parity_identity "$key" >&2
      printf '\n' >&2
      status=1
    }
  done
  return "$status"
}

# flux_exporter_compare DEDICATED_JSON CANDIDATE_JSON INVENTORY_JSON
flux_exporter_compare() {
  require_bash
  [[ "$#" -eq 3 ]] || {
    echo 'Usage: flux_exporter_compare DEDICATED_JSON CANDIDATE_JSON INVENTORY_JSON' >&2
    return 2
  }
  local dedicated_json="$1" candidate_json="$2" inventory_json="$3" key status=0
  declare -A dedicated_labels=() candidate_labels=() inventory_labels=()
  declare -A dedicated_semantic=() candidate_semantic=()

  flux_exporter_parity_load_vector dedicated "$dedicated_json" dedicated_labels dedicated_semantic || status=1
  flux_exporter_parity_load_vector candidate "$candidate_json" candidate_labels candidate_semantic || status=1
  flux_exporter_parity_load_inventory "$inventory_json" inventory_labels || status=1
  [[ "$status" -eq 0 ]] || return 1

  flux_exporter_parity_compare_map dedicated inventory_labels dedicated_semantic || status=1
  flux_exporter_parity_compare_map candidate inventory_labels candidate_semantic || status=1
  flux_exporter_parity_compare_map candidate dedicated_labels candidate_labels || status=1
  return "$status"
}
