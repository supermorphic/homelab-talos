#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/flux-alerts.sh
source scripts/lib/network.sh
# shellcheck source=scripts/test/lib/job.sh
source scripts/test/lib/job.sh
# shellcheck source=scripts/lib/lease.sh
source scripts/lib/lease.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: automation-data-provisioning.sh <kubeconfig>' >&2
  exit 2
}

# This guard precedes kubeconfig inspection and every Kubernetes or n8n request.
expected_confirmation='test:automation-data:provisioning'
[[ "${AUTOMATION_DATA_PROVISIONING_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing automation-data provisioning acceptance: set AUTOMATION_DATA_PROVISIONING_CONFIRM=$expected_confirmation after reviewing the retained acceptance records." >&2
  exit 1
}

provisioning_url="${AUTOMATION_DATA_PROVISIONING_URL:-}"
provisioning_token="${AUTOMATION_DATA_PROVISIONING_TOKEN:-}"
[[ "$provisioning_url" == \
  'https://n8n.lab.supermorphic.com/webhook/automation-data-provision' ]] || {
  echo 'AUTOMATION_DATA_PROVISIONING_URL must be the exact private provisioning webhook URL.' >&2
  exit 1
}
[[ "$provisioning_token" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
  echo 'AUTOMATION_DATA_PROVISIONING_TOKEN must contain at least 32 URL-safe characters.' >&2
  exit 1
}

kubeconfig="$1"
run_dir="${HOMELAB_TEST_RUN_DIR:-}"
[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}
[[ -n "$run_dir" && -d "$run_dir" ]] || {
  echo 'Refusing automation-data provisioning outside the catalog run coordinator.' >&2
  exit 1
}

namespace='automation-data'
domain='issue317_acceptance'
error_domain='issue317_backup_error'
prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}"
run_id="$(basename "$run_dir")"
run_hash="$(printf '%s' "$run_id" | shasum -a 256 | cut -c1-12)"
lease_holder="${TEST_CAMPAIGN_LEASE_HOLDER:-$run_id}"
error_job="automation-data-error-$run_hash"
backup_job="automation-data-backup-$run_hash"
helper_job="automation-data-bundle-$run_hash"
kc=(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace")
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-provisioning.XXXXXX")"
umask 077

write_phase() {
  local phase="$1" phase_status="$2" reason="$3"
  PHASE_STATUS="$phase_status" PHASE_REASON="$reason" \
    yq --null-input --output-format json '{
      "status": strenv(PHASE_STATUS),
      "reason": strenv(PHASE_REASON)
    }' >"$run_dir/$phase.json"
}

write_phase assertion not-classified 'scenario has not completed its primary assertion'
write_phase cleanup not-classified 'run-owned Jobs have not been removed'
write_phase recovery not-required 'the scenario does not disrupt a workload'

job_absent() {
  local name="$1" resource
  resource="$("${kc[@]}" get job "$name" --ignore-not-found --output name)" || return 1
  [[ -z "$resource" ]]
}

verify_lease() {
  verify_test_lease_holder "$kubeconfig" "$lease_holder" || {
    echo 'The shared state-changing test Lease is absent, expired, or owned by another run.' >&2
    return 1
  }
}

cleanup() {
  local original_exit="$?" cleanup_ok=true
  trap - EXIT INT TERM
  set +e
  for job in "$helper_job" "$backup_job" "$error_job"; do
    "${kc[@]}" delete job "$job" --ignore-not-found --wait=true --timeout=2m \
      >/dev/null 2>&1 || cleanup_ok=false
  done
  for job in "$helper_job" "$backup_job" "$error_job"; do
    job_absent "$job" >/dev/null 2>&1 || cleanup_ok=false
  done
  rm -rf -- "$temp_dir" || cleanup_ok=false
  [[ ! -e "$temp_dir" ]] || cleanup_ok=false
  if [[ "$cleanup_ok" == 'true' ]]; then
    write_phase cleanup passed 'all run-owned Jobs and local secret-bearing temporary files were removed'
  else
    write_phase cleanup failed 'one or more run-owned Jobs or local temporary files remain'
  fi
  exit "$original_exit"
}
trap cleanup EXIT

workflow_request() {
  local operation="$1" credential="${2:-}" output="$3"
  local request_file="$temp_dir/request-$operation-${credential:-none}.json"
  local curl_config="$temp_dir/request-$operation-${credential:-none}.curl"
  verify_lease
  if [[ -n "$credential" ]]; then
    jq -n --arg domain "$domain" --arg operation "$operation" \
      --arg credential "$credential" \
      '{domain: $domain, operation: $operation, credential: $credential}' >"$request_file"
  else
    jq -n --arg domain "$domain" --arg operation "$operation" \
      '{domain: $domain, operation: $operation}' >"$request_file"
  fi
  {
    printf '%s\n' 'silent' 'show-error' 'fail-with-body' 'max-time = 120' \
      'request = "POST"' 'header = "Content-Type: application/json"'
    printf 'resolve = "n8n.lab.supermorphic.com:443:%s"\n' "$HOMELAB_GATEWAY_VIP"
    printf 'header = "X-Automation-Data-Provisioning: %s"\n' "$provisioning_token"
    printf 'url = "%s"\n' "$provisioning_url"
    printf 'output = "%s"\n' "$output"
  } >"$curl_config"
  curl --config "$curl_config" --data-binary "@$request_file" || {
    echo "The private provisioning workflow rejected the $operation request." >&2
    return 1
  }
}

require_success_response() {
  local file="$1" operation="$2"
  DOMAIN="$domain" OPERATION="$operation" jq -e '
    .ok == true and
    .domain == env.DOMAIN and
    .operation == env.OPERATION and
    .state == "ready" and
    .database == env.DOMAIN and
    .ownerRole == (env.DOMAIN + "_owner") and
    .migratorRole == (env.DOMAIN + "_migrator") and
    .runtimeRole == (env.DOMAIN + "_runtime") and
    (.migratorCredentialId | type == "string" and length > 0) and
    (.runtimeCredentialId | type == "string" and length > 0) and
    (.migratorCredentialUpdatedAt | type == "string" and length > 0) and
    (.runtimeCredentialUpdatedAt | type == "string" and length > 0) and
    (.checks | length == 15) and
    ([.checks[] | select(. != true)] | length == 0)
  ' "$file" >/dev/null || {
    echo "The $operation response omitted required non-secret identity or permission evidence." >&2
    return 1
  }
}

