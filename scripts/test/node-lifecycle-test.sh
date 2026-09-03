#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/node-lifecycle-state.sh

fail() {
  echo "$*" >&2
  exit 1
}

assert_fails() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$description"
  fi
}

reboot_record='{"schemaVersion":1,"kind":"reboot"}'
abrupt_record='{"schemaVersion":1,"kind":"abrupt-loss"}'
maintenance_record='{
  "schemaVersion": 1,
  "kind": "maintenance",
  "longhorn": {
    "allowScheduling": {"before": true, "during": false},
    "evictionRequested": {"before": false, "during": true}
  }
}'

for record in "$reboot_record" "$abrupt_record" "$maintenance_record"; do
  validate_lifecycle_record "$record"
done
[[ "$(lifecycle_record_kind "$maintenance_record")" == 'maintenance' ]]

invalid_records=(
  'not-json'
  '{}'
  '{"schemaVersion":2,"kind":"reboot"}'
  '{"schemaVersion":1,"kind":"unsupported"}'
  '{"schemaVersion":1,"kind":"maintenance"}'
  '{"schemaVersion":1,"kind":"maintenance","longhorn":{"allowScheduling":{"before":true,"during":true},"evictionRequested":{"before":false,"during":true}}}'
  '{"schemaVersion":1,"kind":"maintenance","longhorn":{"allowScheduling":{"before":true,"during":false},"evictionRequested":{"before":false,"during":false}}}'
)
for record in "${invalid_records[@]}"; do
  assert_fails "Invalid lifecycle record was accepted: $record" \
    validate_lifecycle_record "$record"
done

[[ "$(compare_owned_value false true false)" == 'restore' ]]
[[ "$(compare_owned_value true true false)" == 'noop' ]]
assert_fails 'Conflicting lifecycle-owned value was accepted.' \
  compare_owned_value changed true false

node_fixture=''
lifecycle_kubectl() {
  local _kubeconfig="$1"
  shift
  [[ "$*" == 'get nodes --output json' ]] || return 2
  printf '%s\n' "$node_fixture"
}

node_json() {
  local node_one_ready="$1"
  local node_one_unschedulable="$2"
  local node_one_record="$3"
  local node_two_ready="$4"
  local node_two_unschedulable="$5"
  local node_two_record="$6"
  NODE_ONE_READY="$node_one_ready" \
  NODE_ONE_UNSCHEDULABLE="$node_one_unschedulable" \
  NODE_ONE_RECORD="$node_one_record" \
  NODE_TWO_READY="$node_two_ready" \
  NODE_TWO_UNSCHEDULABLE="$node_two_unschedulable" \
  NODE_TWO_RECORD="$node_two_record" \
    yq --null-input --output-format json '
      {
        "items": [
          {
            "metadata": {
              "name": "nuc1",
              "annotations": {
                "homelab.supermorphic.com/node-lifecycle": strenv(NODE_ONE_RECORD)
              }
            },
            "spec": {"unschedulable": (strenv(NODE_ONE_UNSCHEDULABLE) == "true")},
            "status": {"conditions": [{"type": "Ready", "status": strenv(NODE_ONE_READY)}]}
          },
          {
            "metadata": {
              "name": "nuc2",
              "annotations": {
                "homelab.supermorphic.com/node-lifecycle": strenv(NODE_TWO_RECORD)
              }
            },
            "spec": {"unschedulable": (strenv(NODE_TWO_UNSCHEDULABLE) == "true")},
            "status": {"conditions": [{"type": "Ready", "status": strenv(NODE_TWO_READY)}]}
          }
        ]
      }
    '
}

node_fixture="$(node_json True false '' True false '')"
assert_cluster_disruption_admissible fake-kubeconfig

node_fixture="$(node_json False false '' True false '')"
assert_fails 'An unannotated NotReady node did not block disruption.' \
  assert_cluster_disruption_admissible fake-kubeconfig

node_fixture="$(node_json True true '' True false '')"
assert_fails 'An unexpected cordon did not block disruption.' \
  assert_cluster_disruption_admissible fake-kubeconfig

node_fixture="$(node_json True true "$reboot_record" True false '')"
assert_fails 'An active lifecycle record did not block a new disruption.' \
  assert_cluster_disruption_admissible fake-kubeconfig
assert_cluster_disruption_admissible fake-kubeconfig nuc1

node_fixture="$(node_json False true "$abrupt_record" True false '')"
assert_cluster_disruption_admissible fake-kubeconfig nuc1

node_fixture="$(node_json True true 'malformed' True false '')"
assert_fails 'A malformed lifecycle record was accepted for recovery.' \
  assert_cluster_disruption_admissible fake-kubeconfig nuc1

node_fixture="$(node_json True true "$maintenance_record" True true "$reboot_record")"
assert_fails 'Lifecycle state on a second node did not block recovery.' \
  assert_cluster_disruption_admissible fake-kubeconfig nuc1

echo 'Node lifecycle state tests passed.'
