#!/usr/bin/env bash
# Exercise the guarded NocoDB SOPS Secret writer with synthetic values only.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export NOCODB_TEST_PERMISSIONS_LIB="$repo_root/scripts/test/lib/nocodb-permissions.sh"
just_bin="$(mise exec -- bash -c 'command -v just')"
yq_bin="$(mise exec -- bash -c 'command -v yq')"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-secrets-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
validator_root="$test_dir/validator-tree"
stub_bin="$test_dir/bin"
target='kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml'
kustomization='kubernetes/apps/automation-data/nocodb/app/kustomization.yaml'
expected_confirmation='write:automation-data:nocodb:sops'
expected_recipient='age1syntheticrecipientfornocodb000000000000000000000000000'
retained_connection_key='synthetic-retained-connection-key-00001'
fake_retained_connection_key="$retained_connection_key"
real_mktemp_bin="$(command -v mktemp)"
writer_mktemp_log="$test_dir/writer-mktemp.log"
age_preflight_log="$test_dir/age-preflight.log"
mv_log="$test_dir/mv.log"
declare -a secret_variables=(
  NOCODB_METADATA_PASSWORD
  NOCODB_AUTH_JWT_SECRET
  NOCODB_CONNECTION_ENCRYPT_KEY
  NOCODB_ADMIN_PASSWORD
  NOCODB_SOURCE_PROVISIONING_HEADER
)
declare -a synthetic_values=(
  'synthetic-nocodb-metadata-pass-%:/?@-01'
  'synthetic-nocodb-auth-jwt-secret-00002'
  'synthetic-nocodb-connection-key-000003'
  'synthetic-nocodb-admin-password-00004'
  'synthetic-nocodb-provisioning-header-005'
  'operator@example.test'
  "$retained_connection_key"
)

fail() {
  echo "NocoDB Secret writer test failed: $*" >&2
  exit 1
}

write_stubs() {
  mkdir -p "$stub_bin"

  cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == repo && "$2" == secrets ]] || {
  echo 'Unexpected just invocation from guarded recipe.' >&2
  exit 98
}
[[ -z "${AGE_PREFLIGHT_LOG:-}" ]] || printf '%s\n' invoked >>"$AGE_PREFLIGHT_LOG"
EOF

  cat >"$stub_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
created="$("$REAL_MKTEMP_BIN" "$@")"
source "${NOCODB_TEST_PERMISSIONS_LIB:?}"
mode="$(nocodb_test_mode "$created")"
[[ -z "${WRITER_MKTEMP_LOG:-}" ]] || \
  printf '%s\t%s\n' "$*" "$mode" >>"$WRITER_MKTEMP_LOG"
printf '%s\n' "$created"
EOF

  cat >"$stub_bin/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == filestatus ]]; then
  if [[ "${FAKE_SOPS_FAIL:-}" == filestatus ]]; then
    printf '%s\n' 'encrypted: false'
  else
    printf '%s\n' 'encrypted: true'
  fi
  exit 0
fi

if [[ "$1" == --decrypt && "$#" -eq 2 ]]; then
  [[ "${FAKE_SOPS_FAIL:-}" != decrypt ]] || exit 97
  cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: nocodb-credentials
  namespace: automation-data
type: Opaque
stringData:
  NC_CONNECTION_ENCRYPT_KEY: ${FAKE_RETAINED_CONNECTION_KEY}
YAML
  exit 0
fi

[[ "$1" == --encrypt && "$2" == --filename-override && "$#" -eq 4 ]] || {
  echo 'Unexpected SOPS invocation from guarded recipe.' >&2
  exit 98
}
[[ "${FAKE_SOPS_FAIL:-}" != encrypt ]] || exit 97

target="$3"
input="$4"
recipient='age1syntheticrecipientfornocodb000000000000000000000000000'
[[ "${FAKE_SOPS_WRONG_RECIPIENT:-}" != true ]] || recipient='age1wrongsyntheticrecipient00000000000000000000000000000000'
[[ "$target" == 'kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml' ]]
[[ "$("$REAL_YQ_BIN" -r '.metadata | [.name, .namespace] | join(",")' "$input")" == 'nocodb-credentials,automation-data' ]]
[[ "$("$REAL_YQ_BIN" -r '.stringData | keys | sort | join(",")' "$input")" == \
  'DATABASE_URL,NC_ADMIN_EMAIL,NC_ADMIN_PASSWORD,NC_AUTH_JWT_SECRET,NC_CONNECTION_ENCRYPT_KEY,metadata-password,source-provisioning-header' ]]
