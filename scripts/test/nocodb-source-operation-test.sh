#!/usr/bin/env bash
# Offline contract tests for the guarded NocoDB source lifecycle webhook client.
# A fake curl verifies the request boundary without a cluster or credential.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
export NOCODB_TEST_PERMISSIONS_LIB="$repo_root/scripts/test/lib/nocodb-permissions.sh"

command='scripts/nocodb/source-operation.sh'
[[ -x "$command" ]] || {
  echo "Missing executable NocoDB source operation command: $command" >&2
  exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-source-operation-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
stub_bin="$fixture/bin"
linux_bin="$fixture/linux-bin"
event_log="$fixture/events.log"
mkdir -p "$stub_bin" "$linux_bin"

token='fixture_nocodb_source_provisioning_header_0123456789'
export NOCODB_SOURCE_OPERATION_EVENT_LOG="$event_log"
export NOCODB_SOURCE_OPERATION_TOKEN="$token"

cat >"$linux_bin/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 1 && "$1" == -s ]] || exit 64
printf '%s\n' Linux
EOF

cat >"$linux_bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 3 ]] || exit 64
case "$1:$2" in
  '-f:%Lp')
    printf 'gnu-stat-filesystem-output\n'
    exit 1
    ;;
  '-c:%a')
    if [[ -n "${NOCODB_TEST_STAT_MODE:-}" ]]; then
      printf '%s\n' "$NOCODB_TEST_STAT_MODE"
    elif [[ -d "$3" ]]; then
      printf '%s\n' 700
    else
      printf '%s\n' 600
    fi
    ;;
  *) exit 64 ;;
esac
EOF

cat >"$stub_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git:%s\n' "$1" >>"$NOCODB_SOURCE_OPERATION_EVENT_LOG"
case "$1" in
  status) [[ "${2:-}" == '--porcelain' ]] ;;
  ls-remote)
    [[ "${2:-}" == '--exit-code' && "${3:-}" == origin && "${4:-}" == refs/heads/main ]]
    printf '%s\trefs/heads/main\n' '0123456789012345678901234567890123456789'
    ;;
  cat-file) [[ "${2:-}" == '-e' ]] ;;
  diff) [[ "${2:-}" == '--quiet' ]] ;;
  *) exit 64 ;;
esac
EOF

cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 2 && "$1" == '--config' && -f "$2" ]] || exit 64
config="$2"
config_dir="$(dirname -- "$config")"
source "${NOCODB_TEST_PERMISSIONS_LIB:?}"
[[ "$(nocodb_test_mode "$config_dir")" == 700 ]] || exit 65
[[ "$(nocodb_test_mode "$config")" == 600 ]] || exit 66

url="$(awk -F'"' '/^url = / { print $2; exit }' "$config")"
[[ "$url" == 'https://n8n.lab.supermorphic.com/webhook/automation-data-nocodb-source' ]] || exit 67
rg -Fxq -- 'request = "POST"' "$config" || exit 68
rg -Fxq -- 'max-time = 720' "$config" || exit 69
rg -Fxq -- 'silent' "$config" || exit 70
rg -Fxq -- 'show-error' "$config" || exit 71
rg -Fxq -- "header = \"Authorization: Bearer ${NOCODB_SOURCE_OPERATION_TOKEN}\"" "$config" || exit 72
rg -Fxq -- 'header = "Content-Type: application/json"' "$config" || exit 75

body_path="$(awk -F'"' '/^data-binary = / { value=$2; sub(/^@/, "", value); print value; exit }' "$config")"
[[ -n "$body_path" && -f "$body_path" && "$(dirname -- "$body_path")" == "$config_dir" ]] || exit 73
jq -e --argjson expected "${NOCODB_SOURCE_OPERATION_EXPECTED_BODY:?}" \
  'type == "object" and . == $expected' "$body_path" >/dev/null || exit 74
printf 'curl\n' >>"$NOCODB_SOURCE_OPERATION_EVENT_LOG"

if [[ "${NOCODB_SOURCE_OPERATION_CURL_EXIT:-0}" != 0 ]]; then
  exit "$NOCODB_SOURCE_OPERATION_CURL_EXIT"
fi
printf '%s\n' "${NOCODB_SOURCE_OPERATION_RESPONSE:?}"
EOF
chmod 700 "$stub_bin/git" "$stub_bin/curl" "$linux_bin/uname" "$linux_bin/stat"

