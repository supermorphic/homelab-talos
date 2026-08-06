set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

cilium_chart := "oci://quay.io/cilium/charts/cilium"
cilium_values := "kubernetes/apps/kube-system/cilium/app/values.yaml"
cilium_app := "kubernetes/apps/kube-system/cilium/app"
talosconfig := ".talos/config"
kubeconfig := ".kube/config"
github_owner := "supermorphic"
github_repository := "homelab-talos"

# Render the pinned Cilium chart to standard output without writing generated YAML.
cilium-render:
    @helm template cilium {{cilium_chart}} \
      --version "$(yq -r '.spec.ref.tag' {{cilium_app}}/ocirepository.yaml)" \
      --namespace kube-system \
      --values {{cilium_values}}

# Validate the app-local Cilium source and pinned Helm render.
cilium-validate: require-bash
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

# Fail unless running under bash >= 5; macOS /bin/bash 3.2 does not honor set -e
# for a failed bare [[ ]] mid-recipe, so these acceptance assertions would not gate.
# Validate the metrics-server source: files, wiring, dependency, pinned chart, the
# Talos --kubelet-insecure-tls flag, and the render (version derived from the HR).
metrics-server-validate: require-bash
    @scripts/validate/metrics-server.sh

# Verify metrics-server: Kustomization + HelmRelease Ready, deployment rolled out,
# the metrics.k8s.io APIService Available, and kubectl top returns data.
metrics-server-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.metrics-server -- scripts/verify/metrics-server.sh {{quote(kubeconfig)}}

# Unit-test the offline configuration policies without contacting a cluster.
validator-tests:
    #!/usr/bin/env bash
    set -euo pipefail
    conftest fmt --check tests/policy
    set +e
    conftest verify --policy tests/policy
    result="$?"
    set -e
    if [[ -n "${TEST_RESULT_FRAGMENT_DIR:-}" ]]; then
      set +e
      conftest verify --policy tests/policy --output junit \
        >"$TEST_RESULT_FRAGMENT_DIR/conftest-policy-unit.xml"
      reporter_result="$?"
      set -e
      [[ "$reporter_result" -eq "$result" ]] || {
        echo 'Conftest policy-unit console and JUnit executions disagreed.' >&2
        exit 2
      }
    fi
    exit "$result"

# Prove the observer, diagnostic, and Talos reader authorization boundaries. This is a
# live, read-only gate and must run only after agent-access is deployed and scoped
# credentials have been minted into the current worktree.
agent-access-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.agent-access -- scripts/verify/agent-access.sh {{quote(kubeconfig)}} {{quote(talosconfig)}}

# Enforce cross-application media source policy without contacting the cluster.
media-policy-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    args=(test --combine --all-namespaces --policy tests/policy/media kubernetes/apps/media)
    set +e
    conftest "${args[@]}"
    result="$?"
    set -e
    if [[ -n "${TEST_RESULT_FRAGMENT_DIR:-}" ]]; then
      set +e
      conftest "${args[@]}" --output junit \
        >"$TEST_RESULT_FRAGMENT_DIR/conftest-media-policy.xml"
      reporter_result="$?"
      set -e
      [[ "$reporter_result" -eq "$result" ]] || {
        echo 'Conftest media-policy console and JUnit executions disagreed.' >&2
        exit 2
      }
    fi
    exit "$result"

# On-demand, operator-run Kubernetes conformance via Sonobuoy. NOT in `just ci` and NOT
# scheduled — Sonobuoy is ephemeral (run -> retrieve -> delete), never a standing workload.
# MODE=quick (default, ~5-10m, a validation E2E subset — NOT upstream conformance evidence).
# MODE=certified runs the full certified-conformance suite (~1.5-2h) and IS upstream
# conformance evidence — run it only for major Kubernetes upgrades / platform changes.
conformance: require-bash
    @scripts/test/run-conformance.sh {{quote(kubeconfig)}}

# Inspect an active Sonobuoy run without retrieving, deleting, or changing it.
conformance-status: require-bash
    @scripts/diagnose/sonobuoy.sh {{quote(kubeconfig)}}

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

    kubeconform_args=(
      -strict
      -summary
      -ignore-missing-schemas
      -kubernetes-version "$k8s_version"
      -schema-location default
      -schema-location "$crd_catalog"
      "$temp_dir/validate.yaml"
    )
    set +e
    kubeconform "${kubeconform_args[@]}"
    result="$?"
    set -e
    if [[ -n "${TEST_RESULT_FRAGMENT_DIR:-}" ]]; then
      set +e
      kubeconform \
        -strict \
        -output junit \
        -ignore-missing-schemas \
        -kubernetes-version "$k8s_version" \
        -schema-location default \
        -schema-location "$crd_catalog" \
        "$temp_dir/validate.yaml" \
        >"$TEST_RESULT_FRAGMENT_DIR/kubeconform.xml"
      reporter_result="$?"
      set -e
      [[ "$reporter_result" -eq "$result" ]] || {
        echo 'Kubeconform console and JUnit executions disagreed.' >&2
        exit 2
      }
    fi
    [[ "$result" -eq 0 ]] || exit "$result"

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

