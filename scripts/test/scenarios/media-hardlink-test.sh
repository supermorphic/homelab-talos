#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/results.sh

test_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-media-hardlink-test.XXXXXX")"
pass_dir="$test_root/pass"
primary_failure_dir="$test_root/primary-failure"
cleanup_failure_dir="$test_root/cleanup-failure"
mkdir -p "$pass_dir" "$primary_failure_dir" "$cleanup_failure_dir"
cleanup() {
  rm -f \
    "$pass_dir/evidence.json" "$pass_dir/recovery.json" \
    "$primary_failure_dir/evidence.json" "$primary_failure_dir/recovery.json" \
    "$cleanup_failure_dir/evidence.json" "$cleanup_failure_dir/recovery.json"
  rmdir "$pass_dir" "$primary_failure_dir" "$cleanup_failure_dir" "$test_root"
}
trap cleanup EXIT

# Export a kubectl function so the orchestrator runs without a kubeconfig or cluster. It
# returns one Sonarr pod, deterministic hardlink stats, and an independently controllable
# teardown result.
kubectl() {
  local command="$*"
  case "$command" in
    *" get pod "*) printf 'sonarr-test-0' ;;
    *" exec "*)
      if [[ "$command" == *"rm -rf"* ]]; then
        [[ "${MOCK_CLEANUP_FAIL:-false}" != true ]]
      elif [[ "${MOCK_PRIMARY_FAIL:-false}" == true ]]; then
        printf 'invalid'
      else
        printf '123 2|123 2'
      fi
      ;;
    *) return 1 ;;
  esac
}
export -f kubectl

HOMELAB_TEST_RUN_DIR="$pass_dir" \
  scripts/test/scenarios/media-hardlink.sh fake-kubeconfig >/dev/null
yq -e '.status == "passed"' "$pass_dir/recovery.json" >/dev/null
yq -e '.sameInode == true and .srcLinkCount == 2 and .dstLinkCount == 2' \
  "$pass_dir/evidence.json" >/dev/null

if MOCK_PRIMARY_FAIL=true HOMELAB_TEST_RUN_DIR="$primary_failure_dir" \
  scripts/test/scenarios/media-hardlink.sh fake-kubeconfig >/dev/null 2>&1; then
  echo 'The media-hardlink orchestrator should fail on invalid inode evidence.' >&2
  exit 1
fi
yq -e '.status == "passed"' "$primary_failure_dir/recovery.json" >/dev/null

MOCK_CLEANUP_FAIL=true HOMELAB_TEST_RUN_DIR="$cleanup_failure_dir" \
  scripts/test/scenarios/media-hardlink.sh fake-kubeconfig >/dev/null
yq -e '.status == "failed"' "$cleanup_failure_dir/recovery.json" >/dev/null
[[ "$(result_exit_code 0 "$(recorded_recovery_status "$cleanup_failure_dir")")" -eq 1 ]] || {
  echo 'A recorded media-hardlink teardown failure must fail the overall result.' >&2
  exit 1
}

echo 'media-hardlink cleanup reporting tests passed.'
