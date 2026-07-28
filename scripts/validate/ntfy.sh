#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/ntfy'
ks="$base/ks.yaml"
app="$base/app"
values="$app/values.yaml"
server="$app/server.yml"
hr="$app/helmrelease.yaml"
oci="$app/ocirepository.yaml"
secret="$app/secret.sops.yaml"
route="$app/httproute.yaml"
ingress="$app/tailscale-ingress.yaml"
gatus='kubernetes/apps/monitoring/gatus/app/values.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-ntfy-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$values" "$server" "$hr" "$oci" "$secret" "$app/namespace.yaml" \
  "$route" "$ingress" "$app/servicemonitor.yaml" "$app/ciliumnetworkpolicy.yaml" \
  "$app/prometheusrule.yaml" "$app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing ntfy source: $f" >&2; exit 1; }
done
rg -qx '  - ./ntfy/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: ./ntfy/ks.yaml is not listed in the monitoring kustomization.' >&2
  exit 1
}

# Flux Kustomization: suspend gate, full dependency graph, SOPS decryption.
suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'cilium,internal-gateway,kube-prometheus-stack,longhorn,tailscale-operator' ]]
[[ "$(yq -r '.spec.decryption.provider' "$ks")" == 'sops' ]]

# Pinned app-template chart.
[[ "$(yq -r '.spec.ref.tag' "$oci")" == '5.0.1' ]]
[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

# Single ntfy controller, Recreate on RWO storage, pinned non-latest image, serve arg.
[[ "$(yq -r '.controllers | keys | .[]' "$values")" == 'ntfy' ]]
[[ "$(yq -r '.controllers.ntfy.type' "$values")" == 'deployment' ]]
[[ "$(yq -r '.controllers.ntfy.strategy' "$values")" == 'Recreate' ]]
image_repo="$(yq -r '.controllers.ntfy.containers.app.image.repository' "$values")"
image_tag="$(yq -r '.controllers.ntfy.containers.app.image.tag' "$values")"
[[ "$image_repo" == *'binwiederhier/ntfy' ]]
[[ -n "$image_tag" && "$image_tag" != 'null' && "$image_tag" != 'latest' ]]
[[ "$(yq -r '.controllers.ntfy.containers.app.args | join(" ")' "$values")" == 'serve' ]]

# Hardened non-root pod.
[[ "$(yq -r '.controllers.ntfy.pod.securityContext.runAsNonRoot' "$values")" == 'true' ]]
[[ "$(yq -r '.controllers.ntfy.pod.securityContext.runAsUser' "$values")" != '0' ]]
[[ "$(yq -r '.controllers.ntfy.pod.securityContext.fsGroup' "$values")" != 'null' ]]
[[ "$(yq -r '.controllers.ntfy.pod.securityContext.seccompProfile.type' "$values")" == 'RuntimeDefault' ]]
[[ "$(yq -r '.controllers.ntfy.containers.app.securityContext.capabilities.drop | join(",")' "$values")" == 'ALL' ]]

# Declarative auth from the SOPS Secret.
[[ "$(yq -r '.controllers.ntfy.containers.app.envFrom[].secretRef.name' "$values")" == 'ntfy-secret' ]]

# RWO Longhorn config PVC at /var/lib/ntfy, retained across teardown.
[[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOnce' ]]
[[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
[[ "$(yq -r '.persistence.config.annotations."helm.sh/resource-policy"' "$values")" == 'keep' ]]
[[ "$(yq -r '.persistence.config.globalMounts[0].path' "$values")" == '/var/lib/ntfy' ]]

# Service exposes http + a dedicated metrics port.
[[ "$(yq -r '.service.app.ports.http.port' "$values")" == '80' ]]
[[ "$(yq -r '.service.app.ports.metrics.port' "$values")" == '9090' ]]

# Probes hit the real health endpoint.
[[ "$(yq -r '.controllers.ntfy.containers.app.probes.readiness.spec.httpGet.path' "$values")" == '/v1/health' ]]

# Rollout annotations track server.yml (config-hash) and the encrypted Secret
# (sops-hash, stamped by `just repo ntfy-secrets`) so either change rolls the pod.
[[ "$(yq -r '.controllers.ntfy.pod.annotations.config-hash' "$values")" == "$(git hash-object "$server")" ]]
[[ "$(yq -r '.controllers.ntfy.pod.annotations.sops-hash' "$values")" == "$(git hash-object "$secret")" ]]

# server.yml: parses, private, iOS-ready, dedicated metrics, no attachments/email/phone.
yq -e '.' "$server" >/dev/null
[[ "$(yq -r '.base-url' "$server")" =~ ^https://ntfy\..*\.ts\.net$ ]]
[[ "$(yq -r '.["behind-proxy"]' "$server")" == 'true' ]]
[[ "$(yq -r '.["cache-file"]' "$server")" == /var/lib/ntfy/* ]]
[[ "$(yq -r '.["auth-file"]' "$server")" == /var/lib/ntfy/* ]]
[[ "$(yq -r '.["auth-default-access"]' "$server")" == 'deny-all' ]]
[[ "$(yq -r '.["require-login"]' "$server")" == 'true' ]]
[[ "$(yq -r '.["enable-signup"]' "$server")" == 'false' ]]
[[ "$(yq -r '.["upstream-base-url"]' "$server")" == 'https://ntfy.sh' ]]
[[ "$(yq -r '.["metrics-listen-http"]' "$server")" == ':9090' ]]
for forbidden in attachment-cache-dir smtp-sender-addr smtp-server-listen enable-calls; do
  if [[ "$(yq -r ".[\"$forbidden\"] // \"absent\"" "$server")" != 'absent' ]]; then
    echo "Refusing: server.yml must not enable $forbidden." >&2
    exit 1
  fi
done

# HTTPRoute: LAN host on the internal gateway, port 80 only (never metrics).
[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'ntfy.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == '80' ]]
if rg -q '9090' "$route"; then
  echo 'Refusing: the HTTPRoute must not expose the metrics port (9090).' >&2
  exit 1
fi

# Private Tailscale Ingress: class, shared proxy-group, tag:ntfy, short host, port 80.
[[ "$(yq -r '.spec.ingressClassName' "$ingress")" == 'tailscale' ]]
[[ "$(yq -r '.metadata.annotations."tailscale.com/proxy-group"' "$ingress")" == 'ingress-proxies' ]]
[[ "$(yq -r '.metadata.annotations."tailscale.com/tags"' "$ingress")" == 'tag:ntfy' ]]
[[ "$(yq -r '.spec.tls[0].hosts[0]' "$ingress")" == 'ntfy' ]]

# ServiceMonitor targets the metrics port name.
[[ "$(yq -r '.spec.endpoints[0].port' "$app/servicemonitor.yaml")" == 'metrics' ]]

# CNP restricts metrics to the monitoring namespace and allows egress to ntfy.sh.
rg -q 'k8s:io.kubernetes.pod.namespace: monitoring' "$app/ciliumnetworkpolicy.yaml"
rg -q 'k8s:io.kubernetes.pod.namespace: homepage' "$app/ciliumnetworkpolicy.yaml"
rg -q 'app.kubernetes.io/name: homepage' "$app/ciliumnetworkpolicy.yaml"
rg -q 'world' "$app/ciliumnetworkpolicy.yaml"

# SOPS Secret shape (encryption itself is enforced by verify-files).
[[ "$(yq -r '.kind' "$secret")" == 'Secret' ]]
[[ "$(yq -r '.metadata.name' "$secret")" == 'ntfy-secret' ]]
[[ "$(yq -r '.metadata.namespace' "$secret")" == 'ntfy' ]]

# Activation-aware Gatus probe: present iff ntfy is active (avoids probe noise while staged).
if [[ "$suspend_state" == 'false' ]]; then
  [[ "$(yq -r '.config.endpoints[] | select(.name == "ntfy") | .url' "$gatus")" == 'http://ntfy.ntfy.svc.cluster.local/v1/health' ]] || {
    echo 'Active ntfy must have its in-cluster Gatus /v1/health endpoint.' >&2
    exit 1
  }
else
  [[ -z "$(yq -r '.config.endpoints[] | select(.name == "ntfy") | .name' "$gatus")" ]] || {
    echo 'Suspended ntfy must not yet register a Gatus endpoint.' >&2
    exit 1
  }
fi

# Render.
kustomize build "$app" >/dev/null
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template ntfy oci://ghcr.io/bjw-s-labs/helm/app-template --version "$(yq -r '.spec.ref.tag' "$oci")" --namespace ntfy --values "$values" >/dev/null

echo 'ntfy source, wiring, dependency graph, SOPS decryption, pinned non-root image, RWO PVC, private server.yml, HTTPRoute, Tailscale Ingress, ServiceMonitor, CNP, rollout annotations, activation-aware Gatus, and render passed validation.'