# Verify the live Phase 5 Cilium state without changing cluster resources.
cilium-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.cilium -- scripts/verify/cilium.sh {{quote(kubeconfig)}} {{quote(cilium_values)}}

# Run the state-changing Cilium connectivity suite and clean up its temporary
# workloads after CILIUM_CONNECTIVITY_CONFIRM=test:cilium-connectivity.
# Operator-only; intentionally separate from read-only verification.
cilium-connectivity-test: require-bash
    @scripts/test/run-catalog-suite.sh test.cilium-connectivity -- scripts/test/scenarios/cilium-connectivity.sh {{quote(kubeconfig)}}

# Validate the complete local Phase 6 source and pinned OCI render without mutating the cluster.
flux-validate: require-bash
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
    @scripts/test/run-catalog-suite.sh verification.flux -- scripts/verify/flux.sh {{quote(kubeconfig)}} {{quote(github_owner)}} {{quote(github_repository)}}

# Validate the complete local Phase 7 graph, encrypted providers, and pinned chart renders.
foundation-validate: require-bash
    @scripts/validate/foundation.sh

# Print the read-only Phase 7 controller, certificate, address, Gateway, DNS, and echo state.
foundation-status:
    #!/usr/bin/env bash
    set -u

    source scripts/lib/network.sh
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
    dig +short @"$HOMELAB_DNS_RESOLVER" echo.lab.supermorphic.com A || status=1
    exit "$status"

# Verify the complete live Phase 7 internal foundation acceptance gate.
foundation-verify: foundation-validate require-bash
    @scripts/test/run-catalog-suite.sh verification.foundation -- scripts/verify/foundation.sh {{quote(kubeconfig)}}

# Restart the flux-system controllers and prove reconciliation resumes.
flux-restart: require-bash
    @scripts/test/run-catalog-suite.sh test.flux-restart -- just kube _flux-restart-raw

[private]
_flux-restart-raw: require-bash
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
flux-canary-test: require-bash
    @scripts/test/run-catalog-suite.sh test.flux-canary -- just kube _flux-canary-test-raw

[private]
_flux-canary-test-raw: flux-verify
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

# Validate the suspended dedicated public Plex Gateway, exact route cardinality,
# isolated certificate, MetalLB VIP, and token-safe access-log contract.
plex-public-validate: require-bash
    @scripts/validate/plex-public.sh

# Validate the suspended credential-free Plex DDNS drift exporter, metrics,
# alerts, and bounded network policy.
plex-ddns-drift-validate: require-bash
    @scripts/validate/plex-ddns-drift.sh

# Verify the active dedicated public Plex Gateway, negative listener behavior,
# and all internal foundation/Gatus/Plex acceptance without changing cluster state.
plex-public-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.plex-public -- scripts/verify/plex-public.sh {{quote(kubeconfig)}}

# Verify the live Plex DDNS drift target, metrics, address-free logs, alert rules,
# and existing warning route to ntfy without changing cluster state.
plex-ddns-drift-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.plex-ddns-drift -- scripts/verify/plex-ddns-drift.sh {{quote(kubeconfig)}}

# Verify live Longhorn state without changing cluster resources: controllers,
# node disks, default StorageClass, backup target, and recurring jobs.
storage-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.storage -- scripts/verify/storage.sh {{quote(kubeconfig)}}

# Create and remove a run-scoped PVC to prove Longhorn dynamic provisioning and
# two-node replica anti-affinity after
# STORAGE_PROVISIONING_CONFIRM=test:storage-provisioning. Operator-only and state-changing.
storage-provisioning-test: require-bash
    @scripts/test/run-catalog-suite.sh test.storage-provisioning -- scripts/test/scenarios/storage-provisioning.sh {{quote(kubeconfig)}}

# Verify the live Phase 11 SMB CSI driver: Kustomization Ready, controller +
# node plugin rolled out, and the CSIDriver registered.
csi-driver-smb-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.csi-driver-smb -- scripts/verify/csi-driver-smb.sh {{quote(kubeconfig)}}

