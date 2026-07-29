#!/usr/bin/env bash
# Offline unit tests for scripts/secrets/ntfy-identity.sh and
# scripts/secrets/ntfy-subscriber-password.sh. PATH-stubbed sops proves the scripts call
# the real sops CLI correctly and never leak plaintext; no age key or cluster is needed.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
source scripts/test/lib/ntfy-fixtures.sh

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-ntfy-identity-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
stub_bin="$fixture/bin"
mkdir -p "$stub_bin"
ntfy_write_stub_sops "$stub_bin"
export PATH="$stub_bin:$PATH"
export NTFY_SOPS_POLICY_FILE="$repo_root/.sops.yaml"

case_name=''
fail() {
  echo "FAIL [$case_name]: $1" >&2
  exit 1
}

new_case() { # <name> <main|legacy|none>
  case_name="$1"
  local variant="${2:-main}"
  case_dir="$fixture/$1"
  mkdir -p "$case_dir"
  ntfy_write_registry "$case_dir/registry.yaml"
  if [[ "$variant" != 'none' ]]; then
    ntfy_write_secret_plain "$case_dir/plain.yaml" "$variant"
    ntfy_stub_encrypt "$case_dir/plain.yaml" "$case_dir/secret.sops.yaml" "$NTFY_SOPS_POLICY_FILE"
  fi
  ntfy_write_values_fixture \
    "$case_dir/ntfy-values.yaml" "$case_dir/adapter-values.yaml" "$case_dir/homepage-deployment.yaml"
  export NTFY_IDENTITIES_FILE="$case_dir/registry.yaml"
  export NTFY_SECRET_FILE="$case_dir/secret.sops.yaml"
  export NTFY_HOMEPAGE_SECRET_FILE="$case_dir/homepage-ntfy.sops.yaml"
  export NTFY_VALUES_FILE="$case_dir/ntfy-values.yaml"
  export NTFY_ADAPTER_VALUES_FILE="$case_dir/adapter-values.yaml"
  export NTFY_HOMEPAGE_DEPLOYMENT_FILE="$case_dir/homepage-deployment.yaml"
}

OUT=''
STATUS=0
run_id() { # <confirm|-> <action> <identity>
  local confirm="$1" action="$2" identity="$3"
  set +e
  if [[ "$confirm" == '-' ]]; then
    OUT="$(env -u NTFY_IDENTITY_CONFIRM scripts/secrets/ntfy-identity.sh "$action" "$identity" 2>&1)"
  else
    OUT="$(NTFY_IDENTITY_CONFIRM="$confirm" scripts/secrets/ntfy-identity.sh "$action" "$identity" 2>&1)"
  fi
  STATUS=$?
  set -e
}

run_pw() { # <confirm|-> <stdin>
  local confirm="$1" input="$2"
  set +e
  if [[ "$confirm" == '-' ]]; then
    OUT="$(printf '%s' "$input" | env -u NTFY_SUBSCRIBER_PASSWORD_CONFIRM \
      scripts/secrets/ntfy-subscriber-password.sh 2>&1)"
  else
    OUT="$(printf '%s' "$input" | NTFY_SUBSCRIBER_PASSWORD_CONFIRM="$confirm" \
      scripts/secrets/ntfy-subscriber-password.sh 2>&1)"
  fi
  STATUS=$?
  set -e
}

assert_status() { [[ "$STATUS" -eq "$1" ]] || fail "expected status $1, got $STATUS: $OUT"; }
assert_ok() { assert_status 0; }
assert_contains() { rg -Fq -- "$1" <<<"$OUT" || fail "output missing '$1': $OUT"; }
assert_not_contains() { ! rg -Fq -- "$1" <<<"$OUT" || fail "output leaked: $1"; }
assert_secret_users() {
  local actual
  actual="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_USERS)"
  [[ "$actual" == "$1" ]] || fail "NTFY_AUTH_USERS mismatch: $actual"
}
assert_secret_access() {
  local actual
  actual="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_ACCESS)"
  [[ "$actual" == "$1" ]] || fail "NTFY_AUTH_ACCESS mismatch: $actual"
}
assert_secret_tokens() {
  local actual
  actual="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_TOKENS)"
  [[ "$actual" == "$1" ]] || fail "NTFY_AUTH_TOKENS mismatch: $actual"
}
assert_auth_yml_token() {
  local actual
  actual="$(ntfy_secret_key "$NTFY_SECRET_FILE" auth.yml | yq -r '.ntfy.auth.token')"
  [[ "$actual" == "$1" ]] || fail "auth.yml token mismatch: $actual"
}
assert_stamps() {
  local revision
  revision="$(git hash-object "$NTFY_SECRET_FILE")"
  [[ "$(yq -r '.controllers.ntfy.pod.annotations.sops-hash' "$NTFY_VALUES_FILE")" == "$revision" ]] ||
    fail 'ntfy values sops-hash not stamped'
  [[ "$(yq -r '.controllers["alertmanager-ntfy"].pod.annotations["sops-hash"]' "$NTFY_ADAPTER_VALUES_FILE")" == "$revision" ]] ||
    fail 'adapter values sops-hash not stamped'
}
assert_no_secret_echo() {
  local value
  for value in "$ntfy_fixture_sub_hash" "$ntfy_fixture_am_hash" "$ntfy_fixture_seerr_hash" \
    "$ntfy_fixture_automation_hash" "$ntfy_fixture_homepage_hash" "$ntfy_fixture_am_token" \
    "$ntfy_fixture_seerr_token" "$ntfy_fixture_automation_token" "$ntfy_fixture_homepage_token"; do
    assert_not_contains "$value"
  done
}

