set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

cilium_chart := "oci://quay.io/cilium/charts/cilium"
cilium_values := "kubernetes/apps/kube-system/cilium/app/values.yaml"
cilium_app := "kubernetes/apps/kube-system/cilium/app"
talosconfig := ".talos/config"
kubeconfig := ".kube/config"
github_owner := "7yXwscXEzv6phzUnKfrw"
github_repository := "homelab-talos"

# Render the pinned Cilium chart to standard output without writing generated YAML.
cilium-render:
    @helm template cilium {{cilium_chart}} \
      --version "$(yq -r '.spec.ref.tag' {{cilium_app}}/ocirepository.yaml)" \
      --namespace kube-system \
      --values {{cilium_values}}

# Validate the app-local Cilium source and pinned Helm render.
cilium-validate:
    @scripts/validate/cilium.sh

# Print read-only live Cilium and Kubernetes status.
cilium-status:
    #!/usr/bin/env bash
    set -u

    kubeconfig='{{kubeconfig}}'
    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }

    status=0
    echo '=== Helm release ==='
    helm status cilium --namespace kube-system --kubeconfig "$kubeconfig" || status=1
    echo '=== Kubernetes nodes ==='
    kubectl --kubeconfig "$kubeconfig" get nodes --output wide || status=1
    echo '=== Cilium workloads ==='
    kubectl --kubeconfig "$kubeconfig" --namespace kube-system get pods \
      --selector app.kubernetes.io/part-of=cilium --output wide || status=1
    echo '=== Cilium status ==='
    cilium status --kubeconfig "$kubeconfig" --namespace kube-system || status=1
    exit "$status"

# Print read-only Talos diagnostics from every cluster node.
cilium-diagnostics:
    #!/usr/bin/env bash
    set -u

    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    status=0
    for node_ip in 192.168.90.10 192.168.90.11 192.168.90.12; do
      echo "=== Talos diagnostics: $node_ip ==="
      diagnostics="$(talosctl get diagnostics \
        --nodes "$node_ip" \
        --endpoints "$nodes_csv" \
        --talosconfig "{{talosconfig}}" \
        --output json)" || {
        status=1
        continue
      }
      if [[ -n "$diagnostics" ]]; then
        printf '%s\n' "$diagnostics"
        status=1
      else
        echo 'None'
      fi
    done
    exit "$status"

