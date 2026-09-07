#!/usr/bin/env bash
# Offline command-level tests for the attended NocoDB access scenario.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

scenario='scripts/test/scenarios/nocodb-access.sh'
[[ -x "$scenario" ]] || {
  echo "Missing executable NocoDB access scenario: $scenario" >&2
  exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-access-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/responses"
touch "$fixture/kubeconfig" "$fixture/events.log"

run_id='20260904T120000Z-34b7165a210e-operator-1234abcd'
token_provision='fixture_automation_data_provisioning_0123456789'
token_source='fixture_nocodb_source_provisioning_0123456789'
token_acceptance="fixture_nocodb_acceptance_${run_id:0:16}"

cat >"$fixture/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl\n' >>"${NOCODB_ACCESS_EVENT_LOG:?}"
args=" $* "
if [[ "$args" == *' get lease '* ]]; then
  holder="${TEST_CAMPAIGN_LEASE_HOLDER:-${TEST_RUN_ID:?}}"
  if [[ "${NOCODB_ACCESS_LOSE_LEASE_ON_CLEANUP:-false}" == true &&
    "$(rg -c '^acceptance-probe$' "${NOCODB_ACCESS_EVENT_LOG:?}" || true)" -eq 2 ]]; then
    holder='another-test-run'
  fi
  jq -n --arg holder "$holder" '{
    metadata: {resourceVersion: "7"},
    spec: {
      holderIdentity: $holder,
      leaseDurationSeconds: 90,
      acquireTime: "2099-01-01T00:00:00.000000Z",
      renewTime: "2099-01-01T00:00:00.000000Z"
    }
  }'
elif [[ "$args" == *' get pods '* ]]; then
  case "${NOCODB_ACCESS_BAD_RUNTIME_KIND:-none}" in
    empty) jq -n '{items: []}' ;;
    pod)
      jq -n '{items: [
        {metadata: {name: "nocodb-0", labels: {"app.kubernetes.io/name": "nocodb"}}, spec: {containers: [{name: "nocodb", image: "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9"}]}, status: {phase: "Running", containerStatuses: [{name: "nocodb", ready: true}]}},
        {metadata: {name: "opaque-helper", labels: {component: "alternate"}}, spec: {containers: [{name: "helper", image: "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9"}]}, status: {phase: "Running", containerStatuses: [{name: "helper", ready: true}]}}
      ]}'
      ;;
    *)
      jq -n '{items: [{metadata: {name: "nocodb-0", labels: {"app.kubernetes.io/name": "nocodb"}}, spec: {containers: [{name: "nocodb", image: "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9"}]}, status: {phase: "Running", containerStatuses: [{name: "nocodb", ready: true}]}}]}'
      ;;
  esac
elif [[ "$args" == *' get deployments,statefulsets,daemonsets,jobs,cronjobs '* ]]; then
  case "${NOCODB_ACCESS_BAD_RUNTIME_KIND:-none}" in
    daemonset)
      jq -n '{items: [
        {kind: "Deployment", metadata: {name: "nocodb", labels: {"app.kubernetes.io/name": "nocodb"}}, spec: {replicas: 1, strategy: {type: "Recreate"}, template: {spec: {containers: [{name: "nocodb", image: "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9"}]}}}},
        {kind: "Job", metadata: {name: "nocodb-metadata-bootstrap", labels: {"app.kubernetes.io/name": "nocodb-metadata-bootstrap"}}, spec: {template: {spec: {containers: [{name: "bootstrap", image: "postgres:17.11-alpine3.24"}]}}}},
        {kind: "DaemonSet", metadata: {name: "opaque-runtime", labels: {component: "alternate"}}, spec: {template: {spec: {containers: [{name: "executor", image: "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9"}]}}}}
      ]}'
      ;;
    job)
      jq -n '{items: [
        {kind: "Deployment", metadata: {name: "nocodb", labels: {"app.kubernetes.io/name": "nocodb"}}, spec: {replicas: 1, strategy: {type: "Recreate"}, template: {spec: {containers: [{name: "nocodb", image: "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9"}]}}}},
        {kind: "Job", metadata: {name: "nocodb-metadata-bootstrap", labels: {"app.kubernetes.io/name": "nocodb-metadata-bootstrap"}}, spec: {template: {spec: {containers: [{name: "bootstrap", image: "postgres:17.11-alpine3.24"}]}}}},
        {kind: "Job", metadata: {name: "opaque-cache", labels: {component: "alternate"}}, spec: {template: {spec: {containers: [{name: "cache", image: "docker.io/library/redis:8"}]}}}}
      ]}'
      ;;
    *)
      jq -n '{items: [
        {kind: "Deployment", metadata: {name: "nocodb", labels: {"app.kubernetes.io/name": "nocodb"}}, spec: {replicas: 1, strategy: {type: "Recreate"}, template: {spec: {containers: [{name: "nocodb", image: "docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9", env: [{name: "NC_SITE_URL", value: "https://nocodb.lab.supermorphic.com"}]}]}}}},
        {kind: "Job", metadata: {name: "nocodb-metadata-bootstrap", labels: {"app.kubernetes.io/name": "nocodb-metadata-bootstrap"}}, spec: {template: {spec: {containers: [{name: "bootstrap", image: "postgres:17.11-alpine3.24"}]}}}}
      ]}'
      ;;
  esac
