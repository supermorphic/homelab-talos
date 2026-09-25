#!/usr/bin/env bash
# Reuse the repository Lease contract; never create a second coordination lock.
set -euo pipefail
set +x
export TEST_LEASE_NAMESPACE=flux-system
export TEST_LEASE_NAME=homelab-test-run-lock
unset TEST_LEASE_KUBECTL DISRUPTION_KUBECTL TEST_LEASE_SLEEP
source scripts/lib/lease.sh
source scripts/lib/disruption-admission.sh
mode="$1"
kubeconfig="$2"
holder="$3"
if [[ "$mode" == check ]]; then
  verify_test_lease_holder "$kubeconfig" "$holder" >/dev/null
  assert_established_disruption_admissible "$kubeconfig" >/dev/null
  exit
fi
[[ "$mode" == hold && "$#" -eq 4 ]]
marker="$4"
cleanup() {
  status="$?"
  trap - EXIT
  release_test_lease "$kubeconfig" "$holder" >/dev/null 2>&1 || status=1
  exit "$status"
}
assert_established_disruption_admissible "$kubeconfig" >/dev/null
acquire_test_lease "$kubeconfig" "$holder" 1 existing-only >/dev/null
trap cleanup EXIT
trap 'exit 1' INT TERM
start_test_lease_renewal "$kubeconfig" "$holder" "$marker"
printf 'locked\n'
# The owning Python process closes stdin during normal exit and on exceptions.
while IFS= read -r _; do :; done
