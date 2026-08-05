#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/plex'
ks="$base/ks.yaml"
hr="$base/app/helmrelease.yaml"
values="$base/app/values.yaml"
route="$base/app/httproute.yaml"
cnp="$base/app/ciliumnetworkpolicy.yaml"
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
image_repository='ghcr.io/home-operations/plex'
image_tag='1.43.3.10828'
image_digest='sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7'
controller='.controllers.plex'
temp_dir="$(mktemp -d /tmp/homelab-talos-plex-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$values" "$route" "$cnp" "$base/app/kustomization.yaml" "$oci"; do
  [[ -f "$f" ]] || { echo "Missing Phase 11 Plex source: $f" >&2; exit 1; }
done

rg -qx '  - ./plex/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
  echo 'Refusing: ./plex/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml.' >&2
  exit 1
}

rg -qx '  - ./ciliumnetworkpolicy.yaml' "$base/app/kustomization.yaml" || {
  echo 'Refusing: ./ciliumnetworkpolicy.yaml is not wired into kubernetes/apps/media/plex/app/kustomization.yaml.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,media-storage' ]]

[[ "$(yq -r '.spec.chartRef.kind' "$hr")" == 'OCIRepository' ]]
[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

[[ "$(yq -r "$controller.type" "$values")" == 'deployment' ]]
[[ "$(yq -r "$controller.strategy" "$values")" == 'Recreate' ]]
[[ "$(yq -r "$controller.pod.automountServiceAccountToken" "$values")" == 'false' ]]
[[ "$(yq -r "$controller.pod.securityContext.runAsNonRoot" "$values")" == 'true' ]]
[[ "$(yq -r "$controller.pod.securityContext.runAsUser" "$values")" == '568' ]]
[[ "$(yq -r "$controller.pod.securityContext.runAsGroup" "$values")" == '568' ]]
[[ "$(yq -r "$controller.pod.securityContext.fsGroup" "$values")" == '568' ]]
[[ "$(yq -r "$controller.pod.securityContext.seccompProfile.type" "$values")" == 'RuntimeDefault' ]]

for container in initContainers.runtime-identity containers.app; do
  [[ "$(yq -r "$controller.$container.image.repository" "$values")" == "$image_repository" ]]
  [[ "$(yq -r "$controller.$container.image.tag" "$values")" == "$image_tag" ]]
  [[ "$(yq -r "$controller.$container.image.digest" "$values")" == "$image_digest" ]]
  [[ "$(yq -r "$controller.$container.securityContext.allowPrivilegeEscalation" "$values")" == 'false' ]]
  [[ "$(yq -r "$controller.$container.securityContext.capabilities.drop | join(\",\")" "$values")" == 'ALL' ]]
  [[ "$(yq -r "$controller.$container.securityContext.runAsNonRoot" "$values")" == 'true' ]]
  [[ "$(yq -r "$controller.$container.securityContext.runAsUser" "$values")" == '568' ]]
  [[ "$(yq -r "$controller.$container.securityContext.runAsGroup" "$values")" == '568' ]]
done

identity_script="$(yq -r "$controller.initContainers.runtime-identity.args[0]" "$values")"
for required in \
  'cp /etc/passwd /runtime-identity/passwd' \
  'plex:x:568:568:Plex Media Server:/config:/usr/sbin/nologin' \
  'chmod 0644 /runtime-identity/passwd'; do
  rg -Fq -- "$required" <<<"$identity_script"
done
if rg -Fq 'relayHostKey' <<<"$identity_script"; then
  echo 'Refusing: Plex runtime identity script must not manage relayHostKey.' >&2
  exit 1
fi
if rg -Fq 'relayHostKey' "$values"; then
  echo 'Refusing: Plex values must not define relayHostKey state.' >&2
  exit 1
fi
[[ "$(yq -r "$controller.replicas" "$values")" == '1' ]]

[[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOncePod' ]]
[[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
[[ "$(yq -r '.persistence.media.existingClaim' "$values")" == 'media-data' ]]
[[ "$(yq -r '.persistence.transcode.type' "$values")" == 'emptyDir' ]]
[[ "$(yq -r '.persistence.runtime-identity.type' "$values")" == 'emptyDir' ]]
[[ "$(yq -r '.persistence.runtime-identity.advancedMounts.plex.runtime-identity[0].path' "$values")" == '/runtime-identity' ]]
[[ "$(yq -r '.persistence.runtime-identity.advancedMounts.plex.app[0].path' "$values")" == '/etc/passwd' ]]
[[ "$(yq -r '.persistence.runtime-identity.advancedMounts.plex.app[0].subPath' "$values")" == 'passwd' ]]
[[ "$(yq -r '.persistence.runtime-identity.advancedMounts.plex.app[0].readOnly' "$values")" == 'true' ]]
[[ "$(yq -r '.persistence.media.advancedMounts.plex.app[0].path' "$values")" == '/Volumes/Prometheus' ]]
[[ "$(yq -r '.persistence.media.advancedMounts.plex.app[0].readOnly' "$values")" == 'true' ]]
[[ "$(yq -r '.persistence.media | has("globalMounts")' "$values")" == 'false' ]]

[[ "$(yq -r '.service.app.type' "$values")" == 'ClusterIP' ]]

[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'plex.lab.supermorphic.com' ]]
[[ "$(yq -r '[.spec.parentRefs[].name] | join(",")' "$route")" == 'internal' ]]
[[ "$(yq -r '.metadata.annotations."external-dns.k8s.io/audience"' "$route")" == 'internal' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == '32400' ]]

# Observed containment: the CiliumNetworkPolicy is the hard prerequisite for any
# public ingress. Its allow-list comes from the phase-1 Hubble capture plus the two
# designed identities observation cannot supply (docs/decisions/2026-08-03-plex-containment-capture.md).
[[ "$(yq -r '.kind' "$cnp")" == 'CiliumNetworkPolicy' ]]
[[ "$(yq -r '.metadata.name' "$cnp")" == 'plex' ]]
[[ "$(yq -r '.metadata.namespace' "$cnp")" == 'media' ]]
[[ "$(yq -r '.spec.endpointSelector.matchLabels | keys | join(",")' "$cnp")" == 'app.kubernetes.io/name' ]]
[[ "$(yq -r '.spec.endpointSelector.matchLabels."app.kubernetes.io/name"' "$cnp")" == 'plex' ]]

# TCP 32400 is the only ingress port, from exactly the captured consumer set.
[[ "$(yq -r '.spec.ingress | length' "$cnp")" == '2' ]]
[[ "$(yq -r '[.spec.ingress[].toPorts[].ports[] | .port + "/" + .protocol] | unique | join(",")' "$cnp")" == '32400/TCP' ]]
[[ "$(yq -r '.spec.ingress[0] | keys | sort | join(",")' "$cnp")" == 'fromEndpoints,toPorts' ]]
[[ "$(yq -r '[.spec.ingress[0].fromEndpoints[] | keys | join(",")] | unique | join(",")' "$cnp")" == 'matchLabels' ]]
[[ "$(yq -r '[.spec.ingress[0].fromEndpoints[].matchLabels | to_entries | map(.key + "=" + .value) | sort | join(",")] | sort | join(";")' "$cnp")" == 'app.kubernetes.io/name=homepage,k8s:io.kubernetes.pod.namespace=homepage;app.kubernetes.io/name=tautulli,k8s:io.kubernetes.pod.namespace=media;gateway.envoyproxy.io/owning-gateway-name=internal,k8s:io.kubernetes.pod.namespace=envoy-gateway-system;gateway.envoyproxy.io/owning-gateway-name=public,k8s:io.kubernetes.pod.namespace=envoy-gateway-system' ]]
[[ "$(yq -r '.spec.ingress[1] | keys | sort | join(",")' "$cnp")" == 'fromEntities,toPorts' ]]
[[ "$(yq -r '.spec.ingress[1].fromEntities | sort | join(",")' "$cnp")" == 'host,remote-node' ]]
if yq -e '.spec.ingress[].fromEntities[]? | select(. == "world" or . == "cluster")' "$cnp" >/dev/null 2>&1; then
  echo 'Refusing: Plex policy must not admit ingress from world or cluster entities.' >&2
  exit 1
fi

# Egress is cluster DNS plus public-IPv4 TCP 443 only, with every non-global range
# excluded. No entity-based egress: world would include the NAS, gateway, and VLANs.
[[ "$(yq -r '.spec.egress | length' "$cnp")" == '2' ]]
[[ "$(yq -r '.spec.egress[0] | keys | sort | join(",")' "$cnp")" == 'toEndpoints,toPorts' ]]
[[ "$(yq -r '.spec.egress[0].toEndpoints | length' "$cnp")" == '1' ]]
[[ "$(yq -r '.spec.egress[0].toEndpoints[0].matchLabels | to_entries | map(.key + "=" + .value) | sort | join(",")' "$cnp")" == 'k8s:io.kubernetes.pod.namespace=kube-system,k8s:k8s-app=kube-dns' ]]
[[ "$(yq -r '[.spec.egress[0].toPorts[].ports[] | .port + "/" + .protocol] | sort | join(",")' "$cnp")" == '53/TCP,53/UDP' ]]
[[ "$(yq -r '.spec.egress[1] | keys | sort | join(",")' "$cnp")" == 'toCIDRSet,toPorts' ]]
[[ "$(yq -r '.spec.egress[1].toCIDRSet | length' "$cnp")" == '1' ]]
[[ "$(yq -r '.spec.egress[1].toCIDRSet[0].cidr' "$cnp")" == '0.0.0.0/0' ]]
[[ "$(yq -r '.spec.egress[1].toCIDRSet[0].except | join(",")' "$cnp")" == '10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.0.0.0/24,192.0.2.0/24,192.168.0.0/16,198.18.0.0/15,198.51.100.0/24,203.0.113.0/24,224.0.0.0/4,240.0.0.0/4' ]]
[[ "$(yq -r '[.spec.egress[1].toPorts[].ports[] | .port + "/" + .protocol] | unique | join(",")' "$cnp")" == '443/TCP' ]]
if yq -e '.spec.egress[] | has("toEntities")' "$cnp" >/dev/null 2>&1; then
  echo 'Refusing: Plex policy must not use entity-based egress.' >&2
  exit 1
fi

chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"

kustomize build "$base/app" >/dev/null

helm template plex "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
yq -o=yaml 'select(.kind == "Deployment" and .metadata.name == "plex")' \
  "$temp_dir/render.yaml" >"$temp_dir/deployment.yaml"
rendered="$temp_dir/deployment.yaml"

[[ "$(yq -r '.metadata.name' "$rendered")" == 'plex' ]]
[[ "$(yq -r '.spec.strategy.type' "$rendered")" == 'Recreate' ]]
[[ "$(yq -r '.spec.replicas' "$rendered")" == '1' ]]
if rg -Fq 'relayHostKey' "$rendered"; then
  echo 'Refusing: rendered Plex Deployment must not define relayHostKey state.' >&2
  exit 1
fi
[[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$rendered")" == 'false' ]]
[[ "$(yq -r '.spec.template.spec.securityContext.seccompProfile.type' "$rendered")" == 'RuntimeDefault' ]]
[[ "$(yq -r '.spec.template.spec.initContainers[] | select(.name == "runtime-identity") | .securityContext.runAsUser' "$rendered")" == '568' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") | .volumeMounts[] | select(.mountPath == "/etc/passwd") | .subPath' "$rendered")" == 'passwd' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") | .volumeMounts[] | select(.mountPath == "/etc/passwd") | .readOnly' "$rendered")" == 'true' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") | .volumeMounts[] | select(.mountPath == "/Volumes/Prometheus") | .readOnly' "$rendered")" == 'true' ]]
[[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "runtime-identity") | has("emptyDir")' "$rendered")" == 'true' ]]

for container in runtime-identity app; do
  [[ "$(yq -r "(.spec.template.spec.initContainers[], .spec.template.spec.containers[]) | select(.name == \"$container\") | .image" "$rendered")" == "$image_repository:$image_tag@$image_digest" ]]
done

echo "Plex relay identity, deterministic image, private routing, network containment, and pinned render passed validation."
