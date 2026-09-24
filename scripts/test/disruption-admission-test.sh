#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source scripts/lib/disruption-admission.sh
source scripts/lib/node-target.sh
source scripts/node/resize-longhorn.sh

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

mkdir -p "$temp_dir/resize/clusterconfig" "$temp_dir/resize/talos"
touch "$temp_dir/resize/kubeconfig" "$temp_dir/resize/talosconfig" \
  "$temp_dir/resize/clusterconfig/node-a.yaml"
cp "$temp_dir/talconfig.yaml" "$temp_dir/resize/talos/talconfig.yaml"
resize_calls="$temp_dir/resize-calls"
resolve_cluster_node() { NODE_NAME=node-a; NODE_IP=192.0.2.10; }
require_operator_checkout() { :; }
require_exact_confirmation() { :; }
resize_kube_context() { printf '%s\n' fixture; }
acquire_test_lease() { :; }
start_test_lease_renewal() { :; }
stop_test_lease_renewal() { :; }
release_test_lease() { :; }
verify_test_lease_holder() { :; }
resize_just() { printf '%s\n' "$*" >>"$resize_calls"; }

fake_nodes_json="$(fixture_nodes)"
(
  cd "$temp_dir/resize"
  TALOS_RESIZE_LONGHORN_CONFIRM=resize-longhorn:node-a:192.0.2.10 \
    resize_longhorn_main node-a "$temp_dir/resize/kubeconfig" "$temp_dir/resize/talosconfig"
)
[[ "$(<"$resize_calls")" == 'bootstrap _resize-longhorn-raw node-a' ]]

: >"$resize_calls"
fake_nodes_json="$(fixture_nodes '{"schemaVersion":1,"kind":"maintenance","longhorn":{"allowScheduling":{"before":true,"during":false},"evictionRequested":{"before":false,"during":true}}}' true)"
if (
  cd "$temp_dir/resize"
  TALOS_RESIZE_LONGHORN_CONFIRM=resize-longhorn:node-a:192.0.2.10 \
    resize_longhorn_main node-a "$temp_dir/resize/kubeconfig" "$temp_dir/resize/talosconfig"
); then
  echo 'resize accepted active lifecycle containment' >&2
  exit 1
fi
[[ ! -s "$resize_calls" ]]

fake_nodes_json="$(fixture_nodes '{"schemaVersion":9,"kind":"unknown"}' true)"
if (
  cd "$temp_dir/resize"
  TALOS_RESIZE_LONGHORN_CONFIRM=resize-longhorn:node-a:192.0.2.10 \
    resize_longhorn_main node-a "$temp_dir/resize/kubeconfig" "$temp_dir/resize/talosconfig"
); then
  echo 'resize accepted an unknown lifecycle record' >&2
  exit 1
fi
[[ ! -s "$resize_calls" ]]

fake_nodes_json="$(fixture_nodes)"
verify_test_lease_holder() { return 1; }
if run_resize_longhorn_transaction \
  "$temp_dir/resize/kubeconfig" fixture node-a fixture-holder; then
  echo 'resize continued after Lease ownership loss' >&2
  exit 1
fi
[[ ! -s "$resize_calls" ]]

acquire_test_lease() { return 1; }
if (
  cd "$temp_dir/resize"
  TALOS_RESIZE_LONGHORN_CONFIRM=resize-longhorn:node-a:192.0.2.10 \
    resize_longhorn_main node-a "$temp_dir/resize/kubeconfig" "$temp_dir/resize/talosconfig"
); then
  echo 'resize continued after Lease contention' >&2
  exit 1
fi
[[ ! -s "$resize_calls" ]]

cat >"$temp_dir/resize-cleanup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source scripts/node/resize-longhorn.sh
resolve_cluster_node() { NODE_NAME=node-a; NODE_IP=192.0.2.10; }
require_operator_checkout() { :; }
require_exact_confirmation() { :; }
resize_kube_context() { echo fixture; }
acquire_test_lease() { :; }
start_test_lease_renewal() { :; }
stop_test_lease_renewal() { echo stopped >>"$FIXTURE_LOG"; }
release_test_lease() { echo released >>"$FIXTURE_LOG"; }
run_resize_longhorn_transaction() { return 23; }
cd "$FIXTURE_DIR"
resize_longhorn_main node-a "$FIXTURE_DIR/kubeconfig" "$FIXTURE_DIR/talosconfig"
EOF
cleanup_status=0
: >"$temp_dir/cleanup.log"
FIXTURE_DIR="$temp_dir/resize" FIXTURE_LOG="$temp_dir/cleanup.log" \
  bash "$temp_dir/resize-cleanup.sh" >/dev/null 2>&1 || cleanup_status=$?
[[ "$cleanup_status" == 23 ]]
rg -q '^released$' "$temp_dir/cleanup.log"

echo 'Retained disruption admission and node target tests passed.'
