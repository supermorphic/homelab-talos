set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

talosconfig := ".talos/config"
kubeconfig := ".kube/config"

# Verify all Talos bootstrap prerequisites and refuse if etcd is already initialized.
preflight:
    #!/usr/bin/env bash
    set -euo pipefail

    talosconfig='{{talosconfig}}'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    expected_endpoints=$'192.168.90.10\n192.168.90.11\n192.168.90.12'
    actual_endpoints="$(yq -r '.context as $context | .contexts[$context].endpoints[]' "$talosconfig" | sort)"
    [[ "$actual_endpoints" == "$expected_endpoints" ]] || {
      echo "Refusing to bootstrap: talosconfig must contain exactly the three NUC endpoints." >&2
      exit 1
    }

    just talos validate

    for node_spec in 'nuc1:192.168.90.10' 'nuc2:192.168.90.11' 'nuc3:192.168.90.12'; do
      node="${node_spec%%:*}"
      node_ip="${node_spec#*:}"
      common=(--nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$talosconfig" --output yaml)

      talosctl version --nodes "$node_ip" --endpoints "$node_ip" --talosconfig "$talosconfig" >/dev/null

      hostname_state="$(talosctl get hostname "${common[@]}")"
      [[ "$(yq -r '.spec.hostname' - <<<"$hostname_state")" == "$node" ]]

      boot_state="$(talosctl get bootedentries "${common[@]}")"
      [[ "$(yq -r '.spec.bootedEntry' - <<<"$boot_state")" == 'talos-v1.13.6.efi' ]]

      security_state="$(talosctl get securitystate "${common[@]}")"
      [[ "$(yq -r '.spec.secureBoot' - <<<"$security_state")" == 'true' ]]
      [[ "$(yq -r '.spec.bootedWithUKI' - <<<"$security_state")" == 'true' ]]
      [[ "$(yq -r '.spec.moduleSignatureEnforced' - <<<"$security_state")" == 'true' ]]

      disk_state="$(talosctl get disks "${common[@]}")"
      [[ "$(yq ea -r 'select(.spec.dev_path == "/dev/nvme0n1") | .spec.model' - <<<"$disk_state")" == 'Samsung SSD 990 PRO 1TB' ]]
      [[ "$(yq ea -r 'select(.spec.dev_path == "/dev/nvme0n1") | .spec.size' - <<<"$disk_state")" == '1000204886016' ]]
      [[ -z "$(yq ea -r 'select(.spec.transport == "usb") | .spec.dev_path' - <<<"$disk_state")" ]]

      volume_state="$(talosctl get volumestatuses "${common[@]}")"
      [[ "$(yq ea -r 'select(.metadata.id == "STATE") | .spec.phase' - <<<"$volume_state")" == 'ready' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "STATE") | .spec.encryptionProvider' - <<<"$volume_state")" == 'luks2' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "STATE") | .spec.size' - <<<"$volume_state")" == '104857600' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | .spec.phase' - <<<"$volume_state")" == 'ready' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | .spec.encryptionProvider' - <<<"$volume_state")" == 'luks2' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | .spec.size' - <<<"$volume_state")" == '161061273600' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.phase' - <<<"$volume_state")" == 'ready' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.size' - <<<"$volume_state")" == '536870912000' ]]

      time_state="$(talosctl get timestatus "${common[@]}")"
      [[ "$(yq -r '.spec.synced' - <<<"$time_state")" == 'true' ]]

      mount_state="$(talosctl get mountstatuses.block.talos.dev "${common[@]}")"
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.target' - <<<"$mount_state")" == '/var/mnt/longhorn' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.filesystem' - <<<"$mount_state")" == 'xfs' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.detached' - <<<"$mount_state")" == 'false' ]]

      extension_state="$(talosctl get extensions "${common[@]}")"
      extension_names="$(yq ea -r '.spec.metadata.name' - <<<"$extension_state")"
      for extension in intel-ucode i915 iscsi-tools util-linux-tools; do
        rg -qx "$extension" <<<"$extension_names"
      done

      service_state="$(talosctl get services "${common[@]}")"
      for service in apid containerd cri kubelet machined; do
        [[ "$(yq ea -r 'select(.metadata.id == "'"$service"'") | .spec.running' - <<<"$service_state")" == 'true' ]]
        [[ "$(yq ea -r 'select(.metadata.id == "'"$service"'") | .spec.healthy' - <<<"$service_state")" == 'true' ]]
      done

      diagnostics="$(talosctl get diagnostics \
        --nodes "$node_ip" \
        --endpoints "$node_ip" \
        --talosconfig "$talosconfig" \
        --output json)"
      [[ -z "$diagnostics" ]] || {
        echo "Refusing to bootstrap: Talos diagnostics exist on $node." >&2
        exit 1
      }
    done

    existing_members="$(talosctl get etcdmembers \
      --nodes 192.168.90.10 \
      --endpoints 192.168.90.10 \
      --talosconfig "$talosconfig" \
      --output yaml)"
    if [[ -n "$existing_members" ]]; then
      echo 'Refusing to bootstrap: etcd member resources already exist.' >&2
      exit 1
    fi

    echo 'Talos bootstrap preflight passed on nuc1, nuc2, and nuc3; etcd is not initialized.'

# Bootstrap etcd exactly once on nuc1 after the full guarded preflight.
talos: preflight
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='bootstrap:nuc1:192.168.90.10'
    [[ "${TALOS_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to bootstrap etcd.' >&2
      echo "Set TALOS_BOOTSTRAP_CONFIRM='$expected_confirmation' and rerun after reviewing the preflight." >&2
      exit 1
    }

    echo 'Bootstrapping etcd exactly once on nuc1 (192.168.90.10).'
    talosctl bootstrap \
      --nodes 192.168.90.10 \
      --endpoints 192.168.90.10 \
      --talosconfig "{{talosconfig}}"

# Legacy bootstrap implementation retained privately until the cluster status extraction
# has completed migration validation.
[private]
_status node='all':
    #!/usr/bin/env bash
    set -euo pipefail

    talosconfig='{{talosconfig}}'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    requested_node='{{node}}'
    case "$requested_node" in
      all|nuc1|nuc2|nuc3) ;;
      *)
        echo 'Node must be one of: all, nuc1, nuc2, nuc3.' >&2
        exit 1
        ;;
    esac

    echo '=== etcd membership from nuc1 ==='
    talosctl etcd members \
      --nodes 192.168.90.10 \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig"

    for node_spec in 'nuc1:192.168.90.10' 'nuc2:192.168.90.11' 'nuc3:192.168.90.12'; do
      node="${node_spec%%:*}"
      node_ip="${node_spec#*:}"
      [[ "$requested_node" == 'all' || "$requested_node" == "$node" ]] || continue
      echo "=== $node etcd service ==="
      talosctl service etcd \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig"

      echo "=== $node cluster discovery ==="
      talosctl get members \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig"

      echo "=== $node recent etcd log ==="
      if ! talosctl logs etcd \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig" \
        --tail 80; then
        echo "$node etcd log is not available."
      fi
    done

# Retry one failed non-bootstrap etcd join after guarded live-state checks.
retry-join node:
    #!/usr/bin/env bash
    set -euo pipefail

    node='{{node}}'
    case "$node" in
      nuc2) node_ip='192.168.90.11' ;;
      nuc3) node_ip='192.168.90.12' ;;
      *)
        echo 'Join retry is allowed only for nuc2 or nuc3; never nuc1.' >&2
        exit 1
        ;;
    esac

    talosconfig='{{talosconfig}}'
    kubeconfig='{{kubeconfig}}'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    source scripts/lib/lease.sh
    source scripts/lib/node-lifecycle-state.sh
    [[ -f "$kubeconfig" ]] || {
      echo 'Refusing join retry: Kubernetes API coordination requires the operator kubeconfig.' >&2
      exit 1
    }
    lease_holder="bootstrap:retry-join:${node}:$$"
    lease_failure="$(mktemp "${TMPDIR:-/tmp}/homelab-retry-join-lease.XXXXXX")"
    rm -f -- "$lease_failure"
    lease_acquired=false
    cleanup_retry_join_lease() {
      local task_exit="$?"
      trap - EXIT INT TERM
      stop_test_lease_renewal
      if [[ "$lease_acquired" == 'true' ]]; then
        release_test_lease "$kubeconfig" "$lease_holder" >/dev/null 2>&1 || true
      fi
      rm -f -- "$lease_failure"
      exit "$task_exit"
    }
    trap cleanup_retry_join_lease EXIT INT TERM
    acquire_test_lease "$kubeconfig" "$lease_holder"
    lease_acquired=true
    start_test_lease_renewal "$kubeconfig" "$lease_holder" "$lease_failure"
    assert_no_active_lifecycle_records "$kubeconfig"

    member_table="$(talosctl etcd members \
      --nodes 192.168.90.10 \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    member_names="$(awk 'NR > 1 && NF {print $3}' <<<"$member_table")"
    if rg -qx "$node" <<<"$member_names"; then
      echo "Refusing join retry: $node is already an etcd member." >&2
      exit 1
    fi

    service_status="$(talosctl service etcd \
      --nodes "$node_ip" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    etcd_state="$(awk '$1 == "STATE" {print $2}' <<<"$service_status")"
    [[ "$etcd_state" == 'Failed' ]] || {
      echo "Refusing join retry: $node etcd state is $etcd_state, not Failed." >&2
      exit 1
    }

    discovery_state="$(talosctl get members \
      --nodes "$node_ip" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    discovery_names="$(awk 'NR > 1 && NF {print $4}' <<<"$discovery_state" | sort)"
    [[ "$discovery_names" == $'nuc1\nnuc2\nnuc3' ]] || {
      echo "Refusing join retry: $node does not discover exactly nuc1, nuc2, and nuc3." >&2
      exit 1
    }

    expected_confirmation="retry-etcd-reboot:${node}:${node_ip}"
    [[ "${TALOS_ETCD_RETRY_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing to reboot $node for the failed etcd join." >&2
      echo "Set TALOS_ETCD_RETRY_CONFIRM='$expected_confirmation' and rerun after reviewing status." >&2
      exit 1
    }

    echo "Rebooting only $node to rerun Talos' normal etcd join lifecycle."
    verify_test_lease_holder "$kubeconfig" "$lease_holder"
    assert_no_active_lifecycle_records "$kubeconfig"
    talosctl reboot \
      --nodes "$node_ip" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig" \
      --wait=false

    expected_names=$'nuc1\nnuc2\nnuc3'
    recovery_complete=false
    member_summary='<unavailable>'
    for attempt in {1..60}; do
      members=''
      member_names=''
      if members="$(talosctl etcd members \
        --nodes 192.168.90.10 \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig" 2>/dev/null)"; then
        member_names="$(awk 'NR > 1 && NF {print $3}' <<<"$members" | sort)"
        if [[ -n "$member_names" ]]; then
          member_summary="$(awk 'BEGIN {separator=""} NF {printf "%s%s", separator, $0; separator=","} END {print ""}' <<<"$member_names")"
        else
          member_summary='<none>'
        fi
      fi

      service_ready=false
      status_ready=false
      alarms_clear=false
      if [[ "$member_names" == "$expected_names" ]]; then
        service_status=''
        if service_status="$(talosctl service etcd \
          --nodes "$node_ip" \
          --endpoints "$nodes_csv" \
          --talosconfig "$talosconfig" 2>/dev/null)"; then
          etcd_state="$(awk '$1 == "STATE" {print $2}' <<<"$service_status")"
          etcd_health="$(awk '$1 == "HEALTH" {print $2}' <<<"$service_status")"
          if [[ "$etcd_state" == 'Running' && "$etcd_health" =~ ^(Healthy|OK)$ ]]; then
            service_ready=true
          fi
        fi

        etcd_status=''
        if etcd_status="$(talosctl etcd status \
          --nodes "$nodes_csv" \
          --endpoints "$nodes_csv" \
          --talosconfig "$talosconfig" 2>/dev/null)"; then
          status_rows="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$etcd_status")"
          member_ids="$(awk 'BEGIN {FS="[[:space:]][[:space:]]+"} NR > 1 && NF {print $2}' <<<"$etcd_status" | sort -u)"
          leader_ids="$(awk 'BEGIN {FS="[[:space:]][[:space:]]+"} NR > 1 && NF {print $5}' <<<"$etcd_status" | sort -u)"
          leader_count="$(awk 'NF {count++} END {print count + 0}' <<<"$leader_ids")"
          if [[ "$status_rows" == '3' && "$leader_count" == '1' ]] && rg -Fqx "$leader_ids" <<<"$member_ids"; then
            status_ready=true
          fi
        fi

        alarm_status=''
        if alarm_status="$(talosctl etcd alarm list \
          --nodes "$nodes_csv" \
          --endpoints "$nodes_csv" \
          --talosconfig "$talosconfig" 2>/dev/null)"; then
          alarm_rows="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$alarm_status")"
          if [[ "$alarm_rows" == '0' ]]; then
            alarms_clear=true
          fi
        fi
      fi

      if [[ "$service_ready" == 'true' && "$status_ready" == 'true' && "$alarms_clear" == 'true' ]]; then
        recovery_complete=true
        break
      fi
      sleep 5
    done

    [[ "$recovery_complete" == 'true' ]] || {
      echo "Join retry for $node did not reach verified healthy etcd membership; last observed members: $member_summary." >&2
      exit 1
    }
    [[ ! -f "$lease_failure" ]] || {
      echo 'Shared disruption Lease renewal failed during join retry.' >&2
      exit 1
    }
    verify_test_lease_holder "$kubeconfig" "$lease_holder"
    release_test_lease "$kubeconfig" "$lease_holder"
    lease_acquired=false
    rm -f -- "$lease_failure"
    trap - EXIT INT TERM
    echo "Verified $node joined the healthy three-member etcd cluster without alarms."