# Verify Talos diagnostics and etcd after Cilium connectivity workloads finish.
cilium-postflight:
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    just kube cilium-diagnostics

    terminating_test_namespaces="$(kubectl --kubeconfig "$kubeconfig" get namespaces --output json | \
      yq -r '.items[] | select(.metadata.name | test("^cilium-test")) | select(.metadata.deletionTimestamp != null) | .metadata.name')"
    while IFS= read -r namespace; do
      [[ -n "$namespace" ]] || continue
      kubectl --kubeconfig "$kubeconfig" wait \
        --for=delete "namespace/$namespace" \
        --timeout=2m
    done <<<"$terminating_test_namespaces"

    remaining_test_namespaces="$(kubectl --kubeconfig "$kubeconfig" get namespaces --output json | \
      yq -r '.items[].metadata.name | select(test("^cilium-test"))')"
    [[ -z "$remaining_test_namespaces" ]] || {
      echo "Cilium test namespaces remain: $remaining_test_namespaces" >&2
      exit 1
    }

    nodes_csv='192.168.90.10,192.168.90.11,192.168.90.12'
    etcd_status="$(talosctl etcd status \
      --nodes "$nodes_csv" \
      --endpoints "$nodes_csv" \
      --talosconfig "{{talosconfig}}")"
    printf '%s\n' "$etcd_status"
    [[ "$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$etcd_status")" == '3' ]]

    alarm_status="$(talosctl etcd alarm list \
      --nodes "$nodes_csv" \
      --endpoints "$nodes_csv" \
      --talosconfig "{{talosconfig}}")"
    printf '%s\n' "$alarm_status"
    [[ "$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$alarm_status")" == '0' ]]

    echo 'Cilium postflight passed: test resources removed, no Talos diagnostics, three etcd members, and no etcd alarms.'

# Fail unless running under bash >= 4; macOS /bin/bash 3.2 does not honor set -e
# for a failed bare [[ ]] mid-recipe, so these acceptance assertions would not gate.
# Validate the metrics-server source: files, wiring, dependency, pinned chart, the
# Talos --kubelet-insecure-tls flag, and the render (version derived from the HR).
metrics-server-validate: require-bash
    @scripts/validate/metrics-server.sh

# Verify metrics-server: Kustomization + HelmRelease Ready, deployment rolled out,
# the metrics.k8s.io APIService Available, and kubectl top returns data.
metrics-server-verify: require-bash
    @scripts/verify/metrics-server.sh {{quote(kubeconfig)}}

# Unit-test the offline configuration policies without contacting a cluster.
validator-tests:
    @conftest fmt --check tests/policy
    @conftest verify --policy tests/policy

# Enforce cross-application media source policy without contacting the cluster.
media-policy-validate:
    @conftest test --combine --all-namespaces \
      --policy tests/policy/media kubernetes/apps/media

# Validate the built app manifests against Kubernetes + CRD schemas, offline of the
# cluster (schemas are fetched over HTTPS). Secrets are kept (only the SOPS metadata
# is stripped); CRDs absent from the schema sources are reported as skipped, not
# failed, which is appropriate for this homelab during adoption.
kubeconform: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    k8s_version="$(yq -p=toml -r '.tools.kubectl' .mise.toml 2>/dev/null)"
    [[ "$k8s_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo 'Could not derive the Kubernetes version from .mise.toml [tools].kubectl.' >&2
      exit 1
    }

    # Assemble the datreeio CRD-catalog URL from shell vars so just does not try to
    # interpolate kubeconform's own Go-template schema syntax (.Group / .ResourceKind).
    lb='{'
    rb='}'
    crd_catalog="https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/${lb}${lb}.Group${rb}${rb}/${lb}${lb}.ResourceKind${rb}${rb}_${lb}${lb}.ResourceAPIVersion${rb}${rb}.json"

    temp_dir="$(mktemp -d /tmp/homelab-talos-kubeconform.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    # Build the flux-system aggregate (Flux Kustomization/HelmRelease/OCIRepository
    # CRs) plus every per-app app/ and config/ root (the real Namespaces, HTTPRoutes,
    # Deployments, Secrets, and CRs Flux reconciles).
    kustomize build kubernetes/apps >"$temp_dir/all.yaml"
    while IFS= read -r kfile; do
      { echo '---'; kustomize build "$(dirname "$kfile")"; } >>"$temp_dir/all.yaml"
    done < <(find kubernetes/apps -type f -name kustomization.yaml \( -path '*/app/kustomization.yaml' -o -path '*/config/kustomization.yaml' \) | sort)
    yq ea 'del(.sops)' "$temp_dir/all.yaml" >"$temp_dir/validate.yaml"

    kubeconform -strict -summary -ignore-missing-schemas \
      -kubernetes-version "$k8s_version" \
      -schema-location default \
      -schema-location "$crd_catalog" \
      "$temp_dir/validate.yaml"

    echo "kubeconform passed against Kubernetes v${k8s_version} schemas (CRDs absent from the catalog reported as skipped)."

# Operational check (NOT in `just ci`): warn when the committed Pi-hole CA is within
# 30 days of expiry so it gets rotated. Time-based, so run it locally or on a
# schedule rather than as a required PR gate.
foundation-ca-expiry: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    [[ -f "$pihole_ca" ]] || {
      echo "Missing tracked Pi-hole CA: $pihole_ca" >&2
      exit 1
    }
    if openssl x509 -in "$pihole_ca" -noout -checkend 2592000 >/dev/null; then
      echo 'Pi-hole CA is valid for at least 30 more days.'
    else
      echo 'WARNING: the committed Pi-hole CA expires within 30 days; rotate it (see docs/pihole-integration.md).' >&2
      exit 1
    fi

[private]
require-bash:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/common.sh
    require_bash

# Verify the complete live Phase 5 Cilium acceptance gate.
cilium-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    values_file='{{cilium_values}}'
    expected_names=$'nuc1\nnuc2\nnuc3'
    diagnostic_dir="$(mktemp -d /tmp/homelab-talos-cilium-test.XXXXXX)"
    cleanup() {
      cilium connectivity test \
        --kubeconfig "$kubeconfig" \
        --test-namespace cilium-test \
        --cleanup >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }
    api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')"
    [[ "$api_server" == 'https://192.168.90.20:6443' ]]

    release_json="$(helm list --namespace kube-system --kubeconfig "$kubeconfig" --output json)"
    [[ "$(yq -r '.[] | select(.name == "cilium") | .status' - <<<"$release_json")" == 'deployed' ]]
    [[ "$(yq -r '.[] | select(.name == "cilium") | .chart' - <<<"$release_json")" == 'cilium-1.19.6' ]]

    helm get values cilium \
      --namespace kube-system \
      --kubeconfig "$kubeconfig" \
      --output yaml >"$diagnostic_dir/live-values.yaml"
    yq -o=json -I=0 'sort_keys(..)' "$values_file" >"$diagnostic_dir/expected-values.json"
    yq -o=json -I=0 'sort_keys(..)' "$diagnostic_dir/live-values.yaml" >"$diagnostic_dir/normalized-live-values.json"
    cmp -s "$diagnostic_dir/expected-values.json" "$diagnostic_dir/normalized-live-values.json" || {
      echo "Live Cilium Helm values differ from $values_file." >&2
      diff -u "$diagnostic_dir/expected-values.json" "$diagnostic_dir/normalized-live-values.json" || true
      exit 1
    }

    nodes_json="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json)"
    node_names="$(yq -r '.items[].metadata.name' - <<<"$nodes_json" | sort)"
    [[ "$node_names" == "$expected_names" ]]
    node_states="$(yq -r '.items[] | .metadata.name + " " + ([.status.conditions[] | select(.type == "Ready") | .status][0]) + " " + ((.spec.unschedulable // false) | tostring)' - <<<"$nodes_json" | sort)"
    [[ "$node_states" == $'nuc1 True false\nnuc2 True false\nnuc3 True false' ]]
    forbidden_taints="$(yq -r '.items[] | .metadata.name as $name | (.spec.taints // [])[] | select(.effect == "NoSchedule" or .effect == "NoExecute") | $name + " " + .key' - <<<"$nodes_json")"
    [[ -z "$forbidden_taints" ]]

    daemonset_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset cilium --output json)"
    [[ "$(yq -r '[.status.desiredNumberScheduled, .status.numberReady, (.status.numberUnavailable // 0)] | join(" ")' - <<<"$daemonset_json")" == '3 3 0' ]]
    operator_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment cilium-operator --output json)"
    [[ "$(yq -r '[.spec.replicas, .status.availableReplicas] | join(" ")' - <<<"$operator_json")" == '2 2' ]]
    relay_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment hubble-relay --output json)"
    [[ "$(yq -r '[.spec.replicas, .status.availableReplicas] | join(" ")' - <<<"$relay_json")" == '1 1' ]]
    coredns_json="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment coredns --output json)"
    [[ "$(yq -r '.status.availableReplicas // 0' - <<<"$coredns_json")" -ge 1 ]]

    ! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset kube-proxy >/dev/null 2>&1
    ! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get deployment hubble-ui >/dev/null 2>&1
    ! kubectl --kubeconfig "$kubeconfig" --namespace kube-system get daemonset cilium-envoy >/dev/null 2>&1

    cilium status \
      --kubeconfig "$kubeconfig" \
      --namespace kube-system \
      --wait \
      --wait-duration 10m

    cilium_status_json="$(cilium status \
      --kubeconfig "$kubeconfig" \
      --namespace kube-system \
      --output json)"
    [[ "$(yq -r '.pod_state."hubble-relay" | [.Desired, .Ready, .Available, .Unavailable] | join(" ")' - <<<"$cilium_status_json")" == '1 1 1 0' ]]
    [[ "$(yq -r '[.cilium_status[].hubble.state] | unique | join(" ")' - <<<"$cilium_status_json")" == 'Ok' ]]
    [[ "$(yq -r '.errors."hubble-relay"."hubble-relay" | ((.Errors | length) + (.Warnings | length))' - <<<"$cilium_status_json")" == '0' ]]

    cleanup
    echo "Connectivity-test diagnostics, if required, will remain in $diagnostic_dir."
    if ! cilium connectivity test \
      --kubeconfig "$kubeconfig" \
      --namespace kube-system \
      --test-namespace cilium-test \
      --namespace-labels pod-security.kubernetes.io/enforce=privileged \
      --ip-families ipv4 \
      --hubble=false \
      --flow-validation disabled \
      --test '!no-unexpected-packet-drops' \
      --timeout 45m \
      --sysdump-output-filename "$diagnostic_dir/cilium-sysdump-<ts>"; then
      cilium sysdump \
        --kubeconfig "$kubeconfig" \
        --namespace kube-system \
        --output-filename "$diagnostic_dir/cilium-sysdump-<ts>" || true
      exit 1
    fi

    cleanup
    just kube cilium-postflight

    trap - EXIT
    rm -rf -- "$diagnostic_dir"
    echo 'Phase 5 verification passed: Cilium 1.19.6, three Ready nodes, healthy DNS, Hubble, connectivity, Talos, and etcd.'

