#!/usr/bin/env bash
# Observational only: no application credentials, exec, downloads or live mutation.
set -euo pipefail
source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || {
  echo 'Usage: mylar3.sh <kubeconfig>' >&2
  exit 2
}
kc=(kubectl --kubeconfig "$1")
fail() {
  echo "Mylar3 verification failed: $*" >&2
  exit 1
}
for resource in 'flux-system kustomization' 'media helmrelease'; do
  read -r namespace kind <<<"$resource"
  [[ "$("${kc[@]}" -n "$namespace" get "$kind" mylar3 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == 'True' ]] || fail "$kind is not Ready"
done
"${kc[@]}" -n media rollout status deployment/mylar3 --timeout=60s
for claim in mylar3 media-data; do
  pvc="$("${kc[@]}" -n media get pvc "$claim" -o json)"
  [[ "$(yq -r '.status.phase' <<<"$pvc")" == Bound ]] || fail "$claim is not Bound"
  if [[ "$claim" == mylar3 ]]; then
    [[ "$(yq -r '.spec.storageClassName' <<<"$pvc")" == longhorn ]] || fail 'config claim must use longhorn storage'
    [[ "$(yq -r '.spec.accessModes | join(",")' <<<"$pvc")" == ReadWriteOnce ]] || fail 'config claim must use ReadWriteOnce access'
    [[ "$(yq -r '.metadata.annotations."helm.sh/resource-policy"' <<<"$pvc")" == keep ]] || fail 'config claim is not retained by Helm'
  fi
done
deployment="$("${kc[@]}" -n media get deployment mylar3 -o json)"
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
  select(.persistentVolumeClaim.claimName == "mylar3" and
    (.persistentVolumeClaim.readOnly // false) == false)] | length' <<<"$deployment")" == 1 ]] || fail '/config must reference the writable mylar3 claim'
[[ "$(yq -r '[.spec.template.spec.volumes[] | select(.persistentVolumeClaim.claimName == "media-data")] | length' <<<"$deployment")" == 1 ]] || fail 'shared media claim is missing'
expected_image="$(yq -r '.controllers.mylar3.containers.app.image | .repository + ":" + .tag' kubernetes/apps/media/mylar3/app/values.yaml)"
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") | .image' <<<"$deployment")" == "$expected_image" ]] || fail 'deployed image differs from this checkout'
route="$("${kc[@]}" -n media get httproute mylar3 -o json)"
for condition in Accepted ResolvedRefs; do
  CONDITION="$condition" yq -e '.status.parents[] |
    select(.parentRef.name == "internal") | .conditions[] |
    select(.type == strenv(CONDITION) and .status == "True")' <<<"$route" >/dev/null || fail "route $condition is not True"
done
host='mylar3.lab.supermorphic.com'
[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host" A | sort -u)" == "$HOMELAB_GATEWAY_VIP" ]] || fail 'private DNS differs from the internal Gateway'
status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --max-time 15 --max-redirs 0 --resolve "$host:443:$HOMELAB_GATEWAY_VIP" \
  "https://$host/auth/login")"
[[ "$status" == 200 ]] || fail "login page returned $status, expected 200"
echo 'Mylar3 resources, retained claims, image, private route, DNS and login page passed. Acquisition and rescheduling are separate acceptance gates.'
