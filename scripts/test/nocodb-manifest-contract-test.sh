#!/usr/bin/env bash
set -euo pipefail

source_render="${1:?usage: nocodb-manifest-contract-test.sh SOURCE_RENDER HELM_RENDER}"
helm_render="${2:?usage: nocodb-manifest-contract-test.sh SOURCE_RENDER HELM_RENDER}"

fail() {
  echo "NocoDB manifest contract failed: $*" >&2
  exit 1
}

deployment_count="$(yq ea -r 'select(.kind == "Deployment") | .metadata.name' "$helm_render" | wc -l | tr -d ' ')"
[[ "$deployment_count" == '1' ]] || fail 'expected exactly one rendered Deployment'
[[ "$(yq ea -r 'select(.kind == "Deployment") | .metadata.name' "$helm_render")" == 'nocodb' ]] ||
  fail 'the rendered Deployment must be named nocodb'
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "nocodb") | .spec.replicas' "$helm_render")" == '1' ]] ||
  fail 'NocoDB must render exactly one replica'
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "nocodb") | .spec.strategy.type' "$helm_render")" == 'Recreate' ]] ||
  fail 'the RWO NocoDB Deployment must use Recreate'
! yq ea -r 'select(.kind == "Deployment") | .metadata.name' "$helm_render" | rg -q 'worker' ||
  fail 'a NocoDB worker Deployment must not render'
! rg -q 'NC_REDIS_URL|redis' "$helm_render" || fail 'Redis configuration must not render'
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "nocodb") | .spec.template.spec.containers[] | select(.name == "nocodb") | .image' "$helm_render")" == \
  'docker.io/nocodb/nocodb@sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9' ]] ||
  fail 'the NocoDB image digest is not selected'
[[ "$(yq ea -r 'select(.kind == "Service" and .metadata.name == "nocodb") | [.spec.type, .spec.ports[0].port] | join(",")' "$helm_render")" == 'ClusterIP,8080' ]] ||
  fail 'the rendered NocoDB Service must expose only ClusterIP TCP/8080'
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "nocodb") | .spec.template.spec.volumes[] | select(.persistentVolumeClaim.claimName == "nocodb-data") | .persistentVolumeClaim.claimName' "$helm_render")" == 'nocodb-data' ]] ||
  fail 'the NocoDB Deployment must mount only the existing nocodb-data claim'
! yq ea -r 'select(.kind == "ServiceMonitor") | .metadata.name' "$source_render" | rg -q . ||
  fail 'NocoDB must not create a ServiceMonitor'
! rg -q 'NC_INVITE_ONLY_SIGNUP|career' "$source_render" "$helm_render" ||
  fail 'unsupported signup configuration or a career artifact is present'
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "nocodb") | .spec.template.metadata.labels."app.kubernetes.io/name"' "$helm_render")" == 'nocodb' ]] ||
  fail 'the NocoDB pod labels are not compatible with namespace-wide Alloy collection'
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "nocodb") | .spec.template.metadata.annotations."observability.supermorphic.com/logs" // "enabled"' "$helm_render")" != 'disabled' ]] ||
  fail 'the NocoDB pod must remain in namespace-wide Alloy log collection'

[[ "$(yq ea -r 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "nocodb-data") | [.spec.resources.requests.storage, .spec.accessModes[0], .spec.storageClassName, .metadata.annotations."kustomize.toolkit.fluxcd.io/prune"] | join(",")' "$source_render")" == '10Gi,ReadWriteOnce,longhorn,disabled' ]] ||
  fail 'the retained 10Gi Longhorn RWO attachment PVC is incorrect'
[[ "$(yq ea -r 'select(.kind == "HTTPRoute" and .metadata.name == "nocodb") | [.spec.hostnames[0], .spec.parentRefs[0].namespace, .spec.parentRefs[0].name, .spec.parentRefs[0].sectionName, .spec.rules[0].matches[0].path.value, .spec.rules[0].backendRefs[0].name, .spec.rules[0].backendRefs[0].port] | join(",")' "$source_render")" == 'nocodb.lab.supermorphic.com,networking,internal,https,/,nocodb,8080' ]] ||
  fail 'the private NocoDB route is incorrect'
[[ "$(yq ea -r 'select(.kind == "HTTPRoute" and .metadata.name == "nocodb") | .metadata.annotations."external-dns.k8s.io/audience"' "$source_render")" == 'internal' ]] ||
  fail 'the NocoDB route must be internal DNS only'

[[ "$(yq ea -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "nocodb") | .spec.endpointSelector.matchLabels."app.kubernetes.io/name"' "$source_render")" == 'nocodb' ]] ||
  fail 'the NocoDB policy selector is incorrect'
[[ "$(yq ea -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "nocodb") | [.spec.ingress[].toPorts[].ports[].port] | sort | join(",")' "$source_render")" == '8080,8080,8080' ]] ||
  fail 'the NocoDB policy ingress port contract is incorrect'
