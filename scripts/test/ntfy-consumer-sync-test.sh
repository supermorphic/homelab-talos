#!/usr/bin/env bash
# Offline unit tests for scripts/secrets/ntfy-consumer-sync.sh. A PATH-stubbed curl
# serves and captures Seerr and n8n API calls; a PATH-stubbed sops provides fixture
# credentials. No real application state, credentials, or age identity is used.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
source scripts/test/lib/ntfy-fixtures.sh

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-ntfy-consumer-sync-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
stub_bin="$fixture/bin"
mkdir -p "$stub_bin"
ntfy_write_stub_sops "$stub_bin"

# Stub curl: routes on method + URL suffix, serves STUB_SEERR_GET, records every call
# and every posted body under STUB_DIR.
cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=''
method='GET'
url=''
data=''
cursor_arg=''
declare -a headers=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    --max-time) shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -H) headers+=("$2"); shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    --data-urlencode)
      if [[ "$2" == cursor=* ]]; then
        cursor_arg="${2#cursor=}"
      fi
      shift 2
      ;;
    --get) shift ;;
    --data) shift 2 ;;
    -sS) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [[ -n "$cursor_arg" ]]; then
  encoded_cursor="${cursor_arg//=/\%3D}"
  encoded_cursor="${encoded_cursor//+/\%2B}"
  encoded_cursor="${encoded_cursor//\//\%2F}"
  url+="?limit=250&cursor=$encoded_cursor"
elif [[ "$url" == 'https://n8n.lab.supermorphic.com/api/v1/credentials' && "$method" == 'GET' ]]; then
  url+='?limit=250'
fi
printf '%s %s\n' "$method" "$url" >>"$STUB_DIR/calls.log"
case "$method $url" in
  GET\ */api/v1/settings/notifications/ntfy)
    cat "$STUB_SEERR_GET" >"$out"
    printf '200'
    ;;
  POST\ */api/v1/settings/notifications/ntfy/test)
    cp -- "$data" "$STUB_DIR/test-body.json"
    printf '{}' >"$out"
    printf '%s' "$STUB_SEERR_TEST_CODE"
    ;;
  POST\ */api/v1/settings/notifications/ntfy)
    cp -- "$data" "$STUB_DIR/saved-body.json"
    printf '{}' >"$out"
    printf '200'
    ;;
  GET\ https://n8n.lab.supermorphic.com/api/v1/credentials/cred-existing | \
  GET\ https://n8n.lab.supermorphic.com/api/v1/credentials/cred-created)
    [[ " ${headers[*]} " == *" X-N8N-API-KEY: $STUB_N8N_API_KEY "* ]] || exit 91
    cat "$STUB_N8N_READ" >"$out"
    printf '%s' "$STUB_N8N_READ_CODE"
    ;;
  GET\ https://n8n.lab.supermorphic.com/api/v1/credentials*)
    [[ " ${headers[*]} " == *" X-N8N-API-KEY: $STUB_N8N_API_KEY "* ]] || exit 91
    if [[ "$url" == *'cursor=Y3Vyc29yOjI%3D' && -f "$STUB_N8N_LIST_NEXT" ]]; then
      cat "$STUB_N8N_LIST_NEXT" >"$out"
    else
      cat "$STUB_N8N_LIST" >"$out"
    fi
    printf '%s' "$STUB_N8N_LIST_CODE"
    ;;
  POST\ https://n8n.lab.supermorphic.com/api/v1/credentials)
    [[ " ${headers[*]} " == *" X-N8N-API-KEY: $STUB_N8N_API_KEY "* ]] || exit 91
    cp -- "$data" "$STUB_DIR/n8n-create-body.json"
    cat "$STUB_N8N_WRITE" >"$out"
    printf '%s' "$STUB_N8N_WRITE_CODE"
    ;;
  PATCH\ https://n8n.lab.supermorphic.com/api/v1/credentials/cred-existing)
    [[ " ${headers[*]} " == *" X-N8N-API-KEY: $STUB_N8N_API_KEY "* ]] || exit 91
    cp -- "$data" "$STUB_DIR/n8n-update-body.json"
    cat "$STUB_N8N_WRITE" >"$out"
    printf '%s' "$STUB_N8N_WRITE_CODE"
    ;;
  *)
    printf '404'
    ;;
