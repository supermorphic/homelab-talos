#!/usr/bin/env bash
# Offline transaction tests for the guarded NocoDB bootstrap workflow.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

bootstrap='scripts/nocodb/bootstrap.sh'
if [[ ! -x "$bootstrap" ]]; then
  echo "Missing executable NocoDB bootstrap command: $bootstrap" >&2
  exit 1
fi

bootstrap_recipe="$(mise exec -- just --dry-run bootstrap nocodb 2>&1)" || {
  echo 'Missing bootstrap nocodb recipe.' >&2
  exit 1
}
rg -Fq -- "scripts/nocodb/bootstrap.sh '.kube/config'" <<<"$bootstrap_recipe" || {
  echo 'bootstrap nocodb does not delegate with the scoped kubeconfig.' >&2
  exit 1
}
! rg -n 'jq[^\n]*--arg (password|token)[^\n]*\$(admin_password|nocodb_api_token)' \
  "$bootstrap" >/dev/null || {
  echo 'NocoDB bootstrap places secret material in jq process arguments.' >&2
  exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-bootstrap-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
stub_bin="$fixture/bin"
case_root="$fixture/case"
event_log="$fixture/events.log"
mkdir -p "$stub_bin"

remote_main='0123456789012345678901234567890123456789'
admin_email='operator@example.test'
admin_password='synthetic_admin_password_0123456789'
n8n_api_key='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
jwt='synthetic_nocodb_jwt_0123456789'
nocodb_token='synthetic_nocodb_api_token_0123456789'

export FAKE_NOCODB_EVENT_LOG="$event_log"
export FAKE_REMOTE_MAIN="$remote_main"
export FAKE_ADMIN_EMAIL="$admin_email"
export FAKE_ADMIN_PASSWORD="$admin_password"
export FAKE_N8N_API_KEY="$n8n_api_key"
export FAKE_NOCODB_JWT="$jwt"
export FAKE_NOCODB_TOKEN="$nocodb_token"

cat >"$stub_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$FAKE_NOCODB_EVENT_LOG"
case "$*" in
  'remote get-url origin')
    if [[ "${FAKE_FAILURE:-}" == origin ]]; then
      printf '%s\n' 'https://example.test/not-the-deployed-repository.git'
    else
      printf '%s\n' 'https://github.com/supermorphic/homelab-talos.git'
    fi
    ;;
  'status --porcelain') ;;
  'ls-remote --exit-code origin refs/heads/main')
    printf '%s\trefs/heads/main\n' "$FAKE_REMOTE_MAIN"
    ;;
  "cat-file -e ${FAKE_REMOTE_MAIN}^{commit}"|"cat-file -e origin/main:kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml") ;;
  "diff --quiet ${FAKE_REMOTE_MAIN} --"*)
    count=0
    [[ ! -f "$FAKE_CASE_ROOT/source-check-count" ]] || count="$(<"$FAKE_CASE_ROOT/source-check-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_CASE_ROOT/source-check-count"
    [[ "${FAKE_FAILURE:-}" != source ]] || exit 1
    [[ "${FAKE_FAILURE:-}" != source-recheck || "$count" -lt 2 ]] || exit 1
    ;;
  "rev-parse origin/main") printf '%s\n' "$FAKE_REMOTE_MAIN" ;;
  *)
    echo "unexpected git arguments: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'just %s\n' "$*" >>"$FAKE_NOCODB_EVENT_LOG"
case "$*" in
  'kube nocodb-validate'|'kube flux-verify') ;;
  'kube automation-data-verify')
    count=0
    [[ ! -f "$FAKE_CASE_ROOT/prerequisite-count" ]] || count="$(<"$FAKE_CASE_ROOT/prerequisite-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_CASE_ROOT/prerequisite-count"
    [[ "${FAKE_FAILURE:-}" != prerequisite ]] || exit 70
    [[ "${FAKE_FAILURE:-}" != prerequisite-recheck || "$count" -lt 2 ]] || exit 70
    ;;
  *)
    echo "unexpected just arguments: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$stub_bin/flux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'flux %s\n' "$*" >>"$FAKE_NOCODB_EVENT_LOG"