expected_users_main="alertmanager:$ntfy_fixture_am_hash:user,homepage:$ntfy_fixture_homepage_hash:user,seerr:$ntfy_fixture_seerr_hash:user,subscriber:$ntfy_fixture_sub_hash:user"
expected_access_main='alertmanager:critical:wo,alertmanager:homelab:wo,homepage:critical:ro,seerr:media:wo,subscriber:critical:ro,subscriber:homelab:ro,subscriber:media:ro'
expected_tokens_main="alertmanager:$ntfy_fixture_am_token,homepage:$ntfy_fixture_homepage_token,seerr:$ntfy_fixture_seerr_token"

# --- Guard + argument handling ------------------------------------------------
new_case guard
before="$(git hash-object "$NTFY_SECRET_FILE")"
run_id - reconcile all
assert_status 1
assert_contains "Set NTFY_IDENTITY_CONFIRM='reconcile:monitoring:ntfy:all:sops'"
[[ "$(git hash-object "$NTFY_SECRET_FILE")" == "$before" ]] || fail 'guard refusal changed the Secret'
run_id 'ensure:monitoring:ntfy:bogus:sops' ensure bogus
assert_status 1
assert_contains "'bogus' is not an identity"
set +e
OUT="$(scripts/secrets/ntfy-identity.sh frobnicate all 2>&1)"
STATUS=$?
set -e
assert_status 2
assert_contains 'Usage:'
run_id 'ensure:monitoring:ntfy:automation:sops' ensure automation
assert_status 1
assert_contains "identity 'automation' is retired"

# --- Reconcile: migration from the current production state -------------------
new_case reconcile-migration
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_ok
assert_secret_users "$expected_users_main"
assert_secret_access "$expected_access_main"
assert_secret_tokens "$expected_tokens_main"
assert_auth_yml_token "$ntfy_fixture_am_token"
assert_stamps
[[ "$(ntfy_secret_key "$NTFY_HOMEPAGE_SECRET_FILE" token)" == "$ntfy_fixture_homepage_token" ]] ||
  fail 'homepage Secret was not mirrored with the preserved token'
[[ "$(yq -r '.spec.template.metadata.annotations["sops-hash"]' "$NTFY_HOMEPAGE_DEPLOYMENT_FILE")" == \
  "$(git hash-object "$NTFY_HOMEPAGE_SECRET_FILE")" ]] || fail 'homepage deployment sops-hash not stamped'
assert_no_secret_echo
assert_contains 'Updated encrypted'

# --- Idempotency: a second reconcile changes nothing --------------------------
new_case reconcile-idempotent
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_ok
secret_revision="$(git hash-object "$NTFY_SECRET_FILE")"
homepage_revision="$(git hash-object "$NTFY_HOMEPAGE_SECRET_FILE")"
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_ok
assert_contains 'already synchronized; nothing to do'
[[ "$(git hash-object "$NTFY_SECRET_FILE")" == "$secret_revision" ]] || fail 'ciphertext rewritten'
[[ "$(git hash-object "$NTFY_HOMEPAGE_SECRET_FILE")" == "$homepage_revision" ]] || fail 'homepage ciphertext rewritten'

