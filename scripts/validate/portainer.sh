#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/monitoring/portainer'
app="$base/app"
ks="$base/ks.yaml"
hr="$app/helmrelease.yaml"
values="$app/values.yaml"
repo="$app/helmrepository.yaml"
route="$app/httproute.yaml"
ns="$app/namespace.yaml"
rbac="$app/rbac.yaml"
policy="$app/ciliumnetworkpolicy.yaml"
secret="$app/portainer-admin-password.sops.yaml"
rule="$app/prometheusrule.yaml"
verify_script='scripts/verify/portainer.sh'
temp_dir="$(mktemp -d /tmp/homelab-talos-portainer-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for file in \
  "$ks" "$hr" "$values" "$repo" "$route" "$ns" "$rbac" "$policy" "$secret" "$rule" \
  "$app/kustomization.yaml"; do
  [[ -f "$file" ]] || {
    echo "Missing Portainer source: $file" >&2
    exit 1
  }
done

[[ -x "$verify_script" ]]
rg -Fq "jsonpath='{.metadata.annotations.helm\\.sh/resource-policy}'" "$verify_script" || {
  echo 'Portainer live verification must escape the dotted PVC annotation key exactly once.' >&2
  exit 1
}
! rg -Fq "jsonpath='{.metadata.annotations.helm\\\\.sh/resource-policy}'" "$verify_script" || {
  echo 'Portainer live verification double-escapes the PVC annotation JSONPath.' >&2
  exit 1
}

rg -qx '  - ./portainer/ks.yaml' kubernetes/apps/monitoring/kustomization.yaml || {
  echo 'Refusing: ./portainer/ks.yaml is not wired into the monitoring root.' >&2
  exit 1
}

# Flux staging and dependency contract.
suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.spec.decryption.provider // "none"' "$ks")" == 'sops' ]]
[[ "$(yq -r '.spec.decryption.secretRef.name // "none"' "$ks")" == 'sops-age' ]]
dependencies="$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")"
[[ "$dependencies" == 'cilium,internal-gateway,kube-prometheus-stack,longhorn' ]] || {
  echo "Unexpected Portainer dependencies: $dependencies" >&2
  exit 1
}

# Namespace, repository, route, and activation-aware monitoring.
[[ "$(yq -r '.metadata.name' "$ns")" == 'portainer' ]]
[[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$ns")" == 'baseline' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]]
[[ "$(yq -r '.spec.url' "$repo")" == 'https://portainer.github.io/k8s/' ]]
[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'portainer.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.spec.parentRefs[0].sectionName' "$route")" == 'https' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$route")" == 'portainer' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == '9000' ]]
[[ "$(yq -r '.metadata.annotations."external-dns.k8s.io/audience"' "$route")" == 'internal' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$route")" == 'portainer' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.url"' "$route")" == 'https://portainer.lab.supermorphic.com' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.env"' "$route")" == '1' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.kubernetes"' "$route")" == 'true' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.key"' "$route")" == '{{HOMEPAGE_VAR_PORTAINER_API_KEY}}' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.fields" // "absent"' "$route")" == 'absent' ]] || {
  echo 'Portainer Homepage widget must use its default Kubernetes fields.' >&2
  exit 1
}
if [[ "$suspend_state" == 'false' ]]; then
  [[ "$(yq -r '[.config.endpoints[] | select(
    .name == "portainer" and
    .group == "Platform" and
    .url == "https://portainer.lab.supermorphic.com/" and
    .interval == "1m" and
    .conditions[0] == "[STATUS] == 200" and
    (.conditions | length) == 1
  )] | length' kubernetes/apps/monitoring/gatus/app/values.yaml)" == '1' ]] || {
    echo 'Active Portainer has no Gatus endpoint.' >&2
    exit 1
  }
else
  ! rg -q '^    - name: portainer$' kubernetes/apps/monitoring/gatus/app/values.yaml || {
    echo 'Suspended Portainer must not create a failing Gatus endpoint.' >&2
    exit 1
  }
fi

