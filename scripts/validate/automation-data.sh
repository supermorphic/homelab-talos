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

echo 'automation-data offline source contracts passed.'
