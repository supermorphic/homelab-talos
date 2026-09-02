#!/usr/bin/env bash
# Exercise the guarded automation-data PostgreSQL SOPS Secret writer with synthetic values.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
just_bin="$(mise exec -- bash -c 'command -v just')"
yq_bin="$(mise exec -- bash -c 'command -v yq')"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-automation-data-secrets-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
stub_bin="$test_dir/bin"
target='kubernetes/apps/automation-data/postgresql/app/postgresql-credentials.sops.yaml'
expected_confirmation='write:automation-data:postgresql:sops'
expected_recipient='age1syntheticrecipientforautomationdata0000000000000000000000000'
real_mktemp_bin="$(command -v mktemp)"
writer_mktemp_log="$test_dir/writer-mktemp.log"
age_preflight_log="$test_dir/age-preflight.log"
mv_log="$test_dir/mv.log"
declare -a secret_variables=(
  AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD
  AUTOMATION_DATA_PROVISIONER_PASSWORD
  AUTOMATION_DATA_BACKUP_PASSWORD
  AUTOMATION_DATA_EXPORTER_PASSWORD
)
declare -a synthetic_values=(
  'synthetic-automation-superuser-0001'
  'synthetic-automation-provisioner-002'
  'synthetic-automation-backup-pass-003'
  'synthetic-automation-exporter-%:/?@-04'
)

fail() {
  echo "automation-data Secret writer test failed: $*" >&2
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
[[ -z "${WRITER_MKTEMP_LOG:-}" ]] || printf '%s\n' "$*" >>"$WRITER_MKTEMP_LOG"
exec "$REAL_MKTEMP_BIN" "$@"
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

[[ "$1" == --encrypt && "$2" == --filename-override && "$#" -eq 4 ]] || {
  echo 'Unexpected SOPS encryption invocation from guarded recipe.' >&2
  exit 98
}
[[ "${FAKE_SOPS_FAIL:-}" != encrypt ]] || exit 97

target="$3"
input="$4"
recipient='age1syntheticrecipientforautomationdata0000000000000000000000000'
[[ "${FAKE_SOPS_WRONG_RECIPIENT:-}" != true ]] || \
  recipient='age1wrongsyntheticrecipient00000000000000000000000000000000'
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

[[ "$target" == 'kubernetes/apps/automation-data/postgresql/app/postgresql-credentials.sops.yaml' ]]
[[ "$("$REAL_YQ_BIN" -r '.metadata | [.name, .namespace] | join(",")' "$input")" == \
  'postgresql-credentials,automation-data' ]]
[[ "$("$REAL_YQ_BIN" -r '.stringData | keys | sort | join(",")' "$input")" == \
  'backup-password,exporter-dsn,exporter-password,postgres-superuser-password,provisioner-password' ]]
[[ "$("$REAL_YQ_BIN" -r '.stringData."exporter-dsn"' "$input")" == \
  'postgresql://automation_data_exporter:synthetic-automation-exporter-%25%3A%2F%3F%40-04@127.0.0.1:5432/automation_data_control?sslmode=disable' ]]
cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-credentials
  namespace: automation-data
type: Opaque
stringData:
  postgres-superuser-password: ENC[synthetic]
  provisioner-password: ENC[synthetic]
  backup-password: ENC[synthetic]
  exporter-password: ENC[synthetic]
  exporter-dsn: ENC[synthetic]
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
if [[ "${FAKE_MV_FAIL_AFTER_REPLACE:-}" == true && \
  "$destination" == 'kubernetes/apps/automation-data/postgresql/app/postgresql-credentials.sops.yaml' && \
  ! -e "$FAKE_MV_FAIL_MARKER" ]]; then
  /bin/mv "$@"
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
  mkdir -p "$tree_root/.just" "$tree_root/$(dirname -- "$target")"
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
}

set_all_inputs() {
  AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD="${synthetic_values[0]}"
  AUTOMATION_DATA_PROVISIONER_PASSWORD="${synthetic_values[1]}"
  AUTOMATION_DATA_BACKUP_PASSWORD="${synthetic_values[2]}"
  AUTOMATION_DATA_EXPORTER_PASSWORD="${synthetic_values[3]}"
  AUTOMATION_DATA_SECRETS_CONFIRM="$expected_confirmation"
  unset FAKE_SOPS_FAIL FAKE_SOPS_MALFORMED FAKE_SOPS_WRONG_RECIPIENT
  unset FAKE_MV_FAIL_AFTER_REPLACE FAKE_MV_FAIL_MARKER
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
    "AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD=${AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD-}"
    "AUTOMATION_DATA_PROVISIONER_PASSWORD=${AUTOMATION_DATA_PROVISIONER_PASSWORD-}"
    "AUTOMATION_DATA_BACKUP_PASSWORD=${AUTOMATION_DATA_BACKUP_PASSWORD-}"
    "AUTOMATION_DATA_EXPORTER_PASSWORD=${AUTOMATION_DATA_EXPORTER_PASSWORD-}"
    "AUTOMATION_DATA_SECRETS_CONFIRM=${AUTOMATION_DATA_SECRETS_CONFIRM-}"
  )
  [[ -z "${FAKE_SOPS_FAIL:-}" ]] || env_args+=("FAKE_SOPS_FAIL=$FAKE_SOPS_FAIL")
  [[ -z "${FAKE_SOPS_MALFORMED:-}" ]] || env_args+=("FAKE_SOPS_MALFORMED=$FAKE_SOPS_MALFORMED")
  [[ -z "${FAKE_SOPS_WRONG_RECIPIENT:-}" ]] || \
    env_args+=("FAKE_SOPS_WRONG_RECIPIENT=$FAKE_SOPS_WRONG_RECIPIENT")
  if [[ "${FAKE_MV_FAIL_AFTER_REPLACE:-}" == true ]]; then
    env_args+=("FAKE_MV_FAIL_AFTER_REPLACE=true" "FAKE_MV_FAIL_MARKER=$FAKE_MV_FAIL_MARKER")
  fi

  set +e
  (
    cd "$tree_root"
    env "${env_args[@]}" "$just_bin" --justfile .justfile repo automation-data-secrets
  ) >"$output_file" 2>&1
  RECIPE_EXIT_CODE="$?"
  set -e
  RECIPE_OUTPUT="$(<"$output_file")"
}