[[ "$("$REAL_YQ_BIN" -r '.stringData."metadata-password"' "$input")" == \
  'synthetic-nocodb-metadata-pass-%:/?@-01' ]]
[[ "$("$REAL_YQ_BIN" -r '.stringData.DATABASE_URL' "$input")" == \
  'postgres://nocodb_metadata:synthetic-nocodb-metadata-pass-%25%3A%2F%3F%40-01@automation-data-postgresql.automation-data.svc.cluster.local:5432/nocodb?sslmode=disable' ]]
if [[ -n "${FAKE_EXPECT_CONNECTION_KEY:-}" ]]; then
  [[ "$("$REAL_YQ_BIN" -r '.stringData.NC_CONNECTION_ENCRYPT_KEY' "$input")" == "$FAKE_EXPECT_CONNECTION_KEY" ]]
fi
if [[ "${FAKE_SOPS_MALFORMED:-}" == true ]]; then
  cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: wrong-secret
  namespace: wrong-namespace
type: Opaque
stringData:
  wrong-key: ENC[synthetic]
sops:
  age:
    - recipient: $recipient
YAML
  exit 0
fi
cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: nocodb-credentials
  namespace: automation-data
type: Opaque
stringData:
  DATABASE_URL: ENC[synthetic]
  metadata-password: ENC[synthetic]
  NC_AUTH_JWT_SECRET: ENC[synthetic]
  NC_CONNECTION_ENCRYPT_KEY: ENC[synthetic]
  NC_ADMIN_EMAIL: ENC[synthetic]
  NC_ADMIN_PASSWORD: ENC[synthetic]
  source-provisioning-header: ENC[synthetic]
sops:
  age:
    - recipient: $recipient
YAML
EOF

  cat >"$stub_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source="${@: -2:1}"
destination="${!#}"
[[ -z "${FAKE_MV_LOG:-}" ]] || printf '%s\t%s\n' "$source" "$destination" >>"$FAKE_MV_LOG"
if [[ -n "${FAKE_MV_FAIL_TARGET:-}" && "$destination" == "$FAKE_MV_FAIL_TARGET" && \
  ! -e "$FAKE_MV_FAIL_MARKER" ]]; then
  : >"$FAKE_MV_FAIL_MARKER"
  exit 96
fi
exec /bin/mv "$@"
EOF

  chmod 700 "$stub_bin/just" "$stub_bin/mktemp" "$stub_bin/sops" "$stub_bin/mv"
}

reset_tree() {
  rm -rf -- "$tree_root"
  rm -f -- "$writer_mktemp_log" "$age_preflight_log" "$mv_log"
  mkdir -p "$tree_root/.just" "$(dirname -- "$tree_root/$target")"
  cp "$repo_root/.just/repository.just" "$tree_root/.just/repository.just"
  cat >"$tree_root/.justfile" <<'EOF'
set shell := ["bash", "-euo", "pipefail", "-c"]
mod repo ".just/repository.just"
EOF
  cat >"$tree_root/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^talos/talsecret\\.sops\\.ya?ml$
    age: age1synthetictalosrecipient00000000000000000000000000000000000
    encrypted_regex: '^(.*)$'
  - path_regex: ^kubernetes/.*\\.sops\\.ya?ml$
    age: $expected_recipient
    encrypted_regex: '^(data|stringData)$'
EOF
  cat >"$tree_root/$kustomization" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: automation-data
resources:
  - ./helmrelease.yaml
EOF
}