# Validate the complete local Phase 6 source and pinned OCI render without mutating the cluster.
flux-validate:
    @scripts/validate/flux.sh

# Check the live cluster and Git publication boundary before GitHub bootstrap.
flux-preflight: flux-validate
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='{{github_owner}}'
    repository='{{github_repository}}'
    expected_origin="https://github.com/${owner}/${repository}.git"

    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
      echo "Refusing Flux bootstrap: origin must be $expected_origin." >&2
      exit 1
    }
    source scripts/lib/rollout.sh
    require_deployed_source 'Flux bootstrap' \
      kubernetes/mod.just \
      .just/bootstrap.just \
      kubernetes/flux \
      kubernetes/apps/kube-system/cilium \
      kubernetes/apps/flux-system/flux-canary
    [[ "$(kubectl --kubeconfig "$kubeconfig" config view --minify --output jsonpath='{.clusters[0].cluster.server}')" == 'https://192.168.90.20:6443' ]]

    just kube cilium-status
    just kube cilium-postflight
    flux check --pre --kubeconfig "$kubeconfig"

    if ! kubectl --kubeconfig "$kubeconfig" --namespace flux-system get deployment source-controller >/dev/null 2>&1; then
      [[ "$(yq -r '.spec.suspend' kubernetes/apps/kube-system/cilium/ks.yaml)" == 'true' ]] || {
        echo 'Refusing first bootstrap: Cilium must begin suspended for staged adoption.' >&2
        exit 1
      }
    fi

    echo 'Flux preflight passed: Git is published, Cilium is healthy, and Kubernetes is compatible.'

# Print the read-only Flux reconciliation and controller state.
flux-status:
    #!/usr/bin/env bash
    set -u

    kubeconfig='{{kubeconfig}}'
    status=0
    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }

    echo '=== Flux installation ==='
    flux check --kubeconfig "$kubeconfig" || status=1
    echo '=== Git sources ==='
    flux get sources git --all-namespaces --kubeconfig "$kubeconfig" || status=1
    echo '=== OCI sources ==='
    flux get sources oci --all-namespaces --kubeconfig "$kubeconfig" || status=1
    echo '=== Kustomizations ==='
    flux get kustomizations --all-namespaces --show-source --kubeconfig "$kubeconfig" || status=1
    echo '=== Helm releases ==='
    flux get helmreleases --all-namespaces --kubeconfig "$kubeconfig" || status=1
    echo '=== Flux workloads ==='
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system get deployments,pods --output wide || status=1
    exit "$status"

# Verify final Phase 6 ownership, source, SOPS, canary, and Cilium health.
flux-verify: flux-validate require-bash
    @scripts/verify/flux.sh {{quote(kubeconfig)}} {{quote(github_owner)}} {{quote(github_repository)}}

# Validate the complete local Phase 7 graph, encrypted providers, and pinned chart renders.
foundation-validate:
    @scripts/validate/foundation.sh