credential_signature() {
  jq -c '[
    .domain,
    .database,
    .ownerRole,
    .migratorRole,
    .runtimeRole,
    .migratorCredentialId,
    .runtimeCredentialId,
    .migratorCredentialUpdatedAt,
    .runtimeCredentialUpdatedAt
  ]' "$1"
}

provision_response="$temp_dir/provision.json"
reconcile_one_response="$temp_dir/reconcile-one.json"
reconcile_two_response="$temp_dir/reconcile-two.json"
rotation_response="$temp_dir/rotation.json"
post_rotation_response="$temp_dir/post-rotation.json"

workflow_request provision '' "$provision_response"
require_success_response "$provision_response" provision
[[ "$(jq -r '.passwordsUnchanged' "$provision_response")" == 'null' ]]
initial_signature="$(credential_signature "$provision_response")"

workflow_request reconcile '' "$reconcile_one_response"
require_success_response "$reconcile_one_response" reconcile
[[ "$(jq -r '.passwordsUnchanged' "$reconcile_one_response")" == 'true' && \
  "$(credential_signature "$reconcile_one_response")" == "$initial_signature" ]] || {
  echo 'The first unchanged reconcile changed credential identity or update state.' >&2
  exit 1
}

workflow_request reconcile '' "$reconcile_two_response"
require_success_response "$reconcile_two_response" reconcile
[[ "$(jq -r '.passwordsUnchanged' "$reconcile_two_response")" == 'true' && \
  "$(credential_signature "$reconcile_two_response")" == "$initial_signature" ]] || {
  echo 'The second unchanged reconcile changed credential identity or update state.' >&2
  exit 1
}

