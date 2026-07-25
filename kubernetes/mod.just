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
    @scripts/verify/cilium.sh {{quote(kubeconfig)}} {{quote(cilium_values)}}

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
    @scripts/verify/plex-reschedule.sh {{quote(kubeconfig)}}

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
# Precondition: first-run done (permanent WebUI credential set, subnet-auth bypass
# disabled, and "Bypass authentication for localhost" enabled for the port-forward UP
# command). Phase 12 is not flipped suspend: false / not "done" until this passes.
qbittorrent-killswitch-verify: require-bash
    @scripts/verify/qbittorrent-killswitch.sh {{quote(kubeconfig)}}

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
