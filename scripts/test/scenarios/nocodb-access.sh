#!/usr/bin/env bash
# Attended, catalog-coordinated NocoDB access acceptance.
set -euo pipefail

source scripts/lib/common.sh
# shellcheck source=scripts/lib/lease.sh
source scripts/lib/lease.sh
# shellcheck source=scripts/lib/rollout.sh
source scripts/lib/rollout.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: nocodb-access.sh <kubeconfig>' >&2
  exit 2
}

expected_confirmation='test:nocodb:access'
[[ "${NOCODB_ACCESS_TEST_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing NocoDB access acceptance: set NOCODB_ACCESS_TEST_CONFIRM=$expected_confirmation." >&2
  exit 1
}

kubeconfig="$1"
run_dir="${HOMELAB_TEST_RUN_DIR:-}"
[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}
[[ -n "$run_dir" && -d "$run_dir" ]] || {
  echo 'Refusing NocoDB access acceptance outside the catalog run coordinator.' >&2
  exit 1
}

run_id="$(basename "$run_dir")"
[[ "$run_id" =~ ^[A-Za-z0-9_.:-]+$ ]] || {
  echo 'The catalog coordinator supplied an unsafe run ID.' >&2
  exit 1
}
lease_holder="${TEST_CAMPAIGN_LEASE_HOLDER:-$run_id}"

provisioning_url="${AUTOMATION_DATA_PROVISIONING_URL:-}"
source_url="${NOCODB_SOURCE_PROVISIONING_URL:-}"
acceptance_url="${NOCODB_ACCEPTANCE_URL:-}"
provisioning_token="${AUTOMATION_DATA_PROVISIONING_TOKEN:-}"
source_token="${NOCODB_SOURCE_PROVISIONING_TOKEN:-}"
acceptance_token="${NOCODB_ACCEPTANCE_TOKEN:-}"

[[ "$provisioning_url" == 'https://n8n.lab.supermorphic.com/webhook/automation-data-provision' ]] || {
  echo 'AUTOMATION_DATA_PROVISIONING_URL must be the exact private provisioning webhook URL.' >&2
  exit 1
}
[[ "$source_url" == 'https://n8n.lab.supermorphic.com/webhook/automation-data-nocodb-source' ]] || {
  echo 'NOCODB_SOURCE_PROVISIONING_URL must be the exact private source webhook URL.' >&2
  exit 1
}
[[ "$acceptance_url" == 'https://n8n.lab.supermorphic.com/webhook/nocodb-acceptance-domain' ]] || {
  echo 'NOCODB_ACCEPTANCE_URL must be the exact private acceptance webhook URL.' >&2
  exit 1
}
for token_name in provisioning_token source_token acceptance_token; do
  token_value="${!token_name}"
  [[ "$token_value" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
    echo 'Every NocoDB acceptance webhook token must contain at least 32 URL-safe characters.' >&2
    exit 1
  }
done

require_deployed_source 'NocoDB access acceptance' \
  scripts/test/scenarios/nocodb-access.sh \
  kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json \
  kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json \
  kubernetes/apps/automation/n8n/app/workflows/nocodb-acceptance-domain.json

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-access.XXXXXX")"
chmod 700 "$temp_dir"

write_phase() {
  local phase="$1" status="$2" reason="$3"
  PHASE_STATUS="$status" PHASE_REASON="$reason" \
    yq --null-input --output-format json '{
      "status": strenv(PHASE_STATUS),
      "reason": strenv(PHASE_REASON)
    }' >"$run_dir/$phase.json"
}

write_phase assertion not-classified 'the fixed NocoDB access contract has not completed'
write_phase cleanup not-classified 'current-run acceptance rows have not been removed'
write_phase recovery not-required 'the access scenario does not disrupt or replace a workload'

verify_lease() {
  verify_test_lease_holder "$kubeconfig" "$lease_holder" || {
    echo 'The shared state-changing test Lease is absent, expired, or owned by another run.' >&2
    return 1
  }
}

http_request() { # <label> <url> <token-kind|none> <body> <response> <expected-status>
  local label="$1" url="$2" token_kind="$3" body="$4" response="$5" expected_status="$6"
  local config="$temp_dir/${label}.curl" status curl_status
  {
    printf '%s\n' 'silent' 'show-error' 'request = "POST"' 'max-time = 720' \
      'max-filesize = 65536' \
      'header = "Content-Type: application/json"'
    case "$token_kind" in
      provisioning)
        printf 'header = "X-Automation-Data-Provisioning: %s"\n' "$provisioning_token"
        ;;
      source)
        printf 'header = "Authorization: Bearer %s"\n' "$source_token"
        ;;
      acceptance)
        printf 'header = "Authorization: Bearer %s"\n' "$acceptance_token"
        ;;
      none) ;;
      *) return 2 ;;
    esac
    printf 'data-binary = "@%s"\n' "$body"
    printf 'url = "%s"\n' "$url"
    printf 'output = "%s"\n' "$response"
    printf '%s\n' 'write-out = "%{http_code}"'
  } >"$config"
  chmod 600 "$config" "$body"

  set +e
  status="$(curl --config "$config")"
  curl_status=$?
  set -e
  [[ "$curl_status" -eq 0 ]] || {
    echo "$label request failed before returning an HTTP status." >&2
    return "$curl_status"
  }
  [[ " $expected_status " == *" $status "* ]] || {
    echo "$label returned HTTP ${status:-unknown}; expected one of: $expected_status." >&2
    return 1
  }
  [[ -f "$response" && "$(wc -c <"$response")" -le 65536 ]] || {
    echo "$label response is absent or exceeds 64 KiB." >&2
    return 1
  }
}