[[ "$(yq ea -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "nocodb") | [.spec.ingress[].fromEndpoints[] | [.matchLabels."k8s:io.kubernetes.pod.namespace", .matchLabels."app.kubernetes.io/name", .matchLabels."gateway.envoyproxy.io/owning-gateway-name"] | join("/")] | sort | join(",")' "$source_render")" == 'automation/n8n,envoy-gateway-system/internal' ]] ||
  fail 'the NocoDB policy must allow only internal Gateway and n8n workload ingress'
[[ "$(yq ea -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "nocodb") | [.spec.ingress[].fromEntities[]?] | sort | join(",")' "$source_render")" == 'host,remote-node' ]] ||
  fail 'the NocoDB policy must allow host and remote-node probes only'
[[ "$(yq ea -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "nocodb") | [.spec.egress[].toPorts[].ports[] | [.port, .protocol] | join("/")] | sort | join(",")' "$source_render")" == '53/TCP,53/UDP,5432/TCP' ]] ||
  fail 'the NocoDB policy egress port contract is incorrect'
[[ "$(yq ea -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "nocodb-metadata-bootstrap") | [.spec.egress[].toPorts[].ports[] | [.port, .protocol] | join("/")] | sort | join(",")' "$source_render")" == '53/TCP,53/UDP,5432/TCP' ]] ||
  fail 'the metadata bootstrap policy must allow only DNS and PostgreSQL'
[[ "$(yq ea -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "nocodb") | [.spec.egress[].toEndpoints[].matchLabels | (."k8s:k8s-app" // ."app.kubernetes.io/name")] | join(",")' "$source_render")" == 'kube-dns,automation-data-postgresql' ]] ||
  fail 'the NocoDB policy must target only cluster DNS and automation-data PostgreSQL'

[[ "$(yq ea -r 'select(.kind == "Job" and .metadata.name == "nocodb-metadata-bootstrap") | .spec.template.spec.automountServiceAccountToken' "$source_render")" == 'false' ]] ||
  fail 'the metadata bootstrap Job must not mount a service-account token'
[[ "$(yq ea -r 'select(.kind == "Job" and .metadata.name == "nocodb-metadata-bootstrap") | .spec.template.spec.containers[0].image' "$source_render")" == 'postgres:17.11-alpine3.24' ]] ||
  fail 'the metadata bootstrap Job image is incorrect'
job_command="$(yq ea -r 'select(.kind == "Job" and .metadata.name == "nocodb-metadata-bootstrap") | .spec.template.spec.containers[0].args[]' "$source_render")"
[[ "$job_command" == *"SELECT platform_operations.provision_nocodb_metadata(:'metadata_password');"* ]] ||
  fail 'the metadata bootstrap Job query is not fixed'
! rg -q 'provision_nocodb_metadata[^(:]|CREATE .*SHARE|public share' "$source_render" ||
  fail 'the package contains an unsupported metadata query or public-share creation'
[[ "$(yq ea -r 'select(.kind == "Job" and .metadata.name == "nocodb-metadata-bootstrap") | [.spec.template.spec.volumes[].name] | join(",")' "$source_render")" == 'tmp' ]] ||
  fail 'the metadata bootstrap Job must mount only temporary writable storage'
[[ "$(yq ea -r 'select(.kind == "Job" and .metadata.name == "nocodb-metadata-bootstrap") | [.spec.template.spec.securityContext.runAsNonRoot, .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation, .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem] | join(",")' "$source_render")" == 'true,false,true' ]] ||
  fail 'the metadata bootstrap Job must use the established non-root client security context'
! yq ea -r 'select(.kind == "Job" and .metadata.name == "nocodb-metadata-bootstrap") | .spec.template.spec.containers[0].args[]' "$source_render" | rg -q 'metadata-password|provisioner-password' ||
  fail 'the metadata bootstrap Job must not expose a Secret key in its arguments'
! grep -Eq 'echo|set -x' <<<"$job_command" ||
  fail 'the metadata bootstrap Job must not print secret-bearing client input'

values='kubernetes/apps/automation-data/nocodb/app/values.yaml'
[[ "$(yq -r '[.replicaCount, .updateStrategy.type, .worker.enabled, .autoscaling.enabled] | join(",")' "$values")" == '1,Recreate,false,false' ]] ||
  fail 'the NocoDB one-pod Recreate values are incorrect'
[[ "$(yq -r '[.image.registry, .image.repository, .image.tag, .image.digest] | join(",")' "$values")" == 'docker.io,nocodb/nocodb,2026.08.2,sha256:4b760f0d25471fb49707d515f161d9d36b49c88e7ecbe25eded774af385be5a9' ]] ||
  fail 'the NocoDB image value pin is incorrect'
