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
bootstrap_token_description='NocoDB Operator API bootstrap/v1'
nocodb_ks='kubernetes/apps/automation-data/nocodb/ks.yaml'
nocodb_app='kubernetes/apps/automation-data/nocodb/app'
secret="$nocodb_app/nocodb-credentials.sops.yaml"
secret_resource='./nocodb-credentials.sops.yaml'
platform_preflight='scripts/nocodb/platform-preflight.sh'
n8n_api_key="${N8N_API_KEY:-}"
bootstrap_complete=false
resume_cleanup_intent=false
release_pending=false
success_reported=false
temp_dir=''
request_number=0
captured_main_sha=''
ownership_marker=''
ownership_annotation='homelab.supermorphic.com/nocodb-bootstrap-owner'
credential_id=''
orphan_token_id=''

get_nocodb_kustomization() { # <output>
  kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
    get kustomization nocodb --output json >"$1"
}

replace_nocodb_kustomization() { # <input>
  kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
    replace --filename - <"$1" >/dev/null
}

verify_released_active() {
  local verified="$temp_dir/release-verified.json"
  get_nocodb_kustomization "$verified" || return 1
  jq -e --arg key "$ownership_annotation" '
    .spec.suspend == false and (.metadata.annotations[$key] // "") == ""
  ' "$verified" >/dev/null
}

emit_bootstrap_success() {
  [[ "$success_reported" != true ]] || return 0
  if [[ -n "$orphan_token_id" ]]; then
    printf 'Preserved orphan NocoDB API token ID: %s\n' "$orphan_token_id"
  fi
  printf 'NocoDB Operator API credential ID: %s\n' "$credential_id"
  cat >&2 <<'EOF'
Import the secret-free NocoDB source-provisioning workflow. Bind NocoDB Operator API,
Automation Data Provisioner, and the fixed provisioning Header Auth credential exactly
as its setup note specifies, then publish it. Revoke any reported orphan token in NocoDB
after verifying the credential. Keep durable suspend changes in Git.
EOF
  success_reported=true
}

restore_owned_suspension() {
  local current="$temp_dir/cleanup-current.json"
  local replacement="$temp_dir/cleanup-replacement.json"
  local verified="$temp_dir/cleanup-verified.json"
  local current_marker

  get_nocodb_kustomization "$current" || return 1
  current_marker="$(jq -r --arg key "$ownership_annotation" \
    '.metadata.annotations[$key] // ""' "$current")" || return 1
  if [[ -z "$current_marker" ]]; then
    return 0
  fi
  if [[ "$current_marker" != "$ownership_marker" ]]; then
    echo 'NocoDB cleanup stopped because the bootstrap ownership marker changed.' >&2
    return 1
  fi
  jq --arg key "$ownership_annotation" '
    .spec.suspend = true |
    del(.metadata.annotations[$key]) |
    if (.metadata.annotations | length) == 0 then del(.metadata.annotations) else . end
  ' "$current" >"$replacement" || return 1
  replace_nocodb_kustomization "$replacement" || return 1
  get_nocodb_kustomization "$verified" || return 1
  jq -e --arg key "$ownership_annotation" '
    .spec.suspend == true and (.metadata.annotations[$key] // "") == ""
  ' "$verified" >/dev/null
}

release_owned_marker() {
  local current="$temp_dir/release-current.json"
  local replacement="$temp_dir/release-replacement.json"
  local replace_status

  get_nocodb_kustomization "$current"
  jq -e --arg key "$ownership_annotation" --arg marker "$ownership_marker" '
    .spec.suspend == false and .metadata.annotations[$key] == $marker
  ' "$current" >/dev/null || {
    echo 'NocoDB bootstrap ownership changed before marker release.' >&2
    return 1
  }
  jq --arg key "$ownership_annotation" '
    del(.metadata.annotations[$key]) |
    if (.metadata.annotations | length) == 0 then del(.metadata.annotations) else . end
  ' "$current" >"$replacement"
  release_pending=true
  set +e
  replace_nocodb_kustomization "$replacement"
  replace_status=$?
  set -e
  verify_released_active || {
    [[ "$replace_status" -eq 0 ]] || echo 'NocoDB marker release request failed.' >&2
    return 1
  }
  release_pending=false
  bootstrap_complete=true
}

cleanup_nocodb_bootstrap() {
  local original_exit="$?" cleanup_failed=false
  trap - EXIT
  set +e
  if [[ "$bootstrap_complete" != true && "$resume_cleanup_intent" == true ]]; then
    if [[ "$release_pending" == true ]] && verify_released_active; then
      echo 'NocoDB marker release was confirmed after the client lost its response.' >&2
      release_pending=false
      bootstrap_complete=true
      original_exit=0
      emit_bootstrap_success || cleanup_failed=true
    else
      echo 'NocoDB bootstrap did not pass; restoring the owned suspension while preserving resources and API state.' >&2
      restore_owned_suspension || cleanup_failed=true
    fi
  fi
  if [[ -n "$temp_dir" ]]; then
    rm -rf -- "$temp_dir" || cleanup_failed=true
    [[ ! -e "$temp_dir" ]] || cleanup_failed=true
  fi
  set -e
  if [[ "$cleanup_failed" == true ]]; then
    echo 'Failed to restore the owned NocoDB suspension or remove its secret-bearing temporary files.' >&2
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
remote_record="$(git ls-remote --exit-code origin refs/heads/main)" || {
  echo 'Refusing NocoDB bootstrap: cannot resolve the authoritative origin/main commit.' >&2
  exit 1
}
read -r captured_main_sha remote_ref extra_remote_field <<<"$remote_record"
[[ "$captured_main_sha" =~ ^[0-9a-f]{40}$ && "$remote_ref" == refs/heads/main &&
  -z "${extra_remote_field:-}" ]] || {
  echo 'Refusing NocoDB bootstrap: origin/main returned an invalid authority record.' >&2
  exit 1
}
git cat-file -e "${captured_main_sha}^{commit}" 2>/dev/null || {
  echo 'Refusing NocoDB bootstrap: the captured origin/main commit is unavailable locally.' >&2
  exit 1
}

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-bootstrap.XXXXXX")"
chmod 700 "$temp_dir"
ownership_marker="nocodb-bootstrap-${captured_main_sha:0:12}-$$-$(basename "$temp_dir")"

require_checkout_parity() {
  if [[ "$(git rev-parse HEAD)" != "$captured_main_sha" ]] ||
    [[ -n "$(git status --porcelain --untracked-files=no)" ]] ||
    ! git diff --quiet "$captured_main_sha" -- ||
    ! git diff --cached --quiet "$captured_main_sha" --; then
    echo 'Refusing NocoDB bootstrap: the complete tracked checkout does not equal the captured origin/main commit.' >&2
    return 1
  fi
}

require_secret_contract() {
  [[ -f "$secret" ]] || {
    echo "Refusing NocoDB bootstrap: the encrypted NocoDB Secret is absent: $secret." >&2
    return 1
  }
  git cat-file -e "$captured_main_sha:$secret" 2>/dev/null || {
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
  local deployed_revision
  deployed_revision="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
    get gitrepository flux-system --output jsonpath='{.status.artifact.revision}')"
  [[ "$deployed_revision" == "main@sha1:$captured_main_sha" ]] || {
    echo "Refusing NocoDB bootstrap: Flux revision does not equal the captured origin/main commit $captured_main_sha." >&2
    return 1
  }
}

require_live_suspension() {
  local state="$temp_dir/live-suspension-$request_number.json"
  request_number=$((request_number + 1))
  get_nocodb_kustomization "$state"
  jq -e --arg key "$ownership_annotation" '
    .spec.suspend == true and (.metadata.annotations[$key] // "") == "" and
    (.metadata.resourceVersion | type == "string" and length > 0)
  ' "$state" >/dev/null || {
    echo 'Refusing NocoDB bootstrap: nocodb is not suspended in the live cluster or is already owned.' >&2
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
      'no-location' \
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

list_n8n_credentials() { # <output>
  local output="$1" aggregate="$temp_dir/credential-inventory-aggregate.json"
  local page_response page_url next_cursor='' encoded_cursor seen_cursors='|' page=0
  jq -n '{data: [], nextCursor: null}' >"$aggregate"
  while :; do
    page=$((page + 1))
    [[ "$page" -le 100 ]] || {
      echo 'n8n credential inventory exceeded the bounded page count.' >&2
      return 1
    }
    page_url="$n8n_url/api/v1/credentials?limit=100"
    if [[ -n "$next_cursor" ]]; then
      encoded_cursor="$(CURSOR_VALUE="$next_cursor" jq -nr 'env.CURSOR_VALUE | @uri')"
      page_url="$page_url&cursor=$encoded_cursor"
    fi
    page_response="$temp_dir/credential-inventory-page-$page.json"
    curl_request 'n8n credential inventory' GET "$page_url" n8n '' "$page_response"
    jq -e '
      (.data | type) == "array" and
      (.nextCursor == null or
        ((.nextCursor | type) == "string" and (.nextCursor | length) > 0 and
          (.nextCursor | length) <= 1024))
    ' "$page_response" >/dev/null || {
      echo 'n8n credential inventory returned an invalid page.' >&2
      return 1
    }
    jq -s '{data: (.[0].data + .[1].data), nextCursor: null}' \
      "$aggregate" "$page_response" >"$temp_dir/credential-inventory-next.json"
    mv "$temp_dir/credential-inventory-next.json" "$aggregate"
    next_cursor="$(jq -r '.nextCursor // ""' "$page_response")"
    [[ -n "$next_cursor" ]] || break
    case "$seen_cursors" in
      *"|$next_cursor|"*)
        echo 'n8n credential inventory repeated a pagination cursor.' >&2
        return 1
        ;;
    esac
    seen_cursors="$seen_cursors$next_cursor|"
  done
  mv "$aggregate" "$output"
}

list_nocodb_tokens() { # <output>
  local output="$1" aggregate="$temp_dir/token-inventory-aggregate.json"
  local page_response page_url is_last page_count page=0 offset=0
  jq -n '{list: []}' >"$aggregate"
  while :; do
    page=$((page + 1))
    [[ "$page" -le 100 ]] || {
      echo 'NocoDB token inventory exceeded the bounded page count.' >&2
      return 1
    }
    page_url="$nocodb_url/api/v1/tokens?limit=100&offset=$offset"
    page_response="$temp_dir/token-inventory-page-$page.json"
    curl_request 'NocoDB API token inventory' GET "$page_url" jwt '' "$page_response"
    jq -e '
      (.list | type) == "array" and
      (.pageInfo | type) == "object" and
      (.pageInfo.isLastPage | type) == "boolean"
    ' "$page_response" >/dev/null || {
      echo 'NocoDB token inventory returned an invalid page.' >&2
      return 1
    }
    jq -s '{list: (.[0].list + .[1].list)}' \
      "$aggregate" "$page_response" >"$temp_dir/token-inventory-next.json"
    mv "$temp_dir/token-inventory-next.json" "$aggregate"
    is_last="$(jq -r '.pageInfo.isLastPage' "$page_response")"
    [[ "$is_last" == false ]] || break
    page_count="$(jq '.list | length' "$page_response")"
    [[ "$page_count" -gt 0 ]] || {
      echo 'NocoDB token inventory returned an empty non-terminal page.' >&2
      return 1
    }
    offset=$((offset + page_count))
  done
  mv "$aggregate" "$output"
}

require_attended_evidence() {
  local evidence="$temp_dir/evidence-$request_number.json"
  local candidates="$temp_dir/evidence-candidates-$request_number.tsv"
  local suite evidence_sha evidence_end selected_provisioning_end='' selected_restore_end=''
  local diff_status
  local selected_end candidate_suite
  local -a common_evidence_paths suite_evidence_paths
  curl_request 'Automation-data evidence query' GET "$reports_url" none '' "$evidence"
  jq -e '
    def provisioning_evidence:
      .source == "test" and
      .suite == "platform" and
      .tier == "integration" and
      .target == "automation-data" and
      .scenario == "provisioning";
    def restore_evidence:
      .source == "test" and
      .suite == "platform" and
      .tier == "integration" and
      .target == "automation-data-restore-drill" and
      .scenario == "full-chain";
    def valid_end:
      (.end | type) == "string" and
      (.end | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      ((try (.end | fromdateiso8601) catch null) != null);
    .schema_version == 1 and
    (.runs | type == "array") and
    all(.runs[] | select(
      provisioning_evidence or restore_evidence
    ) | select(.result == "passed" and .authoritative == true);
      (.git_sha | type) == "string" and
      (.git_sha | test("^[0-9a-f]{40}$")) and valid_end)
  ' "$evidence" >/dev/null || {
    echo 'Refusing NocoDB bootstrap: provisioning and restore evidence contains invalid dependency metadata.' >&2
    return 1
  }
  jq -r '
    def provisioning_evidence:
      .source == "test" and
      .suite == "platform" and
      .tier == "integration" and
      .target == "automation-data" and
      .scenario == "provisioning";
    def restore_evidence:
      .source == "test" and
      .suite == "platform" and
      .tier == "integration" and
      .target == "automation-data-restore-drill" and
      .scenario == "full-chain";
    [.runs[] | select(
      (provisioning_evidence or restore_evidence) and
      .result == "passed" and .authoritative == true
    ) | [
      (if provisioning_evidence then
        "test.automation-data-provisioning"
      else
        "test.automation-data-restore-drill"
      end),
      .git_sha,
      .end
    ]] |
    sort_by(.[0], .[2]) | reverse | .[] | @tsv
  ' "$evidence" >"$candidates"

  for suite in test.automation-data-provisioning test.automation-data-restore-drill; do
    selected_end=''
    while IFS=$'\t' read -r candidate_suite evidence_sha evidence_end; do
      [[ "$candidate_suite" == "$suite" ]] || continue
      git cat-file -e "${evidence_sha}^{commit}" 2>/dev/null || {
        echo "Refusing NocoDB bootstrap: applicable provisioning and restore evidence cannot be established because Git object $evidence_sha is unavailable locally." >&2
        return 1
      }
      common_evidence_paths=(
        .justfile
        .mise.toml
        kubernetes/apps/automation-data/namespace
        kubernetes/apps/automation-data/postgresql
        kubernetes/apps/automation/n8n/app/ciliumnetworkpolicy.yaml
        kubernetes/apps/automation/n8n/app/helmrelease.yaml
        kubernetes/apps/automation/n8n/app/kustomization.yaml
        kubernetes/apps/automation/n8n/ks.yaml
        kubernetes/mod.just
        mise.lock
        pyproject.toml
        scripts/lib
        scripts/test/junit_report.py
        scripts/test/junit_tools.py
        scripts/test/lib
        scripts/test/run-catalog-suite.sh
        scripts/test/validate-run.sh
        scripts/validate/automation-data.sh
        scripts/verify/automation-data.sh
        tests/catalog.yaml
        uv.lock
      )
      case "$suite" in
        test.automation-data-provisioning)
          suite_evidence_paths=(
            scripts/test/scenarios/automation-data-provisioning.sh
            kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json
          )
          ;;
        test.automation-data-restore-drill)
          suite_evidence_paths=(
            scripts/test/scenarios/automation-data-restore-drill.sh
            scripts/test/lib/automation-data-restore-command.sh
            kubernetes/apps/automation/n8n/app/workflows/automation-data-canary.json
          )
          ;;
        *)
          echo 'Refusing NocoDB bootstrap: evidence dependency coverage is unknown.' >&2
          return 1
          ;;
      esac
      set +e
      git diff --quiet "$evidence_sha" "$captured_main_sha" -- \
        "${common_evidence_paths[@]}" "${suite_evidence_paths[@]}"
      diff_status=$?
      set -e
      case "$diff_status" in
        0)
          selected_end="$evidence_end"
          break
          ;;
        1) ;;
        *)
          echo 'Refusing NocoDB bootstrap: applicable provisioning and restore evidence has dependency coverage that could not be compared.' >&2
          return 1
          ;;
      esac
    done <"$candidates"
    [[ -n "$selected_end" ]] || {
      echo "Refusing NocoDB bootstrap: applicable provisioning and restore evidence is absent for $suite." >&2
      return 1
    }
    if [[ "$suite" == test.automation-data-provisioning ]]; then
      selected_provisioning_end="$selected_end"
    else
      selected_restore_end="$selected_end"
    fi
  done
  [[ "$(jq -nr --arg provisioning "$selected_provisioning_end" \
    --arg restore "$selected_restore_end" \
    '($restore | fromdateiso8601) > ($provisioning | fromdateiso8601)')" == true ]] || {
    echo 'Refusing NocoDB bootstrap: applicable provisioning and restore evidence is not ordered; restore must be newer.' >&2
    return 1
  }
}

