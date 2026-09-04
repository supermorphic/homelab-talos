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
! rg -n 'rev-parse origin/main|require_deployed_source|flux (resume|suspend)' "$bootstrap" >/dev/null || {
  echo 'NocoDB bootstrap uses mutable source resolution or non-owned suspend operations.' >&2
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
  'status --porcelain --untracked-files=no')
    [[ "${FAKE_FAILURE:-}" != tracked-status ]] || printf '%s\n' ' M scripts/lib/omitted-helper.sh'
    ;;
  'ls-remote --exit-code origin refs/heads/main')
    count=0
    [[ ! -f "$FAKE_CASE_ROOT/remote-check-count" ]] || count="$(<"$FAKE_CASE_ROOT/remote-check-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_CASE_ROOT/remote-check-count"
    if [[ "${FAKE_FAILURE:-}" == remote-ref ]]; then
      printf '%s\trefs/heads/main\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    elif [[ "${FAKE_FAILURE:-}" == mutable-remote && "$count" -gt 1 ]]; then
      printf '%s\trefs/heads/main\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    else
      printf '%s\trefs/heads/main\n' "$FAKE_REMOTE_MAIN"
    fi
    ;;
  "cat-file -e ${FAKE_REMOTE_MAIN}^{commit}"|\
  'cat-file -e aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa^{commit}'|\
  "cat-file -e ${FAKE_REMOTE_MAIN}:kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml") ;;
  'rev-parse HEAD')
    if [[ "${FAKE_FAILURE:-}" == local-head ]]; then
      printf '%s\n' 'cccccccccccccccccccccccccccccccccccccccc'
    else
      printf '%s\n' "$FAKE_REMOTE_MAIN"
    fi
    ;;
  "diff --quiet ${FAKE_REMOTE_MAIN} --"*)
    count=0
    [[ ! -f "$FAKE_CASE_ROOT/source-check-count" ]] || count="$(<"$FAKE_CASE_ROOT/source-check-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_CASE_ROOT/source-check-count"
    [[ "${FAKE_FAILURE:-}" != tracked-drift ]] || exit 1
    [[ "${FAKE_FAILURE:-}" != tracked-drift-recheck || "$count" -lt 2 ]] || exit 1
    [[ "${FAKE_FAILURE:-}" != tracked-drift-after-parent || "$count" -lt 3 ]] || exit 1
    ;;
  "diff --cached --quiet ${FAKE_REMOTE_MAIN} --") ;;
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
  'reconcile kustomization nocodb')
    [[ "${FAKE_FAILURE:-}" != reconcile ]] || exit 72
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
    count=0
    [[ ! -f "$FAKE_CASE_ROOT/flux-revision-count" ]] || count="$(<"$FAKE_CASE_ROOT/flux-revision-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_CASE_ROOT/flux-revision-count"
    if [[ "${FAKE_FAILURE:-}" == flux-revision ||
      ("${FAKE_FAILURE:-}" == flux-revision-after-parent && "$count" -ge 3) ]]; then
      printf '%s' 'main@sha1:dddddddddddddddddddddddddddddddddddddddd'
    else
      printf 'main@sha1:%s' "$FAKE_REMOTE_MAIN"
    fi
    ;;
  *'get kustomization nocodb --output json')
    count=0
    [[ ! -f "$FAKE_CASE_ROOT/suspend-check-count" ]] || count="$(<"$FAKE_CASE_ROOT/suspend-check-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_CASE_ROOT/suspend-check-count"
    if [[ "${FAKE_FAILURE:-}" == live-suspension ||
      ("${FAKE_FAILURE:-}" == live-suspension-recheck && "$count" -ge 3) ]]; then
      jq '.spec.suspend = false' "$FAKE_CASE_ROOT/kustomization.json"
    else
      cat "$FAKE_CASE_ROOT/kustomization.json"
    fi
    ;;
  *'replace --filename -')
    incoming="$FAKE_CASE_ROOT/kustomization-incoming.json"
    cat >"$incoming"
    current_rv="$(jq -er '.metadata.resourceVersion' "$FAKE_CASE_ROOT/kustomization.json")"
    incoming_rv="$(jq -er '.metadata.resourceVersion' "$incoming")"
    desired_suspend="$(jq -r '.spec.suspend' "$incoming")"
    desired_owner="$(jq -r '.metadata.annotations["homelab.supermorphic.com/nocodb-bootstrap-owner"] // ""' "$incoming")"
    if [[ "$desired_suspend" == true && "${FAKE_CLEANUP_FAILURE:-false}" == true ]]; then
      exit 73
    fi
    if [[ "$desired_suspend" == true && "${FAKE_FAILURE:-}" == cleanup-concurrent ]]; then
      jq '.metadata.resourceVersion = ((.metadata.resourceVersion | tonumber) + 1 | tostring)' \
        "$FAKE_CASE_ROOT/kustomization.json" >"$FAKE_CASE_ROOT/kustomization-raced.json"
      mv "$FAKE_CASE_ROOT/kustomization-raced.json" "$FAKE_CASE_ROOT/kustomization.json"
      exit 74
    fi
    [[ "$incoming_rv" == "$current_rv" ]] || exit 75
    jq --arg rv "$((current_rv + 1))" '.metadata.resourceVersion = $rv' "$incoming" \
      >"$FAKE_CASE_ROOT/kustomization-next.json"
    mv "$FAKE_CASE_ROOT/kustomization-next.json" "$FAKE_CASE_ROOT/kustomization.json"
    printf 'kubectl-replace suspend=%s owner=%s\n' "$desired_suspend" "$desired_owner" \
      >>"$FAKE_NOCODB_EVENT_LOG"
    if [[ "$desired_suspend" == false && -n "$desired_owner" &&
      "${FAKE_FAILURE:-}" == resume-apply-lost ]]; then
      exit 76
    fi
    cat "$FAKE_CASE_ROOT/kustomization.json"
    ;;
  *'get secret nocodb-credentials --output jsonpath={.metadata.name}')
    printf 'nocodb-credentials'
    ;;
  *'wait --for=condition=Ready kustomization/automation-data '*) ;;
  *'get job nocodb-metadata-bootstrap --output json')
    if [[ "${FAKE_FAILURE:-}" == cleanup-marker-mismatch ]]; then
      jq '.metadata.annotations["homelab.supermorphic.com/nocodb-bootstrap-owner"] = "another-owner"' \
        "$FAKE_CASE_ROOT/kustomization.json" >"$FAKE_CASE_ROOT/kustomization-other.json"
      mv "$FAKE_CASE_ROOT/kustomization-other.json" "$FAKE_CASE_ROOT/kustomization.json"
      printf '%s\n' '{"status":{"conditions":[{"type":"Failed","status":"True","reason":"SyntheticFailure"}]}}'
    elif [[ "${FAKE_FAILURE:-}" == metadata-job || "${FAKE_FAILURE:-}" == cleanup-concurrent ]]; then
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
    provision_end='2026-09-04T10:00:00Z'
    restore_end='2026-09-04T11:00:00Z'
    case "${FAKE_FAILURE:-}" in
      evidence-stale) restore_end='2026-09-04T09:00:00Z' ;;
      evidence-equal) restore_end="$provision_end" ;;
      evidence-invalid-time) restore_end='not-a-timestamp' ;;
    esac
    printf '%s\n' "{\"schema_version\":1,\"runs\":[{\"suite\":\"test.automation-data-provisioning\",\"result\":\"passed\",\"authoritative\":true,\"git_sha\":\"$FAKE_REMOTE_MAIN\",\"end\":\"2026-09-04T08:00:00Z\"},{\"suite\":\"test.automation-data-provisioning\",\"result\":\"passed\",\"authoritative\":true,\"git_sha\":\"$FAKE_REMOTE_MAIN\",\"end\":\"$provision_end\"},{\"suite\":\"test.automation-data-restore-drill\",\"result\":\"passed\",\"authoritative\":true,\"git_sha\":\"$FAKE_REMOTE_MAIN\",\"end\":\"$restore_end\"}]}" >"$output"
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
    rg -Fxq -- "header = \"xc-auth: ${FAKE_NOCODB_JWT}\"" "$config" || exit 76
    if [[ "$method" == POST && -f "$body" ]]; then
      jq -e '. == {description: "NocoDB Operator API"}' "$body" >/dev/null || exit 77
      [[ "${FAKE_FAILURE:-}" != token ]] || exit 79
      count="$(<"$FAKE_CASE_ROOT/token-create-count")"
      printf '%s\n' "$((count + 1))" >"$FAKE_CASE_ROOT/token-create-count"
      jq --arg token "$FAKE_NOCODB_TOKEN" \
        '. + [{id:"nocodb-token-id",description:"NocoDB Operator API",token:$token}]' \
        "$FAKE_CASE_ROOT/tokens.json" >"$FAKE_CASE_ROOT/tokens-next.json"
      mv "$FAKE_CASE_ROOT/tokens-next.json" "$FAKE_CASE_ROOT/tokens.json"
      [[ "${FAKE_FAILURE:-}" != token-create-lost ]] || exit 80
      printf '%s\n' "{\"id\":\"nocodb-token-id\",\"description\":\"NocoDB Operator API\",\"token\":\"$FAKE_NOCODB_TOKEN\"}" >"$output"
    else
      exit 75
    fi
    ;;
  'https://nocodb.lab.supermorphic.com/api/v1/tokens?limit=100&offset=0'|'https://nocodb.lab.supermorphic.com/api/v1/tokens?limit=100&offset=1')
    [[ "$method" == GET && -z "$body" ]] || exit 75
    rg -Fxq -- "header = \"xc-auth: ${FAKE_NOCODB_JWT}\"" "$config" || exit 76
    if [[ "${FAKE_FAILURE:-}" == duplicate-token ]]; then
      if [[ "$url" == *'offset=1' ]]; then
        jq -n --slurpfile tokens "$FAKE_CASE_ROOT/tokens.json" \
          '{list:[$tokens[0][1]],pageInfo:{isLastPage:true,totalRows:2,pageSize:100}}' >"$output"
      else
        jq -n --slurpfile tokens "$FAKE_CASE_ROOT/tokens.json" \
          '{list:[$tokens[0][0]],pageInfo:{isLastPage:false,totalRows:2,pageSize:100}}' >"$output"
      fi
    else
      jq -n --slurpfile tokens "$FAKE_CASE_ROOT/tokens.json" \
        '{list:$tokens[0],pageInfo:{isLastPage:true,totalRows:($tokens[0] | length),pageSize:100}}' \
        >"$output"
    fi
    ;;
  'https://nocodb.lab.supermorphic.com/api/v2/meta/bases')
    [[ "$method" == GET && -z "$body" ]] || exit 78
    rg -Fxq -- "header = \"xc-token: ${FAKE_NOCODB_TOKEN}\"" "$config" || exit 79
    [[ "${FAKE_FAILURE:-}" != token-probe ]] || exit 80
    printf '%s\n' '{"list":[],"pageInfo":{"totalRows":0,"page":1,"pageSize":25,"isFirstPage":true,"isLastPage":true}}' >"$output"
    ;;
  'https://n8n.lab.supermorphic.com/api/v1/credentials')
    rg -Fxq -- "header = \"X-N8N-API-KEY: ${FAKE_N8N_API_KEY}\"" "$config" || exit 82
    if [[ "$method" == POST && -f "$body" ]]; then
      jq -e --arg token "$FAKE_NOCODB_TOKEN" \
        '. == {name: "NocoDB Operator API", type: "httpHeaderAuth", data: {name: "xc-token", value: $token}}' \
        "$body" >/dev/null || exit 83
      [[ "${FAKE_FAILURE:-}" != credential ]] || exit 84
      count="$(<"$FAKE_CASE_ROOT/credential-create-count")"
      printf '%s\n' "$((count + 1))" >"$FAKE_CASE_ROOT/credential-create-count"
      jq '. + [{id:"credential-id",name:"NocoDB Operator API",type:"httpHeaderAuth"}]' \
        "$FAKE_CASE_ROOT/credentials.json" >"$FAKE_CASE_ROOT/credentials-next.json"
      mv "$FAKE_CASE_ROOT/credentials-next.json" "$FAKE_CASE_ROOT/credentials.json"
      [[ "${FAKE_FAILURE:-}" != credential-create-lost ]] || exit 85
      printf '%s\n' '{"id":"credential-id","name":"NocoDB Operator API","type":"httpHeaderAuth"}' >"$output"
    else
      exit 81
    fi
    ;;
  'https://n8n.lab.supermorphic.com/api/v1/credentials?limit=100'|'https://n8n.lab.supermorphic.com/api/v1/credentials?limit=100&cursor=page-two')
    [[ "$method" == GET && -z "$body" ]] || exit 81
    rg -Fxq -- "header = \"X-N8N-API-KEY: ${FAKE_N8N_API_KEY}\"" "$config" || exit 82
    if [[ "${FAKE_FAILURE:-}" == duplicate-credential ]]; then
      if [[ "$url" == *'cursor=page-two' ]]; then
        jq -n --slurpfile data "$FAKE_CASE_ROOT/credentials.json" \
          '{data:[$data[0][1]],nextCursor:null}' >"$output"
      else
        jq -n --slurpfile data "$FAKE_CASE_ROOT/credentials.json" \
          '{data:[$data[0][0]],nextCursor:"page-two"}' >"$output"
      fi
    else
      jq -n --slurpfile data "$FAKE_CASE_ROOT/credentials.json" \
        '{data:$data[0],nextCursor:null}' >"$output"
    fi
    ;;
  'https://n8n.lab.supermorphic.com/api/v1/credentials/'*)
    [[ "$method" == GET && -z "$body" ]] || exit 85
    rg -Fxq -- "header = \"X-N8N-API-KEY: ${FAKE_N8N_API_KEY}\"" "$config" || exit 86
    credential_id="${url##*/}"
    jq -e --arg id "$credential_id" '.[] | select(.id == $id)' \
      "$FAKE_CASE_ROOT/credentials.json" >/dev/null || exit 87
    case "${FAKE_FAILURE:-}" in
      credential-readback-id)
        printf '%s\n' '{"id":"other-id","name":"NocoDB Operator API","type":"httpHeaderAuth"}' >"$output"
        ;;
      credential-readback-type)
        printf '%s\n' '{"id":"credential-id","name":"NocoDB Operator API","type":"postgres"}' >"$output"
        ;;
      *)
        jq -c --arg id "$credential_id" '.[] | select(.id == $id)' \
          "$FAKE_CASE_ROOT/credentials.json" >"$output"
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
  sed -n '1,240p' "$event_log" >&2
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