workflow_request rotate runtime "$rotation_response"
require_success_response "$rotation_response" rotate
[[ "$(jq -r '.passwordsUnchanged' "$rotation_response")" == 'null' && \
  "$(jq -r '.migratorCredentialId' "$rotation_response")" == \
    "$(jq -r '.migratorCredentialId' "$provision_response")" && \
  "$(jq -r '.runtimeCredentialId' "$rotation_response")" == \
    "$(jq -r '.runtimeCredentialId' "$provision_response")" && \
  "$(jq -r '.migratorCredentialUpdatedAt' "$rotation_response")" == \
    "$(jq -r '.migratorCredentialUpdatedAt' "$provision_response")" && \
  "$(jq -r '.runtimeCredentialUpdatedAt' "$rotation_response")" != \
    "$(jq -r '.runtimeCredentialUpdatedAt' "$provision_response")" ]] || {
  echo 'Explicit runtime rotation did not preserve IDs and update only runtime metadata.' >&2
  exit 1
}
rotation_signature="$(credential_signature "$rotation_response")"

workflow_request reconcile '' "$post_rotation_response"
require_success_response "$post_rotation_response" reconcile
[[ "$(jq -r '.passwordsUnchanged' "$post_rotation_response")" == 'true' && \
  "$(credential_signature "$post_rotation_response")" == "$rotation_signature" ]] || {
  echo 'The post-rotation reconcile changed the stable rotated credential state.' >&2
  exit 1
}

verify_lease
for job in "$error_job" "$backup_job" "$helper_job"; do
  job_absent "$job" || {
    echo "Refusing to adopt existing Job $namespace/$job." >&2
    exit 1
  }
done

error_job_manifest() {
  local error_command
  error_command="psql --no-psqlrc --set=ON_ERROR_STOP=1 --command=\"SELECT platform_operations.record_operation_error('issue317_backup_error', 'acceptance_backup_error');\" >/dev/null"
  JOB_NAME="$error_job" RUN_HASH="$run_hash" ERROR_COMMAND="$error_command" \
    yq --null-input --output-format yaml '
    {
      "apiVersion": "batch/v1",
      "kind": "Job",
      "metadata": {
        "name": strenv(JOB_NAME),
        "namespace": "automation-data",
        "labels": {
          "app.kubernetes.io/name": "automation-data-postgresql-backup",
          "homelab-talos/test": "automation-data-provisioning",
          "homelab-talos/run-id": strenv(RUN_HASH)
        }
      },
      "spec": {
        "activeDeadlineSeconds": 300,
        "backoffLimit": 0,
        "template": {
          "metadata": {"labels": {
            "app.kubernetes.io/name": "automation-data-postgresql-backup",
            "homelab-talos/test": "automation-data-provisioning",
            "homelab-talos/run-id": strenv(RUN_HASH)
          }},
          "spec": {
            "automountServiceAccountToken": false,
            "restartPolicy": "Never",
            "securityContext": {
              "runAsNonRoot": true,
              "runAsUser": 70,
              "runAsGroup": 70,
              "seccompProfile": {"type": "RuntimeDefault"}
            },
            "containers": [{
              "name": "record-error",
              "image": "postgres:17.11-alpine3.24",
              "command": ["/bin/sh", "-ceu"],
              "args": [strenv(ERROR_COMMAND)],
              "env": [
                {"name": "PGDATABASE", "value": "automation_data_control"},
                {"name": "PGHOST", "value": "automation-data-postgresql"},
                {"name": "PGPORT", "value": "5432"},
                {"name": "PGUSER", "value": "automation_data_provisioner"},
                {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {
                  "name": "postgresql-credentials", "key": "provisioner-password"
                }}}
              ],
              "resources": {
                "requests": {"cpu": "10m", "memory": "32Mi"},
                "limits": {"memory": "128Mi"}
              },
              "securityContext": {
                "allowPrivilegeEscalation": false,
                "capabilities": {"drop": ["ALL"]},
                "readOnlyRootFilesystem": true
              },
              "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}]
            }],
            "volumes": [{"name": "tmp", "emptyDir": {}}]
          }
        }
      }
    }'
}

verify_lease
error_job_manifest | "${kc[@]}" create --filename - >/dev/null
wait_for_job_terminal "$error_job" 300 2 "${kc[@]}"

query_database_set() {
  local response
  response="$(flux_alerts_prometheus_query \
    "$prometheus_base_url" "$prometheus_resolve" \
    'automation_data_postgresql_database_size_bytes{namespace="automation-data",service="automation-data-postgresql"}')" || return 1
  yq -e '.status == "success" and (.data.result | length > 0)' \
    >/dev/null 2>&1 <<<"$response" || return 1
  jq -r '.data.result[].metric.database | @base64' <<<"$response" | LC_ALL=C sort -u
}

