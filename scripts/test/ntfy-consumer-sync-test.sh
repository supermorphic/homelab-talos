#!/usr/bin/env bash
# Offline unit tests for scripts/secrets/ntfy-consumer-sync.sh. A PATH-stubbed curl
# serves and captures Seerr API calls; a PATH-stubbed sops provides the fixture
# credentials. Proves: test-before-save ordering, drift detection, preservation of
# operator-owned settings, staged-rotation token selection, and that API responses
# containing secrets never reach output.
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    --max-time) shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -H) shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -sS) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
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
  export STUB_SEERR_TEST_CODE='200'
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

echo 'ntfy-consumer-sync unit tests passed (guard, drift enforcement, preservation, test-before-save ordering, idempotency, test-failure safety, staged rotation, leak guards).'
