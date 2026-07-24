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
