set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]

talosconfig := "../.talos/config"
kubeconfig := "../.kube/config"

# Validate the trackable Talhelper inputs without decrypting cluster identity.
source-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    talhelper validate talconfig talconfig.yaml
    [[ "$(sops filestatus talsecret.sops.yaml | yq -r '.encrypted')" == "true" ]]
    [[ "$(yq -r '.sops.age[0].recipient' talsecret.sops.yaml)" == "$(yq -r '.creation_rules[0].age' ../.sops.yaml)" ]]
    [[ "$(yq -r '.sops.encrypted_regex' talsecret.sops.yaml)" == '^(.*)$' ]]
    expected_extensions=$'siderolabs/intel-ucode\nsiderolabs/i915\nsiderolabs/iscsi-tools\nsiderolabs/util-linux-tools'
    actual_extensions="$(yq -r '.controlPlane.schematic.customization.systemExtensions.officialExtensions[]' talconfig.yaml)"
    [[ "$actual_extensions" == "$expected_extensions" ]]

# Decrypt the tracked identity in memory and render ignored machine configs.
generate: source-validate
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077

    talosconfig='{{talosconfig}}'
    generated_talosconfig='../clusterconfig/talosconfig'
    expected_endpoints=$'192.168.90.10\n192.168.90.11\n192.168.90.12'

    just repo secrets
    rm -rf ../clusterconfig
    talhelper genconfig \
      --config-file talconfig.yaml \
      --secret-file talsecret.sops.yaml \
      --out-dir ../clusterconfig \
      --no-gitignore

    actual_endpoints="$(yq -r '.context as $context | .contexts[$context].endpoints[]' "$generated_talosconfig" | sort)"
    [[ "$actual_endpoints" == "$expected_endpoints" ]] || {
      echo 'Refusing generated talosconfig: expected exactly the three NUC endpoints.' >&2
      exit 1
    }

    talosconfig_dir="${talosconfig%/*}"
    install -d -m 700 "$talosconfig_dir"
    staged_talosconfig="$(mktemp "$talosconfig_dir/config.XXXXXX")"
    trap 'rm -f -- "$staged_talosconfig"' EXIT
    install -m 600 "$generated_talosconfig" "$staged_talosconfig"
    mv -f -- "$staged_talosconfig" "$talosconfig"
    trap - EXIT
    rm -- "$generated_talosconfig"

    just talos validate

