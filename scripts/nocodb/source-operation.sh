#!/usr/bin/env bash
# Invoke the fixed private NocoDB source lifecycle webhook without exposing its header.
set -euo pipefail

usage() {
  echo 'Usage: source-operation.sh <status|prepare|sync|rotate> <domain> [reader|operator]; retry <domain> <reader|operator> <quiesced-operation-id>; configure <domain> <reader-schema> [operator-schema|-]; or pair-register|pair-prepare|pair-sync|pair-rotate|pair-retry <domain> <pair> [schema|access arguments] [quiesced-operation-id]' >&2
  exit 2
}

[[ "$#" -ge 2 && "$#" -le 5 ]] || usage
action="$1"
operation="$action"
domain="$2"
access_kind=''
pair=''
reader_schema=''
operator_schema=''
quiesced_operation_id=''

require_quiesced_operation() {
  quiesced_operation_id="$1"
  [[ "$quiesced_operation_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || usage
  expected_confirmation="${expected_confirmation}:${quiesced_operation_id}:quiesced"
}

[[ "$domain" =~ ^[a-z][a-z0-9_]{0,47}$ ]] || {
  echo 'NocoDB source domain must match ^[a-z][a-z0-9_]{0,47}$.' >&2
  exit 2
}

case "$action" in
status) [[ "$#" -eq 2 ]] || usage ;;
pair-status)
  [[ "$#" -eq 3 ]] || usage
  pair="$3"
  operation=status
  [[ "$pair" =~ ^[a-z][a-z0-9_]{0,23}$ && "$pair" != default ]] || usage
  ;;
  configure)
    [[ "$#" -ge 3 && "$#" -le 4 ]] || usage
    reader_schema="${3:-}"
    operator_schema="${4:--}"
    for schema in "$reader_schema" "$operator_schema"; do
      [[ "$schema" == '-' && "$schema" == "$operator_schema" ]] && continue
      [[ "$schema" =~ ^[a-z][a-z0-9_]{0,47}$ && "$schema" != pg_* && "$schema" != platform* &&
        "$schema" != public && "$schema" != app && "$schema" != read_model &&
        "$schema" != operator && "$schema" != information_schema &&
        "$schema" != platform_internal && "$schema" != platform_operations ]] || usage
    done
    [[ "$reader_schema" != '-' && "$reader_schema" != "$operator_schema" ]] || usage
    expected_confirmation="configure:nocodb:${domain}:${reader_schema}:${operator_schema}"
    [[ "${NOCODB_SOURCE_CONFIGURE_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing NocoDB schema mapping; set NOCODB_SOURCE_CONFIGURE_CONFIRM='$expected_confirmation'." >&2
      exit 1
    }
    ;;
  prepare)
    [[ "$#" -eq 2 ]] || usage
    expected_confirmation="prepare:nocodb:${domain}"
    [[ "${NOCODB_SOURCE_PREPARE_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing NocoDB access preparation; set NOCODB_SOURCE_PREPARE_CONFIRM='$expected_confirmation'." >&2
      exit 1
    }
    ;;
  sync)
    [[ "$#" -eq 2 ]] || usage
    expected_confirmation="sync:nocodb:${domain}"
    [[ "${NOCODB_SOURCE_SYNC_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing NocoDB source sync; set NOCODB_SOURCE_SYNC_CONFIRM='$expected_confirmation'." >&2
      exit 1
    }
    ;;
rotate | retry)
  [[ ("$operation" == rotate && "$#" -eq 3) || ("$operation" == retry && "$#" -eq 4) ]] || usage
    access_kind="$3"
    [[ "$access_kind" == reader || "$access_kind" == operator ]] || {
      echo 'NocoDB source rotation access kind must be reader or operator.' >&2
      exit 2
    }
    expected_confirmation="${operation}:nocodb:${domain}:${access_kind}"
    if [[ "$operation" == retry ]]; then require_quiesced_operation "$4"; fi
    confirmation_variable="NOCODB_SOURCE_${operation^^}_CONFIRM"
    [[ "${!confirmation_variable:-}" == "$expected_confirmation" ]] || {
      echo "Refusing NocoDB source ${operation}; set ${confirmation_variable}='$expected_confirmation'." >&2
      exit 1
    }
    ;;
  pair-register)
    [[ "$#" -eq 5 ]] || usage
    operation=register
    pair="$3"
    reader_schema="$4"
    operator_schema="$5"
    [[ "$pair" =~ ^[a-z][a-z0-9_]{0,23}$ && "$pair" != default ]] || usage
    for schema in "$reader_schema" "$operator_schema"; do
      [[ "$schema" == '-' && "$schema" == "$operator_schema" ]] && continue
      [[ "$schema" =~ ^[a-z][a-z0-9_]{0,47}$ && "$schema" != pg_* && "$schema" != platform* &&
        "$schema" != public && "$schema" != app && "$schema" != read_model &&
        "$schema" != operator && "$schema" != information_schema ]] || usage
    done
    [[ "$reader_schema" != "$operator_schema" ]] || usage
    expected_confirmation="register:nocodb:${domain}:${pair}:${reader_schema}:${operator_schema}"
    [[ "${NOCODB_PAIR_REGISTER_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing NocoDB pair registration; set NOCODB_PAIR_REGISTER_CONFIRM='$expected_confirmation'." >&2
      exit 1
    }
    ;;
pair-prepare | pair-sync | pair-rotate | pair-retry)
  [[ "$#" -eq 3 || ("$action" == pair-rotate && "$#" -eq 4) || ("$action" == pair-retry && "$#" -eq 5) ]] || usage
    pair="$3"
    [[ "$pair" =~ ^[a-z][a-z0-9_]{0,23}$ && "$pair" != default ]] || usage
    operation="${action#pair-}"
    if [[ "$operation" == rotate || "$operation" == retry ]]; then
    [[ ("$operation" == rotate && "$#" -eq 4) || ("$operation" == retry && "$#" -eq 5) ]] || usage
      access_kind="$4"
      [[ "$access_kind" == reader || "$access_kind" == operator ]] || usage
      expected_confirmation="${operation}:nocodb:${domain}:${pair}:${access_kind}"
      if [[ "$operation" == retry ]]; then require_quiesced_operation "$5"; fi
      confirmation_variable="NOCODB_PAIR_${operation^^}_CONFIRM"
    else
      [[ "$#" -eq 3 ]] || usage
      expected_confirmation="${operation}:nocodb:${domain}:${pair}"
      confirmation_variable="NOCODB_PAIR_${operation^^}_CONFIRM"
    fi
    [[ "${!confirmation_variable:-}" == "$expected_confirmation" ]] || {
      echo "Refusing NocoDB pair ${operation}; set ${confirmation_variable}='$expected_confirmation'." >&2
      exit 1
    }
    ;;
  *) usage ;;
