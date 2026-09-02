#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
base="$repo_root/kubernetes/apps/automation-data"
namespace_app="$base/namespace/app"
postgresql_app="$base/postgresql/app"
postgresql_ks="$base/postgresql/ks.yaml"
control_sql="$postgresql_app/scripts/platform-control.sql"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-control-contract.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

fail() {
  echo "automation-data control contract failed: $*" >&2
  exit 1
}

for source in \
  "$base/kustomization.yaml" \
  "$namespace_app/kustomization.yaml" \
  "$postgresql_app/kustomization.yaml" \
  "$postgresql_ks" \
  "$control_sql"; do
  [[ -f "$source" ]] || fail "missing $source"
done

kustomize build "$namespace_app" >"$temp_dir/namespace.yaml"
kustomize build "$postgresql_app" >"$temp_dir/postgresql.yaml"

namespace_contract="$(yq ea -r '
  select(.kind == "Namespace" and .metadata.name == "automation-data") |
  [
    .metadata.labels."pod-security.kubernetes.io/audit",
    .metadata.labels."pod-security.kubernetes.io/enforce",
    .metadata.labels."pod-security.kubernetes.io/warn"
  ] | join(",")
' "$temp_dir/namespace.yaml")"
[[ "$namespace_contract" == 'restricted,restricted,restricted' ]] || \
  fail 'namespace does not enforce the restricted Pod Security profile'

pvc_contract="$(yq ea -r '
  [select(.kind == "PersistentVolumeClaim") | [
    .metadata.name,
    .metadata.annotations."kustomize.toolkit.fluxcd.io/prune",
    .spec.storageClassName,
    (.spec.accessModes | join("+")),
    .spec.resources.requests.storage
  ] | join("|")] | sort | .[]
' "$temp_dir/postgresql.yaml" | sed '/^$/d')"
[[ "$pvc_contract" == $'automation-data-postgresql-backups|disabled|longhorn|ReadWriteOnce|20Gi\nautomation-data-postgresql-data|disabled|longhorn|ReadWriteOnce|20Gi' ]] || \
  fail 'rendered retained claims do not match the two 20 GiB contracts'

statefulset_count="$(yq ea -r '[select(
  .kind == "StatefulSet" and .metadata.name == "automation-data-postgresql"
)] | length' "$temp_dir/postgresql.yaml")"
[[ "$statefulset_count" == 1 ]] || fail 'render must contain one PostgreSQL StatefulSet'

statefulset_contract="$(yq ea -r '
  select(.kind == "StatefulSet" and .metadata.name == "automation-data-postgresql") |
  [
    .spec.replicas,
    .spec.serviceName,
    .spec.template.spec.automountServiceAccountToken,
    .spec.template.spec.securityContext.fsGroup,
    .spec.template.spec.securityContext.seccompProfile.type,
    (.spec.template.spec.containers[] | select(.name == "postgresql") | .image),
    (.spec.template.spec.containers[] | select(.name == "postgresql") |
      .securityContext.runAsNonRoot),
    (.spec.template.spec.containers[] | select(.name == "postgresql") |
      .securityContext.readOnlyRootFilesystem),
    (.spec.template.spec.containers[] | select(.name == "postgresql") |
      .resources.requests.cpu),
    (.spec.template.spec.containers[] | select(.name == "postgresql") |
      .resources.requests.memory),
    (.spec.template.spec.containers[] | select(.name == "postgresql") |
      .resources.limits.memory)
  ] | join("|")
' "$temp_dir/postgresql.yaml")"
[[ "$statefulset_contract" == \
  '1|automation-data-postgresql|false|70|RuntimeDefault|postgres:17.11-alpine3.24|true|true|50m|256Mi|1Gi' ]] || \
  fail 'PostgreSQL StatefulSet identity, hardening, image, or resources drifted'