acceptance_request() { # <operation> <response>
  local operation="$1" response="$2" body
  body="$temp_dir/acceptance-${operation}.json"
  verify_lease || return
  jq -n --arg operation "$operation" --arg run_id "$run_id" \
    '{operation: $operation, runId: $run_id}' >"$body"
  http_request "acceptance-${operation}" "$acceptance_url" acceptance \
    "$body" "$response" 200
}

cleanup() {
  local original_exit="$?" cleanup_ok=true cleanup_response="$temp_dir/cleanup-response.json"
  local final_exit="$original_exit"
  trap - EXIT INT TERM
  set +e
  if acceptance_request cleanup "$cleanup_response" &&
    RUN_ID="$run_id" jq -e '
      .ok == true and
      .operation == "cleanup" and
      .runId == env.RUN_ID and
      .domain == "issue334_acceptance" and
      (.removedCount | type == "number" and . >= 0 and . <= 1000)
    ' "$cleanup_response" >/dev/null; then
    :
  else
    cleanup_ok=false
  fi
  rm -rf -- "$temp_dir" || cleanup_ok=false
  [[ ! -e "$temp_dir" ]] || cleanup_ok=false
  if [[ "$cleanup_ok" == true ]]; then
    write_phase cleanup passed \
      'current-run rows were removed; domain, base, sources, and reserved attachment canary were retained'
  else
    write_phase cleanup failed \
      'current-run acceptance cleanup or retained-canary read-back failed'
    [[ "$final_exit" -ne 0 ]] || final_exit=1
  fi
  if [[ "$original_exit" -ne 0 && "$(yq -r '.status' "$run_dir/assertion.json" 2>/dev/null)" == not-classified ]]; then
    write_phase assertion failed 'the fixed NocoDB access contract failed'
  fi
  exit "$final_exit"
}
trap cleanup EXIT