# Validate rendered machine configs and the Phase 2 acceptance settings.
validate: source-validate
    #!/usr/bin/env bash
    set -euo pipefail
    talosconfig='{{talosconfig}}'
    expected_files=$'../clusterconfig/nuc1.yaml\n../clusterconfig/nuc2.yaml\n../clusterconfig/nuc3.yaml'
    actual_files="$(find ../clusterconfig -maxdepth 1 -type f | sort)"
    [[ "$actual_files" == "$expected_files" ]] || {
      echo "Render exactly nuc1.yaml, nuc2.yaml, and nuc3.yaml first." >&2
      exit 1
    }
    [[ -f "$talosconfig" ]] || {
      echo "Missing $talosconfig; run just talos generate first." >&2
      exit 1
    }
    expected_endpoints=$'192.168.90.10\n192.168.90.11\n192.168.90.12'
    actual_endpoints="$(yq -r '.context as $context | .contexts[$context].endpoints[]' "$talosconfig" | sort)"
    [[ "$actual_endpoints" == "$expected_endpoints" ]] || {
      echo 'Refusing talosconfig: expected exactly the three NUC endpoints.' >&2
      exit 1
    }

    expected_image='factory.talos.dev/metal-installer-secureboot/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79:v1.13.6'
    for node in nuc1 nuc2 nuc3; do
      file="../clusterconfig/${node}.yaml"
      talosctl validate --config "$file" --mode metal --strict

      [[ "$(yq -r 'select(has("machine")) | .version' "$file")" == 'v1alpha1' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.type' "$file")" == 'controlplane' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.install.disk' "$file")" == '/dev/nvme0n1' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.install.wipe' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.install.image' "$file")" == "$expected_image" ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.kubelet.image' "$file")" == 'ghcr.io/siderolabs/kubelet:v1.35.6' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.features.kubePrism.enabled' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.features.kubePrism.port' "$file")" == '7445' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.features.hostDNS.enabled' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .machine.features.hostDNS.forwardKubeDNSToHost' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .cluster.controlPlane.endpoint' "$file")" == 'https://192.168.90.20:6443' ]]
      [[ "$(yq -r 'select(has("machine")) | .cluster.proxy.disabled' "$file")" == 'true' ]]
      [[ "$(yq -r 'select(has("machine")) | .cluster.allowSchedulingOnControlPlanes' "$file")" == 'true' ]]

      [[ "$(yq ea -r 'select(.kind == "HostnameConfig") | .hostname' "$file")" == "$node" ]]
      [[ "$(yq ea -r 'select(.kind == "DHCPv4Config") | .name' "$file")" == 'enp88s0' ]]
      [[ "$(yq ea -r 'select(.kind == "Layer2VIPConfig") | [.name, .link] | join(" ")' "$file")" == '192.168.90.20 enp88s0' ]]
      [[ -z "$(yq ea -r 'select(.kind == "KubeFlannelCNIConfig") | .kind' "$file")" ]]

      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "STATE") | .encryption.provider' "$file")" == 'luks2' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "STATE") | .encryption.keys[0].slot' "$file")" == '0' ]]
      [[ "$(yq ea -o=json -I=0 'select(.kind == "VolumeConfig") | select(.name == "STATE") | .encryption.keys[0].tpm.options.pcrs' "$file")" == '[7]' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "STATE") | .encryption.keys[0].tpm.checkSecurebootStatusOnEnroll' "$file")" == 'true' ]]

      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .provisioning.maxSize' "$file")" == '150GiB' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.provider' "$file")" == 'luks2' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.keys[0].slot' "$file")" == '0' ]]
      [[ "$(yq ea -o=json -I=0 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.keys[0].tpm.options.pcrs' "$file")" == '[7]' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.keys[0].tpm.checkSecurebootStatusOnEnroll' "$file")" == 'true' ]]
      [[ "$(yq ea -r 'select(.kind == "VolumeConfig") | select(.name == "EPHEMERAL") | .encryption.keys[0].lockToState' "$file")" == 'true' ]]

      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .provisioning.diskSelector.match' "$file")" == 'system_disk' ]]
      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .provisioning.maxSize' "$file")" == '500GiB' ]]
      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .provisioning.grow' "$file")" == 'null' ]]
      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .filesystem.type' "$file")" == 'xfs' ]]
      [[ "$(yq ea -r 'select(.kind == "UserVolumeConfig") | select(.name == "longhorn") | .encryption' "$file")" == 'null' ]]
    done

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    for node in nuc1 nuc2 nuc3; do
      cp "../clusterconfig/${node}.yaml" "$tmpdir/${node}.yaml"
      yq ea -i '(. | select(.kind == "HostnameConfig") | .hostname) = "NODE"' "$tmpdir/${node}.yaml"
    done
    unique_hashes="$(for file in "$tmpdir"/*.yaml; do shasum -a 256 "$file" | awk '{print $1}'; done | sort -u | wc -l | tr -d ' ')"
    [[ "$unique_hashes" == '1' ]] || {
      echo "Rendered node configs differ in more than their hostname documents." >&2
      exit 1
    }
    echo "All Phase 2 rendered Talos configs passed validation."

# Apply one generated machine config from maintenance mode after checking the
# live node, Secure Boot state, target NVMe identity, and explicit confirmation.
apply node: validate
    #!/usr/bin/env bash
    set -euo pipefail

    node='{{node}}'
    case "$node" in
      nuc1) node_ip='192.168.90.10' ;;
      nuc2) node_ip='192.168.90.11' ;;
      nuc3) node_ip='192.168.90.12' ;;
      *)
        echo "Node must be one of: nuc1, nuc2, nuc3." >&2
        exit 1
        ;;
    esac

    config="../clusterconfig/${node}.yaml"
    target_disk='/dev/nvme0n1'
    expected_model='Samsung SSD 990 PRO 1TB'
    expected_size='1000204886016'

    [[ "$(yq -r 'select(has("machine")) | .machine.install.disk' "$config")" == "$target_disk" ]]
    [[ "$(yq -r 'select(has("machine")) | .machine.install.wipe' "$config")" == 'true' ]]
    [[ "$(yq ea -r 'select(.kind == "HostnameConfig") | .hostname' "$config")" == "$node" ]]

    security_state="$(talosctl get securitystate \
      --nodes "$node_ip" \
      --endpoints "$node_ip" \
      --insecure \
      --output yaml)"
    [[ "$(yq ea -r 'select(.metadata.id == "securitystate") | .spec.secureBoot' - <<<"$security_state")" == 'true' ]] || {
      echo "Refusing to apply: Secure Boot is not reported as enabled on $node." >&2
      exit 1
    }

    disk_state="$(talosctl get disks \
      --nodes "$node_ip" \
      --endpoints "$node_ip" \
      --insecure \
      --output yaml)"
    disk_model="$(yq ea -r 'select(.spec.dev_path == "/dev/nvme0n1") | .spec.model' - <<<"$disk_state")"
    disk_serial="$(yq ea -r 'select(.spec.dev_path == "/dev/nvme0n1") | .spec.serial' - <<<"$disk_state")"
    disk_size="$(yq ea -r 'select(.spec.dev_path == "/dev/nvme0n1") | .spec.size' - <<<"$disk_state")"
    disk_transport="$(yq ea -r 'select(.spec.dev_path == "/dev/nvme0n1") | .spec.transport' - <<<"$disk_state")"
    disk_readonly="$(yq ea -r 'select(.spec.dev_path == "/dev/nvme0n1") | .spec.readonly' - <<<"$disk_state")"
    unexpected_internal="$(yq ea -r 'select(.spec.bus_path != "/virtual" and .spec.transport != "usb" and .spec.dev_path != "/dev/nvme0n1") | .spec.dev_path' - <<<"$disk_state")"
    usb_boot="$(yq ea -r 'select(.spec.transport == "usb") | .spec.dev_path' - <<<"$disk_state")"

    [[ "$disk_model" == "$expected_model" ]] || {
      echo "Refusing to apply: expected $expected_model, found $disk_model." >&2
      exit 1
    }
    [[ -n "$disk_serial" && "$disk_serial" != 'null' ]]
    [[ "$disk_size" == "$expected_size" ]] || {
      echo "Refusing to apply: expected $expected_size bytes, found $disk_size." >&2
      exit 1
    }
    [[ "$disk_transport" == 'nvme' ]]
    [[ "$disk_readonly" == 'false' ]]
    [[ -z "$unexpected_internal" ]] || {
      echo "Refusing to apply: unexpected internal disk(s): $unexpected_internal" >&2
      exit 1
    }
    [[ -n "$usb_boot" ]] || {
      echo "Refusing to apply: no USB boot device is visible." >&2
      exit 1
    }

    if ! talosctl apply-config \
      --nodes "$node_ip" \
      --endpoints "$node_ip" \
      --insecure \
      --file "$config" \
      --dry-run >/dev/null 2>&1; then
      echo "Refusing to apply: Talos rejected the machine-config dry run." >&2
      exit 1
    fi

    expected_confirmation="${node}:${target_disk}:${disk_serial}"
    [[ "${TALOS_APPLY_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing to wipe $target_disk." >&2
      echo "Set TALOS_APPLY_CONFIRM='$expected_confirmation' and rerun after reviewing the live checks." >&2
      exit 1
    }

    echo "Applying $config to $node ($node_ip); Talos will wipe $target_disk and reboot."
    talosctl apply-config \
      --nodes "$node_ip" \
      --endpoints "$node_ip" \
      --insecure \
      --file "$config"

# Apply a machine-config change to an already-running node over the secure API in
# no-reboot mode, guarded by a dry run and explicit confirmation. Never wipes.
apply-live node: validate
    #!/usr/bin/env bash
    set -euo pipefail

    node='{{node}}'
    case "$node" in
      nuc1) node_ip='192.168.90.10' ;;
      nuc2) node_ip='192.168.90.11' ;;
      nuc3) node_ip='192.168.90.12' ;;
      *)
        echo "Node must be one of: nuc1, nuc2, nuc3." >&2
        exit 1
        ;;
    esac

    talosconfig='{{talosconfig}}'
    config="../clusterconfig/${node}.yaml"
    [[ -f "$talosconfig" ]] || {
      echo "Missing $talosconfig; run just talos generate first." >&2
      exit 1
    }
    [[ -f "$config" ]] || {
      echo "Missing $config; run just talos generate first." >&2
      exit 1
    }

    # Confirm the target is the intended running node via its secure API; this
    # recipe never uses --insecure, so it refuses a node that is not bootstrapped.
    hostname_state="$(talosctl get hostname \
      --nodes "$node_ip" \
      --endpoints "$node_ip" \
      --talosconfig "$talosconfig" \
      --output yaml)"
    [[ "$(yq -r '.spec.hostname' - <<<"$hostname_state")" == "$node" ]] || {
      echo "Refusing apply-live: $node_ip does not report hostname $node over the secure API." >&2
      exit 1
    }

    # Dry run in no-reboot mode: this validates acceptance, prints the diff, and
    # fails if the change would require a reboot (use a rolling procedure for those).
    if ! dry_run_output="$(talosctl apply-config \
      --nodes "$node_ip" \
      --endpoints "$node_ip" \
      --talosconfig "$talosconfig" \
      --file "$config" \
      --mode=no-reboot \
      --dry-run 2>&1)"; then
      echo "Refusing apply-live: Talos rejected the no-reboot dry run for $node." >&2
      echo 'A change that needs a reboot must be applied one node at a time with health checks, not apply-live.' >&2
      printf '%s\n' "$dry_run_output" >&2
      exit 1
    fi
    printf '%s\n' "$dry_run_output"

    expected_confirmation="apply-live:${node}:${node_ip}:no-reboot"
    [[ "${TALOS_APPLY_LIVE_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing to apply the machine config to running $node." >&2
      echo "Set TALOS_APPLY_LIVE_CONFIRM='$expected_confirmation' and rerun after reviewing the dry-run diff." >&2
      exit 1
    }

    echo "Applying $config to running $node ($node_ip) in no-reboot mode."
    talosctl apply-config \
      --nodes "$node_ip" \
      --endpoints "$node_ip" \
      --talosconfig "$talosconfig" \
      --file "$config" \
      --mode=no-reboot

# Read-only checkpoint: report and verify the longhorn user volume and the
# TPM-encrypted STATE/EPHEMERAL volumes on every node. No mutation, no confirmation.
volume-status:
    #!/usr/bin/env bash
    set -euo pipefail
    just repo require-bash

    talosconfig='{{talosconfig}}'
    [[ -f "$talosconfig" ]] || {
      echo "Missing $talosconfig; run just talos generate." >&2
      exit 1
    }

    status=0
    for spec in 'nuc1:192.168.90.10' 'nuc2:192.168.90.11' 'nuc3:192.168.90.12'; do
      node="${spec%%:*}"
      ip="${spec#*:}"
      common=(--talosconfig "$talosconfig" --nodes "$ip" --endpoints "$ip" --output yaml)

      if ! vol="$(talosctl get volumestatuses "${common[@]}" 2>/dev/null)"; then
        echo "  $node: talos API unreachable" >&2
        status=1
        continue
      fi
      mnt="$(talosctl get mountstatuses.block.talos.dev "${common[@]}" 2>/dev/null || true)"

      lh_phase="$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.phase' - <<<"$vol")"
      lh_size="$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.prettySize' - <<<"$vol")"
      lh_enc="$(yq ea -r 'select(.metadata.id == "u-longhorn") | (.spec.encryptionProvider // "none")' - <<<"$vol")"
      lh_target="$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.target' - <<<"$mnt")"
      lh_fs="$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.filesystem' - <<<"$mnt")"
      lh_detached="$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.detached' - <<<"$mnt")"
      state="$(yq ea -r 'select(.metadata.id == "STATE") | [.spec.phase, .spec.encryptionProvider] | join(" ")' - <<<"$vol")"
      ephemeral="$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | [.spec.phase, .spec.encryptionProvider] | join(" ")' - <<<"$vol")"

      printf '  %-5s u-longhorn: %s %s enc=%s mount=%s fs=%s detached=%s | STATE: %s | EPHEMERAL: %s\n' \
        "$node" "${lh_phase:-none}" "${lh_size:-?}" "$lh_enc" "${lh_target:-none}" "${lh_fs:-none}" "${lh_detached:-?}" "$state" "$ephemeral"

      [[ "$lh_phase" == 'ready' && "$lh_target" == '/var/mnt/longhorn' && "$lh_fs" == 'xfs' && "$lh_detached" == 'false' && "$lh_enc" == 'none' ]] || {
        echo "    ^ $node longhorn volume is not healthy (want ready, mounted at /var/mnt/longhorn, xfs, attached, unencrypted)." >&2
        status=1
      }
      [[ "$state" == 'ready luks2' ]] || { echo "    ^ $node STATE volume is not ready+luks2." >&2; status=1; }
      [[ "$ephemeral" == 'ready luks2' ]] || { echo "    ^ $node EPHEMERAL volume is not ready+luks2." >&2; status=1; }
    done

    [[ "$status" == '0' ]] || {
      echo 'One or more node volumes are unhealthy.' >&2
      exit 1
    }
    echo 'All node volumes healthy: longhorn ready and mounted at /var/mnt/longhorn (xfs, unencrypted); STATE and EPHEMERAL ready and luks2.'

# Asks Talos for the admin kubeconfig over the machine API using the talosconfig,
# with no etcd/NotReady gate; the day-two replacement for `just bootstrap verify`
# once Cilium is installed and the nodes are Ready. Requires `just talos generate`.
# Fetch the ignored workstation kubeconfig from Talos into repo-local .kube/config.
kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    just repo require-bash

    talosconfig='{{talosconfig}}'
    kubeconfig='{{kubeconfig}}'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    [[ -f "$talosconfig" ]] || {
      echo "Missing $talosconfig." >&2
      echo 'Load the repository SOPS identity and run just talos generate, or install a trusted existing talosconfig at that path with mode 0600.' >&2
      exit 1
    }

    kubeconfig_dir="${kubeconfig%/*}"
    install -d -m 700 "$kubeconfig_dir"
    staged_kubeconfig="$(mktemp "$kubeconfig_dir/config.XXXXXX")"
    trap 'rm -f -- "$staged_kubeconfig"' EXIT

    talosctl kubeconfig "$staged_kubeconfig" \
      --nodes 192.168.90.10 \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig" \
      --merge=false \
      --force >/dev/null
    chmod 600 "$staged_kubeconfig"

    api_server="$(kubectl --kubeconfig "$staged_kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
    [[ "$api_server" == 'https://192.168.90.20:6443' ]] || {
      echo "Refusing kubeconfig: server $api_server is not the expected API VIP https://192.168.90.20:6443." >&2
      exit 1
    }

    mv -f -- "$staged_kubeconfig" "$kubeconfig"
    trap - EXIT
    echo "Wrote $kubeconfig targeting $api_server."