case_name=''
OUT=''
STATUS=0
fail() {
  echo "FAIL [$case_name]: $1" >&2
  exit 1
}

run_operation() { # <sync|rotate> <domain> [kind] [confirmation|-] [token] [response] [curl-exit]
  local operation="$1" domain="$2" kind="${3:-}" confirmation="${4:--}"
  local supplied_token="${5:-$token}" response="${6:-$valid_sync_response}" curl_exit="${7:-0}"
  local -a args=("$operation" "$domain")
  [[ -z "$kind" ]] || args+=("$kind")
  : >"$event_log"
  set +e
  if [[ "$operation" == sync ]]; then
    if [[ "$confirmation" == '-' ]]; then
      OUT="$(PATH="$stub_bin:$linux_bin:$PATH" \
        NOCODB_SOURCE_OPERATION_EXPECTED_BODY="$(jq -cn --arg domain "$domain" '{domain: $domain, operation: "sync"}')" \
        NOCODB_SOURCE_OPERATION_RESPONSE="$response" \
        NOCODB_SOURCE_OPERATION_CURL_EXIT="$curl_exit" \
        NOCODB_SOURCE_PROVISIONING_HEADER="$supplied_token" \
        env -u NOCODB_SOURCE_SYNC_CONFIRM "$command" "${args[@]}" 2>&1)"
    else
      OUT="$(PATH="$stub_bin:$linux_bin:$PATH" \
        NOCODB_SOURCE_OPERATION_EXPECTED_BODY="$(jq -cn --arg domain "$domain" '{domain: $domain, operation: "sync"}')" \
        NOCODB_SOURCE_OPERATION_RESPONSE="$response" \
        NOCODB_SOURCE_OPERATION_CURL_EXIT="$curl_exit" \
        NOCODB_SOURCE_PROVISIONING_HEADER="$supplied_token" \
        NOCODB_SOURCE_SYNC_CONFIRM="$confirmation" "$command" "${args[@]}" 2>&1)"
    fi
  else
    if [[ "$confirmation" == '-' ]]; then
      OUT="$(PATH="$stub_bin:$linux_bin:$PATH" \
        NOCODB_SOURCE_OPERATION_EXPECTED_BODY="$(jq -cn --arg domain "$domain" --arg kind "$kind" '{domain: $domain, operation: "rotate", accessKind: $kind}')" \
        NOCODB_SOURCE_OPERATION_RESPONSE="$response" \
        NOCODB_SOURCE_OPERATION_CURL_EXIT="$curl_exit" \
        NOCODB_SOURCE_PROVISIONING_HEADER="$supplied_token" \
        env -u NOCODB_SOURCE_ROTATE_CONFIRM "$command" "${args[@]}" 2>&1)"
    else
      OUT="$(PATH="$stub_bin:$linux_bin:$PATH" \
        NOCODB_SOURCE_OPERATION_EXPECTED_BODY="$(jq -cn --arg domain "$domain" --arg kind "$kind" '{domain: $domain, operation: "rotate", accessKind: $kind}')" \
        NOCODB_SOURCE_OPERATION_RESPONSE="$response" \
        NOCODB_SOURCE_OPERATION_CURL_EXIT="$curl_exit" \
        NOCODB_SOURCE_PROVISIONING_HEADER="$supplied_token" \
        NOCODB_SOURCE_ROTATE_CONFIRM="$confirmation" "$command" "${args[@]}" 2>&1)"
    fi
  fi
  STATUS=$?
  set -e
}

assert_status() { [[ "$STATUS" -eq "$1" ]] || fail "expected status $1, got $STATUS"; }
assert_contains() { rg -Fq -- "$1" <<<"$OUT" || fail "output missing '$1'"; }
assert_no_request() { [[ ! -s "$event_log" ]] || fail 'request precondition invoked git or curl'; }
assert_no_curl() { ! rg -Fxq curl "$event_log" || fail 'invalid input reached curl'; }
assert_no_secret_output() { ! rg -Fq -- "$token" <<<"$OUT" || fail 'output exposed the provisioning token'; }