# --- Missing identity generation (legacy state without homepage) ---------------
new_case ensure-generates legacy
run_id 'ensure:monitoring:ntfy:homepage:sops' ensure homepage
assert_ok
users="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_USERS)"
homepage_user="$(yq -r '.stringData.NTFY_AUTH_USERS | @base64d' "$NTFY_SECRET_FILE" | tr ',' '\n' | rg '^homepage:')"
[[ "$homepage_user" =~ ^homepage:\$2[aby]\$.+:user$ ]] || fail "generated homepage hash is not bcrypt: $homepage_user"
tokens="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_TOKENS)"
generated_homepage_token="$(tr ',' '\n' <<<"$tokens" | rg '^homepage:' | cut -d: -f2)"
[[ "$generated_homepage_token" =~ ^tk_[a-z0-9]{29}$ ]] || fail "generated token malformed: $generated_homepage_token"
# Surgical: automation (retired) is preserved until reconcile.
rg -q 'automation:' <<<"$users" || fail 'surgical ensure dropped the retired identity'
rg -Fq "subscriber:$ntfy_fixture_sub_hash" <<<"$users" || fail 'subscriber hash not preserved'
[[ "$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_ACCESS)" == *'homepage:critical:ro'* ]] ||
  fail 'homepage ACL missing'
[[ "$(ntfy_secret_key "$NTFY_HOMEPAGE_SECRET_FILE" token)" == "$generated_homepage_token" ]] ||
  fail 'homepage Secret token does not match the canonical token'

# --- Drift: unknown identity in the Secret must be tombstoned first ------------
new_case reconcile-drift
plain="$case_dir/plain.yaml"
rogue_hash="\$2a\$10\$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhW9"
yq -i ".stringData.NTFY_AUTH_USERS += \",rogue:$rogue_hash:user\"" "$plain"
ntfy_stub_encrypt "$plain" "$NTFY_SECRET_FILE" "$NTFY_SOPS_POLICY_FILE"
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_status 1
assert_contains 'rogue'
assert_contains 'Tombstone'

# --- Fresh bootstrap: the human password is never invented ----------------------
new_case reconcile-missing-subscriber
yq -i ".stringData.NTFY_AUTH_USERS = \"alertmanager:$ntfy_fixture_am_hash:user,seerr:$ntfy_fixture_seerr_hash:user,automation:$ntfy_fixture_automation_hash:user,homepage:$ntfy_fixture_homepage_hash:user\"" \
  "$case_dir/plain.yaml"
ntfy_stub_encrypt "$case_dir/plain.yaml" "$NTFY_SECRET_FILE" "$NTFY_SOPS_POLICY_FILE"
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_status 1
assert_contains 'ntfy-subscriber-password'

# --- Rotation: Git-managed consumer switches immediately ------------------------
new_case rotate-alertmanager
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_ok
run_id 'rotate:monitoring:ntfy:alertmanager:sops' rotate alertmanager
assert_ok
tokens="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_TOKENS)"
new_am_token="$(tr ',' '\n' <<<"$tokens" | rg '^alertmanager:' | cut -d: -f2)"
[[ "$new_am_token" =~ ^tk_[a-z0-9]{29}$ ]] || fail "rotated token malformed: $new_am_token"
[[ "$new_am_token" != "$ntfy_fixture_am_token" ]] || fail 'token was not rotated'
rg -q "homepage:$ntfy_fixture_homepage_token" <<<"$tokens" || fail 'homepage token not preserved'
rg -q "seerr:$ntfy_fixture_seerr_token" <<<"$tokens" || fail 'seerr token not preserved'
assert_auth_yml_token "$new_am_token"
assert_stamps
assert_not_contains "$new_am_token"
assert_no_secret_echo

# --- Rotation: API-managed consumer stages, syncs, then finalizes ---------------
new_case rotate-seerr-staged
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_ok
run_id 'rotate:monitoring:ntfy:seerr:sops' rotate seerr
assert_ok
tokens="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_TOKENS)"
rg -q "seerr:$ntfy_fixture_seerr_token," <<<"$tokens," || fail 'current seerr token not kept during staging'
pending_entry="$(tr ',' '\n' <<<"$tokens" | rg '^seerr:.+:pending$')"
pending_token="$(cut -d: -f2 <<<"$pending_entry")"
[[ "$pending_token" =~ ^tk_[a-z0-9]{29}$ && "$pending_token" != "$ntfy_fixture_seerr_token" ]] ||
  fail 'pending token missing or malformed'
assert_contains 'ntfy-consumer-sync seerr'
assert_contains 'finalize seerr'
run_id 'finalize:monitoring:ntfy:seerr:sops' finalize seerr
assert_ok
tokens="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_TOKENS)"
[[ "$(tr ',' '\n' <<<"$tokens" | rg -c '^seerr:')" == '1' ]] || fail 'finalize must leave one seerr token'
rg -q "seerr:$pending_token" <<<"$tokens" || fail 'pending token not promoted'
! rg -q "$ntfy_fixture_seerr_token" <<<"$tokens" || fail 'previous token not revoked'
run_id 'finalize:monitoring:ntfy:seerr:sops' finalize seerr
assert_status 1
assert_contains 'no pending token'

