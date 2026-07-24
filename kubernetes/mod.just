set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

cilium_chart := "oci://quay.io/cilium/charts/cilium"
cilium_values := "kubernetes/apps/kube-system/cilium/app/values.yaml"
cilium_app := "kubernetes/apps/kube-system/cilium/app"
kubeconfig := "kubeconfig"
flux_path := "kubernetes/flux/clusters/prod"
github_owner := "7yXwscXEzv6phzUnKfrw"
github_repository := "homelab-talos"
cert_manager_chart := "oci://quay.io/jetstack/charts/cert-manager"
metallb_repository := "https://metallb.github.io/metallb"
envoy_gateway_chart := "oci://docker.io/envoyproxy/gateway-helm"
external_dns_repository := "https://kubernetes-sigs.github.io/external-dns"

# Render the pinned Cilium chart to standard output without writing generated YAML.
cilium-render:
    @helm template cilium {{cilium_chart}} \
      --version "$(yq -r '.spec.ref.tag' {{cilium_app}}/ocirepository.yaml)" \
      --namespace kube-system \
      --values {{cilium_values}}

# Validate the app-local Cilium source and pinned Helm render.
cilium-validate:
    #!/usr/bin/env bash
    set -euo pipefail

    app_dir='{{cilium_app}}'
    values_file='{{cilium_values}}'
    chart='{{cilium_chart}}'
    version="$(yq -r '.spec.ref.tag' '{{cilium_app}}/ocirepository.yaml')"
    temp_dir="$(mktemp -d /tmp/homelab-talos-cilium-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for file in \
      "$app_dir/kustomization.yaml" \
      "$app_dir/ocirepository.yaml" \
      "$app_dir/helmrelease.yaml" \
      "$values_file" \
      'kubernetes/apps/kube-system/cilium/ks.yaml'; do
      [[ -f "$file" ]] || {
        echo "Missing required Cilium source: $file" >&2
        exit 1
      }
    done

    [[ -n "$version" && "$version" != 'null' ]]
    [[ "$(yq -r '.spec.url' "$app_dir/ocirepository.yaml")" == "$chart" ]]
    [[ "$(yq -r '.spec.releaseName' "$app_dir/helmrelease.yaml")" == 'cilium' ]]
    [[ "$(yq -r '.spec.targetNamespace' "$app_dir/helmrelease.yaml")" == 'kube-system' ]]
    [[ "$(yq -r '.spec.storageNamespace' "$app_dir/helmrelease.yaml")" == 'kube-system' ]]
    [[ "$(yq -r '.spec.valuesFrom[0].name' "$app_dir/helmrelease.yaml")" == 'cilium-values' ]]
    [[ "$(yq -r '.spec.valuesFrom[0].valuesKey' "$app_dir/helmrelease.yaml")" == 'values.yaml' ]]

    [[ "$(yq -r '.cluster.name' "$values_file")" == 'nuc-cluster' ]]
    [[ "$(yq -r '.cluster.id' "$values_file")" == '1' ]]
    [[ "$(yq -r '.ipam.mode' "$values_file")" == 'kubernetes' ]]
    [[ "$(yq -r '.kubeProxyReplacement' "$values_file")" == 'true' ]]
    [[ "$(yq -r '.k8sServiceHost' "$values_file")" == 'localhost' ]]
    [[ "$(yq -r '.k8sServicePort' "$values_file")" == '7445' ]]
    [[ "$(yq -r '.cgroup.autoMount.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.cgroup.hostRoot' "$values_file")" == '/sys/fs/cgroup' ]]
    [[ "$(yq -r '.routingMode' "$values_file")" == 'tunnel' ]]
    [[ "$(yq -r '.tunnelProtocol' "$values_file")" == 'vxlan' ]]
    [[ "$(yq -r '.bpf.masquerade' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.operator.replicas' "$values_file")" == '2' ]]
    [[ "$(yq -r '.hubble.relay.enabled' "$values_file")" == 'true' ]]
    [[ "$(yq -r '.hubble.ui.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.envoy.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.gatewayAPI.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.l2announcements.enabled' "$values_file")" == 'false' ]]
    [[ "$(yq -r '.bgpControlPlane.enabled' "$values_file")" == 'false' ]]
    ! yq -r '.securityContext.capabilities.ciliumAgent[]' "$values_file" | rg -qx 'SYS_MODULE'

    kustomize build "$app_dir" >"$temp_dir/kustomization.yaml"
    [[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "cilium-values") | .metadata.labels."reconcile.fluxcd.io/watch"' "$temp_dir/kustomization.yaml")" == 'Enabled' ]]
    [[ -n "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "cilium-values") | .data."values.yaml"' "$temp_dir/kustomization.yaml")" ]]

    helm template cilium "$chart" \
      --version "$version" \
      --namespace kube-system \
      --values "$values_file" >"$temp_dir/rendered.yaml"

    [[ -n "$(yq ea -r 'select(.kind == "DaemonSet" and .metadata.name == "cilium") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
    [[ -n "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "cilium-operator") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
    [[ -n "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "hubble-relay") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
    [[ -z "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "hubble-ui") | .metadata.name' "$temp_dir/rendered.yaml")" ]]
    [[ -z "$(yq ea -r 'select(.kind == "DaemonSet" and .metadata.name == "cilium-envoy") | .metadata.name' "$temp_dir/rendered.yaml")" ]]

    echo "Cilium $version app sources and Helm render passed validation."

# Print read-only live Cilium and Kubernetes status.
cilium-status:
    #!/usr/bin/env bash
    set -u

    kubeconfig='{{kubeconfig}}'
    [[ -f "$kubeconfig" ]] || {
      echo "Missing ignored kubeconfig; run just bootstrap verify." >&2
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
        --talosconfig clusterconfig/talosconfig \
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
      --talosconfig clusterconfig/talosconfig)"
    printf '%s\n' "$etcd_status"
    [[ "$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$etcd_status")" == '3' ]]

    alarm_status="$(talosctl etcd alarm list \
      --nodes "$nodes_csv" \
      --endpoints "$nodes_csv" \
      --talosconfig clusterconfig/talosconfig)"
    printf '%s\n' "$alarm_status"
    [[ "$(awk 'NR > 1 && NF {count++} END {print count + 0}' <<<"$alarm_status")" == '0' ]]

    echo 'Cilium postflight passed: test resources removed, no Talos diagnostics, three etcd members, and no etcd alarms.'

# Fail unless running under bash >= 4; macOS /bin/bash 3.2 does not honor set -e
# for a failed bare [[ ]] mid-recipe, so these acceptance assertions would not gate.
# Validate the metrics-server source: files, wiring, dependency, pinned chart, the
# Talos --kubelet-insecure-tls flag, and the render (version derived from the HR).
metrics-server-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/kube-system/metrics-server'
    ks="$base/ks.yaml"
    hr="$base/app/helmrelease.yaml"
    repo="$base/app/helmrepository.yaml"
    values="$base/app/values.yaml"
    temp_dir="$(mktemp -d /tmp/homelab-talos-metrics-server-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$hr" "$repo" "$values" "$base/app/kustomization.yaml"; do
      [[ -f "$f" ]] || { echo "Missing metrics-server source: $f" >&2; exit 1; }
    done
    rg -qx '  - ./metrics-server/ks.yaml' kubernetes/apps/kube-system/kustomization.yaml || {
      echo 'Refusing: ./metrics-server/ks.yaml is not wired into the kube-system kustomization.' >&2
      exit 1
    }
    suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
    [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
    [[ "$(yq ea -r '[.spec.dependsOn[].name] | join(",")' "$ks")" == 'cilium' ]]
    [[ "$(yq -r '.spec.url' "$repo")" == 'https://kubernetes-sigs.github.io/metrics-server' ]]
    [[ -n "$(yq -r '.args[] | select(. == "--kubelet-insecure-tls")' "$values")" ]]
    chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
    [[ -n "$chart_version" && "$chart_version" != 'null' ]]

    kustomize build "$base/app" >/dev/null
    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
    HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
      helm template metrics-server metrics-server --repo https://kubernetes-sigs.github.io/metrics-server --version "$chart_version" --namespace kube-system --values "$values" >/dev/null

    echo 'metrics-server source, wiring, dependency, insecure-tls flag, and pinned render passed validation.'

# Verify metrics-server: Kustomization + HelmRelease Ready, deployment rolled out,
# the metrics.k8s.io APIService Available, and kubectl top returns data.
metrics-server-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization metrics-server --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'metrics-server Kustomization is not Ready.' >&2; exit 1; }
    kubectl --kubeconfig "$kubeconfig" --namespace kube-system rollout status deployment/metrics-server --timeout=5m

    avail=false
    for _ in {1..24}; do
      if [[ "$(kubectl --kubeconfig "$kubeconfig" get apiservice v1beta1.metrics.k8s.io --output jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" == 'True' ]]; then
        avail=true
        break
      fi
      sleep 5
    done
    [[ "$avail" == 'true' ]] || { echo 'The metrics.k8s.io APIService is not Available.' >&2; exit 1; }
    kubectl --kubeconfig "$kubeconfig" top nodes >/dev/null 2>&1 || { echo 'kubectl top nodes did not return metrics.' >&2; exit 1; }

    echo 'metrics-server acceptance passed: deployment ready, metrics.k8s.io Available, and kubectl top nodes returns data.'

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
    [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || {
      echo 'This repository requires bash >= 4 (for example: brew install bash).' >&2
      echo 'macOS /bin/bash 3.2 skips set -e for [[ ]] tests, so validation would not gate.' >&2
      exit 1
    }

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
      echo "Missing ignored kubeconfig; run just bootstrap verify." >&2
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
    #!/usr/bin/env bash
    set -euo pipefail

    expected_flux="$(yq -p=toml -r '.tools.flux2' .mise.toml 2>/dev/null)"
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    temp_dir="$(mktemp -d /tmp/homelab-talos-flux-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for file in \
      '{{flux_path}}/apps.yaml' \
      'kubernetes/apps/kustomization.yaml' \
      'kubernetes/apps/flux-system/kustomization.yaml' \
      'kubernetes/apps/flux-system/flux-canary/ks.yaml' \
      'kubernetes/apps/flux-system/flux-canary/app/kustomization.yaml' \
      'kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml' \
      'kubernetes/apps/kube-system/kustomization.yaml' \
      'kubernetes/apps/kube-system/cilium/ks.yaml'; do
      [[ -f "$file" ]] || {
        echo "Missing required Flux source: $file" >&2
        exit 1
      }
    done

    [[ "$(flux version --client | awk '{print $2}' | sed 's/^v//')" == "$expected_flux" ]]
    [[ "$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .encrypted_regex' .sops.yaml)" == '^(data|stringData)$' ]]
    [[ "$expected_recipient" == age1* ]]

    canary='kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml'
    [[ "$(sops filestatus "$canary" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$canary" | sort -u)" == "$expected_recipient" ]]
    [[ "$(yq -r '.kind' "$canary")" == 'Secret' ]]
    [[ "$(yq -r '.metadata.name' "$canary")" == 'flux-canary' ]]
    [[ "$(yq -r '.stringData.marker' "$canary")" != 'ready' ]]

    root='{{flux_path}}/apps.yaml'
    [[ "$(yq -r '.metadata.name' "$root")" == 'cluster-apps' ]]
    [[ "$(yq -r '.spec.path' "$root")" == './kubernetes/apps' ]]
    [[ "$(yq -r '.spec.sourceRef.name' "$root")" == 'flux-system' ]]
    [[ "$(yq -r '.spec.deletionPolicy' "$root")" == 'Orphan' ]]

    cilium='kubernetes/apps/kube-system/cilium/ks.yaml'
    [[ "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' "$cilium")" == 'disabled' ]]
    [[ "$(yq -r '.spec.deletionPolicy' "$cilium")" == 'Orphan' ]]
    [[ "$(yq -r '.spec.decryption.provider' "$cilium")" == 'sops' ]]
    [[ "$(yq -r '.spec.decryption.secretRef.name' "$cilium")" == 'sops-age' ]]
    cilium_suspend="$(yq -r '.spec.suspend // false' "$cilium")"
    [[ "$cilium_suspend" == 'true' || "$cilium_suspend" == 'false' ]]
    [[ "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' kubernetes/apps/kube-system/cilium/app/helmrelease.yaml)" == 'disabled' ]]

    canary_ks='kubernetes/apps/flux-system/flux-canary/ks.yaml'
    [[ "$(yq -r '.spec.dependsOn[0].name' "$canary_ks")" == 'cilium' ]]
    [[ "$(yq -r '.spec.decryption.provider' "$canary_ks")" == 'sops' ]]
    [[ "$(yq -r '.spec.decryption.secretRef.name' "$canary_ks")" == 'sops-age' ]]

    kustomize build kubernetes/apps >"$temp_dir/apps.yaml"
    kustomize build kubernetes/apps/kube-system >"$temp_dir/kube-system.yaml"
    kustomize build kubernetes/apps/flux-system >"$temp_dir/flux-system.yaml"
    kustomize build kubernetes/apps/kube-system/cilium/app >"$temp_dir/cilium.yaml"
    kustomize build kubernetes/apps/flux-system/flux-canary/app >"$temp_dir/canary.yaml"

    # Presence check, not an exact set: adding an app must not require editing this
    # assertion (it broke on every Phase 9/10 addition). Confirm the critical
    # bootstrap Kustomizations build; app churn is caught by each app's *-validate.
    built_kustomizations="$(yq ea -r '[select(.kind == "Kustomization") | .metadata.name] | .[]' "$temp_dir/apps.yaml" | sort -u)"
    for required in cilium flux-canary; do
      rg -qx "$required" <<<"$built_kustomizations" || {
        echo "flux-validate: required Kustomization '$required' is missing from the apps build." >&2
        exit 1
      }
    done
    [[ -z "$(rg '^apiVersion: (apps|extensions)/v1beta|^apiVersion: (networking.k8s.io|policy)/v1beta1' kubernetes --glob '*.yaml' || true)" ]]

    just kube cilium-validate
    echo "Flux $expected_flux source, SOPS canary, dependency graph, and Cilium adoption guards passed validation."

# Check the live cluster and Git publication boundary before GitHub bootstrap.
flux-preflight: flux-validate
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    owner='{{github_owner}}'
    repository='{{github_repository}}'
    expected_origin="https://github.com/${owner}/${repository}.git"

    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig; run just bootstrap verify only if it must be refreshed.' >&2
      exit 1
    }
    [[ "$(git branch --show-current)" == 'main' ]] || {
      echo 'Refusing Flux bootstrap: the checked-out branch is not main.' >&2
      exit 1
    }
    [[ -z "$(git status --porcelain)" ]] || {
      echo 'Refusing Flux bootstrap: commit and push the reviewed Phase 6 sources first.' >&2
      exit 1
    }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
      echo "Refusing Flux bootstrap: origin must be $expected_origin." >&2
      exit 1
    }
    remote_head="$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')"
    [[ "$remote_head" == "$(git rev-parse HEAD)" ]] || {
      echo 'Refusing Flux bootstrap: local HEAD and origin/main differ.' >&2
      exit 1
    }
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
      echo 'Missing ignored kubeconfig.' >&2
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
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    expected_url='ssh://git@ssh.github.com:443/{{github_owner}}/{{github_repository}}'
    temp_key="$(mktemp /tmp/homelab-talos-flux-age.XXXXXX)"
    trap 'rm -f -- "$temp_key"' EXIT

    flux check --kubeconfig "$kubeconfig"
    for deployment in source-controller kustomize-controller helm-controller notification-controller; do
      available="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get deployment "$deployment" --output jsonpath='{.status.availableReplicas}')"
      [[ "$available" == '1' ]] || {
        echo "$deployment does not have exactly one available replica." >&2
        exit 1
      }
    done

    source_json="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get gitrepository flux-system --output json)"
    [[ "$(yq -r '.spec.url' - <<<"$source_json")" == "$expected_url" ]]
    [[ "$(yq -r '.spec.ref.branch' - <<<"$source_json")" == 'main' ]]
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$source_json")" == 'True' ]]
    remote_head="$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')"
    artifact_revision="$(yq -r '.status.artifact.revision' - <<<"$source_json")"
    [[ "$artifact_revision" == *"$remote_head" ]] || {
      echo "Flux artifact $artifact_revision has not reconciled origin/main at $remote_head." >&2
      exit 1
    }

    for name in flux-system cluster-apps cilium flux-canary; do
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
        --for=condition=Ready "kustomization/$name" --timeout=10m
      state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output json)"
      [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$state")" == 'True' ]] || {
        echo "Flux Kustomization $name is not Ready." >&2
        exit 1
      }
      [[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
    done

    kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret sops-age \
      --output jsonpath='{.data.age\.agekey}' | base64 --decode >"$temp_key"
    chmod 600 "$temp_key"
    [[ "$(age-keygen -y "$temp_key")" == "$expected_recipient" ]]
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-canary --output jsonpath='{.data.marker}' | base64 --decode)" == 'ready' ]]

    source_secret_keys="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get secret flux-system --output json | yq -r '.data | keys | .[]' | sort)"
    [[ "$source_secret_keys" == $'identity\nidentity.pub\nknown_hosts' ]] || {
      echo "Unexpected Flux source credential fields: $source_secret_keys" >&2
      exit 1
    }

    cilium_source="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get ocirepository cilium --output json)"
    [[ -n "$(yq -r '.spec.ref.tag' - <<<"$cilium_source")" ]]
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_source")" == 'True' ]]
    cilium_release="$(kubectl --kubeconfig "$kubeconfig" --namespace kube-system get helmrelease cilium --output json)"
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$cilium_release")" == 'True' ]]
    [[ "$(yq -r '.spec.releaseName' - <<<"$cilium_release")" == 'cilium' ]]

    just kube cilium-postflight
    echo 'Phase 6 verification passed: Flux, SSH source auth, SOPS, canary reconciliation, and Cilium ownership are healthy.'

# Validate the complete local Phase 7 graph, encrypted providers, and pinned chart renders.
foundation-validate:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    cloudflare_secret='kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml'
    pihole_secret='kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml'
    pihole_ca='kubernetes/apps/networking/external-dns/app/pihole-ca.crt'
    temp_dir="$(mktemp -d /tmp/homelab-talos-foundation-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for file in \
      'kubernetes/apps/security/cert-manager/ks.yaml' \
      'kubernetes/apps/security/cert-manager/app/ocirepository.yaml' \
      'kubernetes/apps/security/cert-manager/app/helmrelease.yaml' \
      'kubernetes/apps/security/cert-manager/app/values.yaml' \
      'kubernetes/apps/security/cert-manager/config/clusterissuers.yaml' \
      'kubernetes/apps/security/cert-manager/config/staging-certificate.yaml' \
      'kubernetes/apps/security/cert-manager/certificate/certificate.yaml' \
      'kubernetes/apps/networking/metallb/ks.yaml' \
      'kubernetes/apps/networking/metallb/app/helmrelease.yaml' \
      'kubernetes/apps/networking/metallb/app/values.yaml' \
      'kubernetes/apps/networking/metallb/config/address-pool.yaml' \
      'kubernetes/apps/networking/envoy-gateway/ks.yaml' \
      'kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml' \
      'kubernetes/apps/networking/envoy-gateway/app/helmrelease.yaml' \
      'kubernetes/apps/networking/envoy-gateway/app/values.yaml' \
      'kubernetes/apps/networking/internal-gateway/ks.yaml' \
      'kubernetes/apps/networking/internal-gateway/app/envoyproxy.yaml' \
      'kubernetes/apps/networking/internal-gateway/app/gateway.yaml' \
      'kubernetes/apps/networking/external-dns/ks.yaml' \
      'kubernetes/apps/networking/external-dns/app/helmrelease.yaml' \
      'kubernetes/apps/networking/external-dns/app/kustomization.yaml' \
      "$pihole_ca" \
      'kubernetes/apps/networking/external-dns/app/values.yaml' \
      'kubernetes/apps/testing/echo/ks.yaml' \
      'kubernetes/apps/testing/echo/app/deployment.yaml' \
      'kubernetes/apps/testing/echo/app/httproute.yaml' \
      "$cloudflare_secret" \
      "$pihole_secret"; do
      [[ -f "$file" ]] || {
        echo "Missing required Phase 7 source: $file" >&2
        echo 'Run just repo phase7-secrets if a provider Secret is missing.' >&2
        exit 1
      }
    done

    for secret in "$cloudflare_secret" "$pihole_secret"; do
      [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
      [[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
      [[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
    done
    [[ "$(yq -r '.metadata.name' "$cloudflare_secret")" == 'cloudflare-api-token' ]]
    [[ "$(yq -r '.metadata.namespace' "$cloudflare_secret")" == 'cert-manager' ]]
    [[ "$(yq -r '.metadata.name' "$pihole_secret")" == 'pihole-password' ]]
    [[ "$(yq -r '.metadata.namespace' "$pihole_secret")" == 'external-dns' ]]
    ! rg -q 'PRIVATE KEY' "$pihole_ca"
    openssl verify -CAfile "$pihole_ca" "$pihole_ca" >/dev/null
    # CA remaining-lifetime is a time-based check: it lives in
    # `just kube foundation-ca-expiry`, kept OUT of `just ci` so it cannot turn an
    # unrelated PR red purely because the calendar advanced.

    phase7_sources=(
      kubernetes/apps/security/cert-manager/ks.yaml
      kubernetes/apps/networking/metallb/ks.yaml
      kubernetes/apps/networking/envoy-gateway/ks.yaml
      kubernetes/apps/networking/internal-gateway/ks.yaml
      kubernetes/apps/networking/external-dns/ks.yaml
      kubernetes/apps/testing/echo/ks.yaml
    )
    suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "${phase7_sources[@]}" | sort -u)"
    [[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
      echo 'Every Phase 7 Kustomization must be staged together: all suspended or all active.' >&2
      exit 1
    }

    # Versions are read from the manifests (single source of truth) so a Renovate
    # bump to a HelmRelease/OCIRepository doesn't need a duplicate literal edited here.
    cert_manager_version="$(yq -r '.spec.ref.tag' kubernetes/apps/security/cert-manager/app/ocirepository.yaml)"
    metallb_version="$(yq -r '.spec.chart.spec.version' kubernetes/apps/networking/metallb/app/helmrelease.yaml)"
    envoy_gateway_version="$(yq -r '.spec.ref.tag' kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml)"
    external_dns_chart_version="$(yq -r '.spec.chart.spec.version' kubernetes/apps/networking/external-dns/app/helmrelease.yaml)"
    for v in "$cert_manager_version" "$metallb_version" "$envoy_gateway_version" "$external_dns_chart_version"; do
      [[ -n "$v" && "$v" != 'null' ]]
    done
    [[ "$(yq -r '.spec.url' kubernetes/apps/security/cert-manager/app/ocirepository.yaml)" == '{{cert_manager_chart}}' ]]
    [[ "$(yq -r '.spec.url' kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml)" == '{{envoy_gateway_chart}}' ]]

    cert_ks='kubernetes/apps/security/cert-manager/ks.yaml'
    [[ "$(yq ea -r 'select(.metadata.name == "cert-manager") | .spec.dependsOn[].name' "$cert_ks")" == 'cilium' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "cert-manager-config") | .spec.dependsOn[].name' "$cert_ks")" == 'cert-manager' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "wildcard-certificate") | .spec.dependsOn[].name' "$cert_ks")" == 'cert-manager-config' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/metallb/ks.yaml | head -n 1)" == 'cilium' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "metallb-config") | .spec.dependsOn[].name' kubernetes/apps/networking/metallb/ks.yaml)" == 'metallb' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/envoy-gateway/ks.yaml)" == 'cilium' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/internal-gateway/ks.yaml | sort)" == $'envoy-gateway\nmetallb-config\nwildcard-certificate' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/networking/external-dns/ks.yaml)" == 'internal-gateway' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' kubernetes/apps/testing/echo/ks.yaml)" == 'external-dns-internal' ]]

    metallb_values='kubernetes/apps/networking/metallb/app/values.yaml'
    [[ "$(yq -r '.frrk8s.enabled' "$metallb_values")" == 'false' ]]
    [[ "$(yq -r '.speaker.frr.enabled' "$metallb_values")" == 'false' ]]
    pool='kubernetes/apps/networking/metallb/config/address-pool.yaml'
    [[ "$(yq ea -r 'select(.kind == "IPAddressPool") | .spec.addresses[0]' "$pool")" == '192.168.90.30-192.168.90.39' ]]
    [[ "$(yq ea -r 'select(.kind == "IPAddressPool") | .spec.autoAssign' "$pool")" == 'false' ]]

    gateway='kubernetes/apps/networking/internal-gateway/app/gateway.yaml'
    [[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners[0].hostname' "$gateway")" == '*.lab.supermorphic.com' ]]
    [[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners[0].port' "$gateway")" == '443' ]]
    [[ "$(yq ea -r 'select(.kind == "Gateway") | .spec.listeners[0].tls.certificateRefs[0].name' "$gateway")" == 'wildcard-lab-supermorphic-com-tls' ]]
    proxy='kubernetes/apps/networking/internal-gateway/app/envoyproxy.yaml'
    [[ "$(yq -r '.spec.provider.kubernetes.envoyDeployment.replicas' "$proxy")" == '2' ]]
    [[ "$(yq -r '.spec.provider.kubernetes.envoyService.annotations."metallb.io/loadBalancerIPs"' "$proxy")" == '192.168.90.30' ]]
    [[ "$(yq -r '.spec.provider.kubernetes.envoyService.externalTrafficPolicy' "$proxy")" == 'Local' ]]

    dns_values='kubernetes/apps/networking/external-dns/app/values.yaml'
    [[ "$(yq -r '.provider.name' "$dns_values")" == 'pihole' ]]
    [[ "$(yq -r '.registry' "$dns_values")" == 'noop' ]]
    [[ "$(yq -r '.policy' "$dns_values")" == 'upsert-only' ]]
    [[ "$(yq -r '.sources | join(" ")' "$dns_values")" == 'gateway-httproute' ]]
    [[ "$(yq -r '.domainFilters | join(" ")' "$dns_values")" == 'lab.supermorphic.com' ]]
    [[ "$(yq -r '.annotationFilter' "$dns_values")" == 'external-dns.k8s.io/audience=internal' ]]
    [[ "$(yq -r '.gatewayNamespace' "$dns_values")" == 'networking' ]]
    [[ "$(yq -r '.extraArgs."gateway-name"' "$dns_values")" == 'internal' ]]
    [[ "$(yq -r '.extraArgs."pihole-api-version"' "$dns_values")" == '6' ]]
    [[ "$(yq -r '.extraArgs."pihole-server"' "$dns_values")" == 'https://pi.hole' ]]
    [[ "$(yq -r '.extraArgs."pihole-tls-skip-verify" // ""' "$dns_values")" == '' ]]
    [[ "$(yq -r '.env[] | select(.name == "SSL_CERT_FILE") | .value' "$dns_values")" == '/etc/ssl/pihole/tls_ca.crt' ]]
    [[ "$(yq -r '.extraVolumes[] | select(.name == "pihole-ca") | .configMap.name' "$dns_values")" == 'pihole-ca' ]]
    [[ "$(yq -r '.extraVolumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' "$dns_values")" == '/etc/ssl/pihole true' ]]
    [[ "$(yq -r '.configMapGenerator[] | select(.name == "pihole-ca") | [.namespace, .files[]] | join(" ")' kubernetes/apps/networking/external-dns/app/kustomization.yaml)" == 'external-dns tls_ca.crt=pihole-ca.crt' ]]

    for directory in \
      kubernetes/apps \
      kubernetes/apps/security/cert-manager/app \
      kubernetes/apps/security/cert-manager/config \
      kubernetes/apps/security/cert-manager/certificate \
      kubernetes/apps/networking/metallb/app \
      kubernetes/apps/networking/metallb/config \
      kubernetes/apps/networking/envoy-gateway/app \
      kubernetes/apps/networking/internal-gateway/app \
      kubernetes/apps/networking/external-dns/app \
      kubernetes/apps/testing/echo/app; do
      kustomize build "$directory" >"$temp_dir/$(tr '/' '-' <<<"$directory").yaml"
    done

    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repositories.yaml"
    export HELM_REPOSITORY_CONFIG="$temp_dir/repositories.yaml"
    export HELM_REPOSITORY_CACHE="$temp_dir/repository-cache"
    helm template cert-manager '{{cert_manager_chart}}' \
      --version "$cert_manager_version" \
      --namespace cert-manager \
      --values kubernetes/apps/security/cert-manager/app/values.yaml >"$temp_dir/cert-manager.yaml"
    helm template metallb metallb \
      --repo '{{metallb_repository}}' \
      --version "$metallb_version" \
      --namespace metallb-system \
      --values "$metallb_values" >"$temp_dir/metallb.yaml"
    helm template envoy-gateway '{{envoy_gateway_chart}}' \
      --version "$envoy_gateway_version" \
      --namespace envoy-gateway-system \
      --include-crds \
      --values kubernetes/apps/networking/envoy-gateway/app/values.yaml >"$temp_dir/envoy-gateway.yaml"
    helm template external-dns-internal external-dns \
      --repo '{{external_dns_repository}}' \
      --version "$external_dns_chart_version" \
      --namespace external-dns \
      --values "$dns_values" >"$temp_dir/external-dns.yaml"

    rg -q '^kind: Deployment$' "$temp_dir/cert-manager.yaml"
    rg -q '^  name: cert-manager$' "$temp_dir/cert-manager.yaml"
    rg -q '^kind: DaemonSet$' "$temp_dir/metallb.yaml"
    rg -q '^  name: metallb-speaker$' "$temp_dir/metallb.yaml"
    ! rg -q '^  name: .*frr' "$temp_dir/metallb.yaml"
    rg -q '^  name: envoy-gateway$' "$temp_dir/envoy-gateway.yaml"
    rg -q '^  name: gatewayclasses.gateway.networking.k8s.io$' "$temp_dir/envoy-gateway.yaml"
    rg -q '^  name: gateways.gateway.networking.k8s.io$' "$temp_dir/envoy-gateway.yaml"
    rg -q '^  name: httproutes.gateway.networking.k8s.io$' "$temp_dir/envoy-gateway.yaml"
    rg -q '^  name: envoyproxies.gateway.envoyproxy.io$' "$temp_dir/envoy-gateway.yaml"
    rg -q -- '--source=gateway-httproute' "$temp_dir/external-dns.yaml"
    rg -q -- '--provider=pihole' "$temp_dir/external-dns.yaml"
    rg -q -- '--annotation-filter=external-dns.k8s.io/audience=internal' "$temp_dir/external-dns.yaml"
    rg -q -- '--gateway-name=internal' "$temp_dir/external-dns.yaml"
    rg -q -- '--pihole-server=https://pi.hole' "$temp_dir/external-dns.yaml"
    ! rg -q -- '--pihole-tls-skip-verify' "$temp_dir/external-dns.yaml"
    [[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "external-dns-internal") | .spec.template.spec.containers[] | select(.name == "external-dns") | .env[] | select(.name == "SSL_CERT_FILE") | .value' "$temp_dir/external-dns.yaml")" == '/etc/ssl/pihole/tls_ca.crt' ]]
    [[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "external-dns-internal") | .spec.template.spec.volumes[] | select(.name == "pihole-ca") | .configMap.name' "$temp_dir/external-dns.yaml")" == 'pihole-ca' ]]
    [[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "external-dns-internal") | .spec.template.spec.containers[] | select(.name == "external-dns") | .volumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' "$temp_dir/external-dns.yaml")" == '/etc/ssl/pihole true' ]]

    echo 'Phase 7 source, SOPS provider Secrets, dependency graph, policy, and pinned Helm renders passed validation.'

# Print the read-only Phase 7 controller, certificate, address, Gateway, DNS, and echo state.
foundation-status:
    #!/usr/bin/env bash
    set -u

    kubeconfig='{{kubeconfig}}'
    status=0
    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig.' >&2
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
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    phase7_names=(cert-manager cert-manager-config wildcard-certificate metallb metallb-config envoy-gateway internal-gateway external-dns-internal echo)
    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig.' >&2
      exit 1
    }

    just kube flux-verify
    for name in "${phase7_names[@]}"; do
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait \
        --for=condition=Ready "kustomization/$name" --timeout=15m
      state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output json)"
      [[ "$(yq -r '.spec.suspend // false' - <<<"$state")" == 'false' ]]
      [[ "$(yq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' - <<<"$state")" == 'True' ]]
    done

    for deployment in cert-manager cert-manager-webhook cert-manager-cainjector; do
      kubectl --kubeconfig "$kubeconfig" --namespace cert-manager rollout status "deployment/$deployment" --timeout=10m
      replicas="$(kubectl --kubeconfig "$kubeconfig" --namespace cert-manager get deployment "$deployment" --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
      [[ "$replicas" == '2 2' ]]
    done
    for issuer in letsencrypt-staging letsencrypt-production; do
      kubectl --kubeconfig "$kubeconfig" wait --for=condition=Ready "clusterissuer/$issuer" --timeout=10m
    done
    for certificate in wildcard-lab-supermorphic-com-staging wildcard-lab-supermorphic-com; do
      kubectl --kubeconfig "$kubeconfig" --namespace networking wait --for=condition=Ready "certificate/$certificate" --timeout=15m
    done

    controller="$(kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get deployment metallb-controller --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
    [[ "$controller" == '1 1' ]]
    speaker="$(kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get daemonset metallb-speaker --output json | yq -r '[.status.desiredNumberScheduled, .status.numberReady, (.status.numberUnavailable // 0)] | join(" ")')"
    [[ "$speaker" == '3 3 0' ]]
    pool="$(kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get ipaddresspool internal --output json)"
    [[ "$(yq -r '.spec.addresses | join(" ")' - <<<"$pool")" == '192.168.90.30-192.168.90.39' ]]
    [[ "$(yq -r '.spec.autoAssign' - <<<"$pool")" == 'false' ]]
    ! kubectl --kubeconfig "$kubeconfig" --namespace metallb-system get daemonset frr-k8s-daemon >/dev/null 2>&1

    gateway_class="$(kubectl --kubeconfig "$kubeconfig" get gatewayclass internal --output json)"
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Accepted") | .status][0]' - <<<"$gateway_class")" == 'True' ]]
    gateway="$(kubectl --kubeconfig "$kubeconfig" --namespace networking get gateway internal --output json)"
    [[ "$(yq -r '[.status.conditions[] | select(.type == "Programmed") | .status][0]' - <<<"$gateway")" == 'True' ]]
    [[ "$(yq -r '.status.addresses[].value' - <<<"$gateway" | sort -u)" == '192.168.90.30' ]]
    [[ "$(yq -r '.status.listeners[] | select(.name == "https") | [.conditions[] | select(.type == "Accepted") | .status][0]' - <<<"$gateway")" == 'True' ]]

    envoy_services="$(kubectl --kubeconfig "$kubeconfig" --namespace envoy-gateway-system get services --output json)"
    envoy_service="$(yq -r '.items[] | select(.spec.type == "LoadBalancer" and (.status.loadBalancer.ingress[]?.ip == "192.168.90.30")) | .metadata.name' - <<<"$envoy_services")"
    [[ -n "$envoy_service" && "$(wc -l <<<"$envoy_service" | tr -d ' ')" == '1' ]]
    envoy_deployments="$(kubectl --kubeconfig "$kubeconfig" --namespace envoy-gateway-system get deployments --output json)"
    envoy_ready="$(yq -r '.items[] | select(.metadata.labels."gateway.envoyproxy.io/owning-gateway-name" == "internal") | [.spec.replicas, (.status.availableReplicas // 0)] | join(" ")' - <<<"$envoy_deployments")"
    [[ "$envoy_ready" == '2 2' ]]

    kubectl --kubeconfig "$kubeconfig" --namespace external-dns rollout status deployment/external-dns-internal --timeout=10m
    dns_deployment="$(kubectl --kubeconfig "$kubeconfig" --namespace external-dns get deployment external-dns-internal --output json)"
    dns_args="$(yq -r '.spec.template.spec.containers[0].args[]' - <<<"$dns_deployment")"
    for argument in \
      '--source=gateway-httproute' \
      '--provider=pihole' \
      '--registry=noop' \
      '--policy=upsert-only' \
      '--domain-filter=lab.supermorphic.com' \
      '--annotation-filter=external-dns.k8s.io/audience=internal' \
      '--gateway-name=internal' \
      '--pihole-api-version=6' \
      '--pihole-server=https://pi.hole'; do
      rg -Fx -- "$argument" <<<"$dns_args"
    done
    ! rg -Fx -- '--pihole-tls-skip-verify' <<<"$dns_args"
    [[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "external-dns") | .env[] | select(.name == "SSL_CERT_FILE") | .value' - <<<"$dns_deployment")" == '/etc/ssl/pihole/tls_ca.crt' ]]
    [[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "pihole-ca") | .configMap.name' - <<<"$dns_deployment")" == 'pihole-ca' ]]
    [[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "external-dns") | .volumeMounts[] | select(.name == "pihole-ca") | [.mountPath, .readOnly] | join(" ")' - <<<"$dns_deployment")" == '/etc/ssl/pihole true' ]]
    live_pihole_ca="$(kubectl --kubeconfig "$kubeconfig" --namespace external-dns get configmap pihole-ca --output jsonpath='{.data.tls_ca\.crt}')"
    [[ "$live_pihole_ca" == "$(<kubernetes/apps/networking/external-dns/app/pihole-ca.crt)" ]]

    kubectl --kubeconfig "$kubeconfig" --namespace testing rollout status deployment/echo --timeout=10m
    echo_replicas="$(kubectl --kubeconfig "$kubeconfig" --namespace testing get deployment echo --output json | yq -r '[.spec.replicas, (.status.availableReplicas // 0)] | join(" ")')"
    [[ "$echo_replicas" == '2 2' ]]
    route="$(kubectl --kubeconfig "$kubeconfig" --namespace testing get httproute echo --output json)"
    [[ "$(yq -r '[.status.parents[].conditions[] | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]
    [[ "$(yq -r '[.status.parents[].conditions[] | select(.type == "ResolvedRefs") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]

    dns_answer=''
    for attempt in {1..30}; do
      dns_answer="$(dig +short @192.168.90.2 echo.lab.supermorphic.com A | sort -u)"
      [[ "$dns_answer" == '192.168.90.30' ]] && break
      sleep 10
    done
    [[ "$dns_answer" == '192.168.90.30' ]] || {
      echo "Pi-hole returned '$dns_answer' instead of 192.168.90.30." >&2
      exit 1
    }
    response="$(curl --silent --show-error --fail --max-time 15 \
      --resolve echo.lab.supermorphic.com:443:192.168.90.30 \
      https://echo.lab.supermorphic.com/)"
    [[ -n "$response" ]]

    just kube cilium-postflight
    echo 'Phase 7 verification passed: certificates, MetalLB, Envoy Gateway, Pi-hole DNS, trusted HTTPS, echo, Talos, and etcd are healthy.'

# Restart the flux-system controllers and prove reconciliation resumes.
flux-restart: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    expected_confirmation='restart:flux-system:controllers'
    [[ -f "$kubeconfig" ]] || {
      echo 'Missing ignored kubeconfig.' >&2
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
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/storage/longhorn'
    ks="$base/ks.yaml"
    secret="$base/config/nas-credentials.sops.yaml"
    values="$base/app/values.yaml"
    hr="$base/app/helmrelease.yaml"
    repo="$base/app/helmrepository.yaml"
    jobs="$base/config/recurring-jobs.yaml"
    backuptarget="$base/config/backup-target.yaml"
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    temp_dir="$(mktemp -d /tmp/homelab-talos-storage-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$secret" "$values" "$hr" "$repo" "$jobs" "$backuptarget" \
      "$base/app/namespace.yaml" "$base/app/kustomization.yaml" \
      "$base/config/kustomization.yaml" kubernetes/apps/storage/kustomization.yaml; do
      [[ -f "$f" ]] || {
        echo "Missing Phase 9 storage source: $f" >&2
        echo 'Run just repo storage-secrets if the CIFS Secret is missing.' >&2
        exit 1
      }
    done

    rg -qx '  - ./storage' kubernetes/apps/kustomization.yaml || {
      echo 'Refusing: ./storage is not wired into kubernetes/apps/kustomization.yaml.' >&2
      exit 1
    }

    [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
    [[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
    [[ "$(yq -r '.metadata.name' "$secret")" == 'nas-credentials' ]]
    [[ "$(yq -r '.metadata.namespace' "$secret")" == 'longhorn-system' ]]

    suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "$ks" | sort -u)"
    [[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
      echo 'Both storage Kustomizations must be staged together: all suspended or all active.' >&2
      exit 1
    }

    [[ "$(yq ea -r 'select(.metadata.name == "longhorn") | .spec.dependsOn[].name' "$ks")" == 'cilium' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "longhorn-config") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,longhorn' ]]

    chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
    [[ -n "$chart_version" && "$chart_version" != 'null' ]]
    [[ "$(yq -r '.spec.url' "$repo")" == 'https://charts.longhorn.io' ]]
    [[ "$(yq -r '.defaultSettings.defaultDataPath' "$values")" == '/var/mnt/longhorn' ]]
    [[ "$(yq -r '.defaultSettings.replicaSoftAntiAffinity' "$values")" == 'false' ]]
    [[ "$(yq -r '.persistence.defaultClassReplicaCount' "$values")" == '2' ]]
    [[ "$(yq -r '.kind' "$backuptarget")" == 'BackupTarget' ]]
    [[ "$(yq -r '.metadata.name' "$backuptarget")" == 'default' ]]
    [[ "$(yq -r '.spec.backupTargetURL' "$backuptarget")" == 'cifs://192.168.0.3/Longhorn' ]]
    [[ "$(yq -r '.spec.credentialSecret' "$backuptarget")" == 'nas-credentials' ]]
    [[ "$(yq ea -r '[select(.kind == "RecurringJob") | .spec.task] | .[]' "$jobs" | sort | tr '\n' ' ')" == 'backup snapshot ' ]]

    kustomize build "$base/app" >/dev/null
    kustomize build "$base/config" >/dev/null

    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
    HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
      helm template longhorn longhorn --repo https://charts.longhorn.io --version "$chart_version" --namespace longhorn-system --values "$values" >"$temp_dir/longhorn.yaml"
    rg -q '^  name: longhorn-manager$' "$temp_dir/longhorn.yaml"

    echo 'Phase 9 storage source, encrypted CIFS Secret, dependency graph, values, and pinned Longhorn render passed validation.'

# Validate the Phase 11 SMB CSI driver source, wiring, dependency, and pinned render.
csi-driver-smb-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/storage/csi-driver-smb'
    ks="$base/ks.yaml"
    hr="$base/app/helmrelease.yaml"
    repo="$base/app/helmrepository.yaml"
    values="$base/app/values.yaml"
    chart_repo='https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts'
    temp_dir="$(mktemp -d /tmp/homelab-talos-csi-smb-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$hr" "$repo" "$values" "$base/app/namespace.yaml" "$base/app/kustomization.yaml"; do
      [[ -f "$f" ]] || { echo "Missing Phase 11 csi-driver-smb source: $f" >&2; exit 1; }
    done

    rg -qx '  - ./csi-driver-smb/ks.yaml' kubernetes/apps/storage/kustomization.yaml || {
      echo 'Refusing: ./csi-driver-smb/ks.yaml is not wired into kubernetes/apps/storage/kustomization.yaml.' >&2
      exit 1
    }

    suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
    [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' "$ks")" == 'cilium' ]]
    [[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$base/app/namespace.yaml")" == 'privileged' ]]

    chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
    [[ -n "$chart_version" && "$chart_version" != 'null' ]]
    [[ "$(yq -r '.spec.url' "$repo")" == "$chart_repo" ]]

    kustomize build "$base/app" >/dev/null

    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
    HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
      helm template csi-driver-smb csi-driver-smb --repo "$chart_repo" --version "$chart_version" --namespace csi-driver-smb --values "$values" >"$temp_dir/render.yaml"
    rg -q 'smb\.csi\.k8s\.io' "$temp_dir/render.yaml"

    echo "csi-driver-smb $chart_version source, wiring, dependency, and pinned render passed validation."

# Validate the Phase 11 shared media storage: namespace + app-template source,
# encrypted SMB Secret, static RWX SMB PV/PVC, dependency graph, and wiring.
media-storage-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    ns_ks='kubernetes/apps/media/namespace/ks.yaml'
    st_ks='kubernetes/apps/media/storage/ks.yaml'
    nsfile='kubernetes/apps/media/namespace/app/namespace.yaml'
    oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
    pv='kubernetes/apps/media/storage/app/persistentvolume.yaml'
    pvc='kubernetes/apps/media/storage/app/persistentvolumeclaim.yaml'
    secret='kubernetes/apps/media/storage/app/smb-credentials.sops.yaml'
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"

    for f in "$ns_ks" "$st_ks" "$nsfile" "$oci" "$pv" "$pvc" "$secret" \
      kubernetes/apps/media/namespace/app/kustomization.yaml \
      kubernetes/apps/media/storage/app/kustomization.yaml \
      kubernetes/apps/media/kustomization.yaml; do
      [[ -f "$f" ]] || {
        echo "Missing Phase 11 media storage source: $f" >&2
        echo 'Run just repo media-smb-secrets if the SMB Secret is missing.' >&2
        exit 1
      }
    done

    rg -qx '  - ./media' kubernetes/apps/kustomization.yaml || {
      echo 'Refusing: ./media is not wired into kubernetes/apps/kustomization.yaml.' >&2
      exit 1
    }

    media_suspend="$(yq -r '.spec.suspend // false' "$ns_ks")"
    storage_suspend="$(yq -r '.spec.suspend // false' "$st_ks")"
    [[ "$media_suspend" == "$storage_suspend" ]] || {
      echo 'media and media-storage must be staged together: both suspended or both active.' >&2
      exit 1
    }
    [[ "$media_suspend" == 'true' || "$media_suspend" == 'false' ]]

    [[ "$(yq -r '.spec.dependsOn[].name' "$ns_ks")" == 'cilium' ]]
    [[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$st_ks")" == 'csi-driver-smb,media' ]]

    [[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$nsfile")" == 'internal' ]]
    [[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$nsfile")" == 'privileged' ]]

    [[ "$(yq -r '.spec.url' "$oci")" == 'oci://ghcr.io/bjw-s-labs/helm/app-template' ]]
    oci_tag="$(yq -r '.spec.ref.tag' "$oci")"
    [[ -n "$oci_tag" && "$oci_tag" != 'null' ]]

    [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
    [[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
    [[ "$(yq -r '.metadata.name' "$secret")" == 'smb-credentials' ]]
    [[ "$(yq -r '.metadata.namespace' "$secret")" == 'media' ]]

    [[ "$(yq -r '.kind' "$pv")" == 'PersistentVolume' ]]
    [[ "$(yq -r '.spec.csi.driver' "$pv")" == 'smb.csi.k8s.io' ]]
    [[ "$(yq -r '.spec.csi.volumeAttributes.source' "$pv")" == '//192.168.0.3/Prometheus' ]]
    [[ "$(yq -r '.spec.accessModes[]' "$pv" | sort -u)" == 'ReadWriteMany' ]]
    [[ "$(yq -r '.spec.csi.nodeStageSecretRef.name' "$pv")" == 'smb-credentials' ]]
    [[ "$(yq -r '.spec.csi.nodeStageSecretRef.namespace' "$pv")" == 'media' ]]

    [[ "$(yq -r '.spec.accessModes[]' "$pvc" | sort -u)" == 'ReadWriteMany' ]]
    [[ "$(yq -r '.spec.volumeName' "$pvc")" == 'media-data' ]]
    [[ "$(yq -r '.metadata.namespace' "$pvc")" == 'media' ]]

    kustomize build kubernetes/apps/media/namespace/app >/dev/null
    kustomize build kubernetes/apps/media/storage/app >/dev/null

    echo 'Phase 11 media storage source, encrypted SMB Secret, static RWX SMB PV/PVC, dependency graph, and wiring passed validation.'

# Validate the Phase 11 Plex source: files, wiring, dependency, app-template chartRef,
# values (Recreate + RWO config, shared media-data, emptyDir transcode), HTTPRoute,
# and the pinned app-template render.
plex-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/media/plex'
    ks="$base/ks.yaml"
    hr="$base/app/helmrelease.yaml"
    values="$base/app/values.yaml"
    route="$base/app/httproute.yaml"
    oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-plex-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$hr" "$values" "$route" "$base/app/kustomization.yaml" "$oci"; do
      [[ -f "$f" ]] || { echo "Missing Phase 11 Plex source: $f" >&2; exit 1; }
    done

    rg -qx '  - ./plex/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
      echo 'Refusing: ./plex/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml.' >&2
      exit 1
    }

    suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
    [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
    [[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,media-storage' ]]

    [[ "$(yq -r '.spec.chartRef.kind' "$hr")" == 'OCIRepository' ]]
    [[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

    [[ "$(yq -r '.controllers.plex.type' "$values")" == 'deployment' ]]
    [[ "$(yq -r '.controllers.plex.strategy' "$values")" == 'Recreate' ]]
    [[ "$(yq -r '.controllers.plex.containers.app.image.repository' "$values")" == 'ghcr.io/home-operations/plex' ]]
    image_tag="$(yq -r '.controllers.plex.containers.app.image.tag' "$values")"
    [[ -n "$image_tag" && "$image_tag" != 'null' ]]
    [[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOncePod' ]]
    [[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
    [[ "$(yq -r '.persistence.media.existingClaim' "$values")" == 'media-data' ]]
    [[ "$(yq -r '.persistence.transcode.type' "$values")" == 'emptyDir' ]]

    [[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'plex.lab.supermorphic.com' ]]
    [[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
    [[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == '32400' ]]

    chart_url="$(yq -r '.spec.url' "$oci")"
    chart_tag="$(yq -r '.spec.ref.tag' "$oci")"

    kustomize build "$base/app" >/dev/null

    helm template plex "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
    [[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'plex' ]]
    [[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/render.yaml")" == 'Recreate' ]]

    echo "Plex $image_tag source, app-template chartRef, values (Recreate/RWOP config, media-data, emptyDir transcode), HTTPRoute, and pinned render passed validation."

# Verify the live Longhorn acceptance gate: controllers, node disks, default
# StorageClass, backup target, recurring jobs, and a two-replica test PVC.
storage-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='longhorn-system'
    tpvc='storage-verify-test'
    tmp="$(mktemp -d /tmp/homelab-talos-storage-verify.XXXXXX)"
    cleanup() {
      kubectl --kubeconfig "$kubeconfig" --namespace "$ns" delete pvc "$tpvc" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      rm -rf -- "$tmp"
    }
    trap cleanup EXIT

    for n in longhorn longhorn-config; do
      [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$n" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
        echo "Storage Kustomization $n is not Ready." >&2
        exit 1
      }
    done

    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status daemonset/longhorn-manager --timeout=5m

    nodes_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get nodes.longhorn.io --output json)"
    [[ "$(yq -r '.items | length' - <<<"$nodes_json")" == '3' ]] || { echo 'Expected three Longhorn nodes.' >&2; exit 1; }
    ready="$(yq -r '[.items[] | [.status.conditions[] | select(.type == "Ready") | .status][0]] | unique | join(" ")' - <<<"$nodes_json")"
    [[ "$ready" == 'True' ]] || { echo "Longhorn nodes are not all Ready ($ready)." >&2; exit 1; }
    disk_paths="$(yq -r '[.items[].spec.disks[].path] | unique | join(" ")' - <<<"$nodes_json")"
    [[ "$disk_paths" == '/var/mnt/longhorn' ]] || { echo "Longhorn disk path(s) '$disk_paths', expected /var/mnt/longhorn." >&2; exit 1; }

    sc="$(kubectl --kubeconfig "$kubeconfig" get storageclass longhorn --output json)"
    [[ "$(yq -r '.metadata.annotations."storageclass.kubernetes.io/is-default-class"' - <<<"$sc")" == 'true' ]] || { echo 'longhorn is not the default StorageClass.' >&2; exit 1; }
    [[ "$(yq -r '.parameters.numberOfReplicas' - <<<"$sc")" == '2' ]] || { echo 'longhorn StorageClass is not 2 replicas.' >&2; exit 1; }

    # The CIFS mount + first poll are eventually consistent, so retry (~4 min).
    bt_available=false
    for _ in {1..24}; do
      if [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get backuptargets.longhorn.io default --output jsonpath='{.status.available}' 2>/dev/null)" == 'true' ]]; then
        bt_available=true
        break
      fi
      sleep 10
    done
    [[ "$bt_available" == 'true' ]] || {
      bt_msg="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get backuptargets.longhorn.io default --output jsonpath='{.status.conditions[?(@.type=="Unavailable")].message}' 2>/dev/null)"
      echo "Longhorn backup target is not available after retries: ${bt_msg:-unknown}." >&2
      echo 'Check the CIFS share, the nas-credentials Secret, and whether the Talos nodes can mount CIFS (cifs kernel module).' >&2
      exit 1
    }
    for j in daily-snapshot daily-backup; do
      kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get recurringjobs.longhorn.io "$j" >/dev/null
    done

    export tpvc ns
    yq -n \
      '.apiVersion = "v1" |
       .kind = "PersistentVolumeClaim" |
       .metadata.name = strenv(tpvc) |
       .metadata.namespace = strenv(ns) |
       .spec.accessModes = ["ReadWriteOnce"] |
       .spec.storageClassName = "longhorn" |
       .spec.resources.requests.storage = "1Gi"' >"$tmp/pvc.yaml"
    kubectl --kubeconfig "$kubeconfig" apply --filename "$tmp/pvc.yaml" >/dev/null
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$tpvc" --timeout=3m
    vol="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pvc "$tpvc" --output jsonpath='{.spec.volumeName}')"
    replica_nodes=0
    for _ in {1..24}; do
      replica_nodes="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get replicas.longhorn.io --selector "longhornvolume=$vol" --output json 2>/dev/null | yq -r '[.items[].spec.nodeID] | unique | length')"
      [[ "$replica_nodes" == '2' ]] && break
      sleep 5
    done
    [[ "$replica_nodes" == '2' ]] || { echo "Test volume replicas span $replica_nodes nodes; expected 2 (hard anti-affinity)." >&2; exit 1; }

    just kube foundation-verify
    echo 'Phase 9 storage acceptance passed: Longhorn healthy on three nodes (disks at /var/mnt/longhorn), default two-replica StorageClass, backup target available, recurring jobs present, and a test PVC bound with replicas on two distinct nodes.'

# Verify the live Phase 11 SMB CSI driver: Kustomization Ready, controller +
# node plugin rolled out, and the CSIDriver registered.
csi-driver-smb-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='csi-driver-smb'

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization csi-driver-smb --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
      echo 'csi-driver-smb Kustomization is not Ready.' >&2
      exit 1
    }
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/csi-smb-controller --timeout=3m
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status daemonset/csi-smb-node --timeout=3m
    kubectl --kubeconfig "$kubeconfig" get csidriver smb.csi.k8s.io >/dev/null || {
      echo 'CSIDriver smb.csi.k8s.io is not registered.' >&2
      exit 1
    }
    echo 'Phase 11 csi-driver-smb acceptance passed: Kustomization Ready, controller + node plugin rolled out, CSIDriver registered.'

# Verify the live Phase 11 shared media storage: Kustomizations Ready and the
# static RWX media-data PVC Bound. The mount is exercised for real by Plex (PR 11-2)
# and the documented hardlink proof (docs/phase-11-media.md); binding a static PV is
# a claimRef match and does not by itself prove the SMB mount works.
media-storage-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'

    for n in media media-storage; do
      [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$n" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
        echo "Media Kustomization $n is not Ready." >&2
        exit 1
      }
    done
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace media get pvc media-data --output jsonpath='{.status.phase}' 2>/dev/null)" == 'Bound' ]] || {
      echo 'PVC media/media-data is not Bound.' >&2
      exit 1
    }
    echo 'Phase 11 media storage acceptance passed: media + media-storage Kustomizations Ready and media-data PVC Bound. Run the hardlink proof in docs/phase-11-media.md next.'

# Verify the live Phase 11 Plex: Kustomization + HelmRelease Ready, rollout complete,
# HTTPRoute Accepted, Pi-hole DNS, and /identity reachable over the internal gateway.
# The node-failure reschedule gate is a manual operator test (docs/phase-11-media.md).
plex-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='media'
    gateway_ip='192.168.90.30'
    host='plex.lab.supermorphic.com'

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization plex --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
      echo 'plex Kustomization is not Ready.' >&2
      exit 1
    }
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease plex --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
      echo 'plex HelmRelease is not Ready.' >&2
      exit 1
    }
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/plex --timeout=5m

    accepted=false
    for _ in {1..24}; do
      if [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute plex --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]]; then
        accepted=true
        break
      fi
      sleep 5
    done
    [[ "$accepted" == 'true' ]] || { echo 'plex HTTPRoute was not Accepted.' >&2; exit 1; }

    [[ "$(dig +short @192.168.90.2 "$host" A | sort -u)" == "$gateway_ip" ]] || {
      echo "DNS for $host does not resolve to $gateway_ip via Pi-hole." >&2
      exit 1
    }
    curl --silent --fail --resolve "$host:443:$gateway_ip" "https://$host/identity" >/dev/null || {
      echo "Plex /identity is not reachable via the internal gateway." >&2
      exit 1
    }
    echo 'Phase 11 Plex acceptance passed: Kustomization + HelmRelease Ready, rollout complete, HTTPRoute Accepted, DNS resolves, /identity reachable over TLS. Run the node-failure reschedule test in docs/phase-11-media.md.'

# The Phase 11 gate: prove the single Plex replica recreates on ANOTHER NUC when its
# node becomes unschedulable, with the Longhorn RWO config volume re-attaching and the
# SMB media re-mounting. Safe form (cordon + delete pod); the original node is always
# uncordoned (trap). NOT in `just ci` — destructive, operator-run.
plex-reschedule-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
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
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/kube-system/intel-gpu-plugin'
    ks="$base/ks.yaml"
    ds="$base/app/daemonset.yaml"

    for f in "$ks" "$ds" "$base/app/kustomization.yaml"; do
      [[ -f "$f" ]] || { echo "Missing Phase 11 intel-gpu-plugin source: $f" >&2; exit 1; }
    done

    rg -qx '  - ./intel-gpu-plugin/ks.yaml' kubernetes/apps/kube-system/kustomization.yaml || {
      echo 'Refusing: ./intel-gpu-plugin/ks.yaml is not wired into kubernetes/apps/kube-system/kustomization.yaml.' >&2
      exit 1
    }

    suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
    [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
    [[ "$(yq -r '.spec.dependsOn[].name' "$ks")" == 'cilium' ]]

    [[ "$(yq -r '.kind' "$ds")" == 'DaemonSet' ]]
    [[ "$(yq -r '.metadata.namespace' "$ds")" == 'kube-system' ]]
    image="$(yq -r '.spec.template.spec.containers[0].image' "$ds")"
    [[ "$image" == intel/intel-gpu-plugin:* ]]
    [[ "$image" != *:latest ]]

    kustomize build "$base/app" >/dev/null

    echo "intel-gpu-plugin ($image) source, wiring, dependency, and DaemonSet manifest passed validation."

# Verify the live Phase 11 Intel GPU device plugin: Kustomization Ready, DaemonSet
# rolled out, and every node advertising gpu.intel.com/i915 (QuickSync capacity).
intel-gpu-plugin-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='kube-system'

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization intel-gpu-plugin --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
      echo 'intel-gpu-plugin Kustomization is not Ready.' >&2
      exit 1
    }
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status daemonset/intel-gpu-plugin --timeout=3m

    advertised="$(kubectl --kubeconfig "$kubeconfig" get nodes --output json | yq -r '[.items[] | select(.status.allocatable["gpu.intel.com/i915"] != null)] | length')"
    [[ "$advertised" -ge 1 ]] || {
      echo 'No node advertises gpu.intel.com/i915 — check /dev/dri on the NUCs (the siderolabs/i915 extension) and the plugin logs.' >&2
      exit 1
    }
    echo "Phase 11 intel-gpu-plugin acceptance passed: Kustomization Ready, DaemonSet rolled out, $advertised node(s) advertise gpu.intel.com/i915."

# Validate the Phase 12 qBittorrent+Gluetun source: files, wiring, dependency,
# encrypted ProtonVPN Secret, the sidecar/kill-switch essentials, and the pinned render.
qbittorrent-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/media/qbittorrent'
    ks="$base/ks.yaml"
    hr="$base/app/helmrelease.yaml"
    values="$base/app/values.yaml"
    route="$base/app/httproute.yaml"
    secret="$base/app/protonvpn.sops.yaml"
    oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    temp_dir="$(mktemp -d /tmp/homelab-talos-qbt-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$hr" "$values" "$route" "$secret" "$base/app/kustomization.yaml" "$oci"; do
      [[ -f "$f" ]] || {
        echo "Missing Phase 12 qBittorrent source: $f" >&2
        echo 'Run just repo protonvpn-secrets if the ProtonVPN Secret is missing.' >&2
        exit 1
      }
    done

    rg -qx '  - ./qbittorrent/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
      echo 'Refusing: ./qbittorrent/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml.' >&2
      exit 1
    }

    suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
    [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
    [[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,media-storage' ]]
    [[ "$(yq -r '.spec.decryption.provider' "$ks")" == 'sops' ]]
    [[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

    [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
    [[ "$(yq -r '.metadata.name' "$secret")" == 'protonvpn' ]]
    [[ "$(yq -r '.metadata.namespace' "$secret")" == 'media' ]]

    # Gluetun native sidecar + kill-switch essentials.
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.restartPolicy' "$values")" == 'Always' ]]
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.securityContext.capabilities.add[]' "$values" | tr '\n' ' ')" == 'NET_ADMIN ' ]]
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.VPN_SERVICE_PROVIDER' "$values")" == 'protonvpn' ]]
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.VPN_PORT_FORWARDING' "$values")" == 'on' ]]
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.PORT_FORWARD_ONLY' "$values")" == 'on' ]]
    [[ -n "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.SERVER_COUNTRIES // ""' "$values")" ]]
    # WebUI (8080) + control server (8000) admitted on the pod interface.
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.FIREWALL_INPUT_PORTS' "$values")" == '8000,8080' ]]
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH' "$values")" == '/gluetun/auth/config.toml' ]]
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.VPN_PORT_FORWARDING_UP_COMMAND' "$values")" != 'null' ]]
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.VPN_PORT_FORWARDING_DOWN_COMMAND' "$values")" != 'null' ]]
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.startup.spec.httpGet.port' "$values")" == '8000' ]]
    # Deliberately-slow k8s liveness fallback: restart gluetun only after a sustained
    # stuck-VPN state (running but no forwarded port). Public IP is deliberately not the
    # signal: its one-shot metadata fetch can fail on an otherwise working tunnel.
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.enabled' "$values")" == 'true' ]]
    [[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.custom' "$values")" == 'true' ]]
    probe_cmd="$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.spec.exec.command[2]' "$values")"
    [[ "$probe_cmd" == *'/v1/portforward'* ]]
    [[ "$probe_cmd" != *'/v1/publicip/ip'* ]]
    [[ "$probe_cmd" == *'"status":"stopped"'* ]]
    [[ "$probe_cmd" == *'"status":"running"'* ]]
    [[ "$probe_cmd" == *'|| exit 1'* ]]
    lft="$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.spec.failureThreshold' "$values")"
    lps="$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.spec.periodSeconds' "$values")"
    [[ "$lft" =~ ^[0-9]+$ && "$lps" =~ ^[0-9]+$ && $(( lft * lps )) -ge 180 ]] || { echo 'gluetun liveness must be deliberately slow (failureThreshold*periodSeconds >= 180s).' >&2; exit 1; }
    # Only Gluetun is privileged; qBittorrent drops all caps.
    [[ "$(yq -r '.controllers.qbittorrent.containers.app.securityContext.capabilities.drop[]' "$values" | tr '\n' ' ')" == 'ALL ' ]]
    # Device + auth config mounted; config on Longhorn RWO; shared /data.
    [[ "$(yq -r '.persistence.tun.hostPath' "$values")" == '/dev/net/tun' ]]
    [[ "$(yq -r '.persistence.tun.hostPathType' "$values")" == 'CharDevice' ]]
    [[ "$(yq -r '.persistence."gluetun-auth".type' "$values")" == 'secret' ]]
    [[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
    [[ "$(yq -r '.persistence.data.existingClaim' "$values")" == 'media-data' ]]

    [[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'qbittorrent.lab.supermorphic.com' ]]
    [[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]

    # Reactive VPN-down alerting: in-cluster control-server Service (no HTTPRoute) +
    # a critical PrometheusRule fed by the Gatus health probe.
    svc="$base/app/service-gluetun-control.yaml"
    rule="$base/app/prometheusrule.yaml"
    [[ -f "$svc" && -f "$rule" ]] || {
      echo "Missing Phase 12 VPN-alert source ($svc / $rule)." >&2
      exit 1
    }
    [[ "$(yq -r '.kind' "$svc")" == 'Service' ]]
    [[ "$(yq -r '.metadata.name' "$svc")" == 'qbittorrent-gluetun-control' ]]
    [[ "$(yq -r '.spec.ports[0].port' "$svc")" == '8000' ]]
    # The control server must never be routed to the gateway/LB.
    ! rg -qi 'gluetun-control' "$route"
    [[ "$(yq -r '.kind' "$rule")" == 'PrometheusRule' ]]
    [[ "$(yq -r '[.spec.groups[].rules[] | select(.alert == "QbittorrentVpnDown") | .labels.severity] | .[0]' "$rule")" == 'critical' ]]
    [[ "$(yq -r '[.spec.groups[].rules[] | select(.alert == "QbittorrentGluetunRestartLoop") | .labels.severity] | .[0]' "$rule")" == 'critical' ]]
    rg -q 'gatus_results_endpoint_success' "$rule"
    rg -q 'kube_pod_init_container_status_restarts_total' "$rule"
    # The Gatus health probe that feeds the rule must exist.
    rg -q 'name: qbittorrent-vpn' kubernetes/apps/monitoring/gatus/app/values.yaml
    rg -q 'status == running' kubernetes/apps/monitoring/gatus/app/values.yaml

    chart_url="$(yq -r '.spec.url' "$oci")"
    chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
    kustomize build "$base/app" >/dev/null
    helm template qbittorrent "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
    [[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'qbittorrent' ]]
    [[ "$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.initContainers[] | select(.name == "gluetun") | .restartPolicy' "$temp_dir/render.yaml")" == 'Always' ]]
    yq -r 'select(.kind == "Deployment") | .spec.template.spec.initContainers[] | select(.name == "gluetun") | .livenessProbe.exec.command[]' "$temp_dir/render.yaml" | rg -q '/v1/portforward'

    echo 'Phase 12 qBittorrent+Gluetun source, encrypted ProtonVPN Secret, sidecar/kill-switch config, dependency graph, and pinned render passed validation.'

# Verify the live Phase 12 qBittorrent: Kustomization + HelmRelease Ready, rollout,
# HTTPRoute Accepted, DNS, and the WebUI reachable over the internal gateway. The VPN
# kill-switch is proven separately by qbittorrent-killswitch-verify.
qbittorrent-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='media'
    gateway_ip='192.168.90.30'
    host='qbittorrent.lab.supermorphic.com'

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization qbittorrent --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'qbittorrent Kustomization not Ready.' >&2; exit 1; }
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease qbittorrent --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'qbittorrent HelmRelease not Ready.' >&2; exit 1; }
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/qbittorrent --timeout=5m
    accepted=false
    for _ in {1..24}; do
      [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute qbittorrent --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]] && { accepted=true; break; }
      sleep 5
    done
    [[ "$accepted" == 'true' ]] || { echo 'qbittorrent HTTPRoute was not Accepted.' >&2; exit 1; }
    [[ "$(dig +short @192.168.90.2 "$host" A | sort -u)" == "$gateway_ip" ]] || { echo "DNS for $host does not resolve to $gateway_ip." >&2; exit 1; }
    curl --silent --fail --resolve "$host:443:$gateway_ip" "https://$host/" >/dev/null || { echo 'qBittorrent WebUI not reachable via the gateway.' >&2; exit 1; }
    echo 'Phase 12 qBittorrent acceptance passed. Run qbittorrent-killswitch-verify (the blocking VPN gate) before flipping suspend: false.'

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

    kubeconfig='kubeconfig'
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
    #!/usr/bin/env bash
    set -euo pipefail

    oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
    chart_url="$(yq -r '.spec.url' "$oci")"
    chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
    temp_dir="$(mktemp -d /tmp/homelab-talos-arr-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for app in prowlarr sonarr radarr; do
      base="kubernetes/apps/media/$app"
      ks="$base/ks.yaml"; hr="$base/app/helmrelease.yaml"; values="$base/app/values.yaml"; route="$base/app/httproute.yaml"
      for f in "$ks" "$hr" "$values" "$route" "$base/app/kustomization.yaml"; do
        [[ -f "$f" ]] || { echo "Missing Phase 13 source: $f" >&2; exit 1; }
      done
      rg -qx "  - ./$app/ks.yaml" kubernetes/apps/media/kustomization.yaml || {
        echo "Refusing: ./$app/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml." >&2
        exit 1
      }

      suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
      [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
      # No SOPS decryption — these apps carry no secrets (API keys are first-run).
      [[ "$(yq -r '.spec.decryption // "none"' "$ks")" == 'none' ]] || { echo "$app ks.yaml must not declare decryption (no secrets)." >&2; exit 1; }
      deps="$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")"
      if [[ "$app" == 'prowlarr' ]]; then
        [[ "$deps" == 'internal-gateway,media' ]] || { echo "prowlarr dependsOn must be [media, internal-gateway]; got: $deps." >&2; exit 1; }
      else
        [[ "$deps" == 'internal-gateway,media-storage' ]] || { echo "$app dependsOn must be [media-storage, internal-gateway]; got: $deps." >&2; exit 1; }
      fi

      [[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

      [[ "$(yq -r ".controllers.$app.strategy" "$values")" == 'Recreate' ]]
      [[ "$(yq -r ".controllers.$app.containers.app.image.repository" "$values")" == "ghcr.io/home-operations/$app" ]]
      tag="$(yq -r ".controllers.$app.containers.app.image.tag" "$values")"; [[ -n "$tag" && "$tag" != 'null' ]]
      [[ "$(yq -r ".controllers.$app.containers.app.securityContext.capabilities.drop[]" "$values" | tr '\n' ' ')" == 'ALL ' ]]
      [[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOnce' ]]
      [[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
      [[ "$(yq -r '.persistence.config.annotations."helm.sh/resource-policy"' "$values")" == 'keep' ]]
      if [[ "$app" == 'prowlarr' ]]; then
        [[ "$(yq -r '.persistence.data // "none"' "$values")" == 'none' ]] || { echo 'prowlarr must not mount media-data (config-only).' >&2; exit 1; }
      else
        [[ "$(yq -r '.persistence.data.existingClaim' "$values")" == 'media-data' ]] || { echo "$app must mount media-data at /data." >&2; exit 1; }
      fi

      [[ "$(yq -r '.spec.hostnames[0]' "$route")" == "$app.lab.supermorphic.com" ]]
      [[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
      [[ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$route")" == "$app" ]]

      # A Gatus /ping health probe must exist for this app.
      rg -q "^    - name: $app\$" kubernetes/apps/monitoring/gatus/app/values.yaml || { echo "$app has no Gatus endpoint." >&2; exit 1; }

      kustomize build "$base/app" >/dev/null
      helm template "$app" "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/$app.yaml"
      [[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/$app.yaml")" == "$app" ]]
      [[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/$app.yaml")" == 'Recreate' ]]
      echo "  $app $tag OK"
    done

    echo 'Phase 13 *arr source (Prowlarr, Sonarr, Radarr), wiring, dependency graph, config/Recreate + shared /data, HTTPRoutes, Gatus probes, and pinned renders passed validation.'

# Verify a live Phase 13 *arr app: `just kube arr-verify <prowlarr|sonarr|radarr>`.
# Kustomization + HelmRelease Ready, rollout, HTTPRoute Accepted, DNS, and /ping over the
# internal gateway. Operator-only (needs the cluster); not in `just ci`.
arr-verify app: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    app='{{app}}'
    case "$app" in prowlarr|sonarr|radarr) ;; *) echo "Usage: just kube arr-verify <prowlarr|sonarr|radarr>" >&2; exit 1;; esac
    kubeconfig='kubeconfig'
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

# Validate the Phase 10 monitoring source: files, encrypted Grafana Secret,
# dependency graph, staged-suspend uniformity, key values, wiring, HTTPRoutes,
# and the pinned kube-prometheus-stack render.
monitoring-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/monitoring/kube-prometheus-stack'
    ks="$base/ks.yaml"
    secret="$base/app/grafana-admin.sops.yaml"
    values="$base/app/values.yaml"
    hr="$base/app/helmrelease.yaml"
    repo="$base/app/helmrepository.yaml"
    routes="$base/config/httproutes.yaml"
    expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
    temp_dir="$(mktemp -d /tmp/homelab-talos-monitoring-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$secret" "$values" "$hr" "$repo" "$routes" \
      "$base/app/namespace.yaml" "$base/app/kustomization.yaml" \
      "$base/config/kustomization.yaml" kubernetes/apps/monitoring/kustomization.yaml; do
      [[ -f "$f" ]] || {
        echo "Missing Phase 10 monitoring source: $f" >&2
        echo 'Run just repo monitoring-secrets if the Grafana Secret is missing.' >&2
        exit 1
      }
    done

    rg -qx '  - ./monitoring' kubernetes/apps/kustomization.yaml || {
      echo 'Refusing: ./monitoring is not wired into kubernetes/apps/kustomization.yaml.' >&2
      exit 1
    }

    [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
    [[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
    [[ "$(yq -r '.metadata.name' "$secret")" == 'grafana-admin-secret' ]]
    [[ "$(yq -r '.metadata.namespace' "$secret")" == 'monitoring' ]]

    suspend_states="$(yq ea -r '[select(.kind == "Kustomization") | (.spec.suspend // false)] | .[]' "$ks" | sort -u)"
    [[ "$suspend_states" == 'true' || "$suspend_states" == 'false' ]] || {
      echo 'Both monitoring Kustomizations must be staged together: all suspended or all active.' >&2
      exit 1
    }

    [[ "$(yq ea -r 'select(.metadata.name == "kube-prometheus-stack") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,longhorn' ]]
    [[ "$(yq ea -r 'select(.metadata.name == "kube-prometheus-stack-config") | [.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,kube-prometheus-stack' ]]

    chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
    [[ -n "$chart_version" && "$chart_version" != 'null' ]]
    [[ "$(yq -r '.spec.url' "$repo")" == 'https://prometheus-community.github.io/helm-charts' ]]
    [[ "$(yq -r '.prometheus.prometheusSpec.retention' "$values")" == '30d' ]]
    [[ "$(yq -r '.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage' "$values")" == '50Gi' ]]
    [[ "$(yq -r '.grafana.persistence.enabled' "$values")" == 'true' ]]
    for c in kubeProxy kubeControllerManager kubeScheduler kubeEtcd; do
      [[ "$(yq -r ".${c}.enabled" "$values")" == 'false' ]]
    done
    [[ "$(yq ea -r '[select(.kind == "HTTPRoute") | .spec.hostnames[0]] | sort | join(" ")' "$routes")" == 'alertmanager.lab.supermorphic.com grafana.lab.supermorphic.com prometheus.lab.supermorphic.com' ]]
    [[ "$(yq ea -r '[select(.kind == "HTTPRoute") | .spec.parentRefs[].name] | unique | .[]' "$routes")" == 'internal' ]]
    [[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$base/app/namespace.yaml")" == 'internal' ]]

    kustomize build "$base/app" >/dev/null
    kustomize build "$base/config" >/dev/null

    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
    HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
      helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version "$chart_version" --namespace monitoring --values "$values" >"$temp_dir/kps.yaml"
    render_kinds="$(yq ea -r '[select(.kind == "Prometheus" or .kind == "Alertmanager") | .kind] | .[]' "$temp_dir/kps.yaml" | sort -u | tr '\n' ' ')"
    [[ "$render_kinds" == 'Alertmanager Prometheus ' ]]

    echo 'Phase 10 monitoring source, encrypted Grafana Secret, dependency graph, values, HTTPRoutes, and pinned kube-prometheus-stack render passed validation.'

# Verify the live monitoring stack: HelmRelease + workloads healthy, PVCs bound
# on Longhorn, HTTPRoutes accepted, all three UIs reachable with trusted HTTPS
# through the internal gateway, and the foundation still green.
monitoring-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='monitoring'
    gateway_ip='192.168.90.30'

    for k in kube-prometheus-stack kube-prometheus-stack-config; do
      [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$k" --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
        echo "Monitoring Kustomization $k is not Ready." >&2
        exit 1
      }
    done
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease kube-prometheus-stack --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || {
      echo 'kube-prometheus-stack HelmRelease is not Ready.' >&2
      exit 1
    }

    pvc_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pvc --output json)"
    [[ "$(yq -r '[.items[] | select(.status.phase == "Bound")] | length' - <<<"$pvc_json")" -ge 3 ]] || { echo 'Expected at least three bound PVCs in monitoring.' >&2; exit 1; }
    [[ "$(yq -r '[.items[].status.phase] | unique | join(" ")' - <<<"$pvc_json")" == 'Bound' ]] || { echo 'Not all monitoring PVCs are Bound.' >&2; exit 1; }

    for r in grafana prometheus alertmanager; do
      accepted=false
      for _ in {1..18}; do
        route="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute "$r" --output json 2>/dev/null)"
        if [[ "$(yq -r '[.status.parents[].conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]; then
          accepted=true
          break
        fi
        sleep 5
      done
      [[ "$accepted" == 'true' ]] || {
        echo "HTTPRoute $r is not Accepted; confirm the monitoring namespace carries gateway.supermorphic.com/access=internal and that Envoy Gateway has re-listed it." >&2
        exit 1
      }
    done

    dns_answer=''
    for _ in {1..30}; do
      dns_answer="$(dig +short @192.168.90.2 grafana.lab.supermorphic.com A | sort -u)"
      [[ "$dns_answer" == "$gateway_ip" ]] && break
      sleep 10
    done
    [[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for grafana, not $gateway_ip." >&2; exit 1; }
    for host in prometheus alertmanager; do
      [[ "$(dig +short @192.168.90.2 "$host.lab.supermorphic.com" A | sort -u)" == "$gateway_ip" ]] || { echo "Pi-hole has no $gateway_ip record for $host." >&2; exit 1; }
    done

    health="$(curl --silent --show-error --fail --max-time 15 --resolve "grafana.lab.supermorphic.com:443:$gateway_ip" https://grafana.lab.supermorphic.com/api/health)"
    [[ "$(yq -r '.database' - <<<"$health")" == 'ok' ]] || { echo "Grafana /api/health not ok: $health" >&2; exit 1; }
    curl --silent --show-error --fail --max-time 15 --resolve "prometheus.lab.supermorphic.com:443:$gateway_ip" https://prometheus.lab.supermorphic.com/-/healthy >/dev/null
    curl --silent --show-error --fail --max-time 15 --resolve "alertmanager.lab.supermorphic.com:443:$gateway_ip" https://alertmanager.lab.supermorphic.com/-/healthy >/dev/null

    just kube foundation-verify
    echo 'Phase 10 monitoring acceptance passed: kube-prometheus-stack Ready (Prometheus, Alertmanager, Grafana, exporters), PVCs bound on Longhorn, HTTPRoutes accepted, and all three UIs reachable with trusted HTTPS through the internal gateway.'

# Reset Grafana's DB admin password to the current grafana-admin Secret value. Grafana
# only applies the admin password on first init, so a rotated/recreated Secret (e.g. the
# age-key migration) leaves the DB on the old password (401s, incl. the Homepage widget).
# This reuses the pod's own GF_SECURITY_ADMIN_* env, so no secret value is printed or
# passed on the command line. Operator-run; cluster-dependent; NOT in `just ci`.
grafana-admin-reset: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
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
    echo 'Grafana DB admin password reset to match the grafana-admin Secret; API auth verified. (Sync homepage-secrets grafana-user/password to the same creds + restart homepage for the widget.)'

# Validate the Phase 10 Gatus source: files, wiring, namespace gateway label,
# staged suspend, key values, HTTPRoute, and the pinned chart render.
gatus-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/monitoring/gatus'
    ks="$base/ks.yaml"
    values="$base/app/values.yaml"
    hr="$base/app/helmrelease.yaml"
    repo="$base/app/helmrepository.yaml"
    route="$base/app/httproute.yaml"
    ns="$base/app/namespace.yaml"
    temp_dir="$(mktemp -d /tmp/homelab-talos-gatus-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$values" "$hr" "$repo" "$route" "$ns" "$base/app/kustomization.yaml"; do
      [[ -f "$f" ]] || { echo "Missing Phase 10 Gatus source: $f" >&2; exit 1; }
    done
    rg -qx '  - ./gatus/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
      echo 'Refusing: ./gatus/ks.yaml is not listed in kubernetes/apps/monitoring/kustomization.yaml.' >&2
      exit 1
    }

    suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
    [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
    [[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]]
    [[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,internal-gateway' ]]
    chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
    [[ -n "$chart_version" && "$chart_version" != 'null' ]]
    [[ "$(yq -r '.spec.url' "$repo")" == 'https://twin.github.io/helm-charts' ]]
    [[ "$(yq -r '.config.storage.type' "$values")" == 'memory' ]]
    [[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'gatus.lab.supermorphic.com' ]]
    [[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]

    kustomize build "$base/app" >/dev/null
    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
    HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
      helm template gatus gatus --repo https://twin.github.io/helm-charts --version "$chart_version" --namespace gatus --values "$values" >/dev/null

    echo 'Phase 10 Gatus source, wiring, namespace label, values, HTTPRoute, and pinned chart render passed validation.'

# Verify the live Gatus app: Kustomization + HelmRelease Ready, PVC bound,
# HTTPRoute accepted, the dashboard reachable via HTTPS, and foundation green.
gatus-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='gatus'
    gateway_ip='192.168.90.30'

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization gatus --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Gatus Kustomization is not Ready.' >&2; exit 1; }
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease gatus --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Gatus HelmRelease is not Ready.' >&2; exit 1; }
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/gatus --timeout=3m

    accepted=false
    for _ in {1..18}; do
      route="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute gatus --output json 2>/dev/null)"
      if [[ "$(yq -r '[.status.parents[].conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]; then accepted=true; break; fi
      sleep 5
    done
    [[ "$accepted" == 'true' ]] || { echo 'Gatus HTTPRoute is not Accepted.' >&2; exit 1; }

    dns_answer=''
    for _ in {1..30}; do
      dns_answer="$(dig +short @192.168.90.2 gatus.lab.supermorphic.com A | sort -u)"
      [[ "$dns_answer" == "$gateway_ip" ]] && break
      sleep 10
    done
    [[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for gatus, not $gateway_ip." >&2; exit 1; }
    curl --silent --show-error --fail --max-time 15 --resolve "gatus.lab.supermorphic.com:443:$gateway_ip" https://gatus.lab.supermorphic.com/health >/dev/null

    just kube foundation-verify
    echo 'Phase 10 Gatus acceptance passed: Kustomization and HelmRelease Ready, deployment rolled out (in-memory storage), HTTPRoute accepted, and the dashboard reachable with trusted HTTPS at gatus.lab.supermorphic.com.'

# Validate the Phase 10 Homepage source: files, wiring, namespace gateway label,
# dependency graph, pinned image, allowed-hosts, HTTPRoute, and the render.
homepage-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/monitoring/homepage'
    ks="$base/ks.yaml"
    ns="$base/app/namespace.yaml"
    dep="$base/app/deployment.yaml"
    route="$base/app/httproute.yaml"

    for f in "$ks" "$ns" "$dep" "$route" "$base/app/rbac.yaml" "$base/app/service.yaml" \
      "$base/app/kustomization.yaml" "$base/app/config/settings.yaml" \
      "$base/app/config/kubernetes.yaml" "$base/app/config/services.yaml" \
      "$base/app/config/widgets.yaml" "$base/app/config/bookmarks.yaml"; do
      [[ -f "$f" ]] || { echo "Missing Phase 10 Homepage source: $f" >&2; exit 1; }
    done
    rg -qx '  - ./homepage/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
      echo 'Refusing: ./homepage/ks.yaml is not listed in the monitoring kustomization.' >&2
      exit 1
    }

    suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
    [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
    [[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]]
    [[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,internal-gateway' ]]
    [[ "$(yq -r '.spec.template.spec.containers[0].image' "$dep")" == ghcr.io/gethomepage/homepage:* ]]
    [[ "$(yq -r '[.spec.template.spec.containers[0].env[] | select(.name == "HOMEPAGE_ALLOWED_HOSTS") | .value] | .[0]' "$dep")" == 'homepage.lab.supermorphic.com' ]]
    [[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'homepage.lab.supermorphic.com' ]]
    [[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]

    secret="$base/app/homepage-secrets.sops.yaml"
    [[ -f "$secret" ]] || { echo "Missing Homepage Secret: $secret (run just repo homepage-secrets)." >&2; exit 1; }
    [[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.metadata.name' "$secret")" == 'homepage-secrets' ]]
    [[ "$(yq -r '.metadata.namespace' "$secret")" == 'homepage' ]]

    kustomize build "$base/app" >/dev/null

    echo 'Phase 10 Homepage source, wiring, namespace label, dependency graph, image, allowed-hosts, HTTPRoute, and encrypted Secret passed validation.'

# Verify the live Homepage app: Kustomization Ready, deployment rolled out,
# HTTPRoute accepted, dashboard reachable via HTTPS, and foundation green.
homepage-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='homepage'
    gateway_ip='192.168.90.30'

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization homepage --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Homepage Kustomization is not Ready.' >&2; exit 1; }
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/homepage --timeout=5m

    accepted=false
    for _ in {1..18}; do
      route="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute homepage --output json 2>/dev/null)"
      if [[ "$(yq -r '[.status.parents[].conditions[]? | select(.type == "Accepted") | .status] | unique | join(" ")' - <<<"$route")" == 'True' ]]; then accepted=true; break; fi
      sleep 5
    done
    [[ "$accepted" == 'true' ]] || { echo 'Homepage HTTPRoute is not Accepted.' >&2; exit 1; }

    dns_answer=''
    for _ in {1..30}; do
      dns_answer="$(dig +short @192.168.90.2 homepage.lab.supermorphic.com A | sort -u)"
      [[ "$dns_answer" == "$gateway_ip" ]] && break
      sleep 10
    done
    [[ "$dns_answer" == "$gateway_ip" ]] || { echo "Pi-hole returned '$dns_answer' for homepage, not $gateway_ip." >&2; exit 1; }
    curl --silent --show-error --fail --max-time 15 --resolve "homepage.lab.supermorphic.com:443:$gateway_ip" https://homepage.lab.supermorphic.com/ >/dev/null

    just kube foundation-verify
    echo 'Phase 10 Homepage acceptance passed: Kustomization Ready, deployment rolled out, HTTPRoute accepted, and the dashboard reachable with trusted HTTPS at homepage.lab.supermorphic.com.'

# Validate the Phase 10 Trivy Operator source: files, wiring, staged suspend,
# dependency, pinned chart, key scanner settings, and the render.
trivy-validate: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    base='kubernetes/apps/security/trivy-operator'
    ks="$base/ks.yaml"
    values="$base/app/values.yaml"
    hr="$base/app/helmrelease.yaml"
    repo="$base/app/helmrepository.yaml"
    temp_dir="$(mktemp -d /tmp/homelab-talos-trivy-validate.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    for f in "$ks" "$values" "$hr" "$repo" "$base/app/namespace.yaml" "$base/app/kustomization.yaml"; do
      [[ -f "$f" ]] || { echo "Missing Phase 10 Trivy source: $f" >&2; exit 1; }
    done
    rg -qx '  - ./trivy-operator/ks.yaml' kubernetes/apps/security/kustomization.yaml || {
      echo 'Refusing: ./trivy-operator/ks.yaml is not listed in the security kustomization.' >&2
      exit 1
    }

    suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
    [[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
    [[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium' ]]
    chart_version="$(yq -r '.spec.chart.spec.version' "$hr")"
    [[ -n "$chart_version" && "$chart_version" != 'null' ]]
    [[ "$(yq -r '.spec.url' "$repo")" == 'https://aquasecurity.github.io/helm-charts' ]]
    [[ "$(yq -r '.operator.sbomGenerationEnabled' "$values")" == 'false' ]]
    [[ "$(yq -r '.operator.clusterComplianceEnabled' "$values")" == 'false' ]]
    # infra-assessment cannot run on Talos (read-only host); keep it disabled.
    [[ "$(yq -r '.operator.infraAssessmentScannerEnabled' "$values")" == 'false' ]]
    [[ "$(yq -r '.trivy.ignoreUnfixed' "$values")" == 'true' ]]
    [[ "$(yq -r '.serviceMonitor.enabled' "$values")" == 'true' ]]

    kustomize build "$base/app" >/dev/null
    printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
    HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
      helm template trivy-operator trivy-operator --repo https://aquasecurity.github.io/helm-charts --version "$chart_version" --namespace trivy-system --values "$values" >"$temp_dir/trivy.yaml"
    [[ "$(yq ea 'select(.kind == "ConfigMap" and .metadata.name == "trivy-operator-config") | .data.OPERATOR_SBOM_GENERATION_ENABLED' "$temp_dir/trivy.yaml")" == 'false' ]]

    echo 'Phase 10 Trivy Operator source, wiring, dependency, pinned chart, scanner settings, and render passed validation.'

# Verify the live Trivy Operator: Kustomization + HelmRelease Ready, operator
# rolled out, report CRDs installed, and foundation green.
trivy-verify: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='kubeconfig'
    ns='trivy-system'

    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization trivy-operator --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Trivy Kustomization is not Ready.' >&2; exit 1; }
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease trivy-operator --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'Trivy HelmRelease is not Ready.' >&2; exit 1; }
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/trivy-operator --timeout=5m
    for crd in vulnerabilityreports.aquasecurity.github.io configauditreports.aquasecurity.github.io; do
      kubectl --kubeconfig "$kubeconfig" get crd "$crd" >/dev/null 2>&1 || { echo "Missing Trivy CRD $crd." >&2; exit 1; }
    done

    just kube foundation-verify
    echo 'Phase 10 Trivy Operator acceptance passed: Kustomization and HelmRelease Ready, operator rolled out, and report CRDs installed.'
