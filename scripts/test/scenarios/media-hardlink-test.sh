#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/results.sh

test_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-media-hardlink-test.XXXXXX")"
pass_dir="$test_root/pass"
primary_failure_dir="$test_root/primary-failure"
open_failure_dir="$test_root/open-failure"
open_timeout_dir="$test_root/open-timeout"
cleanup_failure_dir="$test_root/cleanup-failure"
mkdir -p "$pass_dir" "$primary_failure_dir" "$open_failure_dir" "$open_timeout_dir" "$cleanup_failure_dir"
cleanup() {
  rm -f \
    "$pass_dir/evidence.json" "$pass_dir/recovery.json" "$pass_dir/invocations.log" \
    "$primary_failure_dir/evidence.json" "$primary_failure_dir/recovery.json" \
    "$open_failure_dir/evidence.json" "$open_failure_dir/recovery.json" \
    "$open_timeout_dir/evidence.json" "$open_timeout_dir/recovery.json" \
    "$cleanup_failure_dir/evidence.json" "$cleanup_failure_dir/recovery.json"
  rm -f "$pass_dir"/*.holder.out "$pass_dir"/*.holder.err "$pass_dir"/*.opener.out "$pass_dir"/*.opener.err "$pass_dir"/*.fifo \
    "$open_failure_dir"/*.holder.out "$open_failure_dir"/*.holder.err "$open_failure_dir"/*.opener.out "$open_failure_dir"/*.opener.err "$open_failure_dir"/*.fifo \
    "$open_timeout_dir"/*.holder.out "$open_timeout_dir"/*.holder.err "$open_timeout_dir"/*.opener.out "$open_timeout_dir"/*.opener.err "$open_timeout_dir"/*.fifo \
    "$cleanup_failure_dir"/*.holder.out "$cleanup_failure_dir"/*.holder.err "$cleanup_failure_dir"/*.opener.out "$cleanup_failure_dir"/*.opener.err "$cleanup_failure_dir"/*.fifo
  rmdir "$pass_dir" "$primary_failure_dir" "$open_failure_dir" "$open_timeout_dir" "$cleanup_failure_dir" "$test_root"
}
trap cleanup EXIT

# Export a kubectl function so the orchestrator runs without a kubeconfig or cluster. It
# returns the three consumers, deterministic hardlink stats and reads, and an
# independently controllable teardown result.
kubectl() {
  local command="$*"
  case "$command" in
    *" get pod "*)
      case "$command" in
        *qbittorrent*) printf 'qbittorrent-test-0' ;;
        *plex*) printf 'plex-test-0' ;;
        *) printf 'sonarr-test-0' ;;
      esac
      ;;
    *" exec "*)
      if [[ "$command" == *"rm -rf"* ]]; then
        [[ "${MOCK_CLEANUP_FAIL:-false}" != true ]]
      elif [[ "${MOCK_PRIMARY_FAIL:-false}" == true ]]; then
        printf 'invalid'
      elif [[ "$command" == *"READY"* ]]; then
        [[ -z "${MOCK_LOG:-}" ]] || printf 'holder %s\n' "${command//$'\n'/ }" >>"$MOCK_LOG"
        printf 'READY\n'
        IFS= read -r _
      elif [[ "$command" == *"OPEN_OK"* ]]; then
        [[ -z "${MOCK_LOG:-}" ]] || printf 'opener %s\n' "${command//$'\n'/ }" >>"$MOCK_LOG"
        if [[ "${MOCK_OPEN_HANG:-}" == plex && "$command" == *plex-test-0* ]]; then
          while :; do sleep 1; done
        fi
        [[ "${MOCK_OPEN_FAIL:-}" != plex || "$command" != *plex-test-0* ]] || return 1
        printf 'OPEN_OK\n'
      else
        printf '123 2|123 2'
      fi
      ;;
    *) return 1 ;;
  esac
}
export -f kubectl

MOCK_LOG="$pass_dir/invocations.log" HOMELAB_TEST_RUN_DIR="$pass_dir" \
  scripts/test/scenarios/media-hardlink.sh fake-kubeconfig >/dev/null
yq -e '.status == "passed"' "$pass_dir/recovery.json" >/dev/null
yq -e '.sameInode == true and .srcLinkCount == 2 and .dstLinkCount == 2' \
  "$pass_dir/evidence.json" >/dev/null
yq -e '.qbitHeldPlexOpen == true and .plexHeldQbitOpen == true' \
  "$pass_dir/evidence.json" >/dev/null
[[ "$(rg -c '^holder ' "$pass_dir/invocations.log")" == 2 ]]
[[ "$(rg -c '^opener ' "$pass_dir/invocations.log")" == 2 ]]
rg -q '^holder .*qbittorrent-test-0.*\/data\/downloads\/.* rw$' "$pass_dir/invocations.log"
rg -q '^opener .*plex-test-0.*\/Volumes\/Prometheus\/media\/.* ro$' "$pass_dir/invocations.log"
rg -q '^holder .*plex-test-0.*\/Volumes\/Prometheus\/media\/.* ro$' "$pass_dir/invocations.log"
rg -q '^opener .*qbittorrent-test-0.*\/data\/downloads\/.* rw$' "$pass_dir/invocations.log"

if MOCK_PRIMARY_FAIL=true HOMELAB_TEST_RUN_DIR="$primary_failure_dir" \
  scripts/test/scenarios/media-hardlink.sh fake-kubeconfig >/dev/null 2>&1; then
  echo 'The media-hardlink orchestrator should fail on invalid inode evidence.' >&2
  exit 1
fi
yq -e '.status == "passed"' "$primary_failure_dir/recovery.json" >/dev/null

if MOCK_OPEN_FAIL=plex HOMELAB_TEST_RUN_DIR="$open_failure_dir" \
  scripts/test/scenarios/media-hardlink.sh fake-kubeconfig >/dev/null 2>&1; then
  echo 'A failed Plex open must fail the concurrent-open assertion.' >&2
  exit 1
fi
[[ ! -e "$open_failure_dir/evidence.json" ]]
yq -e '.status == "passed"' "$open_failure_dir/recovery.json" >/dev/null

if MOCK_OPEN_HANG=plex MEDIA_HARDLINK_EXEC_TIMEOUT_TICKS=3 HOMELAB_TEST_RUN_DIR="$open_timeout_dir" \
  scripts/test/scenarios/media-hardlink.sh fake-kubeconfig >/dev/null 2>&1; then
  echo 'A stalled Plex open must time out and fail the concurrent-open assertion.' >&2
  exit 1
fi
[[ ! -e "$open_timeout_dir/evidence.json" ]]
yq -e '.status == "passed"' "$open_timeout_dir/recovery.json" >/dev/null

MOCK_CLEANUP_FAIL=true HOMELAB_TEST_RUN_DIR="$cleanup_failure_dir" \
  scripts/test/scenarios/media-hardlink.sh fake-kubeconfig >/dev/null
yq -e '.status == "failed"' "$cleanup_failure_dir/recovery.json" >/dev/null
[[ "$(result_exit_code 0 "$(recorded_recovery_status "$cleanup_failure_dir")")" -eq 1 ]] || {
  echo 'A recorded media-hardlink teardown failure must fail the overall result.' >&2
  exit 1
}

echo 'media-hardlink cleanup reporting tests passed.'
