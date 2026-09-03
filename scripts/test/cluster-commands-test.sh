#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-cluster-commands-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT

root_list="$(mise exec -- just --list --unsorted)"
rg -q '^    node \.\.\.$' <<<"$root_list"
rg -q '^    cluster \.\.\.$' <<<"$root_list"

node_list="$(mise exec -- just --justfile .just/node.just --list --unsorted)"
for command in maintenance-check maintenance-enter maintenance-exit reboot resize-longhorn; do
  rg -q "^    ${command}( |$)" <<<"$node_list"
done

cluster_list="$(mise exec -- just --justfile .just/cluster.just --list --unsorted)"
rg -q '^    status( |$)' <<<"$cluster_list"
rg -q '^    verify( |$)' <<<"$cluster_list"

bootstrap_list="$(mise exec -- just --justfile .just/bootstrap.just --list --unsorted)"
for retired in status reboot resize-longhorn verify; do
  if rg -q "^    ${retired}( |$)" <<<"$bootstrap_list"; then
    echo "Retired public bootstrap command remains: $retired" >&2
    exit 1
  fi
done
mise exec -- just --justfile .just/bootstrap.just --show _verify-pre-cilium >/dev/null
cilium_recipe="$(mise exec -- just --justfile .just/bootstrap.just --show cilium)"
rg -q 'just bootstrap _verify-pre-cilium' <<<"$cilium_recipe"

talosconfig="$fixture_root/talosconfig"
kubeconfig="$fixture_root/kubeconfig"
nodes="$fixture_root/nodes.json"
calls="$fixture_root/calls"
touch "$kubeconfig" "$calls"
cat >"$talosconfig" <<'EOF'
context: homelab
contexts:
  homelab:
    endpoints:
      - 192.168.90.10
      - 192.168.90.11
      - 192.168.90.12
EOF
cat >"$nodes" <<'EOF'
{"items":[{"metadata":{"name":"nuc1"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc2"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc3"},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}
EOF

CLUSTER_KUBECTL="$repo_root/tests/fixtures/cluster-commands/fake-kubectl.sh" \
CLUSTER_TALOSCTL="$repo_root/tests/fixtures/cluster-commands/fake-talosctl.sh" \
CLUSTER_JUST="$repo_root/tests/fixtures/cluster-commands/fake-just.sh" \
CLUSTER_TEST_NODES="$nodes" \
CLUSTER_TEST_CALLS="$calls" \
  scripts/cluster/verify.sh "$kubeconfig" "$talosconfig"
[[ "$(<"$calls")" == $'kube cilium-verify\nkube storage-verify' ]]

set +e
CLUSTER_KUBECTL="$repo_root/tests/fixtures/cluster-commands/fake-kubectl.sh" \
CLUSTER_TALOSCTL="$repo_root/tests/fixtures/cluster-commands/fake-talosctl.sh" \
CLUSTER_JUST="$repo_root/tests/fixtures/cluster-commands/fake-just.sh" \
CLUSTER_TEST_NODES="$nodes" \
CLUSTER_TEST_CALLS="$calls" \
CLUSTER_TEST_FAIL='storage-verify' \
  scripts/cluster/verify.sh "$kubeconfig" "$talosconfig" >/dev/null 2>&1
failure_exit="$?"
set -e
[[ "$failure_exit" -ne 0 ]]

echo 'Cluster command contract tests passed.'