reader_validation='{"valid":true,"loginValid":true,"schemaPrivilegesValid":true,"objectPrivilegesValid":true,"defaultPrivilegesValid":true,"outsideSchemaDenied":true,"databaseIsolationValid":true,"forbiddenAttributesDenied":true,"forbiddenMembershipsDenied":true,"ddlDenied":true,"controlledDmlPresent":false}'
operator_validation='{"valid":true,"loginValid":true,"schemaPrivilegesValid":true,"objectPrivilegesValid":true,"defaultPrivilegesValid":true,"outsideSchemaDenied":true,"databaseIsolationValid":true,"forbiddenAttributesDenied":true,"forbiddenMembershipsDenied":true,"ddlDenied":true,"controlledDmlPresent":true}'
valid_sync_response="$(jq -cn --argjson reader_validation "$reader_validation" --argjson operator_validation "$operator_validation" '{
  ok:true, domain:"domain_one", operation:"sync", baseId:"base-1",
  reader:{accessKind:"reader",state:"ready",sourceId:"source-reader",integrationId:"integration-reader",sourceCreateJobId:"job-reader",sourceCreateJobState:null,sourceDiscovered:true,sourceReadBack:true,generation:1,credentialGeneration:1,operationStartedAt:"2026-09-04T12:00:00Z",updatedAt:"2026-09-04T12:01:00Z",validatedAt:"2026-09-04T12:01:00Z",dataEditAllowed:false,schemaEditAllowed:false,postgresqlValidation:$reader_validation},
  operator:{accessKind:"operator",state:"ready",sourceId:"source-operator",integrationId:"integration-operator",sourceCreateJobId:"job-operator",sourceCreateJobState:null,sourceDiscovered:true,sourceReadBack:true,generation:1,credentialGeneration:1,operationStartedAt:"2026-09-04T12:02:00Z",updatedAt:"2026-09-04T12:03:00Z",validatedAt:"2026-09-04T12:03:00Z",dataEditAllowed:true,schemaEditAllowed:false,postgresqlValidation:$operator_validation},
  errorCode:null
}')"
valid_rotate_response="$(jq -c '.operation = "rotate" | .operator.generation = 2 | .operator.credentialGeneration = 2' <<<"$valid_sync_response")"

case_name='sync requires an exact confirmation before deployed-source checks'
run_operation sync domain_one '' -
assert_status 1
assert_contains "NOCODB_SOURCE_SYNC_CONFIRM='sync:nocodb:domain_one'"
assert_no_request
assert_no_secret_output

case_name='rotate requires a target-bound exact confirmation'
run_operation rotate domain_one operator 'rotate:nocodb:domain_one:reader'
assert_status 1
assert_contains "NOCODB_SOURCE_ROTATE_CONFIRM='rotate:nocodb:domain_one:operator'"
assert_no_request
assert_no_secret_output

case_name='invalid domain cannot reach curl'
run_operation sync Domain_One '' 'sync:nocodb:Domain_One'
assert_status 2
assert_contains 'domain must match'
assert_no_curl
assert_no_secret_output

case_name='rotate only accepts reader or operator'
run_operation rotate domain_one writer 'rotate:nocodb:domain_one:writer'
assert_status 2
assert_contains 'reader or operator'
assert_no_curl
assert_no_secret_output

case_name='sync rejects an unexpected access-kind argument'
run_operation sync domain_one reader 'sync:nocodb:domain_one'
assert_status 2
assert_contains 'Usage:'
assert_no_curl
assert_no_secret_output

case_name='short token cannot reach curl'
run_operation sync domain_one '' 'sync:nocodb:domain_one' short
assert_status 1
assert_contains 'provisioning header is invalid'
assert_no_curl
assert_no_secret_output

case_name='sync uses the exact body and bounded private request'
run_operation sync domain_one '' 'sync:nocodb:domain_one' "$token" "$valid_sync_response"
assert_status 0
[[ "$(jq -cS . <<<"$OUT")" == "$(jq -cS . <<<"$valid_sync_response")" ]] || fail 'sync did not return the bounded webhook response unchanged'
[[ "$(rg -n -m 1 '^git:' "$event_log" | cut -d: -f1)" -lt "$(rg -n -m 1 '^curl$' "$event_log" | cut -d: -f1)" ]] ||
  fail 'curl ran before deployed-source parity'
assert_no_secret_output

case_name='invalid temporary-file modes remain rejected'
export NOCODB_TEST_STAT_MODE=755
run_operation sync domain_one '' 'sync:nocodb:domain_one' "$token" "$valid_sync_response"
unset NOCODB_TEST_STAT_MODE
assert_status 65
assert_no_secret_output