reset_transaction_state() {
  cat >"$case_root/kustomization.json" <<'EOF'
{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"name":"nocodb","namespace":"flux-system","resourceVersion":"1","annotations":{}},"spec":{"suspend":true}}
EOF
}

reset_api_state() { # <failure>
  local failure="$1"
  printf '%s\n' '[]' >"$case_root/tokens.json"
  printf '%s\n' '[]' >"$case_root/credentials.json"
  printf '%s\n' 0 >"$case_root/token-create-count"
  printf '%s\n' 0 >"$case_root/credential-create-count"
  case "$failure" in
    duplicate-token)
      jq -n --arg token "$nocodb_token" '[
        {id:"token-one",description:"NocoDB Operator API",token:$token},
        {id:"token-two",description:"NocoDB Operator API",token:$token}
      ]' >"$case_root/tokens.json"
      ;;
    duplicate-credential)
      jq -n --arg token "$nocodb_token" '[{id:"token-one",description:"NocoDB Operator API",token:$token}]' \
        >"$case_root/tokens.json"
      printf '%s\n' '[{"id":"credential-one","name":"NocoDB Operator API","type":"httpHeaderAuth"},{"id":"credential-two","name":"NocoDB Operator API","type":"httpHeaderAuth"}]' \
        >"$case_root/credentials.json"
      ;;
    wrong-credential-type)
      jq -n --arg token "$nocodb_token" '[{id:"token-one",description:"NocoDB Operator API",token:$token}]' \
        >"$case_root/tokens.json"
      printf '%s\n' '[{"id":"credential-id","name":"NocoDB Operator API","type":"postgres"}]' \
        >"$case_root/credentials.json"
      ;;
    credential-without-token)
      printf '%s\n' '[{"id":"credential-id","name":"NocoDB Operator API","type":"httpHeaderAuth"}]' \
        >"$case_root/credentials.json"
      ;;
  esac
}