elif [[ "$args" == *' get services '* ]]; then
  if [[ "${NOCODB_ACCESS_BAD_RUNTIME_KIND:-none}" == service ]]; then
    jq -n '{items: [
      {kind: "Service", metadata: {name: "nocodb", labels: {"app.kubernetes.io/name": "nocodb"}}, spec: {type: "ClusterIP", selector: {"app.kubernetes.io/name": "nocodb"}, ports: [{name: "http", port: 8080}]}},
      {kind: "Service", metadata: {name: "opaque-cache", labels: {component: "alternate"}}, spec: {selector: {component: "redis"}}}
    ]}'
  else
    jq -n '{items: [{kind: "Service", metadata: {name: "nocodb", labels: {"app.kubernetes.io/name": "nocodb"}}, spec: {type: "ClusterIP", selector: {"app.kubernetes.io/name": "nocodb"}, ports: [{name: "http", port: 8080}]}}]}'
  fi
elif [[ "$args" == *' config view '* ]]; then
  printf 'fixture-cluster'
else
  echo "Unexpected kubectl invocation: $*" >&2
  exit 65
fi
EOF

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == '--config' && -f "$2" ]] || exit 64
config="$2"
config_dir="$(dirname -- "$config")"
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
[[ "$(mode "$config_dir")" == 700 && "$(mode "$config")" == 600 ]] || exit 65
url="$(awk -F'"' '/^url = / {print $2; exit}' "$config")"
output="$(awk -F'"' '/^output = / {print $2; exit}' "$config")"
body_path="$(awk -F'"' '/^data-binary = / {value=$2; sub(/^@/, "", value); print value; exit}' "$config")"
[[ -n "$url" && -n "$output" && -f "$body_path" && "$(dirname -- "$body_path")" == "$config_dir" ]] || exit 66
[[ "$(mode "$body_path")" == 600 ]] || exit 67
rg -Fxq 'request = "POST"' "$config" || exit 68
rg -Fxq 'header = "Content-Type: application/json"' "$config" || exit 69
rg -Fxq 'max-filesize = 65536' "$config" || exit 81

case "$url" in
  https://n8n.lab.supermorphic.com/webhook/automation-data-provision)
    rg -Fxq "header = \"X-Automation-Data-Provisioning: ${NOCODB_ACCESS_PROVISION_TOKEN:?}\"" "$config" || exit 70
    jq -e '. == {domain: "issue334_acceptance", operation: "provision"}' "$body_path" >/dev/null || exit 71
    event='provision'
    response='provision.json'
    ;;
  https://n8n.lab.supermorphic.com/webhook/automation-data-nocodb-source)
    rg -Fxq "header = \"Authorization: Bearer ${NOCODB_ACCESS_SOURCE_TOKEN:?}\"" "$config" || exit 72
    operation="$(jq -r '.operation' "$body_path")"
    if [[ "$operation" == sync ]]; then
      sync_number="$(($(rg -c '^source-sync$' "${NOCODB_ACCESS_EVENT_LOG:?}" || true) + 1))"
      event='source-sync'
      response="source-sync-${sync_number}.json"
      jq -e '. == {domain: "issue334_acceptance", operation: "sync"}' "$body_path" >/dev/null || exit 73
    elif [[ "$operation" == rotate ]]; then
      event='source-rotate'
      response='source-rotate.json'
      jq -e '. == {domain: "issue334_acceptance", operation: "rotate", accessKind: "operator"}' "$body_path" >/dev/null || exit 74
    else
      exit 75
    fi
    ;;
  https://n8n.lab.supermorphic.com/webhook/nocodb-acceptance-domain)
    rg -Fxq "header = \"Authorization: Bearer ${NOCODB_ACCESS_ACCEPTANCE_TOKEN:?}\"" "$config" || exit 76
    operation="$(jq -r '.operation' "$body_path")"
    jq -e --arg operation "$operation" --arg run_id "${TEST_RUN_ID:?}" \
      '. == {operation: $operation, runId: $run_id}' "$body_path" >/dev/null || exit 77
    case "$operation" in
      structure|grants|cleanup|feedback) event="acceptance-${operation}"; response="acceptance-${operation}.json" ;;
      probe)
        probe_number="$(($(rg -c '^acceptance-probe$' "${NOCODB_ACCESS_EVENT_LOG:?}" || true) + 1))"
        event='acceptance-probe'
        response="acceptance-probe-${probe_number}.json"
        ;;
      *) exit 78 ;;
    esac
    ;;
  https://nocodb.lab.supermorphic.com/api/v1/auth/user/signup)
    [[ ! -s "$body_path" || "$(jq -r '.email // empty' "$body_path")" == 'acceptance-denied@example.invalid' ]] || exit 79
    event='signup-denial'
    response='signup-denial.json'
    ;;
  *) exit 80 ;;
