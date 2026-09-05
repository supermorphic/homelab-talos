#!/usr/bin/env bash
set -euo pipefail

mode=run
group="${1:-all}"
if [[ "$group" == --list ]]; then
	mode=list
	group="${2:-}"
	[[ "$#" -eq 2 ]] || exit 2
else
	[[ "$#" -le 1 ]] || exit 2
fi
case "$group" in
all | core | observability | automation | ci-framework) ;;
*)
	echo "Unknown test harness group: ${group:-<empty>}" >&2
	exit 2
	;;
esac

suite_id=validation.test-harness
[[ "$group" == all ]] || suite_id="validation.test-harness-$group"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

group_selected() { [[ "$group" == all || "$group" == "$1" ]]; }

epoch_milliseconds() {
	local now seconds fraction
	now="$EPOCHREALTIME"
	seconds="${now%%.*}"
	fraction="${now#*.}000"
	printf '%s\n' "$((10#$seconds * 1000 + 10#${fraction:0:3}))"
}

run_shell_case() {
	local case_name="$1"
	shift
	local exit_code result case_started_ms case_duration_ms case_duration
	if [[ -z "$fragment_root" ]]; then
		shell_case_index=$((shell_case_index + 1))
		"$@"
		return
	fi
	case_started_ms="$(epoch_milliseconds)"
	set +e
	"$@"
	exit_code="$?"
	set -e
	case_duration_ms=$(( $(epoch_milliseconds) - case_started_ms ))
	printf -v case_duration '%d.%03d' \
		"$((case_duration_ms / 1000))" "$((case_duration_ms % 1000))"
	result=passed
	[[ "$exit_code" -eq 0 ]] || result=failed
	shell_case_index=$((shell_case_index + 1))
	write_result_case_junit \
		"$fragment_root/bash-${shell_case_index}.xml" \
		"$suite_id" "$case_name" "$result" "$case_duration"
	return "$exit_code"
}

list_setup() {
	local owner="$1" setup_name="$2"
	group_selected "$owner" || return 0
	[[ "$mode" != list ]] || printf 'setup:%s\n' "$setup_name"
}

run_group_shell_case() {
	local owner="$1" case_name="$2"
	shift 2
	group_selected "$owner" || return 0
	if [[ "$mode" == list ]]; then
		printf 'shell:%s\n' "$case_name"
		return
	fi
	run_shell_case "$case_name" "$@"
}

register_group_shell_case() {
	local owner="$1" case_name="$2"
	shift 2
	group_selected "$owner" || return 0
	if [[ "$mode" == list ]]; then
		printf 'shell:%s\n' "$case_name"
		return
	fi
	register_harness_shell_case "$case_name" "$@"
}

if [[ "$mode" == run ]]; then
	source scripts/test/lib/results.sh
	source scripts/test/lib/chainsaw-inputs.sh
	source scripts/test/lib/harness-shell-runner.sh
	fragment_root="${TEST_RESULT_FRAGMENT_DIR:-}"
	shell_case_index=0
	test_harness_jobs="${TEST_HARNESS_JOBS-4}"
	validate_harness_shell_jobs "$test_harness_jobs"

	# Keep this validation contract cluster-independent even on an operator workstation.
	export KUBECONFIG="$repo_root/tests/.offline-validation-no-kubeconfig"
	unset SOPS_AGE_KEY SOPS_AGE_KEY_FILE
fi

list_setup ci-framework catalog
if [[ "$mode" == run ]] && group_selected ci-framework; then
	scripts/test/validate-catalog.sh
fi
list_setup ci-framework chainsaw-configuration
if [[ "$mode" == run ]] && group_selected ci-framework; then
	chainsaw lint configuration --file tests/config/chainsaw.yaml
fi
list_setup ci-framework chainsaw-conftest
if [[ "$mode" == run ]] && group_selected ci-framework; then
	scripts/test/run-native-junit-validator.sh \
		--suite "$suite_id" --fragment conftest-chainsaw.xml \
		--label Chainsaw -- conftest test --all-namespaces \
		--policy tests/policy/chainsaw --output junit \
		tests/config/chainsaw.yaml tests/chainsaw/smoke
fi
list_setup ci-framework chainsaw-test-files
if [[ "$mode" == run ]] && group_selected ci-framework; then
	test_count=0
	test_files="$(chainsaw_test_files "$repo_root")"
	if [[ -n "$test_files" ]]; then
		while IFS= read -r test_file; do
			chainsaw lint test --file "$test_file"
			test_count=$((test_count + 1))
		done <<<"$test_files"
	fi
fi
list_setup ci-framework chainsaw-yaml-support-files
if [[ "$mode" == run ]] && group_selected ci-framework; then
	yaml_count=0
	support_files="$(chainsaw_yaml_support_files "$repo_root")"
	if [[ -n "$support_files" ]]; then
		while IFS= read -r yaml_file; do
			yq eval-all 'true' "$yaml_file" >/dev/null
			yaml_count=$((yaml_count + 1))
		done <<<"$support_files"
	fi