case_name='rotate uses the exact target body and bounded private request'
run_operation rotate domain_one operator 'rotate:nocodb:domain_one:operator' "$token" "$valid_rotate_response"
assert_status 0
[[ "$(jq -cS . <<<"$OUT")" == "$(jq -cS . <<<"$valid_rotate_response")" ]] || fail 'rotate did not return the bounded webhook response unchanged'
assert_no_secret_output

case_name='the Just sync recipe preserves the guarded command contract'
: >"$event_log"
set +e
OUT="$(PATH="$stub_bin:$linux_bin:$PATH" \
  NOCODB_SOURCE_OPERATION_EXPECTED_BODY='{"domain":"domain_one","operation":"sync"}' \
  NOCODB_SOURCE_OPERATION_RESPONSE="$valid_sync_response" \
  NOCODB_SOURCE_PROVISIONING_HEADER="$token" \
  NOCODB_SOURCE_SYNC_CONFIRM='sync:nocodb:domain_one' \
  mise exec -- just kube nocodb-source-sync domain_one 2>&1)"
STATUS=$?
set -e
assert_status 0
rg -Fxq curl "$event_log" || fail 'Just sync recipe did not invoke the guarded client'
assert_no_secret_output

case_name='the Just rotate recipe preserves the guarded command contract'
: >"$event_log"
set +e
OUT="$(PATH="$stub_bin:$linux_bin:$PATH" \
  NOCODB_SOURCE_OPERATION_EXPECTED_BODY='{"domain":"domain_one","operation":"rotate","accessKind":"operator"}' \
  NOCODB_SOURCE_OPERATION_RESPONSE="$valid_rotate_response" \
  NOCODB_SOURCE_PROVISIONING_HEADER="$token" \
  NOCODB_SOURCE_ROTATE_CONFIRM='rotate:nocodb:domain_one:operator' \
  mise exec -- just kube nocodb-source-rotate domain_one operator 2>&1)"
STATUS=$?
set -e
assert_status 0
rg -Fxq curl "$event_log" || fail 'Just rotate recipe did not invoke the guarded client'
assert_no_secret_output

case_name='curl failure propagates without exposing request material'
run_operation sync domain_one '' 'sync:nocodb:domain_one' "$token" "$valid_sync_response" 28
assert_status 28
assert_no_secret_output

case_name='response with an unready source fails closed'
unready_response="$(jq -c '.reader.state = "provisioning"' <<<"$valid_sync_response")"
run_operation sync domain_one '' 'sync:nocodb:domain_one' "$token" "$unready_response"
assert_status 1
assert_contains 'response did not satisfy the source lifecycle contract'
assert_no_secret_output

case_name='response with a mismatched domain fails closed'
mismatched_domain_response="$(jq -c '.domain = "other_domain"' <<<"$valid_sync_response")"
run_operation sync domain_one '' 'sync:nocodb:domain_one' "$token" "$mismatched_domain_response"
assert_status 1
assert_contains 'response did not satisfy the source lifecycle contract'
assert_no_secret_output

case_name='response with a mismatched operation fails closed'
mismatched_operation_response="$(jq -c '.operation = "rotate"' <<<"$valid_sync_response")"
run_operation sync domain_one '' 'sync:nocodb:domain_one' "$token" "$mismatched_operation_response"
assert_status 1
assert_contains 'response did not satisfy the source lifecycle contract'
assert_no_secret_output

case_name='response with a mismatched reader access kind fails closed'
mismatched_access_kind_response="$(jq -c '.reader.accessKind = "operator" | .operator = null' <<<"$valid_sync_response")"
run_operation sync domain_one '' 'sync:nocodb:domain_one' "$token" "$mismatched_access_kind_response"
assert_status 1
assert_contains 'response did not satisfy the source lifecycle contract'
assert_no_secret_output

case_name='response with duplicate source access kinds fails closed'
duplicate_access_kind_response="$(jq -c '.operator.accessKind = "reader"' <<<"$valid_sync_response")"
run_operation sync domain_one '' 'sync:nocodb:domain_one' "$token" "$duplicate_access_kind_response"
assert_status 1
assert_contains 'response did not satisfy the source lifecycle contract'
assert_no_secret_output

echo 'NocoDB source operation command tests passed.'
