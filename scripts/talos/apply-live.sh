#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 3 ]] || {
  echo 'Usage: apply-live.sh <node> <talosconfig> <generated-config>' >&2
  exit 64
}

node="$1"
talosconfig="$2"
config="$3"

case "$node" in
  nuc1) node_ip='192.168.90.10' ;;
  nuc2) node_ip='192.168.90.11' ;;
  nuc3) node_ip='192.168.90.12' ;;
  *)
    echo 'Node must be one of: nuc1, nuc2, nuc3.' >&2
    exit 1
    ;;
esac

[[ -f "$talosconfig" ]] || {
  echo "Missing $talosconfig; run just talos generate first." >&2
  exit 1
}
[[ -f "$config" ]] || {
  echo "Missing $config; run just talos generate first." >&2
  exit 1
}

# Confirm the target is the intended running node via its secure API; this
# script never uses --insecure, so it refuses a node that is not bootstrapped.
hostname_state="$(talosctl get hostname \
  --nodes "$node_ip" \
  --endpoints "$node_ip" \
  --talosconfig "$talosconfig" \
  --output yaml)"
[[ "$(yq -r '.spec.hostname' - <<<"$hostname_state")" == "$node" ]] || {
  echo "Refusing apply-live: $node_ip does not report hostname $node over the secure API." >&2
  exit 1
}

# Dry run in no-reboot mode: this validates acceptance, prints the diff, and
# fails if the change would require a reboot (use a rolling procedure for those).
if ! dry_run_output="$(talosctl apply-config \
  --nodes "$node_ip" \
  --endpoints "$node_ip" \
  --talosconfig "$talosconfig" \
  --file "$config" \
  --mode=no-reboot \
  --dry-run 2>&1)"; then
  echo "Refusing apply-live: Talos rejected the no-reboot dry run for $node." >&2
  echo 'A change that needs a reboot must be applied one node at a time with health checks, not apply-live.' >&2
  printf '%s\n' "$dry_run_output" >&2
  exit 1
fi
printf '%s\n' "$dry_run_output"

expected_confirmation="apply-live:${node}:${node_ip}:no-reboot"
[[ "${TALOS_APPLY_LIVE_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing to apply the machine config to running $node." >&2
  echo "Set TALOS_APPLY_LIVE_CONFIRM='$expected_confirmation' and rerun after reviewing the dry-run diff." >&2
  exit 1
}

echo "Applying $config to running $node ($node_ip) in no-reboot mode."
talosctl apply-config \
  --nodes "$node_ip" \
  --endpoints "$node_ip" \
  --talosconfig "$talosconfig" \
  --file "$config" \
  --mode=no-reboot

post_apply_output="$(talosctl apply-config \
  --nodes "$node_ip" \
  --endpoints "$node_ip" \
  --talosconfig "$talosconfig" \
  --file "$config" \
  --mode=no-reboot \
  --dry-run 2>&1)" || {
  echo "Talos post-apply convergence check failed for $node." >&2
  exit 1
}
post_apply_diff="${post_apply_output#*$'Config diff:\n\n'}"
[[ "$post_apply_diff" == 'No changes.' ]] || {
  echo "Talos still reports machine-configuration drift after apply-live for $node." >&2
  printf '%s\n' "$post_apply_output" >&2
  exit 1
}
echo "Talos apply-live converged on $node; the post-apply dry run reports no changes."