esac
EOF
chmod +x "$stub_bin/curl"

export PATH="$stub_bin:$PATH"
export NTFY_SOPS_POLICY_FILE="$repo_root/.sops.yaml"

case_name=''
fail() {
  echo "FAIL [$case_name]: $1" >&2
  exit 1
}

new_case() { # <name>
  case_name="$1"
  case_dir="$fixture/$1"
  mkdir -p "$case_dir"
  ntfy_write_registry "$case_dir/registry.yaml"
  ntfy_write_secret_plain "$case_dir/plain.yaml" main
  ntfy_stub_encrypt "$case_dir/plain.yaml" "$case_dir/secret.sops.yaml" "$NTFY_SOPS_POLICY_FILE"
  cat >"$case_dir/api-secret-plain.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: homepage-seerr
  namespace: homepage
type: Opaque
stringData:
  apiKey: "fixture-seerr-api-key"
EOF
  ntfy_stub_encrypt "$case_dir/api-secret-plain.yaml" "$case_dir/api-secret.sops.yaml" "$NTFY_SOPS_POLICY_FILE"
  export NTFY_IDENTITIES_FILE="$case_dir/registry.yaml"
  export NTFY_SECRET_FILE="$case_dir/secret.sops.yaml"
  export NTFY_SEERR_API_SECRET_FILE="$case_dir/api-secret.sops.yaml"
  export NTFY_SEERR_BASE_URL='http://stub.test'
  export STUB_DIR="$case_dir"
  export STUB_SEERR_GET="$case_dir/get.json"
  export STUB_SEERR_TEST_CODE='204'
  export STUB_N8N_API_KEY='test-n8n-key'
  export STUB_N8N_LIST="$case_dir/n8n-list.json"
  export STUB_N8N_READ="$case_dir/n8n-read.json"
  export STUB_N8N_WRITE="$case_dir/n8n-write.json"
  export STUB_N8N_LIST_NEXT="$case_dir/n8n-list-next.json"
  export STUB_N8N_LIST_CODE='200'
  export STUB_N8N_READ_CODE='200'
  export STUB_N8N_WRITE_CODE='200'
  export N8N_API_KEY="$STUB_N8N_API_KEY"
  printf '{"data":[],"nextCursor":null}\n' >"$STUB_N8N_LIST"
  printf '{"id":"cred-created","name":"Platform Failure ntfy","type":"httpHeaderAuth"}\n' \
    >"$STUB_N8N_READ"
  cp -- "$STUB_N8N_READ" "$STUB_N8N_WRITE"
  : >"$case_dir/calls.log"
}

write_get_drifted() {
  cat >"$STUB_SEERR_GET" <<'EOF'
{
  "enabled": false,
  "types": 0,
  "embedPoster": true,
  "options": {
    "url": "https://ntfy.sh",
    "topic": "unrelated",
    "priority": 5,
    "authMethodUsernamePassword": true,
    "username": "legacy-user",
    "password": "legacy-pass",
    "locale": "de"
  }
}
EOF
}

write_get_synchronized() {
  cat >"$STUB_SEERR_GET" <<EOF
{
  "enabled": true,
  "types": 280,
  "embedPoster": true,
  "options": {
    "url": "http://ntfy.ntfy.svc.cluster.local",
    "topic": "media",
    "priority": 3,
    "authMethodToken": true,
    "authMethodUsernamePassword": false,
    "token": "$ntfy_fixture_seerr_token",
    "locale": "de"
  }
}
EOF
}

