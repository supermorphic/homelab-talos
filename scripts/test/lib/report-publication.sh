#!/usr/bin/env bash
# Validate dedicated publication authority for the exact canonical run.

require_report_publication_confirmation() {
  local linked_worktree="$1"
  local run_id="$2"
  local expected="publish:test-report:$run_id"
  [[ "$linked_worktree" != true ]] || return 0
  [[ "${TEST_REPORT_PUBLISH_CONFIRM:-}" == "$expected" ]] || {
    echo 'Refusing to publish test evidence.' >&2
    echo "Set TEST_REPORT_PUBLISH_CONFIRM='$expected' after reviewing the run." >&2
    return 1
  }
}

validate_report_publication_config() {
  test_access_purpose_check report-publisher "$2" "$1"
}

publication_kubectl() {
  command kubectl "$@"
}
