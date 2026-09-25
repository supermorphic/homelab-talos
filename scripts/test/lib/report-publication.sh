#!/usr/bin/env bash
# Select publication authority without changing a worktree's default context.

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

select_report_publication_context() {
  local kubeconfig="$1"
  local linked_worktree="$2"
  local contexts mapping
  contexts="$(kubectl --kubeconfig "$kubeconfig" config get-contexts --output name)" || return 1
  report_publication_context=''
  if [[ "$linked_worktree" == true ]] ||
    [[ "$contexts" == *homelab-observer* || "$contexts" == *homelab-diagnostic* ||
      "$contexts" == *homelab-report-publisher* ]]; then
    if ! rg -qx 'homelab-report-publisher' <<<"$contexts"; then
      echo 'Publication requires homelab-report-publisher; reinstall scoped worktree credentials after deployment.' >&2
      return 1
    fi
    mapping="$(kubectl --kubeconfig "$kubeconfig" --context homelab-report-publisher \
      config view --minify --output 'jsonpath={.contexts[0].context.user}')" || return 1
    [[ "$mapping" == homelab-report-publisher ]] || {
      echo 'Publication context must use the homelab-report-publisher identity.' >&2
      return 1
    }
    report_publication_context=homelab-report-publisher
  else
    # An operator outside a linked worktree keeps their explicitly supplied
    # credential. Never search for or obtain a broader credential here.
    report_publication_context="$(kubectl --kubeconfig "$kubeconfig" config current-context)" || return 1
    [[ -n "$report_publication_context" ]] || return 1
  fi
}

publication_kubectl() {
  command kubectl --context "$report_publication_context" "$@"
}