esac

source_header="${NOCODB_SOURCE_PROVISIONING_HEADER:-}"
if [[ -z "$source_header" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p 'NocoDB source provisioning header: ' source_header
    printf '\n' >&2
  else
    IFS= read -r source_header || true
  fi
fi
[[ "$source_header" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
  echo 'NocoDB source provisioning header is invalid.' >&2
  exit 1
}

# shellcheck source=scripts/lib/rollout.sh
source scripts/lib/rollout.sh
require_deployed_source "NocoDB source ${operation}" \
  scripts/nocodb/source-operation.sh \
  kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json

webhook_url='https://n8n.lab.supermorphic.com/webhook/automation-data-nocodb-source'

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-source-operation.XXXXXX")"
chmod 700 "$temp_dir"
trap 'rm -rf -- "$temp_dir"' EXIT
request_body="$temp_dir/request.json"
curl_config="$temp_dir/request.curl"

if [[ "$action" == configure ]]; then
  jq -cn --arg domain "$domain" --arg reader "$reader_schema" --arg operator "$operator_schema" \
    '{domain: $domain, operation: "configure", readerSchema: $reader,
      operatorSchema: (if $operator == "-" then null else $operator end)}' >"$request_body"
elif [[ "$action" == pair-register ]]; then
  jq -cn --arg domain "$domain" --arg pair "$pair" --arg reader "$reader_schema" --arg operator "$operator_schema" \
    '{domain: $domain, pair: $pair, operation: "register", readerSchema: $reader,
      operatorSchema: (if $operator == "-" then null else $operator end)}' >"$request_body"
elif [[ "$operation" == rotate || "$operation" == retry ]]; then
  jq -cn --arg domain "$domain" --arg pair "$pair" --arg access_kind "$access_kind" \
    --arg operation "$operation" \
    --arg quiesced "$quiesced_operation_id" \
    '{domain: $domain, operation: $operation, accessKind: $access_kind} +
      (if $pair == "" then {} else {pair: $pair} end) +
      (if $quiesced == "" then {} else {quiescedOperationId: $quiesced} end)' >"$request_body"
else
  jq -cn --arg domain "$domain" --arg pair "$pair" --arg operation "$operation" \
    '{domain: $domain, operation: $operation} +
      (if $pair == "" then {} else {pair: $pair} end)' >"$request_body"
fi

{
  printf '%s\n' 'silent' 'show-error' 'fail-with-body' 'request = "POST"' 'max-time = 720'
  printf 'header = "Authorization: Bearer %s"\n' "$source_header"
  printf '%s\n' 'header = "Content-Type: application/json"'
  printf 'data-binary = "@%s"\n' "$request_body"
  printf 'url = "%s"\n' "$webhook_url"
} >"$curl_config"

set +e
response="$(curl --config "$curl_config")"
curl_status=$?
set -e
[[ "$curl_status" -eq 0 ]] || exit "$curl_status"

if [[ "$operation" == status ]]; then
  jq -e --arg domain "$domain" --arg pair "$pair" '
    .ok == true and .domain == $domain and .operation == "status" and
    (if $pair == "" then has("pair") | not else .pair == $pair end) and
    (keys | sort == (["ok","domain","operation","claim"] + (if $pair == "" then [] else ["pair"] end) | sort)) and
    (.claim == null or (.claim |
      (keys | sort == ["accessKind","generation","operation","operationId","phase"]) and
      (.operationId | type == "string" and test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")) and
      (.phase == "active" or .phase == "uncertain" or .phase == "complete") and
      (.operation == "sync" or .operation == "rotate") and
      (.accessKind == null or .accessKind == "reader" or .accessKind == "operator") and
      (.generation | type == "number" and . >= 1 and . == floor)))
  ' <<<"$response" >/dev/null || {
    echo "NocoDB operation status response is invalid." >&2
    exit 1
  }
elif [[ "$action" == configure ]]; then
  jq -e --arg domain "$domain" --arg reader "$reader_schema" --arg operator "$operator_schema" '
    type == "object" and
    (keys | sort == ["domain", "ok", "operation", "operatorRole", "operatorSchema", "readerRole", "readerSchema", "state"]) and
    .ok == true and .domain == $domain and .operation == "configure" and .state == "configured" and
    .readerSchema == $reader and .readerRole == ($domain + "_reader") and
    (if $operator == "-" then .operatorSchema == null and .operatorRole == null
     else .operatorSchema == $operator and .operatorRole == ($domain + "_operator") end)
  ' <<<"$response" >/dev/null || {
    echo 'NocoDB source response did not satisfy the schema mapping contract.' >&2
    exit 1
  }
