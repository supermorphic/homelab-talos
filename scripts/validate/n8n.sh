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

echo 'n8n namespace, public edge, suspended PostgreSQL, retained storage, logical backup, SQL metrics, monitoring, and containment source passed validation.'