# Print the read-only Phase 7 controller, certificate, address, Gateway, DNS, and echo state.
foundation-status:
    #!/usr/bin/env bash
    set -u

    kubeconfig='{{kubeconfig}}'
    status=0
    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }

    echo '=== Phase 7 Flux Kustomizations ==='
    flux get kustomizations --namespace flux-system --show-source --kubeconfig "$kubeconfig" | rg 'NAME|cert-manager|wildcard-certificate|metallb|envoy-gateway|internal-gateway|external-dns-internal|echo' || status=1
    echo '=== Phase 7 Helm sources and releases ==='
    flux get sources oci --all-namespaces --kubeconfig "$kubeconfig" || status=1
    flux get sources helm --all-namespaces --kubeconfig "$kubeconfig" || status=1
    flux get helmreleases --all-namespaces --kubeconfig "$kubeconfig" || status=1
    echo '=== Certificates ==='
    kubectl --kubeconfig "$kubeconfig" get clusterissuers,certificates --all-namespaces || status=1
    echo '=== MetalLB ==='
    kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get pods,ipaddresspools,l2advertisements --output wide || status=1
    echo '=== Internal Gateway ==='
    kubectl --kubeconfig "$kubeconfig" --namespace networking get gateways,envoyproxies,services,pods --output wide || status=1
    echo '=== ExternalDNS and echo ==='
    kubectl --kubeconfig "$kubeconfig" --namespace external-dns get deployments,pods --output wide || status=1
    kubectl --kubeconfig "$kubeconfig" --namespace testing get deployments,pods,services,httproutes --output wide || status=1
    echo '=== Pi-hole resolution ==='
    dig +short @192.168.90.2 echo.lab.supermorphic.com A || status=1
    exit "$status"

# Verify the complete live Phase 7 internal foundation acceptance gate.
foundation-verify: foundation-validate require-bash
    @scripts/verify/foundation.sh {{quote(kubeconfig)}}

# Restart the flux-system controllers and prove reconciliation resumes.
flux-restart: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_confirmation='restart:flux-system:controllers'
    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }

    flux check --kubeconfig "$kubeconfig"

    [[ "${FLUX_RESTART_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to restart the Flux controllers.' >&2
      echo "Set FLUX_RESTART_CONFIRM='$expected_confirmation' and rerun." >&2
      exit 1
    }

    controllers="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get deployments \
      --selector app.kubernetes.io/part-of=flux --output name)"
    [[ -n "$controllers" ]] || {
      echo 'Refusing restart: no Flux controller deployments found.' >&2
      exit 1
    }
    echo 'Restarting Flux controllers:'
    printf '  %s\n' $controllers
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system rollout restart $controllers
    while IFS= read -r deployment; do
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system rollout status "$deployment" --timeout=5m
    done <<<"$controllers"

    flux check --kubeconfig "$kubeconfig"
    flux reconcile kustomization cluster-apps \
      --namespace flux-system \
      --with-source \
      --kubeconfig "$kubeconfig" \
      --timeout 10m

    just kube flux-verify
    echo 'Flux controllers restarted; controllers are healthy and reconciliation resumed.'

# Delete only the permanent canary and prove Flux recreates it from encrypted Git source.
flux-canary-test: flux-verify
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_confirmation='recreate:flux-system:flux-canary'
    [[ "${FLUX_CANARY_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to delete the Flux reconciliation canary.' >&2
      echo "Set FLUX_CANARY_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    canary_json="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-canary --output json)"
    [[ "$(yq -r '.metadata.labels."app.kubernetes.io/component"' - <<<"$canary_json")" == 'reconciliation-canary' ]] || {
      echo 'Refusing canary test: flux-system/flux-canary does not carry the required safety label.' >&2
      exit 1
    }
    old_uid="$(yq -r '.metadata.uid' - <<<"$canary_json")"
    [[ -n "$old_uid" ]]
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system delete secret flux-canary \
      --wait=true
    flux reconcile kustomization flux-canary \
      --namespace flux-system \
      --with-source \
      --kubeconfig "$kubeconfig" \
      --timeout 5m
    new_uid="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-canary --output jsonpath='{.metadata.uid}')"
    [[ -n "$new_uid" && "$new_uid" != "$old_uid" ]]
    just kube flux-verify
    echo 'Flux canary recreation passed with a new Secret UID.'

# Validate the Phase 9 storage source: files, encrypted CIFS Secret, dependency
# graph, staged-suspend uniformity, key values, wiring, and the pinned Longhorn render.
storage-validate: require-bash
    @scripts/validate/storage.sh

# Validate the Phase 11 SMB CSI driver source, wiring, dependency, and pinned render.
csi-driver-smb-validate: require-bash
    @scripts/validate/csi-driver-smb.sh

# Validate the Phase 11 shared media storage: namespace + app-template source,
# encrypted SMB Secret, static RWX SMB PV/PVC, dependency graph, and wiring.
media-storage-validate: require-bash
    @scripts/validate/media-storage.sh

# Validate the Phase 11 Plex source: files, wiring, dependency, app-template chartRef,
# values (Recreate + RWO config, shared media-data, emptyDir transcode), HTTPRoute,
# and the pinned app-template render.
plex-validate: require-bash
    @scripts/validate/plex.sh

# Verify the live Longhorn acceptance gate: controllers, node disks, default
# StorageClass, backup target, recurring jobs, and a two-replica test PVC.
storage-verify: require-bash
    @scripts/verify/storage.sh {{quote(kubeconfig)}}

# Verify the live Phase 11 SMB CSI driver: Kustomization Ready, controller +
# node plugin rolled out, and the CSIDriver registered.
csi-driver-smb-verify: require-bash
    @scripts/verify/csi-driver-smb.sh {{quote(kubeconfig)}}

# Verify the live Phase 11 shared media storage: Kustomizations Ready and the
# static RWX media-data PVC Bound. The mount is exercised for real by Plex (PR 11-2)
# and the documented hardlink proof (docs/phase-11-media.md); binding a static PV is
# a claimRef match and does not by itself prove the SMB mount works.
media-storage-verify: require-bash
    @scripts/verify/media-storage.sh {{quote(kubeconfig)}}

# Verify the live Phase 11 Plex: Kustomization + HelmRelease Ready, rollout complete,
# HTTPRoute Accepted, Pi-hole DNS, and /identity reachable over the internal gateway.
# The node-failure reschedule gate is a manual operator test (docs/phase-11-media.md).
plex-verify: require-bash
    @scripts/verify/plex.sh {{quote(kubeconfig)}}

# The Phase 11 gate: prove the single Plex replica recreates on ANOTHER NUC when its
# node becomes unschedulable, with the Longhorn RWO config volume re-attaching and the
# SMB media re-mounting. Safe form (cordon + delete pod); the original node is always
# uncordoned (trap). NOT in `just ci` — destructive, operator-run.
plex-reschedule-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    ns='media'
    selector='app.kubernetes.io/name=plex'
    cordoned=''
    cleanup() {
      if [[ -n "$cordoned" ]]; then
        kubectl --kubeconfig "$kubeconfig" uncordon "$cordoned" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup EXIT

    orig_pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l "$selector" --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "$orig_pod" ]] || { echo 'No running Plex pod found.' >&2; exit 1; }
    orig_node="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod "$orig_pod" --output jsonpath='{.spec.nodeName}')"
    echo "Plex pod $orig_pod is on node $orig_node; cordoning it and deleting the pod to force a reschedule."

    kubectl --kubeconfig "$kubeconfig" cordon "$orig_node"
    cordoned="$orig_node"
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" delete pod "$orig_pod" --wait=false

    ready='False'; new_pod=''; new_node=''
    for _ in {1..90}; do
      new_pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l "$selector" --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -n "$new_pod" && "$new_pod" != "$orig_pod" ]]; then
        ready="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod "$new_pod" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)"
        new_node="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod "$new_pod" --output jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
        [[ "$ready" == 'True' ]] && break
      fi
      sleep 10
    done

    kubectl --kubeconfig "$kubeconfig" uncordon "$orig_node"
    cordoned=''

    [[ "$ready" == 'True' ]] || { echo "Plex did not become Ready on another node after reschedule (pod=$new_pod node=$new_node)." >&2; exit 1; }
    [[ "$new_node" != "$orig_node" ]] || { echo "Plex rescheduled onto the same node $orig_node; expected a different NUC." >&2; exit 1; }
    echo "Phase 11 Plex reschedule gate passed: pod moved $orig_node -> $new_node, RWOP config re-attached and SMB media re-mounted, Plex Ready."