set_all_inputs() {
  NOCODB_METADATA_PASSWORD="${synthetic_values[0]}"
  NOCODB_AUTH_JWT_SECRET="${synthetic_values[1]}"
  NOCODB_CONNECTION_ENCRYPT_KEY="${synthetic_values[2]}"
  NOCODB_ADMIN_PASSWORD="${synthetic_values[3]}"
  NOCODB_SOURCE_PROVISIONING_HEADER="${synthetic_values[4]}"
  NOCODB_ADMIN_EMAIL="${synthetic_values[5]}"
  NOCODB_SECRETS_CONFIRM="$expected_confirmation"
  unset NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY
  unset FAKE_SOPS_FAIL FAKE_SOPS_MALFORMED FAKE_SOPS_WRONG_RECIPIENT
  unset FAKE_MV_FAIL_TARGET FAKE_MV_FAIL_MARKER FAKE_EXPECT_CONNECTION_KEY
  fake_retained_connection_key="$retained_connection_key"
}

run_recipe() {
  local output_file="$test_dir/command-output"
  local -a env_args=(
    "PATH=$stub_bin:$PATH"
    "REAL_YQ_BIN=$yq_bin"
    "REAL_MKTEMP_BIN=$real_mktemp_bin"
    "WRITER_MKTEMP_LOG=$writer_mktemp_log"
    "AGE_PREFLIGHT_LOG=$age_preflight_log"
    "FAKE_MV_LOG=$mv_log"
    "FAKE_RETAINED_CONNECTION_KEY=$fake_retained_connection_key"
    "NOCODB_METADATA_PASSWORD=${NOCODB_METADATA_PASSWORD-}"
    "NOCODB_AUTH_JWT_SECRET=${NOCODB_AUTH_JWT_SECRET-}"
    "NOCODB_CONNECTION_ENCRYPT_KEY=${NOCODB_CONNECTION_ENCRYPT_KEY-}"
    "NOCODB_ADMIN_PASSWORD=${NOCODB_ADMIN_PASSWORD-}"
    "NOCODB_SOURCE_PROVISIONING_HEADER=${NOCODB_SOURCE_PROVISIONING_HEADER-}"
    "NOCODB_ADMIN_EMAIL=${NOCODB_ADMIN_EMAIL-}"
    "NOCODB_SECRETS_CONFIRM=${NOCODB_SECRETS_CONFIRM-}"
  )
  [[ -z "${NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY:-}" ]] || \
    env_args+=("NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY=$NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY")
  [[ -z "${FAKE_SOPS_FAIL:-}" ]] || env_args+=("FAKE_SOPS_FAIL=$FAKE_SOPS_FAIL")
  [[ -z "${FAKE_SOPS_MALFORMED:-}" ]] || env_args+=("FAKE_SOPS_MALFORMED=$FAKE_SOPS_MALFORMED")
  [[ -z "${FAKE_SOPS_WRONG_RECIPIENT:-}" ]] || env_args+=("FAKE_SOPS_WRONG_RECIPIENT=$FAKE_SOPS_WRONG_RECIPIENT")
  [[ -z "${FAKE_EXPECT_CONNECTION_KEY:-}" ]] || env_args+=("FAKE_EXPECT_CONNECTION_KEY=$FAKE_EXPECT_CONNECTION_KEY")
  if [[ -n "${FAKE_MV_FAIL_TARGET:-}" ]]; then
    env_args+=("FAKE_MV_FAIL_TARGET=$FAKE_MV_FAIL_TARGET" "FAKE_MV_FAIL_MARKER=$FAKE_MV_FAIL_MARKER")
  fi

  set +e
  (
    cd "$tree_root"
    env "${env_args[@]}" "$just_bin" --justfile .justfile repo nocodb-secrets
  ) >"$output_file" 2>&1
  RECIPE_EXIT_CODE="$?"
  set -e
  RECIPE_OUTPUT="$(<"$output_file")"
}

assert_no_plaintext() {
  local content="$1" value
  local -a values=(
    "${synthetic_values[@]}"
    "${NOCODB_METADATA_PASSWORD:-}"
    "${NOCODB_AUTH_JWT_SECRET:-}"
    "${NOCODB_CONNECTION_ENCRYPT_KEY:-}"
    "${NOCODB_ADMIN_PASSWORD:-}"
    "${NOCODB_SOURCE_PROVISIONING_HEADER:-}"
    "${NOCODB_ADMIN_EMAIL:-}"
    "${NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY:-}"
    "$fake_retained_connection_key"
  )
  for value in "${values[@]}"; do
    [[ -z "$value" ]] && continue
    ! rg -Fq -U -- "$value" <<<"$content" || fail 'a supplied value appeared in output or ciphertext'
  done
}