[[ "$(yq -r '[.externalDatabase.existingSecret, .externalDatabase.existingSecretUrlKey, .auth.existingSecret, .persistence.existingClaim, .service.type, .service.port, .nocodb.publicUrl] | join(",")' "$values")" == 'nocodb-credentials,DATABASE_URL,nocodb-credentials,nocodb-data,ClusterIP,8080,https://nocodb.lab.supermorphic.com' ]] ||
  fail 'the NocoDB database, auth, persistence, service, or URL values are incorrect'
[[ "$(yq -r '[.nocodb.disableMux, .nocodb.disableTelemetry] | join(",")' "$values")" == 'true,true' ]] ||
  fail 'the NocoDB privacy values are incorrect'
[[ "$(yq -r '[.nocodb.extraEnvVars[] | [.name, (.value // .valueFrom.secretKeyRef.name), (.valueFrom.secretKeyRef.key // "")] | join("/")] | sort | join(",")' "$values")" == 'NC_ADMIN_EMAIL/nocodb-credentials/NC_ADMIN_EMAIL,NC_ADMIN_PASSWORD/nocodb-credentials/NC_ADMIN_PASSWORD,NC_ALLOW_LOCAL_EXTERNAL_DBS/true/,NC_DISABLE_SUPPORT_CHAT/true/' ]] ||
  fail 'the NocoDB explicit environment contract is incorrect'
! rg -q 'envFrom|NC_INVITE_ONLY_SIGNUP|NC_REDIS_URL' "$values" ||
  fail 'NocoDB values must not bulk-load credentials or configure unsupported settings'
[[ "$(yq -r '[.resources[]] | sort | join(",")' kubernetes/apps/automation-data/nocodb/app/kustomization.yaml)" == './ciliumnetworkpolicy.yaml,./helmrelease.yaml,./httproute.yaml,./metadata-bootstrap-job.yaml,./ocirepository.yaml,./persistentvolumeclaim.yaml' ]] ||
  fail 'the NocoDB app kustomization resource set is incorrect'

ks='kubernetes/apps/automation-data/nocodb/ks.yaml'
[[ "$(yq -r '[.spec.path, .spec.suspend, .spec.wait, .spec.decryption.provider, .spec.decryption.secretRef.name] | join(",")' "$ks")" == './kubernetes/apps/automation-data/nocodb/app,true,true,sops,sops-age' ]] ||
  fail 'the staged NocoDB Flux Kustomization contract is incorrect'
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'automation-data,automation-data-postgresql,cilium,internal-gateway,longhorn' ]] ||
  fail 'the staged NocoDB Flux dependencies are incorrect'
[[ "$(yq -r '[.spec.url, .spec.ref.digest] | join(",")' kubernetes/apps/automation-data/nocodb/app/ocirepository.yaml)" == 'oci://ghcr.io/nocodb/charts/nocodb,sha256:b2aa331863ec002e5001db33c2ac257bc0f1df690396c340e3e38e6978fece6c' ]] ||
  fail 'the NocoDB OCI chart digest pin is incorrect'
[[ "$(yq -r '[.spec.chartRef.kind, .spec.chartRef.name, .spec.releaseName, .spec.valuesFrom[0].name, .spec.valuesFrom[0].valuesKey] | join(",")' kubernetes/apps/automation-data/nocodb/app/helmrelease.yaml)" == 'OCIRepository,nocodb-chart,nocodb,nocodb-values,values.yaml' ]] ||
  fail 'the NocoDB HelmRelease source contract is incorrect'

postgresql_policy='kubernetes/apps/automation-data/postgresql/app/ciliumnetworkpolicy.yaml'
[[ "$(yq ea -r 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "automation-data-postgresql") | [.spec.ingress[].fromEndpoints[] | select(.matchLabels."k8s:io.kubernetes.pod.namespace" == "automation-data") | .matchLabels."app.kubernetes.io/name"] | sort | join(",")' "$postgresql_policy")" == 'automation-data-postgresql-backup,nocodb,nocodb-metadata-bootstrap' ]] ||
  fail 'the PostgreSQL policy must admit the NocoDB application and metadata bootstrap Job'
[[ "$(yq -r '[.spec.egress[] | select(.toEndpoints[].matchLabels."app.kubernetes.io/name" == "nocodb") | [.toEndpoints[].matchLabels."k8s:io.kubernetes.pod.namespace", .toEndpoints[].matchLabels."app.kubernetes.io/name", .toPorts[].ports[].port] | join(",")] | join(",")' kubernetes/apps/automation/n8n/app/ciliumnetworkpolicy.yaml)" == 'automation-data,nocodb,8080' ]] ||
  fail 'the n8n policy must add only the NocoDB TCP/8080 egress destination'

echo 'NocoDB rendered manifest contract passed.'