database_set_before=''
for _attempt in {1..18}; do
  if database_set_before="$(query_database_set)" && \
    [[ "$(printf '%s' "$domain" | base64 | tr -d '\n')" == \
      "$(rg -x "$(printf '%s' "$domain" | base64 | tr -d '\n')" \
        <<<"$database_set_before")" ]]; then
    break
  fi
  database_set_before=''
  (( _attempt == 18 )) || sleep 10
done
[[ -n "$database_set_before" ]] || {
  echo 'Prometheus did not expose the complete database catalog set before backup.' >&2
  exit 1
}

backup_timestamp_before="$(
  flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" \
    'automation_data_postgresql_backup_last_success_timestamp_seconds{namespace="automation-data",service="automation-data-postgresql"}' |
    yq -r 'select(.status == "success" and (.data.result | length) == 1) | .data.result[0].value[1]'
)"
[[ -n "$backup_timestamp_before" ]]

verify_lease
active_backup_jobs="$(
  "${kc[@]}" get jobs --selector \
    app.kubernetes.io/name=automation-data-postgresql-backup --output json |
    yq -r '[.items[] | select((.status.active // 0) > 0)] | length'
)"
[[ "$active_backup_jobs" == '0' ]] || {
  echo 'Refusing to overlap the acceptance backup with an active backup Job.' >&2
  exit 1
}
"${kc[@]}" create job "$backup_job" \
  --from=cronjob/automation-data-postgresql-backup --dry-run=client --output yaml |
  JOB_NAME="$backup_job" RUN_HASH="$run_hash" yq '
    .metadata.name = strenv(JOB_NAME) |
    .metadata.labels."homelab-talos/test" = "automation-data-provisioning" |
    .metadata.labels."homelab-talos/run-id" = strenv(RUN_HASH) |
    .spec.template.metadata.labels."homelab-talos/test" = "automation-data-provisioning" |
    .spec.template.metadata.labels."homelab-talos/run-id" = strenv(RUN_HASH)
  ' | "${kc[@]}" create --filename - >/dev/null
wait_for_job_terminal "$backup_job" 1800 5 "${kc[@]}"

backup_timestamp_after=''
for _attempt in {1..18}; do
  backup_timestamp_after="$(
    flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" \
      'automation_data_postgresql_backup_last_success_timestamp_seconds{namespace="automation-data",service="automation-data-postgresql"}' |
      yq -r 'select(.status == "success" and (.data.result | length) == 1) | .data.result[0].value[1]'
  )"
  if [[ -n "$backup_timestamp_after" ]] && awk \
    -v before="$backup_timestamp_before" -v after="$backup_timestamp_after" \
    'BEGIN { exit !(after > before) }'; then
    break
  fi
  backup_timestamp_after=''
  (( _attempt == 18 )) || sleep 10
done
[[ -n "$backup_timestamp_after" ]] || {
  echo 'The completed acceptance backup did not advance the validated freshness series.' >&2
  exit 1
}

database_set_after="$(query_database_set)"
[[ "$database_set_after" == "$database_set_before" ]] || {
  echo 'The Prometheus database catalog changed during backup acceptance.' >&2
  exit 1
}
expected_database_set_base64="$(printf '%s\n' "$database_set_before" | base64 | tr -d '\n')"

# shellcheck disable=SC2016 # The generated helper Job expands these variables.
helper_command='set -eu
bundle="$(find /backups -mindepth 1 -maxdepth 1 -type d -name "automation-data-*" | LC_ALL=C sort | tail -n 1)"
test -n "$bundle"
test -s "$bundle/COMPLETE" -a -s "$bundle/SHA256SUMS" -a -s "$bundle/manifest.tsv" -a -s "$bundle/registry.tsv"
(cd "$bundle" && sha256sum -c SHA256SUMS >/dev/null && sha256sum -c COMPLETE >/dev/null)
printf %s "$EXPECTED_DATABASE_SET_BASE64" | base64 -d > /tmp/expected-databases
awk -F "\t" '\''$1 == "database" {print $2}'\'' "$bundle/manifest.tsv" | LC_ALL=C sort -u > /tmp/manifest-databases
cmp -s /tmp/expected-databases /tmp/manifest-databases
awk -F "\t" '\''$1 == "issue317_backup_error" && $6 == "error" && $15 == "acceptance_backup_error" {found=1} END {exit !found}'\'' "$bundle/registry.tsv"
database_count="$(wc -l < /tmp/manifest-databases | tr -d " ")"
printf "bundle_valid=true database_count=%s error_record=present\n" "$database_count"'

