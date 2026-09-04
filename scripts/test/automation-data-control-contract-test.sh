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
rg -Fq 'CREATE TABLE platform_operations.managed_nocodb_sources' "$control_sql" ||
  fail 'NocoDB source registry is missing'
! rg -Fq 'managed_nocodb_domains' "$control_sql" ||
  fail 'removed NocoDB domain registry remains present'
expected_functions=$'platform_operations.begin_nocodb_source\nplatform_operations.capture_backup_state\nplatform_operations.prepare_nocodb_access\nplatform_operations.provision_domain\nplatform_operations.provision_nocodb_metadata\nplatform_operations.publish_backup\nplatform_operations.read_nocodb_source_state\nplatform_operations.reconcile_domain\nplatform_operations.record_domain_credentials\nplatform_operations.record_nocodb_integration\nplatform_operations.record_nocodb_source_error\nplatform_operations.record_nocodb_source_job\nplatform_operations.record_nocodb_source_ready\nplatform_operations.record_operation_error\nplatform_operations.rotate_domain_credential\nplatform_operations.rotate_nocodb_source_credential\nplatform_operations.validate_domain\nplatform_operations.validate_nocodb_access'
[[ "$(printf '%s\n' "${declared_functions[@]}")" == "$expected_functions" ]] || \
  fail 'platform control SQL exposes an unexpected function set'
for state in awaiting_grants provisioning waiting_for_source ready rotating error; do
  rg -Fq "'$state'" "$control_sql" || fail "NocoDB source state $state is missing"
done
for schema in read_model operator; do
  rg -Fq "$schema" "$control_sql" || fail "NocoDB schema $schema is missing"
done

nocodb_functions=(
  provision_nocodb_metadata prepare_nocodb_access read_nocodb_source_state begin_nocodb_source
  record_nocodb_integration record_nocodb_source_job record_nocodb_source_ready
  record_nocodb_source_error rotate_nocodb_source_credential validate_nocodb_access
)
for function_name in "${nocodb_functions[@]}"; do
  function_body="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations\\.${function_name}(/,/^\\\$function\\\$;/p" "$control_sql")"
  [[ -n "$function_body" ]] || fail "NocoDB function $function_name is missing"
  rg -Fq 'SECURITY DEFINER' <<<"$function_body" ||
    fail "NocoDB function $function_name is not SECURITY DEFINER"
  rg -Fq 'SET search_path = pg_catalog, platform_operations' <<<"$function_body" ||
    fail "NocoDB function $function_name lacks a fixed search path"
  rg -Fq 'platform_internal.assert_domain(p_domain)' <<<"$function_body" ||
    [[ "$function_name" == provision_nocodb_metadata ]] ||
      fail "NocoDB function $function_name does not validate its domain"
  ! rg -q 'EXECUTE[[:space:]]\+.*p_' <<<"$function_body" ||
    fail "NocoDB function $function_name accepts dynamic request SQL"
  ! rg -q 'DELETE[[:space:]]\+FROM\|DROP[[:space:]]\+' <<<"$function_body" ||
    fail "NocoDB function $function_name deletes managed state"
done

for function_name in begin_nocodb_source rotate_nocodb_source_credential; do
  function_body="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations\\.${function_name}(/,/^\\\$function\\\$;/p" "$control_sql")"
  rg -Fq 'length(p_password) < 32' <<<"$function_body" ||
    fail "NocoDB function $function_name does not require a 32-character password"
done
for function_name in prepare_nocodb_access read_nocodb_source_state begin_nocodb_source record_nocodb_integration \
  record_nocodb_source_job record_nocodb_source_ready record_nocodb_source_error \
  rotate_nocodb_source_credential validate_nocodb_access; do
  function_body="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations\\.${function_name}(/,/^\\\$function\\\$;/p" "$control_sql")"
  rg -Fq 'pg_advisory_xact_lock' <<<"$function_body" ||
    fail "NocoDB function $function_name does not take a domain advisory lock"
done
for json_field in domain readerRole readerEligible operatorRequested operatorEligible \
  accessKind role baseId state operation generation credentialGeneration integrationId \
  sourceCreateJobId sourceId validatedAt operationStartedAt updatedAt errorCode \
  valid schemaPrivilegesValid objectPrivilegesValid defaultPrivilegesValid \
  outsideSchemaDenied databaseIsolationValid forbiddenAttributesDenied \
  forbiddenMembershipsDenied ddlDenied controlledDmlPresent; do
  rg -Fq "'$json_field'" "$control_sql" || fail "NocoDB result field $json_field is missing"
