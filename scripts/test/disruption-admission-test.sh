#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source scripts/lib/disruption-admission.sh
source scripts/lib/node-target.sh

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/disruption-admission-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

cat >"$temp_dir/talconfig.yaml" <<'YAML'
nodes:
  - hostname: node-a
    ipAddress: 192.0.2.10
    controlPlane: true
  - hostname: node-b
    ipAddress: 192.0.2.11
    controlPlane: true
  - hostname: node-c
    ipAddress: 192.0.2.12
    controlPlane: true
YAML

fixture_nodes() {
  local node_a_record="${1:-}" node_a_unschedulable="${2:-false}"
  NODE_A_RECORD="$node_a_record" NODE_A_UNSCHEDULABLE="$node_a_unschedulable" yq -n -o=json '
    {"items": [
      {"metadata":{"name":"node-a","annotations":{"homelab.supermorphic.com/node-lifecycle":strenv(NODE_A_RECORD)}},"spec":{"unschedulable":(strenv(NODE_A_UNSCHEDULABLE) == "true")},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
      {"metadata":{"name":"node-b"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},
      {"metadata":{"name":"node-c"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}
    ]}'
}

fake_nodes_json=''
disruption_kubectl() {
  printf '%s\n' "$fake_nodes_json"
}

fake_nodes_json="$(fixture_nodes)"
assert_disruption_admissible /fixture/kubeconfig fixture "$temp_dir/talconfig.yaml"

fake_nodes_json="$(fixture_nodes '{"schemaVersion":1,"kind":"maintenance","longhorn":{"allowScheduling":{"before":true,"during":false},"evictionRequested":{"before":false,"during":true}}}' true)"
if assert_disruption_admissible /fixture/kubeconfig fixture "$temp_dir/talconfig.yaml"; then
  echo 'admission accepted active lifecycle containment' >&2
  exit 1
fi

fake_nodes_json="$(fixture_nodes '{"schemaVersion":9,"kind":"unknown"}' true)"
if assert_disruption_admissible /fixture/kubeconfig fixture "$temp_dir/talconfig.yaml"; then
  echo 'admission accepted an unknown lifecycle record' >&2
  exit 1
fi

fake_nodes_json="$(fixture_nodes '' true)"
if assert_disruption_admissible /fixture/kubeconfig fixture "$temp_dir/talconfig.yaml"; then
  echo 'admission accepted an unrelated cordon' >&2
  exit 1
fi

resolve_cluster_node node-b "$temp_dir/talconfig.yaml"
[[ "$NODE_NAME" == node-b && "$NODE_IP" == 192.0.2.11 ]]
if resolve_cluster_node missing "$temp_dir/talconfig.yaml"; then
  echo 'node target accepted a node absent from desired source' >&2
  exit 1
fi

echo 'Retained disruption admission and node target tests passed.'