case "${1:-} ${2:-} ${3:-}" in
  'reconcile kustomization automation-data') ;;
  'resume kustomization nocodb')
    [[ "${FAKE_FAILURE:-}" != resume ]] || exit 71
    ;;
  'reconcile kustomization nocodb')
    [[ "${FAKE_FAILURE:-}" != reconcile ]] || exit 72
    ;;
  'suspend kustomization nocodb')
    [[ "${FAKE_CLEANUP_FAILURE:-false}" != true ]] || exit 73
    ;;
  *)
    echo "unexpected flux arguments: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"$FAKE_NOCODB_EVENT_LOG"

case "$*" in
  *'get gitrepository flux-system --output jsonpath={.status.artifact.revision}')
    printf 'main@sha1:%s' "$FAKE_REMOTE_MAIN"
    ;;
  *'get kustomization nocodb --output jsonpath={.spec.suspend}')
    count=0
    [[ ! -f "$FAKE_CASE_ROOT/suspend-check-count" ]] || count="$(<"$FAKE_CASE_ROOT/suspend-check-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_CASE_ROOT/suspend-check-count"
    if [[ "${FAKE_FAILURE:-}" == live-suspension ||
      ("${FAKE_FAILURE:-}" == live-suspension-recheck && "$count" -ge 3) ]]; then
      printf 'false'
    else
      printf 'true'
    fi
    ;;
  *'get secret nocodb-credentials --output jsonpath={.metadata.name}')
    printf 'nocodb-credentials'
    ;;
  *'wait --for=condition=Ready kustomization/automation-data '*) ;;
  *'get job nocodb-metadata-bootstrap --output json')
    if [[ "${FAKE_FAILURE:-}" == metadata-job ]]; then
      printf '%s\n' '{"status":{"conditions":[{"type":"Failed","status":"True","reason":"SyntheticFailure"}]}}'
    else
      printf '%s\n' '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}'
    fi
    ;;
  *'wait --for=condition=Ready helmrelease/nocodb '*)
    [[ "${FAKE_FAILURE:-}" != helmrelease ]] || exit 74
    ;;
  *'rollout status deployment/nocodb '*)
    [[ "${FAKE_FAILURE:-}" != rollout ]] || exit 75
    ;;
  *'get secret nocodb-credentials --output jsonpath={.data.NC_ADMIN_EMAIL}')
    printf '%s' "$FAKE_ADMIN_EMAIL" | base64
    ;;
  *'get secret nocodb-credentials --output jsonpath={.data.NC_ADMIN_PASSWORD}')
    printf '%s' "$FAKE_ADMIN_PASSWORD" | base64
    ;;
  *)
    echo "unexpected kubectl arguments: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == '--config' && -f "$2" ]] || exit 64
config="$2"
config_dir="$(dirname -- "$config")"
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
[[ "$(mode "$config_dir")" == 700 && "$(mode "$config")" == 600 ]] || exit 65

