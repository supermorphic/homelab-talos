#!/usr/bin/env bash
# Negative coverage for the Alloy logs section of scripts/validate/monitoring.sh.
# Mutations run in a disposable source tree and never touch the real repository.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/monitoring.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/monitoring-alloy-logs-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
config="$tree_root/kubernetes/apps/monitoring/alloy-logs/app/config.alloy"
values="$tree_root/kubernetes/apps/monitoring/alloy-logs/app/values.yaml"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root"
  cp "$repo_root/.sops.yaml" "$tree_root/.sops.yaml"
  cp -R "$repo_root/kubernetes" "$tree_root/kubernetes"
  cp -R "$repo_root/scripts" "$tree_root/scripts"
  cp -R "$repo_root/tests" "$tree_root/tests"
}

run_validator() { (cd "$tree_root" && "$validator") 2>&1; }

expect_pass() {
  local description="$1"
  local output status
  set +e
  output="$(run_validator)"
  status="$?"
  set -e
  [[ "$status" -eq 0 ]] || {
    echo "$description: expected the production monitoring source to pass." >&2
    echo "$output" >&2
    exit 1
  }
}

expect_fail() {
  local description="$1"
  local expected_message="$2"
  local output status
  set +e
  output="$(run_validator)"
  status="$?"
  set -e
  [[ "$status" -eq 1 ]] || {
    echo "$description: expected exit 1, got $status." >&2
    echo "$output" >&2
    exit 1
  }
  rg -Fq "$expected_message" <<<"$output" || {
    echo "$description: missing expected failure message: $expected_message" >&2
    echo "$output" >&2
    exit 1
  }
}

replace_once() {
  local file="$1"
  local old="$2"
  local new="$3"
  python - "$file" "$old" "$new" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
text = path.read_text()
if text.count(old) < 1:
    raise SystemExit(f"mutation source not found in {path}: {old!r}")
path.write_text(text.replace(old, new, 1))
PY
}

reset_tree
expect_pass 'production monitoring source'

echo '1. Changing the Pod annotation opt-out rule from drop to keep is rejected.'
reset_tree
replace_once "$config" 'action        = "drop"' 'action        = "keep"'
expect_fail 'Pod annotation opt-out no longer drops targets' \
  'Refusing: Alloy Kubernetes Pod opt-out rule must drop only disabled targets.'

echo '2. Routing Kubernetes files around their protected process is rejected.'
reset_tree
replace_once "$config" \
  'forward_to = [loki.process.kubernetes.receiver]' \
  'forward_to = [loki.write.default.receiver]'
expect_fail 'Kubernetes source bypasses processing' \
  'Refusing: Alloy Kubernetes source must route only through loki.process.kubernetes.'

echo '3. Routing a Talos file source around its protected process is rejected.'
reset_tree
replace_once "$config" \
  'forward_to = [loki.process.talos.receiver]' \
  'forward_to = [loki.write.default.receiver]'
expect_fail 'Talos source bypasses processing' \
  'Refusing: every Alloy Talos source must route only through loki.process.talos.'

echo '4. Adding a dynamic label after the Kubernetes allowlist is rejected.'
reset_tree
replace_once "$config" \
  $'\tforward_to = [loki.write.default.receiver]\n}' \
  $'\tstage.static_labels {\n\t\tvalues = {\n\t\t\tpod_uid = "synthetic",\n\t\t}\n\t}\n\n\tforward_to = [loki.write.default.receiver]\n}'
expect_fail 'dynamic Kubernetes label added after allowlist' \
  'Refusing: Alloy Kubernetes processing stages must end with the exact label allowlist.'

echo '5. Adding a label to the final Kubernetes allowlist is rejected.'
reset_tree
replace_once "$config" \
  'values = ["cluster", "source", "namespace", "app", "container", "node", "stream"]' \
  'values = ["cluster", "source", "namespace", "app", "container", "node", "stream", "pod_uid"]'
expect_fail 'Kubernetes final label allowlist expanded' \
  'Refusing: Alloy Kubernetes final label allowlist drifted.'

echo '6. Adding structured metadata is rejected.'
reset_tree
replace_once "$config" \
  $'\tstage.label_keep {\n\t\tvalues = ["cluster", "source", "node", "service"]\n\t}' \
  $'\tstage.structured_metadata {\n\t\tvalues = {\n\t\t\ttrace_id = "stream",\n\t\t}\n\t}\n\n\tstage.label_keep {\n\t\tvalues = ["cluster", "source", "node", "service"]\n\t}'
expect_fail 'structured metadata enabled' \
  'Refusing: Alloy log processing must not create structured metadata.'

echo '7. Enabling a Loki write WAL is rejected.'
reset_tree
replace_once "$config" \
  $'loki.write "default" {' \
  $'loki.write "default" {\n\twal {\n\t\tenabled = true\n\t}'
expect_fail 'Alloy WAL enabled' 'Refusing: Alloy Loki delivery must not enable a WAL.'

echo '8. Rendering an Alloy image other than v1.19.0 is rejected.'
reset_tree
yq -i '.image.tag = "v1.18.0"' "$values"
expect_fail 'Alloy image version drifted' \
  'Refusing: rendered Alloy image must be docker.io/grafana/alloy:v1.19.0.'

echo '9. Rendered privilege escalation is rejected.'
reset_tree
yq -i '.alloy.securityContext.allowPrivilegeEscalation = true' "$values"
expect_fail 'Alloy privilege escalation enabled' \
  'Refusing: rendered Alloy must disable privilege escalation.'

echo '10. Rendered privileged mode is rejected.'
reset_tree
yq -i '.alloy.securityContext.privileged = true' "$values"
expect_fail 'Alloy privileged mode enabled' \
  'Refusing: rendered Alloy must disable privileged mode.'

echo '11. Rendered Linux capabilities are rejected.'
reset_tree
yq -i '.alloy.securityContext.capabilities.drop = []' "$values"
expect_fail 'Alloy retained Linux capabilities' \
  'Refusing: rendered Alloy must drop every Linux capability.'

echo '12. A writable rendered root filesystem is rejected.'
reset_tree
yq -i '.alloy.securityContext.readOnlyRootFilesystem = false' "$values"
expect_fail 'Alloy root filesystem became writable' \
  'Refusing: rendered Alloy root filesystem must be read-only.'

echo '13. Changing the bounded rendered UID is rejected.'
reset_tree
yq -i '.alloy.securityContext.runAsUser = 65534' "$values"
expect_fail 'Alloy UID drifted' \
  'Refusing: rendered Alloy UID must remain 0 for Talos mode-0640 logs.'

echo '14. Removing the rendered RuntimeDefault seccomp profile is rejected.'
reset_tree
yq -i '.alloy.securityContext.seccompProfile.type = "Unconfined"' "$values"
expect_fail 'Alloy seccomp profile weakened' \
  'Refusing: rendered Alloy must use the RuntimeDefault seccomp profile.'

echo 'Alloy logs validator mutation tests passed.'
