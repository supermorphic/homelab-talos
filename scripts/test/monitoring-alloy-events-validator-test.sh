#!/usr/bin/env bash
# Negative coverage for the Alloy Events section of scripts/validate/monitoring.sh.
# Mutations run in a disposable source tree and never touch the real repository.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
river_validator="$repo_root/scripts/validate/alloy-logs-river.py"
monitoring_validator="$repo_root/scripts/validate/monitoring.sh"
dashboard_validator="$repo_root/scripts/validate/grafana-dashboard.py"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/monitoring-alloy-events-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
config="$tree_root/kubernetes/apps/monitoring/alloy-events/app/config.alloy"
values="$tree_root/kubernetes/apps/monitoring/alloy-events/app/values.yaml"
dashboard="$tree_root/kubernetes/apps/monitoring/loki/app/dashboards/centralized-logs.json"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root"
  cp "$repo_root/.sops.yaml" "$tree_root/.sops.yaml"
  cp -R "$repo_root/kubernetes" "$tree_root/kubernetes"
  cp -R "$repo_root/scripts" "$tree_root/scripts"
  cp -R "$repo_root/tests" "$tree_root/tests"
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

expect_river_fail() {
  local description="$1"
  local expected_message="$2"
  local output status
  set +e
  output="$(python "$river_validator" --events "$config" 2>&1)"
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

expect_monitoring_fail() {
  local description="$1"
  local expected_message="${2:-}"
  local output status
  set +e
  output="$(cd "$tree_root" && "$monitoring_validator" 2>&1)"
  status="$?"
  set -e
  [[ "$status" -eq 1 ]] || {
    echo "$description: expected exit 1, got $status." >&2
    echo "$output" >&2
    exit 1
  }
  if [[ -n "$expected_message" ]]; then
    rg -Fq "$expected_message" <<<"$output" || {
      echo "$description: missing expected failure message: $expected_message" >&2
      echo "$output" >&2
      exit 1
    }
  fi
}

expect_dashboard_fail() {
  local description="$1"
  local expected_message="$2"
  local output status
  set +e
  output="$(python "$dashboard_validator" "$dashboard" 2>&1)"
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

reset_tree
python "$river_validator" --events "$config" >/dev/null
(cd "$tree_root" && "$monitoring_validator" >/dev/null)

echo '1. Limiting Event collection to one namespace is rejected.'
replace_once "$config" 'namespaces = []' 'namespaces = ["default"]'
expect_river_fail 'Event collection is namespace-limited' \
  'Refusing: Alloy Events source must watch all namespaces.'

echo '2. Routing Events around their protected process is rejected.'
reset_tree
replace_once "$config" \
  'forward_to = [loki.process.events.receiver]' \
  'forward_to = [loki.write.default.receiver]'
expect_river_fail 'Event source bypasses processing' \
  'Refusing: Alloy Events source must route only through loki.process.events.'

echo '3. Weakening Event credential redaction is rejected.'
reset_tree
replace_once "$config" \
  'authorization\s*[:=]\s*(?:bearer|basic)' \
  'authorization\s*[:=]\s*bearer'
expect_river_fail 'Event authorization redaction weakened' \
  'Refusing: Alloy Events credential redaction expression drifted.'

echo '4. Adding a forbidden Event label to the four-label allowlist is rejected.'
reset_tree
replace_once "$config" \
  'values = ["cluster", "source", "namespace", "event_type"]' \
  'values = ["cluster", "source", "namespace", "event_type", "reason"]'
expect_river_fail 'Event reason label added' \
  'Refusing: Alloy Events final label allowlist drifted.'

echo '5. Adding Event-derived structured metadata is rejected.'
reset_tree
replace_once "$config" \
  $'\tstage.label_keep {' \
  $'\tstage.structured_metadata {\n\t\tvalues = {\n\t\t\tevent_uid = "event_type",\n\t\t}\n\t}\n\n\tstage.label_keep {'
expect_river_fail 'Event structured metadata added' \
  'Refusing: Alloy log processing must not create structured metadata.'

echo '6. Enabling a Loki write WAL is rejected.'
reset_tree
replace_once "$config" \
  $'loki.write "default" {' \
  $'loki.write "default" {\n\twal {\n\t\tenabled = true\n\t}'
expect_river_fail 'Event delivery WAL enabled' \
  'Refusing: Alloy Loki delivery must not enable a WAL.'

echo '7. Adding a direct Event-to-Loki bypass source is rejected.'
reset_tree
replace_once "$config" \
  $'loki.write "default" {' \
  $'loki.source.kubernetes_events "bypass" {\n\tnamespaces = []\n\tforward_to = [loki.write.default.receiver]\n}\n\nloki.write "default" {'
expect_river_fail 'alternate Event source added' \
  'Refusing: Alloy River component set must contain only the approved Events flow.'

echo '8. Expanding Events-only RBAC is rejected.'
reset_tree
yq -i '.rbac.rules[0].resources += ["secrets"]' "$values"
expect_monitoring_fail 'Alloy Events RBAC expanded' \
  'Refusing: every Alloy Events source RBAC rule must grant only core Events get, list, and watch.'

echo '9. A rolling Event reader Deployment is rejected.'
reset_tree
yq -i '.controller.updateStrategy.type = "RollingUpdate"' "$values"
expect_monitoring_fail 'Alloy Events rolling strategy enabled' \
  'Refusing: Alloy Events controller must use Recreate.'

echo '10. More than one Event reader replica is rejected.'
reset_tree
yq -i '.controller.replicas = 2' "$values"
expect_monitoring_fail 'Alloy Events replica count expanded' \
  'Refusing: Alloy Events controller must have exactly one replica.'

echo '11. Resource envelope drift is rejected.'
reset_tree
yq -i '.alloy.resources.limits.memory = "512Mi"' "$values"
expect_monitoring_fail 'Alloy Events memory limit expanded' \
  'Refusing: Alloy Events resource envelope drifted.'

echo '12. Rendering an Alloy image other than v1.19.0 is rejected.'
reset_tree
yq -i '.image.tag = "v1.18.0"' "$values"
expect_monitoring_fail 'Alloy Events image version drifted' \
  'Refusing: rendered Alloy image must be docker.io/grafana/alloy:v1.19.0.'

echo '13. Weakening the Event reader container hardening is rejected.'
reset_tree
yq -i '.alloy.securityContext.allowPrivilegeEscalation = true' "$values"
expect_monitoring_fail 'Alloy Events privilege escalation enabled' \
  'Refusing: rendered Alloy must disable privilege escalation.'

echo '14. Redirecting credential redaction away from the raw Event line is rejected.'
reset_tree
replace_once "$config" \
  $'\t\treplace    = "[REDACTED]"' \
  $'\t\treplace    = "[REDACTED]"\n\t\tsource     = "event_type"'
expect_river_fail 'Event credential redaction source redirected' \
  'Refusing: Alloy Events credential redaction stage assignments drifted.'

echo '15. Adding forbidden labels at the Loki writer is rejected.'
reset_tree
replace_once "$config" \
  $'loki.write "default" {' \
  $'loki.write "default" {\n\texternal_labels = { event_name = "forbidden" }'
expect_river_fail 'Event writer external label added' \
  'Refusing: Alloy Loki delivery must not define direct assignments.'

echo '16. Adding a non-resource permission to Events-only RBAC is rejected.'
reset_tree
yq -i '.rbac.rules[0].nonResourceURLs = ["/metrics"]' "$values"
expect_monitoring_fail 'Alloy Events non-resource RBAC added' \
  'Refusing: Alloy Events source RBAC rules must not contain non-resource permissions or unexpected fields.'

echo '17. A weak unsupported-Event-type filter is rejected at its exact boundary.'
reset_tree
replace_once "$config" \
	$'\t\tselector            = `{event_type!~"^(Normal|Warning)$"}`' \
	$'\t\tselector            = `{event_type=~".+"}`'
expect_river_fail 'Alloy Events unsupported-type filter weakened' \
  'Refusing: Alloy Events must drop every event_type other than Normal or Warning before delivery.'

echo '18. Expanding the Warning Events dashboard query is rejected.'
reset_tree
yq -o=json -i '(.panels[] | select(.title == "Recent Kubernetes Warning Events") | .targets[0].expr) = "{source=\"kubernetes_event\",event_type=~\"Warning|Error|Normal\"}"' "$dashboard"
expect_dashboard_fail 'Kubernetes Event dashboard query expanded' \
  'Recent Kubernetes Warning Events: query must select Warning only'

echo 'Alloy Events validator mutation tests passed.'
