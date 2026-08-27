#!/usr/bin/env bash
# Exercise the guarded n8n SOPS Secret writer with synthetic values only.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
just_bin="$(mise exec -- bash -c 'command -v just')"
yq_bin="$(mise exec -- bash -c 'command -v yq')"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-n8n-secrets-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
validator_tree="$test_dir/validator-tree"
stub_bin="$test_dir/bin"
target_runtime='kubernetes/apps/automation/n8n/app/n8n-runtime.sops.yaml'
target_postgresql='kubernetes/apps/automation/n8n-postgresql/app/postgresql-credentials.sops.yaml'
target_canary='kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml'
expected_confirmation='write:automation:n8n-platform:sops'
expected_recipient='age1syntheticrecipientforn8nplatform00000000000000000000000000'
declare -a targets=("$target_runtime" "$target_postgresql" "$target_canary")
declare -a secret_variables=(
  N8N_ENCRYPTION_KEY
  N8N_DB_PASSWORD
  POSTGRES_SUPERUSER_PASSWORD
  POSTGRES_BACKUP_PASSWORD
  POSTGRES_EXPORTER_PASSWORD
  N8N_CANARY_TOKEN
)
declare -a synthetic_values=(
  'synthetic-n8n-encryption-key-00001'
  'synthetic-n8n-db-password-000002'
  'synthetic-postgres-superuser-0003'
  'synthetic-postgres-backup-pass-0004'
  'synthetic-exporter-pass-%:/?@-05'
  'synthetic-n8n-canary-token-00006'
)

write_stubs() {
  mkdir -p "$stub_bin"

  cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == 'repo' && "$2" == 'secrets' ]] || {
  echo 'Unexpected just invocation from guarded recipe.' >&2
  exit 98
}
EOF

  cat >"$stub_bin/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == 'filestatus' ]]; then
  [[ "${FAKE_SOPS_FAIL:-}" != 'filestatus' ]] || {
    printf '%s\n' 'encrypted: false'
    exit 0
  }
  printf '%s\n' 'encrypted: true'
  exit 0
fi

[[ "$1" == '--encrypt' && "$2" == '--filename-override' && "$#" -eq 4 ]] || {
  echo 'Unexpected SOPS encryption invocation from guarded recipe.' >&2
  exit 98
}
[[ "${FAKE_SOPS_FAIL:-}" != 'encrypt' ]] || exit 97

target="$3"
input="$4"
recipient='age1syntheticrecipientforn8nplatform00000000000000000000000000'
[[ "${FAKE_SOPS_WRONG_RECIPIENT:-}" != 'true' ]] || recipient='age1wrongsyntheticrecipient00000000000000000000000000000000'
if [[ "${FAKE_SOPS_MALFORMED_TARGET:-}" == "$target" ]]; then
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
case "$target" in
  kubernetes/apps/automation/n8n/app/n8n-runtime.sops.yaml)
    [[ "$("$REAL_YQ_BIN" -r '.metadata | [.name, .namespace] | join(",")' "$input")" == 'n8n-runtime,automation' ]]
    [[ "$("$REAL_YQ_BIN" -r '.stringData | keys | sort | join(",")' "$input")" == 'N8N_ENCRYPTION_KEY,N8N_HOST,N8N_PORT,N8N_PROTOCOL' ]]
    [[ "$("$REAL_YQ_BIN" -r '.stringData.N8N_HOST' "$input")" == 'n8n.lab.supermorphic.com' ]]
    [[ "$("$REAL_YQ_BIN" -r '.stringData.N8N_PORT' "$input")" == '5678' ]]
    [[ "$("$REAL_YQ_BIN" -r '.stringData.N8N_PROTOCOL' "$input")" == 'https' ]]
    cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: n8n-runtime
  namespace: automation
type: Opaque
stringData:
  N8N_ENCRYPTION_KEY: ENC[synthetic]
  N8N_HOST: ENC[synthetic]
  N8N_PORT: ENC[synthetic]
  N8N_PROTOCOL: ENC[synthetic]
sops:
  age:
    - recipient: $recipient