fi
list_setup core repository-shell-validation
if [[ "$mode" == run ]] && group_selected core; then
	consume_args=(consume --suite "$suite_id")
	[[ -n "${TEST_SHARED_RESULT_DIR:-}" ]] &&
		consume_args+=(--artifact "$TEST_SHARED_RESULT_DIR/repository-shell-validation.json")
	[[ -n "${TEST_RUN_ID:-}" ]] && consume_args+=(--run-id "$TEST_RUN_ID")
	[[ -n "$fragment_root" ]] &&
		consume_args+=(--junit "$fragment_root/repository-shell-validation.xml")
	python scripts/test/repository_shell_validation.py "${consume_args[@]}"
fi

run_group_shell_case ci-framework chaos-confirmation scripts/test/safety/require-chaos-confirmation-test.sh
run_group_shell_case ci-framework e2e-confirmation scripts/test/safety/require-e2e-confirmation-test.sh
run_group_shell_case ci-framework common-library scripts/test/lib/common-test.sh
run_group_shell_case ci-framework result-contract scripts/test/lib/results-test.sh
run_group_shell_case ci-framework chainsaw-inputs scripts/test/lib/chainsaw-inputs-test.sh
run_group_shell_case ci-framework harness-case-timing scripts/test/validate-chainsaw-timing-test.sh
run_group_shell_case ci-framework harness-shell-runner scripts/test/lib/harness-shell-runner-test.sh
run_group_shell_case ci-framework native-junit-validator scripts/test/run-native-junit-validator-test.sh
run_group_shell_case ci-framework catalog-negative scripts/test/validate-catalog-test.sh
register_group_shell_case observability flux-alerts-diagnostics scripts/test/flux-alerts-diagnostics-test.sh
register_group_shell_case observability flux-alert-delivery scripts/test/flux-alert-delivery-test.sh
register_group_shell_case core tailscale-routes scripts/test/tailscale-routes-test.sh
register_group_shell_case ci-framework chainsaw-dispatch scripts/test/run-chainsaw-dispatch-test.sh
register_group_shell_case core media-hardlink scripts/test/scenarios/media-hardlink-test.sh
register_group_shell_case ci-framework probe-dispatch scripts/test/run-probe-dispatch-test.sh
register_group_shell_case ci-framework lease scripts/test/lease-test.sh
register_group_shell_case core node-lifecycle scripts/test/node-lifecycle-test.sh
register_group_shell_case core cluster-commands scripts/test/cluster-commands-test.sh
register_group_shell_case ci-framework catalog-suite-runner scripts/test/run-catalog-suite-test.sh
register_group_shell_case ci-framework ci-runner scripts/test/run-ci-test.sh
register_group_shell_case ci-framework campaign-runner scripts/test/run-campaign-test.sh
register_group_shell_case core scoped-campaign-preflight scripts/test/scoped-campaign-preflight-test.sh
register_group_shell_case core agent-access-verifier scripts/test/agent-access-verify-test.sh
register_group_shell_case core tautulli-verifier scripts/test/tautulli-verify-test.sh
register_group_shell_case core metrics-server-verifier scripts/test/metrics-server-verify-test.sh
register_group_shell_case core cilium-verifier scripts/test/cilium-verify-test.sh
register_group_shell_case observability logging-verifier-topology-storage-runtime scripts/test/logging-verify-test.sh topology-storage-runtime
register_group_shell_case observability logging-verifier-labels scripts/test/logging-verify-test.sh labels
register_group_shell_case observability logging-verifier-counts-compaction scripts/test/logging-verify-test.sh counts-compaction
register_group_shell_case observability logging-verifier-prometheus-targets scripts/test/logging-verify-test.sh prometheus-targets
register_group_shell_case core cilium-validator scripts/test/cilium-validator-test.sh
register_group_shell_case automation n8n-secrets scripts/test/n8n-secrets-test.sh
register_group_shell_case automation n8n-backup scripts/test/n8n-backup-test.sh
register_group_shell_case automation n8n-persistence-query scripts/test/n8n-persistence-query-test.sh
register_group_shell_case observability monitoring-fixtures scripts/test/lib/monitoring-fixtures-test.sh
register_group_shell_case observability monitoring-alloy-logs-validator scripts/test/monitoring-alloy-logs-validator-test.sh
register_group_shell_case observability monitoring-loki-validator scripts/test/monitoring-loki-validator-test.sh
register_group_shell_case observability monitoring-alloy-events-validator scripts/test/monitoring-alloy-events-validator-test.sh
register_group_shell_case observability grafana-admin-reset scripts/test/grafana-admin-reset-test.sh
register_group_shell_case core bootstrap-recovery scripts/test/bootstrap-recovery-test.sh
register_group_shell_case core talos-apply-live scripts/test/talos-apply-live-test.sh
register_group_shell_case core portainer-rbac-verifier scripts/test/portainer-rbac-verify-test.sh
register_group_shell_case observability alertmanager-ntfy-verifier scripts/test/alertmanager-ntfy-verify-test.sh
register_group_shell_case observability ntfy-publish scripts/test/ntfy-publish-test.sh
register_group_shell_case core security-alerts-verifier scripts/test/security-alerts-verify-test.sh
register_group_shell_case core plex-verifier scripts/test/plex-verify-test.sh
register_group_shell_case core plex-validator scripts/test/plex-validator-test.sh
register_group_shell_case core sonobuoy-runner scripts/test/run-sonobuoy-test.sh
register_group_shell_case ci-framework allure-report scripts/test/allure-report-test.sh
register_group_shell_case ci-framework report-publish-install scripts/test/report-publish-install-test.sh
register_group_shell_case ci-framework report-publish-guard scripts/test/report-publish-guard-test.sh
register_group_shell_case core qbit-manage-policy-validator scripts/test/qbit-manage-policy-validator-test.sh
register_group_shell_case core arr-validator scripts/test/arr-validator-test.sh
register_group_shell_case observability gatus-validator scripts/test/gatus-validator-test.sh
register_group_shell_case observability monitoring-alerts-validator scripts/test/monitoring-alerts-validator-test.sh
register_group_shell_case core gatus-media-integration-secrets scripts/test/gatus-media-integration-secrets-test.sh
register_group_shell_case core qbittorrent-probe tests/probes/qbittorrent/probe-test.sh
register_group_shell_case core dns-isolation tests/probes/dns/isolation-test.sh
register_group_shell_case observability ntfy-identity scripts/test/ntfy-identity-test.sh
register_group_shell_case observability ntfy-consumer-sync scripts/test/ntfy-consumer-sync-test.sh