# Verify the bootstrapped pre-Cilium Talos cluster and refresh the ignored kubeconfig.
[private]
_verify-pre-cilium:
    #!/usr/bin/env bash
    set -euo pipefail

    talosconfig='{{talosconfig}}'
    kubeconfig='{{kubeconfig}}'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    expected_names=$'nuc1\nnuc2\nnuc3'
    expected_endpoints=$'192.168.90.10\n192.168.90.11\n192.168.90.12'
    actual_endpoints="$(yq -r '.context as $context | .contexts[$context].endpoints[]' "$talosconfig" | sort)"
    [[ "$actual_endpoints" == "$expected_endpoints" ]]

    members=''
    member_count=0
    for attempt in {1..60}; do
      if members="$(talosctl etcd members \
        --nodes 192.168.90.10 \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig" 2>/dev/null)"; then
        member_count="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$members")"
        [[ "$member_count" == '3' ]] && break
      fi
      sleep 5
    done
    [[ "$member_count" == '3' ]] || {
      echo "Expected three etcd members, found $member_count." >&2
      exit 1
    }
    member_names="$(awk 'NR > 1 && NF {print $3}' <<<"$members" | sort)"
    [[ "$member_names" == "$expected_names" ]]

    etcd_status="$(talosctl etcd status \
      --nodes "$nodes_csv" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    printf '%s\n' "$etcd_status"
    status_rows="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$etcd_status")"
    [[ "$status_rows" == '3' ]]
    member_ids="$(awk 'BEGIN {FS="[[:space:]][[:space:]]+"} NR > 1 {print $2}' <<<"$etcd_status" | sort -u)"
    leader_ids="$(awk 'BEGIN {FS="[[:space:]][[:space:]]+"} NR > 1 {print $5}' <<<"$etcd_status" | sort -u)"
    leader_count="$(awk 'NF {count++} END {print count + 0}' <<<"$leader_ids")"
    [[ "$leader_count" == '1' ]] && rg -qx "$leader_ids" <<<"$member_ids" || {
      echo 'Expected one elected leader ID belonging to the three etcd members.' >&2
      exit 1
    }

    alarm_status="$(talosctl etcd alarm list \
      --nodes "$nodes_csv" \
      --endpoints "$nodes_csv" \
      --talosconfig "$talosconfig")"
    printf '%s\n' "$alarm_status"
    alarm_rows="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$alarm_status")"
    [[ "$alarm_rows" == '0' ]] || {
      echo "Expected no etcd alarms, found $alarm_rows." >&2
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
    [[ "$api_server" == 'https://192.168.90.20:6443' ]]
    mv -f -- "$staged_kubeconfig" "$kubeconfig"
    trap - EXIT

    nodes_json=''
    node_count=0
    for attempt in {1..60}; do
      if nodes_json="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json 2>/dev/null)"; then
        node_count="$(yq -r '.items | length' - <<<"$nodes_json")"
        [[ "$node_count" == '3' ]] && break
      fi
      sleep 5
    done
    [[ "$node_count" == '3' ]]
    actual_names="$(yq -r '.items[].metadata.name' - <<<"$nodes_json" | sort)"
    [[ "$actual_names" == "$expected_names" ]]
    control_plane_count="$(yq -r '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/control-plane"))] | length' - <<<"$nodes_json")"
    [[ "$control_plane_count" == '3' ]]
    ready_states="$(yq -r '.items[].status.conditions[] | select(.type == "Ready") | .status' - <<<"$nodes_json" | sort)"
    [[ "$ready_states" == $'False\nFalse\nFalse' ]] || {
      echo 'Expected all Kubernetes nodes to remain NotReady before Cilium.' >&2
      exit 1
    }

    for node_spec in 'nuc1:192.168.90.10' 'nuc2:192.168.90.11' 'nuc3:192.168.90.12'; do
      node="${node_spec%%:*}"
      node_ip="${node_spec#*:}"
      common=(--nodes "$node_ip" --endpoints "$nodes_csv" --talosconfig "$talosconfig" --output yaml)

      hostname_state="$(talosctl get hostname "${common[@]}")"
      [[ "$(yq -r '.spec.hostname' - <<<"$hostname_state")" == "$node" ]]

      time_state="$(talosctl get timestatus "${common[@]}")"
      [[ "$(yq -r '.spec.synced' - <<<"$time_state")" == 'true' ]]

      security_state="$(talosctl get securitystate "${common[@]}")"
      [[ "$(yq -r '.spec.secureBoot' - <<<"$security_state")" == 'true' ]]
      [[ "$(yq -r '.spec.bootedWithUKI' - <<<"$security_state")" == 'true' ]]

      service_state="$(talosctl get services "${common[@]}")"
      for service in apid containerd cri etcd kubelet machined; do
        [[ "$(yq ea -r 'select(.metadata.id == "'"$service"'") | .spec.running' - <<<"$service_state")" == 'true' ]]
        [[ "$(yq ea -r 'select(.metadata.id == "'"$service"'") | .spec.healthy' - <<<"$service_state")" == 'true' ]]
      done

      volume_state="$(talosctl get volumestatuses "${common[@]}")"
      [[ "$(yq ea -r 'select(.metadata.id == "STATE") | [.spec.phase, .spec.encryptionProvider, .spec.size] | join(" ")' - <<<"$volume_state")" == 'ready luks2 104857600' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | [.spec.phase, .spec.encryptionProvider, .spec.size] | join(" ")' - <<<"$volume_state")" == 'ready luks2 161061273600' ]]
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | [.spec.phase, .spec.filesystem, .spec.size] | join(" ")' - <<<"$volume_state")" == 'ready xfs 536870912000' ]]

      mount_state="$(talosctl get mountstatuses.block.talos.dev "${common[@]}")"
      [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | [.spec.target, .spec.filesystem, .spec.readOnly, .spec.detached] | join(" ")' - <<<"$mount_state")" == '/var/mnt/longhorn xfs false false' ]]

      diagnostics="$(talosctl get diagnostics \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig "$talosconfig" \
        --output json)"
      [[ -z "$diagnostics" ]] || {
        echo "Talos diagnostics exist on $node." >&2
        exit 1
      }
    done

    echo 'Talos cluster verification passed: three-member etcd, one leader, no alarms, VIP API, and three expected NotReady nodes.'

# Install or reconcile Cilium from the canonical app-local values after guarded preflight.
cilium:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    values_file='kubernetes/apps/kube-system/cilium/app/values.yaml'
    chart='oci://quay.io/cilium/charts/cilium'
    version='1.19.6'
    expected_confirmation='bootstrap:cilium:1.19.6:kube-system'
    expected_names=$'nuc1\nnuc2\nnuc3'

    just kube cilium-validate
    just talos validate

    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }
    api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
    [[ "$api_server" == 'https://192.168.90.20:6443' ]] || {
      echo "Refusing Cilium bootstrap: kubeconfig targets $api_server." >&2
      exit 1
    }

    node_names="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json | yq -r '.items[].metadata.name' | sort)"
    [[ "$node_names" == "$expected_names" ]] || {
      echo 'Refusing Cilium bootstrap: expected exactly nuc1, nuc2, and nuc3.' >&2
      exit 1
    }

    ! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset kube-proxy >/dev/null 2>&1 || {
      echo 'Refusing Cilium bootstrap: kube-proxy exists.' >&2
      exit 1
    }

    competing_cni="$(kubectl --kubeconfig "$kubeconfig" get daemonsets --all-namespaces --output name | rg '(calico-node|kube-flannel|weave-net|canal|antrea-agent)' || true)"
    [[ -z "$competing_cni" ]] || {
      echo "Refusing Cilium bootstrap: a competing CNI exists: $competing_cni" >&2
      exit 1
    }

    if kubectl --kubeconfig "$kubeconfig" api-resources \
      --api-group helm.toolkit.fluxcd.io \
      --no-headers 2>/dev/null | rg -q '^helmreleases'; then
      flux_cilium="$(kubectl --kubeconfig "$kubeconfig" get helmreleases.helm.toolkit.fluxcd.io \
        --all-namespaces \
        --output custom-columns=NAME:.metadata.name \
        --no-headers 2>/dev/null | rg -x 'cilium' || true)"
      [[ -z "$flux_cilium" ]] || {
        echo 'Refusing bootstrap ownership: Flux already manages Cilium.' >&2
        exit 1
      }
    fi

    release_exists=false
    if helm status cilium --namespace kube-system --kubeconfig "$kubeconfig" >/dev/null 2>&1; then
      release_exists=true
      release_json="$(helm list --namespace kube-system --kubeconfig "$kubeconfig" --output json)"
      release_chart="$(yq -r '.[] | select(.name == "cilium") | .chart' - <<<"$release_json")"
      [[ "$release_chart" == 'cilium-1.19.6' ]] || {
        echo "Refusing Cilium bootstrap: existing release uses $release_chart." >&2
        exit 1
      }

      temp_dir="$(mktemp -d /tmp/homelab-talos-cilium-bootstrap.XXXXXX)"
      trap 'rm -rf -- "$temp_dir"' EXIT
      helm get values cilium \
        --namespace kube-system \
        --kubeconfig "$kubeconfig" \
        --output yaml >"$temp_dir/live-values.yaml"
      yq -o=json -I=0 'sort_keys(..)' "$values_file" >"$temp_dir/expected-values.json"
      yq -o=json -I=0 'sort_keys(..)' "$temp_dir/live-values.yaml" >"$temp_dir/normalized-live-values.json"
      if cmp -s "$temp_dir/expected-values.json" "$temp_dir/normalized-live-values.json"; then
        echo 'Cilium already matches the canonical chart and values; skipping Helm mutation.'
        just kube cilium-verify
        exit 0
      fi
    else
      unmanaged_cilium=''
      for resource in daemonset/cilium deployment/cilium-operator deployment/hubble-relay; do
        existing_resource="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get \
          "$resource" \
          --ignore-not-found \
          --output name)"
        if [[ -n "$existing_resource" ]]; then
          unmanaged_cilium+="${unmanaged_cilium:+ }$existing_resource"
        fi
      done
      [[ -z "$unmanaged_cilium" ]] || {
        echo "Refusing Cilium bootstrap: Cilium resources exist without the expected Helm release: $unmanaged_cilium" >&2
        exit 1
      }
      just bootstrap _verify-pre-cilium
    fi

    [[ "${CILIUM_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to install or reconcile Cilium.' >&2
      echo "Set CILIUM_BOOTSTRAP_CONFIRM='$expected_confirmation' and rerun after reviewing preflight." >&2
      exit 1
    }

    if [[ "$release_exists" == 'true' ]]; then
      echo 'Reconciling the existing bootstrap Cilium release from canonical values.'
    else
      echo 'Installing the bootstrap Cilium release from canonical values.'
    fi
    helm upgrade --install cilium "$chart" \
      --version "$version" \
      --namespace kube-system \
      --kubeconfig "$kubeconfig" \
      --values "$values_file" \
      --reset-values \
      --cleanup-on-fail \
      --rollback-on-failure \
      --wait=watcher \
      --wait-for-jobs \
      --timeout 10m \
      --history-max 5

    just kube cilium-verify
    CILIUM_CONNECTIVITY_CONFIRM='test:cilium-connectivity' just kube cilium-connectivity-test

# Bootstrap Flux 2.9.2 with a unique read-only GitHub SSH deploy key.
flux:
    #!/usr/bin/env bash
    set -euo pipefail

    owner='supermorphic'
    repository='homelab-talos'
    kubeconfig='{{kubeconfig}}'
    expected_confirmation="bootstrap:flux:prod:${owner}/${repository}:read-only"

    just kube flux-preflight
    [[ -n "${GITHUB_TOKEN:-}" ]] || {
      echo 'Set GITHUB_TOKEN to the temporary repository-scoped Flux bootstrap PAT.' >&2
      exit 1
    }
    [[ "${FLUX_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to bootstrap Flux or create a GitHub deploy key.' >&2
      echo "Set FLUX_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing the preflight." >&2
      exit 1
    }

    authenticated_user="$(GH_TOKEN="$GITHUB_TOKEN" gh api user --jq '.login')"
    [[ "$authenticated_user" == "$owner" ]] || {
      echo "The GitHub token belongs to $authenticated_user, not $owner." >&2
      exit 1
    }
    repository_state="$(GH_TOKEN="$GITHUB_TOKEN" gh api "repos/${owner}/${repository}")"
    [[ "$(yq -r '.full_name' - <<<"$repository_state")" == "${owner}/${repository}" ]]
    [[ "$(yq -r '.private' - <<<"$repository_state")" == 'true' ]] || {
      echo 'Refusing Flux bootstrap: the GitHub repository is not private.' >&2
      exit 1
    }
    [[ "$(yq -r '.permissions.admin and .permissions.push' - <<<"$repository_state")" == 'true' ]] || {
      echo 'The bootstrap PAT needs repository Administration and Contents write access.' >&2
      exit 1
    }

    flux bootstrap github \
      --kubeconfig "$kubeconfig" \
      --owner "$owner" \
      --repository "$repository" \
      --personal \
      --private=true \
      --reconcile \
      --branch main \
      --path kubernetes/flux/clusters/prod \
      --read-write-key=false \
      --ssh-hostname ssh.github.com:443 \
      --ssh-key-algorithm ed25519 \
      --interval 1m \
      --network-policy=true \
      --version v2.9.2 \
      --timeout 10m

    git pull --ff-only origin main
    flux check --kubeconfig "$kubeconfig" --timeout 10m

    source_secret="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-system --output json)"
    source_secret_keys="$(yq -r '.data | keys | .[]' - <<<"$source_secret" | sort)"
    [[ "$source_secret_keys" == $'identity\nidentity.pub\nknown_hosts' ]] || {
      echo "Unexpected Flux source credential fields: $source_secret_keys" >&2
      exit 1
    }
    cluster_public_key="$(yq -r '.data."identity.pub"' - <<<"$source_secret" | base64 --decode | awk '{print $1 " " $2}')"
    matching_key="$(GH_TOKEN="$GITHUB_TOKEN" gh api "repos/${owner}/${repository}/keys" \
      --jq '.[] | select(.read_only == true) | .key' | awk '{print $1 " " $2}' | rg -Fx "$cluster_public_key" || true)"
    [[ "$matching_key" == "$cluster_public_key" ]] || {
      echo 'Flux SSH public key does not match a read-only GitHub deploy key.' >&2
      exit 1
    }

    echo 'Flux 2.9.2 bootstrap passed: four controllers are healthy and Git uses the matching read-only SSH deploy key.'
    echo 'The GitHub PAT was not stored in the cluster; unset GITHUB_TOKEN after the bootstrap session.'

# Preserve the Flux deploy key while replacing a stale SSH known_hosts entry for GitHub port 443.
flux-ssh-known-hosts:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_url='ssh://git@ssh.github.com:443/supermorphic/homelab-talos'
    expected_fingerprint='SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM'
    expected_confirmation='repair:flux-system:known-hosts:ssh.github.com:443'
    key_file="$(mktemp /tmp/homelab-talos-flux-identity.XXXXXX)"
    secret_file="$(mktemp /tmp/homelab-talos-flux-secret.XXXXXX)"
    known_hosts_file="$(mktemp /tmp/homelab-talos-flux-known-hosts.XXXXXX)"
    trap 'rm -f -- "$key_file" "$secret_file" "$known_hosts_file"' EXIT
    chmod 600 "$key_file" "$secret_file" "$known_hosts_file"

    source_json="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get gitrepository flux-system --output json)"
    [[ "$(yq -r '.spec.url' - <<<"$source_json")" == "$expected_url" ]] || {
      echo 'Refusing known_hosts repair: the GitRepository does not use the expected port-443 URL.' >&2
      exit 1
    }
    source_secret="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-system --output json)"
    source_secret_keys="$(yq -r '.data | keys | .[]' - <<<"$source_secret" | sort)"
    [[ "$source_secret_keys" == $'identity\nidentity.pub\nknown_hosts' ]]
    existing_public_key="$(yq -r '.data."identity.pub"' - <<<"$source_secret" | base64 --decode | awk 'NF >= 2 {print $1 " " $2; exit}')"
    yq -r '.data.identity' - <<<"$source_secret" | base64 --decode >"$key_file"

    flux create secret git flux-system \
      --namespace flux-system \
      --url "$expected_url" \
      --private-key-file "$key_file" \
      --export >"$secret_file"
    generated_public_key="$(yq -r '.stringData."identity.pub"' "$secret_file" | awk 'NF >= 2 {print $1 " " $2; exit}')"
    [[ "$generated_public_key" == "$existing_public_key" ]] || {
      echo 'Refusing known_hosts repair: generated credentials do not preserve the deploy key.' >&2
      exit 1
    }
    yq -r '.stringData.known_hosts' "$secret_file" >"$known_hosts_file"
    rg -q '^\[ssh\.github\.com\]:443 ' "$known_hosts_file"
    ssh-keygen -lf "$known_hosts_file" -E sha256 | rg -Fq "$expected_fingerprint" || {
      echo 'Refusing known_hosts repair: GitHub ECDSA fingerprint did not match the published value.' >&2
      exit 1
    }

    [[ "${FLUX_SSH_KNOWN_HOSTS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to replace flux-system/flux-system known_hosts.' >&2
      echo "Set FLUX_SSH_KNOWN_HOSTS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    kubectl --kubeconfig "$kubeconfig" apply --filename "$secret_file"
    flux reconcile source git flux-system \
      --namespace flux-system \
      --kubeconfig "$kubeconfig" \
      --timeout 5m
    source_json="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get gitrepository flux-system --output json)"
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$source_json")" == 'True' ]]
    [[ "$(yq -r '.spec.url' - <<<"$source_json")" == "$expected_url" ]]
    echo 'Flux known_hosts repair passed: the deploy key is unchanged and GitHub SSH port 443 is Ready.'

# Create the Flux SOPS decryption Secret from the validated workstation identity.
flux-sops:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_confirmation='create:flux-system:sops-age'
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    key_file="$(mktemp /tmp/homelab-talos-flux-sops.XXXXXX)"
    trap 'rm -f -- "$key_file"' EXIT
    chmod 600 "$key_file"

    flux check --kubeconfig "$kubeconfig"
    just repo secrets

    if [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
      cp -- "$SOPS_AGE_KEY_FILE" "$key_file"
    else
      printf '%s\n' "$SOPS_AGE_KEY" >"$key_file"
    fi
    [[ "$(age-keygen -y "$key_file")" == "$expected_recipient" ]]

    if kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret sops-age >/dev/null 2>&1; then
      live_key="$(mktemp /tmp/homelab-talos-live-flux-sops.XXXXXX)"
      trap 'rm -f -- "$key_file" "$live_key"' EXIT
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret sops-age \
        --output jsonpath='{.data.age\.agekey}' | base64 --decode >"$live_key"
      chmod 600 "$live_key"
      [[ "$(age-keygen -y "$live_key")" == "$expected_recipient" ]] || {
        echo 'Refusing to overwrite a mismatched flux-system/sops-age Secret.' >&2
        exit 1
      }
      echo "flux-system/sops-age already matches $expected_recipient; no mutation required."
      exit 0
    fi

    [[ "${FLUX_SOPS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to create flux-system/sops-age.' >&2
      echo "Set FLUX_SOPS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    kubectl --kubeconfig "$kubeconfig" --namespace flux-system create secret generic sops-age \
      --from-file=age.agekey="$key_file" \
      --dry-run=client \
      --output yaml | kubectl --kubeconfig "$kubeconfig" apply --filename -
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system label secret sops-age \
      app.kubernetes.io/name=sops-age \
      app.kubernetes.io/part-of=flux \
      --overwrite

    live_key="$(mktemp /tmp/homelab-talos-live-flux-sops.XXXXXX)"
    trap 'rm -f -- "$key_file" "$live_key"' EXIT
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret sops-age \
      --output jsonpath='{.data.age\.agekey}' | base64 --decode >"$live_key"
    chmod 600 "$live_key"
    [[ "$(age-keygen -y "$live_key")" == "$expected_recipient" ]]
    echo "Flux SOPS identity installed; its public recipient matches $expected_recipient."

# Adopt the healthy bootstrap Cilium release, then stage the durable Git unsuspend edit.
flux-adopt-cilium:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    source_file='kubernetes/apps/kube-system/cilium/ks.yaml'
    expected_confirmation='adopt:cilium:kube-system:flux'

    [[ -z "$(git status --porcelain)" ]] || {
      echo 'Refusing Cilium adoption: begin from a clean, published checkout.' >&2
      exit 1
    }
    [[ "$(yq -r '.spec.suspend' "$source_file")" == 'true' ]] || {
      echo 'Refusing Cilium adoption: the reviewed Git source is not in its initial suspended state.' >&2
      exit 1
    }
    just kube flux-validate
    flux check --kubeconfig "$kubeconfig"
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/cluster-apps --timeout=5m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization cilium --output jsonpath='{.spec.suspend}')" == 'true' ]]

    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    live_key="$(mktemp /tmp/homelab-talos-adopt-flux-sops.XXXXXX)"
    before_pods="$(mktemp /tmp/homelab-talos-adopt-cilium-before.XXXXXX)"
    after_pods="$(mktemp /tmp/homelab-talos-adopt-cilium-after.XXXXXX)"
    source_backup="$(mktemp /tmp/homelab-talos-adopt-cilium-source.XXXXXX)"
    cp -- "$source_file" "$source_backup"
    resumed=false
    adoption_complete=false
    cleanup_adoption() {
      original_status="$?"
      set +e
      recovery_status=0
      if [[ "$adoption_complete" != 'true' && "$resumed" == 'true' ]]; then
        flux suspend kustomization cilium \
          --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || recovery_status=1
      fi
      if [[ "$adoption_complete" != 'true' ]]; then
        cp -- "$source_backup" "$source_file" || recovery_status=1
      fi
      rm -f -- "$live_key" "$before_pods" "$after_pods" "$source_backup"
      if (( recovery_status != 0 )); then
        echo 'Cilium adoption recovery did not fully restore the suspended transaction boundary.' >&2
        exit 1
      fi
      exit "$original_status"
    }
    trap cleanup_adoption EXIT
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret sops-age \
      --output jsonpath='{.data.age\.agekey}' | base64 --decode >"$live_key"
    chmod 600 "$live_key"
    [[ "$(age-keygen -y "$live_key")" == "$expected_recipient" ]]

    just kube cilium-status
    kubectl --kubeconfig "$kubeconfig" --namespace kube-system get pods \
      --selector app.kubernetes.io/part-of=cilium \
      --output json | yq -r '.items[] | .metadata.name + "\t" + .metadata.uid + "\t" + ([.status.containerStatuses[].restartCount] | join(","))' | sort >"$before_pods"
    old_revision="$(helm list --namespace kube-system --kubeconfig "$kubeconfig" --output json | yq -r '.[] | select(.name == "cilium") | .revision')"
    flux_release_existed=false
    if kubectl --kubeconfig "$kubeconfig" --namespace kube-system get helmrelease cilium >/dev/null 2>&1; then
      flux_release_existed=true
    fi

    [[ "${FLUX_CILIUM_ADOPTION_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to transfer Cilium reconciliation to Flux.' >&2
      echo "Set FLUX_CILIUM_ADOPTION_CONFIRM='$expected_confirmation' after reviewing the Flux and Cilium status." >&2
      exit 1
    }

    yq --inplace '.spec.suspend = false' "$source_file"
    flux resume kustomization cilium --namespace flux-system --kubeconfig "$kubeconfig"
    resumed=true
    flux reconcile kustomization cilium \
      --namespace flux-system \
      --with-source \
      --kubeconfig "$kubeconfig" \
      --timeout 10m
    kubectl --kubeconfig "$kubeconfig" --namespace kube-system wait \
      --for=condition=Ready helmrelease/cilium --timeout=10m

    kubectl --kubeconfig "$kubeconfig" --namespace kube-system get pods \
      --selector app.kubernetes.io/part-of=cilium \
      --output json | yq -r '.items[] | .metadata.name + "\t" + .metadata.uid + "\t" + ([.status.containerStatuses[].restartCount] | join(","))' | sort >"$after_pods"
    new_revision="$(helm list --namespace kube-system --kubeconfig "$kubeconfig" --output json | yq -r '.[] | select(.name == "cilium") | .revision')"
    if [[ "$flux_release_existed" == 'true' ]]; then
      [[ "$new_revision" == "$old_revision" ]] || {
        echo "Recovered adoption unexpectedly changed Helm revision $old_revision to $new_revision." >&2
        exit 1
      }
      cmp -s "$before_pods" "$after_pods" || {
        echo 'Recovered adoption unexpectedly changed Cilium pod identity or restart counts.' >&2
        diff -u "$before_pods" "$after_pods" || true
        exit 1
      }
    else
      [[ "$new_revision" -gt "$old_revision" ]] || {
        echo "Expected a Helm adoption revision after $old_revision; found $new_revision." >&2
        exit 1
      }
      restarted_pods="$(awk -F '\t' '$3 !~ /^0(,0)*$/ {print $1 "=" $3}' "$after_pods")"
      [[ -z "$restarted_pods" ]] || {
        echo "Cilium containers restarted during adoption: $restarted_pods" >&2
        exit 1
      }
    fi
    just kube cilium-status
    just kube cilium-postflight
    adoption_complete=true

    if [[ "$flux_release_existed" == 'true' ]]; then
      echo "Recovered Cilium adoption passed without another rollout; Helm revision remains $new_revision."
    else
      echo "Cilium adoption passed with healthy zero-restart workloads; Helm revision advanced from $old_revision to $new_revision."
    fi
    echo "Review $source_file, then commit and push its suspend=false change before running just kube flux-verify."

# Reconcile the suspended internal foundation in dependency order after guarded preflight.
foundation:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_network_confirmation='reserve:192.168.90.30-39:gateway:192.168.90.30'
    expected_bootstrap_confirmation='bootstrap:foundation:internal-gateway:192.168.90.30'
    foundation_names=(cert-manager cert-manager-config wildcard-certificate metallb metallb-config envoy-gateway internal-gateway external-dns-internal echo)
    foundation_sources=(
      kubernetes/apps/security/cert-manager/ks.yaml
      kubernetes/apps/networking/metallb/ks.yaml
      kubernetes/apps/networking/envoy-gateway/ks.yaml
      kubernetes/apps/networking/internal-gateway/ks.yaml
      kubernetes/apps/networking/external-dns/ks.yaml
      kubernetes/apps/testing/echo/ks.yaml
    )
    pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    pihole_api='https://pi.hole'
    pihole_curl=(
      curl --silent --show-error --fail-with-body --max-time 10
      --cacert "$pihole_ca"
      --resolve 'pi.hole:443:192.168.90.2'
    )
    temp_dir="$(mktemp -d /tmp/homelab-talos-foundation-bootstrap.XXXXXX)"
    resumed=()
    bootstrap_complete=false
    pihole_sid=''
    cleanup_foundation() {
      if [[ -n "$pihole_sid" ]]; then
        "${pihole_curl[@]}" \
          --request DELETE \
          --header "X-FTL-SID: $pihole_sid" \
          "$pihole_api/api/auth" >/dev/null 2>&1 || true
      fi
      if [[ "$bootstrap_complete" != 'true' && "${#resumed[@]}" -gt 0 ]]; then
        echo 'The internal foundation did not pass; suspending attempted Kustomizations while preserving their resources.' >&2
        for name in "${resumed[@]}"; do
          flux suspend kustomization "$name" \
            --namespace flux-system \
            --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
        done
      fi
      rm -rf -- "$temp_dir"
    }
    trap cleanup_foundation EXIT
    umask 077

    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'internal foundation bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/kustomization.yaml \
      kubernetes/apps/security/kustomization.yaml \
      kubernetes/apps/security/cert-manager \
      kubernetes/apps/networking/kustomization.yaml \
      kubernetes/apps/networking/metallb \
      kubernetes/apps/networking/envoy-gateway \
      kubernetes/apps/networking/internal-gateway \
      kubernetes/apps/networking/external-dns \
      kubernetes/apps/testing/kustomization.yaml \
      kubernetes/apps/testing/echo
    [[ "$(yq ea -r '[select(.kind == "Kustomization") | .spec.suspend] | .[]' "${foundation_sources[@]}" | sort -u)" == 'true' ]] || {
      echo 'Refusing the first internal foundation bootstrap: all nine child Kustomizations must be staged suspended in Git.' >&2
      exit 1
    }

    just repo secrets
    just kube foundation-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system \
      --with-source \
      --kubeconfig "$kubeconfig" \
      --timeout 10m
    for name in "${foundation_names[@]}"; do
      live_suspend="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output jsonpath='{.spec.suspend}')"
      [[ "$live_suspend" == 'true' ]] || {
        echo "Refusing internal foundation bootstrap: $name is not suspended in the live cluster." >&2
        exit 1
      }
    done

    sops --decrypt kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml >"$temp_dir/cloudflare.yaml"
    sops --decrypt kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml >"$temp_dir/pihole.yaml"
    cloudflare_token="$(yq -r '.stringData."api-token"' "$temp_dir/cloudflare.yaml")"
    pihole_password="$(yq -r '.stringData.password' "$temp_dir/pihole.yaml")"
    [[ -n "$cloudflare_token" && "$cloudflare_token" != 'null' ]]
    [[ -n "$pihole_password" && "$pihole_password" != 'null' ]]
    token_state="$(curl --silent --show-error --fail-with-body --max-time 10 \
      --header "Authorization: Bearer $cloudflare_token" \
      https://api.cloudflare.com/client/v4/user/tokens/verify)"
    [[ "$(yq -r '.success and (.result.status == "active")' - <<<"$token_state")" == 'true' ]]
    zone_state="$(curl --silent --show-error --fail-with-body --max-time 10 \
      --get \
      --data-urlencode 'name=supermorphic.com' \
      --header "Authorization: Bearer $cloudflare_token" \
      https://api.cloudflare.com/client/v4/zones)"
    [[ "$(yq -r '.success and (.result | length == 1) and (.result[0].name == "supermorphic.com")' - <<<"$zone_state")" == 'true' ]]
    export PIHOLE_PASSWORD="$pihole_password"
    yq -n -o=json '{"password": strenv(PIHOLE_PASSWORD)}' >"$temp_dir/pihole-auth.json"
    pihole_state="$("${pihole_curl[@]}" \
      --request POST \
      --header 'Content-Type: application/json' \
      --data-binary @"$temp_dir/pihole-auth.json" \
      "$pihole_api/api/auth")"
    [[ "$(yq -r '.session.valid' - <<<"$pihole_state")" == 'true' ]]
    pihole_sid="$(yq -r '.session.sid' - <<<"$pihole_state")"
    [[ -n "$pihole_sid" && "$pihole_sid" != 'null' ]]

    assigned_addresses="$(kubectl --kubeconfig "$kubeconfig" get services --all-namespaces --output json | yq -r '.items[].status.loadBalancer.ingress[]?.ip' | sort -u)"
    conflicts="$(rg '^192\.168\.90\.3[0-9]$' <<<"$assigned_addresses" || true)"
    [[ -z "$conflicts" ]] || {
      echo "Refusing MetalLB rollout: addresses from the reserved pool are already assigned: $conflicts" >&2
      exit 1
    }
    for address in {30..39}; do
      if ping -c 1 -W 500 "192.168.90.$address" >/dev/null 2>&1; then
        echo "Refusing MetalLB rollout: 192.168.90.$address answered ICMP." >&2
        exit 1
      fi
    done
    [[ "${FOUNDATION_NETWORK_CONFIRM:-}" == "$expected_network_confirmation" ]] || {
      echo 'Refusing MetalLB rollout without confirmation that 192.168.90.30-39 is excluded from DHCP.' >&2
      echo "Set FOUNDATION_NETWORK_CONFIRM='$expected_network_confirmation' after checking the router reservation scope." >&2
      exit 1
    }
    [[ "${FOUNDATION_BOOTSTRAP_CONFIRM:-}" == "$expected_bootstrap_confirmation" ]] || {
      echo 'Refusing to reconcile the internal foundation.' >&2
      echo "Set FOUNDATION_BOOTSTRAP_CONFIRM='$expected_bootstrap_confirmation' after reviewing foundation status." >&2
      exit 1
    }

    for name in "${foundation_names[@]}"; do
      echo "Reconciling internal foundation Kustomization $name."
      resumed+=("$name")
      flux resume kustomization "$name" \
        --namespace flux-system \
        --kubeconfig "$kubeconfig"
      flux reconcile kustomization "$name" \
        --namespace flux-system \
        --with-source \
        --kubeconfig "$kubeconfig" \
        --timeout 20m
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
        --for=condition=Ready "kustomization/$name" --timeout=20m
    done

    just kube foundation-verify
    bootstrap_complete=true
    echo 'Internal foundation live acceptance passed. Change all internal foundation Git sources to suspend=false, commit, push, and rerun just kube foundation-verify.'

# Reconcile the suspended Longhorn storage foundation after guarded
# checks, in dependency order, then verify. Flux decrypts the CIFS Secret
# in-cluster, so this needs no operator SOPS key. On failure the resumed
# Kustomizations are re-suspended while their resources are preserved.
storage:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:phase9:storage:longhorn'
    names=(longhorn longhorn-config)
    ks='kubernetes/apps/storage/longhorn/ks.yaml'
    resumed=()
    bootstrap_complete=false
    cleanup_storage() {
      if [[ "$bootstrap_complete" != 'true' && "${#resumed[@]}" -gt 0 ]]; then
        echo 'Longhorn storage did not pass; suspending attempted Kustomizations while preserving their resources.' >&2
        for name in "${resumed[@]}"; do
          flux suspend kustomization "$name" \
            --namespace flux-system \
            --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
        done
      fi
    }
    trap cleanup_storage EXIT

    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'storage bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/storage/kustomization.yaml \
      kubernetes/apps/storage/longhorn
    [[ "$(yq ea -r '[select(.kind == "Kustomization") | .spec.suspend] | .[]' "$ks" | sort -u)" == 'true' ]] || {
      echo 'Refusing storage bootstrap: both storage Kustomizations must be staged suspended in Git.' >&2
      exit 1
    }

    just kube storage-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system \
      --with-source \
      --kubeconfig "$kubeconfig" \
      --timeout 10m
    for name in "${names[@]}"; do
      live_suspend="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output jsonpath='{.spec.suspend}')"
      [[ "$live_suspend" == 'true' ]] || {
        echo "Refusing storage bootstrap: $name is not suspended in the live cluster." >&2
        exit 1
      }
    done

    [[ "${STORAGE_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the Longhorn storage foundation.' >&2
      echo "Set STORAGE_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing storage-validate." >&2
      exit 1
    }

    for name in "${names[@]}"; do
      echo "Reconciling storage Kustomization $name."
      resumed+=("$name")
      flux resume kustomization "$name" \
        --namespace flux-system \
        --kubeconfig "$kubeconfig"
      flux reconcile kustomization "$name" \
        --namespace flux-system \
        --with-source \
        --kubeconfig "$kubeconfig" \
        --timeout 20m
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
        --for=condition=Ready "kustomization/$name" --timeout=20m
    done

    just kube storage-verify
    STORAGE_PROVISIONING_CONFIRM='test:storage-provisioning' just kube storage-provisioning-test
    bootstrap_complete=true
    echo "Longhorn storage live acceptance passed. Change both storage Git sources to suspend=false, commit, push, rerun just kube storage-verify, and use STORAGE_PROVISIONING_CONFIRM='test:storage-provisioning' just kube storage-provisioning-test when a fresh provisioning proof is required."

# Reconcile the suspended SMB CSI driver after guarded checks, then verify.
# Run this before media-storage (which depends on it). On failure the resumed
# Kustomization is re-suspended while its resources are preserved.
csi-driver-smb:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:phase11:csi-driver-smb'
    ks='kubernetes/apps/storage/csi-driver-smb/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_csi() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'The SMB CSI driver did not pass; suspending it while preserving its resources.' >&2
        flux suspend kustomization csi-driver-smb --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_csi EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'csi-driver-smb bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/storage/kustomization.yaml \
      kubernetes/apps/storage/csi-driver-smb
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing csi-driver-smb bootstrap: it must be staged suspended in Git.' >&2
      exit 1
    }

    just kube csi-driver-smb-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization csi-driver-smb --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing csi-driver-smb bootstrap: it is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${CSI_DRIVER_SMB_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the SMB CSI driver.' >&2
      echo "Set CSI_DRIVER_SMB_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing csi-driver-smb-validate." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization csi-driver-smb --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization csi-driver-smb --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready kustomization/csi-driver-smb --timeout=10m

    just kube csi-driver-smb-verify
    bootstrap_complete=true
    echo 'SMB CSI driver live acceptance passed. Set suspend=false in Git, commit, push, and rerun just kube csi-driver-smb-verify.'

# Reconcile the suspended media namespace + shared SMB storage after guarded
# checks, in dependency order (media, then media-storage), then verify. Requires the
# smb-credentials Secret (just repo media-smb-secrets) and csi-driver-smb already
# bootstrapped. Flux decrypts the SMB Secret in-cluster, so this needs no operator
# SOPS key. On failure the resumed Kustomizations are re-suspended, resources kept.
media-storage:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:phase11:media-storage'
    names=(media media-storage)
    ns_ks='kubernetes/apps/media/namespace/ks.yaml'
    st_ks='kubernetes/apps/media/storage/ks.yaml'
    resumed=()
    bootstrap_complete=false
    cleanup_media() {
      if [[ "$bootstrap_complete" != 'true' && "${#resumed[@]}" -gt 0 ]]; then
        echo 'Shared media storage did not pass; suspending attempted Kustomizations while preserving their resources.' >&2
        for name in "${resumed[@]}"; do
          flux suspend kustomization "$name" --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
        done
      fi
    }
    trap cleanup_media EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'media-storage bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/media/kustomization.yaml \
      kubernetes/apps/media/namespace \
      kubernetes/apps/media/storage
    for f in "$ns_ks" "$st_ks"; do
      [[ "$(yq -r '.spec.suspend' "$f")" == 'true' ]] || {
        echo "Refusing media-storage bootstrap: $f must be staged suspended in Git." >&2
        exit 1
      }
    done

    just kube media-storage-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    for name in "${names[@]}"; do
      [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
        echo "Refusing media-storage bootstrap: $name is not suspended in the live cluster." >&2
        exit 1
      }
    done

    [[ "${MEDIA_STORAGE_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the shared media storage foundation.' >&2
      echo "Set MEDIA_STORAGE_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing media-storage-validate." >&2
      exit 1
    }

    for name in "${names[@]}"; do
      echo "Reconciling media Kustomization $name."
      resumed+=("$name")
      flux resume kustomization "$name" --namespace flux-system --kubeconfig "$kubeconfig"
      flux reconcile kustomization "$name" --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready "kustomization/$name" --timeout=10m
    done

    just kube media-storage-verify
    bootstrap_complete=true
    echo 'Media storage live acceptance passed. Set both suspend=false in Git, commit, push, and rerun just kube media-storage-verify. Then run mise exec -- just test integration media-hardlink.'

# Reconcile the suspended Plex app after guarded checks, then verify. Requires
# media-storage already bootstrapped (the shared media-data PVC). On failure the
# resumed Kustomization is re-suspended while its resources are preserved.
plex:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:media:plex'
    ks='kubernetes/apps/media/plex/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_plex() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'Plex did not pass; suspending it while preserving its resources.' >&2
        flux suspend kustomization plex --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_plex EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'plex bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/media/kustomization.yaml \
      kubernetes/apps/media/namespace \
      kubernetes/apps/media/plex
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing plex bootstrap: it must be staged suspended in Git.' >&2
      exit 1
    }

    just kube plex-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization plex --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing plex bootstrap: it is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${PLEX_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile Plex.' >&2
      echo "Set PLEX_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing plex-validate." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization plex --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization plex --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready kustomization/plex --timeout=15m

    just kube plex-verify
    bootstrap_complete=true
    echo 'Plex live acceptance passed. Set suspend=false in Git, commit, push, and rerun just kube plex-verify. Then run the plex-cross-node-reschedule resilience test from the test catalog.'

# Reconcile the suspended qBittorrent+Gluetun app after guarded checks, then verify.
# Requires the protonvpn Secret (just repo protonvpn-secrets) and media-storage already
# bootstrapped. Flux decrypts the Secret in-cluster. After verify, run the BLOCKING
# Chainsaw resilience scenario before flipping suspend=false. On failure the resumed
# Kustomization is re-suspended while its resources are preserved.
qbittorrent:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:media:qbittorrent'
    ks='kubernetes/apps/media/qbittorrent/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_qbt() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'qBittorrent did not pass; suspending it while preserving its resources.' >&2
        flux suspend kustomization qbittorrent --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_qbt EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'qbittorrent bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/media/kustomization.yaml \
      kubernetes/apps/media/namespace \
      kubernetes/apps/media/qbittorrent
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing qbittorrent bootstrap: it must be staged suspended in Git.' >&2
      exit 1
    }

    just kube qbittorrent-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization qbittorrent --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing qbittorrent bootstrap: it is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${QBITTORRENT_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the qBittorrent+Gluetun pod.' >&2
      echo "Set QBITTORRENT_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing qbittorrent-validate." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization qbittorrent --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization qbittorrent --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready kustomization/qbittorrent --timeout=15m

    just kube qbittorrent-verify
    bootstrap_complete=true
    echo "qBittorrent live acceptance passed. NOW run the BLOCKING gate: CLUSTER_CHAOS_CONFIRM='chaos:qbittorrent-vpn-disconnect' just test resilience qbittorrent-vpn-disconnect. Only after it passes, set suspend=false in Git, commit, push, and rerun just kube qbittorrent-verify."

# Reconcile a suspended *arr app after guarded checks, then verify:
#   just bootstrap arr <prowlarr|sonarr|radarr|lidarr>
# Operator-run. Requires the suspended source to match deployed origin/main and
# ARR_BOOTSTRAP_CONFIRM='bootstrap:arr:<app>'. On failure the resumed Kustomization
# is re-suspended while its resources are preserved. Recommended order: prowlarr, then
# sonarr, radarr, and lidarr as each becomes ready.
arr app:
    #!/usr/bin/env bash
    set -euo pipefail

    app='{{app}}'
    case "$app" in
      prowlarr|sonarr|radarr|lidarr) ;;
      *) echo "Usage: just bootstrap arr <prowlarr|sonarr|radarr|lidarr>" >&2; exit 1 ;;
    esac
    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation="bootstrap:arr:$app"
    ks="kubernetes/apps/media/$app/ks.yaml"
    resumed=false
    bootstrap_complete=false
    cleanup_arr() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo "$app did not pass; suspending it while preserving its resources." >&2
        flux suspend kustomization "$app" --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_arr EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source "$app bootstrap" \
      .just/bootstrap.just kubernetes/mod.just \
      scripts/validate/arr.sh scripts/verify/arr.sh scripts/lib/network.sh \
      tests/catalog.yaml \
      kubernetes/apps/media/kustomization.yaml \
      kubernetes/apps/media/namespace \
      "kubernetes/apps/media/$app"
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo "Refusing $app bootstrap: it must be staged suspended in Git." >&2
      exit 1
    }

    just kube arr-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$app" --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo "Refusing $app bootstrap: it is not suspended in the live cluster." >&2
      exit 1
    }

    [[ "${ARR_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing to reconcile $app." >&2
      echo "Set ARR_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing arr-validate." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization "$app" --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization "$app" --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready "kustomization/$app" --timeout=15m

    just kube arr-verify "$app"
    bootstrap_complete=true
    echo "$app live acceptance passed. Set suspend=false in Git, commit, push, and rerun just kube arr-verify $app. Continue with the app's first-run steps in docs/guides/media-automation-setup.md."

# Reconcile a suspended config-only media app after guarded checks, then verify.
# Operator-run. The allowlist intentionally contains only Tautulli.
media-app app:
    #!/usr/bin/env bash
    set -euo pipefail

    app='{{app}}'
    case "$app" in
      tautulli) ;;
      *) echo 'Usage: just bootstrap media-app tautulli' >&2; exit 1 ;;
    esac
    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation="bootstrap:media-app:$app"
    ks="kubernetes/apps/media/$app/ks.yaml"
    resumed=false
    bootstrap_complete=false
    cleanup_media_app() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo "$app did not pass; suspending it while preserving its resources." >&2
        flux suspend kustomization "$app" --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_media_app EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source "$app bootstrap" \
      .just/bootstrap.just kubernetes/mod.just \
      scripts/lib/rollout.sh scripts/lib/network.sh \
      scripts/validate/tautulli.sh scripts/validate/alerts.sh \
      scripts/verify/tautulli.sh tests/catalog.yaml \
      tests/prometheus/media-alerts_test.yaml \
      kubernetes/apps/media/kustomization.yaml \
      kubernetes/apps/media/namespace \
      kubernetes/apps/media/alerts \
      "kubernetes/apps/media/$app"
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo "$app must be staged suspended in Git." >&2
      exit 1
    }

    just kube tautulli-validate
    just kube alerts-validate media
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$app" --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo "$app is not suspended in the live cluster." >&2
      exit 1
    }

    [[ "${MEDIA_APP_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Set MEDIA_APP_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing both validators." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization "$app" --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization "$app" --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready "kustomization/$app" --timeout=15m
    just kube tautulli-verify
    bootstrap_complete=true
    echo "$app liveness passed. Complete authentication, Plex connection, exact-status, library, and playback gates before activation."

# Reconcile the suspended Seerr app after guarded checks, then verify. Operator-run.
# Requires the suspended source to match deployed origin/main and
# SEERR_BOOTSTRAP_CONFIRM='bootstrap:media:seerr'. On failure the resumed Kustomization is
# re-suspended while its resources are preserved.
seerr:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:media:seerr'
    ks='kubernetes/apps/media/seerr/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_seerr() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'Seerr did not pass; suspending it while preserving its resources.' >&2
        flux suspend kustomization seerr --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_seerr EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'seerr bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/media/kustomization.yaml \
      kubernetes/apps/media/namespace \
      kubernetes/apps/media/seerr
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing seerr bootstrap: it must be staged suspended in Git.' >&2
      exit 1
    }

    just kube seerr-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization seerr --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing seerr bootstrap: it is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${SEERR_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the Seerr app.' >&2
      echo "Set SEERR_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing seerr-validate." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization seerr --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization seerr --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready kustomization/seerr --timeout=15m

    just kube seerr-verify
    bootstrap_complete=true
    echo "Seerr live acceptance passed. Set suspend=false in Git, commit, push, rerun just kube seerr-verify. First-run: add Plex + Sonarr + Radarr (URLs + API keys) in the Seerr UI."

# Reconcile the suspended FlareSolverr app (stateless Cloudflare solver for Prowlarr) after
# guarded checks, then verify. Operator-run. Requires the suspended source to match deployed
# origin/main and FLARESOLVERR_BOOTSTRAP_CONFIRM='bootstrap:media:flaresolverr'. On failure
# the resumed Kustomization is re-suspended while its resources are preserved. This owns ONLY
# the FlareSolverr app — the Prowlarr indexer-proxy + 1337x tag stay operator-managed UI.
flaresolverr:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:media:flaresolverr'
    ks='kubernetes/apps/media/flaresolverr/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_flaresolverr() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'FlareSolverr did not pass; suspending it while preserving its resources.' >&2
        flux suspend kustomization flaresolverr --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_flaresolverr EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'flaresolverr bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/media/kustomization.yaml \
      kubernetes/apps/media/namespace \
      kubernetes/apps/media/flaresolverr
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing flaresolverr bootstrap: it must be staged suspended in Git.' >&2
      exit 1
    }

    just kube flaresolverr-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization flaresolverr --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing flaresolverr bootstrap: it is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${FLARESOLVERR_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the FlareSolverr app.' >&2
      echo "Set FLARESOLVERR_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing flaresolverr-validate." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization flaresolverr --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization flaresolverr --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready kustomization/flaresolverr --timeout=15m

    just kube flaresolverr-verify
    bootstrap_complete=true
    echo "FlareSolverr live acceptance passed. Set suspend=false in Git, commit, push, rerun just kube flaresolverr-verify. Then (manual UI): Prowlarr > Settings > Indexers > Add Indexer Proxy > FlareSolverr (http://flaresolverr.media.svc.cluster.local:8191, tag flaresolverr); tag 1337x ONLY; require the proxy Test AND a real 1337x search to pass."

# Reconcile the suspended qbit_manage app (UI-less qBittorrent policy scheduler) after guarded
# checks, then verify. Operator-run. PREREQUISITE: create the real credential first with
# `just repo qbit-manage-secrets` (the committed Secret ships as an inert placeholder).
# Requires the suspended source to match deployed origin/main and
# QBIT_MANAGE_BOOTSTRAP_CONFIRM='bootstrap:media:qbit-manage'. On failure the resumed
# Kustomization is re-suspended while its resources are preserved. The deployed policy is
# active, so the operator must attend its first run after the readiness checks pass.
qbit-manage:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:media:qbit-manage'
    ks='kubernetes/apps/media/qbit-manage/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_qbit_manage() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'qbit-manage did not pass; suspending it while preserving its resources.' >&2
        flux suspend kustomization qbit-manage --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_qbit_manage EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    # NOTE: the credential itself cannot be validated here — it is SOPS-encrypted and this
    # recipe holds no age key (Flux decrypts in-cluster). A wrong or still-placeholder
    # credential surfaces at qbit-manage-verify below as a qBittorrent login failure, which
    # fails the bootstrap and re-suspends the app. Create/rotate it with
    # `just repo qbit-manage-secrets` before bootstrapping.
    source scripts/lib/rollout.sh
    require_deployed_source 'qbit-manage bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/media/kustomization.yaml \
      kubernetes/apps/media/namespace \
      kubernetes/apps/media/qbit-manage
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing qbit-manage bootstrap: it must be staged suspended in Git.' >&2
      exit 1
    }

    just kube qbit-manage-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization qbit-manage --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing qbit-manage bootstrap: it is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${QBIT_MANAGE_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the qbit-manage app.' >&2
      echo "Set QBIT_MANAGE_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing qbit-manage-validate." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization qbit-manage --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization qbit-manage --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready kustomization/qbit-manage --timeout=15m

    just kube qbit-manage-verify
    bootstrap_complete=true
    echo "qbit-manage live readiness passed; the active classification, share-limit, and cleanup policy is running. Attend the first policy run before setting suspend=false through Git, then rerun just kube qbit-manage-verify. See docs/guides/qbit-manage-operations.md and docs/reference/qbit-manage.md."

# Reconcile the Intel GPU device plugin from source staged with suspend=true, then
# verify it before the activation change sets suspend=false.
# Plex already declares its gpu.intel.com/i915 request; reconcile Plex only after the
# plugin advertises it. On failure, the resumed Kustomization is re-suspended while its
# resources are preserved.
intel-gpu-plugin:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:phase11:intel-gpu-plugin'
    ks='kubernetes/apps/kube-system/intel-gpu-plugin/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_gpu() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'The Intel GPU plugin did not pass; suspending it while preserving its resources.' >&2
        flux suspend kustomization intel-gpu-plugin --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_gpu EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'intel-gpu-plugin bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/kube-system/kustomization.yaml \
      kubernetes/apps/kube-system/intel-gpu-plugin
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing intel-gpu-plugin bootstrap: it must be staged suspended in Git.' >&2
      exit 1
    }

    just kube intel-gpu-plugin-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization intel-gpu-plugin --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing intel-gpu-plugin bootstrap: it is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${INTEL_GPU_PLUGIN_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the Intel GPU device plugin.' >&2
      echo "Set INTEL_GPU_PLUGIN_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing intel-gpu-plugin-validate." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization intel-gpu-plugin --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization intel-gpu-plugin --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready kustomization/intel-gpu-plugin --timeout=10m

    just kube intel-gpu-plugin-verify
    bootstrap_complete=true
    echo 'Intel GPU plugin live acceptance passed. Set suspend=false in Git, commit, push, and rerun just kube intel-gpu-plugin-verify. Plex already declares its gpu.intel.com/i915 request.'

# Reconcile the suspended monitoring stack (kube-prometheus-stack) after
# guarded checks, in dependency order, then verify. Flux decrypts the Grafana
# Secret in-cluster, so this needs no operator SOPS key. On failure the resumed
# Kustomizations are re-suspended while their resources are preserved.
monitoring:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:phase10:monitoring:kube-prometheus-stack'
    names=(kube-prometheus-stack kube-prometheus-stack-config)
    ks='kubernetes/apps/monitoring/kube-prometheus-stack/ks.yaml'
    resumed=()
    bootstrap_complete=false
    cleanup_monitoring() {
      if [[ "$bootstrap_complete" != 'true' && "${#resumed[@]}" -gt 0 ]]; then
        echo 'Monitoring did not pass; suspending attempted Kustomizations while preserving their resources.' >&2
        for name in "${resumed[@]}"; do
          flux suspend kustomization "$name" \
            --namespace flux-system \
            --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
        done
      fi
    }
    trap cleanup_monitoring EXIT

    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'monitoring bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/monitoring/kustomization.yaml \
      kubernetes/apps/monitoring/kube-prometheus-stack
    [[ "$(yq ea -r '[select(.kind == "Kustomization") | .spec.suspend] | .[]' "$ks" | sort -u)" == 'true' ]] || {
      echo 'Refusing monitoring bootstrap: both monitoring Kustomizations must be staged suspended in Git.' >&2
      exit 1
    }

    just kube monitoring-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system \
      --with-source \
      --kubeconfig "$kubeconfig" \
      --timeout 10m
    for name in "${names[@]}"; do
      live_suspend="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output jsonpath='{.spec.suspend}')"
      [[ "$live_suspend" == 'true' ]] || {
        echo "Refusing monitoring bootstrap: $name is not suspended in the live cluster." >&2
        exit 1
      }
    done

    [[ "${MONITORING_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the monitoring stack.' >&2
      echo "Set MONITORING_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing monitoring-validate." >&2
      exit 1
    }

    for name in "${names[@]}"; do
      echo "Reconciling monitoring Kustomization $name."
      resumed+=("$name")
      flux resume kustomization "$name" \
        --namespace flux-system \
        --kubeconfig "$kubeconfig"
      flux reconcile kustomization "$name" \
        --namespace flux-system \
        --with-source \
        --kubeconfig "$kubeconfig" \
        --timeout 25m
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
        --for=condition=Ready "kustomization/$name" --timeout=25m
    done

    just kube monitoring-verify
    bootstrap_complete=true
    echo 'Monitoring live acceptance passed. Change both monitoring Git sources to suspend=false, commit, push, and rerun just kube monitoring-verify.'

# Reconcile the suspended Gatus app after guarded checks, then verify.
# On failure the resumed Kustomization is re-suspended, preserving its resources.
gatus:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:phase10:gatus'
    ks='kubernetes/apps/monitoring/gatus/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_gatus() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'Gatus did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization gatus --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_gatus EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'Gatus bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/monitoring/kustomization.yaml \
      kubernetes/apps/monitoring/gatus
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing Gatus bootstrap: the Gatus Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube gatus-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization gatus --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing Gatus bootstrap: gatus is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${GATUS_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the Gatus app.' >&2
      echo "Set GATUS_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing gatus-validate." >&2
      exit 1
    }

    echo 'Reconciling Gatus Kustomization.'
    resumed=true
    flux resume kustomization gatus --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization gatus \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/gatus --timeout=15m

    just kube gatus-verify
    bootstrap_complete=true
    echo 'Gatus live acceptance passed. Change the Gatus Git source to suspend=false, commit, push, and rerun just kube gatus-verify.'

# Reconcile the suspended read-only Portainer design after guarded source and static
# validation, then run live read-only acceptance. On failure the Kustomization is
# re-suspended while its PVC and other resources are preserved.
portainer:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:portainer'
    ks='kubernetes/apps/monitoring/portainer/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_portainer() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'Portainer did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization portainer --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_portainer EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'Portainer bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/monitoring/kustomization.yaml \
      kubernetes/apps/monitoring/portainer
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing Portainer bootstrap: the Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube portainer-validate
    just kube portainer-policy-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization portainer --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing Portainer bootstrap: portainer is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${PORTAINER_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile Portainer.' >&2
      echo "Set PORTAINER_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing portainer-validate." >&2
      exit 1
    }

    echo 'Reconciling Portainer Kustomization.'
    resumed=true
    flux resume kustomization portainer --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization portainer \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/portainer --timeout=15m

    just kube portainer-verify
    bootstrap_complete=true
    echo 'Portainer live acceptance passed. Run the guarded persistence test, then activate Portainer in Git by setting suspend=false and adding its Gatus endpoint in the same reviewed change. Commit, push, wait for Flux, and rerun just kube portainer-verify.'

# Reconcile the suspended persistent test-report host after guarded source/static
# validation, then run live read-only acceptance. Publication remains a separate,
# exactly confirmed operator action.
test-reports:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:test-reports'
    ks='kubernetes/apps/monitoring/test-reports/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_test_reports() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'Test-report server did not pass; suspending its Kustomization while preserving the PVC.' >&2
        flux suspend kustomization test-reports --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_test_reports EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'test-report server bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/monitoring/kustomization.yaml \
      kubernetes/apps/monitoring/test-reports \
      scripts/validate/test-reports.sh scripts/verify/test-reports.sh
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing test-report bootstrap: the Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube test-reports-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
      get kustomization test-reports --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing test-report bootstrap: test-reports is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${TEST_REPORTS_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the test-report server.' >&2
      echo "Set TEST_REPORTS_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing test-reports-validate." >&2
      exit 1
    }

    echo 'Reconciling the test-reports Kustomization.'
    resumed=true
    flux resume kustomization test-reports --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization test-reports \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/test-reports --timeout=15m

    just kube test-reports-verify
    bootstrap_complete=true
    echo 'Test-report server acceptance passed. Publish a sanitized current-main run, verify persistence, then activate it and add the Gatus probe in a follow-up PR.'

# Reconcile the suspended Homepage app after guarded checks, then verify.
# On failure the resumed Kustomization is re-suspended, preserving its resources.
homepage:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:phase10:homepage'
    ks='kubernetes/apps/monitoring/homepage/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_homepage() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'Homepage did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization homepage --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_homepage EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'Homepage bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/monitoring/kustomization.yaml \
      kubernetes/apps/monitoring/homepage
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing Homepage bootstrap: the Homepage Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube homepage-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization homepage --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing Homepage bootstrap: homepage is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${HOMEPAGE_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the Homepage app.' >&2
      echo "Set HOMEPAGE_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing homepage-validate." >&2
      exit 1
    }

    echo 'Reconciling Homepage Kustomization.'
    resumed=true
    flux resume kustomization homepage --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization homepage \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/homepage --timeout=15m

    just kube homepage-verify
    bootstrap_complete=true
    echo 'Homepage live acceptance passed. Change the Homepage Git source to suspend=false, commit, push, and rerun just kube homepage-verify.'

# Reconcile the suspended Trivy Operator after guarded checks, then
# verify. On failure the resumed Kustomization is re-suspended, preserving its
# resources.
trivy:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:phase10:trivy-operator'
    ks='kubernetes/apps/security/trivy-operator/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_trivy() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'Trivy Operator did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization trivy-operator --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_trivy EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'Trivy bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/security/kustomization.yaml \
      kubernetes/apps/security/trivy-operator
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing Trivy bootstrap: the Trivy Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube trivy-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization trivy-operator --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing Trivy bootstrap: trivy-operator is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${TRIVY_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the Trivy Operator.' >&2
      echo "Set TRIVY_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing trivy-validate." >&2
      exit 1
    }

    echo 'Reconciling Trivy Operator Kustomization.'
    resumed=true
    flux resume kustomization trivy-operator --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization trivy-operator \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/trivy-operator --timeout=15m

    just kube trivy-verify
    bootstrap_complete=true
    echo 'Trivy Operator live acceptance passed. Change the Trivy Git source to suspend=false, commit, push, and rerun just kube trivy-verify.'

# Reconcile the suspended Tailscale operator after guarded checks, then verify the
# operator and its ingress ProxyGroup. Requires the operator-oauth Secret committed
# (just repo tailscale-operator-secrets) and the tailnet-side prerequisites in
# docs/guides/tailscale-operator-operations.md already in place. On failure the resumed Kustomization is
# re-suspended, preserving its resources.
tailscale-operator:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:networking:tailscale-operator'
    ks='kubernetes/apps/networking/tailscale-operator/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_tailscale_operator() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'Tailscale operator bootstrap did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization tailscale-operator --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_tailscale_operator EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'Tailscale operator bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/networking/kustomization.yaml \
      kubernetes/apps/networking/tailscale-operator
    [[ "$(yq -r 'select(.metadata.name == "tailscale-operator") | .spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing Tailscale operator bootstrap: the operator Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube tailscale-operator-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization tailscale-operator --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing Tailscale operator bootstrap: tailscale-operator is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${TAILSCALE_OPERATOR_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the Tailscale operator.' >&2
      echo "Set TAILSCALE_OPERATOR_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing tailscale-operator-validate." >&2
      exit 1
    }

    echo 'Reconciling Tailscale operator Kustomization (installs the operator + tailscale.com CRDs).'
    resumed=true
    flux resume kustomization tailscale-operator --namespace flux-system --kubeconfig "$kubeconfig" --timeout 15m
    flux reconcile kustomization tailscale-operator \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/tailscale-operator --timeout=15m

    # The ProxyGroup Kustomization (suspend: false, dependsOn the operator) reconciles
    # once the CRD exists; reconcile it explicitly and gate on it.
    echo 'Reconciling Tailscale ProxyGroup Kustomization (CRD now present).'
    flux reconcile kustomization tailscale-operator-proxygroup \
      --namespace flux-system --kubeconfig "$kubeconfig" --timeout 10m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/tailscale-operator-proxygroup --timeout=10m

    just kube tailscale-operator-verify
    bootstrap_complete=true
    echo 'Tailscale operator live acceptance passed. Change the operator Kustomization (tailscale-operator) Git source to suspend=false, commit, push, and rerun just kube tailscale-operator-verify.'

# Reconcile the suspended lab-subnet-router Connector after guarded checks, then verify.
# PREREQUISITE (tailnet, operator-owned): tag:lab-router must already be owned by
# tag:k8s-operator and the DNS/Gateway grants saved in the tailnet policy BEFORE this runs,
# or the operator cannot create the Connector devices. The Connector CRD is installed by the
# already-active tailscale-operator. On failure the resumed Kustomization is re-suspended,
# preserving its resources. After success, approve both /32 routes on BOTH devices and
# configure split DNS per docs/guides/tailscale-lab-domain-access.md, then open the activation PR.
tailscale-subnet-router:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:networking:tailscale-subnet-router'
    ks='kubernetes/apps/networking/tailscale-operator/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_tailscale_subnet_router() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'Tailscale subnet-router bootstrap did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization tailscale-operator-subnet-router --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_tailscale_subnet_router EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'Tailscale subnet-router bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/networking/kustomization.yaml \
      kubernetes/apps/networking/tailscale-operator/ks.yaml \
      kubernetes/apps/networking/tailscale-operator/subnet-router
    [[ "$(yq -r 'select(.metadata.name == "tailscale-operator-subnet-router") | .spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing Tailscale subnet-router bootstrap: the subnet-router Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube tailscale-subnet-router-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization tailscale-operator-subnet-router --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing Tailscale subnet-router bootstrap: tailscale-operator-subnet-router is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${TAILSCALE_SUBNET_ROUTER_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the Tailscale subnet router.' >&2
      echo "Set TAILSCALE_SUBNET_ROUTER_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing tailscale-subnet-router-validate and confirming tag:lab-router ownership is saved in the tailnet policy." >&2
      exit 1
    }

    echo 'Reconciling Tailscale subnet-router Kustomization (creates the HA Connector + ProxyClass).'
    resumed=true
    flux resume kustomization tailscale-operator-subnet-router --namespace flux-system --kubeconfig "$kubeconfig" --timeout 10m
    flux reconcile kustomization tailscale-operator-subnet-router \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/tailscale-operator-subnet-router --timeout=10m

    just kube tailscale-subnet-router-verify
    bootstrap_complete=true
    echo 'Tailscale subnet-router live acceptance passed. Approve both /32 routes on BOTH lab-subnet-router-* devices and configure split DNS (docs/guides/tailscale-lab-domain-access.md), complete client acceptance, then change the subnet-router Kustomization Git source to suspend=false, commit, push, and rerun just kube tailscale-subnet-router-verify.'

# Reconcile the suspended ntfy notification service after guarded checks, then verify.
# Requires the ntfy-secret committed (just repo ntfy-identity reconcile all) and the
# tailscale-operator already rolled out. On failure the resumed Kustomization is
# re-suspended, preserving its resources (the Longhorn PVC and SOPS Secret are never
# deleted).
ntfy:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:monitoring:ntfy'
    ks='kubernetes/apps/monitoring/ntfy/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_ntfy() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'ntfy bootstrap did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization ntfy --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_ntfy EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'ntfy bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/monitoring/kustomization.yaml \
      kubernetes/apps/monitoring/ntfy
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing ntfy bootstrap: the Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube ntfy-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization ntfy --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing ntfy bootstrap: ntfy is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${NTFY_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile ntfy.' >&2
      echo "Set NTFY_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing ntfy-validate." >&2
      exit 1
    }

    echo 'Reconciling ntfy Kustomization.'
    resumed=true
    flux resume kustomization ntfy --namespace flux-system --kubeconfig "$kubeconfig" --timeout 15m
    flux reconcile kustomization ntfy \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/ntfy --timeout=15m

    just kube ntfy-verify
    bootstrap_complete=true
    echo 'ntfy live acceptance passed. Change the ntfy Git source to suspend=false, commit, push, and rerun just kube ntfy-verify.'

# Reconcile the suspended alertmanager-ntfy adapter after guarded checks, then verify.
# Requires the canonical ntfy-secret (with its auth.yml key) committed (just repo
# ntfy-identity reconcile all) and ntfy already rolled out. On failure the resumed
# Kustomization is re-suspended.
alertmanager-ntfy:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:monitoring:alertmanager-ntfy'
    ks='kubernetes/apps/monitoring/alertmanager-ntfy/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_alertmanager_ntfy() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'alertmanager-ntfy bootstrap did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization alertmanager-ntfy --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_alertmanager_ntfy EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'alertmanager-ntfy bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/monitoring/kustomization.yaml \
      kubernetes/apps/monitoring/alertmanager-ntfy
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing alertmanager-ntfy bootstrap: the Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube alertmanager-ntfy-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization alertmanager-ntfy --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing alertmanager-ntfy bootstrap: alertmanager-ntfy is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${ALERTMANAGER_NTFY_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile alertmanager-ntfy.' >&2
      echo "Set ALERTMANAGER_NTFY_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing alertmanager-ntfy-validate." >&2
      exit 1
    }

    echo 'Reconciling alertmanager-ntfy Kustomization.'
    resumed=true
    flux resume kustomization alertmanager-ntfy --namespace flux-system --kubeconfig "$kubeconfig" --timeout 15m
    flux reconcile kustomization alertmanager-ntfy \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/alertmanager-ntfy --timeout=15m

    just kube alertmanager-ntfy-verify
    bootstrap_complete=true
    echo 'alertmanager-ntfy live acceptance passed. Change the alertmanager-ntfy Git source to suspend=false, commit, push, and rerun just kube alertmanager-ntfy-verify.'

# Reconcile the suspended metrics-server (enables kubectl top / HPA / the Homepage
# Kubernetes widget). On failure the resumed Kustomization is re-suspended.
metrics-server:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:metrics-server'
    ks='kubernetes/apps/kube-system/metrics-server/ks.yaml'
    resumed=false
    bootstrap_complete=false
    cleanup_metrics_server() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'metrics-server did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization metrics-server --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_metrics_server EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source 'metrics-server bootstrap' \
      .just/bootstrap.just kubernetes/mod.just \
      kubernetes/apps/kube-system/kustomization.yaml \
      kubernetes/apps/kube-system/metrics-server
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing metrics-server bootstrap: the Kustomization must be staged suspended in Git.' >&2
      exit 1
    }

    just kube metrics-server-validate
    # Reconcile the published main source before checking Flux's artifact revision.
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization metrics-server --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing metrics-server bootstrap: metrics-server is not suspended in the live cluster.' >&2
      exit 1
    }

    [[ "${METRICS_SERVER_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile metrics-server.' >&2
      echo "Set METRICS_SERVER_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing metrics-server-validate." >&2
      exit 1
    }

    echo 'Reconciling metrics-server Kustomization.'
    resumed=true
    flux resume kustomization metrics-server --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization metrics-server \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/metrics-server --timeout=15m

    just kube metrics-server-verify
    bootstrap_complete=true
    echo 'metrics-server live acceptance passed. Change the Git source to suspend=false, commit, push, and rerun just kube metrics-server-verify.'

# Reconcile the suspended agent-access RBAC after validating the complete policy.
# On failure the resumed Kustomization is re-suspended while preserving resources.
agent-access:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='supermorphic'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation='bootstrap:agent-access'
    ks='kubernetes/apps/kube-system/agent-access/ks.yaml'
    app='kubernetes/apps/kube-system/agent-access/app'
    policy='tests/policy/agent-access'
    temp_dir="$(mktemp -d /tmp/homelab-talos-agent-access.XXXXXX)"
    resumed=false
    bootstrap_complete=false
    cleanup_agent_access() {
      rm -rf -- "$temp_dir"
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo 'agent-access did not pass; suspending the attempted Kustomization while preserving its resources.' >&2
        flux suspend kustomization agent-access --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_agent_access EXIT

    # Validate the policy and the exact rendered RBAC before any cluster access.
    conftest fmt --check "$policy"
    conftest verify --policy "$policy"
    kustomize build "$app" >"$temp_dir/rendered.yaml"
    conftest test --combine --all-namespaces --policy "$policy" "$temp_dir/rendered.yaml"

    source scripts/lib/rollout.sh
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    require_deployed_source 'agent-access bootstrap' \
      .just/bootstrap.just \
      kubernetes/apps/kube-system/kustomization.yaml \
      kubernetes/apps/kube-system/agent-access \
      tests/policy/agent-access
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo 'Refusing agent-access bootstrap: the Kustomization must be staged suspended in Git.' >&2
      exit 1
    }
    [[ "${AGENT_ACCESS_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile agent-access.' >&2
      echo "Set AGENT_ACCESS_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing the rendered RBAC and policy." >&2
      exit 1
    }

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization agent-access --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing agent-access bootstrap: agent-access is not suspended in the live cluster.' >&2
      exit 1
    }

    echo 'Reconciling only the agent-access Kustomization.'
    resumed=true
    flux resume kustomization agent-access --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization agent-access \
      --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 5m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/agent-access --timeout=5m

    # With an admin kubeconfig, the shared verifier selects its complete ServiceAccount
    # impersonation path (username plus all three Kubernetes identity groups). Worktree
    # scoped contexts use the same matrix directly without impersonation.
    scripts/verify/agent-access.sh "$kubeconfig" '{{talosconfig}}'

    bootstrap_complete=true
    echo 'agent-access authorization acceptance passed. Change the Git source to suspend=false in a separate reviewed change.'

# Guard, reboot one node, and require full recovery before returning. Refuses
# unless the cluster is already healthy so a rolling reboot never removes a second
# node while another is degraded. Reused for the initial resilience soak and day-two maintenance.
[private]
_reboot-legacy node:
    #!/usr/bin/env bash
    set -euo pipefail

    node='{{node}}'
    case "$node" in
      nuc1) node_ip='192.168.90.10' ;;
      nuc2) node_ip='192.168.90.11' ;;
      nuc3) node_ip='192.168.90.12' ;;
      *)
        echo 'Node must be one of: nuc1, nuc2, nuc3.' >&2
        exit 1
        ;;
    esac

    talosconfig='{{talosconfig}}'
    kubeconfig='{{kubeconfig}}'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    expected_names=$'nuc1\nnuc2\nnuc3'
    expected_confirmation="reboot:${node}:${node_ip}"

    just repo require-bash
    [[ -f "$talosconfig" ]] || {
      echo "Missing $talosconfig; run just talos generate." >&2
      exit 1
    }
    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }

    cluster_healthy() {
      local nodes_json ready names members member_count member_names alarms alarm_rows
      nodes_json="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json 2>/dev/null)" || return 1
      names="$(yq -r '.items[].metadata.name' - <<<"$nodes_json" | sort)"
      [[ "$names" == "$expected_names" ]] || return 1
      ready="$(yq -r '[.items[] | .status.conditions[] | select(.type == "Ready") | .status] | sort | join(" ")' - <<<"$nodes_json")"
      [[ "$ready" == 'True True True' ]] || return 1
      members="$(talosctl --talosconfig "$talosconfig" --nodes 192.168.90.10 --endpoints "$nodes_csv" etcd members 2>/dev/null)" || return 1
      member_count="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$members")"
      [[ "$member_count" == '3' ]] || return 1
      member_names="$(awk 'NR > 1 && NF {print $3}' <<<"$members" | sort)"
      [[ "$member_names" == "$expected_names" ]] || return 1
      alarms="$(talosctl --talosconfig "$talosconfig" --nodes "$nodes_csv" --endpoints "$nodes_csv" etcd alarm list 2>/dev/null)" || return 1
      alarm_rows="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$alarms")"
      [[ "$alarm_rows" == '0' ]] || return 1
    }

    announcer() {
      kubectl --kubeconfig "$kubeconfig" get servicel2statuses.metallb.io --all-namespaces --output json 2>/dev/null \
        | yq -r '[.items[].status.node] | join(" ")'
    }

    node_ready() {
      kubectl --kubeconfig "$kubeconfig" get node "$node" --output json 2>/dev/null \
        | yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' 2>/dev/null
    }

    echo "=== pre-reboot health gate ==="
    cluster_healthy || {
      echo "Refusing to reboot $node: the cluster is not fully healthy (three Ready nodes, three etcd members, no alarms)." >&2
      exit 1
    }
    announcer_before="$(announcer)"
    echo "Cluster healthy. MetalLB is announcing 192.168.90.30 from: ${announcer_before:-<none>}"

    [[ "${TALOS_REBOOT_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing to reboot $node." >&2
      echo "Set TALOS_REBOOT_CONFIRM='$expected_confirmation' and rerun after reviewing the pre-reboot health." >&2
      exit 1
    }

    echo "Rebooting $node ($node_ip); etcd quorum drops to 2/3 until it returns."
    talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" reboot --wait=false

    if rg -qw "$node" <<<"$announcer_before"; then
      echo "=== $node announced 192.168.90.30; watching MetalLB fail the announcement over ==="
      moved=false
      for _ in {1..90}; do
        current="$(announcer)"
        if [[ -n "$current" ]] && ! rg -qw "$node" <<<"$current"; then
          echo "  192.168.90.30 now announced from: $current"
          moved=true
          break
        fi
        sleep 2
      done
      [[ "$moved" == 'true' ]] || echo "Warning: did not observe MetalLB failover away from $node within the window." >&2
    fi

    echo "=== waiting for $node to drop ==="
    for _ in {1..60}; do
      [[ "$(node_ready)" != 'True' ]] && break
      sleep 2
    done

    echo "=== waiting for $node to return Ready ==="
    ready_state=''
    for _ in {1..90}; do
      ready_state="$(node_ready)"
      [[ "$ready_state" == 'True' ]] && break
      sleep 5
    done
    [[ "$ready_state" == 'True' ]] || {
      echo "Node $node did not return to Ready after reboot." >&2
      exit 1
    }

    echo "=== verifying Secure Boot and TPM volume auto-unlock on $node ==="
    common=(--talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" --output yaml)
    security_state="$(talosctl get securitystate "${common[@]}")"
    [[ "$(yq -r '.spec.secureBoot' - <<<"$security_state")" == 'true' ]] || {
      echo "$node did not report Secure Boot after reboot." >&2
      exit 1
    }
    [[ "$(yq -r '.spec.bootedWithUKI' - <<<"$security_state")" == 'true' ]]
    volume_state="$(talosctl get volumestatuses "${common[@]}")"
    [[ "$(yq ea -r 'select(.metadata.id == "STATE") | [.spec.phase, .spec.encryptionProvider] | join(" ")' - <<<"$volume_state")" == 'ready luks2' ]] || {
      echo "$node STATE volume did not unlock via TPM after reboot." >&2
      exit 1
    }
    [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | [.spec.phase, .spec.encryptionProvider] | join(" ")' - <<<"$volume_state")" == 'ready luks2' ]] || {
      echo "$node EPHEMERAL volume did not unlock via TPM after reboot." >&2
      exit 1
    }
    [[ "$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.phase' - <<<"$volume_state")" == 'ready' ]]

    echo "=== waiting for etcd to return to three healthy members ==="
    for _ in {1..60}; do
      cluster_healthy && break
      sleep 5
    done
    cluster_healthy || {
      echo "Cluster did not return to full health after the $node reboot." >&2
      exit 1
    }

    just kube foundation-verify

    echo "Reboot recovery passed for $node: Secure Boot and TPM auto-unlock, three-member etcd with no alarms, MetalLB, DNS, and trusted HTTPS are healthy."

# Shrink/recreate the longhorn user-volume on one node to the configured maxSize.
# Talos never shrinks a user volume in place, so this applies a config with the
# volume removed (--mode=reboot, so p5 unmounts on the boot), wipes+drops
# nvme0n1p5, then applies the original config (--mode=reboot) so Talos reprovisions
# p5 at the configured size. Two reboots. Refuses unless the cluster is healthy and
# the rendered config targets 500GiB. Wipes ONLY nvme0n1p5; STATE, EPHEMERAL, and
# etcd are preserved. Run only while the volume is empty (pre-Longhorn or after a
# full replica evacuation). Verified on nuc1 2026-07-22.
[private]
_resize-longhorn-raw node:
    #!/usr/bin/env bash
    set -euo pipefail

    node='{{node}}'
    case "$node" in
      nuc1) node_ip='192.168.90.10' ;;
      nuc2) node_ip='192.168.90.11' ;;
      nuc3) node_ip='192.168.90.12' ;;
      *)
        echo 'Node must be one of: nuc1, nuc2, nuc3.' >&2
        exit 1
        ;;
    esac

    talosconfig='{{talosconfig}}'
    kubeconfig='{{kubeconfig}}'
    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    expected_names=$'nuc1\nnuc2\nnuc3'
    config="clusterconfig/${node}.yaml"
    partition='nvme0n1p5'
    expected_confirmation="resize-longhorn:${node}:${node_ip}"

    just repo require-bash
    for f in "$talosconfig" "$kubeconfig" "$config"; do
      [[ -f "$f" ]] || { echo "Missing $f; run just talos generate." >&2; exit 1; }
    done

    node_up() { talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" version >/dev/null 2>&1; }
    node_etcd_ok() { [[ "$(talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$nodes_csv" etcd members 2>/dev/null | awk 'NR > 1 && NF {c++} END {print c + 0}')" == '3' ]]; }
    node_ready() { [[ "$(kubectl --kubeconfig "$kubeconfig" get node "$node" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]]; }

    cluster_healthy() {
      local nodes_json ready names members member_count member_names alarms alarm_rows
      nodes_json="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json 2>/dev/null)" || return 1
      names="$(yq -r '.items[].metadata.name' - <<<"$nodes_json" | sort)"
      [[ "$names" == "$expected_names" ]] || return 1
      ready="$(yq -r '[.items[] | .status.conditions[] | select(.type == "Ready") | .status] | sort | join(" ")' - <<<"$nodes_json")"
      [[ "$ready" == 'True True True' ]] || return 1
      members="$(talosctl --talosconfig "$talosconfig" --nodes 192.168.90.10 --endpoints "$nodes_csv" etcd members 2>/dev/null)" || return 1
      member_count="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$members")"
      [[ "$member_count" == '3' ]] || return 1
      member_names="$(awk 'NR > 1 && NF {print $3}' <<<"$members" | sort)"
      [[ "$member_names" == "$expected_names" ]] || return 1
      alarms="$(talosctl --talosconfig "$talosconfig" --nodes "$nodes_csv" --endpoints "$nodes_csv" etcd alarm list 2>/dev/null)" || return 1
      alarm_rows="$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$alarms")"
      [[ "$alarm_rows" == '0' ]] || return 1
    }

    await_reboot() {
      local label="$1" i
      echo "  [$label] waiting for $node to drop..."
      for i in $(seq 1 45); do node_up || break; sleep 2; done
      echo "  [$label] waiting for $node talos API to return..."
      for i in $(seq 1 90); do node_up && break; sleep 5; done
      node_up || { echo "  [$label] $node talos API did not return." >&2; return 1; }
      echo "  [$label] waiting for etcd 3 members..."
      for i in $(seq 1 24); do node_etcd_ok && break; sleep 5; done
      node_etcd_ok || { echo "  [$label] etcd did not return to three members." >&2; return 1; }
      echo "  [$label] waiting for $node Ready..."
      for i in $(seq 1 36); do node_ready && break; sleep 5; done
      node_ready || { echo "  [$label] $node did not return to Ready." >&2; return 1; }
    }

    echo "=== pre-resize health gate ==="
    cluster_healthy || {
      echo "Refusing to resize $node: the cluster is not fully healthy." >&2
      exit 1
    }
    cfg_max="$(yq ea 'select(.kind == "UserVolumeConfig" and .name == "longhorn") | .provisioning.maxSize' "$config")"
    [[ "$cfg_max" == '500GiB' ]] || {
      echo "Refusing: $config u-longhorn maxSize='$cfg_max', expected '500GiB'." >&2
      exit 1
    }
    current_size="$(talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" get volumestatus u-longhorn --output jsonpath='{.spec.size}' 2>/dev/null || true)"
    echo "Cluster healthy. $node u-longhorn is currently ${current_size:-unknown} bytes; target 500GiB (536870912000)."

    [[ "${TALOS_RESIZE_LONGHORN_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing to resize the longhorn volume on $node (two reboots; wipes $partition)." >&2
      echo "Set TALOS_RESIZE_LONGHORN_CONFIRM='$expected_confirmation' and rerun after confirming the volume is empty (pre-Longhorn)." >&2
      exit 1
    }

    tmp="$(mktemp -d /tmp/homelab-talos-resize.XXXXXX)"
    trap 'rm -rf -- "$tmp"' EXIT
    yq ea 'select((.kind == "UserVolumeConfig" and .name == "longhorn") | not)' "$config" >"$tmp/released.yaml"
    talosctl validate --config "$tmp/released.yaml" --mode metal >/dev/null

    echo "=== 1/3 release: apply the volume-less config to $node (--mode=reboot) ==="
    talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" apply-config --file "$tmp/released.yaml" --mode=reboot
    await_reboot release
    [[ -z "$(talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" get volumestatus u-longhorn --output jsonpath='{.spec.phase}' 2>/dev/null)" ]] || {
      echo "Refusing to wipe: u-longhorn is still present on $node after the release reboot." >&2
      exit 1
    }

    echo "=== 2/3 wipe: drop $partition on $node (now unmounted) ==="
    talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" wipe disk "$partition" --drop-partition

    echo "=== 3/3 restore: apply the original config to $node (--mode=reboot) ==="
    talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" apply-config --file "$config" --mode=reboot
    await_reboot restore

    echo "=== verifying u-longhorn reprovisioned at ~500GiB with Secure Boot and TPM ==="
    volume_state="$(talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" get volumestatuses --output yaml)"
    lh_phase="$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.phase' - <<<"$volume_state")"
    lh_size="$(yq ea -r 'select(.metadata.id == "u-longhorn") | .spec.size' - <<<"$volume_state")"
    [[ "$lh_phase" == 'ready' ]] || {
      echo "$node u-longhorn is not ready after resize (phase=$lh_phase)." >&2
      exit 1
    }
    [[ "$lh_size" -gt 400000000000 && "$lh_size" -lt 600000000000 ]] || {
      echo "$node u-longhorn size $lh_size is not the expected ~500GiB after resize." >&2
      exit 1
    }
    security_state="$(talosctl --talosconfig "$talosconfig" --nodes "$node_ip" --endpoints "$node_ip" get securitystate --output yaml)"
    [[ "$(yq -r '.spec.secureBoot' - <<<"$security_state")" == 'true' ]] || {
      echo "$node did not report Secure Boot after resize." >&2
      exit 1
    }
    [[ "$(yq ea -r 'select(.metadata.id == "STATE") | [.spec.phase, .spec.encryptionProvider] | join(" ")' - <<<"$volume_state")" == 'ready luks2' ]]
    [[ "$(yq ea -r 'select(.metadata.id == "EPHEMERAL") | [.spec.phase, .spec.encryptionProvider] | join(" ")' - <<<"$volume_state")" == 'ready luks2' ]]
    echo "  u-longhorn: phase=$lh_phase size=$lh_size (~$((lh_size / 1024 / 1024 / 1024)) GiB)"

    echo "=== waiting for full cluster health ==="
    for _ in {1..24}; do cluster_healthy && break; sleep 5; done
    cluster_healthy || {
      echo "Cluster did not return to full health after the $node resize." >&2
      exit 1
    }
    just kube foundation-verify

    echo "Resize passed for $node: u-longhorn reprovisioned to ~500GiB, Secure Boot and TPM auto-unlock, three-member etcd, and foundation acceptance are healthy."

# Reconcile the private n8n platform in dependency order while keeping its public
# route suspended. On failure, re-suspend only the Kustomizations resumed here.
n8n:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_origin='https://github.com/supermorphic/homelab-talos.git'
    expected_confirmation='bootstrap:n8n'
    postgresql_ks='kubernetes/apps/automation/n8n-postgresql/ks.yaml'
    n8n_ks='kubernetes/apps/automation/n8n/ks.yaml'
    public_ks='kubernetes/apps/networking/public-webhook-gateway/ks.yaml'
    runtime_secret='kubernetes/apps/automation/n8n/app/n8n-runtime.sops.yaml'
    database_secret='kubernetes/apps/automation/n8n-postgresql/app/postgresql-credentials.sops.yaml'
    canary_secret='kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml'
    bootstrap_run_id="$(date -u +%Y%m%d%H%M%S)-$$"
    backup_job="n8n-backup-bootstrap-$bootstrap_run_id"
    backup_job_created=false
    resumed_postgresql=false
    resumed_n8n=false
    bootstrap_complete=false

    cleanup_n8n_bootstrap() {
      local original_exit="$?" cleanup_failed=false
      trap - EXIT
      if [[ "$bootstrap_complete" != 'true' ]]; then
        set +e
        if [[ "$backup_job_created" == 'true' ]]; then
          echo "n8n private acceptance did not pass; deleting run-owned Job automation/$backup_job." >&2
          kubectl --kubeconfig "$kubeconfig" --namespace automation delete job "$backup_job" \
            --ignore-not-found --wait=true --timeout=2m >/dev/null || cleanup_failed=true
          backup_job_absent || cleanup_failed=true
        fi
        if [[ "$resumed_n8n" == 'true' ]]; then
          echo 'n8n private acceptance did not pass; re-suspending n8n while preserving its resources and claim.' >&2
          flux suspend kustomization n8n --namespace flux-system \
            --kubeconfig "$kubeconfig" >/dev/null || cleanup_failed=true
        fi
        if [[ "$resumed_postgresql" == 'true' ]]; then
          echo 'n8n private acceptance did not pass; re-suspending n8n-postgresql while preserving its resources and claims.' >&2
          flux suspend kustomization n8n-postgresql --namespace flux-system \
            --kubeconfig "$kubeconfig" >/dev/null || cleanup_failed=true
        fi
        set -e
      fi
      if [[ "$cleanup_failed" == 'true' ]]; then
        echo 'Failed to remove the bootstrap Job or re-suspend every n8n Kustomization resumed by this invocation.' >&2
        exit 1
      fi
      exit "$original_exit"
    }
    backup_job_absent() {
      local resource
      resource="$(kubectl --kubeconfig "$kubeconfig" --namespace automation \
        get job "$backup_job" --ignore-not-found --output name)" || return 1
      [[ -z "$resource" ]]
    }
    report_backup_job_failure() {
      echo "Initial n8n backup Job automation/$backup_job did not complete." >&2
      kubectl --kubeconfig "$kubeconfig" --namespace automation get job "$backup_job" \
        --output json 2>/dev/null | yq -r '
          {
            "name": .metadata.name,
            "active": (.status.active // 0),
            "succeeded": (.status.succeeded // 0),
            "failed": (.status.failed // 0),
            "conditions": [.status.conditions[]? | {
              "type": .type,
              "status": .status,
              "reason": (.reason // "")
            }]
          }
        ' >&2 || true
      kubectl --kubeconfig "$kubeconfig" --namespace automation logs "job/$backup_job" \
        --container backup --tail=80 --limit-bytes=16384 --timestamps=true >&2 || true
    }
    wait_for_backup_job() {
      local deadline=$((SECONDS + 1800)) state
      while (( SECONDS < deadline )); do
        if ! state="$(kubectl --kubeconfig "$kubeconfig" --namespace automation \
          get job "$backup_job" --output json)"; then
          report_backup_job_failure
          return 1
        fi
        if [[ "$(yq -r '[.status.conditions[]? | select(
          .type == "Complete" and .status == "True") ] | length' <<<"$state")" == '1' ]]; then
          return 0
        fi
        if [[ "$(yq -r '[.status.conditions[]? | select(
          .type == "Failed" and .status == "True") ] | length' <<<"$state")" == '1' ]]; then
          report_backup_job_failure
          return 1
        fi
        sleep 5
      done
      report_backup_job_failure
      return 1
    }
    trap cleanup_n8n_bootstrap EXIT

    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
      exit 1
    }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
      echo "Refusing n8n bootstrap: origin must be $expected_origin." >&2
      exit 1
    }
    source scripts/lib/rollout.sh
    require_deployed_source 'n8n bootstrap' \
      .just/bootstrap.just kubernetes/mod.just tests/catalog.yaml \
      scripts/validate/n8n.sh scripts/verify/n8n.sh \
      scripts/lib/n8n-alert-activation.sh \
      scripts/test/scenarios/n8n-persistence.sh \
      scripts/test/scenarios/n8n-restore-drill.sh \
      tests/chainsaw/smoke/platform/n8n \
      kubernetes/apps/automation/n8n-postgresql \
      kubernetes/apps/automation/n8n \
      kubernetes/apps/networking/public-webhook-gateway \
      kubernetes/apps/monitoring/gatus/app \
      kubernetes/apps/monitoring/alerts/app/n8n.yaml \
      kubernetes/apps/security/alerts

    [[ "$(yq -r '.spec.suspend' "$postgresql_ks")" == 'true' && \
      "$(yq -r '.spec.suspend' "$n8n_ks")" == 'true' && \
      "$(yq ea -r 'select(.metadata.name == "public-webhook-route") | .spec.suspend' \
        "$public_ks")" == 'true' ]] || {
      echo 'Refusing n8n bootstrap: PostgreSQL, n8n, and the public route must be staged suspended in Git.' >&2
      exit 1
    }

    just kube n8n-validate
    just kube alerts-validate monitoring
    just kube alerts-validate security

    for secret in "$runtime_secret" "$database_secret" "$canary_secret"; do
      git cat-file -e "origin/main:$secret" 2>/dev/null || {
        echo "Refusing n8n bootstrap: deployed Git does not contain $secret." >&2
        exit 1
      }
    done
    yq -e '.resources[] | select(. == "./n8n-runtime.sops.yaml")' \
      kubernetes/apps/automation/n8n/app/kustomization.yaml >/dev/null
    yq -e '.resources[] | select(. == "./postgresql-credentials.sops.yaml")' \
      kubernetes/apps/automation/n8n-postgresql/app/kustomization.yaml >/dev/null
    yq -e '.resources[] | select(. == "./n8n-canary.sops.yaml")' \
      kubernetes/apps/monitoring/gatus/app/kustomization.yaml >/dev/null

    [[ "${N8N_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the private n8n platform.' >&2
      echo "Set N8N_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing the staged source and encrypted recovery unit." >&2
      exit 1
    }

    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    remote_main="$(git rev-parse origin/main)"
    deployed_revision="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
      get gitrepository flux-system --output jsonpath='{.status.artifact.revision}')"
    [[ "$deployed_revision" == *"$remote_main"* ]] || {
      echo "Refusing n8n bootstrap: Flux revision $deployed_revision does not match origin/main $remote_main." >&2
      exit 1
    }
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source \
      --kubeconfig "$kubeconfig" --timeout 10m

    for name in n8n-postgresql n8n public-webhook-route; do
      [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
        get kustomization "$name" --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
        echo "Refusing n8n bootstrap: $name is not suspended in the live cluster." >&2
        exit 1
      }
    done
    public_route_resource="$(kubectl --kubeconfig "$kubeconfig" \
      --namespace networking-public get httproute n8n-platform-canary \
      --ignore-not-found --output name)"
    [[ -z "$public_route_resource" ]] || {
      echo 'Refusing private n8n bootstrap: the public Platform Canary route already exists.' >&2
      exit 1
    }

    echo 'Reconciling the private public-webhook-gateway foundation.'
    flux reconcile kustomization public-webhook-gateway --namespace flux-system \
      --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/public-webhook-gateway --timeout=15m

    echo 'Reconciling n8n-postgresql.'
    resumed_postgresql=true
    flux resume kustomization n8n-postgresql --namespace flux-system \
      --kubeconfig "$kubeconfig"
    flux reconcile kustomization n8n-postgresql --namespace flux-system \
      --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/n8n-postgresql --timeout=15m

    echo 'Reconciling n8n.'
    resumed_n8n=true
    flux resume kustomization n8n --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization n8n --namespace flux-system --with-source \
      --kubeconfig "$kubeconfig" --timeout 20m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/n8n --timeout=20m

    backup_job_absent || {
      echo "Refusing n8n bootstrap: automation/$backup_job exists or its absence cannot be proved." >&2
      exit 1
    }
    echo 'Creating the first validated logical backup from the reconciled CronJob.'
    backup_job_created=true
    kubectl --kubeconfig "$kubeconfig" --namespace automation create job "$backup_job" \
      --from=cronjob/n8n-postgresql-backup --dry-run=client --output yaml | \
      BOOTSTRAP_RUN_ID="$bootstrap_run_id" yq '
        .metadata.labels."app.kubernetes.io/name" = "n8n-postgresql-backup" |
        .metadata.labels."homelab-talos/test" = "n8n-bootstrap" |
        .metadata.labels."homelab-talos/run-id" = strenv(BOOTSTRAP_RUN_ID) |
        .metadata.labels."homelab-talos/role" = "initial-backup" |
        .spec.template.metadata.labels = .metadata.labels
      ' | kubectl --kubeconfig "$kubeconfig" --namespace automation create \
        --filename - >/dev/null
    wait_for_backup_job "$backup_job"
    kubectl --kubeconfig "$kubeconfig" --namespace automation delete job "$backup_job" \
      --wait=true --timeout=2m >/dev/null
    backup_job_absent || {
      echo "Failed to remove run-owned Job automation/$backup_job." >&2
      exit 1
    }
    backup_job_created=false

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
      get kustomization public-webhook-route --output jsonpath='{.spec.suspend}')" == \
      'true' ]] || {
      echo 'The public webhook route became active during private bootstrap.' >&2
      exit 1
    }
    N8N_VERIFY_MODE=private just kube n8n-verify

    bootstrap_complete=true
    trap - EXIT
    cat <<'EOF'
    n8n private platform acceptance passed. The public webhook route is still suspended.
    The first checksum-validated logical backup completed and its freshness metric is current.

    Complete these attended steps through https://n8n.lab.supermorphic.com/:
    1. Create the one owner account in the private UI.
    2. Import kubernetes/apps/automation/n8n/app/workflows/platform-canary.json.
    3. Create one Header Auth credential named "Platform Canary Header" with header name
       "X-Platform-Canary" and the operator-held N8N_CANARY_TOKEN value.
    4. Bind that credential to the imported Webhook node. Do not place the value in the
       workflow JSON, Git, shell history, or command output.
    5. Publish the Platform Canary workflow.
    6. Execute one authenticated request privately, then immediately open its returned
       execution ID in execution history. Require status Succeeded and the same correlation.

    Stop here. Public DNS, router TCP/443 forwarding, route activation, and Gatus activation
    are separate reviewed operator steps. Durable suspend:false changes must go through Git.
    EOF

# Reconcile the staged automation-data PostgreSQL platform, create its first validated
# logical backup, and leave n8n workflow and credential setup to the attended UI.
automation-data:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_origin='https://github.com/supermorphic/homelab-talos.git'
    expected_confirmation='bootstrap:automation-data'
    postgresql_ks='kubernetes/apps/automation-data/postgresql/ks.yaml'
    database_secret='kubernetes/apps/automation-data/postgresql/app/postgresql-credentials.sops.yaml'
    bootstrap_run_id="$(date -u +%Y%m%d%H%M%S)-$$"
    backup_job="automation-data-backup-bootstrap-$bootstrap_run_id"
    backup_job_created=false
    resumed_postgresql=false
    bootstrap_complete=false

    backup_job_absent() {
      local resource
      resource="$(kubectl --kubeconfig "$kubeconfig" --namespace automation-data \
        get job "$backup_job" --ignore-not-found --output name)" || return 1
      [[ -z "$resource" ]]
    }
    report_backup_job_failure() {
      echo "Initial automation-data backup Job automation-data/$backup_job did not complete." >&2
      kubectl --kubeconfig "$kubeconfig" --namespace automation-data get job "$backup_job" \
        --output json 2>/dev/null | yq -r '
          {
            "name": .metadata.name,
            "active": (.status.active // 0),
            "succeeded": (.status.succeeded // 0),
            "failed": (.status.failed // 0),
            "conditions": [.status.conditions[]? | {
              "type": .type,
              "status": .status,
              "reason": (.reason // "")
            }]
          }
        ' >&2 || true
      kubectl --kubeconfig "$kubeconfig" --namespace automation-data logs \
        "job/$backup_job" --container backup --tail=80 --limit-bytes=16384 \
        --timestamps=true >&2 || true
    }
    wait_for_backup_job() {
      local deadline=$((SECONDS + 1800)) state
      while (( SECONDS < deadline )); do
        if ! state="$(kubectl --kubeconfig "$kubeconfig" --namespace automation-data \
          get job "$backup_job" --output json)"; then
          report_backup_job_failure
          return 1
        fi
        if [[ "$(yq -r '[.status.conditions[]? | select(
          .type == "Complete" and .status == "True") ] | length' <<<"$state")" == '1' ]]; then
          return 0
        fi
        if [[ "$(yq -r '[.status.conditions[]? | select(
          .type == "Failed" and .status == "True") ] | length' <<<"$state")" == '1' ]]; then
          report_backup_job_failure
          return 1
        fi
        sleep 5
      done
      report_backup_job_failure
      return 1
    }
    cleanup_automation_data_bootstrap() {
      local original_exit="$?" cleanup_failed=false
      trap - EXIT
      if [[ "$bootstrap_complete" != 'true' ]]; then
        set +e
        if [[ "$backup_job_created" == 'true' ]]; then
          echo "automation-data acceptance did not pass; deleting run-owned Job automation-data/$backup_job." >&2
          kubectl --kubeconfig "$kubeconfig" --namespace automation-data delete job \
            "$backup_job" --ignore-not-found --wait=true --timeout=2m >/dev/null || \
            cleanup_failed=true
          backup_job_absent || cleanup_failed=true
        fi
        if [[ "$resumed_postgresql" == 'true' ]]; then
          echo 'automation-data acceptance did not pass; re-suspending automation-data-postgresql while preserving its resources and claims.' >&2
          flux suspend kustomization automation-data-postgresql --namespace flux-system \
            --kubeconfig "$kubeconfig" >/dev/null || cleanup_failed=true
        fi
        set -e
      fi
      if [[ "$cleanup_failed" == 'true' ]]; then
        echo 'Failed to remove the bootstrap Job or re-suspend automation-data-postgresql.' >&2
        exit 1
      fi
      exit "$original_exit"
    }
    trap cleanup_automation_data_bootstrap EXIT

    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
      exit 1
    }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
      echo "Refusing automation-data bootstrap: origin must be $expected_origin." >&2
      exit 1
    }
    source scripts/lib/rollout.sh
    require_deployed_source 'automation-data bootstrap' \
      .just/bootstrap.just kubernetes/mod.just tests/catalog.yaml \
      scripts/validate/automation-data.sh scripts/verify/automation-data.sh \
      scripts/test/scenarios/automation-data-provisioning.sh \
      scripts/test/scenarios/automation-data-restore-drill.sh \
      scripts/test/lib/automation-data-restore-command.sh \
      kubernetes/apps/automation-data \
      kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json \
      kubernetes/apps/automation/n8n/app/workflows/automation-data-recovery-canary.json \
      kubernetes/apps/monitoring/alerts/app/automation-data.yaml

    [[ "$(yq -r '.spec.suspend' "$postgresql_ks")" == 'true' ]] || {
      echo 'Refusing automation-data bootstrap: PostgreSQL must be staged suspended in Git.' >&2
      exit 1
    }
    just kube automation-data-validate
    just kube alerts-validate monitoring
    git cat-file -e "origin/main:$database_secret" 2>/dev/null || {
      echo "Refusing automation-data bootstrap: deployed Git does not contain $database_secret." >&2
      exit 1
    }
    yq -e '.resources[] | select(. == "./postgresql-credentials.sops.yaml")' \
      kubernetes/apps/automation-data/postgresql/app/kustomization.yaml >/dev/null

    [[ "${AUTOMATION_DATA_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to reconcile the automation-data PostgreSQL platform.' >&2
      echo "Set AUTOMATION_DATA_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing the staged source and encrypted recovery material." >&2
      exit 1
    }

    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    remote_main="$(git rev-parse origin/main)"
    deployed_revision="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
      get gitrepository flux-system --output jsonpath='{.status.artifact.revision}')"
    [[ "$deployed_revision" == *"$remote_main"* ]] || {
      echo "Refusing automation-data bootstrap: Flux revision $deployed_revision does not match origin/main $remote_main." >&2
      exit 1
    }
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source \
      --kubeconfig "$kubeconfig" --timeout 10m

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
      get kustomization automation-data-postgresql \
      --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo 'Refusing automation-data bootstrap: automation-data-postgresql is not suspended in the live cluster.' >&2
      exit 1
    }

    echo 'Reconciling the automation-data namespace.'
    flux reconcile kustomization automation-data --namespace flux-system --with-source \
      --kubeconfig "$kubeconfig" --timeout 10m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/automation-data --timeout=10m

    echo 'Reconciling automation-data-postgresql.'
    resumed_postgresql=true
    flux resume kustomization automation-data-postgresql --namespace flux-system \
      --kubeconfig "$kubeconfig"
    flux reconcile kustomization automation-data-postgresql --namespace flux-system \
      --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
      --for=condition=Ready kustomization/automation-data-postgresql --timeout=15m

    backup_job_absent || {
      echo "Refusing automation-data bootstrap: automation-data/$backup_job exists or its absence cannot be proved." >&2
      exit 1
    }
    echo 'Creating the first validated automation-data logical backup from the reconciled CronJob.'
    backup_job_created=true
    kubectl --kubeconfig "$kubeconfig" --namespace automation-data create job \
      "$backup_job" --from=cronjob/automation-data-postgresql-backup \
      --dry-run=client --output yaml | \
      BOOTSTRAP_RUN_ID="$bootstrap_run_id" yq '
        .metadata.labels."app.kubernetes.io/name" = "automation-data-postgresql-backup" |
        .metadata.labels."homelab-talos/test" = "automation-data-bootstrap" |
        .metadata.labels."homelab-talos/run-id" = strenv(BOOTSTRAP_RUN_ID) |
        .metadata.labels."homelab-talos/role" = "initial-backup" |
        .spec.template.metadata.labels = .metadata.labels
      ' | kubectl --kubeconfig "$kubeconfig" --namespace automation-data create \
        --filename - >/dev/null
    wait_for_backup_job
    kubectl --kubeconfig "$kubeconfig" --namespace automation-data delete job \
      "$backup_job" --wait=true --timeout=2m >/dev/null
    backup_job_absent || {
      echo "Failed to remove run-owned Job automation-data/$backup_job." >&2
      exit 1
    }
    backup_job_created=false

    just kube automation-data-verify

    bootstrap_complete=true
    trap - EXIT
    cat <<'EOF'
    automation-data PostgreSQL acceptance passed. The first complete logical backup is
    current, and PostgreSQL remains private. Complete these attended steps in the private
    n8n UI without sending any credential value to an agent or placing it in Git:

    1. Create a Postgres credential named "Automation Data Provisioner" for database
       automation_data_control and login automation_data_provisioner. Use the same
       operator-held provisioner password represented by the encrypted PostgreSQL Secret.
    2. Create one full-access Community-edition n8n API key. Store it in a Header Auth
       credential named "Automation Data n8n API" with header X-N8N-API-KEY.
    3. Create a separate Header Auth credential named
       "Automation Data Provisioning Header" with header
       X-Automation-Data-Provisioning. Retain its private value outside Git.
    4. Import automation-data-provisioner.json. Bind the three credentials exactly as its
       setup note specifies, then publish the provisioning workflow.
    5. Run the attended provisioning test. It creates issue317_acceptance and the scoped
       n8n migrator/runtime credentials without returning either generated password.
    6. Import automation-data-recovery-canary.json. Bind Platform Canary Header to its
       Webhook and automation-data/issue317_acceptance/runtime to its Postgres node, then
       publish it.
    7. Run the full-chain restore drill only after a later complete n8n dump and
       automation-data bundle include those published bindings.

    Durable suspend:false changes remain Git-managed. Do not activate a destructive
    database or role decommission path as part of this bootstrap.
    EOF