run_case() { # <failure|none> <confirmation|exact> <cleanup-failure> <preserve-api-state>
  local failure="$1" confirmation="${2:-exact}" cleanup_failure="${3:-false}"
  local preserve_api_state="${4:-false}"
  : >"$event_log"
  reset_transaction_state
  [[ "$preserve_api_state" == true ]] || reset_api_state "$failure"
  rm -f -- "$case_root/source-check-count" "$case_root/prerequisite-count" \
    "$case_root/suspend-check-count" "$case_root/remote-check-count" \
    "$case_root/flux-revision-count"
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
  ! rg -q '^flux reconcile kustomization' "$event_log" ||
    fail 'a refused precondition reached activation'
  ! rg -q '^kubectl-replace suspend=false owner=.' "$event_log" ||
    fail 'a refused precondition resumed nocodb'
}
assert_no_suspend() {
  ! rg -q '^kubectl-replace suspend=true ' "$event_log" ||
    fail 'the command suspended a Kustomization it did not resume'
}
assert_cleanup_suspend() {
  [[ "$(rg -c '^kubectl-replace suspend=true owner=' "$event_log")" -eq 1 ]] ||
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

for failure in evidence-stale evidence-equal evidence-invalid-time; do
  case_name="restore evidence must have a valid end newer than provisioning: $failure"
  run_case "$failure"
  assert_failure
  assert_contains 'provisioning and restore evidence'
  assert_no_activation
  assert_no_suspend
done

case_name='drift in any tracked helper refuses before mutation'
run_case tracked-drift
assert_failure
assert_no_activation
assert_no_suspend

case_name='dirty tracked checkout refuses before mutation'
run_case tracked-status
assert_failure
assert_no_activation
assert_no_suspend

case_name='local HEAD must equal the captured remote main commit'
run_case local-head
assert_failure
assert_no_activation
assert_no_suspend

case_name='remote main drift from the local checkout refuses before mutation'
run_case remote-ref
assert_failure
assert_no_activation
assert_no_suspend

case_name='Flux must deploy the captured remote main commit'
run_case flux-revision
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
run_case tracked-drift-recheck
assert_failure
assert_no_activation
assert_no_suspend

case_name='remote main authority is captured once and remains immutable'
run_case mutable-remote
assert_status 0
[[ "$(<"$case_root/remote-check-count")" -eq 1 ]] || fail 'remote main was resolved more than once'
assert_no_suspend

case_name='Flux drift after parent reconcile refuses before resume'
run_case flux-revision-after-parent
assert_failure
assert_event 'flux reconcile kustomization automation-data '
! rg -q '^kubectl-replace suspend=false owner=.' "$event_log" || fail 'resume ran after Flux revision drift'
assert_no_suspend

case_name='tracked checkout drift after parent reconcile refuses before resume'
run_case tracked-drift-after-parent
assert_failure
assert_event 'flux reconcile kustomization automation-data '
! rg -q '^kubectl-replace suspend=false owner=.' "$event_log" || fail 'resume ran after checkout drift'
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
! rg -q '^kubectl-replace suspend=false owner=.' "$event_log" || fail 'resume ran after suspension drift'
assert_no_suspend

case_name='applied resume with a lost response is recovered by owned cleanup'
run_case resume-apply-lost
assert_failure
assert_event 'kubectl-replace suspend=false owner='
assert_cleanup_suspend
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
  assert_event 'kubectl-replace suspend=false owner='
  assert_cleanup_suspend
  assert_no_delete
  assert_no_secret_output
done

case_name='cleanup does not clobber another owner marker'
run_case cleanup-marker-mismatch
assert_failure
assert_contains 'ownership marker changed'
[[ "$(jq -r '.metadata.annotations["homelab.supermorphic.com/nocodb-bootstrap-owner"]' \
  "$case_root/kustomization.json")" == another-owner ]] || fail 'cleanup clobbered another owner marker'
assert_no_suspend

case_name='cleanup resourceVersion conflict remains visible without clobbering state'
run_case cleanup-concurrent
assert_failure
assert_contains 'Failed to restore'
[[ "$(jq -r '.spec.suspend' "$case_root/kustomization.json")" == false ]] || \
  fail 'cleanup clobbered a concurrent Kustomization change'
assert_no_suspend

case_name='cleanup failure remains visible'
run_case signin exact true
assert_failure
assert_contains 'Failed to restore'
[[ "$(jq -r '.spec.suspend' "$case_root/kustomization.json")" == false ]] || \
  fail 'failed cleanup unexpectedly changed the Kustomization'
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

case_name='duplicate NocoDB tokens are refused without creating another token'
run_case duplicate-token
assert_failure
assert_contains 'multiple NocoDB API tokens'
[[ "$(<"$case_root/token-create-count")" -eq 0 ]] || fail 'duplicate-token case created a token'
assert_cleanup_suspend

case_name='duplicate n8n credentials are refused without creating another credential'
run_case duplicate-credential
assert_failure
assert_contains 'multiple n8n credentials'
[[ "$(<"$case_root/credential-create-count")" -eq 0 ]] || fail 'duplicate-credential case created a credential'
assert_cleanup_suspend

case_name='credential without token is refused as inconsistent durable state'
run_case credential-without-token
assert_failure
assert_contains 'credential exists without'
[[ "$(<"$case_root/token-create-count")" -eq 0 ]] || fail 'inconsistent-state case created a token'
assert_cleanup_suspend

case_name='wrong existing credential type is refused'
run_case wrong-credential-type
assert_failure
assert_contains 'unexpected type'
assert_cleanup_suspend

case_name='lost token-create response is retried without a duplicate token'
run_case token-create-lost
assert_failure
[[ "$(jq length "$case_root/tokens.json")" -eq 1 ]] || fail 'first attempt did not retain one token'
run_case none exact false true
assert_status 0
[[ "$(<"$case_root/token-create-count")" -eq 1 ]] || fail 'retry created a duplicate token'
[[ "$(jq length "$case_root/tokens.json")" -eq 1 ]] || fail 'retry retained duplicate tokens'

case_name='lost credential-create response is retried without a duplicate credential'
run_case credential-create-lost
assert_failure
[[ "$(jq length "$case_root/credentials.json")" -eq 1 ]] || fail 'first attempt did not retain one credential'
run_case none exact false true
assert_status 0
[[ "$(<"$case_root/credential-create-count")" -eq 1 ]] || fail 'retry created a duplicate credential'
[[ "$(jq length "$case_root/credentials.json")" -eq 1 ]] || fail 'retry retained duplicate credentials'

echo 'NocoDB guarded bootstrap transaction tests passed.'
