#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
base="$repo_root/kubernetes/apps/automation-data"
namespace_app="$base/namespace/app"
postgresql_app="$base/postgresql/app"
postgresql_ks="$base/postgresql/ks.yaml"
control_sql="$postgresql_app/scripts/platform-control.sql"
n8n_app="$repo_root/kubernetes/apps/automation/n8n/app"
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
kustomize build "$n8n_app" >"$temp_dir/n8n.yaml"

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
[[ "$init_config_contract" == 'init-platform.sh,migrate-control.sh,platform-control.sql|true|true' ]] || \
  fail 'rendered init ConfigMap does not contain the initialization and migration sources'

[[ "$(yq -r '.spec.suspend' "$postgresql_ks")" == false ]] || \
  fail 'accepted PostgreSQL Flux Kustomization must remain active'
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
  crossDomainConnectDenied migratorCredentialId runtimeCredentialId \
  migratorCredentialUpdatedAt runtimeCredentialUpdatedAt migratorDdlValid \
  runtimeCrudValid runtimeDdlDenied runtimeOwnerAssumptionDenied \
  runtimeRoleManagementDenied; do
  rg -Fq "'$validation_field'" "$control_sql" || \
    fail "validate_domain omits $validation_field"
done

rotation_function="$(sed -n \
  '/^CREATE OR REPLACE FUNCTION platform_operations.rotate_domain_credential(/,/^CREATE OR REPLACE FUNCTION platform_operations.record_operation_error(/p' \
  "$control_sql")"
rg -Fq 'IF NOT managed.has_reached_ready THEN' <<<"$rotation_function" || \
  fail 'rotation does not require a domain that previously reached ready'
! rg -q 'managed\.state[[:space:]]*(<>|NOT IN)' <<<"$rotation_function" || \
  fail 'rotation cannot retry after an interrupted rotating or error state'

postgres_ingress_contract="$(yq ea -o=json -I=0 '
  select(.kind == "CiliumNetworkPolicy" and .metadata.name == "automation-data-postgresql") |
  .spec.ingress[] | select(.toPorts[0].ports[0].port == "5432") |
  [.fromEndpoints[].matchLabels | {
    "namespace": ."k8s:io.kubernetes.pod.namespace",
    "workload": ."app.kubernetes.io/name"
  }] | sort_by(.namespace, .workload)
' "$temp_dir/postgresql.yaml")"
[[ "$postgres_ingress_contract" == \
  '[{"namespace":"automation","workload":"n8n"},{"namespace":"automation-data","workload":"automation-data-postgresql-backup"}]' ]] || \
  fail 'PostgreSQL port 5432 ingress is not limited to n8n and the backup Job'

metrics_ingress_contract="$(yq ea -o=json -I=0 '
  select(.kind == "CiliumNetworkPolicy" and .metadata.name == "automation-data-postgresql") |
  .spec.ingress[] | select(.toPorts[0].ports[0].port == "9399") |
  .fromEndpoints[0].matchLabels
' "$temp_dir/postgresql.yaml")"
[[ "$metrics_ingress_contract" == \
  '{"app.kubernetes.io/name":"prometheus","k8s:io.kubernetes.pod.namespace":"monitoring","operator.prometheus.io/name":"kube-prometheus-stack-prometheus"}' ]] || \
  fail 'metrics ingress does not use the exact Prometheus workload identity'

postgres_egress_count="$(yq ea -r '
  [select(.kind == "CiliumNetworkPolicy" and
    .metadata.name == "automation-data-postgresql") | .spec.egress[]] | length
' "$temp_dir/postgresql.yaml")"
[[ "$postgres_egress_count" == 0 ]] || fail 'PostgreSQL workload must have no egress'

backup_egress_contract="$(yq ea -r '
  select(.kind == "CiliumNetworkPolicy" and
    .metadata.name == "automation-data-postgresql-backup") |
  [.spec.egress[] | [
    .toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace",
    (.toEndpoints[0].matchLabels."app.kubernetes.io/name" //
      .toEndpoints[0].matchLabels."k8s:k8s-app"),
    ([.toPorts[0].ports[] | .port + "/" + .protocol] | sort | join("+"))
  ] | join("|")] | sort | join(",")
' "$temp_dir/postgresql.yaml")"
[[ "$backup_egress_contract" == \
  'automation-data|automation-data-postgresql|5432/TCP,kube-system|kube-dns|53/TCP+53/UDP' ]] || \
  fail 'backup egress must contain only DNS and local PostgreSQL'

