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
  # This fixture owns the complete private mktemp directory.
  rm -rf -- "$test_root"
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

MOCK_LOG="$test_root/invocations.log" HOMELAB_TEST_RUN_DIR="$pass_dir" \
  scripts/test/scenarios/media-hardlink.sh fake-kubeconfig >/dev/null
yq -e '.status == "passed"' "$pass_dir/recovery.json" >/dev/null
yq -e '.sameInode == true and .srcLinkCount == 2 and .dstLinkCount == 2' \
  "$pass_dir/evidence.json" >/dev/null
yq -e '.qbitHeldPlexOpen == true and .plexHeldQbitOpen == true' \
  "$pass_dir/evidence.json" >/dev/null
[[ "$(rg -c '^holder ' "$test_root/invocations.log")" == 2 ]]
[[ "$(rg -c '^opener ' "$test_root/invocations.log")" == 2 ]]
rg -q '^holder .*qbittorrent-test-0.*\/data\/downloads\/.* rw$' "$test_root/invocations.log"
rg -q '^opener .*plex-test-0.*\/Volumes\/Prometheus\/media\/.* ro$' "$test_root/invocations.log"
rg -q '^holder .*plex-test-0.*\/Volumes\/Prometheus\/media\/.* ro$' "$test_root/invocations.log"
rg -q '^opener .*qbittorrent-test-0.*\/data\/downloads\/.* rw$' "$test_root/invocations.log"

mkdir -p "$pass_dir/logs" "$pass_dir/diagnostics"
touch "$pass_dir/environment.json" "$pass_dir/junit.xml" "$pass_dir/summary.json"
normalize_native_artifacts "$pass_dir" fixture-run
write_evidence_index "$pass_dir" fixture-run
expected_root=$'diagnostics\nenvironment.json\nevidence.json\njunit.xml\nlogs\nsummary.json'
actual_root="$(find "$pass_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
[[ "$actual_root" == "$expected_root" ]] || {
  echo 'Media hardlink outputs broke the canonical six-entry structure.' >&2
  diff -u <(printf '%s\n' "$expected_root") <(printf '%s\n' "$actual_root") >&2 || true
  exit 1
}
jq -e '[.artifacts[] | select(.path | startswith("diagnostics/media-hardlink/"))] | length == 8' \
  "$pass_dir/evidence.json" >/dev/null

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
