#!/usr/bin/env bash
# Exercise the guarded Gatus media-integration Secret writer in a disposable tree.
# The test stubs the identity check and SOPS so it never needs a real age key or
# touches the repository target.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
just_bin="$(mise exec -- bash -c 'command -v just')"
yq_bin="$(mise exec -- bash -c 'command -v yq')"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-gatus-media-integration-secrets-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
stub_bin="$test_dir/bin"
target_relative='kubernetes/apps/monitoring/gatus/app/media-integration-api-keys.sops.yaml'
expected_confirmation='write:monitoring:gatus-media-integration:sops'
expected_recipient='age1syntheticrecipientforgatusmedia000000000000000000000000000'
declare -a secret_variables=(
  PROWLARR_API_KEY
  SONARR_API_KEY
  RADARR_API_KEY
  LIDARR_API_KEY
  SEERR_API_KEY
)
declare -a synthetic_values=(
  synthetic-prowlarr-api-key
  synthetic-sonarr-api-key
  synthetic-radarr-api-key
  synthetic-lidarr-api-key
  synthetic-seerr-api-key
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
  echo 'Unexpected sops encryption invocation from guarded recipe.' >&2
  exit 98
}
[[ "${FAKE_SOPS_FAIL:-}" != 'encrypt' ]] || exit 97

target="$3"
input="$4"
expected_target='kubernetes/apps/monitoring/gatus/app/media-integration-api-keys.sops.yaml'
[[ "$target" == "$expected_target" ]] || exit 96
[[ "$("$REAL_YQ_BIN" -r '.apiVersion' "$input")" == 'v1' ]]
[[ "$("$REAL_YQ_BIN" -r '.kind' "$input")" == 'Secret' ]]
[[ "$("$REAL_YQ_BIN" -r '.metadata.name' "$input")" == 'gatus-media-integration-api-keys' ]]
[[ "$("$REAL_YQ_BIN" -r '.metadata.namespace' "$input")" == 'gatus' ]]
[[ "$("$REAL_YQ_BIN" -r '.type' "$input")" == 'Opaque' ]]
[[ "$("$REAL_YQ_BIN" -r 'has("data") | not' "$input")" == 'true' ]]
[[ "$("$REAL_YQ_BIN" -r '.stringData | keys | sort | join(",")' "$input")" == \
  'lidarr_api_key,prowlarr_api_key,radarr_api_key,seerr_api_key,sonarr_api_key' ]]

if [[ "${FAKE_SOPS_INVALID_SCHEMA:-}" == 'true' ]]; then
  cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: wrong-secret
  namespace: gatus
type: Opaque
stringData:
  wrong_key: ENC[synthetic]
sops:
  age:
    - recipient: age1syntheticrecipientforgatusmedia000000000000000000000000000
YAML
  exit 0
fi

cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: gatus-media-integration-api-keys
  namespace: gatus
type: Opaque
stringData:
  prowlarr_api_key: ENC[synthetic]
  sonarr_api_key: ENC[synthetic]
  radarr_api_key: ENC[synthetic]
  lidarr_api_key: ENC[synthetic]
  seerr_api_key: ENC[synthetic]
sops:
  age:
    - recipient: age1syntheticrecipientforgatusmedia000000000000000000000000000
YAML
EOF

  chmod 700 "$stub_bin/just" "$stub_bin/sops"
}

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/.just" "$(dirname -- "$tree_root/$target_relative")"
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

run_recipe() {
  local output_file="$test_dir/command-output"
  local -a env_args=(
    "PATH=$stub_bin:$PATH"
    "REAL_YQ_BIN=$yq_bin"
    "PROWLARR_API_KEY=${PROWLARR_API_KEY-}"
    "SONARR_API_KEY=${SONARR_API_KEY-}"
    "RADARR_API_KEY=${RADARR_API_KEY-}"
    "LIDARR_API_KEY=${LIDARR_API_KEY-}"
    "SEERR_API_KEY=${SEERR_API_KEY-}"
    "GATUS_MEDIA_INTEGRATION_SECRETS_CONFIRM=${GATUS_MEDIA_INTEGRATION_SECRETS_CONFIRM-}"
  )
  if [[ -n "${FAKE_SOPS_FAIL:-}" ]]; then
    env_args+=("FAKE_SOPS_FAIL=$FAKE_SOPS_FAIL")
  fi
  if [[ -n "${FAKE_SOPS_INVALID_SCHEMA:-}" ]]; then
    env_args+=("FAKE_SOPS_INVALID_SCHEMA=$FAKE_SOPS_INVALID_SCHEMA")
  fi

  set +e
  (
    cd "$tree_root"
    env "${env_args[@]}" "$just_bin" --justfile .justfile repo gatus-media-integration-secrets
  ) >"$output_file" 2>&1
  RECIPE_EXIT_CODE="$?"
  set -e
  RECIPE_OUTPUT="$(<"$output_file")"
}

