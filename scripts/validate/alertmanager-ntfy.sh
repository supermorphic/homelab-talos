#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/alertmanager-ntfy'
ks="$base/ks.yaml"
app="$base/app"
values="$app/values.yaml"
config="$app/config.yml"
hr="$app/helmrelease.yaml"
auth="$app/auth.sops.yaml"
cnp="$app/ciliumnetworkpolicy.yaml"
kps='kubernetes/apps/monitoring/kube-prometheus-stack/app/values.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-alertmanager-ntfy-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$values" "$config" "$hr" "$auth" "$cnp" "$app/kustomization.yaml"; do
  [[ -f "$f" ]] || { echo "Missing alertmanager-ntfy source: $f" >&2; exit 1; }
done
rg -qx '  - ./alertmanager-ntfy/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: ./alertmanager-ntfy/ks.yaml is not listed in the monitoring kustomization.' >&2
  exit 1
}

# Flux Kustomization: suspend gate, dependency graph (ntfy + kube-prometheus-stack), SOPS.
suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'kube-prometheus-stack,ntfy' ]]
[[ "$(yq -r '.spec.decryption.provider' "$ks")" == 'sops' ]]
[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

# Single adapter controller, pinned non-latest image, split-config args.
[[ "$(yq -r '.controllers | keys | .[]' "$values")" == 'alertmanager-ntfy' ]]
image_repo="$(yq -r '.controllers["alertmanager-ntfy"].containers.app.image.repository' "$values")"
image_tag="$(yq -r '.controllers["alertmanager-ntfy"].containers.app.image.tag' "$values")"
[[ "$image_repo" == 'ghcr.io/alexbakker/alertmanager-ntfy' ]]
[[ "$image_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Refusing: adapter image tag '$image_tag' is not an explicit pinned semver." >&2
  exit 1
}
[[ "$(yq -r '.controllers["alertmanager-ntfy"].containers.app.args | join(" ")' "$values")" == '--configs /config/config.yml,/auth/auth.yml' ]]

# Hardened non-root pod.
[[ "$(yq -r '.controllers["alertmanager-ntfy"].pod.securityContext.runAsNonRoot' "$values")" == 'true' ]]
[[ "$(yq -r '.controllers["alertmanager-ntfy"].pod.securityContext.runAsUser' "$values")" != '0' ]]
[[ "$(yq -r '.controllers["alertmanager-ntfy"].containers.app.securityContext.capabilities.drop | join(",")' "$values")" == 'ALL' ]]

# Service + config/auth mounts.
[[ "$(yq -r '.service.app.ports.http.port' "$values")" == '8000' ]]
[[ "$(yq -r '.persistence.config.name' "$values")" == 'alertmanager-ntfy-config' ]]
[[ "$(yq -r '.persistence.auth.name' "$values")" == 'alertmanager-ntfy-auth' ]]

# Rollout annotations track config.yml and the encrypted auth Secret.
[[ "$(yq -r '.controllers["alertmanager-ntfy"].pod.annotations["config-hash"]' "$values")" == "$(git hash-object "$config")" ]]
[[ "$(yq -r '.controllers["alertmanager-ntfy"].pod.annotations["sops-hash"]' "$values")" == "$(git hash-object "$auth")" ]]

# Non-secret adapter config: in-cluster ntfy target, :8000 listener, dynamic topic mapping.
yq -e '.' "$config" >/dev/null
[[ "$(yq -r '.ntfy.baseurl' "$config")" == 'http://ntfy.ntfy.svc.cluster.local' ]]
[[ "$(yq -r '.http.addr' "$config")" == ':8000' ]]
topic="$(yq -r '.ntfy.notification.topic' "$config")"
[[ "$topic" == *'"critical"'* && "$topic" == *'"homelab"'* ]]
priority="$(yq -r '.ntfy.notification.priority' "$config")"
[[ "$priority" == *'status == "resolved" ? "default"'* ]]
[[ "$priority" == *'labels["severity"] == "critical" ? "urgent" : "default"'* ]]

# Auth Secret shape (encryption enforced by verify-files).
[[ "$(yq -r '.kind' "$auth")" == 'Secret' ]]
[[ "$(yq -r '.metadata.name' "$auth")" == 'alertmanager-ntfy-auth' ]]
[[ "$(yq -r '.metadata.namespace' "$auth")" == 'ntfy' ]]

# CNP: only monitoring (Alertmanager) may reach :8000; adapter may egress to ntfy.
rg -q 'k8s:io.kubernetes.pod.namespace: monitoring' "$cnp"
rg -q 'app.kubernetes.io/name: ntfy' "$cnp"

# The kube-prometheus-stack Alertmanager receiver + route point at this adapter.
[[ "$(yq -r '.alertmanager.config.receivers[] | select(.name == "ntfy") | .webhook_configs[0].url' "$kps")" == 'http://alertmanager-ntfy.ntfy.svc.cluster.local:8000/hook' ]]
[[ "$(yq -r '.alertmanager.config.receivers[] | select(.name == "ntfy") | .webhook_configs[0].send_resolved' "$kps")" == 'true' ]]
[[ "$(yq -r '.alertmanager.config.route.routes[] | select(.receiver == "ntfy") | .matchers | join(",")' "$kps")" == 'severity =~ "critical|warning"' ]]

# ntfy CNP must admit this adapter on port 80.
rg -q 'app.kubernetes.io/name: alertmanager-ntfy' kubernetes/apps/monitoring/ntfy/app/ciliumnetworkpolicy.yaml

# Render.
kustomize build "$app" >/dev/null
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repos.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repos.yaml" HELM_REPOSITORY_CACHE="$temp_dir/cache" \
  helm template alertmanager-ntfy oci://ghcr.io/bjw-s-labs/helm/app-template --version 5.0.1 --namespace ntfy --values "$values" >/dev/null

echo 'alertmanager-ntfy source, wiring, dependency graph, SOPS decryption, pinned image, hardened pod, split config with dynamic topic, CNP, rollout annotations, Alertmanager receiver/route, and render passed validation.'