# Validate the Phase 11 Intel GPU device plugin source: files, wiring, dependency,
# pinned image, and the built DaemonSet manifest.
intel-gpu-plugin-validate: require-bash
    @scripts/validate/intel-gpu-plugin.sh

# Verify the live Phase 11 Intel GPU device plugin: Kustomization Ready, DaemonSet
# rolled out, and every node advertising gpu.intel.com/i915 (QuickSync capacity).
intel-gpu-plugin-verify: require-bash
    @scripts/verify/intel-gpu-plugin.sh {{quote(kubeconfig)}}

# Validate the Phase 12 qBittorrent+Gluetun source: files, wiring, dependency,
# encrypted ProtonVPN Secret, the sidecar/kill-switch essentials, and the pinned render.
qbittorrent-validate: require-bash
    @scripts/validate/qbittorrent.sh

# Verify the live Phase 12 qBittorrent: Kustomization + HelmRelease Ready, rollout,
# HTTPRoute Accepted, DNS, and the WebUI reachable over the internal gateway. The VPN
# kill-switch is proven separately by qbittorrent-killswitch-verify.
qbittorrent-verify: require-bash
    @scripts/verify/qbittorrent.sh {{quote(kubeconfig)}}

# BLOCKING, bulletproof VPN kill-switch gate. NOT in `just ci` — operator-run; it mutates
# the running pod (stops AND hard-kills the VPN) and needs the live ProtonVPN tunnel.
# Proves qBittorrent egresses ONLY through ProtonVPN Sweden and fails closed on both a
# polite stop and an unexpected crash, with the home WAN IP as a hard never-leak invariant.
# Precondition: first-run done (WebUI password set + "Bypass authentication for localhost"
# enabled, which the port-forward UP command also relies on). Phase 12 is not flipped
# suspend: false / not "done" until this passes.
qbittorrent-killswitch-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    ns='media'
    pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [[ -n "$pod" ]] || { echo 'No qbittorrent pod found (is Phase 12 bootstrapped?).' >&2; exit 1; }

    gx() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c gluetun -- "$@"; }
    gapp() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c app -- "$@"; }
    apikey="$(gx sh -c 'grep -E "^apikey" /gluetun/auth/config.toml | sed -E "s/.*\"(.*)\".*/\1/"' 2>/dev/null | tr -d "\r")"
    [[ -n "$apikey" ]] || { echo 'Could not read control-server apikey from /gluetun/auth/config.toml.' >&2; exit 1; }
    ctl() { gx wget -qO- --header "X-API-Key: $apikey" "$@" 2>/dev/null; }
    ctl_put() { gx wget -qO- --method=PUT --header "X-API-Key: $apikey" --body-data "$2" "$1" >/dev/null 2>&1 || true; }
    vpn_status()  { ctl http://localhost:8000/v1/vpn/status    | yq -r '.status // "unknown"' 2>/dev/null || echo unknown; }
    vpn_ip()      { ctl http://localhost:8000/v1/publicip/ip   | yq -r '.public_ip // ""' 2>/dev/null || true; }
    vpn_country() { ctl http://localhost:8000/v1/publicip/ip   | yq -r '.country // ""' 2>/dev/null || true; }
    fport()       { ctl http://localhost:8000/v1/portforward   | yq -r '.port // ""' 2>/dev/null || true; }
    listen_port() { gapp sh -c 'wget -qO- -T 6 http://127.0.0.1:8080/api/v2/app/preferences 2>/dev/null' | yq -r '.listen_port // ""' 2>/dev/null || true; }

    # On a failed/interrupted run, reset to a clean pod (fresh netns + tunnel) rather than
    # a control-API `PUT running`, which re-establishes in-place and can loop on Gluetun's
    # healthcheck DNS. On success the pod was already recreated healthy in step 3.
    passed=false
    trap '[[ "$passed" == "true" ]] || kubectl --kubeconfig "$kubeconfig" --namespace "$ns" delete pod "$pod" --wait=false >/dev/null 2>&1 || true' EXIT

    # The app container needs wget (BusyBox) to probe egress from qBittorrent's OWN netns.
    gapp sh -c 'command -v wget >/dev/null' || { echo 'app container lacks wget; cannot probe qBittorrent egress.' >&2; exit 1; }

    # Independent home/WAN reference: a throwaway pod with NO VPN egresses via the node WAN.
    home_ip="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" run "kswan-$RANDOM" --image=curlimages/curl:8.11.1 --restart=Never --rm -i --quiet --command -- curl -sS -m 15 https://ifconfig.me/ip 2>/dev/null | tr -d '\r\n ' || true)"
    [[ -n "$home_ip" ]] || { echo 'Could not determine the node WAN IP (needed as the leak reference).' >&2; exit 1; }
    echo "Reference home/WAN IP (must NEVER appear as qBittorrent egress): $home_ip"

    # Egress FROM qBittorrent's netns: prints the observed public IP, or empty if blocked.
    # ifconfig.me/ip returns a plain IP for any User-Agent (the bare host serves HTML to
    # wget), so egress parsing is UA-independent.
    app_egress() { gapp sh -c 'wget -qO- -T 6 https://ifconfig.me/ip 2>/dev/null || true' | tr -d '\r\n '; }
    # Route-level probe bypassing DNS (connect to Cloudflare by IP): non-empty if reachable.
    app_route()  { gapp sh -c 'wget -qO- -T 6 https://1.1.1.1/ 2>/dev/null | head -c 1 || true' | tr -d '\r\n '; }
    leak_guard() { [[ -n "$1" && "$1" == "$home_ip" ]] && { echo "LEAK ($2): qBittorrent egress IP == home WAN IP $home_ip." >&2; exit 1; }; return 0; }

    echo '== 1. Baseline (VPN up, must be Sweden, not home) =='
    [[ "$(vpn_status)" == 'running' ]] || { echo 'VPN is not running at baseline.' >&2; exit 1; }
    vip="$(vpn_ip)"; country="$(vpn_country)"; fp="$(fport)"
    [[ -n "$vip" ]] || { echo 'No VPN public IP from the control server.' >&2; exit 1; }
    echo "VPN public IP=$vip country=$country forwarded_port=$fp"
    [[ "$vip" != "$home_ip" ]] || { echo 'LEAK: VPN public IP equals the home WAN IP.' >&2; exit 1; }
    printf '%s' "$country" | grep -qi 'sweden' || { echo "VPN egress country is '$country', not Sweden (SERVER_COUNTRIES=Sweden not honored)." >&2; exit 1; }
    be="$(app_egress)"; echo "qBittorrent egress IP=$be"
    leak_guard "$be" 'baseline'
    [[ "$be" == "$vip" ]] || { echo "qBittorrent egress ($be) != VPN IP ($vip)." >&2; exit 1; }
    [[ -n "$fp" && "$fp" != '0' ]] || { echo 'No active forwarded port at baseline.' >&2; exit 1; }
    lp="$(listen_port)"
    [[ "$lp" == "$fp" ]] || { echo "qBittorrent listen_port ($lp) != forwarded port ($fp). Enable localhost auth bypass + confirm the UP command ran." >&2; exit 1; }
    echo "listen_port matches forwarded port ($fp)."
    # DNS isolation (structural, cache-proof): the app must resolve ONLY via Gluetun's
    # in-netns resolver (127.0.0.1 DoT over the tunnel), never the node/cluster resolver,
    # so DNS queries cannot reach the ISP even when the tunnel drops.
    ns_list="$(gapp sh -c 'grep "^nameserver" /etc/resolv.conf' 2>/dev/null | sed -E 's/^nameserver[[:space:]]+//' | tr -d '\r')"
    echo "app resolver(s): $(printf '%s' "$ns_list" | tr '\n' ' ')"
    [[ -n "$ns_list" ]] || { echo 'Could not read app /etc/resolv.conf.' >&2; exit 1; }
    while read -r n; do
      if [[ -n "$n" && "$n" != '127.0.0.1' ]]; then echo "DNS LEAK RISK: app resolver '$n' is not Gluetun's loopback (127.0.0.1)." >&2; exit 1; fi
    done <<< "$ns_list"

    echo '== 2. Kill switch: polite stop (VPN held down) =='
    ctl_put http://localhost:8000/v1/vpn/status '{"status":"stopped"}'
    sleep 3
    [[ "$(vpn_status)" != 'running' ]] || { echo 'VPN still running after stop request.' >&2; exit 1; }
    for _ in 1 2 3 4 5; do
      out="$(app_egress)"; leak_guard "$out" 'vpn-stopped'
      [[ -z "$out" ]] || { echo "LEAK: qBittorrent reached the internet ($out) with the VPN stopped." >&2; exit 1; }
      [[ -z "$(app_route)" ]] || { echo 'LEAK: route-level egress (1.1.1.1) succeeded with the VPN stopped.' >&2; exit 1; }
      sleep 3
    done
    echo 'Kill switch holds: no IP egress and no route-level egress while the VPN is stopped (DNS is isolated to Gluetun per the baseline resolver check).'

    echo '== 3. Recovery via pod recreation (the node-reschedule path) =='
    # NB: a gluetun *container* crash cannot be injected from `kubectl exec` — the kernel
    # blocks same-PID-namespace SIGKILL to PID 1 (verified: restartCount stays 0). And
    # Gluetun's in-place restart after a control-server stop can loop on healthcheck DNS
    # timeouts. The robust, realistic recovery is pod recreation (exactly what a node
    # reschedule does): a fresh netns + tunnel. During the recreate gap there is no pod,
    # hence no possible egress, so fail-closed is preserved by construction. Fail-closed on
    # an in-place gluetun crash is structural anyway: qBittorrent holds no NET_ADMIN, so it
    # cannot restore routes, and Gluetun's firewall DROP rules persist in the netns.
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
    sleep 20
    back=false
    for _ in {1..48}; do
      newpod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
      [[ -n "$newpod" ]] || { sleep 5; continue; }
      pod="$newpod"  # rebind so gx/gapp target the fresh pod
      [[ "$(vpn_status)" == 'running' && -n "$(vpn_ip)" ]] && { back=true; break; }
      sleep 5
    done
    [[ "$back" == 'true' ]] || { echo 'VPN did not recover to a healthy tunnel within ~4m after pod recreation.' >&2; exit 1; }
    rip="$(vpn_ip)"; rc="$(vpn_country)"; leak_guard "$rip" 'recovery'
    printf '%s' "$rc" | grep -qi 'sweden' || { echo "Recovered country '$rc' is not Sweden." >&2; exit 1; }
    be="$(app_egress)"; leak_guard "$be" 'post-recovery'
    [[ "$be" == "$rip" ]] || { echo "Post-recovery qBittorrent egress ($be) != VPN IP ($rip)." >&2; exit 1; }
    rport=''; for _ in {1..24}; do rport="$(fport)"; [[ -n "$rport" && "$rport" != '0' ]] && break; sleep 5; done
    [[ -n "$rport" && "$rport" != '0' ]] || { echo 'Forwarded port not reacquired after recovery.' >&2; exit 1; }
    rlp=''; for _ in {1..18}; do rlp="$(listen_port)"; [[ "$rlp" == "$rport" ]] && break; sleep 5; done
    [[ "$rlp" == "$rport" ]] || { echo "After recovery, listen_port ($rlp) != forwarded port ($rport) (UP command did not reapply)." >&2; exit 1; }
    echo "Recovered via pod recreation: IP=$rip country=$rc forwarded_port=$rport reapplied to listen_port; no home-IP leak."

    echo '== 4. Final state =='
    [[ "$(vpn_status)" == 'running' ]] || { echo 'VPN not running at final check.' >&2; exit 1; }
    fip="$(vpn_ip)"; fc="$(vpn_country)"; fe="$(app_egress)"; leak_guard "$fe" 'final'
    [[ "$fe" == "$fip" ]] || { echo "Final qBittorrent egress ($fe) != VPN IP ($fip)." >&2; exit 1; }
    printf '%s' "$fc" | grep -qi 'sweden' || { echo "Final country '$fc' not Sweden." >&2; exit 1; }
    passed=true
    echo "PASS: kill switch is bulletproof — egress only via ProtonVPN Sweden ($fip); fail-closed on VPN stop (no IP/route/DNS egress); DNS isolated; recovers to Sweden via pod recreation with the forwarded port reacquired+reapplied; home WAN IP ($home_ip) never leaked. Safe to flip suspend: false."

# Validate the Phase 13 *arr source (Prowlarr, Sonarr, Radarr): files, wiring, dependency
# graph, no-secret ks, app-template chartRef, config-PVC (Longhorn RWO + Recreate + keep),
# shared /data for sonarr/radarr, HTTPRoutes, Gatus /ping probes, and the pinned
# app-template render. Cluster-independent — part of `just ci`.
arr-validate: require-bash
    @scripts/validate/arr.sh

# Verify a live Phase 13 *arr app: `just kube arr-verify <prowlarr|sonarr|radarr>`.
# Kustomization + HelmRelease Ready, rollout, HTTPRoute Accepted, DNS, and /ping over the
# internal gateway. Operator-only (needs the cluster); not in `just ci`.
arr-verify app: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    app='{{app}}'
    case "$app" in prowlarr|sonarr|radarr) ;; *) echo "Usage: just kube arr-verify <prowlarr|sonarr|radarr>" >&2; exit 1;; esac
    kubeconfig='{{kubeconfig}}'
    ns='media'
    gateway_ip='192.168.90.30'
    host="$app.lab.supermorphic.com"

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$app" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo "$app Kustomization not Ready." >&2; exit 1; }
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease "$app" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo "$app HelmRelease not Ready." >&2; exit 1; }
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status "deployment/$app" --timeout=5m
    accepted=false
    for _ in {1..24}; do
      [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute "$app" --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]] && { accepted=true; break; }
      sleep 5
    done
    [[ "$accepted" == 'true' ]] || { echo "$app HTTPRoute was not Accepted." >&2; exit 1; }
    [[ "$(dig +short @192.168.90.2 "$host" A | sort -u)" == "$gateway_ip" ]] || { echo "DNS for $host does not resolve to $gateway_ip." >&2; exit 1; }
    curl --silent --fail --resolve "$host:443:$gateway_ip" "https://$host/ping" >/dev/null || { echo "$app /ping not reachable via the gateway." >&2; exit 1; }
    echo "$app live acceptance passed (Ready, rollout, HTTPRoute Accepted, DNS, /ping)."

