#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/automation'
ns="$base/namespace/app/namespace.yaml"
public_base='kubernetes/apps/networking/public-webhook-gateway'
public_namespace="$public_base/app/namespace.yaml"
public_pool="$public_base/app/address-pool.yaml"
public_certificate="$public_base/app/certificate.yaml"
public_gateway="$public_base/app/gateway.yaml"
public_route="$public_base/route/httproute.yaml"
public_ks="$public_base/ks.yaml"
external_dns='kubernetes/apps/networking/external-dns/app/values.yaml'
postgresql_base="$base/n8n-postgresql"
postgresql_app="$postgresql_base/app"
postgresql_ks="$postgresql_base/ks.yaml"
postgresql_kustomization="$postgresql_app/kustomization.yaml"
postgresql_pvcs="$postgresql_app/persistentvolumeclaims.yaml"
postgresql_service="$postgresql_app/service.yaml"
postgresql_statefulset="$postgresql_app/statefulset.yaml"
postgresql_cronjob="$postgresql_app/cronjob.yaml"
postgresql_monitor="$postgresql_app/servicemonitor.yaml"
postgresql_policy="$postgresql_app/ciliumnetworkpolicy.yaml"
postgresql_init="$postgresql_app/scripts/init-database.sh"
postgresql_backup="$postgresql_app/scripts/backup.sh"
postgresql_status_sql="$postgresql_app/scripts/update-backup-status.sql"
postgresql_exporter="$postgresql_app/sql-exporter.yml"
n8n_base="$base/n8n"
n8n_app="$n8n_base/app"
n8n_ks="$n8n_base/ks.yaml"
n8n_kustomization="$n8n_app/kustomization.yaml"
n8n_source="$n8n_app/ocirepository.yaml"
n8n_release="$n8n_app/helmrelease.yaml"
n8n_values="$n8n_app/values.yaml"
n8n_pvc="$n8n_app/persistentvolumeclaim.yaml"
n8n_route="$n8n_app/httproute.yaml"
n8n_grant="$n8n_app/referencegrant.yaml"
n8n_monitor="$n8n_app/servicemonitor.yaml"
n8n_policy="$n8n_app/ciliumnetworkpolicy.yaml"
n8n_workflow="$n8n_app/workflows/platform-canary.json"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-validate.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

