#!/usr/bin/env bash
# Fixtures and PATH-stubbed fakes for the ntfy credential lifecycle unit tests. The stub
# sops proves the scripts call the real sops CLI correctly (decrypt/encrypt/filestatus)
# and transform stringData values; real age encryption is exercised only by the operator.
# Sourcing this file must not alter the caller's shell options.

ntfy_fixture_sub_hash="\$2a\$10\$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy"
ntfy_fixture_am_hash="\$2b\$10\$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWz"
ntfy_fixture_seerr_hash="\$2b\$10\$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhW0"
ntfy_fixture_automation_hash="\$2b\$10\$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhW1"
ntfy_fixture_homepage_hash="\$2b\$10\$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhW2"
ntfy_fixture_n8n_hash="\$2b\$10\$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhW3"
ntfy_fixture_am_token='tk_aaaaaaaaaaaaaaaaaaaaaaaaaaaa1'
ntfy_fixture_seerr_token='tk_ssssssssssssssssssssssssssss1'
ntfy_fixture_automation_token='tk_uuuuuuuuuuuuuuuuuuuuuuuuuuuu1'
ntfy_fixture_homepage_token='tk_hhhhhhhhhhhhhhhhhhhhhhhhhhhh1'
ntfy_fixture_n8n_token='tk_nnnnnnnnnnnnnnnnnnnnnnnnnnnn1'

# Registry matching the production identities.yaml shape.
ntfy_write_registry() { # <file>
  cat >"$1" <<'EOF'
identities:
  subscriber:
    status: active
    credential: password
    access:
      - { topic: critical, permission: ro }
      - { topic: homelab, permission: ro }
      - { topic: media, permission: ro }
    consumer: none
  alertmanager:
    status: active
    credential: token
    access:
      - { topic: critical, permission: wo }
      - { topic: homelab, permission: wo }
    consumer: alertmanager-auth
  seerr:
    status: active
    credential: token
    access:
      - { topic: media, permission: wo }
    consumer: seerr-api
  homepage:
    status: active
    credential: token
    access:
      - { topic: critical, permission: ro }
    consumer: homepage-secret
  n8n:
    status: active
    credential: token
    access:
      - { topic: homelab, permission: wo }
    consumer: n8n-api
  automation:
    status: retired
EOF
}

# Plaintext (pre-"encryption") canonical Secret fixture. Variant `main` mirrors the
# projected state after explicit n8n identity generation; variant `pre-n8n` mirrors the
# current production state; variant `legacy` predates the homepage and n8n identities.
ntfy_write_secret_plain() { # <file> <main|pre-n8n|legacy>
  local homepage_users='' homepage_access='' homepage_tokens=''
  local n8n_users='' n8n_access='' n8n_tokens=''
  if [[ "$2" == 'main' ]]; then
    homepage_users=",homepage:$ntfy_fixture_homepage_hash:user"
    homepage_access=',homepage:critical:ro'
    homepage_tokens=",homepage:$ntfy_fixture_homepage_token"
    n8n_users=",n8n:$ntfy_fixture_n8n_hash:user"
    n8n_access=',n8n:homelab:wo'
    n8n_tokens=",n8n:$ntfy_fixture_n8n_token"
  elif [[ "$2" == 'pre-n8n' ]]; then
    homepage_users=",homepage:$ntfy_fixture_homepage_hash:user"
    homepage_access=',homepage:critical:ro'
    homepage_tokens=",homepage:$ntfy_fixture_homepage_token"
  fi
  cat >"$1" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ntfy-secret
  namespace: ntfy
type: Opaque
stringData:
  NTFY_AUTH_USERS: "subscriber:$ntfy_fixture_sub_hash:user,alertmanager:$ntfy_fixture_am_hash:user,seerr:$ntfy_fixture_seerr_hash:user,automation:$ntfy_fixture_automation_hash:user$homepage_users$n8n_users"
  NTFY_AUTH_ACCESS: "subscriber:critical:ro,subscriber:homelab:ro,subscriber:media:ro,alertmanager:critical:wo,alertmanager:homelab:wo,seerr:media:wo,automation:homelab:wo$homepage_access$n8n_access"
  NTFY_AUTH_TOKENS: "alertmanager:$ntfy_fixture_am_token,seerr:$ntfy_fixture_seerr_token,automation:$ntfy_fixture_automation_token$homepage_tokens$n8n_tokens"
EOF
}

# "Encrypt" a plaintext Secret fixture through the stub semantics (base64 stringData +
# sops block), so tests can seed state without running the script first.
ntfy_stub_encrypt() { # <plain-file> <out-file> <policy-file>
  RECIPIENT="$(yq -r '.creation_rules[1].age' "$3")" yq \
    '.stringData |= with_entries(.value |= @base64) |
     .sops.age = [{"recipient": strenv(RECIPIENT)}]' \
    "$1" >"$2"
}

ntfy_write_values_fixture() { # <ntfy-values> <adapter-values> <homepage-deployment>
  cat >"$1" <<'EOF'
controllers:
  ntfy:
    pod:
      annotations:
        sops-hash: "outdated"
EOF
  cat >"$2" <<'EOF'
controllers:
  alertmanager-ntfy:
    pod:
      annotations:
        sops-hash: "outdated"
EOF
  cat >"$3" <<'EOF'
spec:
  template:
    metadata:
      annotations: {}
EOF
}

# Stub sops binary honoring the script's three call shapes. STUB_SOPS_PASSTHROUGH=1
# simulates a broken encryption that leaks plaintext (the scripts must refuse).
ntfy_write_stub_sops() { # <bin-dir>
  cat >"$1/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
policy="${NTFY_SOPS_POLICY_FILE:-.sops.yaml}"
case "${1:-}" in
  --decrypt)
    yq -e '.sops' "$2" >/dev/null 2>&1 || { echo "stub sops: $2 is not encrypted" >&2; exit 1; }
    yq 'del(.sops) | .stringData |= with_entries(.value |= @base64d)' "$2"
    ;;
  --encrypt)
    # --encrypt --filename-override <target> <input>
    if [[ "${STUB_SOPS_PASSTHROUGH:-}" == '1' ]]; then
      RECIPIENT="$(yq -r '.creation_rules[1].age' "$policy")" \
        yq '.sops.age = [{"recipient": strenv(RECIPIENT)}]' "$4"
    else
      RECIPIENT="$(yq -r '.creation_rules[1].age' "$policy")" \
        yq '.stringData |= with_entries(.value |= @base64) |
            .sops.age = [{"recipient": strenv(RECIPIENT)}]' "$4"
    fi
    ;;
  filestatus)
    if yq -e '.sops' "$2" >/dev/null 2>&1; then
      yq -n '.encrypted = true'
    else
      yq -n '.encrypted = false'
    fi
    ;;
  *)
    echo "stub sops: unsupported call $*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$1/sops"
}

# Decrypt a fixture Secret through the stub semantics and print one stringData key.
ntfy_secret_key() { # <encrypted-file> <key>
  yq -r ".stringData[\"$2\"] | @base64d" "$1"
}