require_platform_preflight() {
  local output="$temp_dir/platform-preflight-$request_number.out"
  request_number=$((request_number + 1))
  [[ -x "$platform_preflight" ]] || {
    echo 'Refusing NocoDB bootstrap: the fixed platform preflight helper is unavailable.' >&2
    return 1
  }
  "$platform_preflight" "$kubeconfig" >"$output" || {
    echo 'Refusing NocoDB bootstrap: the installed revision and post-upgrade backup preflight failed.' >&2
    return 1
  }
  [[ "$(cat "$output")" == $'installed_revision=026-nocodb-v1\npost_upgrade_backup=true' ]] || {
    echo 'Refusing NocoDB bootstrap: the platform preflight returned unexpected evidence.' >&2
    return 1
  }
}

require_preconditions() {
  [[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
    echo "Refusing NocoDB bootstrap: origin must be $expected_origin." >&2
    return 1
  }
  require_checkout_parity
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

resume_with_ownership() {
  local current="$temp_dir/resume-current.json"
  local replacement="$temp_dir/resume-replacement.json"

  get_nocodb_kustomization "$current"
  jq -e --arg key "$ownership_annotation" '
    .spec.suspend == true and (.metadata.annotations[$key] // "") == "" and
    (.metadata.resourceVersion | type == "string" and length > 0)
  ' "$current" >/dev/null || {
    echo 'Refusing NocoDB bootstrap: nocodb changed before the owned resume.' >&2
    return 1
  }
  jq --arg key "$ownership_annotation" --arg marker "$ownership_marker" '
    .spec.suspend = false |
    .metadata.annotations = (.metadata.annotations // {}) |
    .metadata.annotations[$key] = $marker
  ' "$current" >"$replacement"

  # Arm compensation before the compare-and-swap. If the API applies the object but
  # the client loses the response, cleanup finds this marker and restores suspension.
  resume_cleanup_intent=true
  replace_nocodb_kustomization "$replacement"
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
require_platform_preflight

require_deployed_revision
echo 'Reconciling the automation-data parent before NocoDB activation.' >&2
flux reconcile kustomization automation-data --namespace flux-system \
  --kubeconfig "$kubeconfig" --timeout 10m
require_deployed_revision
kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
  --for=condition=Ready kustomization/automation-data --timeout=10m

# The parent reconcile must not change any authority bound by the original capture.
require_checkout_parity
require_deployed_revision
require_live_suspension
just kube automation-data-verify
require_platform_preflight

echo 'Resuming and reconciling the staged NocoDB package.' >&2
resume_with_ownership
require_deployed_revision
flux reconcile kustomization nocodb --namespace flux-system \
  --kubeconfig "$kubeconfig" --timeout 15m
require_deployed_revision

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

token_list_response="$temp_dir/token-list-response.json"
credential_list_response="$temp_dir/credential-list-response.json"
list_nocodb_tokens "$token_list_response"
list_n8n_credentials "$credential_list_response"

jq -e '(.list | type) == "array"' "$token_list_response" >/dev/null || {
  echo 'NocoDB token inventory returned an invalid response.' >&2
  exit 1
}
jq -e '(.data | type) == "array" and .nextCursor == null' \
  "$credential_list_response" >/dev/null || {
  echo 'n8n credential inventory was invalid or incomplete.' >&2
  exit 1
}
token_count="$(jq --arg description "$bootstrap_token_description" \
  '[.list[] | select(.description == $description)] | length' "$token_list_response")"
credential_name_count="$(jq '[.data[] | select(.name == "NocoDB Operator API")] | length' \
  "$credential_list_response")"
[[ "$credential_name_count" -le 1 ]] || {
  echo 'Refusing NocoDB bootstrap: multiple n8n credentials have the fixed name.' >&2
  exit 1
}
if [[ "$credential_name_count" -eq 1 ]]; then
  jq -e '.data[] | select(
    .name == "NocoDB Operator API" and .type == "httpHeaderAuth" and
    (.id | type == "string" and test("^[A-Za-z0-9_-]+$"))
  )' "$credential_list_response" >/dev/null || {
    echo 'Refusing NocoDB bootstrap: the fixed n8n credential has an unexpected type or ID.' >&2
    exit 1
  }
fi
managed_token_ids="$(jq -er --arg description "$bootstrap_token_description" '
  [.list[] | select(.description == $description)] as $tokens |
  if all($tokens[]; (.id | type == "string" and test("^[A-Za-z0-9_-]+$")))
  then ($tokens | map(.id) | join(","))
  else error("invalid bootstrap token ID")
  end
' "$token_list_response")" || {
  echo 'NocoDB bootstrap-token inventory contains an invalid non-secret ID.' >&2
  exit 1
}

if [[ "$credential_name_count" -eq 1 ]]; then
  credential_id="$(jq -er '.data[] | select(
    .name == "NocoDB Operator API" and .type == "httpHeaderAuth"
  ) | .id' "$credential_list_response")"
else
  if [[ "$token_count" -gt 1 ]]; then
    printf 'Preserved orphan NocoDB API token IDs: %s\n' "$managed_token_ids" >&2
    echo 'Refusing NocoDB bootstrap: more than one preserved orphan token requires attended revocation.' >&2
    exit 1
  fi
  if [[ "$token_count" -eq 1 ]]; then
    orphan_token_id="$managed_token_ids"
  fi
  token_body="$temp_dir/token.json"
  token_response="$temp_dir/token-response.json"
  BOOTSTRAP_TOKEN_DESCRIPTION="$bootstrap_token_description" jq -n \
    '{description: env.BOOTSTRAP_TOKEN_DESCRIPTION}' >"$token_body"
  curl_request 'NocoDB API token creation' POST "$nocodb_url/api/v1/tokens" \
    jwt "$token_body" "$token_response"
  nocodb_api_token="$(jq -er '
    .token | select(type == "string" and length > 0)
  ' "$token_response")" || {
    echo 'NocoDB token response omitted the fixed API token.' >&2
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
fi

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

release_owned_marker
emit_bootstrap_success
