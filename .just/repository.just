set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

# Install the exact tool versions and verify their presence.
tools:
    mise install --locked
    mise exec -- just repo versions

# Print the tool versions used by this repository.
versions:
    @bash --version | head -n 1
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
    @shellcheck --version
    @uv --version
    @sonobuoy version

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
    if [[ -f "$target" ]] && cmp -s "$target" "$temp_dir/pihole-ca.crt"; then
      echo "Tracked Pi-hole CA already matches p1 at SHA256=$new_fingerprint."
      exit 0
    fi
    if [[ -f "$target" ]]; then
      old_fingerprint="$(openssl x509 -in "$target" -noout -fingerprint -sha256 | cut -d= -f2)"
      echo "Replacing tracked Pi-hole CA SHA256=$old_fingerprint with SHA256=$new_fingerprint."
    else
      echo "Installing tracked Pi-hole CA SHA256=$new_fingerprint."
    fi
    install -m 0644 "$temp_dir/pihole-ca.crt" "$target"
    echo 'Review the certificate diff and fingerprint before committing the trust-anchor rotation.'

# Validate Phase 7 provider credentials and write only SOPS-encrypted Secret manifests.
phase7-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:phase7:cloudflare-and-pihole:sops'
    cloudflare_target='kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml'
    pihole_target='kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml'
    pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    pihole_api='https://pi.hole'
    temp_dir="$(mktemp -d /tmp/homelab-talos-phase7-secrets.XXXXXX)"
    pihole_sid=''
    pihole_record_cleanup_needed=false
    pihole_test_hostname="phase7-preflight-$$-${RANDOM}.lab.supermorphic.com"
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
    [[ "${PHASE7_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Phase 7 encrypted Secret manifests.' >&2
      echo "Set PHASE7_SECRETS_CONFIRM='$expected_confirmation' after reviewing both targets." >&2
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

    mv -- "$temp_dir/cloudflare.sops.yaml" "$cloudflare_target"
    mv -- "$temp_dir/pihole.sops.yaml" "$pihole_target"
    echo 'Phase 7 provider credentials passed Cloudflare validation and a trusted-HTTPS Pi-hole create/delete proof; only SOPS ciphertext was written.'

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

    mv -- "$temp_dir/protonvpn.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (protonvpn in media). Control-server apikey is embedded in the encrypted config.toml."

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

    mv -- "$temp_dir/homepage-portainer.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-portainer in homepage)."

# Add or rotate the dedicated Homepage identity in the existing ntfy auth Secret and
# write the matching Homepage widget Secret. Generates the throwaway password, bcrypt
# hash, and token internally; no credential inputs are accepted or printed. Existing
# subscribers and producers are preserved. Both encrypted outputs are prepared before
# either tracked file is replaced.
homepage-ntfy-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:ntfy-homepage:sops'
    ntfy_target='kubernetes/apps/monitoring/ntfy/app/secret.sops.yaml'
    homepage_target='kubernetes/apps/monitoring/homepage/app/homepage-ntfy.sops.yaml'
    values='kubernetes/apps/monitoring/ntfy/app/values.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-ntfy.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -f "$ntfy_target" ]] || {
      echo "Missing $ntfy_target; use just repo ntfy-secrets for initial bootstrap." >&2
      exit 1
    }
    [[ "${HOMEPAGE_NTFY_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to update the ntfy auth and Homepage widget Secrets.' >&2
      echo "Set HOMEPAGE_NTFY_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    entropy="$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
    [[ "$entropy" =~ ^[a-f0-9]{64}$ ]] || {
      echo 'Refusing: could not generate cryptographically random Homepage credentials.' >&2
      exit 1
    }
    homepage_password_hash_line="$(printf '%s\n' "$entropy" | htpasswd -niBC 10 homepage)"
    homepage_password_hash="${homepage_password_hash_line#*:}"
    homepage_token="tk_${entropy:0:29}"
    [[ "$homepage_password_hash" == '$2'*'$'* ]] || {
      echo 'Refusing: generated Homepage password hash is not bcrypt.' >&2
      exit 1
    }
    [[ "$homepage_token" =~ ^tk_[a-z0-9]{29}$ ]] || {
      echo 'Refusing: generated Homepage token has the wrong format.' >&2
      exit 1
    }

    sops --decrypt "$ntfy_target" >"$temp_dir/ntfy-secret.yaml"
    auth_users="$(yq -r '.stringData.NTFY_AUTH_USERS' "$temp_dir/ntfy-secret.yaml")"
    auth_access="$(yq -r '.stringData.NTFY_AUTH_ACCESS' "$temp_dir/ntfy-secret.yaml")"
    auth_tokens="$(yq -r '.stringData.NTFY_AUTH_TOKENS' "$temp_dir/ntfy-secret.yaml")"
    [[ -n "$auth_users" && "$auth_users" != 'null' &&
      -n "$auth_access" && "$auth_access" != 'null' &&
      -n "$auth_tokens" && "$auth_tokens" != 'null' ]] || {
      echo 'Refusing: the existing ntfy Secret does not contain all declarative auth lists.' >&2
      exit 1
    }

    update_entry() {
      local current="$1" prefix="$2" replacement="$3"
      CURRENT="$current" PREFIX="$prefix" REPLACEMENT="$replacement" yq -n -r \
        'strenv(CURRENT) | split(",") |
         map(select(test("^" + strenv(PREFIX)) | not)) +
         [strenv(REPLACEMENT)] | join(",")'
    }
    auth_users="$(update_entry "$auth_users" 'homepage:' \
      "homepage:${homepage_password_hash}:user")"
    auth_access="$(update_entry "$auth_access" 'homepage:' 'homepage:critical:ro')"
    auth_tokens="$(update_entry "$auth_tokens" 'homepage:' \
      "homepage:${homepage_token}")"
    export auth_users auth_access auth_tokens homepage_token

    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "ntfy-secret" |
       .metadata.namespace = "ntfy" |
       .type = "Opaque" |
       .stringData.NTFY_AUTH_USERS = strenv(auth_users) |
       .stringData.NTFY_AUTH_ACCESS = strenv(auth_access) |
       .stringData.NTFY_AUTH_TOKENS = strenv(auth_tokens)' \
      >"$temp_dir/ntfy-secret.updated.yaml"

    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-ntfy" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData.token = strenv(homepage_token)' \
      >"$temp_dir/homepage-ntfy.yaml"

    sops --encrypt --filename-override "$ntfy_target" \
      "$temp_dir/ntfy-secret.updated.yaml" >"$temp_dir/ntfy-secret.sops.yaml"
    sops --encrypt --filename-override "$homepage_target" \
      "$temp_dir/homepage-ntfy.yaml" >"$temp_dir/homepage-ntfy.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/ntfy-secret.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(sops filestatus "$temp_dir/homepage-ntfy.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/ntfy-secret.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-ntfy.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    for secret in "$entropy" "$homepage_password_hash" "$homepage_token"; do
      ! rg -Fq -- "$secret" "$temp_dir/ntfy-secret.sops.yaml"
      ! rg -Fq -- "$secret" "$temp_dir/homepage-ntfy.sops.yaml"
    done

    mv -- "$temp_dir/ntfy-secret.sops.yaml" "$ntfy_target"
    mv -- "$temp_dir/homepage-ntfy.sops.yaml" "$homepage_target"
    revision="$(git hash-object "$ntfy_target")"
    REV="$revision" yq -i '.controllers.ntfy.pod.annotations.sops-hash = strenv(REV)' "$values"
    echo "Updated encrypted $ntfy_target and $homepage_target with generated Homepage read-only access; stamped sops-hash."

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

    mv -- "$temp_dir/qbit-manage-secret.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (qbit-manage-secret in media)."

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
# Devices/Core + Keys/Auth Keys + Services = write) — see docs/tailscale-operator.md.
# Never echoes the values.
tailscale-operator-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:networking:tailscale-operator:sops'
    target='kubernetes/apps/networking/tailscale-operator/app/oauth.sops.yaml'
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

    mv -- "$temp_dir/operator-oauth.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (operator-oauth in tailscale)."

# Write ONLY the SOPS-encrypted ntfy declarative-auth Secret (ntfy-secret in the ntfy
# namespace) from four bcrypt password hashes and three publisher tokens, and stamp the
# resulting ciphertext hash into values.yaml (pod annotation sops-hash) so a token
# rotation rolls the ntfy pod. Never echoes secret values. See docs/ntfy-startup-guide.md.
ntfy-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:ntfy:sops'
    target='kubernetes/apps/monitoring/ntfy/app/secret.sops.yaml'
    values='kubernetes/apps/monitoring/ntfy/app/values.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-ntfy-secrets.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    for var in NTFY_SUBSCRIBER_PASSWORD_HASH NTFY_ALERTMANAGER_PASSWORD_HASH \
      NTFY_SEERR_PASSWORD_HASH NTFY_AUTOMATION_PASSWORD_HASH \
      NTFY_ALERTMANAGER_TOKEN NTFY_SEERR_TOKEN NTFY_AUTOMATION_TOKEN; do
      [[ -n "${!var:-}" ]] || { echo "Set $var (see docs/ntfy-startup-guide.md)." >&2; exit 1; }
    done
    for hash in "$NTFY_SUBSCRIBER_PASSWORD_HASH" "$NTFY_ALERTMANAGER_PASSWORD_HASH" \
      "$NTFY_SEERR_PASSWORD_HASH" "$NTFY_AUTOMATION_PASSWORD_HASH"; do
      [[ "$hash" == '$2'*'$'* ]] || { echo 'Refusing: password hashes must be bcrypt ($2a/$2b/$2y...).' >&2; exit 1; }
    done
    for token in "$NTFY_ALERTMANAGER_TOKEN" "$NTFY_SEERR_TOKEN" "$NTFY_AUTOMATION_TOKEN"; do
      [[ "$token" =~ ^tk_[a-z0-9]{29}$ ]] || { echo 'Refusing: tokens must be tk_ + 29 lowercase alphanumerics (32 chars total).' >&2; exit 1; }
    done
    [[ "${NTFY_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the ntfy Secret.' >&2
      echo "Set NTFY_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    # subscriber reads all topics (iPhone/web password, no token). Producers are write-only
    # on their topic and use distinct, independently rotatable tokens.
    NTFY_AUTH_USERS="subscriber:${NTFY_SUBSCRIBER_PASSWORD_HASH}:user,alertmanager:${NTFY_ALERTMANAGER_PASSWORD_HASH}:user,seerr:${NTFY_SEERR_PASSWORD_HASH}:user,automation:${NTFY_AUTOMATION_PASSWORD_HASH}:user"
    NTFY_AUTH_ACCESS="subscriber:critical:ro,subscriber:homelab:ro,subscriber:media:ro,alertmanager:critical:wo,alertmanager:homelab:wo,seerr:media:wo,automation:homelab:wo"
    NTFY_AUTH_TOKENS="alertmanager:${NTFY_ALERTMANAGER_TOKEN},seerr:${NTFY_SEERR_TOKEN},automation:${NTFY_AUTOMATION_TOKEN}"
    export NTFY_AUTH_USERS NTFY_AUTH_ACCESS NTFY_AUTH_TOKENS
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "ntfy-secret" |
       .metadata.namespace = "ntfy" |
       .type = "Opaque" |
       .stringData.NTFY_AUTH_USERS = strenv(NTFY_AUTH_USERS) |
       .stringData.NTFY_AUTH_ACCESS = strenv(NTFY_AUTH_ACCESS) |
       .stringData.NTFY_AUTH_TOKENS = strenv(NTFY_AUTH_TOKENS)' \
      >"$temp_dir/ntfy-secret.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/ntfy-secret.yaml" >"$temp_dir/ntfy-secret.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/ntfy-secret.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/ntfy-secret.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    for secret in "$NTFY_SUBSCRIBER_PASSWORD_HASH" "$NTFY_ALERTMANAGER_PASSWORD_HASH" \
      "$NTFY_SEERR_PASSWORD_HASH" "$NTFY_AUTOMATION_PASSWORD_HASH" \
      "$NTFY_ALERTMANAGER_TOKEN" "$NTFY_SEERR_TOKEN" "$NTFY_AUTOMATION_TOKEN"; do
      if rg -Fq -- "$secret" "$temp_dir/ntfy-secret.sops.yaml"; then
        echo 'Refusing: a plaintext secret value appears in the encrypted output.' >&2
        exit 1
      fi
    done

    mv -- "$temp_dir/ntfy-secret.sops.yaml" "$target"
    # Stamp the ciphertext hash so a rotation rolls the ntfy pod (sops-hash).
    revision="$(git hash-object "$target")"
    REV="$revision" yq -i '.controllers.ntfy.pod.annotations.sops-hash = strenv(REV)' "$values"
    echo "Wrote SOPS-encrypted $target (ntfy-secret in ntfy) and stamped sops-hash in values.yaml."

# Write ONLY the SOPS-encrypted alertmanager-ntfy adapter auth Secret (alertmanager-ntfy-auth
# in the ntfy namespace) from NTFY_ALERTMANAGER_TOKEN, and stamp the ciphertext hash into
# the adapter values.yaml (sops-hash) so a rotation rolls the adapter pod. This is the same
# ntfy 'alertmanager' publisher token as in ntfy-secret's NTFY_AUTH_TOKENS (one logical
# credential, two namespace-local Secrets); rotate it in BOTH just repo ntfy-secrets and
# here. Never echoes the value.
alertmanager-ntfy-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:alertmanager-ntfy:sops'
    target='kubernetes/apps/monitoring/alertmanager-ntfy/app/auth.sops.yaml'
    values='kubernetes/apps/monitoring/alertmanager-ntfy/app/values.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-alertmanager-ntfy.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${NTFY_ALERTMANAGER_TOKEN:-}" ]] || {
      echo 'Set NTFY_ALERTMANAGER_TOKEN to the ntfy alertmanager publisher token (the same one in ntfy-secret).' >&2
      exit 1
    }
    [[ "${NTFY_ALERTMANAGER_TOKEN}" =~ ^tk_[a-z0-9]{29}$ ]] || {
      echo 'Refusing: NTFY_ALERTMANAGER_TOKEN must be tk_ + 29 lowercase alphanumerics (32 chars total).' >&2
      exit 1
    }
    [[ "${ALERTMANAGER_NTFY_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the alertmanager-ntfy auth Secret.' >&2
      echo "Set ALERTMANAGER_NTFY_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    # Build the adapter's auth.yml (ntfy.auth.token) as a YAML string, then embed it as
    # the Secret's auth.yml key. Built with yq to avoid a multiline literal in the recipe.
    export NTFY_ALERTMANAGER_TOKEN
    AUTH_YML="$(yq -n '.ntfy.auth.token = strenv(NTFY_ALERTMANAGER_TOKEN)')"
    export AUTH_YML
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "alertmanager-ntfy-auth" |
       .metadata.namespace = "ntfy" |
       .type = "Opaque" |
       .stringData["auth.yml"] = strenv(AUTH_YML)' \
      >"$temp_dir/auth.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/auth.yaml" >"$temp_dir/auth.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/auth.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/auth.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    if rg -Fq -- "$NTFY_ALERTMANAGER_TOKEN" "$temp_dir/auth.sops.yaml"; then
      echo 'Refusing: the plaintext token appears in the encrypted output.' >&2
      exit 1
    fi

    mv -- "$temp_dir/auth.sops.yaml" "$target"
    revision="$(git hash-object "$target")"
    REV="$revision" yq -i '.controllers["alertmanager-ntfy"].pod.annotations["sops-hash"] = strenv(REV)' "$values"
    echo "Wrote SOPS-encrypted $target (alertmanager-ntfy-auth in ntfy) and stamped sops-hash in values.yaml."

# Decrypt ntfy-secret and print ONLY the requested producer's publisher token, for pasting
# into a producer's UI (e.g. Seerr's ntfy agent). Deliberately prints a secret to stdout;
# needs the age key and never writes to disk. Usage: just repo ntfy-token seerr
ntfy-token user:
    #!/usr/bin/env bash
    set -euo pipefail

    just repo secrets
    case '{{user}}' in
      alertmanager|seerr|automation) ;;
      *) echo "Refusing: '{{user}}' is not a known ntfy producer (alertmanager|seerr|automation)." >&2; exit 1 ;;
    esac
    secret='kubernetes/apps/monitoring/ntfy/app/secret.sops.yaml'
    [[ -f "$secret" ]] || { echo "Missing $secret." >&2; exit 1; }
    tokens="$(sops --decrypt "$secret" | yq -r '.stringData.NTFY_AUTH_TOKENS')"
    token="$(awk -F, -v u='{{user}}' '{for(i=1;i<=NF;i++){split($i,a,":"); if(a[1]==u){print a[2]; exit}}}' <<<"$tokens")"
    [[ -n "$token" ]] || { echo "No token for '{{user}}' in ntfy-secret." >&2; exit 1; }
    printf '%s\n' "$token"

# Run repository and declarative Talos source validation.
verify: verify-files verify-shell-scripts
    just talos source-validate
    just repo secret-scan
    @echo "Repository and Phase 2 Talos source checks passed."

# Fail unless running under bash >= 5. macOS /bin/bash 3.2 does not honor set -e
# for a failed bare [[ ]] or (( )) mid-recipe, so validation assertions would
# silently not gate. Recipes use #!/usr/bin/env bash, so a bash >= 5 earlier in
# PATH (for example brew install bash) is what makes the guards effective.
# Install the git pre-commit hooks into .git/hooks (idempotent).
hooks:
    pre-commit install

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
verify-shell-scripts:
    @for script in scripts/validate/*.sh scripts/verify/*.sh; do test -x "$script"; done
    @for script in $(find scripts/validate scripts/verify scripts/test tests/probes -type f -name '*.sh' -print | LC_ALL=C sort); do \
      bash -n "$script"; \
      shellcheck --external-sources "$script"; \
    done
    @if rg -n 'shellcheck disable=SC2251' scripts/validate scripts/verify; then echo 'SC2251 suppressions can hide non-gating absence assertions.' >&2; exit 1; fi

# Verify ignore boundaries and SOPS policy.
verify-files: require-bash
    @bash --version | head -n 1
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
    @test "$(rg -c 'require_deployed_source ' .just/bootstrap.just kubernetes/mod.just | awk -F: '{sum += $2} END {print sum}')" -eq 23  # Update when adding/removing a guarded rollout recipe.
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

# Scan Git history and all currently trackable files without printing secrets.
secret-scan:
    #!/usr/bin/env bash
    set -euo pipefail
    if git ls-files --cached --others --exclude-standard -z \
      | xargs -0 rg -l 'AGE-SECRET-KEY-1[0-9A-Z]{20,}' >/dev/null 2>&1; then
      echo "An age private key exists in a trackable file." >&2
      exit 1
    fi
    gitleaks git --redact --no-banner .
    git diff --no-ext-diff HEAD | gitleaks stdin --redact --no-banner
    untracked="$(git ls-files --others --exclude-standard)"
    if [[ -n "$untracked" ]]; then
      while IFS= read -r file; do printf '\nFILE: %s\n' "$file"; cat "$file"; done <<< "$untracked" \
        | gitleaks stdin --redact --no-banner
    fi
