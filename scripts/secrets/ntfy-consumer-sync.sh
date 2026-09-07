#!/usr/bin/env bash
# Synchronize an API-managed ntfy consumer with its publisher token from the canonical
# ntfy Secret. A staged pending token wins during rotation. Seerr settings are tested
# before save. n8n gets exactly one named httpHeaderAuth credential through its private
# API; this script does not read or mutate workflows. API responses and credential values
# are never printed. See docs/guides/ntfy-operations.md.
set -euo pipefail

consumer="${1:-}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

registry_file="${NTFY_IDENTITIES_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/config/identities.yaml}"
secret_file="${NTFY_SECRET_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/app/secret.sops.yaml}"
api_secret_file="${NTFY_SEERR_API_SECRET_FILE:-$repo_root/kubernetes/apps/monitoring/homepage/app/homepage-seerr.sops.yaml}"
seerr_base_url="${NTFY_SEERR_BASE_URL:-https://seerr.lab.supermorphic.com}"
n8n_base_url='https://n8n.lab.supermorphic.com'

fail() {
  echo "$1" >&2
  exit 1
}

case "$consumer" in
  seerr)
    registry_consumer='seerr-api'
    expected_confirmation='sync:media:seerr:ntfy'
    ;;
  n8n)
    registry_consumer='n8n-api'
    expected_confirmation='sync:automation:n8n:ntfy'
    ;;
  *) fail "Refusing: '$consumer' is not a known API-managed ntfy consumer (seerr, n8n)." ;;