# Activation alert contract: black-box failure, missing telemetry, and database
# claim absence/unbound state must remain independently detectable.
rg -qx '  - ./prometheusrule.yaml' "$app/kustomization.yaml"
[[ "$(yq -r '.kind' "$rule")" == 'PrometheusRule' ]]
[[ "$(yq -r '.metadata.name' "$rule")" == 'portainer' ]]
[[ "$(yq -r '.metadata.namespace' "$rule")" == 'portainer' ]]
alerts="$(yq -r '[.spec.groups[].rules[].alert] | sort | join(",")' "$rule")"
[[ "$alerts" == 'PortainerDown,PortainerPersistentVolumeClaimNotBound,PortainerProbeMissing' ]] || {
  echo "Unexpected Portainer alert set: $alerts" >&2
  exit 1
}
[[ "$(yq -r '.spec.groups[].rules[] | select(.alert == "PortainerDown") | .expr' "$rule")" == \
  'gatus_results_endpoint_success{name="portainer", group="Platform"} == 0' ]]
[[ "$(yq -r '.spec.groups[].rules[] | select(.alert == "PortainerDown") | .for' "$rule")" == '5m' ]]
[[ "$(yq -r '.spec.groups[].rules[] | select(.alert == "PortainerDown") | .labels.severity' "$rule")" == 'critical' ]]
[[ "$(yq -r '.spec.groups[].rules[] | select(.alert == "PortainerProbeMissing") | .expr' "$rule")" == \
  'absent(gatus_results_endpoint_success{name="portainer", group="Platform"})' ]]
[[ "$(yq -r '.spec.groups[].rules[] | select(.alert == "PortainerProbeMissing") | .for' "$rule")" == '15m' ]]
[[ "$(yq -r '.spec.groups[].rules[] | select(.alert == "PortainerProbeMissing") | .labels.severity' "$rule")" == 'warning' ]]
pvc_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "PortainerPersistentVolumeClaimNotBound") | .expr' "$rule")"
rg -Fq 'absent(' <<<"$pvc_expr"
rg -q 'kube_persistentvolumeclaim_status_phase' <<<"$pvc_expr"
rg -q 'namespace="portainer"' <<<"$pvc_expr"
rg -q 'persistentvolumeclaim="portainer"' <<<"$pvc_expr"
rg -q 'phase="Bound"' <<<"$pvc_expr"
[[ "$(yq -r '.spec.groups[].rules[] | select(.alert == "PortainerPersistentVolumeClaimNotBound") | .for' "$rule")" == '5m' ]]
[[ "$(yq -r '.spec.groups[].rules[] | select(.alert == "PortainerPersistentVolumeClaimNotBound") | .labels.severity' "$rule")" == 'critical' ]]

# Pinned chart/value contract.
[[ "$(yq -r '.spec.chart.spec.chart' "$hr")" == 'portainer' ]]
[[ "$(yq -r '.spec.chart.spec.version' "$hr")" == '239.5.0' ]]
[[ "$(yq -r '.image.repository' "$values")" == 'portainer/portainer-ce' ]]
[[ "$(yq -r '.image.tag' "$values")" == '2.39.5' ]]
[[ "$(yq -r '.image.pullPolicy' "$values")" == 'IfNotPresent' ]]
[[ "$(yq -r '.enterpriseEdition.enabled' "$values")" == 'false' ]]
[[ "$(yq -r '.localMgmt' "$values")" == 'false' ]]
[[ "$(yq -r '.createNamespace' "$values")" == 'false' ]]
[[ "$(yq -r '.serviceAccount.name' "$values")" == 'portainer-readonly' ]]
[[ "$(yq -r '.service.type' "$values")" == 'ClusterIP' ]]
[[ "$(yq -r '.ingress.enabled' "$values")" == 'false' ]]
[[ "$(yq -r '.trusted_origins.enabled' "$values")" == 'true' ]]
[[ "$(yq -r '.trusted_origins.domains' "$values")" == 'portainer.lab.supermorphic.com' ]]
[[ "$(yq -r '.adminPassword.existingSecret' "$values")" == 'portainer-admin-password' ]]
[[ "$(yq -r '.dbEncryption.existingSecret' "$values")" == '' ]]
[[ "$(yq -r '.extraEnv | length' "$values")" == '0' ]]
[[ "$(yq -r '.persistence.enabled' "$values")" == 'true' ]]
[[ "$(yq -r '.persistence.size' "$values")" == '5Gi' ]]
[[ "$(yq -r '.persistence.storageClass' "$values")" == 'longhorn' ]]
[[ "$(yq -r '.persistence.accessMode' "$values")" == 'ReadWriteOnce' ]]
[[ "$(yq -r '.persistence.annotations."helm.sh/resource-policy"' "$values")" == 'keep' ]]

