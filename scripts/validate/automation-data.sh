#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail() {
  echo "automation-data validation failed: $*" >&2
  exit 1
}

operations_guide='docs/guides/automation-data-operations.md'
recovery_runbook='docs/runbooks/automation-data-recovery.md'
for required_document in "$operations_guide" "$recovery_runbook"; do
  [[ -f "$required_document" ]] || fail "required operations document is missing: $required_document"
done
just --dry-run bootstrap automation-data >/dev/null 2>&1 ||
  fail 'the guarded automation-data bootstrap recipe is missing'

# These focused tests are the only merge-gate owners of the issue-specific behavior.
# Repository-wide lint, schema, policy, SOPS, gitleaks, and Prometheus checks remain in
# their existing suites and are intentionally not repeated here.
scripts/test/automation-data-secrets-test.sh
scripts/test/automation-data-control-contract-test.sh
scripts/test/automation-data-workflow-contract-test.sh
scripts/test/automation-data-provisioning-command-test.sh
scripts/test/automation-data-exporter-grant-test.sh
scripts/test/automation-data-backup-test.sh
scripts/test/automation-data-restore-command-test.sh
scripts/test/automation-data-longhorn-health-test.sh

[[ "$(yq -r '[.resources[] | select(. == "./automation-data")] | length' \
  kubernetes/apps/kustomization.yaml)" == 1 ]] ||
  fail 'the root applications graph must select automation-data exactly once'

platform_graph="$(yq -r '[.resources[]] | sort | join(",")' \
  kubernetes/apps/automation-data/kustomization.yaml)"
[[ "$platform_graph" == './namespace/ks.yaml,./postgresql/ks.yaml' ]] ||
  fail 'the automation-data Flux package graph is incomplete'
[[ "$(yq -r '.spec.suspend' kubernetes/apps/automation-data/postgresql/ks.yaml)" == false ]] ||
  fail 'the accepted automation-data PostgreSQL package must remain active'

exporter='kubernetes/apps/automation-data/postgresql/app/sql-exporter.yml'
mapfile -t metrics < <(
  yq -r '.collectors[].metrics[].metric_name' "$exporter" | LC_ALL=C sort
)
expected_metrics=(
  automation_data_postgresql_backup_last_success_timestamp_seconds
  automation_data_postgresql_connections
  automation_data_postgresql_database_size_bytes
  automation_data_postgresql_oldest_incomplete_provisioning_age_seconds
  automation_data_postgresql_registry_catalog_consistent
  automation_data_postgresql_transactions_total
)
[[ "${metrics[*]}" == "${expected_metrics[*]}" ]] ||
  fail 'SQL Exporter must expose only the four baseline and two platform-health metrics'

dynamic_metrics="$(yq -r '
  [.collectors[].metrics[] |
    select(.metric_name | test("registry_catalog|oldest_incomplete")) |
    .metric_name] | sort | join(",")
' "$exporter")"
[[ "$dynamic_metrics" == \
  'automation_data_postgresql_oldest_incomplete_provisioning_age_seconds,automation_data_postgresql_registry_catalog_consistent' ]] ||
  fail 'SQL Exporter does not contain exactly the two approved dynamic-platform signals'

database_label_contract="$(yq -o=json -I=0 '
  [.collectors[].metrics[] |
    select(.metric_name == "automation_data_postgresql_connections" or
      .metric_name == "automation_data_postgresql_transactions_total" or
      .metric_name == "automation_data_postgresql_database_size_bytes") |
    {"metric": .metric_name, "labels": .key_labels}] | sort_by(.metric)
' "$exporter")"
[[ "$database_label_contract" == \
  '[{"metric":"automation_data_postgresql_connections","labels":["database","state"]},{"metric":"automation_data_postgresql_database_size_bytes","labels":["database"]},{"metric":"automation_data_postgresql_transactions_total","labels":["database","result"]}]' ]] ||
  fail 'database-scoped baseline metrics must retain the database label'

! rg -qi 'domain_count|bundle_count|connection_pressure' "$exporter" ||
  fail 'SQL Exporter contains an unapproved speculative metric'

