#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo 'Usage: status.sh <all|nuc1|nuc2|nuc3> <talosconfig>' >&2
  exit 2
}

requested_node="$1"
talosconfig="$2"
nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
talosctl_bin="${CLUSTER_TALOSCTL:-talosctl}"

case "$requested_node" in
  all|nuc1|nuc2|nuc3) ;;
  *)
    echo 'Node must be one of: all, nuc1, nuc2, nuc3.' >&2
    exit 1
    ;;
esac

echo '=== etcd membership from nuc1 ==='
"$talosctl_bin" etcd members \
  --nodes 192.168.90.10 \
  --endpoints "$nodes_csv" \
  --talosconfig "$talosconfig"

for node_spec in 'nuc1:192.168.90.10' 'nuc2:192.168.90.11' 'nuc3:192.168.90.12'; do
  node="${node_spec%%:*}"
  node_ip="${node_spec#*:}"
  [[ "$requested_node" == 'all' || "$requested_node" == "$node" ]] || continue
  echo "=== $node etcd service ==="
  "$talosctl_bin" service etcd \
    --nodes "$node_ip" \
    --endpoints "$nodes_csv" \
    --talosconfig "$talosconfig"

  echo "=== $node cluster discovery ==="
  "$talosctl_bin" get members \
    --nodes "$node_ip" \
    --endpoints "$nodes_csv" \
    --talosconfig "$talosconfig"

  echo "=== $node recent etcd log ==="
  if ! "$talosctl_bin" logs etcd \
    --nodes "$node_ip" \
    --endpoints "$nodes_csv" \
    --talosconfig "$talosconfig" \
    --tail 80; then
    echo "$node etcd log is not available."
  fi
done