assert_no_plaintext() {
  local content="$1" value
  for value in "${synthetic_values[@]}"; do
    ! rg -Fq -- "$value" <<<"$content" || fail 'a supplied value appeared in output or ciphertext'
  done
}

assert_no_input_side_effects() {
  [[ ! -e "$tree_root/$target" ]] || fail 'a refused input changed the target'
  [[ ! -e "$writer_mktemp_log" ]] || fail 'a refused input created a writer workspace'
  [[ ! -e "$age_preflight_log" ]] || fail 'a refused input invoked the age preflight'
}

expect_failure() {
  local message="$1"
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || fail 'the guarded recipe unexpectedly succeeded'
  rg -Fq -- "$message" <<<"$RECIPE_OUTPUT" || fail "missing refusal: $message"
  assert_no_plaintext "$RECIPE_OUTPUT"
}

assert_target_contract() {
  local artifact="$tree_root/$target"
  [[ -f "$artifact" ]] || fail 'the guarded recipe did not write its target'
  [[ "$("$yq_bin" -r '.metadata | [.name, .namespace] | join(",")' "$artifact")" == \
    'postgresql-credentials,automation-data' ]]
  [[ "$("$yq_bin" -r '.stringData | keys | sort | join(",")' "$artifact")" == \
    'backup-password,exporter-dsn,exporter-password,postgres-superuser-password,provisioner-password' ]]
  [[ "$("$yq_bin" -r '.sops.age[].recipient' "$artifact")" == "$expected_recipient" ]]
  [[ "$("$yq_bin" -r 'has("data") | not' "$artifact")" == true ]]
  assert_no_plaintext "$(<"$artifact")"
  assert_no_plaintext "$RECIPE_OUTPUT"
}

seed_existing_target() {
  printf '%s\n' existing-encrypted-artifact >"$tree_root/$target"
}

assert_existing_target() {
  [[ "$(<"$tree_root/$target")" == existing-encrypted-artifact ]] || \
    fail 'a failed guarded write did not preserve the prior target'
}

write_stubs
reset_tree

# Make the first RED failure name the missing production interface directly.
(
  cd "$tree_root"
  "$just_bin" --justfile .justfile --dry-run repo automation-data-secrets \
    >/dev/null 2>&1
) || fail 'missing repo automation-data-secrets recipe'

set_all_inputs
run_recipe
[[ "$RECIPE_EXIT_CODE" -eq 0 ]] || fail 'complete synthetic input was rejected'
assert_target_contract
[[ -s "$age_preflight_log" ]] || fail 'successful write skipped age preflight'
rg -Fq "$(dirname -- "$target")/.automation-data-secrets." "$writer_mktemp_log" || \
  fail 'candidate staging did not use the target filesystem'
candidate_move="$(awk -F '\t' -v target="$target" '$2 == target {print $1; exit}' "$mv_log")"
[[ "$(basename -- "$candidate_move")" == candidate ]] || \
  fail 'canonical target was not atomically replaced from candidate'

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
AUTOMATION_DATA_SECRETS_CONFIRM='write:automation-data:wrong:sops'
run_recipe
expect_failure 'Refusing to write the automation-data PostgreSQL Secret.'
assert_no_input_side_effects

for short_variable in "${secret_variables[@]}"; do
  reset_tree
  set_all_inputs
  printf -v "$short_variable" '%s' too-short
  run_recipe
  expect_failure "$short_variable must be at least 32 characters"
  ! rg -Fq too-short <<<"$RECIPE_OUTPUT" || fail 'short rejected value appeared in output'
  assert_no_input_side_effects
done

for failure_mode in encrypt filestatus; do
  reset_tree
  seed_existing_target
  set_all_inputs
  FAKE_SOPS_FAIL="$failure_mode"
  run_recipe
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || fail "$failure_mode failure unexpectedly succeeded"
  assert_no_plaintext "$RECIPE_OUTPUT"
  assert_existing_target
done

for invalid_artifact in malformed wrong-recipient; do
  reset_tree
  seed_existing_target
  set_all_inputs
  if [[ "$invalid_artifact" == malformed ]]; then
    FAKE_SOPS_MALFORMED=true
  else
    FAKE_SOPS_WRONG_RECIPIENT=true
  fi
  run_recipe
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || fail "$invalid_artifact artifact unexpectedly succeeded"
  assert_no_plaintext "$RECIPE_OUTPUT"
  assert_existing_target
done

reset_tree
seed_existing_target
set_all_inputs
FAKE_MV_FAIL_AFTER_REPLACE=true
FAKE_MV_FAIL_MARKER="$test_dir/mv-failed-after-replace"
run_recipe
[[ "$RECIPE_EXIT_CODE" -ne 0 ]] || fail 'post-replacement failure unexpectedly succeeded'
assert_no_plaintext "$RECIPE_OUTPUT"
assert_existing_target

echo 'automation-data guarded Secret writer tests passed.'