namespace='automation-data'
kc=(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace")
pods_json="$temp_dir/pods.json"
workloads_json="$temp_dir/workloads.json"
services_json="$temp_dir/services.json"
"${kc[@]}" get pods --output json >"$pods_json"
"${kc[@]}" get deployments,statefulsets,daemonsets,jobs,cronjobs --output json >"$workloads_json"
"${kc[@]}" get services --output json >"$services_json"
jq -e '
  def marked:
    (({name: .metadata.name, labels: (.metadata.labels // {})} | tostring | ascii_downcase) | test("nocodb|redis")) or
    ([.spec.containers[]?, .spec.initContainers[]?, .spec.ephemeralContainers[]? |
      select(((.name + " " + (.image // "")) | ascii_downcase) | test("nocodb|redis"))] | length > 0);
  [.items[] | select(.metadata.labels["app.kubernetes.io/name"] == "nocodb")] as $apps |
  [.items[] | select(marked)] as $marked |
  ($apps | length) == 1 and
  $apps[0].status.phase == "Running" and
  ($apps[0].spec.containers | length) == 1 and
  $apps[0].spec.containers[0].name == "nocodb" and
  $apps[0].spec.containers[0].image == "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9" and
  (($apps[0].spec.initContainers // []) | length) == 0 and
  (($apps[0].spec.ephemeralContainers // []) | length) == 0 and
  ($apps[0].status.containerStatuses | length) == 1 and
  $apps[0].status.containerStatuses[0].name == "nocodb" and
  $apps[0].status.containerStatuses[0].ready == true and
  all($marked[];
    (.metadata.name == $apps[0].metadata.name) or
    (
      .metadata.labels["app.kubernetes.io/name"] == "nocodb-metadata-bootstrap" and
      (.spec.containers | length) == 1 and
      .spec.containers[0].name == "bootstrap" and
      .spec.containers[0].image == "postgres:17.11-alpine3.24" and
      ((.spec.initContainers // []) | length) == 0 and
      ((.spec.ephemeralContainers // []) | length) == 0
    )
  )
' "$pods_json" >/dev/null || {
  echo 'NocoDB must have one ready application pod and no unapproved NocoDB or Redis pod.' >&2
  exit 1
}
jq -e '
  def containers: [
    .spec.template.spec.containers[]?,
    .spec.template.spec.initContainers[]?,
    .spec.jobTemplate.spec.template.spec.containers[]?,
    .spec.jobTemplate.spec.template.spec.initContainers[]?
  ];
  def marked:
    (({name: .metadata.name, labels: (.metadata.labels // {})} | tostring | ascii_downcase) | test("nocodb|redis")) or
    ([containers[] | select(((.name + " " + (.image // "")) | ascii_downcase) | test("nocodb|redis"))] | length > 0);
  [.items[] | select(marked)] as $marked |
  [$marked[] | select(.kind == "Deployment" and .metadata.name == "nocodb")] as $apps |
  [$marked[] | select(.kind == "Job" and .metadata.name == "nocodb-metadata-bootstrap")] as $bootstraps |
  ($marked | length) == 2 and ($apps | length) == 1 and ($bootstraps | length) == 1 and
  $apps[0].metadata.labels["app.kubernetes.io/name"] == "nocodb" and
  $apps[0].spec.replicas == 1 and
  $apps[0].spec.strategy.type == "Recreate" and
  ($apps[0].spec.template.spec.containers | length) == 1 and
  $apps[0].spec.template.spec.containers[0].name == "nocodb" and
  $apps[0].spec.template.spec.containers[0].image == "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9" and
  (($apps[0].spec.template.spec.initContainers // []) | length) == 0 and
  $bootstraps[0].metadata.labels["app.kubernetes.io/name"] == "nocodb-metadata-bootstrap" and
  ($bootstraps[0].spec.template.spec.containers | length) == 1 and
  $bootstraps[0].spec.template.spec.containers[0].name == "bootstrap" and
  $bootstraps[0].spec.template.spec.containers[0].image == "postgres:17.11-alpine3.24" and
  (($bootstraps[0].spec.template.spec.initContainers // []) | length) == 0
' "$workloads_json" >/dev/null || {
  echo 'NocoDB workload inventory must contain only the approved Recreate app and metadata bootstrap Job.' >&2
  exit 1
}
jq -e '
  [.items[] | select(
    (({name: .metadata.name, labels: (.metadata.labels // {}), selector: (.spec.selector // {}), ports: (.spec.ports // [])} | tostring | ascii_downcase) | test("nocodb|redis"))
  )] as $marked |
  ($marked | length) == 1 and
  $marked[0].kind == "Service" and
  $marked[0].metadata.name == "nocodb" and
  $marked[0].metadata.labels["app.kubernetes.io/name"] == "nocodb" and
  $marked[0].spec.type == "ClusterIP" and
  $marked[0].spec.selector["app.kubernetes.io/name"] == "nocodb" and
  ($marked[0].spec.ports | length) == 1 and
  $marked[0].spec.ports[0].port == 8080
' "$services_json" >/dev/null || {
  echo 'NocoDB service inventory must contain only the approved application Service and no Redis service.' >&2
  exit 1
}

provision_body="$temp_dir/provision.json"
provision_response="$temp_dir/provision-response.json"
jq -n '{domain: "issue334_acceptance", operation: "provision"}' >"$provision_body"
verify_lease || exit 1
http_request provision "$provisioning_url" provisioning "$provision_body" \
  "$provision_response" 200
jq -e '
  .ok == true and .domain == "issue334_acceptance" and
  .operation == "provision" and .state == "ready" and
  .database == "issue334_acceptance" and
  .ownerRole == "issue334_acceptance_owner" and
  .migratorRole == "issue334_acceptance_migrator" and
  .runtimeRole == "issue334_acceptance_runtime" and
  (.migratorCredentialId | type == "string" and length > 0) and
  (.runtimeCredentialId | type == "string" and length > 0) and
  (.checks | length == 15 and all)
' "$provision_response" >/dev/null || {
  echo 'The existing automation-data provisioner did not return complete acceptance evidence.' >&2
  exit 1
}

structure_response="$temp_dir/structure-response.json"
acceptance_request structure "$structure_response"
RUN_ID="$run_id" jq -e '
  . == {ok:true,operation:"structure",runId:env.RUN_ID,domain:"issue334_acceptance",structureReady:true}
' "$structure_response" >/dev/null || {
  echo 'The fixed acceptance structure operation did not complete.' >&2
  exit 1
}

source_request() { # <operation> <response>
  local operation="$1" response="$2" body
  body="$temp_dir/source-${operation}-$(basename "$response")"
  verify_lease || return
  if [[ "$operation" == sync ]]; then
    jq -n '{domain: "issue334_acceptance", operation: "sync"}' >"$body"
  else
    jq -n '{domain: "issue334_acceptance", operation: "rotate", accessKind: "operator"}' >"$body"
  fi
  http_request "source-${operation}-$(basename "$response" .json)" "$source_url" source \
    "$body" "$response" 200
}

validate_ready_source() { # <response> <kind>
  local response="$1" kind="$2"
  KIND="$kind" jq -e '
    .accessKind == env.KIND and .state == "ready" and
    (.sourceId | type == "string" and length > 0) and
    (.integrationId | type == "string" and length > 0) and
    (.sourceCreateJobId | type == "string" and length > 0) and
    .sourceCreateJobState == "completed" and
    .sourceDiscovered == true and .sourceReadBack == true and
    (.generation | type == "number" and . > 0) and
    (.credentialGeneration | type == "number" and . > 0) and
    (.operationStartedAt | type == "string" and length > 0) and
    (.updatedAt | type == "string" and length > 0) and
    (.validatedAt | type == "string" and length > 0) and
    .operationStartedAt <= .updatedAt and .updatedAt <= .validatedAt and
    (.dataEditAllowed == (env.KIND == "operator")) and
    .schemaEditAllowed == false and
    .postgresqlValidation.valid == true and
    .postgresqlValidation.loginValid == true and
    .postgresqlValidation.schemaPrivilegesValid == true and
    .postgresqlValidation.objectPrivilegesValid == true and
    .postgresqlValidation.defaultPrivilegesValid == true and
    .postgresqlValidation.outsideSchemaDenied == true and
    .postgresqlValidation.databaseIsolationValid == true and
    .postgresqlValidation.forbiddenAttributesDenied == true and
    .postgresqlValidation.forbiddenMembershipsDenied == true and
    .postgresqlValidation.ddlDenied == true and
    (.postgresqlValidation.controlledDmlPresent == (env.KIND == "operator"))
  ' <<<"$(jq -c --arg kind "$kind" '.[$kind]' "$response")" >/dev/null
}

validate_source_envelope() { # <response> <operation>
  local response="$1" operation="$2"
  OPERATION="$operation" jq -e '
    .ok == true and .domain == "issue334_acceptance" and
    .operation == env.OPERATION and
    (.baseId | type == "string" and length > 0) and .errorCode == null
  ' "$response" >/dev/null
}

first_sync="$temp_dir/source-sync-first.json"
source_request sync "$first_sync"
if ! validate_source_envelope "$first_sync" sync ||
  ! validate_ready_source "$first_sync" reader; then
  echo 'Initial source sync omitted completed reader job, discovery, read-back, or timing evidence.' >&2
  exit 1
fi
jq -e '
  .operator.accessKind == "operator" and
  .operator.state == "awaiting_grants" and
  .operator.sourceId == null and .operator.integrationId == null and
  .operator.sourceCreateJobId == null and .operator.sourceCreateJobState == null and
  .operator.sourceDiscovered == false and .operator.sourceReadBack == false and
  .operator.credentialGeneration == 0
' "$first_sync" >/dev/null || {
  echo 'Initial source sync did not leave the operator awaiting reviewed grants.' >&2
  exit 1
}

grants_response="$temp_dir/grants-response.json"
acceptance_request grants "$grants_response"
RUN_ID="$run_id" jq -e '
  . == {ok:true,operation:"grants",runId:env.RUN_ID,domain:"issue334_acceptance",grantsReady:true}
' "$grants_response" >/dev/null || {
  echo 'The fixed acceptance grants operation did not complete.' >&2
  exit 1
}

ready_sync="$temp_dir/source-sync-ready.json"
source_request sync "$ready_sync"
if ! validate_source_envelope "$ready_sync" sync ||
  ! validate_ready_source "$ready_sync" reader ||
  ! validate_ready_source "$ready_sync" operator; then
  echo 'Ready source sync omitted completed jobs, discovered sources, read-back, or timing evidence.' >&2
  exit 1
fi
jq -e '
  .reader.validatedAt < .operator.operationStartedAt and
  .reader.updatedAt < .operator.updatedAt
' "$ready_sync" >/dev/null || {
  echo 'Reader completion did not precede operator creation.' >&2
  exit 1
}
reader_source_signature() {
  jq -cS '[.baseId, (.reader | {sourceId,integrationId,sourceCreateJobId,generation,credentialGeneration})]' "$1"
}
[[ "$(reader_source_signature "$ready_sync")" == "$(reader_source_signature "$first_sync")" ]] || {
  echo 'Second source sync replaced the ready reader or its base, job, or generation identity.' >&2
  exit 1
}

signup_body="$temp_dir/signup.json"
signup_response="$temp_dir/signup-response.json"
jq -n '{email:"acceptance-denied@example.invalid",password:"acceptance-only-not-a-secret"}' >"$signup_body"
verify_lease || exit 1
http_request signup-denial 'https://nocodb.lab.supermorphic.com/api/v1/auth/user/signup' none \
  "$signup_body" "$signup_response" '400 401 403'
jq -e 'type == "object" and length > 0' "$signup_response" >/dev/null || {
  echo 'Unauthenticated signup denial did not return bounded evidence.' >&2
  exit 1
}

validate_probe() { # <response> <source-response>
  local response="$1" source_response="$2"
  local base_id reader_source_id operator_source_id
  base_id="$(jq -r '.baseId' "$source_response")"
  reader_source_id="$(jq -r '.reader.sourceId' "$source_response")"
  operator_source_id="$(jq -r '.operator.sourceId' "$source_response")"
  RUN_ID="$run_id" BASE_ID="$base_id" READER_SOURCE_ID="$reader_source_id" \
    OPERATOR_SOURCE_ID="$operator_source_id" jq -e '
    .ok == true and .operation == "probe" and .runId == env.RUN_ID and
    .domain == "issue334_acceptance" and
    (env.BASE_ID | length > 0) and
    .credentialProof == {throughN8n:true,credentialName:"NocoDB Operator API"} and
    .inserted == true and .read == true and .readerRead == true and
    .decisionUpdated == true and .removed == true and
    .reflectedSchemas == ["operator","read_model"] and
    ([.reflectedTables[] | select(.schema == "read_model" and .tableName == "acceptance_facts")]) as $facts_tables |
    ([.reflectedTables[] | select(.schema == "operator" and .tableName == "acceptance_decision")]) as $decision_tables |
    ($facts_tables | length) == 1 and ($decision_tables | length) == 1 and
    ($facts_tables[0].id | type == "string" and length > 0) and
    $facts_tables[0].title == "acceptance_facts" and
    $facts_tables[0].sourceId == env.READER_SOURCE_ID and
    ($decision_tables[0].id | type == "string" and length > 0) and
    $decision_tables[0].title == "acceptance_decision" and
    $decision_tables[0].sourceId == env.OPERATOR_SOURCE_ID and
    .forbiddenOperations.protectedUpdateDenied == true and
    .forbiddenOperations.protectedUpdateStatus == 400 and
    .forbiddenOperations.protectedUpdateEvidence == "postgresql_42501" and
    .forbiddenOperations.readerInsertDenied == true and
    .forbiddenOperations.readerInsertStatus == 403 and
    .forbiddenOperations.readerInsertEvidence == "source_read_only" and
    .publicSharing.basePublicShareUuid == null and
    (.publicSharing.views | length) == 2 and
    ([.publicSharing.views[] | [.title,.publicShareUuid]] | sort) == [["acceptance_decision",null],["acceptance_facts",null]] and
    (.attachmentCanary | keys) == [
      "attachmentId","commentId","mimetype","path","rowId","savedViewId",
      "savedViewTableId","savedViewTitle","savedViewType","sha256","size","state","title"
    ] and
    .attachmentCanary.state == "ready" and
    (.attachmentCanary.rowId | type == "string" and length > 0) and
    (.attachmentCanary.savedViewId | type == "string" and length > 0) and
    (.attachmentCanary.savedViewTableId | type == "string" and length > 0) and
    .attachmentCanary.savedViewTableId == $facts_tables[0].id and
    .attachmentCanary.savedViewTitle == "acceptance_facts" and
    .attachmentCanary.savedViewType == 3 and
    (.attachmentCanary.commentId | type == "string" and length > 0) and
    (.attachmentCanary.attachmentId | type == "string" and length > 0) and
    (.attachmentCanary.path | type == "string" and test("^download/issue334_acceptance/recovery-canary-v1/issue334-recovery-canary-v1_[A-Za-z0-9_-]{5}\\.txt$")) and
    .attachmentCanary.title == "issue334-recovery-canary-v1.txt" and
    .attachmentCanary.mimetype == "text/plain" and
    .attachmentCanary.size == 37 and
    .attachmentCanary.sha256 == "09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3"
  ' "$response" >/dev/null
}

probe_one="$temp_dir/probe-one.json"
acceptance_request probe "$probe_one"
validate_probe "$probe_one" "$ready_sync" || {
  echo 'The through-n8n access probe omitted a required success, denial boolean, UI flag, or public-share assertion.' >&2
  exit 1
}
canary_evidence="$run_dir/diagnostics/attachment-canary.json"
base_id="$(jq -r '.baseId' "$ready_sync")"
table_id="$(jq -r '.attachmentCanary.savedViewTableId' "$probe_one")"
jq -n --arg domain issue334_acceptance --arg base_id "$base_id" --arg table_id "$table_id" \
  --slurpfile before "$probe_one" '{
    domain: $domain,
    baseId: $base_id,
    tableId: $table_id,
    beforeRotation: $before[0].attachmentCanary,
    afterRotation: null
  }' >"$canary_evidence"
chmod 600 "$canary_evidence"

unchanged_sync="$temp_dir/source-sync-unchanged.json"
source_request sync "$unchanged_sync"
if ! validate_source_envelope "$unchanged_sync" sync ||
  ! validate_ready_source "$unchanged_sync" reader ||
  ! validate_ready_source "$unchanged_sync" operator; then
  echo 'Unchanged sync omitted complete source evidence.' >&2
  exit 1
fi
stable_source_signature() {
  jq -cS '[
    .baseId,
    (.reader | {sourceId,integrationId,sourceCreateJobId,generation,credentialGeneration}),
    (.operator | {sourceId,integrationId,sourceCreateJobId,generation,credentialGeneration})
  ]' "$1"
}
[[ "$(stable_source_signature "$unchanged_sync")" == "$(stable_source_signature "$ready_sync")" ]] || {
  echo 'Unchanged source sync changed job, source, integration, or generation identity.' >&2
  exit 1
}

rotated_source="$temp_dir/source-rotate-operator.json"
source_request rotate "$rotated_source"
if ! validate_source_envelope "$rotated_source" rotate ||
  ! validate_ready_source "$rotated_source" reader ||
  ! validate_ready_source "$rotated_source" operator; then
  echo 'Operator rotation omitted restored source evidence.' >&2
  exit 1
fi
rotation_stable_signature() {
  jq -cS '[
    .baseId,
    (.reader | {sourceId,integrationId,sourceCreateJobId,generation,credentialGeneration}),
    (.operator | {sourceId,integrationId,sourceCreateJobId})
  ]' "$1"
}
[[ "$(rotation_stable_signature "$rotated_source")" == \
  "$(rotation_stable_signature "$unchanged_sync")" ]] &&
  [[ "$(jq -r '.reader.credentialGeneration' "$rotated_source")" == \
    "$(jq -r '.reader.credentialGeneration' "$unchanged_sync")" ]] &&
  [[ "$(jq -r '.operator.credentialGeneration' "$rotated_source")" -eq \
    "$(( $(jq -r '.operator.credentialGeneration' "$unchanged_sync") + 1 ))" ]] &&
  [[ "$(jq -r '.operator.generation' "$rotated_source")" -gt \
    "$(jq -r '.operator.generation' "$unchanged_sync")" ]] || {
  echo 'Rotation did not change only the operator credential generation.' >&2
  exit 1
}

probe_two="$temp_dir/probe-two.json"
acceptance_request probe "$probe_two"
validate_probe "$probe_two" "$rotated_source" || {
  echo 'The post-rotation through-n8n access probe failed.' >&2
  exit 1
}
updated_canary_evidence="$temp_dir/attachment-canary.json"
jq --slurpfile after "$probe_two" \
  '.afterRotation = $after[0].attachmentCanary' "$canary_evidence" >"$updated_canary_evidence"
chmod 600 "$updated_canary_evidence"
mv "$updated_canary_evidence" "$canary_evidence"
jq -e '.beforeRotation == .afterRotation' "$canary_evidence" >/dev/null || {
  echo 'Operator rotation replaced or changed the durable attachment canary.' >&2
  exit 1
}

write_phase assertion passed 'the fixed NocoDB access contract passed'
echo 'NocoDB attended access acceptance passed; cleanup will remove only current-run rows.'