helper_job_manifest() {
  JOB_NAME="$helper_job" RUN_HASH="$run_hash" \
    EXPECTED_DATABASE_SET_BASE64="$expected_database_set_base64" \
    HELPER_COMMAND="$helper_command" yq --null-input --output-format yaml '
      {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
          "name": strenv(JOB_NAME),
          "namespace": "automation-data",
          "labels": {
            "app.kubernetes.io/name": "automation-data-postgresql-backup",
            "homelab-talos/test": "automation-data-provisioning",
            "homelab-talos/run-id": strenv(RUN_HASH)
          }
        },
        "spec": {
          "activeDeadlineSeconds": 300,
          "backoffLimit": 0,
          "template": {
            "metadata": {"labels": {
              "app.kubernetes.io/name": "automation-data-postgresql-backup",
              "homelab-talos/test": "automation-data-provisioning",
              "homelab-talos/run-id": strenv(RUN_HASH)
            }},
            "spec": {
              "automountServiceAccountToken": false,
              "restartPolicy": "Never",
              "securityContext": {
                "fsGroup": 70,
                "fsGroupChangePolicy": "OnRootMismatch",
                "runAsNonRoot": true,
                "runAsUser": 70,
                "runAsGroup": 70,
                "seccompProfile": {"type": "RuntimeDefault"}
              },
              "containers": [{
                "name": "validate-bundle",
                "image": "postgres:17.11-alpine3.24",
                "command": ["/bin/sh", "-ceu"],
                "args": [strenv(HELPER_COMMAND)],
                "env": [{
                  "name": "EXPECTED_DATABASE_SET_BASE64",
                  "value": strenv(EXPECTED_DATABASE_SET_BASE64)
                }],
                "resources": {
                  "requests": {"cpu": "10m", "memory": "32Mi"},
                  "limits": {"memory": "128Mi"}
                },
                "securityContext": {
                  "allowPrivilegeEscalation": false,
                  "capabilities": {"drop": ["ALL"]},
                  "readOnlyRootFilesystem": true
                },
                "volumeMounts": [
                  {"name": "backups", "mountPath": "/backups", "readOnly": true},
                  {"name": "tmp", "mountPath": "/tmp"}
                ]
              }],
              "volumes": [
                {"name": "backups", "persistentVolumeClaim": {
                  "claimName": "automation-data-postgresql-backups", "readOnly": true
                }},
                {"name": "tmp", "emptyDir": {}}
              ]
            }
          }
        }
      }'
}

verify_lease
helper_job_manifest | "${kc[@]}" create --filename - >/dev/null
wait_for_job_terminal "$helper_job" 300 2 "${kc[@]}"
helper_result="$("${kc[@]}" logs "job/$helper_job" --tail=1)"
[[ "$helper_result" =~ ^bundle_valid=true\ database_count=[0-9]+\ error_record=present$ ]] || {
  echo 'The read-only backup helper did not return its bounded success evidence.' >&2
  exit 1
}

jq -n \
  --arg domain "$domain" \
  --arg errorDomain "$error_domain" \
  --argjson credentialIdsStable true \
  --argjson repeatedReconcileStable true \
  --argjson runtimeRotationValidated true \
  --argjson permissionChecksPassed true \
  --argjson backupAdvanced true \
  --arg bundleEvidence "$helper_result" \
  '{
    domain: $domain,
    errorDomain: $errorDomain,
    credentialIdsStable: $credentialIdsStable,
    repeatedReconcileStable: $repeatedReconcileStable,
    runtimeRotationValidated: $runtimeRotationValidated,
    permissionChecksPassed: $permissionChecksPassed,
    backupAdvanced: $backupAdvanced,
    bundleEvidence: $bundleEvidence
  }' >"$run_dir/automation-data-provisioning-evidence.json"

write_phase assertion passed 'provisioning, idempotency, permission, rotation, and backup assertions passed'
echo "automation-data attended provisioning acceptance passed for $domain: credential IDs and unchanged reconciliation remained stable; permission checks and runtime rotation passed; the error registry row did not block a complete dynamically discovered backup."