OUT=''
STATUS=0
run_sync() { # <confirm|->
  set +e
  if [[ "$1" == '-' ]]; then
    OUT="$(env -u NTFY_CONSUMER_SYNC_CONFIRM scripts/secrets/ntfy-consumer-sync.sh seerr 2>&1)"
  else
    OUT="$(NTFY_CONSUMER_SYNC_CONFIRM="$1" scripts/secrets/ntfy-consumer-sync.sh seerr 2>&1)"
  fi
  STATUS=$?
  set -e
}

run_n8n() { # <confirm|->
  set +e
  if [[ "$1" == '-' ]]; then
    OUT="$(env -u NTFY_CONSUMER_SYNC_CONFIRM scripts/secrets/ntfy-consumer-sync.sh n8n 2>&1)"
  else
    OUT="$(NTFY_CONSUMER_SYNC_CONFIRM="$1" scripts/secrets/ntfy-consumer-sync.sh n8n 2>&1)"
  fi
  STATUS=$?
  set -e
}

assert_status() { [[ "$STATUS" -eq "$1" ]] || fail "expected status $1, got $STATUS: $OUT"; }
assert_ok() { assert_status 0; }
assert_contains() { rg -Fq -- "$1" <<<"$OUT" || fail "output missing '$1': $OUT"; }
assert_not_contains() { ! rg -Fq -- "$1" <<<"$OUT" || fail "output leaked: $1"; }
assert_saved() { # <yq-expression>
  [[ -f "$STUB_DIR/saved-body.json" ]] || fail 'no settings were saved'
  yq -e "$1" "$STUB_DIR/saved-body.json" >/dev/null || fail "saved body failed assertion '$1': $(cat "$STUB_DIR/saved-body.json")"
}
count_calls() { # <pattern> — ripgrep prints nothing (and exits 1) on zero matches
  rg -c "$1" "$STUB_DIR/calls.log" || printf '0'
}
assert_no_secret_echo() {
  assert_not_contains "$ntfy_fixture_seerr_token"
  assert_not_contains 'fixture-seerr-api-key'
}

assert_no_n8n_secret_echo() {
  assert_not_contains "$ntfy_fixture_n8n_token"
  assert_not_contains 'test-n8n-key'
}

# --- Guard + argument handling ------------------------------------------------
new_case guard
write_get_drifted
run_sync -
assert_status 1
assert_contains "Set NTFY_CONSUMER_SYNC_CONFIRM='sync:media:seerr:ntfy'"
[[ ! -e "$STUB_DIR/saved-body.json" ]] || fail 'guard refusal saved settings'
set +e
OUT="$(NTFY_CONSUMER_SYNC_CONFIRM='sync:media:seerr:ntfy' \
  scripts/secrets/ntfy-consumer-sync.sh radarr 2>&1)"
STATUS=$?
set -e
assert_status 1
assert_contains "not a known API-managed ntfy consumer"

# --- Drift: test passes, then the enforced settings are saved ------------------
new_case sync-drifted
write_get_drifted
run_sync 'sync:media:seerr:ntfy'
assert_ok
assert_contains 'synchronized'
assert_contains 'options.token'
[[ "$(rg -c '^POST ' "$STUB_DIR/calls.log")" == '2' ]] || fail 'expected test + save POSTs'
rg -q '^POST .*/ntfy/test$' "$STUB_DIR/calls.log" || fail 'test endpoint was not called'
head_order="$(head -n2 "$STUB_DIR/calls.log" | tail -n1)"
[[ "$head_order" == 'POST http://stub.test/api/v1/settings/notifications/ntfy/test' ]] ||
  fail "the test call must precede the save call: $(cat "$STUB_DIR/calls.log")"