YAML
    ;;
  kubernetes/apps/automation/n8n-postgresql/app/postgresql-credentials.sops.yaml)
    [[ "$("$REAL_YQ_BIN" -r '.metadata | [.name, .namespace] | join(",")' "$input")" == 'postgresql-credentials,automation' ]]
    [[ "$("$REAL_YQ_BIN" -r '.stringData | keys | sort | join(",")' "$input")" == 'backup-password,exporter-dsn,exporter-password,n8n-password,postgres-superuser-password' ]]
    [[ "$("$REAL_YQ_BIN" -r '.stringData."exporter-dsn"' "$input")" == 'postgresql://n8n_exporter:synthetic-exporter-pass-%25%3A%2F%3F%40-05@127.0.0.1:5432/n8n?sslmode=disable' ]]
    cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-credentials
  namespace: automation
type: Opaque
stringData:
  postgres-superuser-password: ENC[synthetic]
  n8n-password: ENC[synthetic]
  backup-password: ENC[synthetic]
  exporter-password: ENC[synthetic]
  exporter-dsn: ENC[synthetic]
sops:
  age:
    - recipient: $recipient
YAML
    ;;
  kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml)
    [[ "$("$REAL_YQ_BIN" -r '.metadata | [.name, .namespace] | join(",")' "$input")" == 'n8n-canary,gatus' ]]
    [[ "$("$REAL_YQ_BIN" -r '.stringData | keys | sort | join(",")' "$input")" == 'token' ]]
    cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: n8n-canary
  namespace: gatus
type: Opaque
stringData:
  token: ENC[synthetic]
sops:
  age:
    - recipient: $recipient
YAML
    ;;
  *)
    echo 'Unexpected SOPS target from guarded recipe.' >&2
    exit 96
    ;;
esac
EOF

  cat >"$stub_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source="${@: -2:1}"
destination="${!#}"
if [[ -n "${FAKE_MV_LOG:-}" ]]; then
  printf '%s\t%s\n' "$source" "$destination" >>"$FAKE_MV_LOG"
fi
if [[ -n "${FAKE_MV_FAIL_TARGET:-}" && "$destination" == "$FAKE_MV_FAIL_TARGET" && \
  ! -e "$FAKE_MV_FAIL_MARKER" ]]; then
  : >"$FAKE_MV_FAIL_MARKER"
  exit 96
fi
if [[ "${FAKE_MV_RESTORE_FAILURE:-}" == true && "$(basename -- "$source")" == 'previous' ]]; then
  exit 95
fi
exec /bin/mv "$@"
EOF

  chmod 700 "$stub_bin/just" "$stub_bin/sops" "$stub_bin/mv"
}

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/.just"
  for target in "${targets[@]}"; do
    mkdir -p "$(dirname -- "$tree_root/$target")"
  done
  cat >"$tree_root/.justfile" <<'EOF'
set shell := ["bash", "-euo", "pipefail", "-c"]
mod repo ".just/repository.just"
EOF
  cp "$repo_root/.just/repository.just" "$tree_root/.just/repository.just"
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
  N8N_ENCRYPTION_KEY="${synthetic_values[0]}"
  N8N_DB_PASSWORD="${synthetic_values[1]}"
  POSTGRES_SUPERUSER_PASSWORD="${synthetic_values[2]}"
  POSTGRES_BACKUP_PASSWORD="${synthetic_values[3]}"
  POSTGRES_EXPORTER_PASSWORD="${synthetic_values[4]}"
  N8N_CANARY_TOKEN="${synthetic_values[5]}"
  N8N_SECRETS_CONFIRM="$expected_confirmation"
  unset FAKE_SOPS_FAIL FAKE_SOPS_MALFORMED_TARGET FAKE_SOPS_WRONG_RECIPIENT
  unset FAKE_MV_FAIL_TARGET FAKE_MV_FAIL_MARKER FAKE_MV_LOG FAKE_MV_RESTORE_FAILURE
}