esac

printf '%s\n' "$event" >>"${NOCODB_ACCESS_EVENT_LOG:?}"
if [[ "${NOCODB_ACCESS_OVERSIZE_RESPONSE:-}" == "$event" ]]; then
  dd if=/dev/zero of="$output" bs=65537 count=1 2>/dev/null
  exit 63
fi
cp "${NOCODB_ACCESS_RESPONSES:?}/$response" "$output"
if [[ "$event" == signup-denial ]]; then
  printf '%s' "${NOCODB_ACCESS_SIGNUP_STATUS:-403}"
else
  printf '200'
fi
EOF
chmod 700 "$fixture/bin/git" "$fixture/bin/kubectl" "$fixture/bin/curl"

cat >"$fixture/responses/provision.json" <<'EOF'
{"ok":true,"domain":"issue334_acceptance","operation":"provision","state":"ready","database":"issue334_acceptance","ownerRole":"issue334_acceptance_owner","migratorRole":"issue334_acceptance_migrator","runtimeRole":"issue334_acceptance_runtime","migratorCredentialId":"credential-migrator","runtimeCredentialId":"credential-runtime","migratorCredentialUpdatedAt":"2026-09-04T12:00:00Z","runtimeCredentialUpdatedAt":"2026-09-04T12:00:00Z","passwordsUnchanged":null,"checks":[true,true,true,true,true,true,true,true,true,true,true,true,true,true,true]}
EOF
cat >"$fixture/responses/acceptance-structure.json" <<EOF
{"ok":true,"operation":"structure","runId":"$run_id","domain":"issue334_acceptance","structureReady":true}
EOF
cat >"$fixture/responses/acceptance-grants.json" <<EOF
{"ok":true,"operation":"grants","runId":"$run_id","domain":"issue334_acceptance","grantsReady":true}
EOF
cat >"$fixture/responses/acceptance-cleanup.json" <<EOF
{"ok":true,"operation":"cleanup","runId":"$run_id","domain":"issue334_acceptance","removedCount":2}
EOF
cat >"$fixture/responses/acceptance-feedback.json" <<EOF
{"ok":true,"operation":"feedback","runId":"$run_id","domain":"issue334_acceptance","factId":7000000011,"feedback":{"initialFact":"original","operatorDecision":"corrected","effectiveBeforeRefresh":"corrected","refreshedFact":"refreshed","effectiveAfterRefresh":"corrected"}}
EOF
cat >"$fixture/responses/signup-denial.json" <<'EOF'
{"error":"signup_disabled"}
EOF

source_record() {
  local kind="$1" state="$2" source_id="$3" integration_id="$4" job_id="$5"
  local generation="$6" credential_generation="$7" started="$8" updated="$9" validated="${10}"
  jq -cn --arg kind "$kind" --arg state "$state" --arg source_id "$source_id" \
    --arg integration_id "$integration_id" --arg job_id "$job_id" \
    --argjson generation "$generation" --argjson credential_generation "$credential_generation" \
    --arg started "$started" --arg updated "$updated" --arg validated "$validated" '{
      accessKind: $kind,
      state: $state,
      sourceId: (if $source_id == "" then null else $source_id end),
      integrationId: (if $integration_id == "" then null else $integration_id end),
      generation: $generation,
      credentialGeneration: $credential_generation,
      sourceCreateJobId: (if $job_id == "" then null else $job_id end),
      sourceCreateJobState: (if $job_id == "" then null else "completed" end),
      sourceDiscovered: ($source_id != ""),
      sourceReadBack: ($source_id != ""),
      operationStartedAt: $started,
      updatedAt: $updated,
      validatedAt: (if $validated == "" then null else $validated end),
      dataEditAllowed: (if $state != "ready" then null else $kind == "operator" end),
      schemaEditAllowed: (if $state != "ready" then null else false end),
      postgresqlValidation: (if $state != "ready" then null else {
        valid: true,
        loginValid: true,
        schemaPrivilegesValid: true,
        objectPrivilegesValid: true,
        defaultPrivilegesValid: true,
        outsideSchemaDenied: true,
        databaseIsolationValid: true,
        forbiddenAttributesDenied: true,
        forbiddenMembershipsDenied: true,
        ddlDenied: true,
        controlledDmlPresent: ($kind == "operator")
      } end)
    }'
}

