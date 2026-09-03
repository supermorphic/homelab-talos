#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/node-lifecycle-state.sh
source scripts/node/common.sh
source scripts/node/longhorn.sh
source scripts/node/drain.sh
source scripts/node/recovery.sh
source scripts/node/lifecycle.sh
source scripts/node/resize-longhorn.sh

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

node_fixture="$(node_json True false "$reboot_record" True false '')"
assert_fails 'A lifecycle record without its cordon was accepted for recovery.' \
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
captured_resource_version="$(yq -r '.metadata.resourceVersion' "$longhorn_state")"
[[ "$(yq -o=json -I=0 '.' - <<<"$captured_record")" == \
  "$(yq -o=json -I=0 '.' - <<<"$maintenance_record")" ]]
apply_longhorn_maintenance_state fake-kubeconfig nuc1 "$captured_record" \
  "$captured_resource_version"
[[ "$(yq -r '[.spec.allowScheduling, .spec.evictionRequested] | join(" ")' "$longhorn_state")" == 'false true' ]]
restore_longhorn_maintenance_state fake-kubeconfig nuc1 "$captured_record"
[[ "$(yq -r '[.spec.allowScheduling, .spec.evictionRequested] | join(" ")' "$longhorn_state")" == 'true false' ]]
restored_replace_count="$longhorn_replace_count"
restore_longhorn_maintenance_state fake-kubeconfig nuc1 "$captured_record"
[[ "$longhorn_replace_count" == "$restored_replace_count" ]]
assert_fails 'A stale Longhorn resourceVersion was accepted for maintenance entry.' \
  apply_longhorn_maintenance_state fake-kubeconfig nuc1 "$captured_record" \
    "$captured_resource_version"

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

controlled_pods='{
  "items": [
    {
      "metadata": {
        "namespace": "media",
        "name": "plex-abc",
        "ownerReferences": [{"kind": "ReplicaSet", "name": "plex-123", "controller": true}]
      },
      "spec": {
        "volumes": [
          {"name": "config", "persistentVolumeClaim": {"claimName": "plex-config"}},
          {"name": "transcode", "emptyDir": {}}
        ]
      }
    },
    {
      "metadata": {
        "namespace": "kube-system",
        "name": "cilium-abc",
        "ownerReferences": [{"kind": "DaemonSet", "name": "cilium", "controller": true}]
      },
      "spec": {"volumes": []}
    }
  ]
}'
validate_drain_pods "$controlled_pods" >/dev/null
empty_dir_report="$(report_drain_local_data "$controlled_pods")"
rg -q 'media/plex-abc.*transcode' <<<"$empty_dir_report"

unmanaged_pods='{
  "items": [{
    "metadata": {"namespace": "default", "name": "unmanaged", "ownerReferences": []},
    "spec": {"volumes": []}
  }]
}'
assert_fails 'An unmanaged Pod was accepted for drain.' \
  validate_drain_pods "$unmanaged_pods"

mirror_pods='{
  "items": [{
    "metadata": {
      "namespace": "kube-system",
      "name": "static",
      "annotations": {"kubernetes.io/config.mirror": "fixture"}
    },
    "spec": {"volumes": []}
  }]
}'
validate_drain_pods "$mirror_pods" >/dev/null

drain_calls="$state_dir/drain-calls"
touch "$drain_calls"
eviction_available=true
drain_kubectl() {
  local _kubeconfig="$1"
  shift
  printf '%s\n' "$*" >>"$drain_calls"
  if [[ "$*" == 'get --raw /apis/policy/v1' ]]; then
    if [[ "$eviction_available" == 'true' ]]; then
      printf '%s\n' '{"resources":[{"name":"pods/eviction","kind":"Eviction"}]}'
    else
      printf '%s\n' '{"resources":[]}'
    fi
  fi
}

perform_kubernetes_drain fake-kubeconfig nuc1
drain_command="$(tail -1 "$drain_calls")"
rg -q '^drain nuc1 ' <<<"$drain_command"
rg -q -- '--ignore-daemonsets' <<<"$drain_command"
rg -q -- '--delete-emptydir-data' <<<"$drain_command"
rg -q -- '--timeout=' <<<"$drain_command"
if rg -q -- '--disable-eviction|--force' <<<"$drain_command"; then
  fail "Unsafe drain flag found: $drain_command"
fi

eviction_available=false
before_refusal_lines="$(wc -l <"$drain_calls" | tr -d ' ')"
assert_fails 'Drain ran without the policy/v1 Eviction resource.' \
  perform_kubernetes_drain fake-kubeconfig nuc1