run_recipe() {
  local output_file="$test_dir/command-output"
  local -a env_args=(
    "PATH=$stub_bin:$PATH"
    "REAL_YQ_BIN=$yq_bin"
    "N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY-}"
    "N8N_DB_PASSWORD=${N8N_DB_PASSWORD-}"
    "POSTGRES_SUPERUSER_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD-}"
    "POSTGRES_BACKUP_PASSWORD=${POSTGRES_BACKUP_PASSWORD-}"
    "POSTGRES_EXPORTER_PASSWORD=${POSTGRES_EXPORTER_PASSWORD-}"
    "N8N_CANARY_TOKEN=${N8N_CANARY_TOKEN-}"
    "N8N_SECRETS_CONFIRM=${N8N_SECRETS_CONFIRM-}"
  )
  [[ -z "${FAKE_SOPS_FAIL:-}" ]] || env_args+=("FAKE_SOPS_FAIL=$FAKE_SOPS_FAIL")
  [[ -z "${FAKE_SOPS_MALFORMED_TARGET:-}" ]] || env_args+=("FAKE_SOPS_MALFORMED_TARGET=$FAKE_SOPS_MALFORMED_TARGET")
  [[ -z "${FAKE_SOPS_WRONG_RECIPIENT:-}" ]] || env_args+=("FAKE_SOPS_WRONG_RECIPIENT=$FAKE_SOPS_WRONG_RECIPIENT")
  if [[ -n "${FAKE_MV_FAIL_TARGET:-}" ]]; then
    env_args+=("FAKE_MV_FAIL_TARGET=$FAKE_MV_FAIL_TARGET" "FAKE_MV_FAIL_MARKER=$FAKE_MV_FAIL_MARKER")
  fi
  [[ -z "${FAKE_MV_LOG:-}" ]] || env_args+=("FAKE_MV_LOG=$FAKE_MV_LOG")
  [[ "${FAKE_MV_RESTORE_FAILURE:-}" != true ]] || env_args+=("FAKE_MV_RESTORE_FAILURE=true")

  set +e
  (
    cd "$tree_root"
    env "${env_args[@]}" "$just_bin" --justfile .justfile repo n8n-secrets
  ) >"$output_file" 2>&1
  RECIPE_EXIT_CODE="$?"
  set -e
  RECIPE_OUTPUT="$(<"$output_file")"
}

assert_no_plaintext() {
  local content="$1"
  local value
  for value in "${synthetic_values[@]}"; do
    ! rg -Fq -- "$value" <<<"$content" || {
      echo 'A supplied synthetic value appeared in command output or ciphertext.' >&2
      exit 1
    }
  done
}

expect_failure() {
  local expected_message="$1"
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || {
    echo 'The guarded recipe unexpectedly succeeded.' >&2
    exit 1
  }
  rg -Fq -- "$expected_message" <<<"$RECIPE_OUTPUT" || {
    echo 'The guarded recipe did not report the expected refusal.' >&2
    exit 1
  }
  assert_no_plaintext "$RECIPE_OUTPUT"
}

assert_target_contracts() {
  local runtime="$tree_root/$target_runtime"
  local postgresql="$tree_root/$target_postgresql"
  local canary="$tree_root/$target_canary"
  local expected_files actual_files
  expected_files="$(printf '%s\n' "$runtime" "$postgresql" "$canary" | LC_ALL=C sort)"
  actual_files="$(find "$tree_root/kubernetes" -type f -print | LC_ALL=C sort)"
  [[ "$actual_files" == "$expected_files" ]] || {
    echo 'The guarded recipe wrote an unexpected target set.' >&2
    exit 1
  }
  [[ "$("$yq_bin" -r '.metadata | [.name, .namespace] | join(",")' "$runtime")" == 'n8n-runtime,automation' ]]
  [[ "$("$yq_bin" -r '.stringData | keys | sort | join(",")' "$runtime")" == 'N8N_ENCRYPTION_KEY,N8N_HOST,N8N_PORT,N8N_PROTOCOL' ]]
  [[ "$("$yq_bin" -r '.metadata | [.name, .namespace] | join(",")' "$postgresql")" == 'postgresql-credentials,automation' ]]
  [[ "$("$yq_bin" -r '.stringData | keys | sort | join(",")' "$postgresql")" == 'backup-password,exporter-dsn,exporter-password,n8n-password,postgres-superuser-password' ]]
  [[ "$("$yq_bin" -r '.metadata | [.name, .namespace] | join(",")' "$canary")" == 'n8n-canary,gatus' ]]
  [[ "$("$yq_bin" -r '.stringData | keys | sort | join(",")' "$canary")" == 'token' ]]
  for target in "${targets[@]}"; do
    local artifact="$tree_root/$target"
    [[ "$("$yq_bin" -r 'keys | sort | join(",")' "$artifact")" == 'apiVersion,kind,metadata,sops,stringData,type' ]]
    [[ "$("$yq_bin" -r '.metadata | keys | sort | join(",")' "$artifact")" == 'name,namespace' ]]
    [[ "$("$yq_bin" -r '.apiVersion' "$artifact")" == 'v1' ]]
    [[ "$("$yq_bin" -r '.kind' "$artifact")" == 'Secret' ]]
    [[ "$("$yq_bin" -r '.type' "$artifact")" == 'Opaque' ]]
    [[ "$("$yq_bin" -r 'has("data") | not' "$artifact")" == 'true' ]]
    [[ "$("$yq_bin" -r '.sops.age[].recipient' "$artifact")" == "$expected_recipient" ]]
    rg -Fq 'ENC[synthetic]' "$artifact"
    assert_no_plaintext "$(<"$artifact")"
  done
  assert_no_plaintext "$RECIPE_OUTPUT"
}

