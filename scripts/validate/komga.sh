#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/komga'
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-komga-validate.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

kustomize build kubernetes/apps/media >"$temp_dir/media.yaml"
[[ "$(yq -r 'select(.kind == "Kustomization" and .metadata.name == "komga") | .spec.path' "$temp_dir/media.yaml")" == "./$base/app" ]]
kustomize build "$base/app" >"$temp_dir/source.yaml"
helm template komga "$(yq -r '.spec.url' "$oci")" \
  --version "$(yq -r '.spec.ref.tag' "$oci")" --namespace media \
  --values "$base/app/values.yaml" >"$temp_dir/helm-output.yaml"
sed '/^Pulled: /d; /^Digest: sha256:/d' "$temp_dir/helm-output.yaml" >"$temp_dir/render.yaml"
yq 'select(.kind == "Deployment")' "$temp_dir/render.yaml" >"$temp_dir/deployment.yaml"
dep="$temp_dir/deployment.yaml"
yq 'select(.kind == "PersistentVolumeClaim")' "$temp_dir/render.yaml" >"$temp_dir/pvc.yaml"
yq 'select(.kind == "Service")' "$temp_dir/render.yaml" >"$temp_dir/service.yaml"

# SQLite must have one writer on retained block storage, never the SMB library.
[[ "$(yq -r '[.metadata.name, .spec.replicas, .spec.strategy.type] | join(",")' "$dep")" == 'komga,1,Recreate' ]]
[[ "$(yq -r '[.metadata.name, .spec.storageClassName, .spec.accessModes[0], .metadata.annotations."helm.sh/resource-policy"] | join(",")' "$temp_dir/pvc.yaml")" == 'komga,longhorn,ReadWriteOnce,keep' ]]
[[ "$(yq -r '[.spec.template.spec.volumes[] | select(.name == "config") | .persistentVolumeClaim.claimName] | join(",")' "$dep")" == komga ]]
[[ "$(yq -r '[.spec.template.spec.containers[0].volumeMounts[] | select(.name == "config") | [.mountPath, (.readOnly // false)] | join(",")] | join(",")' "$dep")" == '/config,false' ]]
# Only the comic subtree is visible, and no container may write to that volume.
[[ "$(yq -r '[.spec.template.spec.volumes[] | select(.persistentVolumeClaim.claimName == "media-data") | .name] | join(",")' "$dep")" == data ]]
[[ "$(yq -r '[.spec.template.spec.containers[].volumeMounts[] | select(.name == "data") | [.mountPath, .subPath, .readOnly] | join(",")] | join(",")' "$dep")" == '/data/media/comics,media/comics,true' ]]
[[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$dep")" == false ]]
[[ "$(yq -r '.spec.template.spec.securityContext.runAsNonRoot' "$dep")" == true ]]
[[ "$(yq -r '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' "$dep")" == false ]]
[[ "$(yq -r '.spec.template.spec.containers[0].securityContext.capabilities.drop | join(",")' "$dep")" == ALL ]]

# The upstream Docker contract uses port 25600 and permits health without login.
[[ "$(yq -r '[.metadata.name, .spec.type, .spec.ports[0].port] | join(",")' "$temp_dir/service.yaml")" == 'komga,ClusterIP,25600' ]]
for probe in startupProbe readinessProbe livenessProbe; do
  [[ "$(yq -r ".spec.template.spec.containers[0].$probe.httpGet | [.path, .port] | join(\",\")" "$dep")" == '/actuator/health,25600' ]]
done
[[ "$(yq -r '.spec.parentRefs[] | [.name, .namespace, .sectionName] | join(",")' "$base/app/httproute.yaml")" == 'internal,networking,https' ]]
[[ "$(yq -r '.spec.rules[].backendRefs[] | [.name, .port] | join(",")' "$base/app/httproute.yaml")" == 'komga,25600' ]]
kubeconform -strict -summary \
  -kubernetes-version "$(yq -p=toml -oy -r '.tools.kubectl' .mise.toml)" \
  "$temp_dir/render.yaml"
echo 'Komga chart, retained single-writer state, read-only comic subtree and private health passed.'