# Verify the live Phase 11 shared media storage: Kustomizations Ready and the
# static RWX media-data PVC Bound. The mount is exercised for real by Plex (PR 11-2)
# and the documented hardlink proof (docs/phase-11-media.md); binding a static PV is
# a claimRef match and does not by itself prove the SMB mount works.
media-storage-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.media-storage -- scripts/verify/media-storage.sh {{quote(kubeconfig)}}

# Verify the live Phase 11 Plex: Kustomization + HelmRelease Ready, rollout complete,
# HTTPRoute Accepted, Pi-hole DNS, and /identity reachable over the internal gateway.
plex-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.plex -- scripts/verify/plex.sh {{quote(kubeconfig)}}

# Print UID/key preflight facts and sanitized Plex Relay lifecycle lines without
# creating a session or mutating the cluster. Operator-only live diagnostic.
plex-relay-status: require-bash
    @scripts/diagnose/plex-relay-status.sh {{quote(kubeconfig)}}

# Observe Plex L3/L4 Hubble flows for 1-600 seconds through a local port-forward.
# Operator-only and read-only; no packet payloads or cluster mutations.
plex-network-observe seconds='300': require-bash
    @scripts/diagnose/plex-network-observe.sh {{quote(kubeconfig)}} {{quote(seconds)}}

# Prove Plex ingress and egress containment with run-scoped control/selected probes.
# Operator-only and state-changing; creates and removes only run-scoped Pods.
plex-network-policy-test: require-bash
    @scripts/test/run-catalog-suite.sh test.plex-network-policy -- scripts/test/scenarios/plex-network-policy.sh {{quote(kubeconfig)}}

# Prove public Envoy pod-admin isolation and token-safe access logging with one
# run-scoped probe Pod. Operator-only and state-changing.
plex-public-probe-test: require-bash
    @scripts/test/run-catalog-suite.sh test.plex-public-probe -- scripts/test/scenarios/plex-public-probe.sh {{quote(kubeconfig)}}

# After the operator has removed the WAN DNAT, restart only the dedicated public
# Envoy Deployment to terminate any established stateful sessions, then verify.
plex-public-connection-flush: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_confirmation='flush:plex-public:dnat-removed'
    owner_selector='gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public'

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "${PLEX_PUBLIC_CONNECTION_FLUSH_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to restart public Envoy before explicit confirmation that DNAT is removed.' >&2
      echo "Set PLEX_PUBLIC_CONNECTION_FLUSH_CONFIRM='$expected_confirmation' only after deleting the WAN rule." >&2
      exit 1
    }

    source scripts/lib/rollout.sh
    require_deployed_source 'Plex public connection flush' \
      kubernetes/mod.just tests/catalog.yaml \
      scripts/lib/network.sh scripts/verify/plex-public.sh \
      scripts/verify/foundation.sh scripts/verify/gatus.sh scripts/verify/plex.sh \
      kubernetes/apps/networking/public-gateway

    deployments="$(kubectl --kubeconfig "$kubeconfig" --namespace envoy-gateway-system get deployments \
      --selector "$owner_selector" --output json)"
    [[ "$(yq -r '.items | length' - <<<"$deployments")" == '1' ]] || {
      echo 'Refusing connection flush: expected exactly one public-owned Envoy Deployment.' >&2
      exit 1
    }
    deployment="$(yq -r '.items[0].metadata.name' - <<<"$deployments")"
    [[ -n "$deployment" && "$deployment" != 'null' ]] || {
      echo 'Refusing connection flush: public Envoy Deployment name is empty.' >&2
      exit 1
    }

    kubectl --kubeconfig "$kubeconfig" --namespace envoy-gateway-system rollout restart "deployment/$deployment"
    kubectl --kubeconfig "$kubeconfig" --namespace envoy-gateway-system rollout status "deployment/$deployment" --timeout=10m
    just kube plex-public-verify
    echo 'Public Envoy established connections flushed after DNAT removal; dedicated gateway and internal acceptance remain healthy.'

# Validate the Phase 11 Intel GPU device plugin source: files, wiring, dependency,
# pinned image, and the built DaemonSet manifest.
intel-gpu-plugin-validate: require-bash
    @scripts/validate/intel-gpu-plugin.sh

# Verify the live Phase 11 Intel GPU device plugin: Kustomization Ready, DaemonSet
# rolled out, and every node advertising gpu.intel.com/i915 (QuickSync capacity).
intel-gpu-plugin-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.intel-gpu-plugin -- scripts/verify/intel-gpu-plugin.sh {{quote(kubeconfig)}}

# Validate the Phase 12 qBittorrent+Gluetun source: files, wiring, dependency,
# encrypted ProtonVPN Secret, the sidecar/kill-switch essentials, and the pinned render.
qbittorrent-validate: require-bash
    @scripts/validate/qbittorrent.sh

