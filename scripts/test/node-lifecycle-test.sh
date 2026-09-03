#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/node-lifecycle-state.sh
source scripts/node/common.sh
source scripts/node/longhorn.sh

state_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-node-lifecycle-test.XXXXXX")"
trap 'rm -rf -- "$state_dir"' EXIT

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

resolve_node_target nuc1
[[ "$NODE_NAME" == 'nuc1' && "$NODE_IP" == '192.168.90.10' ]]
resolve_node_target nuc3
[[ "$NODE_NAME" == 'nuc3' && "$NODE_IP" == '192.168.90.12' ]]
assert_fails 'An unknown node target was accepted.' resolve_node_target other

NODE_ALLOW_LINKED_WORKTREE_FOR_TESTS=true require_operator_checkout
assert_fails 'The linked worktree was accepted as an operator checkout.' \
  env -u NODE_ALLOW_LINKED_WORKTREE_FOR_TESTS bash -c \
    'source scripts/node/common.sh; require_operator_checkout'

node_state="$state_dir/node-state.json"
yq --null-input --output-format json '
  {
    "apiVersion": "v1",
    "kind": "Node",
    "metadata": {"name": "nuc1", "resourceVersion": "7", "annotations": {}},
    "spec": {"unschedulable": false},
    "status": {"conditions": [{"type": "Ready", "status": "True"}]}
  }
' >"$node_state"
node_conflict=false
node_readback_mismatch=false
node_kubectl() {
  local _kubeconfig="$1"
  shift
  local operation="$1"
  shift
  case "$operation" in
    get)
      [[ "$1 $2 $3" == 'node nuc1 --output' && "$4" == 'json' ]] || return 2
      cat "$node_state"
      ;;
    replace)
      [[ "$1 $2" == '--filename -' ]] || return 2
      replacement="$(cat)"
      [[ "$node_conflict" != 'true' ]] || return 1
      current_version="$(yq -r '.metadata.resourceVersion' "$node_state")"
      [[ "$(yq -r '.metadata.resourceVersion' - <<<"$replacement")" == "$current_version" ]] || return 1
      if [[ "$node_readback_mismatch" != 'true' ]]; then
        NEXT_VERSION="$((current_version + 1))" \
          yq '.metadata.resourceVersion = strenv(NEXT_VERSION)' \
          <<<"$replacement" >"$state_dir/node-next.json"
        mv "$state_dir/node-next.json" "$node_state"
      fi
      ;;
    *) return 2 ;;
  esac
}

persist_node_containment fake-kubeconfig nuc1 "$reboot_record"
[[ "$(yq -r '.spec.unschedulable' "$node_state")" == 'true' ]]
[[ "$(ANNOTATION="$NODE_LIFECYCLE_ANNOTATION" \
  yq -r '.metadata.annotations[strenv(ANNOTATION)]' "$node_state")" == "$reboot_record" ]]

remove_node_containment_and_uncordon fake-kubeconfig nuc1 "$reboot_record" recovery-accepted
[[ "$(yq -r '.spec.unschedulable' "$node_state")" == 'false' ]]
[[ "$(ANNOTATION="$NODE_LIFECYCLE_ANNOTATION" \
  yq -r '.metadata.annotations[strenv(ANNOTATION)] // ""' "$node_state")" == '' ]]
assert_fails 'Final Node transition did not require recovery acceptance.' \
  remove_node_containment_and_uncordon fake-kubeconfig nuc1 "$reboot_record" not-accepted

node_conflict=true
assert_fails 'A resource-version conflict was accepted.' \
  persist_node_containment fake-kubeconfig nuc1 "$reboot_record"
node_conflict=false
node_readback_mismatch=true
assert_fails 'A containment read-back mismatch was accepted.' \
  persist_node_containment fake-kubeconfig nuc1 "$reboot_record"
node_readback_mismatch=false

longhorn_state="$state_dir/longhorn-state.json"
yq --null-input --output-format json '
  {
    "apiVersion": "longhorn.io/v1beta2",
    "kind": "Node",
    "metadata": {"name": "nuc1", "namespace": "longhorn-system", "resourceVersion": "20"},
    "spec": {"allowScheduling": true, "evictionRequested": false}
  }
' >"$longhorn_state"
longhorn_replace_count=0
longhorn_kubectl() {
  local _kubeconfig="$1"
  shift
  local operation="$1"
  shift
  case "$operation" in
    get)
      [[ "$1 $2 $3 $4" == 'nodes.longhorn.io nuc1 --output json' ]] || return 2
      cat "$longhorn_state"
      ;;
    replace)
      [[ "$1 $2" == '--filename -' ]] || return 2
      replacement="$(cat)"
      current_version="$(yq -r '.metadata.resourceVersion' "$longhorn_state")"
      [[ "$(yq -r '.metadata.resourceVersion' - <<<"$replacement")" == "$current_version" ]] || return 1
      NEXT_VERSION="$((current_version + 1))" \
        yq '.metadata.resourceVersion = strenv(NEXT_VERSION)' \
        <<<"$replacement" >"$state_dir/longhorn-next.json"
      mv "$state_dir/longhorn-next.json" "$longhorn_state"
      longhorn_replace_count=$((longhorn_replace_count + 1))
      ;;
    *) return 2 ;;
  esac
}

captured_record="$(build_maintenance_lifecycle_record fake-kubeconfig nuc1)"
[[ "$(yq -o=json -I=0 '.' - <<<"$captured_record")" == \
  "$(yq -o=json -I=0 '.' - <<<"$maintenance_record")" ]]
apply_longhorn_maintenance_state fake-kubeconfig nuc1 "$captured_record"
[[ "$(yq -r '[.spec.allowScheduling, .spec.evictionRequested] | join(" ")' "$longhorn_state")" == 'false true' ]]
restore_longhorn_maintenance_state fake-kubeconfig nuc1 "$captured_record"
[[ "$(yq -r '[.spec.allowScheduling, .spec.evictionRequested] | join(" ")' "$longhorn_state")" == 'true false' ]]
restored_replace_count="$longhorn_replace_count"
restore_longhorn_maintenance_state fake-kubeconfig nuc1 "$captured_record"
[[ "$longhorn_replace_count" == "$restored_replace_count" ]]

yq '.spec.allowScheduling = false | .spec.evictionRequested = false' \
  "$longhorn_state" >"$state_dir/longhorn-conflict.json"
mv "$state_dir/longhorn-conflict.json" "$longhorn_state"
restore_longhorn_maintenance_state fake-kubeconfig nuc1 "$captured_record"
[[ "$(yq -r '[.spec.allowScheduling, .spec.evictionRequested] | join(" ")' "$longhorn_state")" == 'true false' ]]

yq '.spec.allowScheduling = "external"' \
  "$longhorn_state" >"$state_dir/longhorn-conflict.json"
mv "$state_dir/longhorn-conflict.json" "$longhorn_state"
conflict_replace_count="$longhorn_replace_count"
assert_fails 'Conflicting live Longhorn state was overwritten.' \
  restore_longhorn_maintenance_state fake-kubeconfig nuc1 "$captured_record"
[[ "$longhorn_replace_count" == "$conflict_replace_count" ]]

echo 'Node lifecycle state tests passed.'