assert_saved '.enabled == true'
assert_saved '.types == 280'
assert_saved '.options.url == "http://ntfy.ntfy.svc.cluster.local"'
assert_saved '.options.topic == "media"'
assert_saved '.options.priority == 3'
assert_saved '.options.authMethodToken == true'
assert_saved '.options.authMethodUsernamePassword == false'
assert_saved ".options.token == \"$ntfy_fixture_seerr_token\""
assert_saved '.embedPoster == true'
assert_saved '.options.locale == "de"'
assert_saved '.options.username == "legacy-user"'
cmp -s "$STUB_DIR/test-body.json" "$STUB_DIR/saved-body.json" ||
  fail 'the saved settings differ from the tested candidate'
assert_no_secret_echo

# --- Compatibility: Seerr versions returning 200 from test are also accepted ---
new_case sync-test-200
write_get_drifted
export STUB_SEERR_TEST_CODE='200'
run_sync 'sync:media:seerr:ntfy'
assert_ok
[[ -f "$STUB_DIR/saved-body.json" ]] || fail 'HTTP 200 test success was not saved'
assert_no_secret_echo

# --- Already synchronized: no test, no save --------------------------------------
new_case sync-idempotent
write_get_synchronized
run_sync 'sync:media:seerr:ntfy'
assert_ok
assert_contains 'already synchronized; nothing to do'
[[ "$(count_calls '^POST ')" == '0' ]] ||
  fail "a synchronized consumer must not be mutated: $(cat "$STUB_DIR/calls.log")"
assert_no_secret_echo

# --- Test failure prevents any mutation ------------------------------------------
new_case sync-test-fails
write_get_drifted
export STUB_SEERR_TEST_CODE='500'
run_sync 'sync:media:seerr:ntfy'
assert_status 1
assert_contains 'NOT modified'
[[ ! -e "$STUB_DIR/saved-body.json" ]] || fail 'settings were saved after a failed test'
[[ "$(count_calls '^POST .*/settings/notifications/ntfy$')" == '0' ]] ||
  fail 'save was attempted after a failed test'
assert_no_secret_echo

new_case sync-test-unexpected
write_get_drifted
export STUB_SEERR_TEST_CODE='202'
run_sync 'sync:media:seerr:ntfy'
assert_status 1
assert_contains 'NOT modified'
[[ ! -e "$STUB_DIR/saved-body.json" ]] || fail 'settings were saved after an unexpected test response'
assert_no_secret_echo

# --- Staged rotation: the pending token is synchronized ----------------------------
new_case sync-staged
write_get_synchronized
yq -i ".stringData.NTFY_AUTH_TOKENS = \"alertmanager:$ntfy_fixture_am_token,seerr:$ntfy_fixture_seerr_token,seerr:tk_wwwwwwwwwwwwwwwwwwwwwwwwwwww1:pending,automation:$ntfy_fixture_automation_token,homepage:$ntfy_fixture_homepage_token\"" \
  "$case_dir/plain.yaml"
ntfy_stub_encrypt "$case_dir/plain.yaml" "$NTFY_SECRET_FILE" "$NTFY_SOPS_POLICY_FILE"
run_sync 'sync:media:seerr:ntfy'
assert_ok
assert_contains 'finalize seerr'
assert_saved '.options.token == "tk_wwwwwwwwwwwwwwwwwwwwwwwwwwww1"'
assert_not_contains 'tk_wwwwwwwwwwwwwwwwwwwwwwwwwwww1'
assert_no_secret_echo

# --- n8n create: exact private API, name, type, and Header Auth data -------------
new_case n8n-create
run_n8n 'sync:automation:n8n:ntfy'
assert_ok
assert_contains "Created n8n credential 'Platform Failure ntfy'"
[[ "$(count_calls '^POST https://n8n.lab.supermorphic.com/api/v1/credentials$')" == '1' ]] ||
  fail "expected one n8n credential create: $(cat "$STUB_DIR/calls.log")"
[[ "$(count_calls '^GET https://n8n.lab.supermorphic.com/api/v1/credentials/cred-created$')" == '1' ]] ||
  fail 'created credential metadata was not read back'
