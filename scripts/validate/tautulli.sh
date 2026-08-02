#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/tautulli'
ks="$base/ks.yaml"
hr="$base/app/helmrelease.yaml"
values="$base/app/values.yaml"
route="$base/app/httproute.yaml"
app_kustomization="$base/app/kustomization.yaml"
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
gatus_values='kubernetes/apps/monitoring/gatus/app/values.yaml'
homepage_deployment='kubernetes/apps/monitoring/homepage/app/deployment.yaml'
homepage_kustomization='kubernetes/apps/monitoring/homepage/app/kustomization.yaml'
homepage_secret='kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-tautulli-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$values" "$route" "$app_kustomization" "$oci" \
  "$gatus_values" "$homepage_deployment" "$homepage_kustomization"; do
  [[ -f "$f" ]] || { echo "Missing Tautulli source: $f" >&2; exit 1; }
done
rg -qx '  - ./tautulli/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
  echo 'Refusing: ./tautulli/ks.yaml is not wired into the media kustomization.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.spec.decryption // "none"' "$ks")" == 'none' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,media' ]]
[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

[[ "$(yq -r '.controllers.tautulli.strategy' "$values")" == 'Recreate' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.image.repository' "$values")" == 'ghcr.io/home-operations/tautulli' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.image.tag' "$values")" == '2.17.2' ]]
[[ "$(yq -r '.controllers.tautulli.pod.securityContext.runAsUser' "$values")" == '568' ]]
[[ "$(yq -r '.controllers.tautulli.pod.securityContext.runAsGroup' "$values")" == '568' ]]
[[ "$(yq -r '.controllers.tautulli.pod.securityContext.fsGroup' "$values")" == '568' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.securityContext.allowPrivilegeEscalation' "$values")" == 'false' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.securityContext.capabilities.drop | join(",")' "$values")" == 'ALL' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.resources.requests.cpu' "$values")" == '25m' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.resources.requests.memory' "$values")" == '256Mi' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.resources.limits.memory' "$values")" == '1Gi' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.resources.limits.cpu // "none"' "$values")" == 'none' ]]

for probe in readiness liveness startup; do
  [[ "$(yq -r ".controllers.tautulli.containers.app.probes.$probe.custom" "$values")" == 'true' ]]
  [[ "$(yq -r ".controllers.tautulli.containers.app.probes.$probe.spec.httpGet.path" "$values")" == '/status' ]]
  [[ "$(yq -r ".controllers.tautulli.containers.app.probes.$probe.spec.httpGet.port" "$values")" == '8181' ]]
done
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.readiness.spec.periodSeconds' "$values")" == '10' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.readiness.spec.failureThreshold' "$values")" == '3' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.liveness.spec.periodSeconds' "$values")" == '30' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.liveness.spec.failureThreshold' "$values")" == '5' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.startup.spec.periodSeconds' "$values")" == '5' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.startup.spec.failureThreshold' "$values")" == '30' ]]

[[ "$(yq -r '.service.app.ports.http.port' "$values")" == '8181' ]]
[[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOnce' ]]
[[ "$(yq -r '.persistence.config.size' "$values")" == '5Gi' ]]
[[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
[[ "$(yq -r '.persistence.config.annotations."helm.sh/resource-policy"' "$values")" == 'keep' ]]
[[ "$(yq -r '.persistence.config.globalMounts[0].path' "$values")" == '/config' ]]
[[ "$(yq -r '.persistence.data // "none"' "$values")" == 'none' ]]
[[ "$(yq -r '.persistence.media // "none"' "$values")" == 'none' ]]

[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'tautulli.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$route")" == 'tautulli' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == '8181' ]]
widget_count="$(yq -r '[(.metadata.annotations // {}) | keys[] | select(test("^gethomepage\\.dev/widget\\."))] | length' "$route")"
gatus_count="$(yq -r '[.config.endpoints[] | select(.name == "tautulli" and .group == "Media")] | length' "$gatus_values")"
homepage_env_count="$(yq -r '[.spec.template.spec.containers[].env[]? | select(.name == "HOMEPAGE_VAR_TAUTULLI_API_KEY")] | length' "$homepage_deployment")"
homepage_resource_count="$(yq -r '[.resources[] | select(. == "./homepage-tautulli.sops.yaml")] | length' "$homepage_kustomization")"
if [[ "$suspend_state" == 'true' ]]; then
  [[ "$widget_count" == '0' ]]
  [[ "$gatus_count" == '0' ]]
  [[ "$homepage_env_count" == '0' ]]
  [[ "$homepage_resource_count" == '0' ]]
  [[ ! -e "$homepage_secret" ]]
else
  [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$route")" == 'tautulli' ]]
  [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.url"' "$route")" == 'http://tautulli.media.svc.cluster.local:8181' ]]
  [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.key"' "$route")" == '{{HOMEPAGE_VAR_TAUTULLI_API_KEY}}' ]]
  [[ "$gatus_count" == '1' ]]
  [[ "$(yq -r '.config.endpoints[] | select(.name == "tautulli") | .url' "$gatus_values")" == 'https://tautulli.lab.supermorphic.com/status' ]]
  [[ "$(yq -r '.config.endpoints[] | select(.name == "tautulli") | .conditions | join(",")' "$gatus_values")" == '[STATUS] == 200' ]]
  [[ "$homepage_env_count" == '1' ]]
  [[ "$homepage_resource_count" == '1' ]]
  [[ -f "$homepage_secret" ]]
  [[ "$(sops filestatus "$homepage_secret" | yq -r '.encrypted')" == 'true' ]]
  [[ "$(yq -r '.metadata.name' "$homepage_secret")" == 'homepage-tautulli' ]]
  [[ "$(yq -r '.metadata.namespace' "$homepage_secret")" == 'homepage' ]]
  [[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_TAUTULLI_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$homepage_deployment")" == 'homepage-tautulli' ]]
  [[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_TAUTULLI_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$homepage_deployment")" == 'apiKey' ]]
  [[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_TAUTULLI_API_KEY") | .valueFrom.secretKeyRef.optional] | .[0]' "$homepage_deployment")" == 'true' ]]
fi

chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
kustomize build "$base/app" >/dev/null
helm template tautulli "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
[[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'tautulli' ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/render.yaml")" == 'Recreate' ]]
[[ "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .metadata.name' "$temp_dir/render.yaml")" == 'tautulli' ]]

echo 'Tautulli source, config-only storage, security, probes, route, activation boundary, and pinned render passed validation.'