normalise_resource_path() {
  local path="$1"
  while [[ "$path" == ./* ]]; do
    path="${path#./}"
  done
  printf '%s\n' "$path"
}

validate_selected_sops_secret() {
  local owner="$1" resource="$2" target="$3" expected_name="$4"
  local expected_namespace="$5" expected_keys="$6" expected_recipient selected_resource
  local normalised_resource normalised_selected_resource selected=false
  local -a expected_recipients candidate_recipients

  [[ -f "$owner" ]] || return 0
  normalised_resource="$(normalise_resource_path "$resource")"
  while IFS= read -r selected_resource; do
    normalised_selected_resource="$(normalise_resource_path "$selected_resource")"
    [[ "$normalised_selected_resource" != "$normalised_resource" ]] || selected=true
  done < <(yq -r '.resources[]?' "$owner")
  [[ "$selected" == true ]] || return 0
  [[ -f "$target" ]] || {
    echo "Missing selected n8n SOPS Secret: $target." >&2
    exit 1
  }
  # shellcheck disable=SC2016 # yq reads target through its env() function.
  mapfile -t expected_recipients < <(
    target="$target" yq -r \
      '.creation_rules[] | select(.path_regex as $rule | env(target) | test($rule)) | .age' \
      .sops.yaml
  )
  [[ "${#expected_recipients[@]}" -eq 1 && -n "${expected_recipients[0]}" && \
    "${expected_recipients[0]}" != 'null' ]] || {
    echo "Unable to select exactly one SOPS age recipient for $target." >&2
    exit 1
  }
  expected_recipient="${expected_recipients[0]}"
  [[ "$(sops filestatus "$target" | yq -r '.encrypted')" == 'true' ]] || {
    echo "Selected n8n SOPS Secret is not encrypted: $target." >&2
    exit 1
  }
  mapfile -t candidate_recipients < <(yq -r '.sops.age[].recipient' "$target" | sort -u)
  [[ "${#candidate_recipients[@]}" -eq 1 && \
    "${candidate_recipients[0]}" == "$expected_recipient" ]] || {
    echo "Selected n8n SOPS Secret has an unexpected age recipient: $target." >&2
    exit 1
  }
  [[ "$(yq -r 'has("data") | not' "$target")" == 'true' ]] || {
    echo "Selected n8n SOPS Secret must not contain data: $target." >&2
    exit 1
  }
  [[ "$(yq -r 'keys | sort | join(",")' "$target")" == \
    'apiVersion,kind,metadata,sops,stringData,type' ]] || {
    echo "Selected n8n SOPS Secret has an unexpected top-level schema: $target." >&2
    exit 1
  }
  [[ "$(yq -r '.metadata | keys | sort | join(",")' "$target")" == 'name,namespace' && \
    "$(yq -r '.apiVersion' "$target")" == 'v1' && \
    "$(yq -r '.kind' "$target")" == 'Secret' && \
    "$(yq -r '.metadata.name' "$target")" == "$expected_name" && \
    "$(yq -r '.metadata.namespace' "$target")" == "$expected_namespace" && \
    "$(yq -r '.type' "$target")" == 'Opaque' ]] || {
    echo "Selected n8n SOPS Secret has an unexpected Secret contract: $target." >&2
    exit 1
  }
  [[ "$(yq -r '.stringData | keys | sort | join(",")' "$target")" == "$expected_keys" ]] || {
    echo "Selected n8n SOPS Secret has an unexpected key set: $target." >&2
    exit 1
  }
}

validate_postgresql_metrics_ingress() {
  local manifest="$1" metrics_identity
  metrics_identity="$(yq ea -r '
    select(.kind == "CiliumNetworkPolicy" and .metadata.name == "n8n-postgresql") |
    .spec.ingress[] |
    select(.toPorts[].ports[].port == "9399") |
    .fromEndpoints[].matchLabels |
    to_entries | sort_by(.key) | map(.key + "=" + .value) | join(",")
  ' "$manifest")"
  [[ "$metrics_identity" == \
    'app.kubernetes.io/name=prometheus,k8s:io.kubernetes.pod.namespace=monitoring,operator.prometheus.io/name=kube-prometheus-stack-prometheus' ]] || {
    echo 'PostgreSQL metrics ingress must select only the pinned Prometheus workload identity.' >&2
    exit 1
  }
}

for file in "$base/kustomization.yaml" "$base/namespace/ks.yaml" \
  "$base/namespace/app/kustomization.yaml" "$ns"; do
  [[ -f "$file" ]] || { echo "Missing n8n platform source: $file" >&2; exit 1; }
done
for file in "$public_namespace" "$public_pool" "$public_certificate" "$public_gateway" \
  "$public_route" "$public_ks" "$public_base/app/kustomization.yaml" \
  "$public_base/route/kustomization.yaml" "$external_dns"; do
  [[ -f "$file" ]] || { echo "Missing n8n platform source: $file" >&2; exit 1; }
done
for file in "$postgresql_ks" "$postgresql_kustomization" "$postgresql_pvcs" \
  "$postgresql_service" "$postgresql_statefulset" "$postgresql_cronjob" \
  "$postgresql_monitor" "$postgresql_policy" "$postgresql_init" \
  "$postgresql_backup" "$postgresql_status_sql" "$postgresql_exporter"; do
  [[ -f "$file" ]] || { echo "Missing n8n PostgreSQL source: $file" >&2; exit 1; }
done
for file in "$n8n_ks" "$n8n_kustomization" "$n8n_source" "$n8n_release" \
  "$n8n_values" "$n8n_pvc" "$n8n_route" "$n8n_grant" "$n8n_monitor" \
  "$n8n_policy"; do
  [[ -f "$file" ]] || { echo "Missing n8n chart source: $file" >&2; exit 1; }
done
[[ -f "$n8n_workflow" ]] || {
  echo "Missing n8n Platform Canary workflow template: $n8n_workflow" >&2
  exit 1
}
yq -e '.resources[] | select(. == "./automation")' kubernetes/apps/kustomization.yaml >/dev/null
yq -e '.resources[] | select(. == "./public-webhook-gateway/ks.yaml")' \
  kubernetes/apps/networking/kustomization.yaml >/dev/null
[[ "$(yq -r '.metadata.name' "$ns")" == 'automation' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]] || {
  echo 'n8n automation namespace Gateway access must be internal.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$ns")" == 'restricted' ]]
[[ "$(yq -r '.spec.dependsOn[0].name' "$base/namespace/ks.yaml")" == 'cilium' ]]
kustomize build "$base/namespace/app" >/dev/null

validate_selected_sops_secret \
  "$base/n8n/app/kustomization.yaml" './n8n-runtime.sops.yaml' \
  "$base/n8n/app/n8n-runtime.sops.yaml" n8n-runtime automation \
  'N8N_ENCRYPTION_KEY,N8N_HOST,N8N_PORT,N8N_PROTOCOL'
validate_selected_sops_secret \
  "$base/n8n-postgresql/app/kustomization.yaml" './postgresql-credentials.sops.yaml' \
  "$base/n8n-postgresql/app/postgresql-credentials.sops.yaml" postgresql-credentials automation \
  'backup-password,exporter-dsn,exporter-password,n8n-password,postgres-superuser-password'
validate_selected_sops_secret \
  'kubernetes/apps/monitoring/gatus/app/kustomization.yaml' './n8n-canary.sops.yaml' \
  'kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml' n8n-canary gatus token

yq -e '(.metadata.name == "networking-public") and
  (.metadata.labels | length == 1) and
  (.metadata.labels."gateway.supermorphic.com/access" == "public")' "$public_namespace" >/dev/null || {
  echo 'networking-public must have only the public Gateway access label.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks")] | length' "$public_pool")" == '1' && \
  "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks") | .spec.addresses | length' "$public_pool")" == '1' && \
  "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks") | .spec.addresses[0]' "$public_pool")" == '192.168.90.39/32' && \
  "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks") | .spec.autoAssign' "$public_pool")" == 'false' ]] || {
  echo 'public-webhooks must contain only 192.168.90.39/32 with autoAssign=false.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$public_certificate")" == 'hooks-lab-supermorphic-com' && \
  "$(yq -r '.spec.dnsNames | length' "$public_certificate")" == '1' && \
  "$(yq -r '.spec.dnsNames[0]' "$public_certificate")" == 'hooks.lab.supermorphic.com' && \
  "$(yq -r '.spec.issuerRef.name' "$public_certificate")" == 'letsencrypt-production' && \
  "$(yq -r '.spec.privateKey.algorithm' "$public_certificate")" == 'ECDSA' ]] || {
  echo 'The public Certificate must contain only hooks.lab.supermorphic.com.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "GatewayClass" and .metadata.name == "public-webhooks")] | length' "$public_gateway")" == '1' && \
  "$(yq ea -r 'select(.kind == "GatewayClass" and .metadata.name == "public-webhooks") | .spec.controllerName' "$public_gateway")" == 'gateway.envoyproxy.io/gatewayclass-controller' ]] || {
  echo 'The public GatewayClass must use the Envoy Gateway controller.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks")] | length' "$public_gateway")" == '1' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.gatewayClassName' "$public_gateway")" == 'public-webhooks' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.listeners | length' "$public_gateway")" == '1' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.listeners[0].hostname' "$public_gateway")" == 'hooks.lab.supermorphic.com' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.listeners[0].allowedRoutes.namespaces.from' "$public_gateway")" == 'Same' ]] || {
  echo 'The public listener must use its exact hostname and Same-namespace route admission.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.metadata.name == "public-webhook-route") | [.spec.dependsOn[].name] | sort | join(",")' "$public_ks")" == 'n8n,public-webhook-gateway' && \
  "$(yq ea -r 'select(.metadata.name == "public-webhook-route") | .spec.suspend' "$public_ks")" == 'true' ]] || {
  echo 'The public webhook route must depend on public-webhook-gateway and n8n while suspended.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.namespace' "$public_route")" == 'networking-public' && \
  "$(yq -r '.spec.parentRefs | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.parentRefs[0] | [.namespace, .name, .sectionName] | join(",")' "$public_route")" == 'networking-public,public-webhooks,https' && \
  "$(yq -r '.spec.rules | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.rules[0].matches | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.rules[0].matches[0].path | [.type, .value] | join(",")' "$public_route")" == 'Exact,/webhook/platform-canary' && \
  "$(yq -r '.spec.rules[0].backendRefs | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.rules[0].backendRefs[0] | [.kind, .namespace, .name, .port] | join(",")' "$public_route")" == 'Service,automation,n8n,5678' ]] || {
  echo 'The public webhook route must be the exact platform-canary path to automation/n8n:5678.' >&2
  exit 1
}
[[ "$(yq -r '.annotationFilter' "$external_dns")" == 'external-dns.k8s.io/audience=internal' ]] || {
  echo 'The internal ExternalDNS controller must not publish the public webhook name.' >&2
  exit 1
}

yq -e '.resources[] | select(. == "./n8n-postgresql/ks.yaml")' \
  "$base/kustomization.yaml" >/dev/null || {
  echo 'The automation root must select n8n-postgresql/ks.yaml.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$postgresql_ks")" == 'n8n-postgresql' && \
  "$(yq -r '.metadata.namespace' "$postgresql_ks")" == 'flux-system' && \
  "$(yq -r '.spec.path' "$postgresql_ks")" == './kubernetes/apps/automation/n8n-postgresql/app' && \
  "$(yq -r '.spec.suspend' "$postgresql_ks")" == 'true' && \
  "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$postgresql_ks")" == \
    'automation,cilium,kube-prometheus-stack,longhorn' ]] || {
  echo 'n8n-postgresql must remain suspended with its complete foundation dependency graph.' >&2
  exit 1
}
declare -A postgresql_resource_counts=()
while IFS= read -r resource; do
  resource="$(normalise_resource_path "$resource")"
  case "$resource" in
    ciliumnetworkpolicy.yaml | cronjob.yaml | persistentvolumeclaims.yaml | service.yaml | \
      servicemonitor.yaml | statefulset.yaml | postgresql-credentials.sops.yaml)
      postgresql_resource_counts["$resource"]=$((
        ${postgresql_resource_counts["$resource"]:-0} + 1
      ))
      ;;
    *)
      echo "The PostgreSQL app Kustomization selects an unexpected resource: $resource" >&2
      exit 1
      ;;
  esac
done < <(yq -r '.resources[]' "$postgresql_kustomization")
for resource in ciliumnetworkpolicy.yaml cronjob.yaml persistentvolumeclaims.yaml \
  service.yaml servicemonitor.yaml statefulset.yaml; do
  [[ "${postgresql_resource_counts["$resource"]:-0}" == '1' ]] || {
    echo "The PostgreSQL app must select $resource exactly once." >&2
    exit 1
  }
done
[[ "${postgresql_resource_counts[postgresql-credentials.sops.yaml]:-0}" -le 1 ]] || {
  echo 'The PostgreSQL app must not select its credential Secret more than once.' >&2
  exit 1
}
[[ "$(yq -r '[.configMapGenerator[].name] | sort | join(",")' \
  "$postgresql_kustomization")" == \
  'n8n-postgresql-backup,n8n-postgresql-init,n8n-postgresql-sql-exporter' ]] || {
  echo 'The PostgreSQL app must render init, backup, and SQL Exporter ConfigMaps.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .metadata.name] | sort | join(",")' \
  "$postgresql_pvcs")" == 'n8n-postgresql-backups,n8n-postgresql-data' && \
  "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .spec.resources.requests.storage] | unique | join(",")' \
  "$postgresql_pvcs")" == '10Gi' && \
  "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .spec.accessModes[]] | unique | join(",")' \
  "$postgresql_pvcs")" == 'ReadWriteOnce' && \
  "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .spec.storageClassName] | unique | join(",")' \
  "$postgresql_pvcs")" == 'longhorn' && \
  "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .metadata.annotations."kustomize.toolkit.fluxcd.io/prune"] | unique | join(",")' \
  "$postgresql_pvcs")" == 'disabled' ]] || {
  echo 'PostgreSQL data and backup claims must be retained 10Gi Longhorn RWO claims.' >&2
  exit 1
}

[[ "$(yq -r '.spec.type' "$postgresql_service")" == 'ClusterIP' && \
  "$(yq -r '[.spec.ports[] | .name + ":" + (.port | tostring)] | sort | join(",")' \
  "$postgresql_service")" == 'metrics:9399,postgresql:5432' ]] || {
  echo 'PostgreSQL must expose only its internal database and exporter Service ports.' >&2
  exit 1
}

[[ "$(yq -r '.spec.replicas' "$postgresql_statefulset")" == '1' && \
  "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$postgresql_statefulset")" == 'false' && \
  "$(yq -r '.spec.template.spec.securityContext.seccompProfile.type' "$postgresql_statefulset")" == 'RuntimeDefault' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .image' \
  "$postgresql_statefulset")" == 'postgres:17.11-alpine3.24' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | .image' \
  "$postgresql_statefulset")" == 'burningalchemist/sql_exporter:0.24.6' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .securityContext.runAsUser' \
  "$postgresql_statefulset")" == '70' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .securityContext.runAsGroup' \
  "$postgresql_statefulset")" == '70' && \
  "$(yq -r '[.spec.template.spec.containers[].securityContext.capabilities.drop[]] | unique | join(",")' \
  "$postgresql_statefulset")" == 'ALL' ]] || {
  echo 'The PostgreSQL pod must use one hardened replica with the exact database and exporter images.' >&2
  exit 1
}
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .env[] | select(.name == "PGDATA") | .value' \
  "$postgresql_statefulset")" == '/var/lib/postgresql/data/pgdata' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | [.startupProbe.exec.command[0], .readinessProbe.exec.command[0], .livenessProbe.exec.command[0]] | unique | join(",")' \
  "$postgresql_statefulset")" == 'pg_isready' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .volumeMounts[] | select(.mountPath == "/docker-entrypoint-initdb.d") | .readOnly' \
  "$postgresql_statefulset")" == 'true' && \
  "$(yq -r '.spec.template.spec.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName' \
  "$postgresql_statefulset")" == 'n8n-postgresql-data' ]] || {
  echo 'The PostgreSQL container must mount retained data and read-only initialization with exec probes.' >&2
  exit 1
}
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | [.resources.requests.cpu, .resources.requests.memory, .resources.limits.memory] | join(",")' \
  "$postgresql_statefulset")" == '50m,256Mi,1Gi' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .resources.limits | has("cpu") | not' \
  "$postgresql_statefulset")" == 'true' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | [.resources.requests.cpu, .resources.requests.memory, .resources.limits.memory] | join(",")' \
  "$postgresql_statefulset")" == '10m,32Mi,128Mi' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | .resources.limits | has("cpu") | not' \
  "$postgresql_statefulset")" == 'true' ]] || {
  echo 'PostgreSQL and SQL Exporter resource envelopes do not match the capacity design.' >&2
  exit 1
}
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | .securityContext.runAsNonRoot' \
  "$postgresql_statefulset")" == 'true' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | [.env[] | select(has("valueFrom")) | .valueFrom.secretKeyRef.key] | join(",")' \
  "$postgresql_statefulset")" == 'exporter-dsn' ]] || {
  echo 'SQL Exporter must run non-root and consume only exporter-dsn.' >&2
  exit 1
}

[[ "$(yq -r '.spec.schedule' "$postgresql_cronjob")" == '0 1 * * *' && \
  "$(yq -r '.spec.timeZone' "$postgresql_cronjob")" == 'Etc/UTC' && \
  "$(yq -r '.spec.concurrencyPolicy' "$postgresql_cronjob")" == 'Forbid' && \
  "$(yq -r '.spec.successfulJobsHistoryLimit' "$postgresql_cronjob")" == '1' && \
  "$(yq -r '.spec.failedJobsHistoryLimit' "$postgresql_cronjob")" == '1' && \
  "$(yq -r '.spec.jobTemplate.spec.activeDeadlineSeconds' "$postgresql_cronjob")" == '1800' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .image' \
  "$postgresql_cronjob")" == 'postgres:17.11-alpine3.24' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | [.resources.requests.cpu, .resources.requests.memory, .resources.limits.memory] | join(",")' \
  "$postgresql_cronjob")" == '50m,64Mi,512Mi' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .resources.limits | has("cpu") | not' \
  "$postgresql_cronjob")" == 'true' ]] || {
  echo 'The logical backup CronJob schedule, history, deadline, image, or resources are incorrect.' >&2
  exit 1
}
[[ "$(yq -r '.spec.jobTemplate.spec.template.metadata.labels."app.kubernetes.io/name"' \
  "$postgresql_cronjob")" == 'n8n-postgresql-backup' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.securityContext | [.runAsUser, .runAsGroup] | join(",")' \
  "$postgresql_cronjob")" == '70,70' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.securityContext.seccompProfile.type' \
  "$postgresql_cronjob")" == 'RuntimeDefault' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .securityContext.capabilities.drop | join(",")' \
  "$postgresql_cronjob")" == 'ALL' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .securityContext.readOnlyRootFilesystem' \
  "$postgresql_cronjob")" == 'true' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | [.env[] | select(has("valueFrom")) | .valueFrom.secretKeyRef.key] | join(",")' \
  "$postgresql_cronjob")" == 'backup-password' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .volumeMounts[] | select(.mountPath == "/scripts/update-backup-status.sql") | .readOnly' \
  "$postgresql_cronjob")" == 'true' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "backups") | .persistentVolumeClaim.claimName' \
  "$postgresql_cronjob")" == 'n8n-postgresql-backups' ]] || {
  echo 'The backup Job identity, least-privileged credential, scripts, or retained claim are incorrect.' >&2
  exit 1
}

[[ "$(yq -r '.spec.selector.matchLabels."app.kubernetes.io/name"' "$postgresql_monitor")" == \
  'n8n-postgresql' && \
  "$(yq -r '[.spec.endpoints[] | .port + ":" + .path] | join(",")' \
  "$postgresql_monitor")" == 'metrics:/metrics' ]] || {
  echo 'The PostgreSQL ServiceMonitor must scrape only the named metrics port.' >&2
  exit 1
}
validate_postgresql_metrics_ingress "$postgresql_policy"
[[ "$(yq ea -r 'select(.metadata.name == "n8n-postgresql") | [.spec.ingress[].toPorts[].ports[].port] | sort | join(",")' \
  "$postgresql_policy")" == '5432,9399' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql") | [.spec.ingress[] | select(.toPorts[].ports[].port == "5432") | .fromEndpoints[].matchLabels."app.kubernetes.io/name"] | sort | join(",")' \
  "$postgresql_policy")" == 'n8n,n8n-postgresql-backup' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql") | [.spec.ingress[].fromEndpoints[].matchLabels."k8s:io.kubernetes.pod.namespace"] | sort | join(",")' \
  "$postgresql_policy")" == 'automation,automation,monitoring' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql") | .spec.egress | length' \
  "$postgresql_policy")" == '0' ]] || {
  echo 'PostgreSQL ingress identities or no-egress containment are incorrect.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.metadata.name == "n8n-postgresql-backup") | [.spec.egress[].toPorts[].ports[].port] | sort | join(",")' \
  "$postgresql_policy")" == '53,53,5432' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql-backup") | [.spec.egress[].toEndpoints[].matchLabels."app.kubernetes.io/name"] | map(select(. != null)) | join(",")' \
  "$postgresql_policy")" == 'n8n-postgresql' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql-backup") | [.spec.egress[].toEndpoints[] | select(.matchLabels."app.kubernetes.io/name" == "n8n-postgresql") | .matchLabels."k8s:io.kubernetes.pod.namespace"] | join(",")' \
  "$postgresql_policy")" == 'automation' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql-backup") | [.spec.egress[].toEndpoints[].matchLabels."k8s:k8s-app"] | map(select(. != null)) | join(",")' \
  "$postgresql_policy")" == 'kube-dns' ]] || {
  echo 'The backup Job must reach only cluster DNS and PostgreSQL.' >&2
  exit 1
}

[[ "$(yq -r '[.collectors[].metrics[].metric_name] | sort | join(",")' \
  "$postgresql_exporter")" == \
  'n8n_postgresql_backup_last_success_timestamp_seconds,n8n_postgresql_connections,n8n_postgresql_database_size_bytes,n8n_postgresql_transactions_total' && \
  "$(yq -r '.collectors[].metrics[] | select(.metric_name == "n8n_postgresql_connections") | .key_labels | join(",")' \
  "$postgresql_exporter")" == 'state' && \
  "$(yq -r '.collectors[].metrics[] | select(.metric_name == "n8n_postgresql_transactions_total") | .key_labels | join(",")' \
  "$postgresql_exporter")" == 'result' ]] || {
  echo 'SQL Exporter must define the four n8n PostgreSQL metric families.' >&2
  exit 1
}

sh -n "$postgresql_init" "$postgresql_backup"
shellcheck "$postgresql_init" "$postgresql_backup"
kustomize build "$postgresql_app" >"$temp_dir/postgresql.yaml"
yq ea 'del(.sops)' "$temp_dir/postgresql.yaml" >"$temp_dir/postgresql-conform.yaml"
kubeconform -strict -summary -ignore-missing-schemas "$temp_dir/postgresql-conform.yaml"
validate_postgresql_metrics_ingress "$temp_dir/postgresql.yaml"
yq ea -r 'select(.kind == "ConfigMap" and has("data") and .data."init-database.sh" != null) | .data."init-database.sh"' \
  "$temp_dir/postgresql.yaml" >"$temp_dir/init-database.sh"
yq ea -r 'select(.kind == "ConfigMap" and has("data") and .data."backup.sh" != null) | .data."backup.sh"' \
  "$temp_dir/postgresql.yaml" >"$temp_dir/backup.sh"
yq ea -r 'select(.kind == "ConfigMap" and has("data") and .data."update-backup-status.sql" != null) | .data."update-backup-status.sql"' \
  "$temp_dir/postgresql.yaml" >"$temp_dir/update-backup-status.sql"
yq ea -r 'select(.kind == "ConfigMap" and has("data") and .data."sql-exporter.yml" != null) | .data."sql-exporter.yml"' \
  "$temp_dir/postgresql.yaml" >"$temp_dir/sql-exporter.yml"
[[ -s "$temp_dir/init-database.sh" && -s "$temp_dir/backup.sh" && \
  -s "$temp_dir/update-backup-status.sql" && -s "$temp_dir/sql-exporter.yml" ]] || {
  echo 'The rendered PostgreSQL ConfigMaps must contain every runtime script and collector.' >&2
  exit 1
}
[[ "$(yq -r '[.collectors[].metrics[].metric_name] | sort | join(",")' \
  "$temp_dir/sql-exporter.yml")" == \
  'n8n_postgresql_backup_last_success_timestamp_seconds,n8n_postgresql_connections,n8n_postgresql_database_size_bytes,n8n_postgresql_transactions_total' ]]
rg -q '^CREATE ROLE n8n ' "$temp_dir/init-database.sh"
rg -q '^CREATE ROLE n8n_backup ' "$temp_dir/init-database.sh"
rg -q '^CREATE ROLE n8n_exporter ' "$temp_dir/init-database.sh"
rg -q '^GRANT pg_read_all_data TO n8n_backup;' "$temp_dir/init-database.sh"
rg -q '^GRANT pg_monitor TO n8n_exporter;' "$temp_dir/init-database.sh"
rg -q '^GRANT SELECT, INSERT, UPDATE ON platform_operations.logical_backup_status TO n8n_backup;' \
  "$temp_dir/init-database.sh"
rg -q '^GRANT SELECT ON platform_operations.logical_backup_status TO n8n_exporter;' \
  "$temp_dir/init-database.sh"
! rg -q -- '--set=.*PASSWORD' "$temp_dir/init-database.sh" || {
  echo 'Database initialization must not place role passwords in process arguments.' >&2
  exit 1
}
rg -q '^INSERT INTO platform_operations.logical_backup_status' "$temp_dir/update-backup-status.sql"
rg -q '^ON CONFLICT ' "$temp_dir/update-backup-status.sql"
rg -q '^DO UPDATE SET' "$temp_dir/update-backup-status.sql"
rg -Fq ":'completed_at'::timestamp with time zone" "$temp_dir/update-backup-status.sql"
rg -Fq ":'filename'::text" "$temp_dir/update-backup-status.sql"
rg -Fq ":'checksum'::character(64)" "$temp_dir/update-backup-status.sql"

previous_line=0
# shellcheck disable=SC2016 # These are literal markers from the rendered script.
for marker in \
  'pg_dump --format=custom --compress=9 --no-owner --no-privileges' \
  'pg_restore --file /dev/null "$temporary_dump"' \
  'checksum="$(sha256sum "$temporary_dump" | awk' \
  'printf '\''%s  %s\n'\'' "$checksum" "$(basename "$final_dump")"' \
  'mv -- "$temporary_dump" "$final_dump"' \
  'mv -- "$temporary_checksum" "$final_checksum"' \
  '(cd "$backup_dir" && sha256sum --check "$(basename "$final_checksum")")' \
  'psql --set=ON_ERROR_STOP=1 --set=completed_at="$completed_at"'; do
  marker_line="$(rg -n -m 1 -F -- "$marker" "$temp_dir/backup.sh" | cut -d: -f1)"
  [[ -n "$marker_line" && "$marker_line" -gt "$previous_line" ]] || {
    echo "Rendered backup order is missing or incorrect at: $marker" >&2
    exit 1
  }
  previous_line="$marker_line"
done
cleanup_line="$(rg -n -m 1 -F -- 'find "$backup_dir"' "$temp_dir/backup.sh" | cut -d: -f1)"
[[ -n "$cleanup_line" && "$cleanup_line" -gt "$previous_line" ]] || {
  echo 'Backup cleanup must occur only after the status upsert.' >&2
  exit 1
}

[[ -z "$(yq ea -r 'select(.kind == "HTTPRoute") | .metadata.name' \
  "$temp_dir/postgresql.yaml")" ]] || {
  echo 'PostgreSQL must not render an HTTPRoute.' >&2
  exit 1
}
[[ -z "$(yq ea -r 'select(.kind == "Service" and (.spec.type == "NodePort" or .spec.type == "LoadBalancer")) | .metadata.name' \
  "$temp_dir/postgresql.yaml")" ]] || {
  echo 'PostgreSQL must not render an externally exposed Service.' >&2
  exit 1
}

yq -e '.resources[] | select(. == "./n8n/ks.yaml")' "$base/kustomization.yaml" >/dev/null || {
  echo 'The automation root must select n8n/ks.yaml.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$n8n_ks")" == 'n8n' && \
  "$(yq -r '.metadata.namespace' "$n8n_ks")" == 'flux-system' && \
  "$(yq -r '.spec.path' "$n8n_ks")" == './kubernetes/apps/automation/n8n/app' && \
  "$(yq -r '.spec.suspend' "$n8n_ks")" == 'true' && \
  "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$n8n_ks")" == \
    'automation,cilium,internal-gateway,kube-prometheus-stack,longhorn,n8n-postgresql,public-webhook-gateway' ]] || {
  echo 'n8n must remain suspended with its complete foundation dependency graph.' >&2
  exit 1
}

[[ "$(yq -r '.kind' "$n8n_source")" == 'OCIRepository' && \
  "$(yq -r '.metadata.name' "$n8n_source")" == 'n8n-chart' && \
  "$(yq -r '.metadata.namespace' "$n8n_source")" == 'automation' && \
  "$(yq -r '.spec.url' "$n8n_source")" == 'oci://ghcr.io/n8n-io/n8n-helm-chart/n8n' && \
  "$(yq -r '.spec.ref.digest' "$n8n_source")" == \
    'sha256:a0bf4694f6e0f91dfb196fd8de08ad40cb3dd798edaa9bd54fa9c3f32566517c' && \
  "$(yq -r '.spec.layerSelector | [.mediaType, .operation] | join(",")' "$n8n_source")" == \
    'application/vnd.cncf.helm.chart.content.v1.tar+gzip,copy' ]] || {
  echo 'n8n must use the immutable official chart 1.11.0 OCI artifact.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$n8n_release")" == 'n8n' && \
  "$(yq -r '.metadata.namespace' "$n8n_release")" == 'automation' && \
  "$(yq -r '.spec.chartRef | [.kind, .name] | join(",")' "$n8n_release")" == \
    'OCIRepository,n8n-chart' && \
  "$(yq -r '.spec.releaseName' "$n8n_release")" == 'n8n' && \
  "$(yq -r '.spec.valuesFrom | length' "$n8n_release")" == '1' && \
  "$(yq -r '.spec.valuesFrom[0] | [.kind, .name, .valuesKey] | join(",")' "$n8n_release")" == \
    'ConfigMap,n8n-values,values.yaml' ]] || {
  echo 'The n8n HelmRelease must consume only the watched n8n-values ConfigMap.' >&2
  exit 1
}
expected_postrender_contract='[{"target":{"group":"apps","version":"v1","kind":"Deployment","name":"n8n-main"},"patch":[{"op":"replace","path":"/metadata/name","value":"n8n"}]},{"target":{"group":"","version":"v1","kind":"Service","name":"n8n-main"},"patch":[{"op":"replace","path":"/metadata/name","value":"n8n"}]}]'
actual_postrender_contract="$(yq -o=json -I=0 '
  [.spec.postRenderers[0].kustomize.patches[] | {
    "target": {
      "group": .target.group,
      "version": .target.version,
      "kind": .target.kind,
      "name": .target.name
    },
    "patch": (.patch | from_yaml)
  }] | sort_by(.target.kind)
' "$n8n_release")"
[[ "$(yq -r '.spec.postRenderers | length' "$n8n_release")" == '1' && \
  "$(yq -r '.spec.postRenderers[0] | keys | sort | join(",")' "$n8n_release")" == \
    'kustomize' && \
  "$(yq -r '.spec.postRenderers[0].kustomize | keys | sort | join(",")' \
    "$n8n_release")" == 'patches' && \
  "$(yq -r '[.spec.postRenderers[0].kustomize.patches[].target |
    keys | sort | join(",")] | sort | join(";")' "$n8n_release")" == \
    'group,kind,name,version;group,kind,name,version' && \
  "$actual_postrender_contract" == "$expected_postrender_contract" ]] || {
  echo 'The Helm post-renderer must expose the one main Deployment and Service as n8n.' >&2
  exit 1
}

declare -A n8n_resource_counts=()
while IFS= read -r resource; do
  resource="$(normalise_resource_path "$resource")"
  case "$resource" in
    ciliumnetworkpolicy.yaml | helmrelease.yaml | httproute.yaml | ocirepository.yaml | \
      persistentvolumeclaim.yaml | referencegrant.yaml | servicemonitor.yaml | n8n-runtime.sops.yaml)
      n8n_resource_counts["$resource"]=$((
        ${n8n_resource_counts["$resource"]:-0} + 1
      ))
      ;;
    *)
      echo "The n8n app Kustomization selects an unexpected resource: $resource" >&2
      exit 1
      ;;
  esac
done < <(yq -r '.resources[]' "$n8n_kustomization")
for resource in ciliumnetworkpolicy.yaml helmrelease.yaml httproute.yaml ocirepository.yaml \
  persistentvolumeclaim.yaml referencegrant.yaml servicemonitor.yaml; do
  [[ "${n8n_resource_counts["$resource"]:-0}" == '1' ]] || {
    echo "The n8n app must select $resource exactly once." >&2
    exit 1
  }
done
expected_n8n_configmaps='[{"files":["values.yaml=values.yaml"],"name":"n8n-values"},{"files":["platform-canary.json=workflows/platform-canary.json"],"name":"n8n-workflow-templates"}]'
actual_n8n_configmaps="$(yq -o=json -I=0 '
  [.configMapGenerator[] | {"files": .files, "name": .name}] | sort_by(.name)
' "$n8n_kustomization")"
[[ "${n8n_resource_counts[n8n-runtime.sops.yaml]:-0}" -le 1 && \
  "$actual_n8n_configmaps" == "$expected_n8n_configmaps" && \
  "$(yq -r '.generatorOptions.disableNameSuffixHash' "$n8n_kustomization")" == 'true' ]] || {
  echo 'The n8n app must package the stable values and inactive Platform Canary template ConfigMaps.' >&2
  exit 1
}

jq -e . "$n8n_workflow" >/dev/null || {
  echo 'Platform Canary must be valid importable workflow JSON.' >&2
  exit 1
}
jq -e '
  .name == "Platform Canary" and
  .active == false and
  (.nodes | type == "array" and length == 2) and
  ([.nodes[] | .type] | sort) == ["n8n-nodes-base.set", "n8n-nodes-base.webhook"] and
  ([.nodes[] | select(
    .type == "n8n-nodes-base.webhook" and
    .name == "Webhook" and
    .parameters.responseMode == "lastNode" and
    .parameters.authentication == "headerAuth"
  )] | length) == 1 and
  ([.nodes[] | select(
    .type == "n8n-nodes-base.set" and .name == "Edit Fields"
  )] | length) == 1 and
  .connections == {
    "Webhook": {
      "main": [[{"node": "Edit Fields", "type": "main", "index": 0}]]
    }
  } and
  ([.. | objects | select(has("credentials"))] | length) == 0
' "$n8n_workflow" >/dev/null || {
  echo 'Platform Canary must be a secret-free inactive two-node Webhook and Edit Fields template.' >&2
  exit 1
}
# shellcheck disable=SC2016 # The expected n8n expressions are literal workflow JSON.
expected_canary_fields='[{"name":"correlation","type":"string","value":"={{ $json.body.correlation }}"},{"name":"executionId","type":"string","value":"={{ $execution.id }}"},{"name":"status","type":"string","value":"ok"}]'
actual_canary_fields="$(jq -c '
  [.nodes[] | select(.type == "n8n-nodes-base.set") |
    .parameters.assignments.assignments[] | {name, type, value}] | sort_by(.name)
' "$n8n_workflow")"
[[ "$actual_canary_fields" == "$expected_canary_fields" ]] || {
  echo 'Platform Canary must return only the required status, correlation, and executionId fields.' >&2
  exit 1
}
[[ "$(jq -r '[.settings.saveDataErrorExecution, .settings.saveDataSuccessExecution] | join(",")' \
  "$n8n_workflow")" == 'all,all' ]] || {
  echo 'Platform Canary must save successful and failed executions.' >&2
  exit 1
}
workflow_path="$(jq -r '.nodes[] | select(.type == "n8n-nodes-base.webhook") | .parameters.path' \
  "$n8n_workflow")"
mapfile -t public_webhook_matches < <(
  find kubernetes/apps -type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -print0 |
    xargs -0 yq ea -r '
      select(type == "!!map") |
      select(.kind == "HTTPRoute") |
      select(.spec.parentRefs[]? | .name == "public-webhooks") |
      .spec.rules[]?.matches[]?.path? | [.type, .value] | join(",")
    '
)
[[ "${#public_webhook_matches[@]}" == '1' && \
  "${public_webhook_matches[0]}" == 'Exact,/webhook/platform-canary' ]] || {
  echo 'The only public production webhook path under kubernetes/apps must be /webhook/platform-canary.' >&2
  exit 1
}
[[ "$(yq -r '.spec.rules[0].matches[0].path.value' "$public_route")" == \
  "/webhook/$workflow_path" ]] || {
  echo 'The public route and Platform Canary Webhook must use the same production path.' >&2
  exit 1
}

[[ "$(yq -r '.metadata.name' "$n8n_pvc")" == 'n8n-data' && \
  "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' "$n8n_pvc")" == \
    'disabled' && \
  "$(yq -r '.spec.accessModes | join(",")' "$n8n_pvc")" == 'ReadWriteOnce' && \
  "$(yq -r '.spec.resources.requests.storage' "$n8n_pvc")" == '5Gi' && \
  "$(yq -r '.spec.storageClassName' "$n8n_pvc")" == 'longhorn' ]] || {
  echo 'n8n-data must be a retained 5Gi Longhorn RWO claim.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.annotations."external-dns.k8s.io/audience"' "$n8n_route")" == \
    'internal' && \
  "$(yq -r '.spec.hostnames | join(",")' "$n8n_route")" == 'n8n.lab.supermorphic.com' && \
  "$(yq -r '.spec.parentRefs | length' "$n8n_route")" == '1' && \
  "$(yq -r '.spec.parentRefs[0] | [.namespace, .name, .sectionName] | join(",")' "$n8n_route")" == \
    'networking,internal,https' && \
  "$(yq -r '.spec.rules | length' "$n8n_route")" == '1' && \
  "$(yq -r '.spec.rules[0].backendRefs | length' "$n8n_route")" == '1' && \
  "$(yq -r '.spec.rules[0].backendRefs[0] | [.kind, .name, .port] | join(",")' "$n8n_route")" == \
    'Service,n8n,5678' ]] || {
  echo 'The private n8n route must attach only to networking/internal and target n8n:5678.' >&2
  exit 1
}
[[ "$(yq -r '.spec.from | length' "$n8n_grant")" == '1' && \
  "$(yq -r '.spec.from[0] | [.group, .kind, .namespace] | join(",")' "$n8n_grant")" == \
    'gateway.networking.k8s.io,HTTPRoute,networking-public' && \
  "$(yq -r '.spec.to | length' "$n8n_grant")" == '1' && \
  "$(yq -r '.spec.to[0] | [.group, .kind, .name] | join(",")' "$n8n_grant")" == \
    ',Service,n8n' ]] || {
  echo 'The ReferenceGrant must admit only networking-public HTTPRoutes to Service n8n.' >&2
  exit 1
}
[[ "$(yq -r '.spec.selector.matchLabels."app.kubernetes.io/name"' "$n8n_monitor")" == \
    'n8n' && \
  "$(yq -r '[.spec.endpoints[] | .port + ":" + .path] | join(",")' "$n8n_monitor")" == \
    'http:/metrics' ]] || {
  echo 'The n8n ServiceMonitor must scrape only /metrics on the named HTTP port.' >&2
  exit 1
}

expected_n8n_ingress='[{"fromEndpoints":["app.kubernetes.io/name=prometheus,k8s:io.kubernetes.pod.namespace=monitoring,operator.prometheus.io/name=kube-prometheus-stack-prometheus"],"fromEntities":[],"toPorts":["5678/TCP"]},{"fromEndpoints":["gateway.envoyproxy.io/owning-gateway-name=internal,gateway.envoyproxy.io/owning-gateway-namespace=networking,k8s:io.kubernetes.pod.namespace=envoy-gateway-system","gateway.envoyproxy.io/owning-gateway-name=public-webhooks,gateway.envoyproxy.io/owning-gateway-namespace=networking-public,k8s:io.kubernetes.pod.namespace=envoy-gateway-system"],"fromEntities":[],"toPorts":["5678/TCP"]},{"fromEndpoints":[],"fromEntities":["host","remote-node"],"toPorts":["5678/TCP"]}]'
actual_n8n_ingress="$(yq -o=json -I=0 '
  [.spec.ingress[] | {
    "fromEndpoints": ([.fromEndpoints[]?.matchLabels |
      to_entries | sort_by(.key) | map(.key + "=" + .value) | join(",")] | sort),
    "fromEntities": ((.fromEntities // []) | sort),
    "toPorts": ([.toPorts[]?.ports[] | .port + "/" + .protocol] | sort)
  }] | sort_by((.fromEndpoints + .fromEntities + .toPorts) | join("|"))
' "$n8n_policy")"
[[ "$(yq -r '.spec | keys | sort | join(",")' "$n8n_policy")" == \
    'egress,endpointSelector,ingress' && \
  "$(yq -o=json -I=0 '.spec.endpointSelector' "$n8n_policy")" == \
    '{"matchLabels":{"app.kubernetes.io/name":"n8n"}}' && \
  "$(yq -r '[.spec.ingress[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == \
    'fromEndpoints,toPorts;fromEndpoints,toPorts;fromEntities,toPorts' && \
  "$(yq -r '[.spec.ingress[].fromEndpoints[]? | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'matchLabels;matchLabels;matchLabels' && \
  "$(yq -r '[.spec.ingress[].toPorts[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'ports;ports;ports' && \
  "$(yq -r '[.spec.ingress[].toPorts[].ports[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'port,protocol;port,protocol;port,protocol' && \
  "$actual_n8n_ingress" == "$expected_n8n_ingress" ]] || {
  echo 'n8n ingress must admit only both Envoy data planes, Prometheus, and kubelet probes.' >&2
  exit 1
}
expected_n8n_egress='[{"toEndpoints":[],"toCIDRSet":["0.0.0.0/0 except=0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.0.0.0/24,192.0.2.0/24,192.168.0.0/16,192.88.99.0/24,198.18.0.0/15,198.51.100.0/24,203.0.113.0/24,224.0.0.0/4,240.0.0.0/4"],"toPorts":["443/TCP"]},{"toEndpoints":["app.kubernetes.io/name=n8n-postgresql,k8s:io.kubernetes.pod.namespace=automation"],"toCIDRSet":[],"toPorts":["5432/TCP"]},{"toEndpoints":["k8s:io.kubernetes.pod.namespace=kube-system,k8s:k8s-app=kube-dns"],"toCIDRSet":[],"toPorts":["53/TCP","53/UDP"]}]'
actual_n8n_egress="$(yq -o=json -I=0 '
  [.spec.egress[] | {
    "toEndpoints": ([.toEndpoints[]?.matchLabels |
      to_entries | sort_by(.key) | map(.key + "=" + .value) | join(",")] | sort),
    "toCIDRSet": ([.toCIDRSet[]? |
      .cidr + " except=" + ((.except // []) | sort | join(","))] | sort),
    "toPorts": ([.toPorts[]?.ports[] | .port + "/" + .protocol] | sort)
  }] | sort_by((.toEndpoints + .toCIDRSet + .toPorts) | join("|"))
' "$n8n_policy")"
[[ "$(yq -r '[.spec.egress[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == \
    'toCIDRSet,toPorts;toEndpoints,toPorts;toEndpoints,toPorts' && \
  "$(yq -r '[.spec.egress[].toEndpoints[]? | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'matchLabels;matchLabels' && \
  "$(yq -r '[.spec.egress[].toCIDRSet[]? | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'cidr,except' && \
  "$(yq -r '[.spec.egress[].toPorts[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'ports;ports;ports' && \
  "$(yq -r '[.spec.egress[].toPorts[].ports[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == \
    'port,protocol;port,protocol;port,protocol;port,protocol' && \
  "$actual_n8n_egress" == "$expected_n8n_egress" ]] || {
  echo 'n8n egress must reach only DNS, PostgreSQL, and public IPv4 HTTPS.' >&2
  exit 1
}

kustomize build "$n8n_app" >"$temp_dir/n8n-source.yaml"
yq ea 'del(.sops)' "$temp_dir/n8n-source.yaml" >"$temp_dir/n8n-source-conform.yaml"
kubeconform -strict -summary -ignore-missing-schemas "$temp_dir/n8n-source-conform.yaml"
chart_pull_output="$(helm pull "$(yq -r '.spec.url' "$n8n_source")" --version 1.11.0 \
  --destination "$temp_dir")"
rg -Fq 'Digest: sha256:a0bf4694f6e0f91dfb196fd8de08ad40cb3dd798edaa9bd54fa9c3f32566517c' \
  <<<"$chart_pull_output" || {
  echo 'The downloaded n8n chart does not match the pinned OCI digest.' >&2
  exit 1
}
helm template n8n "$temp_dir/n8n-1.11.0.tgz" --namespace automation \
  --values "$n8n_values" >"$temp_dir/n8n-chart.yaml"
# Apply the exact declared Flux post-render patches with Kustomize. A target that does
# not match the pinned chart remains unmodified and fails the rendered-name assertions.
mkdir -p "$temp_dir/n8n-postrender"
cp "$temp_dir/n8n-chart.yaml" "$temp_dir/n8n-postrender/resources.yaml"
n8n_release="$n8n_release" yq -n '
  .apiVersion = "kustomize.config.k8s.io/v1beta1" |
  .kind = "Kustomization" |
  .resources = ["./resources.yaml"] |
  .patches = load(strenv(n8n_release)).spec.postRenderers[0].kustomize.patches
' >"$temp_dir/n8n-postrender/kustomization.yaml"
kustomize build "$temp_dir/n8n-postrender" >"$temp_dir/n8n-rendered.yaml"
kubeconform -strict -summary -ignore-missing-schemas "$temp_dir/n8n-rendered.yaml"

[[ "$(yq ea -r '[select(.kind == "Deployment")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/n8n-rendered.yaml")" == \
    'n8n' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.replicas' "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/n8n-rendered.yaml")" == \
    'Recreate' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.containers | length' "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$temp_dir/n8n-rendered.yaml")" == \
    'docker.n8n.io/n8nio/n8n:2.36.7' ]] || {
  echo 'The n8n chart must render one exact-image Deployment replica with Recreate.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "Service")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r 'select(.kind == "Service") | [.metadata.name, .spec.type, .spec.ports[0].name, .spec.ports[0].port] | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    'n8n,ClusterIP,http,5678' && \
  "$(yq ea -r '[select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName] | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    'n8n-data' ]] || {
  echo 'The n8n chart must expose n8n:5678 and mount only the retained n8n-data claim.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources | [.requests.cpu, .requests.memory, .limits.memory] | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    '100m,256Mi,1Gi' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits | has("cpu") | not' "$temp_dir/n8n-rendered.yaml")" == \
    'true' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.automountServiceAccountToken' "$temp_dir/n8n-rendered.yaml")" == \
    'false' && \
  "$(yq ea -r '[select(.kind == "Role" or .kind == "RoleBinding" or .kind == "ServiceAccount")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '0' ]] || {
  echo 'The n8n pod must use the exact resource envelope without Kubernetes API credentials.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.kind == "Deployment") | [.spec.template.spec.containers[0].env[] | select(.name == "DB_POSTGRESDB_PASSWORD") | .valueFrom.secretKeyRef | [.name, .key] | join(",")] | join(";")' "$temp_dir/n8n-rendered.yaml")" == \
    'postgresql-credentials,n8n-password' && \
  "$(yq ea -r 'select(.kind == "ConfigMap") | [.data.DB_TYPE, .data.DB_POSTGRESDB_HOST, .data.DB_POSTGRESDB_PORT, .data.DB_POSTGRESDB_DATABASE, .data.DB_POSTGRESDB_USER] | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    'postgresdb,n8n-postgresql.automation.svc.cluster.local,5432,n8n,n8n' ]] || {
  echo 'The n8n chart must use only the dedicated external PostgreSQL database.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.kind == "Deployment") | [.spec.template.spec.containers[0].env[] | select(.valueFrom.secretKeyRef != null) | .name + "=" + .valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key] | sort | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    'DB_POSTGRESDB_PASSWORD=postgresql-credentials/n8n-password,N8N_ENCRYPTION_KEY=n8n-runtime/N8N_ENCRYPTION_KEY,N8N_HOST=n8n-runtime/N8N_HOST,N8N_PORT=n8n-runtime/N8N_PORT,N8N_PROTOCOL=n8n-runtime/N8N_PROTOCOL' ]] || {
  echo 'The n8n container must consume only the exact runtime and database Secret keys.' >&2
  exit 1
}
[[ -z "$(yq ea -r 'select(.kind == "ConfigMap") | .data | keys | .[] | select(test("REDIS|QUEUE"))' \
    "$temp_dir/n8n-rendered.yaml")" && \
  "$(yq ea -r '[select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" != "main")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '0' && \
  "$(yq ea -r '[select(.kind == "Secret" or .kind == "HorizontalPodAutoscaler" or .kind == "PodDisruptionBudget" or .kind == "Ingress" or .kind == "ScaledObject")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '0' ]] || {
  echo 'The n8n chart must not render queue, Redis, worker, webhook-processor, autoscaling, disruption-budget, or Ingress behavior.' >&2
  exit 1
}

n8n_env_query='select(.kind == "Deployment") | .spec.template.spec.containers[0].env'
[[ "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_WEBHOOK_URL\")] | length" "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_EDITOR_BASE_URL\")] | length" "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"WEBHOOK_URL\")] | length" "$temp_dir/n8n-rendered.yaml")" == \
    '0' && \
  "$(yq ea -r 'select(.kind == "ConfigMap") | .data | has("WEBHOOK_URL")' "$temp_dir/n8n-rendered.yaml")" == \
    'false' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_WEBHOOK_URL\") | .value, .[] | select(.name == \"N8N_EDITOR_BASE_URL\") | .value] | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'https://hooks.lab.supermorphic.com/,https://n8n.lab.supermorphic.com/' ]] || {
  echo 'The n8n container must have each canonical URL once and no deprecated WEBHOOK_URL.' >&2
  exit 1
}
[[ "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_PROXY_HOPS\") | .value, .[] | select(.name == \"N8N_METRICS\") | .value, .[] | select(.name == \"N8N_METRICS_INCLUDE_WORKFLOW_STATISTICS\") | .value, .[] | select(.name == \"N8N_METRICS_INCLUDE_DB_POOL_METRICS\") | .value] | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    '1,true,true,true' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_DIAGNOSTICS_ENABLED\" or .name == \"N8N_VERSION_NOTIFICATIONS_ENABLED\" or .name == \"N8N_PERSONALIZATION_ENABLED\") | .name + \"=\" + .value] | sort | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'N8N_DIAGNOSTICS_ENABLED=false,N8N_PERSONALIZATION_ENABLED=false,N8N_VERSION_NOTIFICATIONS_ENABLED=false' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_METRICS_INCLUDE_WORKFLOW_ID_LABEL\" or .name == \"N8N_METRICS_INCLUDE_NODE_TYPE_LABEL\" or .name == \"N8N_METRICS_INCLUDE_CREDENTIAL_TYPE_LABEL\") | .name + \"=\" + .value] | sort | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'N8N_METRICS_INCLUDE_CREDENTIAL_TYPE_LABEL=false,N8N_METRICS_INCLUDE_NODE_TYPE_LABEL=false,N8N_METRICS_INCLUDE_WORKFLOW_ID_LABEL=false' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_DEFAULT_BINARY_DATA_MODE\") | .value] | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'filesystem' ]] || {
  echo 'The n8n proxy, metrics, telemetry, and filesystem settings are incorrect.' >&2
  exit 1
}
[[ "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"EXECUTIONS_DATA_SAVE_ON_ERROR\") | .value, .[] | select(.name == \"EXECUTIONS_DATA_SAVE_ON_SUCCESS\") | .value, .[] | select(.name == \"EXECUTIONS_DATA_PRUNE\") | .value, .[] | select(.name == \"EXECUTIONS_DATA_MAX_AGE\") | .value, .[] | select(.name == \"EXECUTIONS_DATA_PRUNE_MAX_COUNT\") | .value] | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'all,all,true,336,10000' ]] || {
  echo 'n8n must save success and error executions and enforce both retention bounds.' >&2
  exit 1
}

echo 'n8n standalone external-PostgreSQL render, private route, retained storage, metrics, and containment passed validation.'