# Verify the live Phase 12 qBittorrent: Kustomization + HelmRelease Ready, rollout,
# HTTPRoute Accepted, DNS, and the WebUI reachable over the internal gateway.
qbittorrent-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.qbittorrent -- scripts/verify/qbittorrent.sh {{quote(kubeconfig)}}

# Validate the current *arr source (Prowlarr, Sonarr, Radarr, Lidarr): files, wiring, dependency
# graph, no-secret ks, app-template chartRef, config-PVC (Longhorn RWO + Recreate + keep),
# shared /data for sonarr/radarr, HTTPRoutes, Gatus /ping probes, and the pinned
# app-template render. Cluster-independent — part of `just ci`.
arr-validate: require-bash
    @scripts/validate/arr.sh

# Verify a current live *arr app: `just kube arr-verify <prowlarr|sonarr|radarr|lidarr>`.
# Kustomization + HelmRelease Ready, rollout, HTTPRoute Accepted, DNS, and /ping over the
# internal gateway. Operator-only (needs the cluster); not in `just ci`.
arr-verify app: require-bash
    @scripts/test/run-catalog-suite.sh verification.{{app}} -- scripts/verify/arr.sh {{quote(app)}} {{quote(kubeconfig)}}

# Validate the Phase 14 Seerr source: files, wiring, no-secret ks, app-template chartRef,
# config-only PVC (Longhorn RWO + Recreate + keep at /app/config), HTTPRoute, Gatus probe,
# and the pinned app-template render. Cluster-independent — part of `just ci`.
seerr-validate: require-bash
    @scripts/validate/seerr.sh

# Validate the Tautulli source, config-only retained PVC, security/resources, exact probes,
# internal route, activation-aware Gatus/Homepage boundary, and pinned app-template render.
# Cluster-independent and included in `just ci`.
tautulli-validate: require-bash
    @scripts/validate/tautulli.sh

# Validate the isolated media-alerts Flux dependency/placement contract, then extract the
# manifest rule spec and run promtool syntax and temporal/matcher unit tests.
media-alerts-validate: require-bash
    @scripts/validate/media-alerts.sh

# Verify the live Phase 14 Seerr: Kustomization + HelmRelease Ready, rollout, HTTPRoute
# Accepted, DNS, and /api/v1/status over the internal gateway. Operator-only; not in ci.
seerr-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.seerr -- scripts/verify/seerr.sh {{quote(kubeconfig)}}

# Verify live Tautulli resources, route, DNS, and exact non-redirecting HTTP 200 responses
# from /status through the Service and internal gateway. Operator-only/read-only; not in ci.
tautulli-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.tautulli -- scripts/verify/tautulli.sh {{quote(kubeconfig)}}

# Validate the FlareSolverr source: files, wiring, no-secret ks, app-template chartRef,
# stateless (no config PVC, no HTTPRoute), non-root + drop-ALL caps, /dev/shm memory,
# ClusterIP :8191, activation-aware Gatus probe, and the pinned render. Cluster-independent
# — part of `just ci`.
flaresolverr-validate: require-bash
    @scripts/validate/flaresolverr.sh

# Verify the live FlareSolverr: Kustomization + HelmRelease Ready, rollout, Service
# endpoints, and an in-cluster GET / "ready" probe over a port-forward (no HTTPRoute/DNS).
# Operator-only; not in ci. Proves the service is UP, NOT that any indexer works.
flaresolverr-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.flaresolverr -- scripts/verify/flaresolverr.sh {{quote(kubeconfig)}}

# Validate the qbit_manage source: files, wiring, encrypted-Secret decryption, app-template
# chartRef, non-root drop-ALL Recreate deployment, UI-less (no Service/HTTPRoute/Gatus),
# SOPS creds via envFrom, and the declarative-policy safety semantics (no category changes,
# no destructive features, no unknown-tracker catch-all, inert dry-run stage). Plus the
# pinned render. Cluster-independent — part of `just ci`.
qbit-manage-validate: require-bash
    @scripts/validate/qbit-manage.sh

# Validate the suspended, inert encoding benchmark sources without contacting the cluster.
encode-benchmark-validate: require-bash
    @scripts/validate/encode-benchmark.sh

# Read-only cluster placement check: reports every node and requires one non-Plex
# node with a free i915 slot and at least 200Gi actual node.fs.availableBytes.
encode-benchmark-preflight: require-bash
    @scripts/encode-benchmark/preflight.sh {{quote(kubeconfig)}}