reader_created="$(source_record reader ready source-reader integration-reader job-reader 1 1 \
  2026-09-04T12:01:00Z 2026-09-04T12:02:00Z 2026-09-04T12:02:00Z)"
reader_current="$(jq -c '.sourceCreateJobState = null' <<<"$reader_created")"
operator_waiting="$(source_record operator awaiting_grants '' '' '' 1 0 \
  2026-09-04T12:02:01Z 2026-09-04T12:02:01Z '')"
operator_created="$(source_record operator ready source-operator integration-operator job-operator 1 1 \
  2026-09-04T12:03:00Z 2026-09-04T12:04:00Z 2026-09-04T12:04:00Z)"
operator_current="$(jq -c '.sourceCreateJobState = null' <<<"$operator_created")"
operator_rotated="$(source_record operator ready source-operator integration-operator job-operator 2 2 \
  2026-09-04T12:05:00Z 2026-09-04T12:06:00Z 2026-09-04T12:06:00Z)"
operator_rotated="$(jq -c '.sourceCreateJobState = null' <<<"$operator_rotated")"

jq -n --argjson reader "$reader_created" --argjson operator "$operator_waiting" '{ok:true,domain:"issue334_acceptance",operation:"sync",baseId:"base-acceptance",reader:$reader,operator:$operator,errorCode:null}' >"$fixture/responses/source-sync-1.json"
jq -n --argjson reader "$reader_current" --argjson operator "$operator_created" '{ok:true,domain:"issue334_acceptance",operation:"sync",baseId:"base-acceptance",reader:$reader,operator:$operator,errorCode:null}' >"$fixture/responses/source-sync-2.json"
jq -n --argjson reader "$reader_current" --argjson operator "$operator_current" '{ok:true,domain:"issue334_acceptance",operation:"sync",baseId:"base-acceptance",reader:$reader,operator:$operator,errorCode:null}' >"$fixture/responses/source-sync-3.json"
jq -n --argjson reader "$reader_current" --argjson operator "$operator_rotated" '{ok:true,domain:"issue334_acceptance",operation:"rotate",baseId:"base-acceptance",reader:$reader,operator:$operator,errorCode:null}' >"$fixture/responses/source-rotate.json"

probe_response() {
  jq -n --arg run_id "$run_id" '{
    ok: true,
    operation: "probe",
    runId: $run_id,
    domain: "issue334_acceptance",
    credentialProof: {throughN8n: true, credentialName: "NocoDB Operator API"},
    inserted: true,
    read: true,
    readerRead: true,
    decisionUpdated: true,
    removed: true,
    reflectedSchemas: ["operator", "read_model"],
    reflectedTables: [
      {id:"table-decision",title:"acceptance_decision",tableName:"acceptance_decision",sourceId:"source-operator",schema:"operator"},
      {id:"table-facts",title:"acceptance_facts",tableName:"acceptance_facts",sourceId:"source-reader",schema:"read_model"}
    ],
    publicSharing: {basePublicShareUuid:null,views:[{title:"acceptance_facts",publicShareUuid:null},{title:"acceptance_decision",publicShareUuid:null}]},
    recoveryCanary: {
      version:2,state:"ready",baseId:"base-acceptance",readerSourceId:"source-reader",
      operatorSourceId:"source-operator",factTableId:"table-facts",decisionTableId:"table-decision",
      viewId:"view-facts",rowId:"41",factId:-334,
      artifact:{id:"issue334-artifact-v1",uri:"https://artifacts.example.invalid/issue334/artifact-v1",
        mediaType:"text/plain",sizeBytes:37,sha256:"09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3"}
    },
    forbiddenOperations: {
      protectedUpdateDenied:true,protectedUpdateStatus:400,protectedUpdateEvidence:"postgresql_42501",
      readerInsertDenied:true,readerInsertStatus:403,readerInsertEvidence:"source_read_only"
    }
  }'
}
probe_response >"$fixture/responses/acceptance-probe-1.json"
probe_response >"$fixture/responses/acceptance-probe-2.json"

case_name=''
OUT=''
STATUS=0
run_dir=''
fail() { echo "FAIL [$case_name]: $1" >&2; exit 1; }
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