elif [[ "$action" == pair-register ]]; then
  jq -e --arg domain "$domain" --arg pair "$pair" --arg reader "$reader_schema" --arg operator "$operator_schema" '
    type == "object" and
    (keys | sort == ["domain", "ok", "operation", "operatorRole", "operatorSchema", "pair", "readerRole", "readerSchema", "state"]) and
    .ok == true and .domain == $domain and .pair == $pair and
    .operation == "register" and .state == "registered" and
    .readerSchema == $reader and
    (.readerRole | type == "string" and test("^nocodb_[a-f0-9]{32}_reader$")) and
    (if $operator == "-" then .operatorSchema == null and .operatorRole == null
     else .operatorSchema == $operator and
       (.operatorRole | type == "string" and test("^nocodb_[a-f0-9]{32}_operator$")) end)
  ' <<<"$response" >/dev/null || {
    echo 'NocoDB pair registration response did not satisfy its contract.' >&2
    exit 1
  }
elif [[ "$operation" == prepare ]]; then
  jq -e --arg domain "$domain" --arg pair "$pair" '
    type == "object" and
    (keys | sort == (["domain", "ok", "operation", "operatorEligible", "operatorRequested", "operatorRole",
      "readerEligible", "readerRole", "state"] + (if $pair == "" then [] else ["pair"] end) | sort)) and
    .ok == true and .domain == $domain and .operation == "prepare" and .state == "prepared" and
    (if $pair == "" then .readerRole == ($domain + "_reader") and .readerEligible == true
     else .pair == $pair and (.readerRole | type == "string" and test("^nocodb_[a-f0-9]{32}_reader$")) and
       (.readerEligible | type == "boolean") end) and
    (.operatorRequested | type == "boolean") and (.operatorEligible | type == "boolean") and
    (if .operatorRequested then
      (if $pair == "" then .operatorRole == ($domain + "_operator")
       else (.operatorRole | type == "string" and test("^nocodb_[a-f0-9]{32}_operator$")) end)
    else
      .operatorRole == null and .operatorEligible == false
    end)
  ' <<<"$response" >/dev/null || {
    echo 'NocoDB source response did not satisfy the prepare contract.' >&2
    exit 1
  }
