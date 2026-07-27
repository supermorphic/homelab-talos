#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-report-install.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
storage="$fixture/storage"
bundle="$fixture/bundle"
run_id='20260727T120000Z-aaaaaaaaaaaa-operator-00000001'
generation='20260727T120100Z-deadbeef'

TEST_REPORTS_STORAGE_ROOT="$storage" \
  sh "$repo_root/kubernetes/apps/monitoring/test-reports/app/bootstrap-storage.sh"
mkdir -p \
  "$bundle/artifact" \
  "$bundle/generation/$generation/api" \
  "$bundle/report/$run_id/awesome"
printf '%s\n' report >"$bundle/report/$run_id/awesome/index.html"
printf '%s\n' artifact >"$bundle/artifact/$run_id.tar.gz"
printf '%s\n' '{"schema_version":1,"runs":[]}' \
  >"$bundle/generation/$generation/catalog.json"
printf '%s\n' '{"schema_version":1}' \
  >"$bundle/generation/$generation/state.json"
printf '%s\n' '<html>index</html>' >"$bundle/generation/$generation/index.html"
printf '%s\n' '{"items":[]}' >"$bundle/generation/$generation/api/homepage.json"
printf '%s\n' '# fixture' >"$bundle/generation/$generation/api/metrics.prom"
: >"$bundle/generation/$generation/history.jsonl"
: >"$bundle/prune.txt"
(
  cd "$bundle"
  find artifact generation report prune.txt -type f -print |
    LC_ALL=C sort |
    while IFS= read -r path; do
      sha256sum "$path"
    done >manifest.sha256
)

tar -cf - -C "$bundle" . |
  TEST_REPORTS_STORAGE_ROOT="$storage" \
    sh "$repo_root/kubernetes/apps/monitoring/test-reports/app/install-report.sh" \
    "$run_id" "$generation"
[[ -f "$storage/reports/$run_id/awesome/index.html" ]]
[[ -f "$storage/artifacts/$run_id.tar.gz" ]]
[[ "$(readlink "$storage/state/current")" == "generations/$generation" ]]
[[ "$(cat "$storage/state/current/index.html")" == '<html>index</html>' ]]

# A failed checksum must leave the active generation untouched.
printf '%s\n' corrupt >>"$bundle/report/$run_id/awesome/index.html"
if tar -cf - -C "$bundle" . |
  TEST_REPORTS_STORAGE_ROOT="$storage" \
    sh "$repo_root/kubernetes/apps/monitoring/test-reports/app/install-report.sh" \
    "$run_id" '20260727T120200Z-feedface' >/dev/null 2>&1; then
  echo 'Installer accepted a corrupt publication bundle.' >&2
  exit 1
fi
[[ "$(readlink "$storage/state/current")" == "generations/$generation" ]]

echo 'Atomic test-report bundle installation passed.'