expect_failure() {
  local message="$1"
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || fail 'the guarded recipe unexpectedly succeeded'
  rg -Fq -- "$message" <<<"$RECIPE_OUTPUT" || fail "missing refusal: $message"
  assert_no_plaintext "$RECIPE_OUTPUT"
}

assert_no_input_side_effects() {
  [[ ! -e "$tree_root/$target" ]] || fail 'a refused input changed the Secret target'
  [[ ! -e "$writer_mktemp_log" ]] || fail 'a refused input created a writer workspace'
  [[ ! -e "$age_preflight_log" ]] || fail 'a refused input invoked the age preflight'
  ! rg -Fq './nocodb-credentials.sops.yaml' "$tree_root/$kustomization" || \
    fail 'a refused input changed the Kustomization'
}

assert_target_contract() {
  local artifact="$tree_root/$target"
  [[ -f "$artifact" ]] || fail 'the guarded recipe did not write its Secret target'
  [[ "$("$yq_bin" -r '.metadata | [.name, .namespace] | join(",")' "$artifact")" == 'nocodb-credentials,automation-data' ]]
  [[ "$("$yq_bin" -r '.stringData | keys | sort | join(",")' "$artifact")" == \
    'DATABASE_URL,NC_ADMIN_EMAIL,NC_ADMIN_PASSWORD,NC_AUTH_JWT_SECRET,NC_CONNECTION_ENCRYPT_KEY,metadata-password,source-provisioning-header' ]]
  [[ "$("$yq_bin" -r '.sops.age[].recipient' "$artifact")" == "$expected_recipient" ]]
  [[ "$("$yq_bin" -r 'has("data") | not' "$artifact")" == true ]]
  rg -qx '  - ./nocodb-credentials.sops.yaml' "$tree_root/$kustomization" || \
    fail 'the guarded recipe did not add the Secret to the NocoDB Kustomization'
  assert_no_plaintext "$(<"$artifact")"
  assert_no_plaintext "$RECIPE_OUTPUT"
}

assert_atomic_install() {
  local source destination secret_moves=0 kustomization_moves=0
  while IFS=$'\t' read -r source destination; do
    if [[ "$destination" == "$target" ]]; then
      [[ "$(basename -- "$source")" == candidate ]] || fail 'Secret was not directly replaced from its candidate'
      secret_moves=$((secret_moves + 1))
    elif [[ "$destination" == "$kustomization" ]]; then
      [[ "$(basename -- "$source")" == kustomization ]] || fail 'Kustomization was not directly replaced from its candidate'
      kustomization_moves=$((kustomization_moves + 1))
    fi
  done <"$mv_log"
  [[ "$secret_moves" -eq 1 && "$kustomization_moves" -eq 1 ]] || \
    fail 'first creation did not atomically replace exactly the Secret and Kustomization'
}

seed_existing_target() {
  printf '%s\n' existing-encrypted-artifact >"$tree_root/$target"
  printf '%s\n' '  - ./nocodb-credentials.sops.yaml' >>"$tree_root/$kustomization"
}

assert_existing_files() {
  [[ "$(<"$tree_root/$target")" == existing-encrypted-artifact ]] || \
    fail 'a failed guarded write did not restore the existing Secret'
  [[ "$(tail -n 1 "$tree_root/$kustomization")" == '  - ./nocodb-credentials.sops.yaml' ]] || \
    fail 'a failed guarded write did not restore the existing Kustomization'
}

assert_absent_outputs() {
  [[ ! -e "$tree_root/$target" ]] || fail 'a failed candidate write installed a Secret'
  ! rg -Fq './nocodb-credentials.sops.yaml' "$tree_root/$kustomization" || \
    fail 'a failed candidate write changed the Kustomization'
  assert_no_plaintext "$RECIPE_OUTPUT"
}