else
  response_operation="$operation"
  [[ "$operation" != retry ]] || response_operation=rotate
  jq -e --arg domain "$domain" --arg pair "$pair" --arg operation "$response_operation" '
  type == "object" and
  (keys | sort == (["baseId", "domain", "errorCode", "ok", "operation", "operator", "reader"] +
    (if $pair == "" then [] else ["pair"] end) | sort)) and
  .ok == true and
  .domain == $domain and
  (if $pair == "" then true else .pair == $pair end) and
  .operation == $operation and
  (.baseId | type == "string" and length > 0) and
  .errorCode == null and
  (.reader | type == "object") and
  ([.reader, .operator] | map(select(. != null))) as $sources |
  ($sources | length >= 1) and
  ($sources | all(
    type == "object" and
    (keys | sort == [
      "accessKind", "credentialGeneration", "dataEditAllowed", "generation", "integrationId",
      "operationStartedAt", "postgresqlValidation", "schemaEditAllowed", "sourceCreateJobId",
      "sourceCreateJobState", "sourceDiscovered", "sourceId", "sourceReadBack", "state",
      "updatedAt", "validatedAt"
    ]) and
    (.accessKind == "reader" or .accessKind == "operator") and
    (.state == "ready" or .state == "awaiting_grants") and
    (.generation | type == "number") and
    (.credentialGeneration | type == "number") and
    (.sourceId | . == null or type == "string") and
    (.integrationId | . == null or type == "string") and
    (.sourceCreateJobId | . == null or type == "string") and
    (.sourceCreateJobState | . == null or . == "completed") and
    (.sourceDiscovered | type == "boolean") and
    (.sourceReadBack | type == "boolean") and
    (.operationStartedAt | type == "string" and length > 0) and
    (.updatedAt | type == "string" and length > 0) and
    (.validatedAt | . == null or (type == "string" and length > 0)) and
    (.dataEditAllowed | . == null or type == "boolean") and
    (.schemaEditAllowed | . == null or type == "boolean") and
    (if .state == "ready" then
      (.sourceId | type == "string" and length > 0) and
      (.integrationId | type == "string" and length > 0) and
      (.sourceCreateJobId | type == "string" and length > 0) and
      .sourceDiscovered == true and .sourceReadBack == true and
      (.validatedAt | type == "string" and length > 0) and
      (.dataEditAllowed == (.accessKind == "operator")) and
      .schemaEditAllowed == false and
      (.postgresqlValidation | type == "object") and
      (.postgresqlValidation | keys | sort == [
        "controlledDmlPresent", "databaseIsolationValid", "ddlDenied", "defaultPrivilegesValid",
        "forbiddenAttributesDenied", "forbiddenMembershipsDenied", "loginValid", "objectPrivilegesValid",
        "outsideSchemaDenied", "schemaPrivilegesValid", "valid"
      ]) and
      (.postgresqlValidation | to_entries | all(.value | type == "boolean")) and
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
      (.postgresqlValidation.controlledDmlPresent == (.accessKind == "operator"))
    else
      .accessKind == "operator" and
      .sourceId == null and .integrationId == null and .sourceCreateJobId == null and
      .sourceCreateJobState == null and .sourceDiscovered == false and .sourceReadBack == false and
      .credentialGeneration == 0 and .validatedAt == null and .dataEditAllowed == null and
      .schemaEditAllowed == null and .postgresqlValidation == null
    end)
  )) and
  ($sources | map(.accessKind)) as $access_kinds |
  (($access_kinds | unique | length) == ($access_kinds | length)) and
  (.reader.accessKind == "reader") and
  (.operator == null or .operator.accessKind == "operator")
  ' <<<"$response" >/dev/null || {
    echo 'NocoDB source response did not satisfy the source lifecycle contract.' >&2
    exit 1
  }
fi

printf '%s\n' "$response"