after_refusal_lines="$(wc -l <"$drain_calls" | tr -d ' ')"
[[ "$after_refusal_lines" -eq $((before_refusal_lines + 1)) ]]

plex_values='kubernetes/apps/media/plex/app/values.yaml'
[[ "$(yq -r '.controllers.plex.strategy' "$plex_values")" == 'Recreate' ]]
[[ "$(yq -r '.controllers.plex.pod.terminationGracePeriodSeconds' "$plex_values")" == '120' ]]
[[ "$(yq -r '.controllers.plex.containers.app.probes.readiness.spec.httpGet.path' "$plex_values")" == '/identity' ]]
[[ "$(yq -r '.persistence.config.type' "$plex_values")" == 'persistentVolumeClaim' ]]
[[ "$(yq -r '.persistence.media.type' "$plex_values")" == 'persistentVolumeClaim' ]]
[[ "$(yq -r '.persistence.media.existingClaim' "$plex_values")" == 'media-data' ]]
[[ "$(yq -r '.persistence.transcode.type' "$plex_values")" == 'emptyDir' ]]

recovery_calls=''
record_recovery_call() {
  recovery_calls+="${recovery_calls:+ }$1"
}
verify_returned_node_contained() { record_recovery_call contained; }
verify_talos_recovery() { record_recovery_call talos; }
restore_longhorn_maintenance_state() { record_recovery_call longhorn-restore; }
verify_longhorn_convergence() { record_recovery_call longhorn-converged; }
verify_etcd_recovery() { record_recovery_call etcd; }
verify_cilium_recovery() { record_recovery_call cilium; }
verify_workload_replacements() { record_recovery_call workloads; }
recovery_just() {
  [[ "$*" == 'kube foundation-verify' ]] || return 2
  record_recovery_call foundation
}

# shellcheck disable=SC2218  # The later definitions are deliberate transaction fakes.
perform_recovery_acceptance fake-kubeconfig fake-talosconfig nuc1 192.168.90.10 \
  "$maintenance_record" fake-inventory
[[ "$recovery_calls" == \
  'contained talos longhorn-restore longhorn-converged etcd cilium workloads foundation' ]]

recovery_calls=''
# shellcheck disable=SC2218  # The later definitions are deliberate transaction fakes.
perform_recovery_acceptance fake-kubeconfig fake-talosconfig nuc1 192.168.90.10 \
  "$reboot_record"
[[ "$recovery_calls" == 'contained talos longhorn-converged etcd cilium foundation' ]]

capacity_nodes="$state_dir/capacity-nodes.json"
capacity_pods="$state_dir/capacity-pods.json"
cat >"$capacity_nodes" <<'EOF'
{"items":[
  {"metadata":{"name":"nuc1","labels":{"kubernetes.io/hostname":"nuc1"}},"status":{"allocatable":{"cpu":"4000m","memory":"8Gi","pods":"110","gpu.intel.com/i915":"1"}}},
  {"metadata":{"name":"nuc2","labels":{"kubernetes.io/hostname":"nuc2"}},"status":{"allocatable":{"cpu":"4000m","memory":"8Gi","pods":"110","gpu.intel.com/i915":"1"}}},
  {"metadata":{"name":"nuc3","labels":{"kubernetes.io/hostname":"nuc3"}},"status":{"allocatable":{"cpu":"4000m","memory":"8Gi","pods":"110","gpu.intel.com/i915":"1"}}}
]}
EOF
cat >"$capacity_pods" <<'EOF'
{"items":[
  {"metadata":{"namespace":"media","name":"plex","ownerReferences":[{"kind":"ReplicaSet","controller":true}]},"spec":{"nodeName":"nuc1","containers":[{"resources":{"requests":{"cpu":"100m","memory":"512Mi","gpu.intel.com/i915":"1"}}}]},"status":{"phase":"Running"}},
  {"metadata":{"namespace":"default","name":"existing","ownerReferences":[{"kind":"ReplicaSet","controller":true}]},"spec":{"nodeName":"nuc2","containers":[{"resources":{"requests":{"cpu":"500m","memory":"1Gi"}}}]},"status":{"phase":"Running"}}
]}
EOF
mise exec -- python scripts/node/capacity.py nuc1 "$capacity_nodes" "$capacity_pods" >/dev/null
yq '(.items[] | select(.metadata.name != "nuc1") | .status.allocatable."gpu.intel.com/i915") = "0"' \
  "$capacity_nodes" >"$state_dir/capacity-blocked.json"
assert_fails 'Insufficient extended-resource headroom was accepted.' \
  mise exec -- python scripts/node/capacity.py nuc1 \
    "$state_dir/capacity-blocked.json" "$capacity_pods"