yq -e \
  '.name == "Platform Failure ntfy" and .type == "httpHeaderAuth" and
   .data.name == "Authorization" and
   .data.value == "Bearer tk_nnnnnnnnnnnnnnnnnnnnnnnnnnnn1"' \
  "$STUB_DIR/n8n-create-body.json" >/dev/null || fail 'n8n create body is wrong'
assert_no_n8n_secret_echo

# --- n8n update: exact name/type preserves the credential ID --------------------
new_case n8n-update
cat >"$STUB_N8N_LIST" <<'EOF'
{"data":[{"id":"cred-existing","name":"Platform Failure ntfy","type":"httpHeaderAuth","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z","shared":[]}],"nextCursor":null}
EOF
cat >"$STUB_N8N_READ" <<'EOF'
{"id":"cred-existing","name":"Platform Failure ntfy","type":"httpHeaderAuth"}
EOF
cp -- "$STUB_N8N_READ" "$STUB_N8N_WRITE"
run_n8n 'sync:automation:n8n:ntfy'
assert_ok
assert_contains "Updated n8n credential 'Platform Failure ntfy' (ID preserved)."
[[ "$(count_calls '^PATCH https://n8n.lab.supermorphic.com/api/v1/credentials/cred-existing$')" == '1' ]] ||
  fail 'n8n credential was not updated by its existing ID'
[[ ! -e "$STUB_DIR/n8n-create-body.json" ]] || fail 'update path created another credential'
yq -e '.data.name == "Authorization" and .data.value == "Bearer tk_nnnnnnnnnnnnnnnnnnnnnnnnnnnn1"' \
  "$STUB_DIR/n8n-update-body.json" >/dev/null || fail 'n8n update body is wrong'
assert_no_n8n_secret_echo

# --- n8n pagination: exact-name matching spans the full collection ---------------
new_case n8n-paginated-update
cat >"$STUB_N8N_LIST" <<'EOF'
{"data":[{"id":"unrelated","name":"Another credential","type":"httpHeaderAuth"}],"nextCursor":"Y3Vyc29yOjI="}
EOF
cat >"$STUB_N8N_LIST_NEXT" <<'EOF'
{"data":[{"id":"cred-existing","name":"Platform Failure ntfy","type":"httpHeaderAuth"}],"nextCursor":null}
EOF
cat >"$STUB_N8N_READ" <<'EOF'
{"id":"cred-existing","name":"Platform Failure ntfy","type":"httpHeaderAuth"}
EOF
cp -- "$STUB_N8N_READ" "$STUB_N8N_WRITE"
run_n8n 'sync:automation:n8n:ntfy'
assert_ok
[[ "$(count_calls '^GET https://n8n\.lab\.supermorphic\.com/api/v1/credentials\?')" == '2' ]] ||
  fail 'n8n credential list pagination was incomplete'
[[ "$(count_calls '^PATCH https://n8n.lab.supermorphic.com/api/v1/credentials/cred-existing$')" == '1' ]] ||
  fail 'paginated exact match was not updated'
assert_no_n8n_secret_echo

new_case n8n-invalid-id
cat >"$STUB_N8N_LIST" <<'EOF'
{"data":[{"id":"../../workflows","name":"Platform Failure ntfy","type":"httpHeaderAuth"}],"nextCursor":null}
EOF
run_n8n 'sync:automation:n8n:ntfy'
assert_status 1
assert_contains 'invalid credential ID'
[[ "$(count_calls '^(POST|PATCH) ')" == '0' ]] || fail 'invalid credential ID caused mutation'
assert_no_n8n_secret_echo

# --- n8n staged rotation: pending token wins ------------------------------------
new_case n8n-staged
yq -i ".stringData.NTFY_AUTH_TOKENS += \",n8n:tk_pppppppppppppppppppppppppppp1:pending\"" \
  "$case_dir/plain.yaml"
