#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/results.sh

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
fragment_root="${TEST_RESULT_FRAGMENT_DIR:-}"
shell_case_index=0

run_shell_case() {
  local case_name="$1"
  shift
  local exit_code result
  if [[ -z "$fragment_root" ]]; then
    "$@"
    return
  fi
  set +e
  "$@"
  exit_code="$?"
  set -e
  result='passed'
  [[ "$exit_code" -eq 0 ]] || result='failed'
  shell_case_index=$((shell_case_index + 1))
  write_result_case_junit \
    "$fragment_root/bash-${shell_case_index}.xml" \
    validation.test-harness \
    "$case_name" \
    "$result" \
    0
  return "$exit_code"
}

# Keep this validation contract cluster-independent even on an operator workstation.
export KUBECONFIG="$repo_root/tests/.offline-validation-no-kubeconfig"
unset SOPS_AGE_KEY SOPS_AGE_KEY_FILE

scripts/test/validate-catalog.sh
chainsaw lint configuration --file tests/config/chainsaw.yaml
set +e
conftest test --all-namespaces \
  --policy tests/policy/chainsaw \
  tests/config/chainsaw.yaml tests/chainsaw/smoke
conftest_exit_code="$?"
set -e
if [[ -n "$fragment_root" ]]; then
  set +e
  conftest test --all-namespaces \
    --policy tests/policy/chainsaw \
    --output junit \
    tests/config/chainsaw.yaml tests/chainsaw/smoke \
    >"$fragment_root/conftest-chainsaw.xml"
  conftest_report_exit_code="$?"
  set -e
  [[ "$conftest_report_exit_code" -eq "$conftest_exit_code" ]] || {
    echo 'Conftest console and JUnit executions disagreed.' >&2
    exit 2
  }
fi
[[ "$conftest_exit_code" -eq 0 ]] || exit "$conftest_exit_code"

test_count=0
while IFS= read -r test_file; do
  chainsaw lint test --file "$test_file"
  test_count=$((test_count + 1))
done < <(
  find tests/chainsaw tests/fixtures/chainsaw -type f \
    \( -name 'chainsaw-test.yaml' -o -name 'chainsaw-test.yml' \) \
    -print | LC_ALL=C sort
)

yaml_count=0
while IFS= read -r yaml_file; do
  yq eval-all 'true' "$yaml_file" >/dev/null
  yaml_count=$((yaml_count + 1))
done < <(
  find tests/chainsaw tests/fixtures/chainsaw -type f \
    \( -name '*.yaml' -o -name '*.yml' \) \
    -print | LC_ALL=C sort
)

script_count=0
declare -a shell_scripts=()
while IFS= read -r script_file; do
  bash -n "$script_file"
  shell_scripts+=("$script_file")
  script_count=$((script_count + 1))
done < <(find scripts/test tests/probes -type f -name '*.sh' -print | LC_ALL=C sort)

shellcheck_exit_code=0
for script_file in "${shell_scripts[@]}"; do
  shellcheck --external-sources "$script_file" || shellcheck_exit_code="$?"
done
if [[ -n "$fragment_root" ]]; then
  set +e
  shellcheck --external-sources --format=json "${shell_scripts[@]}" \
    >"$fragment_root/shellcheck.json"
  shellcheck_json_exit_code="$?"
  uv run --locked python scripts/test/junit_tools.py shellcheck \
    --output "$fragment_root/shellcheck.xml" \
    --suite validation.test-harness.shellcheck \
    --findings "$fragment_root/shellcheck.json" \
    "${shell_scripts[@]}"
  shellcheck_adapter_exit_code="$?"
  set -e
  [[ "$shellcheck_json_exit_code" -eq "$shellcheck_adapter_exit_code" ]] || {
    echo 'ShellCheck JSON and JUnit adapter outcomes disagreed.' >&2
    exit 2
  }
fi
[[ "$shellcheck_exit_code" -eq 0 ]] || exit "$shellcheck_exit_code"

run_shell_case chaos-confirmation \
  scripts/test/safety/require-chaos-confirmation-test.sh
run_shell_case e2e-confirmation \
  scripts/test/safety/require-e2e-confirmation-test.sh