expect_failure() {
  local description="$1"
  local expected_message="$2"
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || {
    echo "$description: guarded recipe unexpectedly succeeded." >&2
    exit 1
  }
  rg -Fq -- "$expected_message" <<<"$RECIPE_OUTPUT" || {
    echo "$description: expected failure message was absent." >&2
    exit 1
  }
}

assert_no_plaintext() {
  local content="$1"
  local description="$2"
  local value
  for value in "${synthetic_values[@]}"; do
    ! rg -Fq -- "$value" <<<"$content" || {
      echo "$description: synthetic plaintext appeared." >&2
      exit 1
    }
  done
}

set_all_inputs() {
  PROWLARR_API_KEY="${synthetic_values[0]}"
  SONARR_API_KEY="${synthetic_values[1]}"
  RADARR_API_KEY="${synthetic_values[2]}"
  LIDARR_API_KEY="${synthetic_values[3]}"
  SEERR_API_KEY="${synthetic_values[4]}"
  GATUS_MEDIA_INTEGRATION_SECRETS_CONFIRM="$expected_confirmation"
  unset FAKE_SOPS_FAIL FAKE_SOPS_INVALID_SCHEMA
}

write_stubs

# The initial RED condition is a missing recipe. Once implemented, this same case is the
# success contract: it creates only the synthetic target and no plaintext reaches output.
reset_tree
set_all_inputs
run_recipe
[[ "$RECIPE_EXIT_CODE" -eq 0 ]] || {
  echo 'Gatus media-integration Secret recipe must exist and accept complete synthetic input.' >&2
  exit 1
}
target="$tree_root/$target_relative"
[[ -f "$target" ]]
[[ "$(find "$tree_root/kubernetes" -type f -print | LC_ALL=C sort)" == "$target" ]]
[[ "$("$yq_bin" -r 'keys | sort | join(",")' "$target")" == 'apiVersion,kind,metadata,sops,stringData,type' ]]
[[ "$("$yq_bin" -r '.metadata | keys | sort | join(",")' "$target")" == 'name,namespace' ]]
[[ "$("$yq_bin" -r '.metadata.name' "$target")" == 'gatus-media-integration-api-keys' ]]
[[ "$("$yq_bin" -r '.metadata.namespace' "$target")" == 'gatus' ]]
[[ "$("$yq_bin" -r '.type' "$target")" == 'Opaque' ]]
[[ "$("$yq_bin" -r 'has("data") | not' "$target")" == 'true' ]]
[[ "$("$yq_bin" -r '.stringData | keys | sort | join(",")' "$target")" == \
  'lidarr_api_key,prowlarr_api_key,radarr_api_key,seerr_api_key,sonarr_api_key' ]]
[[ "$("$yq_bin" -r '.sops.age[].recipient' "$target")" == "$expected_recipient" ]]
rg -Fq 'ENC[synthetic]' "$target"
assert_no_plaintext "$(<"$target")" 'output artifact'
assert_no_plaintext "$RECIPE_OUTPUT" 'command output'

for missing_variable in "${secret_variables[@]}"; do
  reset_tree
  set_all_inputs
  unset "$missing_variable"
  run_recipe
  expect_failure "missing $missing_variable" "Set $missing_variable"
  [[ ! -e "$tree_root/$target_relative" ]]
done

reset_tree
set_all_inputs
unset GATUS_MEDIA_INTEGRATION_SECRETS_CONFIRM
run_recipe
expect_failure 'missing confirmation' 'Refusing to write the Gatus media-integration Secret.'
[[ ! -e "$tree_root/$target_relative" ]]

reset_tree
set_all_inputs
GATUS_MEDIA_INTEGRATION_SECRETS_CONFIRM='wrong-confirmation'
run_recipe
expect_failure 'wrong confirmation' 'Refusing to write the Gatus media-integration Secret.'
[[ ! -e "$tree_root/$target_relative" ]]

for failure_mode in encrypt filestatus; do
  reset_tree
  printf '%s\n' 'existing-ciphertext' >"$tree_root/$target_relative"
  set_all_inputs
  FAKE_SOPS_FAIL="$failure_mode"
  run_recipe
  [[ "$RECIPE_EXIT_CODE" -ne 0 ]] || {
    echo "$failure_mode failure: guarded recipe unexpectedly succeeded." >&2
    exit 1
  }
  [[ "$(<"$tree_root/$target_relative")" == 'existing-ciphertext' ]]
done

reset_tree
printf '%s\n' 'existing-ciphertext' >"$tree_root/$target_relative"
set_all_inputs
FAKE_SOPS_INVALID_SCHEMA=true
run_recipe
[[ "$RECIPE_EXIT_CODE" -ne 0 ]] || {
  echo 'candidate schema failure: guarded recipe unexpectedly succeeded.' >&2
  exit 1
}
[[ "$(<"$tree_root/$target_relative")" == 'existing-ciphertext' ]]

echo 'Gatus media-integration Secret recipe tests passed.'
