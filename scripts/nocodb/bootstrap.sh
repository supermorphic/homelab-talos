#!/usr/bin/env bash
# Perform the guarded first activation of NocoDB and bind its API token to n8n.
set -euo pipefail
set +x

[[ "$#" -eq 1 ]] || {
  echo 'Usage: bootstrap.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
expected_origin='https://github.com/supermorphic/homelab-talos.git'
expected_confirmation='bootstrap:nocodb'
nocodb_url='https://nocodb.lab.supermorphic.com'
n8n_url='https://n8n.lab.supermorphic.com'
reports_url='https://tests.lab.supermorphic.com/api/catalog.json'
nocodb_ks='kubernetes/apps/automation-data/nocodb/ks.yaml'
nocodb_app='kubernetes/apps/automation-data/nocodb/app'
secret="$nocodb_app/nocodb-credentials.sops.yaml"
secret_resource='./nocodb-credentials.sops.yaml'
n8n_api_key="${N8N_API_KEY:-}"
bootstrap_complete=false
resumed_nocodb=false
temp_dir=''
request_number=0

cleanup_nocodb_bootstrap() {
  local original_exit="$?" cleanup_failed=false
  trap - EXIT
  set +e
  if [[ "$bootstrap_complete" != true && "$resumed_nocodb" == true ]]; then
    echo 'NocoDB bootstrap did not pass; re-suspending nocodb while preserving its resources and API state.' >&2
    flux suspend kustomization nocodb --namespace flux-system \
      --kubeconfig "$kubeconfig" >/dev/null || cleanup_failed=true
  fi
  if [[ -n "$temp_dir" ]]; then
    rm -rf -- "$temp_dir" || cleanup_failed=true
    [[ ! -e "$temp_dir" ]] || cleanup_failed=true
  fi
  set -e
  if [[ "$cleanup_failed" == true ]]; then
    echo 'Failed to re-suspend nocodb or remove its secret-bearing temporary files.' >&2
    exit 1
  fi
  exit "$original_exit"
}
trap cleanup_nocodb_bootstrap EXIT

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}
[[ "$n8n_api_key" =~ ^[A-Za-z0-9._-]{32,}$ ]] || {
  echo 'Set N8N_API_KEY to the private full-access n8n API key.' >&2
  exit 1
}
[[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
  echo "Refusing NocoDB bootstrap: origin must be $expected_origin." >&2
  exit 1
}

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-bootstrap.XXXXXX")"
chmod 700 "$temp_dir"

# shellcheck source=scripts/lib/rollout.sh
source scripts/lib/rollout.sh

require_source_parity() {
  require_deployed_source 'NocoDB bootstrap' \
    .just/bootstrap.just \
    scripts/nocodb/bootstrap.sh \
    scripts/validate/nocodb.sh \
    tests/catalog.yaml \
    kubernetes/apps/automation-data/nocodb \
    kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json \
    scripts/verify/automation-data.sh \
    scripts/test/scenarios/automation-data-provisioning.sh \
    scripts/test/scenarios/automation-data-restore-drill.sh
}

require_secret_contract() {
  [[ -f "$secret" ]] || {
    echo "Refusing NocoDB bootstrap: the encrypted NocoDB Secret is absent: $secret." >&2
    return 1
  }
  git cat-file -e "origin/main:$secret" 2>/dev/null || {
    echo 'Refusing NocoDB bootstrap: the encrypted NocoDB Secret is not deployed on origin/main.' >&2
    return 1
  }
  SECRET_RESOURCE="$secret_resource" yq -e '
    (.resources | type) == "!!seq" and
    (.resources | any_c(. == strenv(SECRET_RESOURCE)))
  ' "$nocodb_app/kustomization.yaml" >/dev/null || {
    echo 'Refusing NocoDB bootstrap: the encrypted NocoDB Secret is not selected by its Kustomization.' >&2
    return 1
  }
  if ! {
    [[ "$(yq -r '[.apiVersion, .kind, .metadata.name, .metadata.namespace] | join(",")' \
      "$secret")" == 'v1,Secret,nocodb-credentials,automation-data' &&
      "$(yq -r '.stringData | keys | sort | join(",")' "$secret")" == \
        'DATABASE_URL,NC_ADMIN_EMAIL,NC_ADMIN_PASSWORD,NC_AUTH_JWT_SECRET,NC_CONNECTION_ENCRYPT_KEY,metadata-password,source-provisioning-header' &&
      "$(yq -r '.sops.age | length' "$secret")" -gt 0 ]] &&
      ! yq -r '.stringData[]' "$secret" | rg -v '^ENC\[' >/dev/null
  }; then
    echo 'Refusing NocoDB bootstrap: the deployed NocoDB Secret shape or encryption metadata is invalid.' >&2
    return 1
  fi
}