assert_update_install() {
  local source destination secret_moves=0 kustomization_moves=0
  while IFS=$'\t' read -r source destination; do
    if [[ "$destination" == "$target" ]]; then
      [[ "$(basename -- "$source")" == candidate ]] || fail 'repeat write did not replace the Secret from its candidate'
      secret_moves=$((secret_moves + 1))
    elif [[ "$destination" == "$kustomization" ]]; then
      kustomization_moves=$((kustomization_moves + 1))
    fi
  done <"$mv_log"
  [[ "$secret_moves" -eq 1 && "$kustomization_moves" -eq 0 ]] || \
    fail 'repeat write changed the NocoDB Kustomization'
}

reset_validator_tree() {
  rm -rf -- "$validator_root"
  mkdir -p "$validator_root/kubernetes/apps/automation-data"
  cp -R "$repo_root/kubernetes/apps/automation-data/nocodb" \
    "$validator_root/kubernetes/apps/automation-data/nocodb"
  cp "$repo_root/kubernetes/apps/automation-data/kustomization.yaml" \
    "$validator_root/kubernetes/apps/automation-data/kustomization.yaml"
  cp "$repo_root/.sops.yaml" "$validator_root/.sops.yaml"
  mkdir -p "$validator_root/scripts/validate"
  cp "$repo_root/scripts/validate/nocodb.sh" "$validator_root/scripts/validate/nocodb.sh"
}

write_validator_secret() {
  local name="$1" recipient="$2"
  cat >"$validator_root/$target" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: automation-data
type: Opaque
stringData:
  DATABASE_URL: ENC[synthetic]
  metadata-password: ENC[synthetic]
  NC_AUTH_JWT_SECRET: ENC[synthetic]
  NC_CONNECTION_ENCRYPT_KEY: ENC[synthetic]
  NC_ADMIN_EMAIL: ENC[synthetic]
  NC_ADMIN_PASSWORD: ENC[synthetic]
  source-provisioning-header: ENC[synthetic]
sops:
  age:
    - recipient: $recipient
YAML
  printf '%s\n' '  - ./nocodb-credentials.sops.yaml' >>"$validator_root/$kustomization"
}

run_validator() {
  local output_file="$test_dir/validator-output"
  set +e
  (
    cd "$validator_root"
    env "PATH=$stub_bin:$PATH" "REAL_MKTEMP_BIN=$real_mktemp_bin" \
      "FAKE_SOPS_FAIL=${FAKE_SOPS_FAIL:-}" \
      scripts/validate/nocodb.sh
  ) >"$output_file" 2>&1
  VALIDATOR_EXIT_CODE="$?"
  set -e
  VALIDATOR_OUTPUT="$(<"$output_file")"
}

write_stubs

# RED: the complete public recipe interface must exist before its behavior is exercised.
reset_tree
(
  cd "$tree_root"
  "$just_bin" --justfile .justfile --dry-run repo nocodb-secrets >/dev/null 2>&1
) || fail 'missing repo nocodb-secrets recipe'

set_all_inputs
run_recipe
[[ "$RECIPE_EXIT_CODE" -eq 0 ]] || fail 'complete synthetic input was rejected'
assert_target_contract
assert_atomic_install
[[ -s "$age_preflight_log" ]] || fail 'successful write skipped age preflight'
rg -Fq "$(dirname -- "$target")/.nocodb-secrets." "$writer_mktemp_log" || \
  fail 'candidate staging did not use the target filesystem'
awk -F '\t' '$2 != "700" {exit 1}' "$writer_mktemp_log" || \
  fail 'writer temporary directories are not mode 0700'

: >"$mv_log"
NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY="$retained_connection_key"
FAKE_EXPECT_CONNECTION_KEY="$retained_connection_key"
run_recipe
[[ "$RECIPE_EXIT_CODE" -eq 0 ]] || fail 'repeat synthetic input was rejected'
assert_target_contract
assert_update_install

for missing_variable in "${secret_variables[@]}"; do
  reset_tree
  set_all_inputs
  unset "$missing_variable"
  run_recipe
  expect_failure "Set $missing_variable"
  assert_no_input_side_effects
done

reset_tree
set_all_inputs
NOCODB_SECRETS_CONFIRM='write:automation-data:wrong:sops'
run_recipe
expect_failure 'Refusing to write the automation-data NocoDB Secret.'
assert_no_input_side_effects