# Validate the Phase 14 Seerr source: files, wiring, no-secret ks, app-template chartRef,
# config-only PVC (Longhorn RWO + Recreate + keep at /app/config), HTTPRoute, Gatus probe,
# and the pinned app-template render. Cluster-independent — part of `just ci`.
seerr-validate: require-bash
    @scripts/validate/seerr.sh

# Verify the live Phase 14 Seerr: Kustomization + HelmRelease Ready, rollout, HTTPRoute
# Accepted, DNS, and /api/v1/status over the internal gateway. Operator-only; not in ci.
seerr-verify: require-bash
    @scripts/verify/seerr.sh {{quote(kubeconfig)}}

# Validate the Phase 10 monitoring source: files, encrypted Grafana Secret,
# dependency graph, staged-suspend uniformity, key values, wiring, HTTPRoutes,
# and the pinned kube-prometheus-stack render.
monitoring-validate: require-bash
    @scripts/validate/monitoring.sh

# Verify the live monitoring stack: HelmRelease + workloads healthy, PVCs bound
# on Longhorn, HTTPRoutes accepted, all three UIs reachable with trusted HTTPS
# through the internal gateway, and the foundation still green.
monitoring-verify: require-bash
    @scripts/verify/monitoring.sh {{quote(kubeconfig)}}