run_scenario() { # [confirmation|-] [bad-runtime-kind] [signup-status] [oversize-event] [lose-lease-on-cleanup] [omit-binding-confirm] [binding-confirm]
  local confirmation="${1:--}" bad_runtime_kind="${2:-none}" signup_status="${3:-403}"
  local oversize_event="${4:-}" lose_lease_on_cleanup="${5:-false}"
  local omit_binding_confirm="${6:-false}"
  local binding_confirm="${7:-bound:issue334_acceptance:credential-migrator:credential-runtime}"
  local result_root="$fixture/run-$RANDOM-$RANDOM"
  mkdir -p "$result_root/logs" "$result_root/diagnostics"
  run_dir="$result_root/$run_id"
  mv "$result_root/logs" "$result_root/diagnostics" "$run_dir" 2>/dev/null || {
    mkdir -p "$run_dir/logs" "$run_dir/diagnostics"
  }
  : >"$fixture/events.log"
  set +e
  [[ "$omit_binding_confirm" != true ]] || binding_confirm=''
  if [[ "$confirmation" == '-' ]]; then
    OUT="$(PATH="$fixture/bin:$PATH" \
      NOCODB_ACCESS_EVENT_LOG="$fixture/events.log" NOCODB_ACCESS_RESPONSES="$fixture/responses" \
      NOCODB_ACCESS_PROVISION_TOKEN="$token_provision" NOCODB_ACCESS_SOURCE_TOKEN="$token_source" NOCODB_ACCESS_ACCEPTANCE_TOKEN="$token_acceptance" \
      NOCODB_ACCESS_BAD_RUNTIME_KIND="$bad_runtime_kind" NOCODB_ACCESS_SIGNUP_STATUS="$signup_status" \
      NOCODB_ACCESS_OVERSIZE_RESPONSE="$oversize_event" NOCODB_ACCESS_LOSE_LEASE_ON_CLEANUP="$lose_lease_on_cleanup" \
      TEST_RUN_ID="$run_id" HOMELAB_TEST_RUN_DIR="$run_dir" HOMELAB_REPO_ROOT="$repo_root" \
      AUTOMATION_DATA_PROVISIONING_URL='https://n8n.lab.supermorphic.com/webhook/automation-data-provision' \
      AUTOMATION_DATA_PROVISIONING_TOKEN="$token_provision" \
      NOCODB_SOURCE_PROVISIONING_URL='https://n8n.lab.supermorphic.com/webhook/automation-data-nocodb-source' \
      NOCODB_SOURCE_PROVISIONING_TOKEN="$token_source" \
      NOCODB_ACCEPTANCE_URL='https://n8n.lab.supermorphic.com/webhook/nocodb-acceptance-domain' \
      NOCODB_ACCEPTANCE_TOKEN="$token_acceptance" \
      NOCODB_ACCEPTANCE_BINDING_CONFIRM="$binding_confirm" \
      env -u NOCODB_ACCESS_TEST_CONFIRM "$scenario" "$fixture/kubeconfig" 2>&1)"
  else
    OUT="$(PATH="$fixture/bin:$PATH" \
      NOCODB_ACCESS_EVENT_LOG="$fixture/events.log" NOCODB_ACCESS_RESPONSES="$fixture/responses" \
      NOCODB_ACCESS_PROVISION_TOKEN="$token_provision" NOCODB_ACCESS_SOURCE_TOKEN="$token_source" NOCODB_ACCESS_ACCEPTANCE_TOKEN="$token_acceptance" \
      NOCODB_ACCESS_BAD_RUNTIME_KIND="$bad_runtime_kind" NOCODB_ACCESS_SIGNUP_STATUS="$signup_status" \
      NOCODB_ACCESS_OVERSIZE_RESPONSE="$oversize_event" NOCODB_ACCESS_LOSE_LEASE_ON_CLEANUP="$lose_lease_on_cleanup" \
      TEST_RUN_ID="$run_id" HOMELAB_TEST_RUN_DIR="$run_dir" HOMELAB_REPO_ROOT="$repo_root" \
      AUTOMATION_DATA_PROVISIONING_URL='https://n8n.lab.supermorphic.com/webhook/automation-data-provision' \
      AUTOMATION_DATA_PROVISIONING_TOKEN="$token_provision" \
      NOCODB_SOURCE_PROVISIONING_URL='https://n8n.lab.supermorphic.com/webhook/automation-data-nocodb-source' \
      NOCODB_SOURCE_PROVISIONING_TOKEN="$token_source" \
      NOCODB_ACCEPTANCE_URL='https://n8n.lab.supermorphic.com/webhook/nocodb-acceptance-domain' \
      NOCODB_ACCEPTANCE_TOKEN="$token_acceptance" \
      NOCODB_ACCEPTANCE_BINDING_CONFIRM="$binding_confirm" \
      NOCODB_ACCESS_TEST_CONFIRM="$confirmation" "$scenario" "$fixture/kubeconfig" 2>&1)"
  fi
  STATUS=$?
  set -e
}

assert_status() { [[ "$STATUS" -eq "$1" ]] || fail "expected status $1, got $STATUS: $OUT"; }
assert_no_secret_output() {
  for secret in "$token_provision" "$token_source" "$token_acceptance"; do
    ! rg -Fq -- "$secret" <<<"$OUT" || fail 'command output exposed a webhook token'
    ! rg -Fq -- "$secret" "$fixture/events.log" || fail 'event log exposed a webhook token'
  done
}