# Create one run-owned capability Job after exact confirmation and proof that the
# renderer/runtime sources match the deployed origin/main boundary.
encode-benchmark-capabilities: require-bash
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/rollout.sh
    require_deployed_source 'encode-benchmark capabilities' \
      kubernetes/mod.just \
      scripts/encode-benchmark \
      kubernetes/apps/media/encode-benchmark
    scripts/encode-benchmark/dispatch.sh '{{kubeconfig}}' capabilities

# Create a suspended census Job, attach its qbit_manage inode inventory through
# an owned ConfigMap, then unsuspend only after the lifecycle join is complete.
encode-benchmark-census: require-bash
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/lib/rollout.sh
    require_deployed_source 'encode-benchmark census' \
      kubernetes/mod.just \
      scripts/encode-benchmark \
      kubernetes/apps/media/encode-benchmark
    scripts/encode-benchmark/dispatch.sh '{{kubeconfig}}' census

# Render and create only the selected run-scoped benchmark mode. Confirmation is
# bound to the exact mode; an optional run ID is an explicit resume handle.
encode-benchmark-run mode run_id="" sample_id="": require-bash
    #!/usr/bin/env bash
    set -euo pipefail
    mode={{quote(mode)}}
    run_id={{quote(run_id)}}
    sample_id={{quote(sample_id)}}
    source scripts/lib/rollout.sh
    require_deployed_source "encode-benchmark $mode" \
      kubernetes/mod.just \
      scripts/encode-benchmark \
      kubernetes/apps/media/encode-benchmark
    args=(run "$mode")
    if [[ -n "$run_id" ]]; then args+=("$run_id"); fi
    if [[ -n "$sample_id" ]]; then
      [[ -n "$run_id" ]] || {
        echo 'encode-benchmark-run requires a run ID before a sample ID.' >&2
        exit 64
      }
      args+=("$sample_id")
    fi
    scripts/encode-benchmark/dispatch.sh '{{kubeconfig}}' "${args[@]}"

# Thin finalist convenience alias. The shared run recipe owns the single source
# guard and dispatch path; finalist confirmation remains run/sample-bound.
encode-benchmark-finalist run_id sample_id:
    @just kube encode-benchmark-run finalist {{quote(run_id)}} {{quote(sample_id)}}

# Read-only Job phase, pod node, sanitized summary, and actual kubelet imageID evidence.
encode-benchmark-results run_id: require-bash
    @scripts/encode-benchmark/results.sh {{quote(kubeconfig)}} {{quote(run_id)}}

# Read-only live acceptance for activated inert inputs and ephemeral pod placement.
encode-benchmark-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.encode-benchmark -- scripts/verify/encode-benchmark.sh {{quote(kubeconfig)}}

# Create one short-lived cleanup Job that can remove only the confirmed run tree.
encode-benchmark-clean run_id: require-bash
    @scripts/encode-benchmark/dispatch.sh {{quote(kubeconfig)}} clean {{quote(run_id)}}

# Verify the live qbit_manage: Kustomization + HelmRelease Ready, rollout, no crash-loop, and
# a recent authenticated run with no config-parse/login failure. Operator-only; not in ci.
qbit-manage-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.qbit-manage -- scripts/verify/qbit-manage.sh {{quote(kubeconfig)}}

# Read the preserved application trace for one run-owned qbit_manage E2E Job.
# The exact run/phase validation and labels prevent this diagnostic from reading
# an unrelated qbit_manage workload. Operator-only; not in ci.
qbit-manage-e2e-trace run_id phase="limits": require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    run_id={{quote(run_id)}}
    phase={{quote(phase)}}
    kubeconfig='{{kubeconfig}}'
    namespace='media'

    [[ "$run_id" =~ ^[a-z0-9]{8,24}$ ]] || {
      echo 'Usage: just kube qbit-manage-e2e-trace <run-id> [private|cz-apply|cz-repeat|limits|cleanup|cleanup-repeat]' >&2
      exit 2
    }
    case "$phase" in
      private|cz-apply|cz-repeat|limits|cleanup|cleanup-repeat) ;;
      *)
        echo 'Usage: just kube qbit-manage-e2e-trace <run-id> [private|cz-apply|cz-repeat|limits|cleanup|cleanup-repeat]' >&2
        exit 2
        ;;
    esac
    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }

    job="qbm-e2e-${run_id}-${phase}"
    job_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      get "job/$job" --output json)"
    actual_run="$(yq -r '.metadata.labels."homelab-talos/e2e-run" // ""' <<<"$job_json")"
    actual_target="$(yq -r '.metadata.labels."homelab-talos/e2e-target" // ""' <<<"$job_json")"
    [[ "$actual_run" == "$run_id" && "$actual_target" == 'qbit-manage-policy' ]] || {
      echo "Refusing trace: job/$job does not carry the exact E2E ownership labels." >&2
      exit 1
    }

    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      logs "job/$job" --container app | \
      rg --ignore-case --context 3 \
        "$run_id|share limit group|check (failed|passed)|assigning|completed|filter|config error|exiting scheduled run"