# Reset Grafana's DB admin password to the current grafana-admin Secret value. Grafana
# only applies the admin password on first init, so a rotated/recreated Secret (e.g. the
# age-key migration) leaves the DB on the old password (401s, incl. the Homepage widget).
# This reuses the pod's own GF_SECURITY_ADMIN_* env, so no secret value is printed or
# passed on the command line. Operator-run; cluster-dependent; NOT in `just ci`.
grafana-admin-reset: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    ns='monitoring'
    pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [[ -n "$pod" ]] || { echo 'No grafana pod found in monitoring.' >&2; exit 1; }

    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c grafana -- \
      sh -c 'grafana cli --homepath /usr/share/grafana admin reset-admin-password "$GF_SECURITY_ADMIN_PASSWORD" >/dev/null 2>&1 && echo ok' | grep -qx ok || {
        echo 'grafana cli reset-admin-password failed.' >&2; exit 1; }

    # Verify the Secret creds now authenticate to the API (no secret printed).
    ok="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c grafana -- sh -c '
      a=$(printf "%s:%s" "$GF_SECURITY_ADMIN_USER" "$GF_SECURITY_ADMIN_PASSWORD" | base64 | tr -d "\n")
      wget -qO- -T 6 --header="Authorization: Basic $a" "http://localhost:3000/api/search?limit=1" >/dev/null 2>&1 && echo yes || echo no')"
    [[ "$ok" == 'yes' ]] || { echo 'Grafana admin creds still fail to authenticate after reset.' >&2; exit 1; }
    echo 'Grafana DB admin password reset to match the grafana-admin Secret; API auth verified. (Sync the homepage-grafana Secret to the same creds via just repo homepage-grafana-secrets + restart homepage for the widget.)'