esac
[[ -f "$registry_file" ]] || fail "Missing ntfy identity registry: $registry_file"
[[ "$(yq -r ".identities[\"$consumer\"].status // \"\"" "$registry_file")" == 'active' &&
  "$(yq -r ".identities[\"$consumer\"].consumer // \"\"" "$registry_file")" == "$registry_consumer" ]] ||
  fail "Refusing: the registry does not declare an active $registry_consumer identity '$consumer'."
[[ -f "$secret_file" ]] || fail "Missing canonical ntfy Secret: $secret_file"
if [[ "$consumer" == 'seerr' ]]; then
  [[ -f "$api_secret_file" ]] || fail "Missing Homepage Seerr API-key Secret: $api_secret_file"
fi

[[ "${NTFY_CONSUMER_SYNC_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing to synchronize the $consumer ntfy consumer." >&2
  echo "Set NTFY_CONSUMER_SYNC_CONFIRM='$expected_confirmation' after reviewing the target." >&2
  exit 1
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-ntfy-consumer-sync.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
umask 077

api_key=''
if [[ "$consumer" == 'seerr' ]]; then
  api_key="$(sops --decrypt "$api_secret_file" | yq -r '.stringData.apiKey // ""')"
  [[ -n "$api_key" ]] || fail "Refusing: $api_secret_file does not contain stringData.apiKey."
else
  api_key="${N8N_API_KEY:-}"
  [[ -n "$api_key" ]] || fail 'Refusing: set N8N_API_KEY in the environment for n8n credential sync.'
fi

# The staged pending token wins during a rotation; otherwise the current token.
auth_tokens="$(sops --decrypt "$secret_file" | yq -r '.stringData.NTFY_AUTH_TOKENS // ""')"
[[ -n "$auth_tokens" ]] || fail "Refusing: the canonical Secret has no NTFY_AUTH_TOKENS list."
token=''
pending=''
IFS=',' read -ra entries <<<"$auth_tokens"
for entry in "${entries[@]}"; do
  [[ "${entry%%:*}" == "$consumer" ]] || continue
  rest="${entry#*:}"
  if [[ "$entry" == *':pending' ]]; then
    pending="${rest%:*}"
  else
    token="${rest%%:*}"
  fi
done
[[ -n "$token" || -n "$pending" ]] ||
  fail "Refusing: no $consumer token in the canonical Secret; run 'just repo ntfy-identity ensure $consumer'."
staged=false
if [[ -n "$pending" ]]; then
  token="$pending"
  staged=true
fi

request_seerr() { # <method> <path> [body-file] -> prints HTTP status, body to response
  local method="$1" path="$2" body_file="${3:-}" code
  local args=(-sS -o "$temp_dir/response" -w '%{http_code}' --max-time 20
    -X "$method" -H "X-Api-Key: $api_key")
  if [[ -n "$body_file" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body_file")
  fi
  if ! code="$(curl "${args[@]}" "$seerr_base_url/api/v1/$path")"; then
    code='000'
  fi
  printf '%s' "$code"
}

request_n8n() { # <method> <path> [body-file] -> prints HTTP status, body to response
  local method="$1" path="$2" body_file="${3:-}" code
  local args=(-sS -o "$temp_dir/response" -w '%{http_code}' --max-time 20 --max-redirs 0
    --proto '=https' -X "$method" -H "X-N8N-API-KEY: $api_key")
  if [[ -n "$body_file" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body_file")
  fi
  if ! code="$(curl "${args[@]}" "$n8n_base_url/api/v1/$path")"; then
    code='000'
  fi
  printf '%s' "$code"
}

request_n8n_list() { # [opaque-cursor] -> prints HTTP status, body to response
  local cursor_value="${1:-}" code
  local args=(-sS -o "$temp_dir/response" -w '%{http_code}' --max-time 20 --max-redirs 0
    --proto '=https' -X GET -H "X-N8N-API-KEY: $api_key" --get --data 'limit=250')
  if [[ -n "$cursor_value" ]]; then
    args+=(--data-urlencode "cursor=$cursor_value")
  fi
  if ! code="$(curl "${args[@]}" "$n8n_base_url/api/v1/credentials")"; then
    code='000'
  fi
  printf '%s' "$code"
}

if [[ "$consumer" == 'n8n' ]]; then
  credential_name='Platform Failure ntfy'
  credential_type='httpHeaderAuth'
  matches="$temp_dir/matches.jsonl"
  : >"$matches"
  cursor=''
  declare -A seen_cursors=()
  while :; do
    if [[ -n "$cursor" ]]; then
      [[ "${#cursor}" -le 2048 ]] ||
        fail 'Refusing: n8n returned malformed credential metadata (nextCursor is too long).'
      [[ -z "${seen_cursors[$cursor]:-}" ]] ||
        fail 'Refusing: n8n returned malformed credential metadata (repeated nextCursor).'
      seen_cursors[$cursor]=1
    fi
    code="$(request_n8n_list "$cursor")"
    [[ "$code" == '200' ]] ||
      fail "Refusing: could not list n8n credentials (HTTP $code); check N8N_API_KEY and private reachability."
    cp -- "$temp_dir/response" "$temp_dir/page.json"
    yq -e '
      (.data | type) == "!!seq" and
      ([.data[] | ((.id | type) == "!!str" and (.id | length) > 0 and
        (.name | type) == "!!str" and (.type | type) == "!!str")] | all) and
      (.nextCursor == null or ((.nextCursor | type) == "!!str" and (.nextCursor | length) > 0))
    ' "$temp_dir/page.json" >/dev/null 2>&1 ||
      fail 'Refusing: n8n returned malformed credential metadata.'
    yq -o=json -I=0 ".data[] | select(.name == \"$credential_name\")" \
      "$temp_dir/page.json" >>"$matches"
    cursor="$(yq -r '.nextCursor // ""' "$temp_dir/page.json")"
    [[ -n "$cursor" ]] || break
  done

  match_count="$(wc -l <"$matches" | tr -d '[:space:]')"
  [[ "$match_count" -le 1 ]] ||
    fail "Refusing: n8n has multiple credentials named '$credential_name'; resolve duplicates manually."

  VALUE="Bearer $token" yq -n -o=json -I=0 \
    '.name = "Platform Failure ntfy" |
     .type = "httpHeaderAuth" |
     .data.name = "Authorization" |
     .data.value = strenv(VALUE)' >"$temp_dir/credential.json"

  credential_id=''
  if [[ "$match_count" == '1' ]]; then
    credential_id="$(yq -r '.id' "$matches")"
    existing_type="$(yq -r '.type' "$matches")"
    [[ "$existing_type" == "$credential_type" ]] ||
      fail "Refusing: n8n credential '$credential_name' has type '$existing_type', expected '$credential_type'."
    [[ "$credential_id" =~ ^[A-Za-z0-9_-]+$ ]] ||
      fail 'Refusing: n8n returned an invalid credential ID; no credential was changed.'
    code="$(request_n8n PATCH "credentials/$credential_id" "$temp_dir/credential.json")"
    operation='Updated'
  else
    code="$(request_n8n POST credentials "$temp_dir/credential.json")"
    operation='Created'
    if [[ "$code" == '200' ]]; then
      cp -- "$temp_dir/response" "$temp_dir/write.json"
      credential_id="$(yq -r '.id // ""' "$temp_dir/write.json" 2>/dev/null || true)"
    fi
  fi
  [[ "$code" == '200' ]] ||
    fail "Refusing: n8n credential write failed (HTTP $code); no workflow was modified."
  [[ "$credential_id" =~ ^[A-Za-z0-9_-]+$ ]] ||
    fail 'Refusing: n8n credential write returned malformed metadata.'

  code="$(request_n8n GET "credentials/$credential_id")"
  [[ "$code" == '200' ]] ||
    fail "Refusing: n8n credential metadata read-back failed (HTTP $code)."
  yq -e \
    ".id == \"$credential_id\" and .name == \"$credential_name\" and .type == \"$credential_type\"" \
    "$temp_dir/response" >/dev/null 2>&1 ||
    fail 'Refusing: n8n credential metadata did not match after the write.'

  message="$operation n8n credential '$credential_name'"
  if [[ "$operation" == 'Updated' ]]; then
    message+=' (ID preserved).'
  else
    message+='.'
  fi
  if [[ "$staged" == true ]]; then
    message+=" A staged rotation is in flight: run 'just repo ntfy-identity finalize n8n' only after delivery proof."
  fi
  echo "$message"
  exit 0
fi

code="$(request_seerr GET settings/notifications/ntfy)"
[[ "$code" == '200' ]] ||
  fail "Refusing: could not read Seerr's ntfy settings (HTTP $code); check the API key and reachability of $seerr_base_url."
cp -- "$temp_dir/response" "$temp_dir/current.json"
yq -e '.' "$temp_dir/current.json" >/dev/null ||
  fail 'Refusing: Seerr returned a non-JSON settings document.'

# Managed fields; everything else (embedPoster, options.locale, ...) is preserved.
TOKEN="$token" yq -o=json -I=0 '
  .enabled = true |
  .types = 280 |
  .options.url = "http://ntfy.ntfy.svc.cluster.local" |
  .options.topic = "media" |
  .options.priority = 3 |
  .options.authMethodToken = true |
  .options.authMethodUsernamePassword = false |
  .options.token = strenv(TOKEN)
' "$temp_dir/current.json" >"$temp_dir/candidate.json"

drifted=''
for path in enabled types options.url options.topic options.priority \
  options.authMethodToken options.authMethodUsernamePassword options.token; do
  current="$(yq -r ".$path // \"<absent>\"" "$temp_dir/current.json")"
  desired="$(yq -r ".$path // \"<absent>\"" "$temp_dir/candidate.json")"
  [[ "$current" == "$desired" ]] || drifted+="${drifted:+, }$path"
done
if [[ -z "$drifted" ]]; then
  echo "Seerr ntfy settings are already synchronized; nothing to do."
  exit 0
fi

# Prove the candidate with Seerr's test endpoint (delivers one test notification to
# the media topic) and save only after the test succeeds.
code="$(request_seerr POST settings/notifications/ntfy/test "$temp_dir/candidate.json")"
[[ "$code" == '200' || "$code" == '204' ]] ||
  fail "Refusing: Seerr's test notification with the candidate settings failed (HTTP $code). Seerr settings were NOT modified; check that ntfy is reachable from the media namespace and the token is provisioned."

code="$(request_seerr POST settings/notifications/ntfy "$temp_dir/candidate.json")"
[[ "$code" == '200' ]] ||
  fail "Refusing: saving Seerr's ntfy settings failed (HTTP $code) after a successful test; re-run to retry."

message="Seerr ntfy settings synchronized: enforced ${drifted} (test notification delivered before saving)."
if [[ "$staged" == true ]]; then
  message+=" A staged rotation is in flight: run 'just repo ntfy-identity finalize seerr' to revoke the previous token."
fi
echo "$message"