assert_no_targets() {
  local target
  for target in "${targets[@]}"; do
    [[ ! -e "$tree_root/$target" ]] || {
      echo 'A refused guarded write changed a target.' >&2
      exit 1
    }
  done
}

seed_existing_targets() {
  local index=0 target
  for target in "${targets[@]}"; do
    printf 'existing-ciphertext-%s\n' "$index" >"$tree_root/$target"
    index=$((index + 1))
  done
}

assert_existing_targets() {
  local index=0 target
  for target in "${targets[@]}"; do
    [[ "$(<"$tree_root/$target")" == "existing-ciphertext-$index" ]] || {
      echo 'A failed guarded write did not roll back every target.' >&2
      exit 1
    }
    index=$((index + 1))
  done
}

assert_atomic_replacements() {
  local target source destination target_moves=0
  while IFS=$'\t' read -r source destination; do
    for target in "${targets[@]}"; do
      [[ "$source" != "$target" ]] || {
        echo 'A prior target was moved away before its replacement was installed.' >&2
        exit 1
      }
      if [[ "$destination" == "$target" ]]; then
        [[ "$(basename -- "$source")" == 'candidate' ]] || {
          echo 'A canonical target was not directly replaced from its same-filesystem candidate.' >&2
          exit 1
        }
        target_moves=$((target_moves + 1))
      fi
    done
  done <"$FAKE_MV_LOG"
  [[ "$target_moves" -eq "${#targets[@]}" ]] || {
    echo 'Each target must receive exactly one direct candidate replacement.' >&2
    exit 1
  }
}

assert_retained_recovery_copy() {
  local target
  for target in "${targets[@]}"; do
    find "$(dirname -- "$tree_root/$target")" -maxdepth 2 -type f -name previous -print -quit | \
      rg -q . && return 0
  done
  echo 'A failed rollback removed every retained ciphertext recovery copy.' >&2
  exit 1
}

reset_validator_tree() {
  rm -rf -- "$validator_tree"
  mkdir -p "$validator_tree/kubernetes/apps/networking"
  cp "$repo_root/kubernetes/apps/kustomization.yaml" \
    "$validator_tree/kubernetes/apps/kustomization.yaml"
  cp -R "$repo_root/kubernetes/apps/automation" \
    "$validator_tree/kubernetes/apps/automation"
  cp "$repo_root/kubernetes/apps/networking/kustomization.yaml" \
    "$validator_tree/kubernetes/apps/networking/kustomization.yaml"
  cp -R "$repo_root/kubernetes/apps/networking/external-dns" \
    "$validator_tree/kubernetes/apps/networking/external-dns"
  cp -R "$repo_root/kubernetes/apps/networking/public-webhook-gateway" \
    "$validator_tree/kubernetes/apps/networking/public-webhook-gateway"
  cat >"$validator_tree/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^kubernetes/.*\\.sops\\.ya?ml$
    age: $expected_recipient
    encrypted_regex: '^(data|stringData)$'
EOF
}