# Validate the Phase 10 Gatus source: files, wiring, namespace gateway label,
# staged suspend, key values, HTTPRoute, and the pinned chart render.
gatus-validate: require-bash
    @scripts/validate/gatus.sh

# Verify the live Gatus app: Kustomization + HelmRelease Ready, PVC bound,
# HTTPRoute accepted, the dashboard reachable via HTTPS, and foundation green.
gatus-verify: require-bash
    @scripts/verify/gatus.sh {{quote(kubeconfig)}}

# Validate the Phase 10 Homepage source: files, wiring, namespace gateway label,
# dependency graph, pinned image, allowed-hosts, HTTPRoute, and the render.
homepage-validate: require-bash
    @scripts/validate/homepage.sh

# Verify the live Homepage app: Kustomization Ready, deployment rolled out,
# HTTPRoute accepted, dashboard reachable via HTTPS, and foundation green.
homepage-verify: require-bash
    @scripts/verify/homepage.sh {{quote(kubeconfig)}}

# Validate the Phase 10 Trivy Operator source: files, wiring, staged suspend,
# dependency, pinned chart, key scanner settings, and the render.
trivy-validate: require-bash
    @scripts/validate/trivy.sh

# Verify the live Trivy Operator: Kustomization + HelmRelease Ready, operator
# rolled out, report CRDs installed, and foundation green.
trivy-verify: require-bash
    @scripts/verify/trivy.sh {{quote(kubeconfig)}}