require_deployed_revision() {
  local remote_main deployed_revision
  remote_main="$(git rev-parse origin/main)"
  deployed_revision="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
    get gitrepository flux-system --output jsonpath='{.status.artifact.revision}')"
  [[ "$deployed_revision" == *"$remote_main"* ]] || {
    echo "Refusing NocoDB bootstrap: Flux revision $deployed_revision does not match origin/main $remote_main." >&2
    return 1
  }
}

require_live_suspension() {
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
    get kustomization nocodb --output jsonpath='{.spec.suspend}')" == true ]] || {
    echo 'Refusing NocoDB bootstrap: nocodb is not suspended in the live cluster.' >&2
    return 1
  }
}

curl_request() { # <label> <method> <url> <auth:none|jwt|n8n|token> <body-or-empty> <output>
  local label="$1" method="$2" url="$3" auth="$4" body="$5" output="$6"
  local config="$temp_dir/request-$request_number.curl" status size
  request_number=$((request_number + 1))
  {
    printf '%s\n' \
      'silent' \
      'show-error' \
      'fail-with-body' \
      'location = false' \
      'connect-timeout = 10' \
      'max-time = 60' \
      'max-filesize = 65536' \
      'proto = "=https"'
    printf 'request = "%s"\n' "$method"
    printf 'url = "%s"\n' "$url"
    printf 'output = "%s"\n' "$output"
    case "$auth" in
      none) ;;
      jwt) printf 'header = "xc-auth: %s"\n' "$session_jwt" ;;
      n8n) printf 'header = "X-N8N-API-KEY: %s"\n' "$n8n_api_key" ;;
      token) printf 'header = "xc-token: %s"\n' "$nocodb_api_token" ;;
      *) return 64 ;;
    esac
    if [[ -n "$body" ]]; then
      printf '%s\n' 'header = "Content-Type: application/json"'
      printf 'data-binary = "@%s"\n' "$body"
    fi
  } >"$config"

  set +e
  curl --config "$config"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || {
    echo "$label failed." >&2
    return "$status"
  }
  [[ -f "$output" ]] || {
    echo "$label returned no response." >&2
    return 1
  }
  size="$(wc -c <"$output" | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 65536 ]] || {
    echo "$label exceeded the bounded response size." >&2
    return 1
  }
}

require_attended_evidence() {
  local evidence="$temp_dir/evidence-$request_number.json"
  local remote_main
  remote_main="$(git rev-parse origin/main)"
  curl_request 'Automation-data evidence query' GET "$reports_url" none '' "$evidence"
  jq -e --arg revision "$remote_main" '
    .schema_version == 1 and
    (.runs | type == "array") and
    ([.runs[] | select(
      .suite == "test.automation-data-provisioning" and
      .result == "passed" and
      .authoritative == true and
      .git_sha == $revision
    )] | length >= 1) and
    ([.runs[] | select(
      .suite == "test.automation-data-restore-drill" and
      .result == "passed" and
      .authoritative == true and
      .git_sha == $revision
    )] | length >= 1)
  ' "$evidence" >/dev/null || {
    echo 'Refusing NocoDB bootstrap: current authoritative automation-data provisioning and restore evidence is absent.' >&2
    return 1
  }
}