ntfy_stub_encrypt "$case_dir/plain.yaml" "$NTFY_SECRET_FILE" "$NTFY_SOPS_POLICY_FILE"
run_n8n 'sync:automation:n8n:ntfy'
assert_ok
yq -e '.data.value == "Bearer tk_pppppppppppppppppppppppppppp1"' \
  "$STUB_DIR/n8n-create-body.json" >/dev/null || fail 'n8n sync did not select pending token'
assert_contains 'finalize n8n'
assert_not_contains 'tk_pppppppppppppppppppppppppppp1'
assert_no_n8n_secret_echo

# --- n8n safety: guard, API key, duplicate, wrong type, and malformed metadata ---
new_case n8n-guard
run_n8n -
assert_status 1
assert_contains "Set NTFY_CONSUMER_SYNC_CONFIRM='sync:automation:n8n:ntfy'"
[[ "$(count_calls .)" == '0' ]] || fail 'guard refusal contacted n8n'

new_case n8n-api-key
set +e
OUT="$(env -u N8N_API_KEY NTFY_CONSUMER_SYNC_CONFIRM='sync:automation:n8n:ntfy' \
  scripts/secrets/ntfy-consumer-sync.sh n8n 2>&1)"
STATUS=$?
set -e
assert_status 1
assert_contains 'N8N_API_KEY'
[[ "$(count_calls .)" == '0' ]] || fail 'missing API key contacted n8n'

new_case n8n-duplicate
cat >"$STUB_N8N_LIST" <<'EOF'
{"data":[{"id":"cred-1","name":"Platform Failure ntfy","type":"httpHeaderAuth"},{"id":"cred-2","name":"Platform Failure ntfy","type":"httpHeaderAuth"}],"nextCursor":null}
EOF
run_n8n 'sync:automation:n8n:ntfy'
assert_status 1
assert_contains 'multiple credentials named'
[[ "$(count_calls '^(POST|PATCH) ')" == '0' ]] || fail 'duplicate metadata caused mutation'
assert_no_n8n_secret_echo

new_case n8n-wrong-type
cat >"$STUB_N8N_LIST" <<'EOF'
{"data":[{"id":"cred-existing","name":"Platform Failure ntfy","type":"httpBasicAuth"}],"nextCursor":null}
EOF
run_n8n 'sync:automation:n8n:ntfy'
assert_status 1
assert_contains "has type 'httpBasicAuth', expected 'httpHeaderAuth'"
[[ "$(count_calls '^(POST|PATCH) ')" == '0' ]] || fail 'wrong type caused mutation'
assert_no_n8n_secret_echo

new_case n8n-malformed
printf '{"data":{},"nextCursor":null}\n' >"$STUB_N8N_LIST"
run_n8n 'sync:automation:n8n:ntfy'
assert_status 1
assert_contains 'malformed credential metadata'
[[ "$(count_calls '^(POST|PATCH) ')" == '0' ]] || fail 'malformed metadata caused mutation'
assert_no_n8n_secret_echo

new_case n8n-list-failure
export STUB_N8N_LIST_CODE='503'
run_n8n 'sync:automation:n8n:ntfy'
assert_status 1
assert_contains 'HTTP 503'
[[ "$(count_calls '^(POST|PATCH) ')" == '0' ]] || fail 'failed list caused mutation'
assert_no_n8n_secret_echo

new_case n8n-write-failure
export STUB_N8N_WRITE_CODE='500'
run_n8n 'sync:automation:n8n:ntfy'
assert_status 1
assert_contains 'HTTP 500'
[[ "$(count_calls '^GET https://n8n.lab.supermorphic.com/api/v1/credentials/cred-created$')" == '0' ]] ||
  fail 'failed create was read back as if successful'
assert_no_n8n_secret_echo

echo 'ntfy-consumer-sync unit tests passed (Seerr settings sync and n8n credential create/update, staged rotation, malformed metadata, API failures, and leak guards).'