done
for function_name in "${nocodb_functions[@]}"; do
  rg -Fq "GRANT EXECUTE ON FUNCTION platform_operations.$function_name" "$control_sql" ||
    fail "provisioner execution grant for $function_name is missing"
  grant_lines="$(rg -F "GRANT EXECUTE ON FUNCTION platform_operations.$function_name" "$control_sql")"
  [[ "$grant_lines" == *" TO automation_data_provisioner;"* ]] ||
    fail "NocoDB function $function_name lacks the exact provisioner grant"
  while IFS= read -r grant_line; do
    [[ "$grant_line" == *' TO automation_data_provisioner;' ]] ||
      fail "NocoDB function $function_name is executable by a non-provisioner role"
  done <<<"$grant_lines"
done
rg -Fq 'GRANT SELECT ON platform_operations.managed_domains,' "$control_sql" ||
  fail 'backup and exporter grant boundary is missing'
! rg -q 'GRANT SELECT ON platform_operations\.managed_nocodb_sources TO automation_data_(backup|exporter)' \
  "$control_sql" || fail 'backup and exporter must not read NocoDB source IDs'
! rg -Uq 'GRANT SELECT ON[^;]*platform_operations\.managed_nocodb_sources[^;]*TO automation_data_provisioner;' \
  "$control_sql" || fail 'provisioner must not receive direct NocoDB source registry SELECT'
provisioner_select_grants="$(rg -U 'GRANT SELECT ON[^;]*TO automation_data_provisioner;' "$control_sql")"
[[ "$provisioner_select_grants" == 'GRANT SELECT ON platform_operations.managed_domains TO automation_data_provisioner;' ]] ||
  fail 'provisioner receives unexpected direct table SELECT privileges'

read_nocodb_source_state_function="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations.read_nocodb_source_state(/,/^\$function\$;/p" "$control_sql")"
[[ -n "$read_nocodb_source_state_function" ]] || fail 'NocoDB source-state reader is missing'
rg -Fq "operation text NOT NULL CHECK (operation IN ('sync', 'rotate'))" "$control_sql" ||
  fail 'NocoDB source registry does not persist the exact retry operation'
rg -Fq 'p_domain text' <<<"$read_nocodb_source_state_function" ||
  fail 'NocoDB source-state reader lacks the domain parameter'
rg -Fq 'p_access_kind text' <<<"$read_nocodb_source_state_function" ||
  fail 'NocoDB source-state reader lacks the access-kind parameter'
rg -Fq 'platform_internal.assert_domain(p_domain)' <<<"$read_nocodb_source_state_function" ||
  fail 'NocoDB source-state reader does not validate the managed domain'
rg -Fq 'platform_internal.assert_nocodb_access_kind(p_access_kind)' <<<"$read_nocodb_source_state_function" ||
  fail 'NocoDB source-state reader does not validate the access kind'
access_kind_assertion_function="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_internal.assert_nocodb_access_kind(/,/^\$function\$;/p" "$control_sql")"
rg -Fq "p_access_kind IS NULL OR p_access_kind NOT IN ('reader', 'operator')" \
  <<<"$access_kind_assertion_function" ||
  fail 'NocoDB access-kind validation does not explicitly reject NULL'
rg -Fq "RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid_access_kind';" \
  <<<"$access_kind_assertion_function" ||
  fail 'NocoDB access-kind validation does not reject invalid values with its fixed error'
rg -Fq 'PERFORM 1 FROM platform_operations.managed_domains WHERE domain = p_domain FOR KEY SHARE;' \
  <<<"$read_nocodb_source_state_function" ||
  fail 'NocoDB source-state reader does not prove the managed domain exists'
rg -Fq "RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'domain_not_found';" \
  <<<"$read_nocodb_source_state_function" ||
  fail 'NocoDB source-state reader does not reject an unknown managed domain'
managed_domain_line="$(rg -n -F 'PERFORM 1 FROM platform_operations.managed_domains WHERE domain = p_domain FOR KEY SHARE;' \
  <<<"$read_nocodb_source_state_function" | cut -d: -f1)"
null_result_line="$(rg -n -F "RETURN COALESCE(platform_internal.nocodb_source_result(p_domain, p_access_kind), 'null'::jsonb);" \
  <<<"$read_nocodb_source_state_function" | cut -d: -f1)"
[[ -n "$managed_domain_line" && -n "$null_result_line" && "$managed_domain_line" -lt "$null_result_line" ]] ||
  fail 'NocoDB source-state reader can return JSON null before proving the managed domain'