require_preconditions() {
  [[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
    echo "Refusing NocoDB bootstrap: origin must be $expected_origin." >&2
    return 1
  }
  require_source_parity
  [[ "$(yq -r '.spec.suspend' "$nocodb_ks")" == true ]] || {
    echo 'Refusing NocoDB bootstrap: nocodb must be staged suspended in Git.' >&2
    return 1
  }
  just kube nocodb-validate
  require_secret_contract
  require_deployed_revision
  require_live_suspension
  just kube automation-data-verify
  require_attended_evidence
}

wait_for_metadata_job() {
  local deadline=$((SECONDS + 900)) state
  while (( SECONDS < deadline )); do
    state="$(kubectl --kubeconfig "$kubeconfig" --namespace automation-data \
      get job nocodb-metadata-bootstrap --output json)" || return 1
    if [[ "$(jq -r '[.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length' <<<"$state")" == 1 ]]; then
      return 0
    fi
    if [[ "$(jq -r '[.status.conditions[]? | select(.type == "Failed" and .status == "True")] | length' <<<"$state")" == 1 ]]; then
      echo 'NocoDB metadata bootstrap Job failed.' >&2
      return 1
    fi
    sleep 5
  done
  echo 'NocoDB metadata bootstrap Job did not reach a terminal condition.' >&2
  return 1
}

# The first pass is reviewable preflight. The second pass is the immediate check before
# the first mutation; neither pass resumes or reconciles a Kustomization.
require_preconditions
[[ "${NOCODB_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo 'Refusing to activate and initialize NocoDB.' >&2
  echo "Set NOCODB_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing the staged package and prerequisite evidence." >&2
  exit 1
}
require_preconditions

echo 'Reconciling the automation-data parent before NocoDB activation.' >&2
flux reconcile kustomization automation-data --namespace flux-system --with-source \
  --kubeconfig "$kubeconfig" --timeout 10m
kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
  --for=condition=Ready kustomization/automation-data --timeout=10m

# The parent reconcile can advance the source. Bind the resume to the same deployed
# origin/main and repeat the target suspension check immediately before it changes.
require_deployed_revision
require_live_suspension

echo 'Resuming and reconciling the staged NocoDB package.' >&2
flux resume kustomization nocodb --namespace flux-system --kubeconfig "$kubeconfig"
resumed_nocodb=true
flux reconcile kustomization nocodb --namespace flux-system --with-source \
  --kubeconfig "$kubeconfig" --timeout 15m

wait_for_metadata_job
kubectl --kubeconfig "$kubeconfig" --namespace automation-data wait \
  --for=condition=Ready helmrelease/nocodb --timeout=15m
kubectl --kubeconfig "$kubeconfig" --namespace automation-data rollout status \
  deployment/nocodb --timeout=15m

health_response="$temp_dir/health.json"
curl_request 'NocoDB health check' GET "$nocodb_url/api/v1/health" none '' "$health_response"
jq -e '.message == "OK"' "$health_response" >/dev/null || {
  echo 'NocoDB health response did not satisfy the fixed contract.' >&2
  exit 1
}

# Read only the two administrator fields required for sign-in. Keep all authentication
# material in shell memory or mode-0600 request/configuration files.
set +x
admin_email="$(kubectl --kubeconfig "$kubeconfig" --namespace automation-data \
  get secret nocodb-credentials --output jsonpath='{.data.NC_ADMIN_EMAIL}' | base64 --decode)"
admin_password="$(kubectl --kubeconfig "$kubeconfig" --namespace automation-data \
  get secret nocodb-credentials --output jsonpath='{.data.NC_ADMIN_PASSWORD}' | base64 --decode)"
[[ -n "$admin_email" && -n "$admin_password" ]] || {
  echo 'NocoDB administrator fields are absent.' >&2
  exit 1
}

signin_body="$temp_dir/signin.json"
signin_response="$temp_dir/signin-response.json"
ADMIN_EMAIL="$admin_email" ADMIN_PASSWORD="$admin_password" jq -n \
  '{email: env.ADMIN_EMAIL, password: env.ADMIN_PASSWORD}' >"$signin_body"
curl_request 'NocoDB administrator sign-in' POST \
  "$nocodb_url/api/v1/auth/user/signin" none "$signin_body" "$signin_response"
session_jwt="$(jq -er '.token | select(type == "string" and length > 0)' "$signin_response")" || {
  echo 'NocoDB sign-in response omitted the session token.' >&2
  exit 1
}
[[ "$session_jwt" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo 'NocoDB sign-in returned an invalid session-token shape.' >&2
  exit 1
}

settings_body="$temp_dir/settings.json"
settings_update_response="$temp_dir/settings-update-response.json"
settings_read_response="$temp_dir/settings-read-response.json"
jq -n '{invite_only_signup: true, restrict_workspace_creation: true}' >"$settings_body"
curl_request 'NocoDB app-settings update' POST "$nocodb_url/api/v1/app-settings" \
  jwt "$settings_body" "$settings_update_response"
curl_request 'NocoDB app-settings read-back' GET "$nocodb_url/api/v1/app-settings" \
  jwt '' "$settings_read_response"
jq -e '.invite_only_signup == true and .restrict_workspace_creation == true' \
  "$settings_read_response" >/dev/null || {
    echo 'NocoDB app-settings read-back did not enable both required restrictions.' >&2
    exit 1
  }

token_body="$temp_dir/token.json"
token_response="$temp_dir/token-response.json"
jq -n '{description: "NocoDB Operator API"}' >"$token_body"
curl_request 'NocoDB API token creation' POST "$nocodb_url/api/v1/tokens" \
  jwt "$token_body" "$token_response"
nocodb_api_token="$(jq -er '.token | select(type == "string" and length > 0)' "$token_response")" || {
  echo 'NocoDB token response omitted the API token.' >&2
  exit 1
}
[[ "$nocodb_api_token" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo 'NocoDB returned an invalid API-token shape.' >&2
  exit 1
}

source_list_response="$temp_dir/source-list-response.json"
curl_request 'NocoDB API token source-list probe' GET \
  "$nocodb_url/api/v2/meta/bases" token '' "$source_list_response"
jq -e '
  type == "object" and
  (.list | type == "array") and
  (.pageInfo | type == "object")
' "$source_list_response" >/dev/null || {
  echo 'NocoDB API token source-list response did not satisfy the fixed contract.' >&2
  exit 1
}

credential_body="$temp_dir/credential.json"
credential_response="$temp_dir/credential-response.json"
NOCODB_API_TOKEN="$nocodb_api_token" jq -n '{
  name: "NocoDB Operator API",
  type: "httpHeaderAuth",
  data: {name: "xc-token", value: env.NOCODB_API_TOKEN}
}' >"$credential_body"
curl_request 'n8n NocoDB credential creation' POST "$n8n_url/api/v1/credentials" \
  n8n "$credential_body" "$credential_response"
credential_id="$(jq -er '
  select(.name == "NocoDB Operator API" and .type == "httpHeaderAuth") |
  .id | select(type == "string" and test("^[A-Za-z0-9_-]+$"))
' "$credential_response")" || {
  echo 'n8n credential response did not match the requested Header Auth identity.' >&2
  exit 1
}

credential_read_response="$temp_dir/credential-read-response.json"
curl_request 'n8n NocoDB credential read-back' GET \
  "$n8n_url/api/v1/credentials/$credential_id" n8n '' "$credential_read_response"
jq -e --arg id "$credential_id" '
  .id == $id and
  .name == "NocoDB Operator API" and
  .type == "httpHeaderAuth"
' "$credential_read_response" >/dev/null || {
  echo 'n8n credential read-back did not match the created Header Auth identity.' >&2
  exit 1
}

bootstrap_complete=true
printf 'NocoDB Operator API credential ID: %s\n' "$credential_id"
cat >&2 <<'EOF'
Import the secret-free NocoDB source-provisioning workflow. Bind NocoDB Operator API,
Automation Data Provisioner, and the fixed provisioning Header Auth credential exactly
as its setup note specifies, then publish it. Keep durable suspend changes in Git.
EOF