# SOPS Secret metadata and ciphertext shape. Never decrypt or print its value.
[[ "$(yq -r '.metadata.name' "$secret")" == 'portainer-admin-password' ]]
[[ "$(yq -r '.metadata.namespace' "$secret")" == 'portainer' ]]
[[ "$(yq -r '.type' "$secret")" == 'Opaque' ]]
[[ "$(yq -r '.stringData.password // "none"' "$secret")" != 'none' ]]
[[ "$(yq -r '.sops // "none"' "$secret")" != 'none' ]] || {
  echo 'portainer-admin-password.sops.yaml is not SOPS-encrypted.' >&2
  exit 1
}

# Read-only RBAC invariants.
[[ "$(yq -r 'select(.kind == "ServiceAccount") | .metadata.name' "$rbac")" == 'portainer-readonly' ]]
[[ "$(yq -r 'select(.kind == "ClusterRoleBinding") | .roleRef.name' "$rbac")" == 'portainer-readonly' ]]
[[ "$(yq -r 'select(.kind == "ClusterRoleBinding") | .subjects[0].name' "$rbac")" == 'portainer-readonly' ]]
role_verbs="$(yq -r 'select(.kind == "ClusterRole" and .metadata.name == "portainer-readonly") | .rules[].verbs[]' "$rbac" | sort -u | paste -sd, -)"
[[ "$role_verbs" == 'get,list,watch' ]] || {
  echo "Portainer ClusterRole has unexpected verbs: $role_verbs" >&2
  exit 1
}
! yq -r 'select(.kind == "ClusterRole") | .rules[] | (.apiGroups[]), (.resources[]), (.verbs[])' "$rbac" | rg -qx '\*' || {
  echo 'Portainer ClusterRole must not contain wildcards.' >&2
  exit 1
}
! yq -r 'select(.kind == "ClusterRole") | .rules[].resources[]' "$rbac" |
  rg -qx '(secrets|pods/(exec|attach|portforward))' || {
    echo 'Portainer ClusterRole exposes Secrets or an interactive pod subresource.' >&2
    exit 1
  }

# Cilium Phase-1 isolation: Gateway/health ingress plus API/DNS egress only.
[[ "$(yq -r '.spec.endpointSelector.matchLabels."app.kubernetes.io/name"' "$policy")" == 'portainer' ]]
[[ "$(yq -r '[.spec.ingress[].toPorts[].ports[].port] | sort | join(",")' "$policy")" == '9000,9443' ]]
[[ "$(yq -r '.spec.egress[0].toEntities[0]' "$policy")" == 'kube-apiserver' ]]
[[ "$(yq -r '[.spec.egress[].toPorts[]?.ports[]?.port] | unique | join(",")' "$policy")" == '53' ]]
! rg -q '(9001|AGENT_SECRET)' "$policy" "$values" || {
  echo 'Pi Agent connectivity and AGENT_SECRET must remain deferred in Phase 1.' >&2
  exit 1
}

