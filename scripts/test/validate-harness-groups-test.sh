#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

list_work() {
	local group="$1"
	scripts/test/validate-chainsaw.sh --list "$group"
}

list_shell() {
	list_work "$1" | sed -n 's/^shell://p'
}

expect_lines() {
	local actual="$1" expected="$2"
	[[ "$actual" == "$expected" ]] || {
		echo 'Harness group inventory did not match its expected identities.' >&2
		diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
		exit 1
	}
}

core="$(list_shell core)"
expect_lines "$core" $'tailscale-routes\nmedia-hardlink\nnode-lifecycle\ncluster-commands\nscoped-campaign-preflight\nagent-access-verifier\ntautulli-verifier\nmetrics-server-verifier\ncilium-verifier\ncilium-validator\nbootstrap-recovery\ntalos-apply-live\nportainer-rbac-verifier\nsecurity-alerts-verifier\nplex-verifier\nplex-validator\nsonobuoy-runner\nqbit-manage-policy-validator\narr-validator\ngatus-media-integration-secrets\nqbittorrent-probe\ndns-isolation'
[[ "$(wc -l <<<"$core" | tr -d ' ')" -eq 22 ]]

observability="$(list_shell observability)"
automation="$(list_shell automation)"
ci_framework="$(list_shell ci-framework)"
all="$(list_shell all)"

expect_lines "$observability" $'flux-alerts-diagnostics\nflux-alert-delivery\nlogging-verifier-topology-storage-runtime\nlogging-verifier-labels\nlogging-verifier-counts-compaction\nlogging-verifier-prometheus-targets\nmonitoring-fixtures\nmonitoring-alloy-logs-validator\nmonitoring-loki-validator\nmonitoring-alloy-events-validator\ngrafana-admin-reset\nalertmanager-ntfy-verifier\nntfy-publish\ngatus-validator\nmonitoring-alerts-validator\nntfy-identity\nntfy-consumer-sync'
expect_lines "$automation" $'n8n-secrets\nn8n-backup\nn8n-persistence-query'
expect_lines "$ci_framework" $'chaos-confirmation\ne2e-confirmation\ncommon-library\nresult-contract\nchainsaw-inputs\nharness-case-timing\nharness-shell-runner\nnative-junit-validator\ncatalog-negative\nchainsaw-dispatch\nprobe-dispatch\nlease\ncatalog-suite-runner\nci-runner\nci-workflow-contract\ncampaign-runner\nallure-report\nreport-publish-install\nreport-publish-guard'
expect_lines "$all" $'chaos-confirmation\ne2e-confirmation\ncommon-library\nresult-contract\nchainsaw-inputs\nharness-case-timing\nharness-shell-runner\nnative-junit-validator\ncatalog-negative\nflux-alerts-diagnostics\nflux-alert-delivery\ntailscale-routes\nchainsaw-dispatch\nmedia-hardlink\nprobe-dispatch\nlease\nnode-lifecycle\ncluster-commands\ncatalog-suite-runner\nci-runner\nci-workflow-contract\ncampaign-runner\nscoped-campaign-preflight\nagent-access-verifier\ntautulli-verifier\nmetrics-server-verifier\ncilium-verifier\nlogging-verifier-topology-storage-runtime\nlogging-verifier-labels\nlogging-verifier-counts-compaction\nlogging-verifier-prometheus-targets\ncilium-validator\nn8n-secrets\nn8n-backup\nn8n-persistence-query\nmonitoring-fixtures\nmonitoring-alloy-logs-validator\nmonitoring-loki-validator\nmonitoring-alloy-events-validator\ngrafana-admin-reset\nbootstrap-recovery\ntalos-apply-live\nportainer-rbac-verifier\nalertmanager-ntfy-verifier\nntfy-publish\nsecurity-alerts-verifier\nplex-verifier\nplex-validator\nsonobuoy-runner\nallure-report\nreport-publish-install\nreport-publish-guard\nqbit-manage-policy-validator\narr-validator\ngatus-validator\nmonitoring-alerts-validator\ngatus-media-integration-secrets\nqbittorrent-probe\ndns-isolation\nntfy-identity\nntfy-consumer-sync'

[[ "$(wc -l <<<"$observability" | tr -d ' ')" -eq 17 ]]
[[ "$(wc -l <<<"$automation" | tr -d ' ')" -eq 3 ]]
[[ "$(wc -l <<<"$ci_framework" | tr -d ' ')" -eq 19 ]]
[[ "$(wc -l <<<"$all" | tr -d ' ')" -eq 61 ]]
[[ -z "$(printf '%s\n' "$core" "$observability" "$automation" "$ci_framework" |
	LC_ALL=C sort | uniq -d)" ]]

core_work="$(list_work core)"
observability_work="$(list_work observability)"
automation_work="$(list_work automation)"
ci_framework_work="$(list_work ci-framework)"
all_work="$(list_work all)"

[[ "$(wc -l <<<"$all_work" | tr -d ' ')" -eq 72 ]]
expect_lines "$(printf '%s\n' "$all_work" | sed -n '1,6p')" \
	$'setup:catalog\nsetup:chainsaw-configuration\nsetup:chainsaw-conftest\nsetup:chainsaw-test-files\nsetup:chainsaw-yaml-support-files\nsetup:repository-shell-validation'
expect_lines "$(printf '%s\n' "$all_work" | tail -n 5)" \
	$'python:scripts/test/scenarios\npython:tests/probes\npython:scripts/test\nruff:check\nruff:format'
expect_lines "$(printf '%s\n' "$ci_framework_work" | sed -n 's/^python://p')" \
	'scripts/test'
expect_lines "$(printf '%s\n' "$core_work" | sed -n 's/^python://p')" \
	$'scripts/test/scenarios\ntests/probes'
[[ -z "$(printf '%s\n' "$observability_work" "$automation_work" | sed -n 's/^python://p')" ]]
expect_lines "$(printf '%s\n' "$core_work" | sed -n 's/^ruff://p')" \
	$'check\nformat'
[[ -z "$(printf '%s\n' "$observability_work" "$automation_work" "$ci_framework_work" |
	sed -n 's/^ruff://p')" ]]

[[ -z "$(printf '%s\n' "$core_work" "$observability_work" "$automation_work" \
	"$ci_framework_work" | LC_ALL=C sort | uniq -d)" ]]
[[ "$(printf '%s\n' "$all_work" | LC_ALL=C sort)" == \
	"$(printf '%s\n' "$core_work" "$observability_work" "$automation_work" "$ci_framework_work" |
		LC_ALL=C sort)" ]]

# The explicit Ruff list prevents a new Python test from silently losing ongoing style checks.
rg -q '^\s*scripts/test/test_repository_secret_scan\.py([[:space:]]|$)' \
	scripts/test/validate-chainsaw.sh

set +e
invalid_output="$(scripts/test/validate-chainsaw.sh --list invalid 2>&1)"
invalid_status="$?"
set -e
[[ "$invalid_status" -eq 2 ]]
[[ "$invalid_output" == 'Unknown test harness group: invalid' ]]

echo 'Harness group inventory tests passed.'