run_shell_case common-library scripts/test/lib/common-test.sh
run_shell_case result-contract scripts/test/lib/results-test.sh
run_shell_case catalog-negative scripts/test/validate-catalog-test.sh
run_shell_case chainsaw-dispatch scripts/test/run-chainsaw-dispatch-test.sh
run_shell_case media-hardlink scripts/test/scenarios/media-hardlink-test.sh
run_shell_case probe-dispatch scripts/test/run-probe-dispatch-test.sh
run_shell_case lease scripts/test/lease-test.sh
run_shell_case catalog-suite-runner scripts/test/run-catalog-suite-test.sh
run_shell_case ci-runner scripts/test/run-ci-test.sh
run_shell_case sonobuoy-runner scripts/test/run-sonobuoy-test.sh
run_shell_case allure-report scripts/test/allure-report-test.sh
run_shell_case report-publish-install scripts/test/report-publish-install-test.sh
run_shell_case report-publish-guard scripts/test/report-publish-guard-test.sh
run_shell_case qbit-manage-policy-shellcheck \
  shellcheck scripts/validate/qbit-manage-policy.sh
run_shell_case qbit-manage-policy-validator \
  scripts/test/qbit-manage-policy-validator-test.sh
run_shell_case qbittorrent-probe tests/probes/qbittorrent/probe-test.sh
run_shell_case dns-isolation tests/probes/dns/isolation-test.sh

# Offline Python unit tests for host-side E2E logic and probe analyzers. uv (pinned via
# mise) provides the locked interpreter/dependencies; these modules are pure or mocked,
# so this needs no cluster. Discover per directory so tests can import sibling modules.
py_test_dirs=0
while IFS= read -r py_test_dir; do
  if [[ -n "$fragment_root" ]]; then
    safe_dir="${py_test_dir//\//-}"
    uv run --locked python scripts/test/junit_tools.py unittest \
      --output "$fragment_root/python-${safe_dir}.xml" \
      --suite "validation.test-harness.${safe_dir}" \
      --start-directory "$py_test_dir" \
      --pattern 'test_*.py'
  else
    uv run --locked python -m unittest discover -s "$py_test_dir" -p 'test_*.py'
  fi
  py_test_dirs=$((py_test_dirs + 1))
done < <(
  find scripts/test/scenarios tests/probes -type f -name 'test_*.py' \
    -exec dirname {} \; | LC_ALL=C sort -u
)
if [[ -n "$fragment_root" ]]; then
  uv run --locked python scripts/test/junit_tools.py unittest \
    --output "$fragment_root/python-test-tools.xml" \
    --suite validation.test-harness.python-tools \
    --start-directory scripts/test \
    --pattern 'test_*.py'
else
  uv run --locked python -m unittest discover -s scripts/test -p 'test_*.py'
fi
uv run --locked ruff check \
  scripts/test/allure_report.py \
  scripts/test/test_allure_report.py \
  scripts/test/report_publish.py \
  scripts/test/test_report_publish.py \
  scripts/test/junit_report.py \
  scripts/test/junit_tools.py \
  scripts/test/test_junit_tools.py \
  scripts/test/helpers/qbit_manage_policy_api.py \
  scripts/test/scenarios/resilience_support.py \
  scripts/test/scenarios/plex_cross_node_reschedule.py \
  scripts/test/scenarios/qbittorrent_pod_recreation.py \
  scripts/test/scenarios/qbittorrent_vpn_disconnect.py \
  scripts/test/scenarios/test_reports_persistence.py \
  scripts/test/scenarios/qbit_manage_policy_config.py \
  scripts/test/scenarios/qbit_manage_policy.py \
  scripts/test/scenarios/test_qbit_manage_policy.py \
  scripts/test/scenarios/test_resilience_controllers.py
uv run --locked ruff format --check \
  scripts/test/allure_report.py \
  scripts/test/test_allure_report.py \
  scripts/test/report_publish.py \
  scripts/test/test_report_publish.py \
  scripts/test/junit_report.py \
  scripts/test/junit_tools.py \
  scripts/test/test_junit_tools.py \
  scripts/test/helpers/qbit_manage_policy_api.py \
  scripts/test/scenarios/resilience_support.py \
  scripts/test/scenarios/plex_cross_node_reschedule.py \
  scripts/test/scenarios/qbittorrent_pod_recreation.py \
  scripts/test/scenarios/qbittorrent_vpn_disconnect.py \
  scripts/test/scenarios/test_reports_persistence.py \
  scripts/test/scenarios/qbit_manage_policy_config.py \
  scripts/test/scenarios/qbit_manage_policy.py \
  scripts/test/scenarios/test_qbit_manage_policy.py \
  scripts/test/scenarios/test_resilience_controllers.py

printf 'Chainsaw offline validation passed: configurations=1 tests=%d yaml_files=%d shell_scripts=%d python_test_dirs=%d.\n' \
  "$test_count" "$yaml_count" "$script_count" "$py_test_dirs"