case_name='exact confirmation precedes cluster and webhook access'
run_scenario -
assert_status 1
[[ ! -s "$fixture/events.log" ]] || fail 'missing confirmation reached kubectl or curl'
assert_no_secret_output

case_name='paired binding guard rejects a missing runtime credential identity'
run_scenario test:nocodb:access none 403 '' false false \
  'bound:issue334_acceptance:credential-migrator:'
assert_status 1
[[ "$(cat "$fixture/events.log")" == $'kubectl\nkubectl\nkubectl\nkubectl\nprovision' ]] ||
  fail 'incomplete paired binding reached the acceptance workflow'
[[ "$OUT" == *'Generated runtime credential ID: credential-runtime'* ]] ||
  fail 'paired binding rejection did not report the expected non-secret runtime ID'
assert_no_secret_output

case_name='first run provisions the synthetic domain before explicit acceptance binding'
run_scenario test:nocodb:access none 403 '' false true
assert_status 1
[[ "$(cat "$fixture/events.log")" == $'kubectl\nkubectl\nkubectl\nkubectl\nprovision' ]] ||
  fail "first-run onboarding reached acceptance before binding: $(tr '\n' ' ' <"$fixture/events.log")"
[[ "$OUT" == *'Generated migrator credential ID: credential-migrator'* ]] ||
  fail 'first-run onboarding omitted the generated migrator credential ID'
[[ "$OUT" == *'Generated runtime credential ID: credential-runtime'* ]] ||
  fail 'first-run onboarding omitted the generated runtime credential ID'
[[ "$OUT" == *"NOCODB_ACCEPTANCE_BINDING_CONFIRM='bound:issue334_acceptance:credential-migrator:credential-runtime'"* ]] ||
  fail 'first-run onboarding omitted the explicit rerun confirmation'
yq -e '.status == "failed"' "$run_dir/assertion.json" >/dev/null ||
  fail 'binding stop was not recorded as an incomplete acceptance run'
yq -e '.status == "not-required"' "$run_dir/cleanup.json" >/dev/null ||
  fail 'binding stop attempted acceptance cleanup before any acceptance mutation'
assert_no_secret_output

case_name='successful acceptance follows the exact lifecycle and writes separate phase evidence'
run_scenario test:nocodb:access
assert_status 0
expected_order=$'kubectl\nkubectl\nkubectl\nkubectl\nprovision\nkubectl\nacceptance-structure\nkubectl\nsource-sync\nkubectl\nacceptance-grants\nkubectl\nsource-sync\nkubectl\nsignup-denial\nkubectl\nacceptance-probe\nkubectl\nacceptance-feedback\nkubectl\nsource-sync\nkubectl\nsource-rotate\nkubectl\nacceptance-probe\nkubectl\nacceptance-cleanup'
[[ "$(cat "$fixture/events.log")" == "$expected_order" ]] || fail "unexpected lifecycle order: $(tr '\n' ' ' <"$fixture/events.log")"
yq -e '.status == "passed" and .reason == "the fixed NocoDB access contract passed"' "$run_dir/assertion.json" >/dev/null || fail 'assertion evidence is not passed'
yq -e '.status == "passed" and .reason == "current-run rows were removed; domain, base, sources, and reserved record canary were retained"' "$run_dir/cleanup.json" >/dev/null || fail 'cleanup evidence is not passed'
yq -e '.status == "not-required"' "$run_dir/recovery.json" >/dev/null || fail 'recovery evidence is not separate'
jq -e '
  (keys | sort) == ["afterRotation","baseId","beforeRotation","domain","factTableId"] and
  .domain == "issue334_acceptance" and .baseId == "base-acceptance" and
  .factTableId == "table-facts" and .beforeRotation == .afterRotation and
  .beforeRotation == {
    version:2,state:"ready",baseId:"base-acceptance",readerSourceId:"source-reader",
    operatorSourceId:"source-operator",factTableId:"table-facts",decisionTableId:"table-decision",
    viewId:"view-facts",rowId:"41",factId:-334,
    artifact:{id:"issue334-artifact-v1",uri:"https://artifacts.example.invalid/issue334/artifact-v1",
      mediaType:"text/plain",sizeBytes:37,sha256:"09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3"}
  }
' "$run_dir/diagnostics/recovery-canary.json" >/dev/null || fail 'durable record-canary evidence is absent or incomplete'
[[ "$(file_mode "$run_dir/diagnostics/recovery-canary.json")" == 600 ]] || fail 'durable record-canary evidence is not mode 0600'
plugin_feedback="$run_dir/diagnostics/feedback.json"
jq -e '
  . == {runId:"20260904T120000Z-34b7165a210e-operator-1234abcd",factId:7000000011,
    feedback:{initialFact:"original",operatorDecision:"corrected",effectiveBeforeRefresh:"corrected",
      refreshedFact:"refreshed",effectiveAfterRefresh:"corrected"}}