# Delete only the preserved Jobs and ConfigMaps owned by one exact qbit_manage E2E run.
# This is a live-cluster mutation, so it requires a run-bound confirmation token.
qbit-manage-e2e-debug-cleanup run_id: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    run_id={{quote(run_id)}}
    kubeconfig='{{kubeconfig}}'
    namespace='media'
    expected_confirmation="delete:e2e-qbit-manage:${run_id}"

    [[ "$run_id" =~ ^[a-z0-9]{8,24}$ ]] || {
      echo 'Usage: QBM_E2E_CLEANUP_CONFIRM=delete:e2e-qbit-manage:<run-id> just kube qbit-manage-e2e-debug-cleanup <run-id>' >&2
      exit 2
    }
    [[ "${QBM_E2E_CLEANUP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Refusing cleanup: set QBM_E2E_CLEANUP_CONFIRM=$expected_confirmation" >&2
      exit 1
    }
    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run just talos kubeconfig." >&2
      exit 1
    }
    api_server="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
      --output jsonpath='{.clusters[0].cluster.server}')"
    [[ "$api_server" == 'https://192.168.90.20:6443' ]] || {
      echo "Refusing cleanup: kubeconfig targets $api_server, not the cluster API VIP." >&2
      exit 1
    }

    selector="homelab-talos/e2e-run=${run_id},homelab-talos/e2e-target=qbit-manage-policy"
    resources="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      get job,configmap --selector "$selector" --output name)"
    if [[ -z "$resources" ]]; then
      echo "No preserved qbit_manage E2E resources found for run $run_id."
      exit 0
    fi
    while IFS= read -r resource; do
      [[ "$resource" =~ ^(job\.batch|configmap)/qbm-e2e-${run_id}-(private|cz-apply|cz-repeat|limits|cleanup|cleanup-repeat)$ ]] || {
        echo "Refusing cleanup: unexpected labeled resource $resource" >&2
        exit 1
      }
    done <<<"$resources"

    printf '%s\n' "$resources"
    kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      delete job,configmap --selector "$selector" --wait=true --timeout=2m
    remaining="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
      get job,configmap --selector "$selector" --output name)"
    [[ -z "$remaining" ]] || {
      echo "Cleanup failed; resources remain: $remaining" >&2
      exit 1
    }
    echo "Removed preserved qbit_manage E2E resources for run $run_id."

# Validate the Phase 10 monitoring source: files, encrypted Grafana Secret,
# dependency graph, staged-suspend uniformity, key values, wiring, HTTPRoutes,
# and the pinned kube-prometheus-stack render.
monitoring-validate: require-bash
    @scripts/validate/monitoring.sh

# Verify the live monitoring stack: HelmReleases + workloads healthy, PVCs bound,
# HTTPRoutes accepted, Prometheus has an up Flux-exporter target with every configured
# resource kind, both Flux rules loaded and healthy, an active Alertmanager connection,
# the expected ntfy route loaded, and the foundation still green. Does not send alerts.
monitoring-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.monitoring -- scripts/verify/monitoring.sh {{quote(kubeconfig)}}

# Diagnose the Flux resource-alert signal path stage by stage, preserving targeted,
# sanitized evidence in a canonical test result. Read-only; never sends an alert.
flux-alerts-diagnostics: require-bash
    @scripts/test/run-catalog-suite.sh diagnostics.flux-alerts -- scripts/diagnose/flux-alerts.sh {{quote(kubeconfig)}}

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
    @scripts/test/run-catalog-suite.sh verification.gatus -- scripts/verify/gatus.sh {{quote(kubeconfig)}}

# Validate the staged Portainer Phase 1 source: encrypted bootstrap Secret,
# read-only RBAC, Cilium isolation, internal route, retained Longhorn PVC, and
# exact chart post-render. Cluster-independent; included in `just ci`.
portainer-validate: require-bash
    @scripts/validate/portainer.sh

# Enforce the Portainer read-only ClusterRole and binding with Conftest.
portainer-policy-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    args=(
      test
      --all-namespaces
      --policy tests/policy/portainer
      kubernetes/apps/monitoring/portainer/app/rbac.yaml
    )
    set +e
    conftest "${args[@]}"
    result="$?"
    set -e
    if [[ -n "${TEST_RESULT_FRAGMENT_DIR:-}" ]]; then
      set +e
      conftest "${args[@]}" --output junit \
        >"$TEST_RESULT_FRAGMENT_DIR/conftest-portainer-policy.xml"
      reporter_result="$?"
      set -e
      [[ "$reporter_result" -eq "$result" ]] || {
        echo 'Conftest Portainer-policy console and JUnit executions disagreed.' >&2
        exit 2
      }
    fi
    exit "$result"