dashboard='kubernetes/apps/monitoring/kube-prometheus-stack/config/dashboards/automation-data-postgresql.json'
[[ "$(yq -r '[.configMapGenerator[] |
    select(.name == "automation-data-postgresql-dashboard") | .files[] |
    select(. == "dashboards/automation-data-postgresql.json")] | length' \
    kubernetes/apps/monitoring/kube-prometheus-stack/config/kustomization.yaml)" == 1 ]] ||
  fail 'the automation-data Grafana dashboard must be packaged exactly once'
jq -e --argjson expected 13 '
  .uid == "automation-data-postgresql" and
  (.panels | length) == $expected and
  ([.panels[] | select(.datasource != {"type":"prometheus","uid":"${datasource}"})] | length) == 0
' "$dashboard" >/dev/null || fail 'the automation-data dashboard contract is incomplete'
for metric in "${metrics[@]}"; do
  rg -Fq "$metric" "$dashboard" || fail "dashboard does not use $metric"
done

[[ "$(yq -r '[.resources[] | select(. == "./automation-data.yaml")] | length' \
  kubernetes/apps/monitoring/alerts/app/kustomization.yaml)" == 1 ]] ||
  fail 'the automation-data PrometheusRule must be selected exactly once'

just --dry-run kube automation-data-verify >/dev/null 2>&1 ||
  fail 'the read-only automation-data verification recipe is missing'
just --dry-run kube automation-data-provisioning-test >/dev/null 2>&1 ||
  fail 'the attended automation-data provisioning recipe is missing'
just --dry-run kube automation-data-restore-drill >/dev/null 2>&1 ||
  fail 'the attended automation-data restore drill recipe is missing'

catalog='tests/catalog.yaml'
verification_contract="$(yq -o=json -I=0 '
  .suites[] | select(.metadata.id == "verification.automation-data") |
  {
    "mutates": .metadata.mutates_cluster,
    "owner": .metadata.execution_owner,
    "access": .access.tier,
    "confirmation": .confirmation.type,
    "command": .runner.command,
    "implementation": .runner.implementation
  }
' "$catalog")"
[[ "$verification_contract" == \
  '{"mutates":false,"owner":"human","access":"observer","confirmation":"none","command":"mise exec -- just kube automation-data-verify","implementation":"scripts/verify/automation-data.sh"}' ]] ||
  fail 'the read-only automation-data catalog contract is missing or unsafe'

provisioning_contract="$(yq -o=json -I=0 '
  .suites[] | select(.metadata.id == "test.automation-data-provisioning") |
  {
    "mutates": .metadata.mutates_cluster,
    "owner": .metadata.execution_owner,
    "confirmation": .confirmation,
    "command": .runner.command,
    "implementation": .runner.implementation,
    "dispatch": .dispatch
  }
' "$catalog")"
[[ "$provisioning_contract" == \
  '{"mutates":true,"owner":"human","confirmation":{"type":"exact","variable":"AUTOMATION_DATA_PROVISIONING_CONFIRM","expected":"test:automation-data:provisioning"},"command":"AUTOMATION_DATA_PROVISIONING_CONFIRM=test:automation-data:provisioning mise exec -- just kube automation-data-provisioning-test","implementation":"scripts/test/scenarios/automation-data-provisioning.sh","dispatch":{"mode":"direct","runtime":"bash","path":"scripts/test/scenarios/automation-data-provisioning.sh","args":[".kube/config"],"selector":null}}' ]] ||
  fail 'the attended automation-data provisioning catalog contract is missing or unsafe'

restore_contract="$(yq -o=json -I=0 '
  .suites[] | select(.metadata.id == "test.automation-data-restore-drill") |
  {
    "mutates": .metadata.mutates_cluster,
    "owner": .metadata.execution_owner,
    "confirmation": .confirmation,
    "command": .runner.command,
    "implementation": .runner.implementation,
    "dispatch": .dispatch
  }
' "$catalog")"
[[ "$restore_contract" == \
  '{"mutates":true,"owner":"human","confirmation":{"type":"exact","variable":"AUTOMATION_DATA_RESTORE_CONFIRM","expected":"restore:automation-data:full-chain"},"command":"AUTOMATION_DATA_RESTORE_CONFIRM=restore:automation-data:full-chain mise exec -- just kube automation-data-restore-drill","implementation":"scripts/test/scenarios/automation-data-restore-drill.sh","dispatch":{"mode":"direct","runtime":"bash","path":"scripts/test/scenarios/automation-data-restore-drill.sh","args":[".kube/config"],"selector":null}}' ]] ||
  fail 'the attended automation-data restore catalog contract is missing or unsafe'

verifier='scripts/verify/automation-data.sh'
scenario='scripts/test/scenarios/automation-data-provisioning.sh'
restore_scenario='scripts/test/scenarios/automation-data-restore-drill.sh'
restore_test='scripts/test/automation-data-restore-command-test.sh'
[[ -x "$verifier" && -x "$scenario" && -x "$restore_scenario" && -x "$restore_test" ]] ||
  fail 'automation-data live verification implementations must be executable'
! rg -n 'kubectl[^\n]*((get|describe)[[:space:]]+secrets?|exec|port-forward)|psql|/api/v1/credentials|/webhook/' \
  "$verifier" >/dev/null ||
  fail 'the read-only verifier crosses its observer-safe boundary'
for verifier_contract in \
  'automation-data-postgresql-data automation-data-postgresql-backups' \
  "'/api/v1/targets?state=active'" \
  "'/api/v1/rules?type=alert'" \
  'automation_data_postgresql_backup_last_success_timestamp_seconds' \
  'automation_data_postgresql_registry_catalog_consistent' \
  'automation_data_postgresql_oldest_incomplete_provisioning_age_seconds' \
  'get volumes.longhorn.io --output json'; do
  rg -Fq "$verifier_contract" "$verifier" ||
    fail "the read-only verifier omits $verifier_contract"
done

for scenario_contract in \
  "expected_confirmation='test:automation-data:provisioning'" \
  'X-Automation-Data-Provisioning' \
  "domain='issue317_acceptance'" \
  "error_domain='issue317_backup_error'" \
  'secretKeyRef' \
  'record_operation_error' \
  '--from=cronjob/automation-data-postgresql-backup' \
  'automation-data-postgresql-backups", "readOnly": true' \
  'backup_timestamp_after' \
  'credential_signature'; do
  rg -Fq -- "$scenario_contract" "$scenario" ||
    fail "the attended provisioning scenario omits $scenario_contract"
done
! rg -n 'echo[^\n]*(provisioning_token|PGPASSWORD)|printf[^\n]*PGPASSWORD|globals\.sql[^\n]*(cat|less|head|tail)' \
  "$scenario" >/dev/null ||
  fail 'the attended provisioning scenario can print a credential or globals dump'

for restore_contract_value in \
  "expected_confirmation='restore:automation-data:full-chain'" \
  'n8n_restore_job_command' \
  'automation_data_restore_job_command' \
  'automation-data-postgresql-backups' \
  'n8n-postgresql-backups' \
  'N8N_ENCRYPTION_KEY' \
  'automation-data-recovery-canary' \
  'restored_runtime_credential=authenticated' \
  'n8n_routes_target_service' \
  'storage": "20Gi"'; do
  rg -Fq -- "$restore_contract_value" "$restore_scenario" ||
    fail "the full-chain restore scenario omits $restore_contract_value"
done
! rg -n 'echo[^\n]*(PGPASSWORD|CANARY_TOKEN)|printf[^\n]*(PGPASSWORD|CANARY_TOKEN)|globals\.sql[^\n]*(cat|less|head|tail)' \
  "$restore_scenario" >/dev/null ||
  fail 'the full-chain restore scenario can print a credential or globals dump'

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-validate.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
sed -n '/^platform_manifests()/,/^}/p; /^policy_manifests()/,/^}/p; /^restore_job_manifest()/,/^}/p; /^n8n_application_manifests()/,/^}/p; /^request_job_manifest()/,/^}/p' \
  "$restore_scenario" >"$temp_dir/restore-functions.sh"
# shellcheck source=scripts/test/lib/n8n-restore-command.sh
source scripts/test/lib/n8n-restore-command.sh
# shellcheck source=scripts/test/lib/automation-data-restore-command.sh
source scripts/test/lib/automation-data-restore-command.sh
# shellcheck disable=SC1091 # generated from the bounded function definitions above.
source "$temp_dir/restore-functions.sh"
run_hash='123456789abc'
prefix="ad-restore-$run_hash"
ad_namespace='automation-data'
n8n_namespace='automation'
request_namespace='gatus'
ad_database="$prefix-db"
ad_service="$prefix-db"
ad_data_pvc="$prefix-ad-data"
n8n_database="$prefix-n8n-db"
n8n_service="$prefix-n8n-db"
n8n_data_pvc="$prefix-n8n-data"
n8n_app="$prefix-n8n"
ad_restore_job="$prefix-ad-load"
n8n_restore_job="$prefix-n8n-load"
request_job="$prefix-request"
ad_policy="$prefix-ad-policy"
n8n_policy="$prefix-n8n-policy"
request_policy="$prefix-request-policy"
backup_configmap='automation-data-postgresql-backup-bk2fk62b6h'
# The extracted manifest functions consume these globals. Exporting also makes that
# generated-source boundary explicit to ShellCheck's repository-wide batch.
export run_hash prefix ad_namespace n8n_namespace request_namespace ad_database \
  ad_service ad_data_pvc n8n_database n8n_service n8n_data_pvc n8n_app \
  ad_restore_job n8n_restore_job request_job ad_policy n8n_policy request_policy \
  backup_configmap
platform_manifests >"$temp_dir/platform.yaml"
policy_manifests >"$temp_dir/policies.yaml"
restore_job_manifest automation-data >"$temp_dir/automation-data-job.yaml"
restore_job_manifest n8n >"$temp_dir/n8n-job.yaml"
n8n_application_manifests '192.0.2.10' >"$temp_dir/n8n.yaml"
request_job_manifest >"$temp_dir/request.yaml"
kubeconform -strict -summary -ignore-missing-schemas "$temp_dir"/*.yaml >/dev/null

[[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.name' \
  "$temp_dir/automation-data-job.yaml")" == "$backup_configmap" ]] ||
  fail 'the automation-data restore Job does not use the resolved backup ConfigMap'

[[ "$(yq -r '.spec.template.spec.containers[0].env[].name' \
  "$temp_dir/automation-data-job.yaml" | LC_ALL=C sort | paste -sd, -)" == \
  'AUTOMATION_DATA_BACKUP_PASSWORD,BACKUP_DIR,PGHOST,PGPASSWORD,PGPORT,PGUSER,POST_RECOVERY_BACKUP_DIR' ]] ||
  fail 'the automation-data restore Job environment is not narrowly scoped'
[[ "$(yq -r '.spec.template.spec.containers[0].env[].name' \
  "$temp_dir/n8n-job.yaml" | LC_ALL=C sort | paste -sd, -)" == \
  'PGHOST,PGPASSWORD,PGPORT,PGUSER,RESTORE_DATABASE' ]] ||
  fail 'the n8n restore Job environment is not narrowly scoped'
[[ "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .spec.resources.requests.storage' \
  "$temp_dir/platform.yaml" | sed '/^---$/d' | LC_ALL=C sort -u | paste -sd, -)" == '20Gi' ]] ||
  fail 'both isolated restore data claims must start at 20Gi'
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.hostAliases[0].hostnames[]' \
  "$temp_dir/n8n.yaml" | sed '/^---$/d' | paste -sd, -)" == \
  'automation-data-postgresql,automation-data-postgresql.automation-data.svc.cluster.local' ]] ||
  fail 'the restored n8n instance does not target the isolated automation-data Service'
[[ "$(yq -r 'select(.kind == "HTTPRoute") | .kind' "$temp_dir"/*.yaml | sed '/^---$/d' | wc -l | tr -d ' ')" == 0 ]] ||
  fail 'the isolated restore manifests must not expose an HTTPRoute'

just --show bootstrap automation-data >"$temp_dir/bootstrap-source"
# shellcheck disable=SC2016 # Shell variables are literal rendered-recipe markers.
for bootstrap_marker in \
  "expected_confirmation='bootstrap:automation-data'" \
  "require_deployed_source 'automation-data bootstrap'" \
  'git cat-file -e "origin/main:$database_secret"' \
  'flux resume kustomization automation-data-postgresql' \
  '--from=cronjob/automation-data-postgresql-backup' \
  'just kube automation-data-verify' \
  'trap cleanup_automation_data_bootstrap EXIT' \
  'bootstrap_complete=true'; do
  rg -Fq -- "$bootstrap_marker" "$temp_dir/bootstrap-source" ||
    fail "the automation-data bootstrap omits $bootstrap_marker"
done
bootstrap_trap_line="$(rg -n -m 1 -F 'trap cleanup_automation_data_bootstrap EXIT' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
deployed_source_line="$(rg -n -m 1 -F "require_deployed_source 'automation-data bootstrap'" \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
secret_commit_line="$(rg -n -m 1 -F 'git cat-file -e "origin/main:$database_secret"' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
confirmation_line="$(rg -n -m 1 -F '[[ "${AUTOMATION_DATA_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]]' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
live_suspend_line="$(rg -n -m 1 -F 'get kustomization automation-data-postgresql' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
namespace_reconcile_line="$(rg -n -m 1 -F 'flux reconcile kustomization automation-data --namespace' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
resume_line="$(rg -n -m 1 -F 'flux resume kustomization automation-data-postgresql' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
create_line="$(rg -n -m 1 -F '"$backup_job" --from=cronjob/automation-data-postgresql-backup' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
wait_line="$(rg -n -F 'wait_for_backup_job' "$temp_dir/bootstrap-source" | tail -n 1 | cut -d: -f1)"
delete_line="$(rg -n -F 'delete job' "$temp_dir/bootstrap-source" | tail -n 1 | cut -d: -f1)"
verify_line="$(rg -n -m 1 -F 'just kube automation-data-verify' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
complete_line="$(rg -n -m 1 -F 'bootstrap_complete=true' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
trap_clear_line="$(rg -n -F 'trap - EXIT' "$temp_dir/bootstrap-source" | tail -n 1 | cut -d: -f1)"
previous_line=0
for ordered_line in "$bootstrap_trap_line" "$deployed_source_line" \
  "$secret_commit_line" "$confirmation_line" "$live_suspend_line" \
  "$namespace_reconcile_line" "$resume_line" "$create_line" "$wait_line" \
  "$delete_line" "$verify_line" "$complete_line" "$trap_clear_line"; do
  [[ -n "$ordered_line" && "$ordered_line" -gt "$previous_line" ]] ||
    fail 'the automation-data bootstrap preflight, mutation, validation, and cleanup order is unsafe'
  previous_line="$ordered_line"
done
cleanup_delete_line="$(rg -n -m 1 -F 'delete job' "$temp_dir/bootstrap-source" | cut -d: -f1)"
cleanup_suspend_line="$(rg -n -m 1 -F 'flux suspend kustomization automation-data-postgresql' \
  "$temp_dir/bootstrap-source" | cut -d: -f1)"
[[ -n "$cleanup_delete_line" && -n "$cleanup_suspend_line" && \
  "$cleanup_delete_line" -lt "$cleanup_suspend_line" && \
  "$cleanup_suspend_line" -lt "$deployed_source_line" ]] ||
  fail 'the automation-data bootstrap rollback does not clean its Job before re-suspending PostgreSQL'
if rg -n 'kubectl[^\n]*(get|describe)[^\n]*secrets?|kubectl[^\n]*exec|sops[[:space:]]+-d|resume kustomization n8n|create[^\n]*httproute' \
  "$temp_dir/bootstrap-source"; then
  fail 'the automation-data bootstrap reads Secrets, execs, or broadens its activation scope'
fi

echo 'automation-data offline source contracts passed.'