rg -Fq "RETURN COALESCE(platform_internal.nocodb_source_result(p_domain, p_access_kind), 'null'::jsonb);" \
  <<<"$read_nocodb_source_state_function" ||
  fail 'NocoDB source-state reader does not return the fixed registry result or JSON null'
! rg -q 'EXECUTE[[:space:]]+.*p_|format[[:space:]]*\(' <<<"$read_nocodb_source_state_function" ||
  fail 'NocoDB source-state reader permits dynamic request SQL'
source_result_builder="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_internal.nocodb_source_result(/,/^\$function\$;/p" "$control_sql")"
for json_field in domain accessKind role baseId integrationId sourceCreateJobId sourceId \
  state operation generation credentialGeneration operationStartedAt validatedAt updatedAt errorCode; do
  rg -Fq "'$json_field'" <<<"$source_result_builder" ||
    fail "NocoDB source-state reader result omits $json_field"
done
! rg -qi 'password|token|header|config' <<<"$source_result_builder" ||
  fail 'NocoDB source-state reader result exposes secret material'
rg -Fq 'REVOKE EXECUTE ON FUNCTION platform_operations.read_nocodb_source_state(text, text) FROM PUBLIC;' \
  "$control_sql" || fail 'NocoDB source-state reader does not revoke PUBLIC execute'
read_source_state_grants="$(rg -F 'GRANT EXECUTE ON FUNCTION platform_operations.read_nocodb_source_state(text, text)' "$control_sql")"
[[ "$read_source_state_grants" == 'GRANT EXECUTE ON FUNCTION platform_operations.read_nocodb_source_state(text, text) TO automation_data_provisioner;' ]] ||
  fail 'NocoDB source-state reader execute grant is not provisioner-exclusive'

begin_nocodb_source_function="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations.begin_nocodb_source(/,/^\$function\$;/p" "$control_sql")"
rg -Fq 'prepared := platform_operations.prepare_nocodb_access(p_domain);' <<<"$begin_nocodb_source_function" ||
  fail 'NocoDB source begin does not inspect prepared eligibility'
rg -Fq "source.state = 'error' AND source.operation <> 'sync'" <<<"$begin_nocodb_source_function" ||
  fail 'NocoDB source begin permits sync to reuse a failed rotation row'
rg -Fq "state = 'provisioning', operation = 'sync'" <<<"$begin_nocodb_source_function" ||
  fail 'NocoDB source begin does not persist its initial sync operation'
rg -Fq "prepared->>'operatorEligible'" <<<"$begin_nocodb_source_function" ||
  fail 'NocoDB source begin does not reject an ineligible operator before login'
! rg -Fq 'validate_nocodb_access(p_domain, p_access_kind)' <<<"$begin_nocodb_source_function" ||
  fail 'NocoDB source begin validates only after changing the remote login'
result_line="$(rg -n 'result := platform_internal.nocodb_source_result' <<<"$begin_nocodb_source_function" | cut -d: -f1)"
login_line="$(rg -n "ALTER ROLE %I LOGIN" <<<"$begin_nocodb_source_function" | cut -d: -f1)"
[[ -n "$result_line" && -n "$login_line" && "$result_line" -lt "$login_line" ]] ||
  fail 'NocoDB source begin can fail locally after enabling the remote login'

prepare_nocodb_access_function="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations.prepare_nocodb_access(/,/^\$function\$;/p" "$control_sql")"
rg -Fq 'IF operator_requested AND NOT operator_eligible THEN' <<<"$prepare_nocodb_access_function" ||
  fail 'NocoDB prepare does not branch for an operator awaiting reviewed grants'
rg -Fq "'awaiting_grants'" <<<"$prepare_nocodb_access_function" ||
  fail 'NocoDB prepare does not persist the awaiting-grants transition'
rg -Fq 'INSERT INTO platform_operations.managed_nocodb_sources' <<<"$prepare_nocodb_access_function" ||
  fail 'NocoDB prepare does not create the awaiting-grants source row'

for transition_contract in \
  'begin_nocodb_source:source.state NOT IN' \
  "record_nocodb_integration:source.state <> 'provisioning'" \
  "record_nocodb_source_job:source.state = 'waiting_for_source'" \
  'record_nocodb_source_ready:source.state NOT IN' \
  "rotate_nocodb_source_credential:source.state NOT IN ('ready', 'error')"; do
  function_name="${transition_contract%%:*}"
  expected_guard="${transition_contract#*:}"
  function_body="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations\\.${function_name}(/,/^\\\$function\\\$;/p" "$control_sql")"
  rg -Fq "$expected_guard" <<<"$function_body" ||
    fail "NocoDB function $function_name lacks its strict transition guard"
