#!/usr/bin/env bash
# Invoke the fixed private NocoDB source lifecycle webhook without exposing its header.
set -euo pipefail

usage() {
  echo 'Usage: source-operation.sh <sync|rotate> <domain> [reader|operator]' >&2
  exit 2
}

[[ "$#" -ge 2 && "$#" -le 3 ]] || usage
operation="$1"
domain="$2"
access_kind="${3:-}"

[[ "$domain" =~ ^[a-z][a-z0-9_]{0,47}$ ]] || {
  echo 'NocoDB source domain must match ^[a-z][a-z0-9_]{0,47}$.' >&2
  exit 2
}

case "$operation" in
  sync)
    [[ -z "$access_kind" ]] || usage
    expected_confirmation="sync:nocodb:${domain}"
    [[ "${NOCODB_SOURCE_SYNC_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing NocoDB source sync; set NOCODB_SOURCE_SYNC_CONFIRM='$expected_confirmation'." >&2
      exit 1
    }
    ;;
  rotate)
    [[ "$access_kind" == reader || "$access_kind" == operator ]] || {
      echo 'NocoDB source rotation access kind must be reader or operator.' >&2
      exit 2
    }
    expected_confirmation="rotate:nocodb:${domain}:${access_kind}"
    [[ "${NOCODB_SOURCE_ROTATE_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing NocoDB source rotation; set NOCODB_SOURCE_ROTATE_CONFIRM='$expected_confirmation'." >&2
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

if [[ "$operation" == sync ]]; then
  jq -cn --arg domain "$domain" '{domain: $domain, operation: "sync"}' >"$request_body"
else
  jq -cn --arg domain "$domain" --arg access_kind "$access_kind" \
    '{domain: $domain, operation: "rotate", accessKind: $access_kind}' >"$request_body"
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

jq -e --arg domain "$domain" --arg operation "$operation" '
  type == "object" and
  (keys | sort == ["baseId", "domain", "errorCode", "ok", "operation", "operator", "reader"]) and
  .ok == true and
  .domain == $domain and
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

printf '%s\n' "$response"
