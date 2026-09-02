#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail() {
  echo "automation-data validation failed: $*" >&2
  exit 1
}

# These focused tests are the only merge-gate owners of the issue-specific behavior.
# Repository-wide lint, schema, policy, SOPS, gitleaks, and Prometheus checks remain in
# their existing suites and are intentionally not repeated here.
scripts/test/automation-data-secrets-test.sh
scripts/test/automation-data-control-contract-test.sh
scripts/test/automation-data-workflow-contract-test.sh
scripts/test/automation-data-backup-test.sh

[[ "$(yq -r '[.resources[] | select(. == "./automation-data")] | length' \
  kubernetes/apps/kustomization.yaml)" == 1 ]] ||
  fail 'the root applications graph must select automation-data exactly once'

platform_graph="$(yq -r '[.resources[]] | sort | join(",")' \
  kubernetes/apps/automation-data/kustomization.yaml)"
[[ "$platform_graph" == './namespace/ks.yaml,./postgresql/ks.yaml' ]] ||
  fail 'the automation-data Flux package graph is incomplete'
[[ "$(yq -r '.spec.suspend' kubernetes/apps/automation-data/postgresql/ks.yaml)" == true ]] ||
  fail 'the automation-data PostgreSQL package must remain staged'

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

verifier='scripts/verify/automation-data.sh'
scenario='scripts/test/scenarios/automation-data-provisioning.sh'
[[ -x "$verifier" && -x "$scenario" ]] ||
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

echo 'automation-data offline source contracts passed.'