done

rotate_nocodb_source_function="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations.rotate_nocodb_source_credential(/,/^\$function\$;/p" "$control_sql")"
rg -Fq 'source.source_id IS NULL OR source.integration_id IS NULL OR source.base_id IS NULL' \
  <<<"$rotate_nocodb_source_function" ||
  fail 'NocoDB source rotation does not require the retained exact source identity'
rg -Fq "source.state = 'error' AND source.operation <> 'rotate'" \
  <<<"$rotate_nocodb_source_function" ||
  fail 'NocoDB source rotation permits a failed initial generation to use the retained-identity retry'
rg -Fq "SET state = 'rotating', operation = 'rotate'" <<<"$rotate_nocodb_source_function" ||
  fail 'NocoDB source rotation does not persist its retry operation'
rg -Fq "ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L" \
  <<<"$rotate_nocodb_source_function" ||
  fail 'NocoDB source rotation does not re-enable a failed retained source safely'

record_nocodb_source_error_function="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations.record_nocodb_source_error(/,/^\$function\$;/p" "$control_sql")"
rg -Fq 'p_operation text' <<<"$record_nocodb_source_error_function" ||
  fail 'NocoDB source error recording does not accept the exact failed operation'
rg -Fq "p_operation NOT IN ('sync', 'rotate')" <<<"$record_nocodb_source_error_function" ||
  fail 'NocoDB source error recording does not validate its operation'
rg -Fq 'SET state = '\''error'\'', operation = p_operation' <<<"$record_nocodb_source_error_function" ||
  fail 'NocoDB source error recording does not persist its exact operation'
rg -Fqx 'GRANT EXECUTE ON FUNCTION platform_operations.record_nocodb_source_error(text, text, text, text) TO automation_data_provisioner;' \
  "$control_sql" || fail 'NocoDB source error recording does not have the exact fixed grant signature'

validate_nocodb_access_function="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_operations.validate_nocodb_access(/,/^\$function\$;/p" "$control_sql")"
authority_validation_function="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_internal.validate_nocodb_access_authority(/,/^\$function\$;/p" "$control_sql")"
rg -Fq 'true' <<<"$validate_nocodb_access_function" ||
  fail 'ready NocoDB access validation does not require LOGIN'
rg -Fq 'FROM pg_database AS database' <<<"$authority_validation_function" ||
  fail 'NocoDB access validation does not inspect every catalog database'
rg -Fq 'database.datallowconn AND NOT database.datistemplate' <<<"$authority_validation_function" ||
  fail 'NocoDB access validation does not include every connectable database'
rg -Fq 'relation_attribute.attacl' <<<"$authority_validation_function" ||
  fail 'NocoDB access validation ignores column-level operator grants'
rg -Fq 'pg_default_acl' <<<"$authority_validation_function" ||
  fail 'NocoDB access validation does not inspect default privileges'
! rg -Fq 'object_privileges_valid := true;' <<<"$authority_validation_function" ||
  fail 'NocoDB operator object privilege validation is hard-coded'
! rg -Fq 'ELSE true' <<<"$authority_validation_function" ||
  fail 'NocoDB operator default privilege validation is hard-coded'