url="$(awk -F'"' '/^url = / { print $2; exit }' "$config")"
method="$(awk -F'"' '/^request = / { print $2; exit }' "$config")"
output="$(awk -F'"' '/^output = / { print $2; exit }' "$config")"
body="$(awk -F'"' '/^data-binary = / { value=$2; sub(/^@/, "", value); print value; exit }' "$config")"
[[ -n "$url" && -n "$method" && -n "$output" && "$output" == "$config_dir"/* ]] || exit 66
[[ -z "$body" || (-f "$body" && "$(mode "$body")" == 600) ]] || exit 66
rg -Fxq -- 'silent' "$config" && rg -Fxq -- 'show-error' "$config" &&
  rg -Fxq -- 'fail-with-body' "$config" && rg -Fxq -- 'location = false' "$config" &&
  rg -Fxq -- 'max-filesize = 65536' "$config" || exit 67

case "$url" in
  'https://tests.lab.supermorphic.com/api/catalog.json')
    [[ "$method" == GET && -z "$body" ]] || exit 68
    [[ "${FAKE_FAILURE:-}" != evidence ]] || {
      printf '%s\n' '{"schema_version":1,"runs":[]}' >"$output"
      exit 0
    }
    printf '%s\n' "{\"schema_version\":1,\"runs\":[{\"suite\":\"test.automation-data-provisioning\",\"result\":\"passed\",\"authoritative\":true,\"git_sha\":\"$FAKE_REMOTE_MAIN\"},{\"suite\":\"test.automation-data-restore-drill\",\"result\":\"passed\",\"authoritative\":true,\"git_sha\":\"$FAKE_REMOTE_MAIN\"}]}" >"$output"
    ;;
  'https://nocodb.lab.supermorphic.com/api/v1/health')
    [[ "$method" == GET && -z "$body" ]] || exit 69
    [[ "${FAKE_FAILURE:-}" != health ]] || exit 76
    printf '%s\n' '{"message":"OK"}' >"$output"
    ;;
  'https://nocodb.lab.supermorphic.com/api/v1/auth/user/signin')
    [[ "$method" == POST && -f "$body" ]] || exit 70
    jq -e --arg email "$FAKE_ADMIN_EMAIL" --arg password "$FAKE_ADMIN_PASSWORD" \
      '. == {email: $email, password: $password}' "$body" >/dev/null || exit 71
    [[ "${FAKE_FAILURE:-}" != signin ]] || exit 77
    printf '%s\n' "{\"token\":\"$FAKE_NOCODB_JWT\"}" >"$output"
    ;;
  'https://nocodb.lab.supermorphic.com/api/v1/app-settings')
    rg -Fxq -- "header = \"xc-auth: ${FAKE_NOCODB_JWT}\"" "$config" || exit 72
    if [[ "$method" == POST ]]; then
      jq -e '. == {invite_only_signup: true, restrict_workspace_creation: true}' "$body" >/dev/null || exit 73
      [[ "${FAKE_FAILURE:-}" != settings-update ]] || exit 78
      printf '%s\n' '{"invite_only_signup":true,"restrict_workspace_creation":true}' >"$output"
    elif [[ "$method" == GET && -z "$body" ]]; then
      if [[ "${FAKE_FAILURE:-}" == settings-readback ]]; then
        printf '%s\n' '{"invite_only_signup":true,"restrict_workspace_creation":false}' >"$output"
      else
        printf '%s\n' '{"invite_only_signup":true,"restrict_workspace_creation":true}' >"$output"
      fi
    else
      exit 74
    fi
    ;;
  'https://nocodb.lab.supermorphic.com/api/v1/tokens')
    [[ "$method" == POST && -f "$body" ]] || exit 75
    rg -Fxq -- "header = \"xc-auth: ${FAKE_NOCODB_JWT}\"" "$config" || exit 76
    jq -e '. == {description: "NocoDB Operator API"}' "$body" >/dev/null || exit 77
    [[ "${FAKE_FAILURE:-}" != token ]] || exit 79
    printf '%s\n' "{\"id\":\"nocodb-token-id\",\"token\":\"$FAKE_NOCODB_TOKEN\"}" >"$output"
    ;;
  'https://nocodb.lab.supermorphic.com/api/v2/meta/bases')
    [[ "$method" == GET && -z "$body" ]] || exit 78
    rg -Fxq -- "header = \"xc-token: ${FAKE_NOCODB_TOKEN}\"" "$config" || exit 79
    [[ "${FAKE_FAILURE:-}" != token-probe ]] || exit 80
    printf '%s\n' '{"list":[],"pageInfo":{"totalRows":0,"page":1,"pageSize":25,"isFirstPage":true,"isLastPage":true}}' >"$output"
    ;;
  'https://n8n.lab.supermorphic.com/api/v1/credentials')
    [[ "$method" == POST && -f "$body" ]] || exit 81
    rg -Fxq -- "header = \"X-N8N-API-KEY: ${FAKE_N8N_API_KEY}\"" "$config" || exit 82
    jq -e --arg token "$FAKE_NOCODB_TOKEN" \
      '. == {name: "NocoDB Operator API", type: "httpHeaderAuth", data: {name: "xc-token", value: $token}}' \
      "$body" >/dev/null || exit 83
    [[ "${FAKE_FAILURE:-}" != credential ]] || exit 84
    printf '%s\n' '{"id":"credential-id","name":"NocoDB Operator API","type":"httpHeaderAuth"}' >"$output"
    ;;
  'https://n8n.lab.supermorphic.com/api/v1/credentials/credential-id')
    [[ "$method" == GET && -z "$body" ]] || exit 85
    rg -Fxq -- "header = \"X-N8N-API-KEY: ${FAKE_N8N_API_KEY}\"" "$config" || exit 86
    case "${FAKE_FAILURE:-}" in
      credential-readback-id)
        printf '%s\n' '{"id":"other-id","name":"NocoDB Operator API","type":"httpHeaderAuth"}' >"$output"
        ;;
      credential-readback-type)
        printf '%s\n' '{"id":"credential-id","name":"NocoDB Operator API","type":"postgres"}' >"$output"
        ;;
      *)
        printf '%s\n' '{"id":"credential-id","name":"NocoDB Operator API","type":"httpHeaderAuth"}' >"$output"
        ;;
    esac
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 85
    ;;
esac
printf 'curl %s %s\n' "$method" "$url" >>"$FAKE_NOCODB_EVENT_LOG"
EOF
chmod 700 "$stub_bin/git" "$stub_bin/just" "$stub_bin/flux" "$stub_bin/kubectl" "$stub_bin/curl"

case_name=''
OUT=''
STATUS=0

fail() {
  echo "FAIL [$case_name]: $1" >&2
  exit 1
}

write_fixture() {
  rm -rf -- "$case_root"
  mkdir -p \
    "$case_root/.kube" \
    "$case_root/scripts/lib" \
    "$case_root/scripts/nocodb" \
    "$case_root/kubernetes/apps/automation-data/nocodb/app"
  : >"$case_root/.kube/config"
  cp "$repo_root/scripts/lib/rollout.sh" "$case_root/scripts/lib/rollout.sh"
  cp "$repo_root/scripts/nocodb/bootstrap.sh" "$case_root/scripts/nocodb/bootstrap.sh"
  cat >"$case_root/kubernetes/apps/automation-data/nocodb/ks.yaml" <<'EOF'
spec:
  suspend: true
EOF
  cat >"$case_root/kubernetes/apps/automation-data/nocodb/app/kustomization.yaml" <<'EOF'
resources:
  - ./nocodb-credentials.sops.yaml
EOF
  cat >"$case_root/kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: nocodb-credentials
  namespace: automation-data
stringData:
  DATABASE_URL: ENC[synthetic]
  NC_ADMIN_EMAIL: ENC[synthetic]
  NC_ADMIN_PASSWORD: ENC[synthetic]
  NC_AUTH_JWT_SECRET: ENC[synthetic]
  NC_CONNECTION_ENCRYPT_KEY: ENC[synthetic]
  metadata-password: ENC[synthetic]
  source-provisioning-header: ENC[synthetic]
sops:
  age:
    - recipient: age1syntheticfixture000000000000000000000000000000000000000000000000000
EOF
}

run_case() { # <failure|none> <confirmation|exact> <cleanup-failure>
  local failure="$1" confirmation="${2:-exact}" cleanup_failure="${3:-false}"
  : >"$event_log"
  rm -f -- "$case_root/source-check-count" "$case_root/prerequisite-count" \
    "$case_root/suspend-check-count"
  set +e
  if [[ "$confirmation" == exact ]]; then
    OUT="$(cd "$case_root" && PATH="$stub_bin:$PATH" FAKE_CASE_ROOT="$case_root" \
      FAKE_FAILURE="$failure" NOCODB_BOOTSTRAP_CONFIRM='bootstrap:nocodb' \
      FAKE_CLEANUP_FAILURE="$cleanup_failure" N8N_API_KEY="$n8n_api_key" \
      scripts/nocodb/bootstrap.sh .kube/config 2>&1)"
  else
    OUT="$(cd "$case_root" && PATH="$stub_bin:$PATH" FAKE_CASE_ROOT="$case_root" \
      FAKE_FAILURE="$failure" N8N_API_KEY="$n8n_api_key" \
      FAKE_CLEANUP_FAILURE="$cleanup_failure" \
      env -u NOCODB_BOOTSTRAP_CONFIRM scripts/nocodb/bootstrap.sh .kube/config 2>&1)"
  fi
  STATUS=$?
  set -e
}

assert_status() { [[ "$STATUS" -eq "$1" ]] || fail "expected status $1, got $STATUS: $OUT"; }
assert_failure() { [[ "$STATUS" -ne 0 ]] || fail 'expected failure'; }
assert_contains() { rg -Fq -- "$1" <<<"$OUT" || fail "output missing '$1': $OUT"; }
assert_event() { rg -Fq -- "$1" "$event_log" || fail "event log missing '$1'"; }
assert_no_activation() {
  ! rg -q '^flux (reconcile kustomization|resume kustomization)' "$event_log" ||
    fail 'a refused precondition reached activation'
}
assert_no_suspend() {
  ! rg -q '^flux suspend kustomization' "$event_log" ||
    fail 'the command suspended a Kustomization it did not resume'
}
assert_cleanup_suspend() {
  [[ "$(rg -c '^flux suspend kustomization nocodb ' "$event_log")" -eq 1 ]] ||
    fail 'failed activation did not suspend exactly the resumed nocodb Kustomization'
}
assert_no_delete() {
  ! rg -qi '(^| )(delete|DELETE)( |$)' "$event_log" ||
    fail 'bootstrap attempted destructive compensation'
}
assert_no_secret_output() {
  for value in "$admin_password" "$jwt" "$nocodb_token" "$n8n_api_key"; do
    ! rg -Fq -- "$value" <<<"$OUT" || fail 'bootstrap exposed secret material'
  done
}

write_fixture

case_name='exact confirmation is required before mutation'
run_case none missing
assert_failure
assert_contains "NOCODB_BOOTSTRAP_CONFIRM='bootstrap:nocodb'"
assert_no_activation
assert_no_suspend
assert_no_delete
assert_no_secret_output

case_name='issue-317 prerequisite evidence is required'
run_case prerequisite
assert_failure
assert_no_activation
assert_no_suspend
assert_no_delete

case_name='published provisioning and restore evidence is required'
run_case evidence
assert_failure
assert_contains 'provisioning and restore evidence'
assert_no_activation
assert_no_suspend

case_name='source mismatch refuses before mutation'
run_case source
assert_failure
assert_no_activation
assert_no_suspend

case_name='wrong origin refuses before mutation'
run_case origin
assert_failure
assert_contains 'origin must be'
assert_no_activation
assert_no_suspend

case_name='source drift during the immediate recheck refuses before mutation'
run_case source-recheck
assert_failure
assert_no_activation
assert_no_suspend

case_name='prerequisite drift during the immediate recheck refuses before mutation'
run_case prerequisite-recheck
assert_failure
assert_no_activation
assert_no_suspend

case_name='missing encrypted Secret refuses before mutation'
mv "$case_root/kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml" \
  "$case_root/kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml.absent"
run_case none
assert_failure
assert_contains 'encrypted NocoDB Secret'
assert_no_activation
assert_no_suspend
mv "$case_root/kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml.absent" \
  "$case_root/kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml"

case_name='wrong live suspension refuses before mutation'
run_case live-suspension
assert_failure
assert_contains 'not suspended in the live cluster'
assert_no_activation
assert_no_suspend

case_name='live suspension is rechecked immediately before resume'
run_case live-suspension-recheck
assert_failure
assert_contains 'not suspended in the live cluster'
assert_event 'flux reconcile kustomization automation-data '
! rg -q '^flux resume kustomization nocodb ' "$event_log" || fail 'resume ran after suspension drift'
assert_no_suspend

case_name='failed resume does not suspend a Kustomization the command did not resume'
run_case resume
assert_failure
assert_event 'flux resume kustomization nocodb '
assert_no_suspend
assert_no_delete

case_name='failed reconcile re-suspends the Kustomization resumed by this command'
run_case reconcile
assert_failure
assert_cleanup_suspend
assert_no_delete

for failure in metadata-job helmrelease rollout health signin settings-update \
  settings-readback token token-probe credential credential-readback-id \
  credential-readback-type; do
  case_name="failure after resume preserves durable state: $failure"
  run_case "$failure"
  assert_failure
  assert_event 'flux resume kustomization nocodb '
  assert_cleanup_suspend
  assert_no_delete
  assert_no_secret_output
done

case_name='cleanup failure remains visible'
run_case signin exact true
assert_failure
assert_contains 'Failed to re-suspend nocodb'
assert_cleanup_suspend
assert_no_delete

case_name='successful bootstrap probes the token and reads back the fixed credential'
run_case none
assert_status 0
[[ "$OUT" == *'NocoDB Operator API credential ID: credential-id'* ]] ||
  fail "success omitted the non-secret credential ID: $OUT"
assert_event 'curl POST https://nocodb.lab.supermorphic.com/api/v1/app-settings'
assert_event 'curl GET https://nocodb.lab.supermorphic.com/api/v1/app-settings'
assert_event 'curl POST https://nocodb.lab.supermorphic.com/api/v1/tokens'
assert_event 'curl GET https://nocodb.lab.supermorphic.com/api/v2/meta/bases'
assert_event 'curl POST https://n8n.lab.supermorphic.com/api/v1/credentials'
assert_event 'curl GET https://n8n.lab.supermorphic.com/api/v1/credentials/credential-id'
assert_no_suspend
assert_no_delete
assert_no_secret_output

settings_post_line="$(rg -n -m 1 'curl POST https://nocodb.lab.supermorphic.com/api/v1/app-settings' "$event_log" | cut -d: -f1)"
settings_get_line="$(rg -n -m 1 'curl GET https://nocodb.lab.supermorphic.com/api/v1/app-settings' "$event_log" | cut -d: -f1)"
token_line="$(rg -n -m 1 'curl POST https://nocodb.lab.supermorphic.com/api/v1/tokens' "$event_log" | cut -d: -f1)"
probe_line="$(rg -n -m 1 'curl GET https://nocodb.lab.supermorphic.com/api/v2/meta/bases' "$event_log" | cut -d: -f1)"
credential_create_line="$(rg -n -m 1 'curl POST https://n8n.lab.supermorphic.com/api/v1/credentials' "$event_log" | cut -d: -f1)"
credential_read_line="$(rg -n -m 1 'curl GET https://n8n.lab.supermorphic.com/api/v1/credentials/credential-id' "$event_log" | cut -d: -f1)"
[[ "$settings_post_line" -lt "$settings_get_line" && "$settings_get_line" -lt "$token_line" &&
  "$token_line" -lt "$probe_line" && "$probe_line" -lt "$credential_create_line" &&
  "$credential_create_line" -lt "$credential_read_line" ]] ||
  fail 'token creation did not follow settings update and read-back'

echo 'NocoDB guarded bootstrap transaction tests passed.'
