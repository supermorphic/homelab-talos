set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Install the exact tool versions and verify their presence.
tools:
    mise install --locked
    mise exec -- just repo versions

# Print the tool versions used by this repository.
versions: toolchain-validate
    @bash --version | head -n 1
    @python3 --version
    @bats --version
    @shfmt --version
    @talosctl version --client --short
    @talhelper --version
    @kubectl version --client
    @helm version --short
    @flux --version
    @cilium version --client
    @chainsaw version
    @node --version
    @allure --version
    @conftest --version
    @kustomize version
    @sops --version
    @age --version
    @yq --version
    @just --version
    @gh --version | head -n 1
    @gitleaks version
    @promtool --version | head -n 1
    @shellcheck --version
    @uv --version
    @pre-commit --version
    @sonobuoy version

# Prove that supported repository commands resolve the exact mise-managed Python.
toolchain-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    expected_version='3.13.14'
    python_root="$(cd "$(mise where python)" && pwd -P)"
    python_path="$(command -v python3)"
    python_version="$(python3 -c 'import platform; print(platform.python_version())')"
    python_executable="$(python3 -c 'import os, sys; print(os.path.realpath(sys.executable))')"
    uv_python="$(uv python find --system "$expected_version")"
    uv_python_executable="$("$uv_python" -c 'import os, sys; print(os.path.realpath(sys.executable))')"

    [[ "$python_version" == "$expected_version" ]] || {
      echo "Expected Python $expected_version, got $python_version from $python_path." >&2
      exit 1
    }
    case "$python_executable" in
      "$python_root"/*) ;;
      *)
        echo "Python must resolve under the mise installation $python_root; got $python_executable." >&2
        exit 1
        ;;
    esac
    case "$uv_python_executable" in
      "$python_root"/*) ;;
      *)
        echo "uv must resolve Python under the mise installation $python_root; got $uv_python_executable." >&2
        exit 1
        ;;
    esac

    printf 'Python %s: %s (mise-managed)\n' "$python_version" "$python_path"
    printf 'uv Python: %s (mise-managed)\n' "$uv_python"

# Read GitHub merge settings, the complete Protect main ruleset, and rules effective
# on main; fail when they differ from the tracked protection contract.
github-protection-check:
    uv run --locked --no-dev python scripts/repository/github_protection.py check

# Show the GitHub protection changes the guarded apply recipe would make.
github-protection-plan:
    uv run --locked --no-dev python scripts/repository/github_protection.py plan

# Reconcile squash-only merging and Protect main after explicit authorization.
# Guard: GITHUB_PROTECTION_CONFIRM='apply:github-protection:supermorphic/homelab-talos'.
github-protection-apply:
    uv run --locked --no-dev python scripts/repository/github_protection.py apply

# Verify that the loaded private age identity matches this repository.
secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    expected="$(yq -r '.creation_rules[0].age' .sops.yaml)"
    if [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
      actual="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
    elif [[ -n "${SOPS_AGE_KEY:-}" ]]; then
      key_file="$(mktemp "${TMPDIR:-/tmp}/homelab-talos-age.XXXXXX")"
      trap 'rm -f "$key_file"' EXIT
      chmod 600 "$key_file"
      printf '%s\n' "$SOPS_AGE_KEY" > "$key_file"
      actual="$(age-keygen -y "$key_file")"
    else
      echo "Set and export SOPS_AGE_KEY or SOPS_AGE_KEY_FILE." >&2
      exit 1
    fi
    [[ "$actual" == "$expected" ]] || {
      echo "Loaded age identity does not match $expected." >&2
      exit 1
    }
    echo "Loaded age identity matches $expected."

# Write only the SOPS-encrypted Gatus media-integration API-key Secret. The five
# API keys are used by Gatus native-health endpoints; this recipe never echoes them.
gatus-media-integration-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:gatus-media-integration:sops'
    target='kubernetes/apps/monitoring/gatus/app/media-integration-api-keys.sops.yaml'
    umask 077
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-gatus-media-integration-secrets.XXXXXX")"
    trap 'rm -rf -- "$temp_dir"' EXIT

    just repo secrets
    [[ -n "${PROWLARR_API_KEY:-}" ]] || {
      echo 'Set PROWLARR_API_KEY to the API key from Prowlarr Settings > General.' >&2
      exit 1
    }
    [[ -n "${SONARR_API_KEY:-}" ]] || {
      echo 'Set SONARR_API_KEY to the API key from Sonarr Settings > General.' >&2
      exit 1
    }
    [[ -n "${RADARR_API_KEY:-}" ]] || {
      echo 'Set RADARR_API_KEY to the API key from Radarr Settings > General.' >&2
      exit 1
    }
    [[ -n "${LIDARR_API_KEY:-}" ]] || {
      echo 'Set LIDARR_API_KEY to the API key from Lidarr Settings > General.' >&2
      exit 1
    }
    [[ -n "${SEERR_API_KEY:-}" ]] || {
      echo 'Set SEERR_API_KEY to the API key from Seerr Settings > General.' >&2
      exit 1
    }
    [[ "${GATUS_MEDIA_INTEGRATION_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Gatus media-integration Secret.' >&2
      echo "Set GATUS_MEDIA_INTEGRATION_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    mapfile -t expected_recipients < <(
      target="$target" yq -r \
        '.creation_rules[] | select(.path_regex as $rule | env(target) | test($rule)) | .age' \
        .sops.yaml
    )
    [[ "${#expected_recipients[@]}" -eq 1 && -n "${expected_recipients[0]}" && \
      "${expected_recipients[0]}" != 'null' ]] || {
      echo "Unable to select exactly one SOPS age recipient for $target." >&2
      exit 1
    }
    expected_recipient="${expected_recipients[0]}"

    export PROWLARR_API_KEY SONARR_API_KEY RADARR_API_KEY LIDARR_API_KEY SEERR_API_KEY
    plaintext="$temp_dir/media-integration-api-keys.yaml"
    candidate="$temp_dir/media-integration-api-keys.sops.yaml"
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "gatus-media-integration-api-keys" |
       .metadata.namespace = "gatus" |
       .type = "Opaque" |
       .stringData.prowlarr_api_key = strenv(PROWLARR_API_KEY) |
       .stringData.sonarr_api_key = strenv(SONARR_API_KEY) |
       .stringData.radarr_api_key = strenv(RADARR_API_KEY) |
       .stringData.lidarr_api_key = strenv(LIDARR_API_KEY) |
       .stringData.seerr_api_key = strenv(SEERR_API_KEY)' \
      >"$plaintext"

    sops --encrypt --filename-override "$target" "$plaintext" >"$candidate"
    [[ "$(sops filestatus "$candidate" | yq -r '.encrypted')" == 'true' ]]
    mapfile -t candidate_recipients < <(yq -r '.sops.age[].recipient' "$candidate" | sort -u)
    [[ "${#candidate_recipients[@]}" -eq 1 && \
      "${candidate_recipients[0]}" == "$expected_recipient" ]]
    [[ "$(yq -r 'keys | sort | join(",")' "$candidate")" == \
      'apiVersion,kind,metadata,sops,stringData,type' ]]
    [[ "$(yq -r '.metadata | keys | sort | join(",")' "$candidate")" == 'name,namespace' ]]
    [[ "$(yq -r '.apiVersion' "$candidate")" == 'v1' ]]
    [[ "$(yq -r '.kind' "$candidate")" == 'Secret' ]]
    [[ "$(yq -r '.metadata.name' "$candidate")" == 'gatus-media-integration-api-keys' ]]
    [[ "$(yq -r '.metadata.namespace' "$candidate")" == 'gatus' ]]
    [[ "$(yq -r '.type' "$candidate")" == 'Opaque' ]]
    [[ "$(yq -r 'has("data") | not' "$candidate")" == 'true' ]]
    [[ "$(yq -r '.stringData | keys | sort | join(",")' "$candidate")" == \
      'lidarr_api_key,prowlarr_api_key,radarr_api_key,seerr_api_key,sonarr_api_key' ]]
    for supplied_value in \
      "$PROWLARR_API_KEY" "$SONARR_API_KEY" "$RADARR_API_KEY" "$LIDARR_API_KEY" "$SEERR_API_KEY"; do
      ! rg -Fq -- "$supplied_value" "$candidate"
    done

    mv -- "$candidate" "$target"
    echo "Wrote SOPS-encrypted $target (gatus-media-integration-api-keys in gatus)."

# Write the SOPS-encrypted automation-data PostgreSQL Secret from operator-supplied
# platform values. Domain passwords and n8n API keys are intentionally excluded.
automation-data-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:automation-data:postgresql:sops'
    target='kubernetes/apps/automation-data/postgresql/app/postgresql-credentials.sops.yaml'
    [[ -n "${AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD:-}" ]] || {
      echo 'Set AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD to the PostgreSQL superuser password.' >&2
      exit 1
    }
    [[ -n "${AUTOMATION_DATA_PROVISIONER_PASSWORD:-}" ]] || {
      echo 'Set AUTOMATION_DATA_PROVISIONER_PASSWORD to the platform provisioner password.' >&2
      exit 1
    }
    [[ -n "${AUTOMATION_DATA_BACKUP_PASSWORD:-}" ]] || {
      echo 'Set AUTOMATION_DATA_BACKUP_PASSWORD to the protected globals-backup password.' >&2
      exit 1
    }
    [[ -n "${AUTOMATION_DATA_EXPORTER_PASSWORD:-}" ]] || {
      echo 'Set AUTOMATION_DATA_EXPORTER_PASSWORD to the SQL Exporter password.' >&2
      exit 1
    }
    [[ "${AUTOMATION_DATA_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the automation-data PostgreSQL Secret.' >&2
      echo "Set AUTOMATION_DATA_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }
    for secret_variable in AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD \
      AUTOMATION_DATA_PROVISIONER_PASSWORD AUTOMATION_DATA_BACKUP_PASSWORD \
      AUTOMATION_DATA_EXPORTER_PASSWORD; do
      secret_value="${!secret_variable}"
      [[ "${#secret_value}" -ge 32 ]] || {
        echo "Refusing: $secret_variable must be at least 32 characters." >&2
        exit 1
      }
    done

    committed=false
    replaced=false
    retained_stage=false
    stage_directory=''
    backup=''
    umask 077
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-automation-data-secrets.XXXXXX")"
    cleanup() {
      local result="$?" rollback_failed=false
      trap - EXIT
      if [[ "$committed" != true && -n "$backup" && -e "$backup" ]]; then
        if ! mv -- "$backup" "$target"; then
          rollback_failed=true
          retained_stage=true
        fi
      elif [[ "$committed" != true && "$replaced" == true ]]; then
        rm -f -- "$target" || rollback_failed=true
      fi
      rm -rf -- "$temp_dir"
      if [[ -n "$stage_directory" && "$retained_stage" == true ]]; then
        echo "Recovery ciphertext retained at $stage_directory for $target." >&2
      elif [[ -n "$stage_directory" ]]; then
        rm -rf -- "$stage_directory"
      fi
      if [[ "$rollback_failed" == true ]]; then
        echo 'Failed to restore the previous automation-data PostgreSQL Secret.' >&2
        result=1
      fi
      exit "$result"
    }
    trap cleanup EXIT

    just repo secrets
    mapfile -t expected_recipients < <(
      target="$target" yq -r \
        '.creation_rules[] | select(.path_regex as $rule | env(target) | test($rule)) | .age' \
        .sops.yaml
    )
    [[ "${#expected_recipients[@]}" -eq 1 && -n "${expected_recipients[0]}" && \
      "${expected_recipients[0]}" != null ]] || {
      echo "Unable to select exactly one SOPS age recipient for $target." >&2
      exit 1
    }
    expected_recipient="${expected_recipients[0]}"

    export AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD
    export AUTOMATION_DATA_PROVISIONER_PASSWORD AUTOMATION_DATA_BACKUP_PASSWORD
    export AUTOMATION_DATA_EXPORTER_PASSWORD
    exporter_password_encoded="$(python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["AUTOMATION_DATA_EXPORTER_PASSWORD"], safe=""))')"
    export exporter_password_encoded
    plaintext="$temp_dir/postgresql-credentials.yaml"
    candidate="$temp_dir/postgresql-credentials.sops.yaml"
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "postgresql-credentials" |
       .metadata.namespace = "automation-data" |
       .type = "Opaque" |
       .stringData."postgres-superuser-password" = strenv(AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD) |
       .stringData."provisioner-password" = strenv(AUTOMATION_DATA_PROVISIONER_PASSWORD) |
       .stringData."backup-password" = strenv(AUTOMATION_DATA_BACKUP_PASSWORD) |
       .stringData."exporter-password" = strenv(AUTOMATION_DATA_EXPORTER_PASSWORD) |
       .stringData."exporter-dsn" = "postgresql://automation_data_exporter:" + strenv(exporter_password_encoded) + "@127.0.0.1:5432/automation_data_control?sslmode=disable"' \
      >"$plaintext"
    sops --encrypt --filename-override "$target" "$plaintext" >"$candidate"

    [[ "$(sops filestatus "$candidate" | yq -r '.encrypted')" == true ]]
    mapfile -t candidate_recipients < <(yq -r '.sops.age[].recipient' "$candidate" | sort -u)
    [[ "${#candidate_recipients[@]}" -eq 1 && \
      "${candidate_recipients[0]}" == "$expected_recipient" ]]
    [[ "$(yq -r 'keys | sort | join(",")' "$candidate")" == \
      'apiVersion,kind,metadata,sops,stringData,type' ]]
    [[ "$(yq -r '.metadata | keys | sort | join(",")' "$candidate")" == \
      'name,namespace' ]]
    [[ "$(yq -r '.apiVersion' "$candidate")" == v1 ]]
    [[ "$(yq -r '.kind' "$candidate")" == Secret ]]
    [[ "$(yq -r '.metadata.name' "$candidate")" == postgresql-credentials ]]
    [[ "$(yq -r '.metadata.namespace' "$candidate")" == automation-data ]]
    [[ "$(yq -r '.type' "$candidate")" == Opaque ]]
    [[ "$(yq -r 'has("data") | not' "$candidate")" == true ]]
    [[ "$(yq -r '.stringData | keys | sort | join(",")' "$candidate")" == \
      'backup-password,exporter-dsn,exporter-password,postgres-superuser-password,provisioner-password' ]]
    for supplied_value in "$AUTOMATION_DATA_POSTGRES_SUPERUSER_PASSWORD" \
      "$AUTOMATION_DATA_PROVISIONER_PASSWORD" "$AUTOMATION_DATA_BACKUP_PASSWORD" \
      "$AUTOMATION_DATA_EXPORTER_PASSWORD"; do
      ! rg -Fq -- "$supplied_value" "$candidate"
    done

    mkdir -p "$(dirname -- "$target")"
    stage_directory="$(mktemp -d "$(dirname -- "$target")/.automation-data-secrets.XXXXXX")"
    stage="$stage_directory/candidate"
    backup="$stage_directory/previous"
    cp -- "$candidate" "$stage"
    [[ ! -e "$target" ]] || cp -- "$target" "$backup"
    mv -- "$stage" "$target"
    replaced=true
    committed=true
    echo "Wrote SOPS-encrypted $target."

# Write the three SOPS-encrypted n8n platform Secrets from operator-supplied values.
# The stable n8n encryption key and database passwords must be retained for recovery.
n8n-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:automation:n8n-platform:sops'
    runtime_target='kubernetes/apps/automation/n8n/app/n8n-runtime.sops.yaml'
    postgresql_target='kubernetes/apps/automation/n8n-postgresql/app/postgresql-credentials.sops.yaml'
    canary_target='kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml'
    [[ -n "${N8N_ENCRYPTION_KEY:-}" ]] || {
      echo 'Set N8N_ENCRYPTION_KEY to one stable n8n encryption key.' >&2
      exit 1
    }
    [[ -n "${N8N_DB_PASSWORD:-}" ]] || {
      echo 'Set N8N_DB_PASSWORD to the n8n PostgreSQL password.' >&2
      exit 1
    }
    [[ -n "${POSTGRES_SUPERUSER_PASSWORD:-}" ]] || {
      echo 'Set POSTGRES_SUPERUSER_PASSWORD to the PostgreSQL superuser password.' >&2
      exit 1
    }
    [[ -n "${POSTGRES_BACKUP_PASSWORD:-}" ]] || {
      echo 'Set POSTGRES_BACKUP_PASSWORD to the PostgreSQL backup-role password.' >&2
      exit 1
    }
    [[ -n "${POSTGRES_EXPORTER_PASSWORD:-}" ]] || {
      echo 'Set POSTGRES_EXPORTER_PASSWORD to the SQL Exporter password.' >&2
      exit 1
    }
    [[ -n "${N8N_CANARY_TOKEN:-}" ]] || {
      echo 'Set N8N_CANARY_TOKEN to the n8n canary token.' >&2
      exit 1
    }
    [[ "${N8N_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the n8n platform Secrets.' >&2
      echo "Set N8N_SECRETS_CONFIRM='$expected_confirmation' after reviewing all three targets." >&2
      exit 1
    }
    for secret_variable in N8N_ENCRYPTION_KEY N8N_DB_PASSWORD \
      POSTGRES_SUPERUSER_PASSWORD POSTGRES_BACKUP_PASSWORD \
      POSTGRES_EXPORTER_PASSWORD N8N_CANARY_TOKEN; do
      secret_value="${!secret_variable}"
      [[ "${#secret_value}" -ge 32 ]] || {
        echo "Refusing: $secret_variable must be at least 32 characters." >&2
        exit 1
      }
    done
    [[ "$N8N_CANARY_TOKEN" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
      echo 'Refusing: N8N_CANARY_TOKEN must use only A-Z, a-z, 0-9, _, and -, with at least 32 characters.' >&2
      exit 1
    }

    declare -a targets=("$runtime_target" "$postgresql_target" "$canary_target")
    declare -a candidates=()
    declare -a stage_directories=()
    declare -a stages=()
    declare -a backups=()
    declare -a replaced=(false false false)
    declare -a retained_stage=(false false false)
    committed=false
    umask 077
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-n8n-secrets.XXXXXX")"

    cleanup() {
      local result="$?"
      local index target backup stage_directory rollback_failed=false
      trap - EXIT
      if [[ "$committed" != true ]]; then
        for ((index = ${#targets[@]} - 1; index >= 0; index -= 1)); do
          target="${targets[$index]}"
          backup="${backups[$index]:-}"
          if [[ -n "$backup" && -e "$backup" ]]; then
            if ! mv -- "$backup" "$target"; then
              rollback_failed=true
              retained_stage[$index]=true
            fi
          elif [[ "${replaced[$index]}" == true ]]; then
            rm -f -- "$target" || rollback_failed=true
          fi
        done
      fi
      rm -rf -- "$temp_dir"
      for index in "${!stage_directories[@]}"; do
        stage_directory="${stage_directories[$index]}"
        if [[ "${retained_stage[$index]}" == true ]]; then
          echo "Recovery ciphertext retained at $stage_directory for ${targets[$index]}." >&2
        else
          rm -rf -- "$stage_directory"
        fi
      done
      if [[ "$rollback_failed" == true ]]; then
        echo 'Failed to restore every previous n8n Secret target.' >&2
        result=1
      fi
      exit "$result"
    }
    trap cleanup EXIT

    just repo secrets
    mapfile -t expected_recipients < <(
      target="$runtime_target" yq -r \
        '.creation_rules[] | select(.path_regex as $rule | env(target) | test($rule)) | .age' \
        .sops.yaml
    )
    [[ "${#expected_recipients[@]}" -eq 1 && -n "${expected_recipients[0]}" && \
      "${expected_recipients[0]}" != 'null' ]] || {
      echo 'Unable to select exactly one SOPS age recipient for n8n platform Secrets.' >&2
      exit 1
    }
    expected_recipient="${expected_recipients[0]}"

    export N8N_ENCRYPTION_KEY N8N_DB_PASSWORD POSTGRES_SUPERUSER_PASSWORD
    export POSTGRES_BACKUP_PASSWORD POSTGRES_EXPORTER_PASSWORD N8N_CANARY_TOKEN
    exporter_password_encoded="$(python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["POSTGRES_EXPORTER_PASSWORD"], safe=""))')"
    export exporter_password_encoded
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "n8n-runtime" |
       .metadata.namespace = "automation" |
       .type = "Opaque" |
       .stringData.N8N_ENCRYPTION_KEY = strenv(N8N_ENCRYPTION_KEY) |
       .stringData.N8N_HOST = "n8n.lab.supermorphic.com" |
       .stringData.N8N_PORT = "5678" |
       .stringData.N8N_PROTOCOL = "https"' \
      >"$temp_dir/n8n-runtime.yaml"
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "postgresql-credentials" |
       .metadata.namespace = "automation" |
       .type = "Opaque" |
       .stringData."postgres-superuser-password" = strenv(POSTGRES_SUPERUSER_PASSWORD) |
       .stringData."n8n-password" = strenv(N8N_DB_PASSWORD) |
       .stringData."backup-password" = strenv(POSTGRES_BACKUP_PASSWORD) |
       .stringData."exporter-password" = strenv(POSTGRES_EXPORTER_PASSWORD) |
       .stringData."exporter-dsn" = "postgresql://n8n_exporter:" + strenv(exporter_password_encoded) + "@127.0.0.1:5432/n8n?sslmode=disable"' \
      >"$temp_dir/postgresql-credentials.yaml"
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "n8n-canary" |
       .metadata.namespace = "gatus" |
       .type = "Opaque" |
       .stringData.token = strenv(N8N_CANARY_TOKEN)' \
      >"$temp_dir/n8n-canary.yaml"

    sops --encrypt --filename-override "$runtime_target" \
      "$temp_dir/n8n-runtime.yaml" >"$temp_dir/n8n-runtime.sops.yaml"
    sops --encrypt --filename-override "$postgresql_target" \
      "$temp_dir/postgresql-credentials.yaml" >"$temp_dir/postgresql-credentials.sops.yaml"
    sops --encrypt --filename-override "$canary_target" \
      "$temp_dir/n8n-canary.yaml" >"$temp_dir/n8n-canary.sops.yaml"
    candidates=(
      "$temp_dir/n8n-runtime.sops.yaml"
      "$temp_dir/postgresql-credentials.sops.yaml"
      "$temp_dir/n8n-canary.sops.yaml"
    )

    validate_candidate() {
      local candidate="$1" expected_name="$2" expected_namespace="$3" expected_keys="$4"
      [[ "$(sops filestatus "$candidate" | yq -r '.encrypted')" == 'true' ]]
      mapfile -t candidate_recipients < <(yq -r '.sops.age[].recipient' "$candidate" | sort -u)
      [[ "${#candidate_recipients[@]}" -eq 1 && \
        "${candidate_recipients[0]}" == "$expected_recipient" ]]
      [[ "$(yq -r 'keys | sort | join(",")' "$candidate")" == \
        'apiVersion,kind,metadata,sops,stringData,type' ]]
      [[ "$(yq -r '.metadata | keys | sort | join(",")' "$candidate")" == 'name,namespace' ]]
      [[ "$(yq -r '.apiVersion' "$candidate")" == 'v1' ]]
      [[ "$(yq -r '.kind' "$candidate")" == 'Secret' ]]
      [[ "$(yq -r '.metadata.name' "$candidate")" == "$expected_name" ]]
      [[ "$(yq -r '.metadata.namespace' "$candidate")" == "$expected_namespace" ]]
      [[ "$(yq -r '.type' "$candidate")" == 'Opaque' ]]
      [[ "$(yq -r 'has("data") | not' "$candidate")" == 'true' ]]
      [[ "$(yq -r '.stringData | keys | sort | join(",")' "$candidate")" == "$expected_keys" ]]
      for supplied_value in "$N8N_ENCRYPTION_KEY" "$N8N_DB_PASSWORD" \
        "$POSTGRES_SUPERUSER_PASSWORD" "$POSTGRES_BACKUP_PASSWORD" \
        "$POSTGRES_EXPORTER_PASSWORD" "$N8N_CANARY_TOKEN"; do
        ! rg -Fq -- "$supplied_value" "$candidate"
      done
    }
    validate_candidate "${candidates[0]}" n8n-runtime automation \
      'N8N_ENCRYPTION_KEY,N8N_HOST,N8N_PORT,N8N_PROTOCOL'
    validate_candidate "${candidates[1]}" postgresql-credentials automation \
      'backup-password,exporter-dsn,exporter-password,n8n-password,postgres-superuser-password'
    validate_candidate "${candidates[2]}" n8n-canary gatus token

    for index in "${!targets[@]}"; do
      stage_directory="$(mktemp -d "$(dirname -- "${targets[$index]}")/.n8n-secrets.XXXXXX")"
      stage_directories+=("$stage_directory")
      stages+=("$stage_directory/candidate")
      backups+=("$stage_directory/previous")
      cp -- "${candidates[$index]}" "${stages[$index]}"
      [[ ! -e "${targets[$index]}" ]] || cp -- "${targets[$index]}" "${backups[$index]}"
    done
    for index in "${!targets[@]}"; do
      target="${targets[$index]}"
      mv -- "${stages[$index]}" "$target"
      replaced[$index]=true
    done
    committed=true
    echo 'Wrote three SOPS-encrypted n8n platform Secret manifests.'

# Verify the external Pi-hole v6 HTTPS identity and write-capable app-session policy.
pihole-status:
    #!/usr/bin/env bash
    set -euo pipefail

    pihole_host='p1'
    pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    temp_dir="$(mktemp -d /tmp/homelab-talos-pihole-status.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n cat /etc/pihole/tls_ca.crt' >"$temp_dir/remote-ca.crt"
    remote_domain="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.domain')"
    remote_ports="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.port')"
    remote_app_sudo="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.api.app_sudo')"

    [[ "$remote_domain" == 'pi.hole' ]]
    rg -q '(^|,)443o?s($|,)' <<<"$remote_ports"
    [[ "$remote_app_sudo" == 'true' ]]
    [[ "$(dig +short @192.168.90.2 pi.hole A | sort -u)" == '192.168.90.2' ]]
    openssl verify -CAfile "$temp_dir/remote-ca.crt" "$temp_dir/remote-ca.crt" >/dev/null
    openssl x509 -in "$temp_dir/remote-ca.crt" -noout -checkend 2592000 >/dev/null
    [[ -f "$pihole_ca" ]]
    cmp -s "$pihole_ca" "$temp_dir/remote-ca.crt" || {
      echo 'The tracked Pi-hole CA differs from p1; run the guarded pihole-ca-refresh recipe.' >&2
      exit 1
    }
    curl --silent --show-error --fail-with-body --max-time 10 \
      --cacert "$pihole_ca" \
      --resolve 'pi.hole:443:192.168.90.2' \
      https://pi.hole/api/info/login >/dev/null

    fingerprint="$(openssl x509 -in "$pihole_ca" -noout -fingerprint -sha256 | cut -d= -f2)"
    echo "Pi-hole HTTPS passed: pi.hole resolves to 192.168.90.2, app_sudo=true, and tracked CA SHA256=$fingerprint."

# Refresh only the tracked public Pi-hole CA after a reviewed Pi-hole reinstall or CA rotation.
pihole-ca-refresh:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='refresh:pihole-ca:p1:pi.hole'
    pihole_host='p1'
    target='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    secret='kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml'
    values='kubernetes/apps/networking/external-dns/app/values.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-pihole-ca-refresh.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    [[ "${PIHOLE_CA_REFRESH_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to replace the tracked Pi-hole trust anchor.' >&2
      echo "Set PIHOLE_CA_REFRESH_CONFIRM='$expected_confirmation' after verifying the p1 SSH host identity." >&2
      exit 1
    }

    remote_domain="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.domain')"
    remote_ports="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n pihole-FTL --config webserver.port')"
    [[ "$remote_domain" == 'pi.hole' ]]
    rg -q '(^|,)443o?s($|,)' <<<"$remote_ports"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$pihole_host" \
      'sudo -n cat /etc/pihole/tls_ca.crt' >"$temp_dir/pihole-ca.crt"
    ! rg -q 'PRIVATE KEY' "$temp_dir/pihole-ca.crt"
    openssl verify -CAfile "$temp_dir/pihole-ca.crt" "$temp_dir/pihole-ca.crt" >/dev/null
    openssl x509 -in "$temp_dir/pihole-ca.crt" -noout -checkend 2592000 >/dev/null
    openssl x509 -in "$temp_dir/pihole-ca.crt" -noout -text | rg -q 'CA:TRUE'

    new_fingerprint="$(openssl x509 -in "$temp_dir/pihole-ca.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
    scripts/repository/stamp-external-dns-provider.sh \
      "$temp_dir/pihole-ca.crt" "$secret" "$values" "$temp_dir/values.yaml"
    ca_changed=true
    values_changed=true
    [[ ! -f "$target" ]] || ! cmp -s "$target" "$temp_dir/pihole-ca.crt" || ca_changed=false
    cmp -s "$values" "$temp_dir/values.yaml" && values_changed=false
    if [[ "$ca_changed" == false && "$values_changed" == false ]]; then
      echo "Tracked Pi-hole CA already matches p1 at SHA256=$new_fingerprint."
      exit 0
    fi
    if [[ "$ca_changed" == true && -f "$target" ]]; then
      old_fingerprint="$(openssl x509 -in "$target" -noout -fingerprint -sha256 | cut -d= -f2)"
      echo "Replacing tracked Pi-hole CA SHA256=$old_fingerprint with SHA256=$new_fingerprint."
    elif [[ "$ca_changed" == true ]]; then
      echo "Installing tracked Pi-hole CA SHA256=$new_fingerprint."
    fi
    [[ "$ca_changed" == false ]] || install -m 0644 "$temp_dir/pihole-ca.crt" "$target"
    [[ "$values_changed" == false ]] || install -m 0644 "$temp_dir/values.yaml" "$values"
    echo 'Review the certificate, rollout-stamp, and fingerprint changes before committing the trust-anchor rotation.'

# Validate internal foundation provider credentials and write only SOPS-encrypted Secret manifests.
foundation-provider-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:foundation-providers:cloudflare-and-pihole:sops'
    cloudflare_target='kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml'
    pihole_target='kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml'
    pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    external_dns_values='kubernetes/apps/networking/external-dns/app/values.yaml'
    pihole_api='https://pi.hole'
    temp_dir="$(mktemp -d /tmp/homelab-talos-foundation-provider-secrets.XXXXXX)"
    pihole_sid=''
    pihole_record_cleanup_needed=false
    pihole_test_hostname="provider-preflight-$$-${RANDOM}.lab.supermorphic.com"
    pihole_test_record="192.0.2.1 $pihole_test_hostname"
    pihole_test_url="$pihole_api/api/config/dns/hosts/192.0.2.1%20$pihole_test_hostname"
    pihole_curl=(
      curl --silent --show-error --fail-with-body --max-time 10
      --cacert "$pihole_ca"
      --resolve 'pi.hole:443:192.168.90.2'
    )
    cleanup_pihole_record() {
      [[ "$pihole_record_cleanup_needed" == 'true' && -n "$pihole_sid" ]] || return 0
      "${pihole_curl[@]}" \
        --request DELETE \
        --header "X-FTL-SID: $pihole_sid" \
        "$pihole_test_url" >/dev/null || return 1
      current_records="$("${pihole_curl[@]}" \
        --header "X-FTL-SID: $pihole_sid" \
        "$pihole_api/api/config/dns/hosts")" || return 1
      if yq -r '.config.dns.hosts[]?' - <<<"$current_records" | rg -Fxq -- "$pihole_test_record"; then
        return 1
      fi
      pihole_record_cleanup_needed=false
    }
    cleanup() {
      original_status=$?
      set +e
      cleanup_status=0
      if ! cleanup_pihole_record; then
        echo "Pi-hole cleanup failed; remove the temporary record '$pihole_test_record' before retrying." >&2
        cleanup_status=1
      fi
      if [[ -n "$pihole_sid" ]]; then
        "${pihole_curl[@]}" \
          --request DELETE \
          --header "X-FTL-SID: $pihole_sid" \
          "$pihole_api/api/auth" >/dev/null 2>&1 || \
          echo 'Warning: Pi-hole session logout failed; the short-lived session will expire.' >&2
      fi
      rm -rf -- "$temp_dir"
      if (( cleanup_status != 0 )); then
        return "$cleanup_status"
      fi
      return "$original_status"
    }
    trap cleanup EXIT
    umask 077

    just repo secrets
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || {
      echo 'Set CLOUDFLARE_API_TOKEN to the supermorphic.com-scoped cert-manager token.' >&2
      exit 1
    }
    [[ -n "${PIHOLE_PASSWORD:-}" ]] || {
      echo 'Set PIHOLE_PASSWORD to a dedicated Pi-hole v6 application password.' >&2
      exit 1
    }
    [[ "${FOUNDATION_PROVIDER_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the internal foundation encrypted Secret manifests.' >&2
      echo "Set FOUNDATION_PROVIDER_SECRETS_CONFIRM='$expected_confirmation' after reviewing both targets." >&2
      exit 1
    }

    [[ -f "$pihole_ca" ]]
    ! rg -q 'PRIVATE KEY' "$pihole_ca"
    openssl verify -CAfile "$pihole_ca" "$pihole_ca" >/dev/null
    openssl x509 -in "$pihole_ca" -noout -checkend 2592000 >/dev/null || {
      echo 'The tracked Pi-hole CA expires within 30 days.' >&2
      exit 1
    }
    "${pihole_curl[@]}" "$pihole_api/api/info/login" >/dev/null

    token_state="$(curl --silent --show-error --fail-with-body --max-time 10 \
      --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      https://api.cloudflare.com/client/v4/user/tokens/verify)"
    [[ "$(yq -r '.success and (.result.status == "active")' - <<<"$token_state")" == 'true' ]] || {
      echo 'Cloudflare rejected the API token or it is not active.' >&2
      exit 1
    }
    zone_state="$(curl --silent --show-error --fail-with-body --max-time 10 \
      --get \
      --data-urlencode 'name=supermorphic.com' \
      --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      https://api.cloudflare.com/client/v4/zones)"
    [[ "$(yq -r '.success and (.result | length == 1) and (.result[0].name == "supermorphic.com")' - <<<"$zone_state")" == 'true' ]] || {
      echo 'The Cloudflare token cannot read exactly the supermorphic.com zone.' >&2
      exit 1
    }

    export PIHOLE_PASSWORD
    yq -n -o=json '{"password": strenv(PIHOLE_PASSWORD)}' >"$temp_dir/pihole-auth.json"
    pihole_state="$("${pihole_curl[@]}" \
      --request POST \
      --header 'Content-Type: application/json' \
      --data-binary @"$temp_dir/pihole-auth.json" \
      "$pihole_api/api/auth")"
    [[ "$(yq -r '.session.valid' - <<<"$pihole_state")" == 'true' ]] || {
      echo 'Pi-hole v6 did not accept the application password.' >&2
      exit 1
    }
    pihole_sid="$(yq -r '.session.sid' - <<<"$pihole_state")"
    [[ -n "$pihole_sid" && "$pihole_sid" != 'null' ]]

    current_records="$("${pihole_curl[@]}" \
      --header "X-FTL-SID: $pihole_sid" \
      "$pihole_api/api/config/dns/hosts")"
    if yq -r '.config.dns.hosts[]?' - <<<"$current_records" | rg -Fxq -- "$pihole_test_record"; then
      echo "Refusing to overwrite the unexpected Pi-hole record '$pihole_test_record'." >&2
      exit 1
    fi
    pihole_record_cleanup_needed=true
    if ! "${pihole_curl[@]}" \
      --request PUT \
      --header "X-FTL-SID: $pihole_sid" \
      "$pihole_test_url" >/dev/null; then
      if current_records="$("${pihole_curl[@]}" \
        --header "X-FTL-SID: $pihole_sid" \
        "$pihole_api/api/config/dns/hosts")" && \
        ! yq -r '.config.dns.hosts[]?' - <<<"$current_records" | rg -Fxq -- "$pihole_test_record"; then
        pihole_record_cleanup_needed=false
      fi
      echo 'Pi-hole rejected the temporary DNS write; verify webserver.api.app_sudo=true.' >&2
      exit 1
    fi
    current_records="$("${pihole_curl[@]}" \
      --header "X-FTL-SID: $pihole_sid" \
      "$pihole_api/api/config/dns/hosts")"
    yq -r '.config.dns.hosts[]?' - <<<"$current_records" | rg -Fxq -- "$pihole_test_record" || {
      echo 'Pi-hole accepted the write request but did not return the temporary DNS record.' >&2
      exit 1
    }
    cleanup_pihole_record || {
      echo "Pi-hole did not remove the temporary record '$pihole_test_record'." >&2
      exit 1
    }

    export CLOUDFLARE_API_TOKEN
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "cloudflare-api-token" |
       .metadata.namespace = "cert-manager" |
       .type = "Opaque" |
       .stringData."api-token" = strenv(CLOUDFLARE_API_TOKEN)' \
      >"$temp_dir/cloudflare.yaml"
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "pihole-password" |
       .metadata.namespace = "external-dns" |
       .type = "Opaque" |
       .stringData.password = strenv(PIHOLE_PASSWORD)' \
      >"$temp_dir/pihole.yaml"

    sops --encrypt --filename-override "$cloudflare_target" \
      "$temp_dir/cloudflare.yaml" >"$temp_dir/cloudflare.sops.yaml"
    sops --encrypt --filename-override "$pihole_target" \
      "$temp_dir/pihole.yaml" >"$temp_dir/pihole.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/cloudflare.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(sops filestatus "$temp_dir/pihole.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/cloudflare.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/pihole.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$CLOUDFLARE_API_TOKEN" "$temp_dir/cloudflare.sops.yaml"
    ! rg -Fq -- "$PIHOLE_PASSWORD" "$temp_dir/pihole.sops.yaml"

    scripts/repository/stamp-external-dns-provider.sh \
      "$pihole_ca" "$temp_dir/pihole.sops.yaml" "$external_dns_values" \
      "$temp_dir/external-dns-values.yaml"

    mv -- "$temp_dir/cloudflare.sops.yaml" "$cloudflare_target"
    mv -- "$temp_dir/pihole.sops.yaml" "$pihole_target"
    mv -- "$temp_dir/external-dns-values.yaml" "$external_dns_values"
    echo 'Internal foundation provider credentials passed Cloudflare validation and a trusted-HTTPS Pi-hole create/delete proof; only SOPS ciphertext and the ExternalDNS rollout stamp were written.'

# Validate the UNAS CIFS credentials and write only the SOPS-encrypted Longhorn
# backup Secret (nas-credentials in longhorn-system). Best-effort smbclient auth
# check when available; Longhorn re-validates the backup target after rollout.
storage-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:storage:nas-credentials:sops'
    target='kubernetes/apps/storage/longhorn/config/nas-credentials.sops.yaml'
    cifs_share='//192.168.0.3/Longhorn'
    temp_dir="$(mktemp -d /tmp/homelab-talos-storage-secrets.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${CIFS_USERNAME:-}" ]] || {
      echo 'Set CIFS_USERNAME to the UNAS SMB user for the Longhorn backup share.' >&2
      exit 1
    }
    [[ -n "${CIFS_PASSWORD:-}" ]] || {
      echo 'Set CIFS_PASSWORD to that SMB user password.' >&2
      exit 1
    }
    [[ "${STORAGE_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Longhorn backup Secret.' >&2
      echo "Set STORAGE_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    if command -v smbclient >/dev/null 2>&1; then
      if PASSWD="$CIFS_PASSWORD" smbclient "$cifs_share" -U "$CIFS_USERNAME" -c 'ls' >/dev/null 2>&1; then
        echo "CIFS auth to $cifs_share succeeded."
      else
        echo "CIFS auth to $cifs_share failed; check CIFS_USERNAME/CIFS_PASSWORD and the share." >&2
        exit 1
      fi
    else
      echo 'smbclient not found; skipping the live CIFS auth check (Longhorn validates the backup target after rollout, and storage-verify confirms it).' >&2
    fi

    export CIFS_USERNAME CIFS_PASSWORD
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "nas-credentials" |
       .metadata.namespace = "longhorn-system" |
       .type = "Opaque" |
       .stringData.CIFS_USERNAME = strenv(CIFS_USERNAME) |
       .stringData.CIFS_PASSWORD = strenv(CIFS_PASSWORD)' \
      >"$temp_dir/nas-credentials.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/nas-credentials.yaml" >"$temp_dir/nas-credentials.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/nas-credentials.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/nas-credentials.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$CIFS_PASSWORD" "$temp_dir/nas-credentials.sops.yaml"

    mv -- "$temp_dir/nas-credentials.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (nas-credentials in longhorn-system)."

# Validate the UNAS SMB credentials for the media share and write only the
# SOPS-encrypted smb-credentials Secret (in the media namespace) that csi-driver-smb
# uses to mount //192.168.0.3/Prometheus at /data. Keys are username/password (what
# smb.csi.k8s.io expects), distinct from the Longhorn backup Secret. Best-effort
# smbclient auth check when available. Never echoes the password.
media-smb-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:media:smb-credentials:sops'
    target='kubernetes/apps/media/storage/app/smb-credentials.sops.yaml'
    smb_share='//192.168.0.3/Prometheus'
    temp_dir="$(mktemp -d /tmp/homelab-talos-media-smb-secrets.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${CIFS_USERNAME:-}" ]] || {
      echo 'Set CIFS_USERNAME to the UNAS SMB user for the Prometheus media share.' >&2
      exit 1
    }
    [[ -n "${CIFS_PASSWORD:-}" ]] || {
      echo 'Set CIFS_PASSWORD to that SMB user password.' >&2
      exit 1
    }
    [[ "${MEDIA_SMB_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the media SMB Secret.' >&2
      echo "Set MEDIA_SMB_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    if command -v smbclient >/dev/null 2>&1; then
      if PASSWD="$CIFS_PASSWORD" smbclient "$smb_share" -U "$CIFS_USERNAME" -c 'ls' >/dev/null 2>&1; then
        echo "SMB auth to $smb_share succeeded."
      else
        echo "SMB auth to $smb_share failed; check CIFS_USERNAME/CIFS_PASSWORD and the share." >&2
        exit 1
      fi
    else
      echo 'smbclient not found; skipping the live SMB auth check (media-storage-verify confirms the mount after rollout).' >&2
    fi

    export CIFS_USERNAME CIFS_PASSWORD
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "smb-credentials" |
       .metadata.namespace = "media" |
       .type = "Opaque" |
       .stringData.username = strenv(CIFS_USERNAME) |
       .stringData.password = strenv(CIFS_PASSWORD)' \
      >"$temp_dir/smb-credentials.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/smb-credentials.yaml" >"$temp_dir/smb-credentials.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/smb-credentials.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/smb-credentials.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$CIFS_PASSWORD" "$temp_dir/smb-credentials.sops.yaml"

    mv -- "$temp_dir/smb-credentials.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (smb-credentials in media)."

# Write the SOPS-encrypted ProtonVPN Secret for the qBittorrent+Gluetun pod: the
# WireGuard private key plus a generated Gluetun control-server auth config.toml
# (no-auth health role + apikey-guarded mutating routes). The operator supplies ONLY
# WIREGUARD_PRIVATE_KEY (ProtonVPN dashboard -> WireGuard config with NAT-PMP/port
# forwarding on a P2P server); Gluetun auto-selects the server via PORT_FORWARD_ONLY.
# Never echoes the key or the apikey.
protonvpn-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:media:protonvpn:sops'
    target='kubernetes/apps/media/qbittorrent/app/protonvpn.sops.yaml'
    values='kubernetes/apps/media/qbittorrent/app/values.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-protonvpn-secrets.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${WIREGUARD_PRIVATE_KEY:-}" ]] || {
      echo 'Set WIREGUARD_PRIVATE_KEY to the ProtonVPN WireGuard PrivateKey (generate a WireGuard config with port forwarding/NAT-PMP enabled on a P2P server).' >&2
      exit 1
    }
    [[ "${PROTONVPN_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the ProtonVPN Secret.' >&2
      echo "Set PROTONVPN_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    # Generate a control-server API key for the mutating routes (health stays no-auth).
    apikey="$(openssl rand -hex 32)"
    cat >"$temp_dir/config.toml" <<TOML
    [[roles]]
    name = "health"
    routes = ["GET /v1/vpn/status"]
    auth = "none"

    [[roles]]
    name = "vpn_control"
    routes = ["PUT /v1/vpn/status", "GET /v1/publicip/ip", "GET /v1/portforward"]
    auth = "apikey"
    apikey = "$apikey"
    TOML
    # strip the leading indentation the heredoc kept
    sed -i '' 's/^    //' "$temp_dir/config.toml" 2>/dev/null || sed -i 's/^    //' "$temp_dir/config.toml"

    export WIREGUARD_PRIVATE_KEY
    CONTROL_CONFIG="$(cat "$temp_dir/config.toml")"
    export CONTROL_CONFIG
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "protonvpn" |
       .metadata.namespace = "media" |
       .type = "Opaque" |
       .stringData."WIREGUARD_PRIVATE_KEY" = strenv(WIREGUARD_PRIVATE_KEY) |
       .stringData."config.toml" = strenv(CONTROL_CONFIG)' \
      >"$temp_dir/protonvpn.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/protonvpn.yaml" >"$temp_dir/protonvpn.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/protonvpn.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/protonvpn.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$WIREGUARD_PRIVATE_KEY" "$temp_dir/protonvpn.sops.yaml"
    ! rg -Fq -- "$apikey" "$temp_dir/protonvpn.sops.yaml"

    revision="$(git hash-object "$temp_dir/protonvpn.sops.yaml")"
    cp -- "$values" "$temp_dir/values.yaml"
    REV="$revision" yq -i \
      '.controllers.qbittorrent.pod.annotations."sops-hash" = strenv(REV)' \
      "$temp_dir/values.yaml"
    [[ "$(yq -r '.controllers.qbittorrent.pod.annotations."sops-hash"' "$temp_dir/values.yaml")" == "$revision" ]]

    mv -- "$temp_dir/protonvpn.sops.yaml" "$target"
    mv -- "$temp_dir/values.yaml" "$values"
    [[ "$(git hash-object "$target")" == "$revision" ]]
    [[ "$(yq -r '.controllers.qbittorrent.pod.annotations."sops-hash"' "$values")" == "$revision" ]]
    echo "Wrote SOPS-encrypted $target (protonvpn in media) and stamped its rollout revision in $values. Control-server apikey is embedded in the encrypted config.toml."

# Write only the SOPS-encrypted Grafana admin Secret for kube-prometheus-stack
# from GRAFANA_ADMIN_USER/GRAFANA_ADMIN_PASSWORD. Never echoes the password.
monitoring-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:grafana-admin:sops'
    target='kubernetes/apps/monitoring/kube-prometheus-stack/app/grafana-admin.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-monitoring-secrets.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${GRAFANA_ADMIN_USER:-}" ]] || {
      echo 'Set GRAFANA_ADMIN_USER to the Grafana admin username.' >&2
      exit 1
    }
    [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] || {
      echo 'Set GRAFANA_ADMIN_PASSWORD to the Grafana admin password.' >&2
      exit 1
    }
    [[ "${#GRAFANA_ADMIN_PASSWORD}" -ge 12 ]] || {
      echo 'Refusing: GRAFANA_ADMIN_PASSWORD must be at least 12 characters.' >&2
      exit 1
    }
    [[ "${MONITORING_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Grafana admin Secret.' >&2
      echo "Set MONITORING_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "grafana-admin-secret" |
       .metadata.namespace = "monitoring" |
       .type = "Opaque" |
       .stringData."admin-user" = strenv(GRAFANA_ADMIN_USER) |
       .stringData."admin-password" = strenv(GRAFANA_ADMIN_PASSWORD)' \
      >"$temp_dir/grafana-admin.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/grafana-admin.yaml" >"$temp_dir/grafana-admin.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/grafana-admin.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/grafana-admin.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$GRAFANA_ADMIN_PASSWORD" "$temp_dir/grafana-admin.sops.yaml"

    mv -- "$temp_dir/grafana-admin.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (grafana-admin-secret in monitoring)."

# Write only the SOPS-encrypted Homepage Secret (Grafana widget credentials) from
# GRAFANA_ADMIN_USER/GRAFANA_ADMIN_PASSWORD. Same creds as the Grafana admin login.
# Write ONLY the SOPS-encrypted Homepage Grafana widget Secret (homepage-grafana in the
# homepage namespace) from GRAFANA_ADMIN_USER/GRAFANA_ADMIN_PASSWORD. Split from the Plex
# token so either can be rotated independently. Never echoes the values.
homepage-grafana-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-grafana:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-grafana.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-grafana.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${GRAFANA_ADMIN_USER:-}" ]] || {
      echo 'Set GRAFANA_ADMIN_USER to the Grafana admin username (must match the grafana-admin Secret).' >&2
      exit 1
    }
    [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] || {
      echo 'Set GRAFANA_ADMIN_PASSWORD to that Grafana admin password (must match the grafana-admin Secret).' >&2
      exit 1
    }
    [[ "${HOMEPAGE_GRAFANA_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Grafana Secret.' >&2
      echo "Set HOMEPAGE_GRAFANA_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-grafana" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."username" = strenv(GRAFANA_ADMIN_USER) |
       .stringData."password" = strenv(GRAFANA_ADMIN_PASSWORD)' \
      >"$temp_dir/homepage-grafana.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-grafana.yaml" >"$temp_dir/homepage-grafana.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-grafana.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-grafana.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$GRAFANA_ADMIN_PASSWORD" "$temp_dir/homepage-grafana.sops.yaml"

    mv -- "$temp_dir/homepage-grafana.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-grafana in homepage)."

# Write ONLY the SOPS-encrypted Homepage Portainer widget Secret
# (homepage-portainer in the homepage namespace) from PORTAINER_API_KEY.
# Generate a dedicated Portainer access token; never echoes the value.
homepage-portainer-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-portainer:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-portainer.sops.yaml'
    deployment='kubernetes/apps/monitoring/homepage/app/deployment.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-portainer.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${PORTAINER_API_KEY:-}" ]] || {
      echo 'Set PORTAINER_API_KEY to a dedicated Portainer access token for the Homepage widget.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_PORTAINER_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Portainer Secret.' >&2
      echo "Set HOMEPAGE_PORTAINER_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export PORTAINER_API_KEY
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-portainer" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."apiKey" = strenv(PORTAINER_API_KEY)' \
      >"$temp_dir/homepage-portainer.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-portainer.yaml" >"$temp_dir/homepage-portainer.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-portainer.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-portainer.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$PORTAINER_API_KEY" "$temp_dir/homepage-portainer.sops.yaml"

    scripts/repository/stamp-homepage-portainer.sh \
      "$temp_dir/homepage-portainer.sops.yaml" "$deployment" \
      "$temp_dir/homepage-deployment.yaml"

    mv -- "$temp_dir/homepage-portainer.sops.yaml" "$target"
    mv -- "$temp_dir/homepage-deployment.yaml" "$deployment"
    echo "Wrote SOPS-encrypted $target and stamped its revision into $deployment."

# Write ONLY the SOPS-encrypted Homepage Plex widget Secret (homepage-plex in the homepage
# namespace) from PLEX_TOKEN. Independent of the Grafana Secret. Never echoes the value.
homepage-plex-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-plex:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-plex.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-plex.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${PLEX_TOKEN:-}" ]] || {
      echo 'Set PLEX_TOKEN to a Plex server token (X-Plex-Token) for the Homepage Plex widget.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_PLEX_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Plex Secret.' >&2
      echo "Set HOMEPAGE_PLEX_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export PLEX_TOKEN
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-plex" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."token" = strenv(PLEX_TOKEN)' \
      >"$temp_dir/homepage-plex.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-plex.yaml" >"$temp_dir/homepage-plex.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-plex.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-plex.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$PLEX_TOKEN" "$temp_dir/homepage-plex.sops.yaml"

    mv -- "$temp_dir/homepage-plex.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-plex in homepage)."

homepage-tautulli-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-tautulli:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-tautulli.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${TAUTULLI_API_KEY:-}" ]] || {
      echo 'Set TAUTULLI_API_KEY to the API key generated in Tautulli.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_TAUTULLI_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Tautulli Secret.' >&2
      echo "Set HOMEPAGE_TAUTULLI_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export TAUTULLI_API_KEY
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-tautulli" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."apiKey" = strenv(TAUTULLI_API_KEY)' \
      >"$temp_dir/homepage-tautulli.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-tautulli.yaml" >"$temp_dir/homepage-tautulli.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-tautulli.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-tautulli.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$TAUTULLI_API_KEY" "$temp_dir/homepage-tautulli.sops.yaml"

    mv -- "$temp_dir/homepage-tautulli.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-tautulli in homepage)."

# Write ONLY the SOPS-encrypted Homepage Seerr widget Secret
# (homepage-seerr in the homepage namespace) from SEERR_API_KEY.
# Independent of the other Homepage widget credentials. Never echoes the value.
homepage-seerr-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-seerr:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-seerr.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-seerr.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${SEERR_API_KEY:-}" ]] || {
      echo 'Set SEERR_API_KEY to the API key from Seerr Settings > General.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_SEERR_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Seerr Secret.' >&2
      echo "Set HOMEPAGE_SEERR_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export SEERR_API_KEY
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-seerr" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."apiKey" = strenv(SEERR_API_KEY)' \
      >"$temp_dir/homepage-seerr.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-seerr.yaml" >"$temp_dir/homepage-seerr.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-seerr.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-seerr.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$SEERR_API_KEY" "$temp_dir/homepage-seerr.sops.yaml"

    mv -- "$temp_dir/homepage-seerr.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-seerr in homepage)."

# Write ONLY the SOPS-encrypted Homepage Radarr widget Secret
# (homepage-radarr in the homepage namespace) from RADARR_API_KEY.
# Independent of the other Homepage widget credentials. Never echoes the value.
homepage-radarr-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-radarr:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-radarr.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-radarr.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${RADARR_API_KEY:-}" ]] || {
      echo 'Set RADARR_API_KEY to the API key from Radarr Settings > General.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_RADARR_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Radarr Secret.' >&2
      echo "Set HOMEPAGE_RADARR_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export RADARR_API_KEY
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-radarr" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."apiKey" = strenv(RADARR_API_KEY)' \
      >"$temp_dir/homepage-radarr.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-radarr.yaml" >"$temp_dir/homepage-radarr.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-radarr.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-radarr.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$RADARR_API_KEY" "$temp_dir/homepage-radarr.sops.yaml"

    mv -- "$temp_dir/homepage-radarr.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-radarr in homepage)."

# Write ONLY the SOPS-encrypted Homepage Lidarr widget Secret
# (homepage-lidarr in the homepage namespace) from LIDARR_API_KEY.
# Independent of the other Homepage widget credentials. Never echoes the value.
homepage-lidarr-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-lidarr:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-lidarr.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-lidarr.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${LIDARR_API_KEY:-}" ]] || {
      echo 'Set LIDARR_API_KEY to the API key from Lidarr Settings > General.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_LIDARR_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Lidarr Secret.' >&2
      echo "Set HOMEPAGE_LIDARR_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export LIDARR_API_KEY
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-lidarr" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."apiKey" = strenv(LIDARR_API_KEY)' \
      >"$temp_dir/homepage-lidarr.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-lidarr.yaml" >"$temp_dir/homepage-lidarr.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-lidarr.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-lidarr.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$LIDARR_API_KEY" "$temp_dir/homepage-lidarr.sops.yaml"

    mv -- "$temp_dir/homepage-lidarr.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-lidarr in homepage)."

# Write ONLY the SOPS-encrypted Homepage Sonarr widget Secret
# (homepage-sonarr in the homepage namespace) from SONARR_API_KEY.
# Independent of the other Homepage widget credentials. Never echoes the value.
homepage-sonarr-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-sonarr:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-sonarr.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-sonarr.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${SONARR_API_KEY:-}" ]] || {
      echo 'Set SONARR_API_KEY to the API key from Sonarr Settings > General.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_SONARR_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Sonarr Secret.' >&2
      echo "Set HOMEPAGE_SONARR_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export SONARR_API_KEY
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-sonarr" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."apiKey" = strenv(SONARR_API_KEY)' \
      >"$temp_dir/homepage-sonarr.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-sonarr.yaml" >"$temp_dir/homepage-sonarr.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-sonarr.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-sonarr.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$SONARR_API_KEY" "$temp_dir/homepage-sonarr.sops.yaml"

    mv -- "$temp_dir/homepage-sonarr.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-sonarr in homepage)."

# Write ONLY the SOPS-encrypted Homepage Prowlarr widget Secret
# (homepage-prowlarr in the homepage namespace) from PROWLARR_API_KEY.
# Independent of the other Homepage widget credentials. Never echoes the value.
homepage-prowlarr-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-prowlarr:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-prowlarr.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-prowlarr.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${PROWLARR_API_KEY:-}" ]] || {
      echo 'Set PROWLARR_API_KEY to the API key from Prowlarr Settings > General.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_PROWLARR_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Prowlarr Secret.' >&2
      echo "Set HOMEPAGE_PROWLARR_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export PROWLARR_API_KEY
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-prowlarr" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."apiKey" = strenv(PROWLARR_API_KEY)' \
      >"$temp_dir/homepage-prowlarr.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-prowlarr.yaml" >"$temp_dir/homepage-prowlarr.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-prowlarr.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-prowlarr.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$PROWLARR_API_KEY" "$temp_dir/homepage-prowlarr.sops.yaml"

    mv -- "$temp_dir/homepage-prowlarr.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-prowlarr in homepage)."

# Write ONLY the SOPS-encrypted Homepage qBittorrent widget Secret
# (homepage-qbittorrent in the homepage namespace) from the permanent qBittorrent
# WebUI credential. qBittorrent's supported Homepage/Servarr integrations use this
# username/password; never echoes either value.
homepage-qbittorrent-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-qbittorrent:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-qbittorrent.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-qbittorrent.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${QBITTORRENT_USERNAME:-}" ]] || {
      echo 'Set QBITTORRENT_USERNAME to the permanent qBittorrent WebUI username.' >&2
      exit 1
    }
    [[ -n "${QBITTORRENT_PASSWORD:-}" ]] || {
      echo 'Set QBITTORRENT_PASSWORD to the permanent qBittorrent WebUI password.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_QBITTORRENT_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage qBittorrent Secret.' >&2
      echo "Set HOMEPAGE_QBITTORRENT_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export QBITTORRENT_USERNAME QBITTORRENT_PASSWORD
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-qbittorrent" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."username" = strenv(QBITTORRENT_USERNAME) |
       .stringData."password" = strenv(QBITTORRENT_PASSWORD)' \
      >"$temp_dir/homepage-qbittorrent.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-qbittorrent.yaml" >"$temp_dir/homepage-qbittorrent.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-qbittorrent.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-qbittorrent.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$QBITTORRENT_USERNAME" "$temp_dir/homepage-qbittorrent.sops.yaml"
    ! rg -Fq -- "$QBITTORRENT_PASSWORD" "$temp_dir/homepage-qbittorrent.sops.yaml"

    mv -- "$temp_dir/homepage-qbittorrent.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-qbittorrent in homepage)."

# Write the SOPS-encrypted qbit_manage Secret in the media namespace from the permanent
# qBittorrent WebUI credential. qbit_manage's config.yml reads qbt.user/qbt.pass via
# !ENV QBT_USER / !ENV QBT_PASS (those keys have no env override), so this Secret is the
# one authoritative media-namespace copy of the WebUI credential. The value's source of
# truth stays the operator's password manager — the same credential Sonarr/Radarr use.
# Overwrites the placeholder committed with the app. Never echoes either value.
qbit-manage-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:media:qbit-manage-secret:sops'
    target='kubernetes/apps/media/qbit-manage/app/qbit-manage-secret.sops.yaml'
    values='kubernetes/apps/media/qbit-manage/app/values.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-qbit-manage-secrets.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${QBITTORRENT_USERNAME:-}" ]] || {
      echo 'Set QBITTORRENT_USERNAME to the permanent qBittorrent WebUI username.' >&2
      exit 1
    }
    [[ -n "${QBITTORRENT_PASSWORD:-}" ]] || {
      echo 'Set QBITTORRENT_PASSWORD to the permanent qBittorrent WebUI password.' >&2
      exit 1
    }
    [[ "${QBIT_MANAGE_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the qbit_manage Secret.' >&2
      echo "Set QBIT_MANAGE_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export QBITTORRENT_USERNAME QBITTORRENT_PASSWORD
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "qbit-manage-secret" |
       .metadata.namespace = "media" |
       .type = "Opaque" |
       .stringData."QBT_USER" = strenv(QBITTORRENT_USERNAME) |
       .stringData."QBT_PASS" = strenv(QBITTORRENT_PASSWORD)' \
      >"$temp_dir/qbit-manage-secret.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/qbit-manage-secret.yaml" >"$temp_dir/qbit-manage-secret.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/qbit-manage-secret.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/qbit-manage-secret.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$QBITTORRENT_USERNAME" "$temp_dir/qbit-manage-secret.sops.yaml"
    ! rg -Fq -- "$QBITTORRENT_PASSWORD" "$temp_dir/qbit-manage-secret.sops.yaml"
    scripts/repository/stamp-qbit-manage-secret.sh \
      "$temp_dir/qbit-manage-secret.sops.yaml" "$values" "$temp_dir/values.yaml"

    mv -- "$temp_dir/qbit-manage-secret.sops.yaml" "$target"
    mv -- "$temp_dir/values.yaml" "$values"
    [[ "$(yq -r '.controllers."qbit-manage".pod.annotations."sops-hash"' "$values")" == \
      "$(git hash-object "$target")" ]]
    echo "Wrote SOPS-encrypted $target and stamped its rollout revision in $values."

# Write only the SOPS-encrypted initial Portainer administrator password. Portainer
# consumes this on first database initialization; rotating the live administrator
# password later requires Portainer's supported password-change/reset workflow.
portainer-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:portainer-admin:sops'
    target='kubernetes/apps/monitoring/portainer/app/portainer-admin-password.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-portainer-secrets.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${PORTAINER_ADMIN_PASSWORD:-}" ]] || {
      echo 'Set PORTAINER_ADMIN_PASSWORD to the initial Portainer administrator password.' >&2
      exit 1
    }
    [[ "${#PORTAINER_ADMIN_PASSWORD}" -ge 12 ]] || {
      echo 'Refusing: PORTAINER_ADMIN_PASSWORD must be at least 12 characters.' >&2
      exit 1
    }
    [[ "${PORTAINER_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Portainer administrator Secret.' >&2
      echo "Set PORTAINER_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export PORTAINER_ADMIN_PASSWORD
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "portainer-admin-password" |
       .metadata.namespace = "portainer" |
       .type = "Opaque" |
       .stringData.password = strenv(PORTAINER_ADMIN_PASSWORD)' \
      >"$temp_dir/portainer-admin-password.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/portainer-admin-password.yaml" >"$temp_dir/portainer-admin-password.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/portainer-admin-password.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/portainer-admin-password.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$PORTAINER_ADMIN_PASSWORD" "$temp_dir/portainer-admin-password.sops.yaml"

    mv -- "$temp_dir/portainer-admin-password.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (portainer-admin-password in portainer)."

# Write ONLY the SOPS-encrypted Tailscale operator OAuth Secret (operator-oauth in the
# tailscale namespace) from TS_OAUTH_CLIENT_ID and TS_OAUTH_CLIENT_SECRET. The chart
# consumes this pre-created Secret when oauth.clientId/clientSecret are empty. Create the
# OAuth client in the tailnet admin console first (tagged tag:k8s-operator, scopes
# Devices/Core + Keys/Auth Keys + Services = write) — see
# docs/guides/tailscale-operator-operations.md.
# Never echoes the values.
tailscale-operator-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:networking:tailscale-operator:sops'
    target='kubernetes/apps/networking/tailscale-operator/app/oauth.sops.yaml'
    values='kubernetes/apps/networking/tailscale-operator/app/values.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-tailscale-operator.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${TS_OAUTH_CLIENT_ID:-}" ]] || {
      echo 'Set TS_OAUTH_CLIENT_ID to the Tailscale OAuth client ID (tag:k8s-operator).' >&2
      exit 1
    }
    [[ -n "${TS_OAUTH_CLIENT_SECRET:-}" ]] || {
      echo 'Set TS_OAUTH_CLIENT_SECRET to the Tailscale OAuth client secret.' >&2
      exit 1
    }
    [[ "${TS_OAUTH_CLIENT_SECRET}" == tskey-client-* ]] || {
      echo 'Refusing: TS_OAUTH_CLIENT_SECRET does not look like a Tailscale OAuth client secret (tskey-client-*).' >&2
      exit 1
    }
    [[ "${TAILSCALE_OPERATOR_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Tailscale operator OAuth Secret.' >&2
      echo "Set TAILSCALE_OPERATOR_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export TS_OAUTH_CLIENT_ID TS_OAUTH_CLIENT_SECRET
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "operator-oauth" |
       .metadata.namespace = "tailscale" |
       .type = "Opaque" |
       .stringData.client_id = strenv(TS_OAUTH_CLIENT_ID) |
       .stringData.client_secret = strenv(TS_OAUTH_CLIENT_SECRET)' \
      >"$temp_dir/operator-oauth.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/operator-oauth.yaml" >"$temp_dir/operator-oauth.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/operator-oauth.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/operator-oauth.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$TS_OAUTH_CLIENT_ID" "$temp_dir/operator-oauth.sops.yaml"
    ! rg -Fq -- "$TS_OAUTH_CLIENT_SECRET" "$temp_dir/operator-oauth.sops.yaml"
    scripts/repository/stamp-tailscale-operator-secret.sh \
      "$temp_dir/operator-oauth.sops.yaml" "$values" "$temp_dir/values.yaml"

    mv -- "$temp_dir/operator-oauth.sops.yaml" "$target"
    mv -- "$temp_dir/values.yaml" "$values"
    [[ "$(yq -r '.operatorConfig.podAnnotations."sops-hash"' "$values")" == \
      "$(git hash-object "$target")" ]]
    echo "Wrote SOPS-encrypted $target and stamped its Operator rollout revision in $values."

# Registry-backed ntfy credential lifecycle over the canonical ntfy Secret (ntfy-secret
# in the ntfy namespace, carrying the NTFY_AUTH_* lists and the adapter's auth.yml) and
# the mirrored Homepage widget Secret. ensure/reconcile/rotate/finalize preserve existing
# credentials by default, generate them only for missing or rotated identities, and never
# print secrets. Guard: NTFY_IDENTITY_CONFIRM='<action>:monitoring:ntfy:<identity>:sops'
# (reconcile uses 'all' as the identity). See docs/guides/ntfy-operations.md.
ntfy-identity action identity:
    #!/usr/bin/env bash
    set -euo pipefail
    just repo secrets
    exec scripts/secrets/ntfy-identity.sh '{{action}}' '{{identity}}'

# Set or change the human-known ntfy subscriber password. Prompts twice without echo,
# generates the bcrypt hash internally, and updates only the subscriber entries in the
# canonical ntfy Secret. Guard: NTFY_SUBSCRIBER_PASSWORD_CONFIRM='write:monitoring:ntfy-subscriber:sops'.
ntfy-subscriber-password:
    #!/usr/bin/env bash
    set -euo pipefail
    just repo secrets
    exec scripts/secrets/ntfy-subscriber-password.sh

# Reject broken relative Markdown links and bare repository documentation paths.
links-validate:
    scripts/validate/links-test.sh

# Run repository and declarative Talos source validation.
validate: toolchain-validate validate-files validate-shell-scripts
    just talos source-validate
    just repo secret-scan
    @echo "Repository and Talos source checks passed."

# Fail unless running under bash >= 5. macOS /bin/bash 3.2 does not honor set -e
# for a failed bare [[ ]] or (( )) mid-recipe, so validation assertions would
# silently not gate. Recipes use #!/usr/bin/env bash, so a bash >= 5 earlier in
# PATH (for example brew install bash) is what makes the guards effective.
# Install the git pre-commit hooks into the shared Git common directory (idempotent).
hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
    hooks_dir="$common_dir/hooks"
    prior_hooks_path=''
    prior_hooks_path_set=false
    if prior_hooks_path="$(git config --local --get core.hooksPath)"; then
      prior_hooks_path_set=true
    else
      status="$?"
      [[ "$status" -eq 1 ]] || exit "$status"
    fi
    restore_prior_hooks_path() {
      local status="$?"
      trap - EXIT
      if [[ "$prior_hooks_path_set" == true ]]; then
        git config --local core.hooksPath "$prior_hooks_path"
      else
        git config --local --unset-all core.hooksPath || [[ "$?" -eq 5 ]]
      fi
      exit "$status"
    }
    trap restore_prior_hooks_path EXIT
    mkdir -p "$hooks_dir"
    git config --local --unset-all core.hooksPath || [[ "$?" -eq 5 ]]
    pre-commit install --install-hooks
    install -m 0755 scripts/hooks/pre-commit.sh "$hooks_dir/pre-commit"
    git config --local core.hooksPath "$hooks_dir"
    trap - EXIT

# Run every pre-commit hook against the whole tree. Fails if a hook fails or would
# modify a file. Folded into `just ci` for local fast feedback and CI.
lint:
    pre-commit run --all-files --show-diff-on-failure

[private]
require-bash:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/common.sh
    require_bash

# Parse and ShellCheck every Bash validation, verification, test, and probe
# entrypoint. Live behavior is proven separately through operator-run gates.
[private]
validate-shell-scripts:
    #!/usr/bin/env bash
    set -euo pipefail
    for script in scripts/hooks/*.sh scripts/repository/*.sh scripts/talos/*.sh scripts/validate/*.sh scripts/verify/*.sh; do
      test -x "$script"
    done
    artifact_root="${TEST_SHARED_RESULT_DIR:-}"
    artifact_root_created=false
    if [[ -z "$artifact_root" ]]; then
      artifact_root="$(mktemp -d "${TMPDIR:-/tmp}/repo-shell.XXXXXX")"
      artifact_root_created=true
    fi
    cleanup_artifact_root() {
      local exit_status="$?"
      trap - EXIT
      if [[ "$artifact_root_created" == true ]]; then
        rm -rf -- "$artifact_root"
      fi
      exit "$exit_status"
    }
    trap cleanup_artifact_root EXIT
    args=(produce --suite validation.repo-validate \
      --artifact "$artifact_root/repository-shell-validation.json" \
      --run-id "${TEST_RUN_ID:-standalone}")
    if [[ -n "${TEST_RESULT_FRAGMENT_DIR:-}" ]]; then
      args+=(--junit "$TEST_RESULT_FRAGMENT_DIR/repository-shell-validation.xml")
    fi
    python scripts/test/repository_shell_validation.py "${args[@]}"
    if rg -n 'shellcheck disable=SC2251' scripts/validate scripts/verify; then
      echo 'SC2251 suppressions can hide non-gating absence assertions.' >&2
      exit 1
    fi

# Verify ignore boundaries and SOPS policy.
validate-files: require-bash
    @bash --version | head -n 1
    @scripts/test/hooks-test.sh
    @scripts/test/external-dns-provider-rollout-test.sh
    @scripts/test/homepage-portainer-rollout-test.sh
    @scripts/test/qbit-manage-secret-rollout-test.sh
    @scripts/test/tailscale-operator-secret-rollout-test.sh
    @git check-ignore -q clusterconfig/nuc1.yaml
    @git check-ignore -q .talos/config
    @git check-ignore -q .kube/config
    @git check-ignore -q scratch/talosconfig
    @git check-ignore -q scratch/kubeconfig
    @git check-ignore -q support-bundles/example.tar.gz
    @test -f scripts/lib/common.sh
    @bash -n scripts/lib/common.sh
    @test -f scripts/lib/rollout.sh
    @bash -n scripts/lib/rollout.sh
    @rg -q '^require_deployed_source\(\)' scripts/lib/rollout.sh
    @if rg -q '^require_deployed_source\(\)' scripts/lib/common.sh; then echo "rollout guards belong in scripts/lib/rollout.sh, not the validator-safe common library" >&2; exit 1; fi
    @if rg -n "git branch --show-current.*main|local HEAD and origin/main differ|checked-out branch is not main" .just/bootstrap.just kubernetes/mod.just; then echo "cluster rollout guards must be branch-agnostic and compare their deployed source paths with origin/main" >&2; exit 1; fi
    @test "$(rg -c 'require_deployed_source ' .just/bootstrap.just kubernetes/mod.just | awk -F: '{sum += $2} END {print sum}')" -eq 28  # Update when adding/removing a guarded rollout recipe.
    @agent_access_recipe="$(just --dry-run bootstrap agent-access 2>&1)"; \
      normalized_recipe="$(tr '\n\t' '  ' <<<"$agent_access_recipe" | sed -E 's/\\[[:space:]]+/ /g; s/[[:space:]]+/ /g')"; \
      matrix_contract="scripts/verify/agent-access.sh \"\$kubeconfig\" '.talos/config'"; \
      rg -Fq -- "$matrix_contract" <<<"$normalized_recipe" || { echo 'agent-access bootstrap must run the shared complete authorization matrix' >&2; exit 1; }
    @if rg -n "(^[[:space:]]*talosconfig='(\\.\\./)?clusterconfig/talosconfig'|--talosconfig (\\.\\./)?clusterconfig/talosconfig|^[[:space:]]*kubeconfig='(\\.\\./)?kubeconfig'|^kubeconfig := \"kubeconfig\")" .just/bootstrap.just talos/mod.just kubernetes/mod.just; then echo "runtime credentials must use the centralized .talos/config and .kube/config paths" >&2; exit 1; fi
    @if git check-ignore -q talos/talconfig.yaml; then echo "talos/talconfig.yaml must be trackable" >&2; exit 1; fi
    @if git check-ignore -q talos/talsecret.sops.yaml; then echo "encrypted Talos secrets must be trackable" >&2; exit 1; fi
    @if git check-ignore -q kubernetes/apps/example/secret.sops.yaml; then echo "encrypted Kubernetes secrets must be trackable" >&2; exit 1; fi
    @test -f kubernetes/flux/clusters/prod/apps.yaml
    @test -f kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml
    @test -f kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml
    @test -f kubernetes/apps/networking/external-dns/app/pihole-ca.crt
    @test -f kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml
    @test -f kubernetes/apps/monitoring/portainer/app/portainer-admin-password.sops.yaml
    @if git check-ignore -q kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml; then echo "the encrypted Flux canary must be trackable" >&2; exit 1; fi
    @if git check-ignore -q kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml; then echo "the encrypted Cloudflare token must be trackable" >&2; exit 1; fi
    @if git check-ignore -q kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml; then echo "the encrypted Pi-hole password must be trackable" >&2; exit 1; fi
    @if git check-ignore -q kubernetes/apps/monitoring/portainer/app/portainer-admin-password.sops.yaml; then echo "the encrypted Portainer administrator password must be trackable" >&2; exit 1; fi
    @test "$(yq -r '.creation_rules[0].encrypted_regex' .sops.yaml)" = '^(.*)$'
    @test "$(yq -r '.creation_rules[1].encrypted_regex' .sops.yaml)" = '^(data|stringData)$'
    @test "$(yq -r '[.creation_rules[].age | test("^age1")] | all' .sops.yaml)" = true
    @test "$(sops filestatus kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml | yq -r '.encrypted')" = true
    @test "$(sops filestatus kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml | yq -r '.encrypted')" = true
    @test "$(sops filestatus kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml | yq -r '.encrypted')" = true
    @test "$(sops filestatus kubernetes/apps/monitoring/portainer/app/portainer-admin-password.sops.yaml | yq -r '.encrypted')" = true
    @if rg -q 'PRIVATE KEY' kubernetes/apps/networking/external-dns/app/pihole-ca.crt; then echo "Pi-hole CA source must not contain a private key" >&2; exit 1; fi

# Scan HEAD ancestry and all currently trackable files without printing secrets.
secret-scan:
    #!/usr/bin/env bash
    set -euo pipefail
    if git ls-files --cached --others --exclude-standard -z \
      | xargs -0 rg -l 'AGE-SECRET-KEY-1[0-9A-Z]{20,}' >/dev/null 2>&1; then
      echo "An age private key exists in a trackable file." >&2
      exit 1
    fi
    gitleaks git --log-opts=HEAD --redact --no-banner .
    git diff --no-ext-diff HEAD | gitleaks stdin --redact --no-banner
    untracked="$(git ls-files --others --exclude-standard)"
    if [[ -n "$untracked" ]]; then
      while IFS= read -r file; do printf '\nFILE: %s\n' "$file"; cat "$file"; done <<< "$untracked" \
        | gitleaks stdin --redact --no-banner
    fi