# Verify live Portainer readiness, storage, routing, isolation, and effective
# impersonated Kubernetes authorization. Operator-only; not in `just ci`.
portainer-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.portainer -- scripts/verify/portainer.sh {{quote(kubeconfig)}}

# Validate the suspended persistent report host and guarded publishing contract.
# Cluster-independent and included in `just ci`.
test-reports-validate: require-bash
    @scripts/validate/test-reports.sh

# Verify the live static report host, retained PVC, route, policy, and catalog.
# Operator-only and read-only.
test-reports-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.test-reports -- scripts/verify/test-reports.sh {{quote(kubeconfig)}}

# Print scoped, read-only report-host reconciliation diagnostics. The dedicated
# namespace contains no Secrets, so pod specs, events, and static-server logs are
# safe to inspect. Operator-only; not in `just ci`.
test-reports-diagnostics: require-bash
    @scripts/diagnose/test-reports.sh {{quote(kubeconfig)}}

# Confirmation-guarded pod recreation proving the Portainer database remains on
# the original PVC. Operator-only and intentionally separate from bootstrap.
portainer-persistence-test: require-bash
    @scripts/test/run-catalog-suite.sh test.portainer-persistence -- scripts/verify/portainer-persistence.sh {{quote(kubeconfig)}}

# Validate the Phase 10 Homepage source: files, wiring, namespace gateway label,
# dependency graph, pinned image, allowed-hosts, HTTPRoute, and the render.
homepage-validate: require-bash
    @scripts/validate/homepage.sh

# Verify the live Homepage app: Kustomization Ready, deployment rolled out,
# HTTPRoute accepted, dashboard reachable via HTTPS, and foundation green.
homepage-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.homepage -- scripts/verify/homepage.sh {{quote(kubeconfig)}}

# Validate the Phase 10 Trivy Operator source: files, wiring, staged suspend,
# dependency, pinned chart, key scanner settings, and the render.
trivy-validate: require-bash
    @scripts/validate/trivy.sh

# Verify the live Trivy Operator: Kustomization + HelmRelease Ready, operator
# rolled out, report CRDs installed, and foundation green.
trivy-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.trivy -- scripts/verify/trivy.sh {{quote(kubeconfig)}}

# Validate the Tailscale operator source: files, wiring, staged suspend, cilium
# dependency, SOPS decryption, pinned chart, privileged-namespace exception, the
# API-server-proxy scope guard, the ingress ProxyGroup, and the render.
tailscale-operator-validate: require-bash
    @scripts/validate/tailscale-operator.sh

# Verify the live Tailscale operator: Kustomization + HelmRelease Ready, operator
# rolled out, both ingress ProxyGroup replicas Ready, and foundation green.
tailscale-operator-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.tailscale-operator -- scripts/verify/tailscale-operator.sh {{quote(kubeconfig)}}

# Validate the Tailscale subnet-router source: files, staged Kustomization wiring +
# operator dependency, hostnamePrefix HA Connector referencing the node-spread ProxyClass,
# the dedicated tag:lab-router, the exact-two-/32 least-privilege route allowlist (rejecting
# LAN/Pod/Service CIDRs), the hard topology-spread ProxyClass, no Funnel, and the render.
tailscale-subnet-router-validate: require-bash
    @scripts/validate/tailscale-subnet-router.sh

# Verify the live Tailscale subnet router: Kustomization Ready, ConnectorReady, two managed
# devices, exactly the two /32 routes, two Ready replicas on distinct nodes, Envoy Gateway
# Programmed, and a representative HTTPRoute Accepted. Route approval stays a manual step.
tailscale-subnet-router-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.tailscale-subnet-router -- scripts/verify/tailscale-subnet-router.sh {{quote(kubeconfig)}}

# Validate the Tailscale alert rules offline: extract the PrometheusRule .spec (single source)
# and run promtool check + unit tests — the 7 alerts across three temporal states (silent →
# firing → silent) and the absent() matcher cases (unrelated object present, target absent).
tailscale-alerts-validate: require-bash
    @scripts/validate/tailscale-alerts.sh

# Validate the ntfy source: files, wiring, staged suspend, dependency graph, SOPS
# decryption, pinned image, hardened non-root pod, RWO PVC, server.yml (deny-all,
# require-login, signup off, iOS upstream, metrics listener), the internal HTTPRoute,
# the private Tailscale Ingress, ServiceMonitor, CiliumNetworkPolicy, and the render.
ntfy-validate: require-bash
    @scripts/validate/ntfy.sh