database_env="$(yq ea -r '
  select(.kind == "StatefulSet" and .metadata.name == "automation-data-postgresql") |
  .spec.template.spec.containers[] | select(.name == "postgresql") |
  [.env[] | [
    .name,
    (.value // .valueFrom.secretKeyRef.name // ""),
    (.valueFrom.secretKeyRef.key // "")
  ] | join("|")] | sort | .[]
' "$temp_dir/postgresql.yaml")"
[[ "$database_env" == $'BACKUP_PASSWORD|postgresql-credentials|backup-password\nEXPORTER_PASSWORD|postgresql-credentials|exporter-password\nPGDATA|/var/lib/postgresql/data/pgdata|\nPOSTGRES_DB|automation_data_control|\nPOSTGRES_INITDB_ARGS|--auth-host=scram-sha-256 --auth-local=trust|\nPOSTGRES_PASSWORD|postgresql-credentials|postgres-superuser-password\nPROVISIONER_PASSWORD|postgresql-credentials|provisioner-password' ]] || \
  fail 'PostgreSQL environment does not bind the exact platform bootstrap inputs'

service_contract="$(yq ea -r '
  select(.kind == "Service" and .metadata.name == "automation-data-postgresql") |
  [
    .spec.type,
    ([.spec.ports[] | select(
      .name == "postgresql" and .port == 5432 and .targetPort == "postgresql"
    )] | length),
    ([.spec.ports[] | select(.nodePort != null)] | length)
  ] | join("|")
' "$temp_dir/postgresql.yaml")"
[[ "$service_contract" == 'ClusterIP|1|0' ]] || \
  fail 'PostgreSQL Service is not private ClusterIP port 5432'

external_surface_count="$(yq ea -r '[select(
  .kind == "HTTPRoute" or .kind == "Gateway" or
  (.kind == "Service" and (.spec.type == "LoadBalancer" or .spec.type == "NodePort"))
)] | length' "$temp_dir/postgresql.yaml")"
[[ "$external_surface_count" == 0 ]] || fail 'platform render exposes an external surface'

secret_contract="$(yq ea -r '
  select(.kind == "Secret" and .metadata.name == "postgresql-credentials") |
  [
    .metadata.namespace,
    (.stringData | keys | sort | join(",")),
    (has("data") | not)
  ] | join("|")
' "$temp_dir/postgresql.yaml")"
[[ "$secret_contract" == \
  'automation-data|backup-password,exporter-dsn,exporter-password,postgres-superuser-password,provisioner-password|true' ]] || \
  fail 'selected encrypted Secret has an unexpected rendered contract'

init_config_contract="$(yq ea -r '
  select(.kind == "ConfigMap" and (.metadata.name | test("^automation-data-postgresql-init-"))) |
  [.data | keys | sort | join(","), (.data."init-platform.sh" | length > 0),
    (.data."platform-control.sql" | length > 0)] | join("|")
' "$temp_dir/postgresql.yaml")"
[[ "$init_config_contract" == 'init-platform.sh,platform-control.sql|true|true' ]] || \
  fail 'rendered init ConfigMap does not contain both executable platform sources'

[[ "$(yq -r '.spec.suspend' "$postgresql_ks")" == true ]] || \
  fail 'PostgreSQL Flux Kustomization must remain staged suspended'
dependencies="$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$postgresql_ks")"
[[ "$dependencies" == 'automation-data,cilium,kube-prometheus-stack,longhorn' ]] || \
  fail 'PostgreSQL Flux dependency graph is incomplete'
[[ "$(yq -r '.spec.decryption.provider' "$postgresql_ks")" == sops ]] || \
  fail 'PostgreSQL Flux Kustomization must enable SOPS decryption'

mapfile -t declared_functions < <(
  sed -nE 's/^CREATE OR REPLACE FUNCTION (platform_operations\.[a-z_]+)\(.*/\1/p' \
    "$control_sql" | sort -u
)
expected_functions=$'platform_operations.capture_backup_state\nplatform_operations.provision_domain\nplatform_operations.publish_backup\nplatform_operations.reconcile_domain\nplatform_operations.record_domain_credentials\nplatform_operations.record_operation_error\nplatform_operations.rotate_domain_credential\nplatform_operations.validate_domain'
[[ "$(printf '%s\n' "${declared_functions[@]}")" == "$expected_functions" ]] || \
  fail 'platform control SQL exposes an unexpected function set'

rg -Fq "^[a-z][a-z0-9_]{0,47}$" "$control_sql" || \
  fail 'platform control SQL does not enforce the domain identifier boundary'
rg -Fq 'SECURITY DEFINER' "$control_sql" || fail 'control functions lack a privilege boundary'
rg -Fq 'SET search_path = pg_catalog, platform_operations' "$control_sql" || \
  fail 'security-definer search_path is not fixed'
rg -Fq 'REVOKE ALL ON SCHEMA platform_operations FROM PUBLIC' "$control_sql" || \
  fail 'platform schema remains exposed to PUBLIC'
! rg -q 'GRANT EXECUTE ON ALL FUNCTIONS|DROP[[:space:]]+(DATABASE|ROLE)' "$control_sql" || \
  fail 'control SQL exposes broad execution or destructive cluster operations'
for validation_field in runtimePrivilegesValid defaultPrivilegesValid \
  crossDomainConnectDenied; do
  rg -Fq "'$validation_field'" "$control_sql" || \
    fail "validate_domain omits $validation_field"
done

echo 'automation-data rendered platform and control interface passed.'
