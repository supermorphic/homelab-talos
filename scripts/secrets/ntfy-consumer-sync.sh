#!/usr/bin/env bash
# Synchronize an API-managed ntfy consumer's notification settings. Currently Seerr:
# reads the Seerr API key from the encrypted Homepage Seerr Secret and the seerr
# publisher token from the canonical ntfy Secret (a staged pending token wins during
# rotation), GETs Seerr's ntfy settings, enforces the managed fields while preserving
# operator-owned ones (embedPoster, locale), proves the candidate with Seerr's test
# endpoint, and saves only after the test succeeds. API responses and credentials are
# never printed. See docs/ntfy-startup-guide.md.
set -euo pipefail

consumer="${1:-}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

registry_file="${NTFY_IDENTITIES_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/config/identities.yaml}"
secret_file="${NTFY_SECRET_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/app/secret.sops.yaml}"
api_secret_file="${NTFY_SEERR_API_SECRET_FILE:-$repo_root/kubernetes/apps/monitoring/homepage/app/homepage-seerr.sops.yaml}"
base_url="${NTFY_SEERR_BASE_URL:-https://seerr.lab.supermorphic.com}"

fail() {
  echo "$1" >&2
  exit 1
}

[[ "$consumer" == 'seerr' ]] ||
  fail "Refusing: '$consumer' is not a known API-managed ntfy consumer (seerr)."
[[ -f "$registry_file" ]] || fail "Missing ntfy identity registry: $registry_file"
[[ "$(yq -r '.identities.seerr.status // ""' "$registry_file")" == 'active' &&
  "$(yq -r '.identities.seerr.consumer // ""' "$registry_file")" == 'seerr-api' ]] ||
  fail "Refusing: the registry does not declare an active seerr-api identity 'seerr'."
[[ -f "$secret_file" ]] || fail "Missing canonical ntfy Secret: $secret_file"
[[ -f "$api_secret_file" ]] || fail "Missing Homepage Seerr API-key Secret: $api_secret_file"

expected_confirmation='sync:media:seerr:ntfy'
[[ "${NTFY_CONSUMER_SYNC_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing to synchronize the Seerr ntfy settings." >&2
  echo "Set NTFY_CONSUMER_SYNC_CONFIRM='$expected_confirmation' after reviewing the target." >&2
  exit 1
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-ntfy-consumer-sync.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
umask 077

api_key="$(sops --decrypt "$api_secret_file" | yq -r '.stringData.apiKey // ""')"
[[ -n "$api_key" ]] || fail "Refusing: $api_secret_file does not contain stringData.apiKey."

# The staged pending token wins during a rotation; otherwise the current token.
auth_tokens="$(sops --decrypt "$secret_file" | yq -r '.stringData.NTFY_AUTH_TOKENS // ""')"
[[ -n "$auth_tokens" ]] || fail "Refusing: the canonical Secret has no NTFY_AUTH_TOKENS list."
token=''
pending=''
IFS=',' read -ra entries <<<"$auth_tokens"
for entry in "${entries[@]}"; do
  [[ "${entry%%:*}" == 'seerr' ]] || continue
  rest="${entry#*:}"
  if [[ "$entry" == *':pending' ]]; then
    pending="${rest%:*}"
  else
    token="${rest%%:*}"
  fi
done
[[ -n "$token" || -n "$pending" ]] ||
  fail "Refusing: no seerr token in the canonical Secret; run 'just repo ntfy-identity ensure seerr'."
staged=false
if [[ -n "$pending" ]]; then
  token="$pending"
  staged=true
fi

request() { # <method> <path> [body-file] -> prints HTTP status, body to $temp_dir/response
  local method="$1" path="$2" body_file="${3:-}" code
  local args=(-sS -o "$temp_dir/response" -w '%{http_code}' --max-time 20
    -X "$method" -H "X-Api-Key: $api_key")
  if [[ -n "$body_file" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body_file")
  fi
  if ! code="$(curl "${args[@]}" "$base_url/api/v1/$path")"; then
    code='000'
  fi
  printf '%s' "$code"
}

code="$(request GET settings/notifications/ntfy)"
[[ "$code" == '200' ]] ||
  fail "Refusing: could not read Seerr's ntfy settings (HTTP $code); check the API key and reachability of $base_url."
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
code="$(request POST settings/notifications/ntfy/test "$temp_dir/candidate.json")"
[[ "$code" == '200' ]] ||
  fail "Refusing: Seerr's test notification with the candidate settings failed (HTTP $code). Seerr settings were NOT modified; check that ntfy is reachable from the media namespace and the token is provisioned."

code="$(request POST settings/notifications/ntfy "$temp_dir/candidate.json")"
[[ "$code" == '200' ]] ||
  fail "Refusing: saving Seerr's ntfy settings failed (HTTP $code) after a successful test; re-run to retry."

message="Seerr ntfy settings synchronized: enforced ${drifted} (test notification delivered before saving)."
if [[ "$staged" == true ]]; then
  message+=" A staged rotation is in flight: run 'just repo ntfy-identity finalize seerr' to revoke the previous token."
fi
echo "$message"
