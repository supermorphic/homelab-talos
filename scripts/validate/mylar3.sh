#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/mylar3'
values="$base/app/values.yaml"
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-mylar3-validate.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

rg -qx '  - ./mylar3/ks.yaml' kubernetes/apps/media/kustomization.yaml
kustomize build "$base/app" >"$temp_dir/source.yaml"
helm template mylar3 "$(yq -r '.spec.url' "$oci")" \
  --version "$(yq -r '.spec.ref.tag' "$oci")" --namespace media \
  --values "$values" >"$temp_dir/helm-output.yaml"
# Helm 4 prints OCI pull metadata to stdout before its YAML documents.
sed '/^Pulled: /d; /^Digest: sha256:/d' "$temp_dir/helm-output.yaml" >"$temp_dir/render.yaml"
yq 'select(.kind == "Deployment")' "$temp_dir/render.yaml" >"$temp_dir/deployment.yaml"
yq 'select(.kind == "PersistentVolumeClaim")' "$temp_dir/render.yaml" >"$temp_dir/pvc.yaml"
dep="$temp_dir/deployment.yaml"

# Rendered invariants: a single config writer, retained block storage, shared data,
# and a private Service whose port agrees with the route and health checks.
[[ "$(yq -r '.metadata.name' "$dep")" == 'mylar3' ]]
[[ "$(yq -r '.spec.replicas' "$dep")" == '1' ]]
[[ "$(yq -r '.spec.strategy.type' "$dep")" == 'Recreate' ]]
[[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$dep")" == 'false' ]]
[[ "$(yq -r '[.spec.storageClassName, .spec.accessModes[0], .metadata.annotations."helm.sh/resource-policy"] | join(",")' "$temp_dir/pvc.yaml")" == 'longhorn,ReadWriteOnce,keep' ]]
[[ "$(yq -r '[.spec.template.spec.volumes[] | select(.persistentVolumeClaim.claimName == "media-data")] | length' "$dep")" == '1' ]]
[[ "$(yq -r '[.spec.template.spec.containers[0].volumeMounts[].mountPath] | sort | join(",")' "$dep")" == '/config,/data' ]]
[[ "$(yq -r 'select(.kind == "Service") | .spec.ports[0].port' "$temp_dir/render.yaml")" == '8090' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$base/app/httproute.yaml")" == '8090' ]]
for probe in startupProbe readinessProbe livenessProbe; do
  [[ "$(yq -r ".spec.template.spec.containers[0].$probe.httpGet.path" "$dep")" == '/auth/login' ]]
  [[ "$(yq -r ".spec.template.spec.containers[0].$probe.httpGet.port" "$dep")" == '8090' ]]
done

# LinuxServer's root init needs only these capabilities to set ownership and drop
# to the shared media UID. No custom command may bypass that privilege drop.
[[ "$(yq -r '.controllers.mylar3.containers.app.command // "none"' "$values")" == 'none' ]]
[[ "$(yq -r '.controllers.mylar3.containers.app.env.PUID' "$values")" == '568' ]]
[[ "$(yq -r '.controllers.mylar3.containers.app.env.PGID' "$values")" == '568' ]]
[[ "$(yq -r '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' "$dep")" == 'false' ]]
[[ "$(yq -r '.spec.template.spec.containers[0].securityContext.capabilities.add | sort | join(",")' "$dep")" == 'CHOWN,DAC_OVERRIDE,FOWNER,KILL,SETGID,SETUID' ]]

# Onboarding comics must not enroll them in cleanup before import/seeding acceptance.
[[ "$(yq -r '[.share_limits[] | select(.cleanup == true) | .categories[] | select(. == "comics")] | length' kubernetes/apps/media/qbit-manage/app/config.yml)" == '0' ]]
kubeconform -strict -summary \
  -kubernetes-version "$(yq -p=toml -oy -r '.tools.kubectl' .mise.toml)" \
  "$temp_dir/render.yaml"
echo 'Mylar3 chart, config retention, shared data, startup privileges, probes and category isolation passed.'