select_all_n8n_secrets() {
  mkdir -p "$validator_tree/kubernetes/apps/automation/n8n/app"
  mkdir -p "$validator_tree/kubernetes/apps/automation/n8n-postgresql/app"
  mkdir -p "$validator_tree/kubernetes/apps/monitoring/gatus/app"
  cat >"$validator_tree/kubernetes/apps/automation/n8n/app/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./n8n-runtime.sops.yaml
YAML
  cat >"$validator_tree/kubernetes/apps/automation/n8n-postgresql/app/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./postgresql-credentials.sops.yaml
YAML
  cat >"$validator_tree/kubernetes/apps/monitoring/gatus/app/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./n8n-canary.sops.yaml
YAML
}

select_runtime_secret() {
  local resource="$1"
  mkdir -p "$validator_tree/kubernetes/apps/automation/n8n/app"
  cat >"$validator_tree/kubernetes/apps/automation/n8n/app/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - $resource
EOF
}

write_selected_secret_fixtures() {
  cat >"$validator_tree/$target_runtime" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: n8n-runtime
  namespace: automation
type: Opaque
stringData:
  N8N_ENCRYPTION_KEY: ENC[synthetic]
  N8N_HOST: ENC[synthetic]
  N8N_PORT: ENC[synthetic]
  N8N_PROTOCOL: ENC[synthetic]
sops:
  age:
    - recipient: $expected_recipient
EOF
  cat >"$validator_tree/$target_postgresql" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-credentials
  namespace: automation
type: Opaque
stringData:
  postgres-superuser-password: ENC[synthetic]
  n8n-password: ENC[synthetic]
  backup-password: ENC[synthetic]
  exporter-password: ENC[synthetic]
  exporter-dsn: ENC[synthetic]
sops:
  age:
    - recipient: $expected_recipient
EOF
  cat >"$validator_tree/$target_canary" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: n8n-canary
  namespace: gatus
type: Opaque
stringData:
  token: ENC[synthetic]
sops:
  age:
    - recipient: $expected_recipient
EOF
}

run_validator() {
  local output_file="$test_dir/validator-output"
  set +e
  (
    cd "$validator_tree"
    PATH="$stub_bin:$PATH" "$repo_root/scripts/validate/n8n.sh"
  ) >"$output_file" 2>&1
  VALIDATOR_EXIT_CODE="$?"
  set -e
  VALIDATOR_OUTPUT="$(<"$output_file")"
}

expect_validator_pass() {
  [[ "$VALIDATOR_EXIT_CODE" -eq 0 ]] || {
    echo 'The selected n8n Secret validation unexpectedly failed.' >&2
    exit 1
  }
}

expect_validator_failure() {
  local expected_message="$1"
  [[ "$VALIDATOR_EXIT_CODE" -ne 0 ]] || {
    echo 'Malformed selected n8n Secret validation unexpectedly passed.' >&2
    exit 1
  }
  rg -Fq -- "$expected_message" <<<"$VALIDATOR_OUTPUT" || {
    echo 'The selected n8n Secret validation did not report the expected failure.' >&2
    exit 1
  }
}

write_stubs

# The first complete synthetic invocation is the writer's primary contract.
reset_tree
set_all_inputs
run_recipe
[[ "$RECIPE_EXIT_CODE" -eq 0 ]] || {
  echo 'The n8n-secrets recipe must accept complete synthetic input.' >&2
  exit 1
}
assert_target_contracts

for missing_variable in "${secret_variables[@]}"; do
  reset_tree
  set_all_inputs
  unset "$missing_variable"
  run_recipe
  expect_failure "Set $missing_variable"
  assert_no_targets
done

reset_tree
set_all_inputs
unset N8N_SECRETS_CONFIRM
run_recipe
expect_failure 'Refusing to write the n8n platform Secrets.'
assert_no_targets

reset_tree
set_all_inputs
N8N_SECRETS_CONFIRM='write:automation:wrong:sops'
run_recipe
expect_failure 'Refusing to write the n8n platform Secrets.'
assert_no_targets

for short_variable in "${secret_variables[@]}"; do
  reset_tree
  set_all_inputs
  printf -v "$short_variable" '%s' 'too-short'
  run_recipe
  expect_failure "$short_variable must be at least 32 characters"
  ! rg -Fq -- 'too-short' <<<"$RECIPE_OUTPUT" || {
    echo 'A rejected short synthetic value appeared in command output.' >&2
    exit 1
  }
  assert_no_targets