# Render the exact upstream chart, then apply the same post-render patches Flux uses.
kustomize build "$app" >"$temp_dir/source.yaml"
printf 'apiVersion: v1\ngenerated: null\nrepositories: []\n' >"$temp_dir/repositories.yaml"
HELM_REPOSITORY_CONFIG="$temp_dir/repositories.yaml" \
HELM_REPOSITORY_CACHE="$temp_dir/cache" \
HELM_CONTENT_CACHE="$temp_dir/content" \
  helm template portainer portainer \
    --repo https://portainer.github.io/k8s/ \
    --version 239.5.0 \
    --namespace portainer \
    --values "$values" >"$temp_dir/raw-render.yaml"

! yq ea -r 'select(.kind == "Namespace") | .metadata.name' "$temp_dir/raw-render.yaml" | rg -q . || {
  echo 'Pinned Portainer chart unexpectedly renders a Namespace.' >&2
  exit 1
}
! yq ea -r 'select(.kind == "ClusterRoleBinding") | .roleRef.name' "$temp_dir/raw-render.yaml" | rg -q . || {
  echo 'Pinned Portainer chart unexpectedly renders a ClusterRoleBinding.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "portainer") | .spec.strategy.type' "$temp_dir/raw-render.yaml")" == 'Recreate' ]]
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "portainer") | .spec.template.spec.serviceAccountName // "none"' "$temp_dir/raw-render.yaml")" == 'none' ]]
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "portainer") | .spec.template.spec.containers[0].image' "$temp_dir/raw-render.yaml")" == 'portainer/portainer-ce:2.39.5' ]]
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "portainer") | .spec.template.spec.containers[0].args[]' "$temp_dir/raw-render.yaml" | paste -sd, -)" == '--admin-password-file=/run/portainer/admin-password,--trusted-origins=portainer.lab.supermorphic.com' ]]
[[ "$(yq ea -r 'select(.kind == "Service" and .metadata.name == "portainer") | [.spec.ports[].port] | sort | join(",")' "$temp_dir/raw-render.yaml")" == '8000,9000,9443' ]]
[[ "$(yq ea -r 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "portainer") | .spec.accessModes[0]' "$temp_dir/raw-render.yaml")" == 'ReadWriteOnce' ]]
[[ "$(yq ea -r 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "portainer") | .spec.storageClassName' "$temp_dir/raw-render.yaml")" == 'longhorn' ]]
[[ "$(yq ea -r 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "portainer") | .metadata.annotations."helm.sh/resource-policy"' "$temp_dir/raw-render.yaml")" == 'keep' ]]

mkdir "$temp_dir/post-render"
cp "$temp_dir/raw-render.yaml" "$temp_dir/post-render/render.yaml"
deployment_patch="$(yq -r '.spec.postRenderers[0].kustomize.patches[] | select(.target.kind == "Deployment") | .patch' "$hr")"
service_patch="$(yq -r '.spec.postRenderers[0].kustomize.patches[] | select(.target.kind == "Service") | .patch' "$hr")"
export deployment_patch service_patch
yq -n \
  '.apiVersion = "kustomize.config.k8s.io/v1beta1" |
   .kind = "Kustomization" |
   .resources = ["render.yaml"] |
   .patches = [
     {
       "target": {"group": "apps", "version": "v1", "kind": "Deployment", "name": "portainer"},
       "patch": strenv(deployment_patch)
     },
     {
       "target": {"version": "v1", "kind": "Service", "name": "portainer"},
       "patch": strenv(service_patch)
     }
   ]' >"$temp_dir/post-render/kustomization.yaml"
kustomize build "$temp_dir/post-render" >"$temp_dir/final-render.yaml"

[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "portainer") | .spec.template.spec.serviceAccountName' "$temp_dir/final-render.yaml")" == 'portainer-readonly' ]]
[[ "$(yq ea -r 'select(.kind == "Service" and .metadata.name == "portainer") | [.spec.ports[].port] | join(",")' "$temp_dir/final-render.yaml")" == '9000' ]]

echo 'Portainer CE 2.39.5/chart 239.5.0 source, SOPS bootstrap Secret, read-only RBAC, Cilium isolation, internal route, retained RWO PVC, activation monitoring, Homepage widget, and final post-render passed validation.'