NODE_MAINTENANCE_CONFIRM='enter:nuc1:192.168.90.10' \
  require_exact_confirmation NODE_MAINTENANCE_CONFIRM 'enter:nuc1:192.168.90.10'
NODE_REBOOT_CONFIRM='reboot:nuc1:192.168.90.10' \
  require_exact_confirmation NODE_REBOOT_CONFIRM 'reboot:nuc1:192.168.90.10'
NODE_LIFECYCLE_CONFIRM='accept:nuc1:maintenance' \
  require_exact_confirmation NODE_LIFECYCLE_CONFIRM 'accept:nuc1:maintenance'
assert_fails 'A stale maintenance confirmation was accepted.' \
  env NODE_MAINTENANCE_CONFIRM='enter:nuc2:192.168.90.11' bash -c \
    'source scripts/node/common.sh; require_exact_confirmation NODE_MAINTENANCE_CONFIRM enter:nuc1:192.168.90.10'

transaction_calls=''
record_transaction_call() {
  transaction_calls+="${transaction_calls:+ }$1"
}
persist_node_containment() { record_transaction_call contain; }
apply_longhorn_maintenance_state() { record_transaction_call longhorn-during; }
capture_drain_inventory() { record_transaction_call inventory; }
perform_kubernetes_drain() { record_transaction_call drain; }
verify_workload_replacements() { record_transaction_call replacements; }
verify_no_drainable_workloads() { record_transaction_call drain-empty; }
evacuate_longhorn_replicas() { record_transaction_call longhorn-evacuated; }
verify_short_absence_longhorn_safety() { record_transaction_call longhorn-safe; }
repeat_disruption_safety() { record_transaction_call safety-repeat; }
send_talos_shutdown() { record_transaction_call shutdown; }
send_talos_reboot() { record_transaction_call reboot; }
verify_node_offline() { record_transaction_call offline; }
observe_node_reboot() { record_transaction_call reboot-observed; }
perform_recovery_acceptance() { record_transaction_call accepted; }
remove_node_containment_and_uncordon() { record_transaction_call uncordon; }

run_maintenance_enter_transaction fake-kubeconfig fake-talosconfig nuc1 \
  192.168.90.10 holder "$maintenance_record" fake-inventory
[[ "$transaction_calls" == \
  'contain longhorn-during inventory drain replacements drain-empty longhorn-evacuated safety-repeat shutdown offline' ]]

transaction_calls=''
run_reboot_transaction fake-kubeconfig fake-talosconfig nuc1 \
  192.168.90.10 holder "$reboot_record" fake-inventory
[[ "$transaction_calls" == \
  'contain inventory drain replacements drain-empty longhorn-safe safety-repeat reboot reboot-observed accepted safety-repeat uncordon' ]]

transaction_calls=''
run_maintenance_exit_transaction fake-kubeconfig fake-talosconfig nuc1 \
  192.168.90.10 holder "$maintenance_record" fake-inventory
[[ "$transaction_calls" == 'accepted safety-repeat uncordon' ]]

# shellcheck disable=SC2329  # Invoked indirectly by run_reboot_transaction.
perform_kubernetes_drain() { record_transaction_call drain; return 1; }
transaction_calls=''
assert_fails 'A blocked drain did not stop reboot.' \
  run_reboot_transaction fake-kubeconfig fake-talosconfig nuc1 \
    192.168.90.10 holder "$reboot_record" fake-inventory
[[ "$transaction_calls" == 'contain inventory drain' ]]

perform_kubernetes_drain() { record_transaction_call drain; }
perform_recovery_acceptance() { record_transaction_call accepted; return 1; }
transaction_calls=''
assert_fails 'Rejected recovery was reported as a successful reboot.' \
  run_reboot_transaction fake-kubeconfig fake-talosconfig nuc1 \
    192.168.90.10 holder "$reboot_record" fake-inventory
[[ "$transaction_calls" != *uncordon* ]]

resize_calls=''
verify_test_lease_holder() { resize_calls+="${resize_calls:+ }lease"; }
assert_cluster_disruption_admissible() { resize_calls+="${resize_calls:+ }admission"; }
resize_just() {
  [[ "$*" == 'bootstrap _resize-longhorn-raw nuc1' ]] || return 2
  resize_calls+="${resize_calls:+ }resize"
}
run_resize_longhorn_transaction fake-kubeconfig nuc1 holder
[[ "$resize_calls" == 'lease admission resize' ]]

echo 'Node lifecycle state tests passed.'