# Verify the live ntfy: Kustomization + HelmRelease Ready, rollout complete, health
# endpoint healthy, anonymous access denied, the subscriber's exact runtime read-only
# ACLs, per-token ACLs, and cache persistence.
ntfy-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.ntfy -- scripts/verify/ntfy.sh {{quote(kubeconfig)}}

# Validate the alertmanager-ntfy adapter source: files, wiring, staged suspend, dependency
# graph, SOPS decryption, pinned image, hardened pod, split config (dynamic topic/priority),
# CNP, rollout annotations, the Alertmanager receiver/route in kube-prometheus-stack, and
# the render.
alertmanager-ntfy-validate: require-bash
    @scripts/validate/alertmanager-ntfy.sh

# Verify the live alertmanager-ntfy adapter: Kustomization + HelmRelease Ready, rollout
# complete, and the Alertmanager 'ntfy' receiver present. A synthetic notification remains
# a separate explicit, confirmation-guarded E2E test.
alertmanager-ntfy-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.alertmanager-ntfy -- scripts/verify/alertmanager-ntfy.sh {{quote(kubeconfig)}}

# Prove the real Flux failure rule, Alertmanager route, and synchronous ntfy adapter
# delivery for both firing and resolved states. Creates only a run-owned Kustomization
# with a deliberately nonexistent source, holds the failure for the production 15-minute
# alert window, and deletes it. Operator-only; state-changing; allow about 25 minutes.
# Guard: FLUX_ALERT_E2E_CONFIRM='test:flux-alert:firing-resolved'.
flux-alert-delivery-test: require-bash
    @scripts/test/run-catalog-suite.sh test.e2e.flux-alert-delivery -- scripts/test/scenarios/flux-alert-delivery.sh {{quote(kubeconfig)}}

# Synchronize an API-managed ntfy consumer (seerr) with its token from the canonical
# ntfy Secret: enforce the managed ntfy settings through Seerr's settings API, proving
# the candidate with Seerr's test endpoint before saving. Operator-only; needs the age
# key and LAN reachability. Guard: NTFY_CONSUMER_SYNC_CONFIRM='sync:media:seerr:ntfy'.
ntfy-consumer-sync consumer: require-bash
    #!/usr/bin/env bash
    set -euo pipefail

    kubeconfig='{{kubeconfig}}'
    expected_origin='https://github.com/{{github_owner}}/{{github_repository}}.git'
    [[ -f "$kubeconfig" ]] || {
      echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
      exit 1
    }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]] || {
      echo "Refusing ntfy consumer sync: origin must be $expected_origin." >&2
      exit 1
    }

    source scripts/lib/rollout.sh
    require_deployed_source 'ntfy consumer sync' \
      kubernetes/mod.just \
      scripts/secrets/ntfy-consumer-sync.sh \
      kubernetes/apps/monitoring/ntfy \
      kubernetes/apps/monitoring/homepage/app/homepage-seerr.sops.yaml \
      kubernetes/apps/media/seerr

    remote_ref="$(git ls-remote --exit-code origin refs/heads/main)"
    read -r remote_sha _ <<<"$remote_ref"
    [[ "$remote_sha" =~ ^[0-9a-f]{40}$ ]] || {
      echo "Refusing ntfy consumer sync: invalid origin/main revision '$remote_sha'." >&2
      exit 1
    }
    flux_revision="$(
      kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
        get gitrepository flux-system \
        --output jsonpath='{.status.artifact.revision}'
    )"
    flux_sha="${flux_revision##*:}"
    [[ "$flux_sha" == "$remote_sha" ]] || {
      echo "Refusing ntfy consumer sync: origin/main=$remote_sha Flux=$flux_sha." >&2
      exit 1
    }
    for app in ntfy homepage seerr; do
      state="$(
        kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
          get kustomization "$app" --output json
      )"
      ready="$(yq -r '[(.status.conditions // [])[] | select(.type == "Ready") | .status][0] // ""' - <<<"$state")"
      applied="$(yq -r '.status.lastAppliedRevision // ""' - <<<"$state")"
      suspended="$(yq -r '.spec.suspend // false' - <<<"$state")"
      [[ "$ready" == 'True' && "$suspended" == 'false' && "$applied" == *"$remote_sha" ]] || {
        echo "Refusing ntfy consumer sync: Flux Kustomization $app is not Ready and applied at origin/main $remote_sha." >&2
        exit 1
      }
    done

    just repo secrets
    exec scripts/secrets/ntfy-consumer-sync.sh '{{consumer}}'