if [[ "$mode" == list ]]; then
	group_selected core && printf 'python:scripts/test/scenarios\npython:tests/probes\n'
	group_selected ci-framework && printf 'python:scripts/test\n'
	group_selected core && printf 'ruff:check\nruff:format\n'
	exit 0
fi

run_registered_harness_shell_cases \
	"$fragment_root" "$test_harness_jobs" "$shell_case_index" "$suite_id"
shell_case_index=$((shell_case_index + ${#HARNESS_SHELL_CASE_NAMES[@]}))
printf 'Harness shell cases passed: cases=%d parallel_jobs=%d.\n' \
	"$shell_case_index" "$test_harness_jobs"

py_test_dirs=0
if group_selected core; then
	while IFS= read -r py_test_dir; do
		if [[ -n "$fragment_root" ]]; then
			safe_dir="${py_test_dir//\//-}"
			uv run --locked python scripts/test/junit_tools.py unittest \
				--output "$fragment_root/python-${safe_dir}.xml" \
				--suite "$suite_id.${safe_dir}" --start-directory "$py_test_dir" \
				--pattern 'test_*.py'
		else
			uv run --locked python -m unittest discover -s "$py_test_dir" -p 'test_*.py'
		fi
		py_test_dirs=$((py_test_dirs + 1))
	done < <(find scripts/test/scenarios tests/probes -type f -name 'test_*.py' \
		-exec dirname {} \; | LC_ALL=C sort -u)
fi
if group_selected ci-framework; then
	if [[ -n "$fragment_root" ]]; then
		uv run --locked python scripts/test/junit_tools.py unittest \
			--output "$fragment_root/python-test-tools.xml" \
			--suite "$suite_id.python-tools" --start-directory scripts/test \
			--pattern 'test_*.py'
	else
		uv run --locked python -m unittest discover -s scripts/test -p 'test_*.py'
	fi
	py_test_dirs=$((py_test_dirs + 1))
fi
if group_selected core; then
	ruff_files=(
		scripts/repository/github_protection.py scripts/test/catalog_compatibility.py
		scripts/test/catalog_validator.py scripts/test/allure_report.py
		scripts/test/test_allure_report.py scripts/test/report_publish.py
		scripts/test/test_report_publish.py scripts/test/junit_report.py
		scripts/test/junit_tools.py scripts/test/test_junit_tools.py
		scripts/test/repository_shell_validation.py scripts/test/test_repository_shell_validation.py
		scripts/test/ci_plan.py scripts/test/test_ci_plan.py
		scripts/test/test_github_protection.py scripts/test/helpers/qbit_manage_policy_api.py
		scripts/test/scenarios/resilience_support.py scripts/test/scenarios/plex_cross_node_reschedule.py
		scripts/test/scenarios/qbittorrent_pod_recreation.py scripts/test/scenarios/qbittorrent_vpn_disconnect.py
		scripts/test/scenarios/tailscale_subnet_router_replica_recovery.py scripts/test/scenarios/test_reports_persistence.py
		scripts/test/scenarios/qbit_manage_policy_config.py scripts/test/scenarios/qbit_manage_policy.py
		scripts/test/scenarios/test_qbit_manage_policy.py scripts/test/scenarios/test_resilience_controllers.py
		scripts/test/scenarios/test_tailscale_subnet_router_replica_recovery.py
	)
	uv run --locked ruff check "${ruff_files[@]}"
	uv run --locked ruff format --check "${ruff_files[@]}"
fi

configuration_count=0
group_selected ci-framework && configuration_count=1
printf 'Chainsaw offline validation passed: configurations=%d tests=%d yaml_files=%d python_test_dirs=%d.\n' \
	"$configuration_count" "${test_count:-0}" "${yaml_count:-0}" "$py_test_dirs"