n8n_platform_egress_count="$(yq ea -r '
  [select(.kind == "CiliumNetworkPolicy" and .metadata.name == "n8n") |
    .spec.egress[] | select(
      .toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "automation-data" and
      .toEndpoints[0].matchLabels."app.kubernetes.io/name" == "automation-data-postgresql" and
      .toPorts[0].ports[0].port == "5432" and
      .toPorts[0].ports[0].protocol == "TCP"
    )] | length
' "$temp_dir/n8n.yaml")"
[[ "$n8n_platform_egress_count" == 1 ]] || \
  fail 'n8n must have exactly one stable automation-data PostgreSQL egress path'

policy_sources=(
  "$postgresql_app/ciliumnetworkpolicy.yaml"
  "$n8n_app/ciliumnetworkpolicy.yaml"
)
! rg -q '(_owner|_migrator|_runtime|domain_one|backup_test_domain)' "${policy_sources[@]}" || \
  fail 'Cilium policy contains domain-scoped selectors or names'

# Execute the production migration assembler without a database. Its payload must
# contain exactly the reviewed functions, preserving the fresh-install definition.
mkdir "$temp_dir/bin"
cat >"$temp_dir/bin/psql" <<'SH'
#!/bin/sh
for argument in "$@"; do
  case "$argument" in --file=*) cp "${argument#--file=}" "$MIGRATION_CAPTURE";; esac
done
SH
chmod +x "$temp_dir/bin/psql"
MIGRATION_CAPTURE="$temp_dir/migration.sql" PATH="$temp_dir/bin:$PATH" \
  /bin/sh "$postgresql_app/scripts/migrate-control.sh" >"$temp_dir/status"
[[ "$(cat "$temp_dir/status")" == 'control_migration=applied' ]] || fail 'migration status missing'
python - "$control_sql" "$temp_dir/migration.sql" <<'PYTHON'
import re
import sys
from pathlib import Path
source, migration = (Path(path).read_text() for path in sys.argv[1:])
# Function bodies contain semicolons; delimit by the tagged body terminator.
pattern = r"CREATE OR REPLACE FUNCTION ([a-z_.]+)\(.*?\$function\$;"
def functions(sql):
    return {match[1]: match[0] for match in re.finditer(pattern, sql, re.S)}
actual = functions(migration)
expected = {name: definition for name, definition in functions(source).items() if name in {
    "platform_internal.assert_domain", "platform_operations.provision_domain",
    "platform_operations.record_operation_error",
}}
assert actual == expected and len(actual) == 3, "migration differs from initialized control source"
provision = actual["platform_operations.provision_domain"]
assert provision.index("unmanaged_object_collision") < provision.index("INSERT INTO platform_operations.managed_domains") < provision.index("CREATE ROLE"), "ownership must precede role mutation"
assert "FOR UPDATE" not in provision, "caller row locks conflict with independently committed ownership"
assert "INSERT INTO" not in actual["platform_operations.record_operation_error"], "error reporting cannot establish ownership"
PYTHON

# Render the actual migration Job: exact source, workload identity and Secret ref.
source "$repo_root/scripts/lib/automation-data-bootstrap.sh"
automation_data_control_migration_job_manifest control-test test-run \
  automation-data-postgresql-init-synthetic >"$temp_dir/migration-job.yaml"
kubeconform -strict -summary -ignore-missing-schemas "$temp_dir/migration-job.yaml" >/dev/null
yq -o=json '.' "$temp_dir/migration-job.yaml" >"$temp_dir/migration-job.json"
python - "$temp_dir/migration-job.json" <<'PYTHON'
import json
import sys
from pathlib import Path
job = json.loads(Path(sys.argv[1]).read_text())
container = job["spec"]["template"]["spec"]["containers"][0]
assert job["metadata"]["labels"]["homelab-talos/run-id"] == "test-run"
assert container["image"] == "postgres:17.11-alpine3.24"
assert container["args"] == ["/scripts/migrate-control.sh"]
secret = next(env for env in container["env"] if env["name"] == "PGPASSWORD")
assert secret["valueFrom"]["secretKeyRef"] == {"name": "postgresql-credentials", "key": "backup-password"}
PYTHON

echo 'automation-data rendered platform and control interface passed.'