for short_variable in "${secret_variables[@]}"; do
  reset_tree
  set_all_inputs
  printf -v "$short_variable" '%s' too-short
  run_recipe
  expect_failure "$short_variable must be at least 32 characters"
  assert_no_input_side_effects
done

for invalid_email in 'operator.example.test' 'operator @example.test' $'operator\n@example.test'; do
  reset_tree
  set_all_inputs
  NOCODB_ADMIN_EMAIL="$invalid_email"
  run_recipe
  expect_failure 'NOCODB_ADMIN_EMAIL must be one non-whitespace email address'
  assert_no_input_side_effects
done

reset_tree
seed_existing_target
set_all_inputs
NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY="$retained_connection_key"
FAKE_EXPECT_CONNECTION_KEY="$retained_connection_key"
run_recipe
[[ "$RECIPE_EXIT_CODE" -eq 0 ]] || fail 'matching recovery input was rejected'
assert_target_contract

for recovery_key in '' 'synthetic-wrong-recovery-connection-key'; do
  reset_tree
  seed_existing_target
  set_all_inputs
  NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY="$recovery_key"
  run_recipe
  expect_failure 'Refusing to replace the retained NC_CONNECTION_ENCRYPT_KEY.'
  assert_existing_files
done

reset_tree
seed_existing_target
set_all_inputs
fake_retained_connection_key='too-short'
NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY="$fake_retained_connection_key"
run_recipe
[[ "$RECIPE_EXIT_CODE" -ne 0 ]] || fail 'short retained effective connection key was accepted'
rg -Fq 'retained NC_CONNECTION_ENCRYPT_KEY must be at least 32 characters' <<<"$RECIPE_OUTPUT" || \
  fail 'short retained effective connection key did not report its refusal'
assert_no_plaintext "$RECIPE_OUTPUT"
assert_existing_files

for failure_mode in encrypt filestatus malformed wrong-recipient; do
  reset_tree
  set_all_inputs
  case "$failure_mode" in
    encrypt|filestatus) FAKE_SOPS_FAIL="$failure_mode" ;;
    malformed) FAKE_SOPS_MALFORMED=true ;;
    wrong-recipient) FAKE_SOPS_WRONG_RECIPIENT=true ;;
  esac
  run_recipe
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || fail "$failure_mode candidate failure unexpectedly succeeded"
  assert_absent_outputs
done

reset_tree
seed_existing_target
set_all_inputs
NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY="$retained_connection_key"
FAKE_SOPS_FAIL=decrypt
run_recipe
[[ "$RECIPE_EXIT_CODE" -ne 0 ]] || fail 'decrypt failure unexpectedly succeeded'
assert_existing_files
assert_no_plaintext "$RECIPE_OUTPUT"

for failed_target in "$target" "$kustomization"; do
  reset_tree
  set_all_inputs
  FAKE_MV_FAIL_TARGET="$failed_target"
  FAKE_MV_FAIL_MARKER="$test_dir/mv-failed-$(basename -- "$failed_target")"
  run_recipe
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || fail "install failure for $failed_target unexpectedly succeeded"
  [[ ! -e "$tree_root/$target" ]] || fail 'rollback did not remove the newly installed Secret'
  ! rg -Fq './nocodb-credentials.sops.yaml' "$tree_root/$kustomization" || \
    fail 'rollback did not restore the original Kustomization'
  assert_no_plaintext "$RECIPE_OUTPUT"
done

reset_validator_tree
write_validator_secret wrong-secret "$expected_recipient"
run_validator
[[ "$VALIDATOR_EXIT_CODE" -ne 0 ]] || fail 'validator accepted a malformed NocoDB Secret'
rg -Fq 'unexpected identity' <<<"$VALIDATOR_OUTPUT" || fail 'validator did not reject malformed Secret identity'

reset_validator_tree
write_validator_secret nocodb-credentials age1wrongsyntheticrecipient00000000000000000000000000000000
run_validator
[[ "$VALIDATOR_EXIT_CODE" -ne 0 ]] || fail 'validator accepted a mismatched NocoDB recipient'
rg -Fq 'unexpected SOPS age recipient' <<<"$VALIDATOR_OUTPUT" || fail 'validator did not reject mismatched recipient'

echo 'NocoDB guarded Secret writer tests passed.'