' "$plugin_feedback" >/dev/null || fail 'feedback evidence is absent or incomplete'
[[ "$(file_mode "$plugin_feedback")" == 600 ]] || fail 'feedback evidence is not mode 0600'
assert_no_secret_output

case_name='probe reflection must contain exactly the two approved tables'
cp "$fixture/responses/acceptance-probe-1.json" "$fixture/responses/probe.valid.json"
jq '.reflectedTables += [{id:"table-extra"}]' \
  "$fixture/responses/probe.valid.json" >"$fixture/responses/acceptance-probe-1.json"
run_scenario test:nocodb:access
assert_status 1
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'extra reflected table did not clean current-run rows'
mv "$fixture/responses/probe.valid.json" "$fixture/responses/acceptance-probe-1.json"
assert_no_secret_output

case_name='each successful probe must return the complete record canary'
cp "$fixture/responses/acceptance-probe-1.json" "$fixture/responses/probe.valid.json"
jq 'del(.recoveryCanary)' "$fixture/responses/probe.valid.json" >"$fixture/responses/acceptance-probe-1.json"
run_scenario test:nocodb:access
assert_status 1
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'missing canary did not clean current-run rows'
mv "$fixture/responses/probe.valid.json" "$fixture/responses/acceptance-probe-1.json"
assert_no_secret_output

case_name='operator rotation must not replace the durable record canary'
cp "$fixture/responses/acceptance-probe-2.json" "$fixture/responses/probe.valid.json"
jq '.recoveryCanary.rowId = "42"' \
  "$fixture/responses/probe.valid.json" >"$fixture/responses/acceptance-probe-2.json"
run_scenario test:nocodb:access
assert_status 1
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'canary drift did not clean current-run rows'
jq -e '.beforeRotation.rowId == "41" and .afterRotation.rowId == "42"' \
  "$run_dir/diagnostics/recovery-canary.json" >/dev/null || fail 'canary drift was not recorded before rejection'
mv "$fixture/responses/probe.valid.json" "$fixture/responses/acceptance-probe-2.json"
assert_no_secret_output

for forbidden_canary_field in attachmentCanary signedUrl rawBytes author credentials; do
  case_name="record canary rejects forbidden $forbidden_canary_field evidence"
  cp "$fixture/responses/acceptance-probe-1.json" "$fixture/responses/probe.valid.json"
  jq --arg field "$forbidden_canary_field" '.recoveryCanary[$field] = "fixture-forbidden-value"' \
    "$fixture/responses/probe.valid.json" >"$fixture/responses/acceptance-probe-1.json"
  run_scenario test:nocodb:access
  assert_status 1
  yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'forbidden canary evidence did not clean current-run rows'
  mv "$fixture/responses/probe.valid.json" "$fixture/responses/acceptance-probe-1.json"
  assert_no_secret_output
done

case_name='second sync must preserve the first base identity'
cp "$fixture/responses/source-sync-2.json" "$fixture/responses/sync-two.valid.json"
jq '.baseId = "replacement-base"' "$fixture/responses/sync-two.valid.json" >"$fixture/responses/source-sync-2.json"
run_scenario test:nocodb:access
assert_status 1
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'base drift did not clean current-run rows'
mv "$fixture/responses/sync-two.valid.json" "$fixture/responses/source-sync-2.json"
assert_no_secret_output

case_name='second sync must preserve the first reader source identity and generations'
cp "$fixture/responses/source-sync-2.json" "$fixture/responses/sync-two.valid.json"
jq '.reader.sourceId = "replacement-reader" | .reader.generation = 2' \
  "$fixture/responses/sync-two.valid.json" >"$fixture/responses/source-sync-2.json"
run_scenario test:nocodb:access
assert_status 1
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'reader drift did not clean current-run rows'
mv "$fixture/responses/sync-two.valid.json" "$fixture/responses/source-sync-2.json"
assert_no_secret_output

case_name='a false denial boolean cannot be hidden behind a successful webhook'
cp "$fixture/responses/acceptance-probe-1.json" "$fixture/responses/probe.valid.json"
jq '.forbiddenOperations.readerInsertDenied = false' "$fixture/responses/probe.valid.json" >"$fixture/responses/acceptance-probe-1.json"
run_scenario test:nocodb:access
assert_status 1
yq -e '.status == "failed"' "$run_dir/assertion.json" >/dev/null || fail 'failed assertion was not classified'
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'failure did not clean current-run rows'
mv "$fixture/responses/probe.valid.json" "$fixture/responses/acceptance-probe-1.json"
assert_no_secret_output

case_name='feedback must prove the corrected decision survives fact refresh'
cp "$fixture/responses/acceptance-feedback.json" "$fixture/responses/feedback.valid.json"
jq '.feedback.effectiveAfterRefresh = "refreshed"' \
  "$fixture/responses/feedback.valid.json" >"$fixture/responses/acceptance-feedback.json"
