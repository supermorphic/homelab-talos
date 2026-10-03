#!/usr/bin/env bash
# Observational only: no application credentials, exec, downloads or live mutation.
set -euo pipefail
source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: komga.sh <kubeconfig>' >&2
  exit 2
}
kc=(kubectl --kubeconfig "$1" --context homelab-observer)
fail() {
  echo "Komga verification failed: $*" >&2
  exit 1
}
for resource in 'flux-system kustomization' 'media helmrelease'; do
  read -r namespace kind <<<"$resource"
  [[ "$("${kc[@]}" -n "$namespace" get "$kind" komga -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == 'True' ]] || fail "$kind is not Ready"
done
"${kc[@]}" -n media rollout status deployment/komga --timeout=60s
for claim in komga media-data; do
  pvc="$("${kc[@]}" -n media get pvc "$claim" -o json)"
  [[ "$(yq -r '.status.phase' <<<"$pvc")" == Bound ]] || fail "$claim is not Bound"
  if [[ "$claim" == komga ]]; then
    [[ "$(yq -r '.spec.storageClassName' <<<"$pvc")" == longhorn ]] || fail 'config claim must use longhorn storage'
    [[ "$(yq -r '.spec.accessModes | join(",")' <<<"$pvc")" == ReadWriteOnce ]] || fail 'config claim must use ReadWriteOnce access'
    [[ "$(yq -r '.metadata.annotations."helm.sh/resource-policy"' <<<"$pvc")" == keep ]] || fail 'config claim is not retained by Helm'
  fi
done
deployment="$("${kc[@]}" -n media get deployment komga -o json)"
[[ "$(yq -r '.spec.strategy.type' <<<"$deployment")" == Recreate ]] || fail 'deployment is not Recreate'
[[ "$(yq -r '.spec.replicas' <<<"$deployment")" == 1 ]] || fail 'deployment has multiple config writers'
# Follow the application's mount reference to its PVC; a Bound but unused claim
# does not preserve application state. Volume names/order are chart details.
config_mounts="$(yq -o=json '[.spec.template.spec.containers[] | select(.name == "app") |
  .volumeMounts[]? | select(.mountPath == "/config")]' <<<"$deployment")"
[[ "$(yq -r 'length' <<<"$config_mounts")" == 1 ]] || fail 'app must mount /config exactly once'
[[ "$(yq -r '.[0].readOnly // false' <<<"$config_mounts")" == false ]] || fail '/config mount is read-only'
config_volume="$(yq -r '.[0].name' <<<"$config_mounts")"
[[ "$(CONFIG_VOLUME="$config_volume" yq -r '[.spec.template.spec.volumes[] |
  select(.name == strenv(CONFIG_VOLUME)) |
  select(.persistentVolumeClaim.claimName == "komga" and
    (.persistentVolumeClaim.readOnly // false) == false)] | length' <<<"$deployment")" == 1 ]] || fail '/config must reference the writable komga claim'
[[ "$(yq -r '[.spec.template.spec.volumes[] | select(.persistentVolumeClaim.claimName == "media-data")] | length' <<<"$deployment")" == 1 ]] || fail 'shared media claim is missing'
expected_image="$(yq -r '.controllers.komga.containers.app.image | .repository + ":" + .tag' kubernetes/apps/media/komga/app/values.yaml)"
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") | .image' <<<"$deployment")" == "$expected_image" ]] || fail 'deployed image differs from this checkout'
route="$("${kc[@]}" -n media get httproute komga -o json)"
for condition in Accepted ResolvedRefs; do
  CONDITION="$condition" yq -e '.status.parents[] |
    select(.parentRef.name == "internal") | .conditions[] |
    select(.type == strenv(CONDITION) and .status == "True")' <<<"$route" >/dev/null || fail "route $condition is not True"
done
# Follow the comic mount to the shared claim and require the same restricted view.
comic_mounts="$(yq -o=json '[.spec.template.spec.containers[] | select(.name == "app") |
  .volumeMounts[]? | select(.mountPath == "/data/media/comics")]' <<<"$deployment")"
[[ "$(yq -r 'length' <<<"$comic_mounts")" == 1 ]] || fail 'comic mount must exist exactly once'
[[ "$(yq -r '.[0] | [.subPath, .readOnly] | join(",")' <<<"$comic_mounts")" == 'media/comics,true' ]] || fail 'comic mount must be a read-only subtree'
comic_volume="$(yq -r '.[0].name' <<<"$comic_mounts")"
[[ "$(COMIC_VOLUME="$comic_volume" yq -r '[.spec.template.spec.volumes[] |
  select(.name == strenv(COMIC_VOLUME) and .persistentVolumeClaim.claimName == "media-data")] |
  length' <<<"$deployment")" == 1 ]] || fail 'comic mount does not reference media-data'
[[ "$(yq -r '.spec.parentRefs[] | [.name, .namespace, .sectionName] | join(",")' <<<"$route")" == 'internal,networking,https' ]] || fail 'route must attach only to private HTTPS'
host='komga.lab.supermorphic.com'
[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host" A | sort -u)" == "$HOMELAB_GATEWAY_VIP" ]] || fail 'private DNS differs from the internal Gateway'
# Use normal client DNS and TLS trust; no --resolve or insecure TLS bypass.
health="$(curl --fail --silent --show-error --max-time 15 --max-redirs 0 \
  "https://$host/actuator/health")"
[[ "$(yq -p=json -r '.status' <<<"$health")" == UP ]] || fail 'server health is not UP'
echo 'Komga resources, retained state, read-only comics, image, private route, DNS and trusted HTTPS passed. Indexing, native reading, resource sizing and recovery remain separate acceptance gates.'