prelogin_authority_function="$(sed -n "/^CREATE OR REPLACE FUNCTION platform_internal.validate_nocodb_access_authority(/,/^\$function\$;/p" "$control_sql")"
[[ -n "$prelogin_authority_function" ]] ||
  fail 'NocoDB pre-login authority validator is missing'
rg -Fq 'p_expect_login boolean' <<<"$prelogin_authority_function" ||
  fail 'NocoDB pre-login authority validator does not model the expected login state'
rg -Fq 'NOT login_valid' <<<"$prelogin_authority_function" ||
  fail 'NocoDB pre-login authority validator does not require NOLOGIN'
for validation_field in valid loginValid schemaPrivilegesValid objectPrivilegesValid \
  defaultPrivilegesValid outsideSchemaDenied databaseIsolationValid \
  forbiddenAttributesDenied forbiddenMembershipsDenied ddlDenied controlledDmlPresent; do
  rg -Fq "'$validation_field'" <<<"$prelogin_authority_function" ||
    fail "NocoDB pre-login authority validator omits $validation_field"
done
[[ "$(rg -Fc 'platform_internal.validate_nocodb_access_authority(' <<<"$prepare_nocodb_access_function")" == 2 ]] ||
  fail 'NocoDB prepare does not run one full pre-login authority gate per access role'
rg -Fq 'has_table_privilege' <<<"$prelogin_authority_function" ||
  fail 'NocoDB authority validation does not use effective table privileges'
rg -Fq 'has_sequence_privilege' <<<"$prelogin_authority_function" ||
  fail 'NocoDB authority validation does not use effective sequence privileges'
rg -Fq 'acl.grantee IN (0,' <<<"$prelogin_authority_function" ||
  fail 'NocoDB authority validation does not inspect PUBLIC default ACLs'
rg -Fq "has_any_column_privilege(%1\$L, format(''%%I.%%I'', namespace.nspname, relation.relname), ''INSERT,UPDATE,REFERENCES'')" \
  <<<"$prelogin_authority_function" ||
  fail 'NocoDB reader authority validation does not reject effective column DML or REFERENCES privileges'
rg -Fq 'reader_expect_login boolean' <<<"$prepare_nocodb_access_function" ||
  fail 'NocoDB preparation does not model the reader login state'
rg -Fq 'operator_expect_login boolean' <<<"$prepare_nocodb_access_function" ||
  fail 'NocoDB preparation does not model the operator login state'
for active_login_guard in \
  "reader_expect_login := FOUND AND reader_source.state IN ('provisioning', 'waiting_for_source', 'ready', 'rotating');" \
  "operator_expect_login := operator_source_exists AND operator_source.state IN ('provisioning', 'waiting_for_source', 'ready', 'rotating');"; do
  rg -Fq "$active_login_guard" <<<"$prepare_nocodb_access_function" ||
    fail 'NocoDB preparation does not reconcile an active source with LOGIN required'
done
rg -Fq 'IF NOT reader_expect_login THEN' <<<"$prepare_nocodb_access_function" ||
  fail 'NocoDB preparation can disable an active reader source'
rg -Fq 'IF NOT operator_expect_login THEN' <<<"$prepare_nocodb_access_function" ||
  fail 'NocoDB preparation can disable an active operator source'
rg -Fq "p_domain, 'reader', reader_name, reader_expect_login" <<<"$prepare_nocodb_access_function" ||
  fail 'NocoDB reader preparation does not validate its expected login state'
rg -Fq "p_domain, 'operator', operator_name, operator_expect_login" <<<"$prepare_nocodb_access_function" ||
  fail 'NocoDB operator preparation does not validate its expected login state'

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
  '[{"namespace":"automation","workload":"n8n"},{"namespace":"automation-data","workload":"automation-data-postgresql-backup"},{"namespace":"automation-data","workload":"nocodb"},{"namespace":"automation-data","workload":"nocodb-metadata-bootstrap"}]' ]] || \
  fail 'PostgreSQL port 5432 ingress is not limited to approved n8n, backup, and NocoDB workloads'

postgres_nocodb_ingress_tuples="$(yq ea -o=json -I=0 '
  select(.kind == "CiliumNetworkPolicy" and .metadata.name == "automation-data-postgresql") |
  {
    "nocodb": [
      .spec.ingress[] |
      select([.fromEndpoints[].matchLabels |
        select(."k8s:io.kubernetes.pod.namespace" == "automation-data" and
          ."app.kubernetes.io/name" == "nocodb")] | length == 1) |
      {
        "namespace": "automation-data",
        "workload": "nocodb",
        "toPorts": ([.toPorts[]?.ports[] | .port + "/" + .protocol] | sort)
      }
    ],
    "metadataBootstrap": [
      .spec.ingress[] |
      select([.fromEndpoints[].matchLabels |
        select(."k8s:io.kubernetes.pod.namespace" == "automation-data" and
          ."app.kubernetes.io/name" == "nocodb-metadata-bootstrap")] | length == 1) |
      {
        "namespace": "automation-data",
        "workload": "nocodb-metadata-bootstrap",
        "toPorts": ([.toPorts[]?.ports[] | .port + "/" + .protocol] | sort)
      }
    ]
  }
' "$temp_dir/postgresql.yaml")"
[[ "$postgres_nocodb_ingress_tuples" == \
  '{"nocodb":[{"namespace":"automation-data","workload":"nocodb","toPorts":["5432/TCP"]}],"metadataBootstrap":[{"namespace":"automation-data","workload":"nocodb-metadata-bootstrap","toPorts":["5432/TCP"]}]}' ]] || \
  fail 'NocoDB PostgreSQL ingress must bind each approved source to only TCP/5432'

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