# --- Rotation: the human password identity is refused ----------------------------
new_case rotate-subscriber
run_id 'rotate:monitoring:ntfy:subscriber:sops' rotate subscriber
assert_status 1
assert_contains 'ntfy-subscriber-password'

# --- Malformed registries -------------------------------------------------------
new_case registry-bad-status
yq -i '.identities.seerr.status = "paused"' "$NTFY_IDENTITIES_FILE"
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_status 1
assert_contains "invalid status 'paused'"

new_case registry-retired-extra
yq -i '.identities.automation.credential = "token"' "$NTFY_IDENTITIES_FILE"
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_status 1
assert_contains "retired identity 'automation' may only carry status/note"

new_case registry-duplicate-consumer
yq -i '.identities.seerr.consumer = "homepage-secret"' "$NTFY_IDENTITIES_FILE"
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_status 1
assert_contains "consumer 'homepage-secret' is claimed by both"

new_case registry-bad-acl
yq -i '.identities.seerr.access[0].permission = "admin"' "$NTFY_IDENTITIES_FILE"
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all
assert_status 1
assert_contains "malformed access entry 'media:admin'"

# --- Plaintext-leak guard + rollback --------------------------------------------
new_case leak-guard
before="$(git hash-object "$NTFY_SECRET_FILE")"
set +e
OUT="$(STUB_SOPS_PASSTHROUGH=1 NTFY_IDENTITY_CONFIRM='rotate:monitoring:ntfy:alertmanager:sops' \
  scripts/secrets/ntfy-identity.sh rotate alertmanager 2>&1)"
STATUS=$?
set -e
assert_status 1
assert_contains 'plaintext credential'
[[ "$(git hash-object "$NTFY_SECRET_FILE")" == "$before" ]] || fail 'original Secret was replaced'

# --- Subscriber password lifecycle ------------------------------------------------
new_case password-guard
run_pw - $'long-enough-password\nlong-enough-password\n'
assert_status 1
assert_contains "Set NTFY_SUBSCRIBER_PASSWORD_CONFIRM='write:monitoring:ntfy-subscriber:sops'"

new_case password-mismatch
before="$(git hash-object "$NTFY_SECRET_FILE")"
run_pw 'write:monitoring:ntfy-subscriber:sops' $'first-long-password\nsecond-long-password\n'
assert_status 1
assert_contains 'do not match'
[[ "$(git hash-object "$NTFY_SECRET_FILE")" == "$before" ]] || fail 'Secret changed on mismatch'

new_case password-too-short
run_pw 'write:monitoring:ntfy-subscriber:sops' $'short\nshort\n'
assert_status 1
assert_contains 'at least 12 characters'

new_case password-change
run_id 'reconcile:monitoring:ntfy:all:sops' reconcile all # adds auth.yml first
assert_ok
run_pw 'write:monitoring:ntfy-subscriber:sops' $'correct horse battery\ncorrect horse battery\n'
assert_ok
users="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_USERS)"
new_sub_hash="$(tr ',' '\n' <<<"$users" | rg '^subscriber:' | cut -d: -f2)"
[[ "$new_sub_hash" =~ ^\$2[aby]\$.+ && "$new_sub_hash" != "$ntfy_fixture_sub_hash" ]] ||
  fail 'subscriber hash not replaced with a fresh bcrypt hash'
rg -Fq "alertmanager:$ntfy_fixture_am_hash" <<<"$users" || fail 'alertmanager hash not preserved'
assert_secret_access "$expected_access_main"
assert_secret_tokens "$expected_tokens_main"
assert_auth_yml_token "$ntfy_fixture_am_token"
assert_stamps
assert_not_contains 'correct horse battery'
assert_not_contains "$new_sub_hash"

new_case password-bootstrap none
run_pw 'write:monitoring:ntfy-subscriber:sops' $'bootstrap password\nbootstrap password\n'
assert_ok
users="$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_USERS)"
[[ "$users" =~ ^subscriber:\$2[aby]\$.+:user$ ]] || fail "bootstrap users mismatch: $users"
[[ "$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_ACCESS)" == \
  'subscriber:critical:ro,subscriber:homelab:ro,subscriber:media:ro' ]] || fail 'bootstrap ACLs mismatch'
[[ "$(ntfy_secret_key "$NTFY_SECRET_FILE" NTFY_AUTH_TOKENS)" == '' ]] || fail 'bootstrap tokens must be empty'

echo 'ntfy-identity unit tests passed (guard, reconcile, migration, idempotency, generation, drift, rotation, staging, finalize, malformed registries, leak guard, subscriber password).'
