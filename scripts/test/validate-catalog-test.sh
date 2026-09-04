#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

uv run --locked --no-dev python scripts/test/catalog_compatibility.py
scripts/test/validate-harness-shell-consumer-test.sh
scripts/test/validate-harness-groups-test.sh

[[ "$(yq -r '.suites[] | select(.metadata.id == "validation.repo-validate") | .native_results.strategy' tests/catalog.yaml)" == native-junit ]]

assert_execution() {
	local execution="$1" expected="$2" actual
	actual="$(yq -r ".executions[\"$execution\"][]" tests/catalog.yaml)"
	[[ "$actual" == "$expected" ]] || {
		echo "Execution $execution has unexpected members." >&2
		exit 1
	}
}

assert_harness_field() {
	local suite_id="$1" field="$2" expected="$3" actual
	local -x SUITE_ID="$suite_id"
	actual="$(yq -r '.suites[] | select(.metadata.id == env(SUITE_ID)) | '"$field" tests/catalog.yaml)"
	[[ "$actual" == "$expected" ]]
}

assert_execution ci-core $'validation.repo-lint\nvalidation.repo-validate\nvalidation.links\nvalidation.test-harness-core\nvalidation.policy-unit\nvalidation.kubeconform\nvalidation.cilium\nvalidation.metrics-server\nvalidation.flux\nvalidation.foundation\nvalidation.storage\nvalidation.csi-driver-smb\nvalidation.media-storage\nvalidation.plex\nvalidation.intel-gpu-plugin\nvalidation.qbittorrent\nvalidation.arr\nvalidation.qbit-manage\nvalidation.seerr\nvalidation.tautulli\nvalidation.media-alerts\nvalidation.security-alerts\nvalidation.flaresolverr\nvalidation.media-policy\nvalidation.portainer\nvalidation.portainer-policy\nvalidation.homepage\nvalidation.trivy\nvalidation.tailscale-operator\nvalidation.tailscale-subnet-router\nvalidation.networking-alerts\nvalidation.alerts-coverage'
assert_execution ci-observability $'validation.test-harness-observability\nvalidation.monitoring-alerts\nvalidation.monitoring\nvalidation.gatus\nvalidation.test-reports\nvalidation.ntfy\nvalidation.alertmanager-ntfy'
assert_execution ci-automation $'validation.test-harness-automation\nvalidation.n8n\nvalidation.automation-data'
assert_execution ci-framework $'validation.test-harness-ci-framework'

ci_group_members="$(yq -r '.executions["ci-core"][], .executions["ci-observability"][], .executions["ci-automation"][], .executions["ci-framework"][]' tests/catalog.yaml)"
[[ -z "$(printf '%s\n' "$ci_group_members" | LC_ALL=C sort | uniq -d)" ]] || {
	echo 'CI group executions contain duplicate suite IDs.' >&2
	exit 1
}
[[ "$(printf '%s\n' "$ci_group_members" | LC_ALL=C sort)" == "$(yq -r '.executions.ci[]' tests/catalog.yaml | LC_ALL=C sort)" ]] || {
	echo 'CI group executions are not the exact full CI partition.' >&2
	exit 1
}

for group in core observability automation ci-framework; do
	suite_id="validation.test-harness-$group"
	assert_harness_field "$suite_id" .runner.command "mise exec -- just test validate $group"
	assert_harness_field "$suite_id" .runner.implementation scripts/test/validate-chainsaw.sh
	assert_harness_field "$suite_id" .native_results.strategy native-junit
done

if rg -n 'bash -n.*\$|find scripts/secrets scripts/test tests/probes' \
	scripts/test/validate-chainsaw.sh; then
	echo 'Harness must not rerun canonical Bash validation.' >&2
	exit 1
fi
if rg -n 'shellcheck.*--format=json|while .*shellcheck' \
	scripts/test/validate-chainsaw.sh; then
	echo 'Harness must not rerun canonical ShellCheck validation.' >&2
	exit 1
fi
if rg -n 'qbit-manage-policy-shellcheck' \
	scripts/test/validate-chainsaw.sh tests/catalog.yaml; then
	echo 'Focused qbit ShellCheck must remain owned by repository validation.' >&2
	exit 1
fi
git ls-files -co --exclude-standard -- scripts/validate |
	rg -qx 'scripts/validate/qbit-manage-policy.sh'