run_scenario test:nocodb:access
assert_status 1
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'invalid feedback did not clean current-run rows'
mv "$fixture/responses/feedback.valid.json" "$fixture/responses/acceptance-feedback.json"
assert_no_secret_output

case_name='an accepted HTTP error is not treated as authorization evidence'
cp "$fixture/responses/acceptance-probe-1.json" "$fixture/responses/probe.valid.json"
printf '%s\n' '{"error":"ERR_FORBIDDEN"}' >"$fixture/responses/acceptance-probe-1.json"
run_scenario test:nocodb:access
assert_status 1
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'HTTP-error response did not clean current-run rows'
mv "$fixture/responses/probe.valid.json" "$fixture/responses/acceptance-probe-1.json"
assert_no_secret_output

case_name='rotation must change only the operator credential generation'
cp "$fixture/responses/source-rotate.json" "$fixture/responses/rotate.valid.json"
jq '.reader.credentialGeneration = 2' "$fixture/responses/rotate.valid.json" >"$fixture/responses/source-rotate.json"
run_scenario test:nocodb:access
assert_status 1
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'rotation failure did not clean current-run rows'
mv "$fixture/responses/rotate.valid.json" "$fixture/responses/source-rotate.json"
assert_no_secret_output

for invalid_runtime in empty daemonset job pod service; do
  case_name="runtime inventory rejects $invalid_runtime alternate form"
  run_scenario test:nocodb:access "$invalid_runtime"
  assert_status 1
  [[ "$(rg -c '^provision$' "$fixture/events.log" || true)" -eq 0 ]] || fail 'invalid runtime reached provisioning'
  assert_no_secret_output
done

case_name='cleanup-time Lease loss prevents the cleanup webhook mutation'
run_scenario test:nocodb:access none 403 '' true
assert_status 1
yq -e '.status == "passed"' "$run_dir/assertion.json" >/dev/null || fail 'Lease loss changed the completed primary assertion'
yq -e '.status == "failed"' "$run_dir/cleanup.json" >/dev/null || fail 'Lease loss was not recorded as failed cleanup'
[[ "$(rg -c '^acceptance-cleanup$' "$fixture/events.log" || true)" -eq 0 ]] || fail 'cleanup webhook ran after Lease loss'
assert_no_secret_output

case_name='oversize response fails during bounded curl transfer and still cleans current-run rows'
run_scenario test:nocodb:access none 403 provision
assert_status 63
yq -e '.status == "not-required"' "$run_dir/cleanup.json" >/dev/null || fail 'oversize provisioning response incorrectly ran acceptance cleanup'
assert_no_secret_output

case_name='signup must return an explicit denial status'
run_scenario test:nocodb:access none 200
assert_status 1
yq -e '.status == "passed"' "$run_dir/cleanup.json" >/dev/null || fail 'signup failure did not clean current-run rows'
assert_no_secret_output

case_name='the Just recipe and catalog preserve the guarded coordinator contract'
dry_run="$(mise exec -- just --dry-run kube nocodb-access-test 2>&1)"
rg -Fq 'run-catalog-suite.sh test.nocodb-access -- scripts/test/scenarios/nocodb-access.sh' \
  <<<"$dry_run" || fail 'Just does not dispatch the scenario through the catalog coordinator'
source scripts/test/lib/catalog.sh
entry_json="$(catalog_entry_by_id tests/catalog.yaml test.nocodb-access)"
jq -e '
  .metadata.id == "test.nocodb-access" and
  .metadata.source == "test" and .metadata.framework == "bash" and
  .metadata.suite == "platform" and .metadata.tier == "integration" and
  .metadata.target == "nocodb" and .metadata.scenario == "access" and
  .metadata.scope == "system" and .metadata.intent == "acceptance" and
  .metadata.mutates_cluster == true and .metadata.execution_owner == "human" and
  .confirmation.type == "exact" and
  .confirmation.variable == "NOCODB_ACCESS_TEST_CONFIRM" and
  .confirmation.expected == "test:nocodb:access" and
  .runner.command == "NOCODB_ACCESS_TEST_CONFIRM=test:nocodb:access mise exec -- just kube nocodb-access-test" and
  .runner.implementation == "scripts/test/scenarios/nocodb-access.sh" and
  .native_results.strategy == "wrapper-junit" and
  .dispatch.mode == "direct" and .dispatch.runtime == "bash" and
  .dispatch.path == "scripts/test/scenarios/nocodb-access.sh" and
  .dispatch.args == [".kube/config"] and .dispatch.selector == null
' <<<"$entry_json" >/dev/null || fail 'catalog metadata does not preserve the attended mutation contract'

echo 'NocoDB access command tests passed.'