done

for failure_mode in encrypt filestatus; do
  reset_tree
  seed_existing_targets
  set_all_inputs
  FAKE_SOPS_FAIL="$failure_mode"
  run_recipe
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || {
    echo 'A failed SOPS check unexpectedly wrote targets.' >&2
    exit 1
  }
  assert_no_plaintext "$RECIPE_OUTPUT"
  assert_existing_targets
done

for malformed_target in "${targets[@]}"; do
  reset_tree
  seed_existing_targets
  set_all_inputs
  FAKE_SOPS_MALFORMED_TARGET="$malformed_target"
  run_recipe
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || {
    echo 'A malformed encrypted Secret unexpectedly wrote targets.' >&2
    exit 1
  }
  assert_no_plaintext "$RECIPE_OUTPUT"
  assert_existing_targets
done

reset_tree
seed_existing_targets
set_all_inputs
FAKE_SOPS_WRONG_RECIPIENT=true
run_recipe
[[ "$RECIPE_EXIT_CODE" -ne 0 ]] || {
  echo 'A Secret with the wrong SOPS recipient unexpectedly wrote targets.' >&2
  exit 1
}
assert_no_plaintext "$RECIPE_OUTPUT"
assert_existing_targets

reset_tree
seed_existing_targets
set_all_inputs
FAKE_MV_FAIL_TARGET="$target_postgresql"
FAKE_MV_FAIL_MARKER="$test_dir/mv-failed-once"
run_recipe
[[ "$RECIPE_EXIT_CODE" -ne 0 ]] || {
  echo 'A replacement failure unexpectedly succeeded.' >&2
  exit 1
}
assert_no_plaintext "$RECIPE_OUTPUT"
assert_existing_targets

reset_tree
seed_existing_targets
set_all_inputs
FAKE_MV_LOG="$test_dir/mv-atomic-replacements"
run_recipe
[[ "$RECIPE_EXIT_CODE" -eq 0 ]] || {
  echo 'Atomic replacement coverage requires a successful guarded write.' >&2
  exit 1
}
assert_atomic_replacements

reset_tree
seed_existing_targets
set_all_inputs
FAKE_MV_FAIL_TARGET="$target_postgresql"
FAKE_MV_FAIL_MARKER="$test_dir/mv-replacement-failed-once"
FAKE_MV_RESTORE_FAILURE=true
run_recipe
[[ "$RECIPE_EXIT_CODE" -ne 0 ]] || {
  echo 'A replacement failure with failed rollback unexpectedly succeeded.' >&2
  exit 1
}
assert_no_plaintext "$RECIPE_OUTPUT"
rg -Fq 'Recovery ciphertext retained at' <<<"$RECIPE_OUTPUT" || {
  echo 'A failed rollback did not report its safe retained-ciphertext recovery path.' >&2
  exit 1
}
assert_retained_recovery_copy

reset_validator_tree
run_validator
expect_validator_pass

reset_validator_tree
select_all_n8n_secrets
run_validator
expect_validator_failure "Missing selected n8n SOPS Secret: $target_runtime."

reset_validator_tree
select_runtime_secret 'n8n-runtime.sops.yaml'
run_validator
expect_validator_failure "Missing selected n8n SOPS Secret: $target_runtime."

reset_validator_tree
select_all_n8n_secrets
write_selected_secret_fixtures
run_validator
expect_validator_pass

reset_validator_tree
select_all_n8n_secrets
write_selected_secret_fixtures
yq -i '.data = {"plaintext": "not-allowed"}' "$validator_tree/$target_runtime"
run_validator
expect_validator_failure "Selected n8n SOPS Secret must not contain data: $target_runtime."

reset_validator_tree
select_all_n8n_secrets
write_selected_secret_fixtures
yq -i '.sops.age[0].recipient = "age1wrongsyntheticrecipient00000000000000000000000000000000"' \
  "$validator_tree/$target_canary"
run_validator
expect_validator_failure "Selected n8n SOPS Secret has an unexpected age recipient: $target_canary."

echo 'n8n guarded Secret writer tests passed.'
