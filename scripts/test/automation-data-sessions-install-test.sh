#!/usr/bin/env bash
# Check access-session packaging, the install Job manifest, the guarded command entry,
# and discovery classification without a cluster.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source scripts/lib/automation-data-bootstrap.sh
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-sessions-install.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
fail() {
  echo "automation-data sessions install test failed: $*" >&2
  exit 1
}
scripts_dir=kubernetes/apps/automation-data/postgresql/app/scripts

kustomize build kubernetes/apps/automation-data/postgresql/app >"$temp_dir/rendered.yaml"
yq ea -o=json 'select(.kind == "ConfigMap" and
    (.metadata.name | test("^automation-data-postgresql-access-sessions-[a-z0-9]+$")))' \
  "$temp_dir/rendered.yaml" >"$temp_dir/configmap.json"
[[ "$(jq -s 'length' "$temp_dir/configmap.json")" == 1 ]] ||
  fail 'exactly one access-sessions ConfigMap must be rendered'
[[ "$(jq -r '.data | keys | join(",")' "$temp_dir/configmap.json")" == \
  'access-sessions.sql,enable-session-sweeper.sh,enable-session-sweeper.sql,install-access-sessions.sh,restore-session-logins.sh' ]] ||
  fail 'the access-sessions ConfigMap must contain exactly the reviewed SQL and wrappers'
for key in access-sessions.sql install-access-sessions.sh enable-session-sweeper.sql \
    enable-session-sweeper.sh restore-session-logins.sh; do
  jq -j --arg key "$key" '.data[$key]' "$temp_dir/configmap.json" >"$temp_dir/$key"
  cmp -s "$temp_dir/$key" "$scripts_dir/$key" || fail "$key differs from reviewed source"
done
configmap="$(jq -r '.metadata.name' "$temp_dir/configmap.json")"
# The StatefulSet must not mount it: a changed mount would restart PostgreSQL.
yq ea -e 'select(.kind == "StatefulSet") |
    [.spec.template.spec.volumes[].configMap.name // ""] |
    map(select(test("access-sessions"))) | length == 0' "$temp_dir/rendered.yaml" >/dev/null ||
  fail 'the StatefulSet must not mount the access-sessions ConfigMap'

# Commands accept only one deployed ConfigMap whose data equals the generated source.
fake_kubectl() { cat "$temp_dir/deployed.json"; }
deployed() {
  jq --arg name "$1" '{items: [{metadata: {name: $name}, data: .data}]}' \
    "$temp_dir/configmap.json" >"$temp_dir/deployed.json"
}
deployed "$configmap"
[[ "$(automation_data_access_sessions_configmap "$temp_dir" fake_kubectl)" == "$configmap" ]] ||
  fail 'the deployed ConfigMap check must accept the reviewed source'
jq '.items[0].data."access-sessions.sql" += "-- drift\n"' "$temp_dir/deployed.json" >"$temp_dir/drift.json"
mv "$temp_dir/drift.json" "$temp_dir/deployed.json"
if automation_data_access_sessions_configmap "$temp_dir" fake_kubectl >/dev/null 2>&1; then
  fail 'the deployed ConfigMap check must reject drifted content'
fi
deployed "$configmap"
jq '.items[0].data.extra = "x"' "$temp_dir/deployed.json" >"$temp_dir/extra.json"
mv "$temp_dir/extra.json" "$temp_dir/deployed.json"
if automation_data_access_sessions_configmap "$temp_dir" fake_kubectl >/dev/null 2>&1; then
  fail 'the deployed ConfigMap check must reject an extra key'
fi
deployed "$configmap"
jq '.items += [.items[0] | .metadata.name = "automation-data-postgresql-access-sessions-zz"]' \
  "$temp_dir/deployed.json" >"$temp_dir/two.json"
mv "$temp_dir/two.json" "$temp_dir/deployed.json"
if automation_data_access_sessions_configmap "$temp_dir" fake_kubectl >/dev/null 2>&1; then
  fail 'the deployed ConfigMap check must reject two candidates'
fi

if automation_data_access_sessions_job_manifest job run-1 not-a-configmap >/dev/null 2>&1; then
  fail 'the manifest must reject an unexpected ConfigMap name'
fi
automation_data_access_sessions_job_manifest automation-data-sessions-run-1 run-1 "$configmap" \
  >"$temp_dir/job.yaml"
yq -o=json "$temp_dir/job.yaml" | jq -e --arg cm "$configmap" '
  .kind == "Job" and .metadata.namespace == "automation-data" and
  .metadata.labels."homelab-talos/run-id" == "run-1" and
  .metadata.labels."homelab-talos/role" == "access-sessions-install" and
  .spec.template.metadata.labels."homelab-talos/run-id" == "run-1" and
  .spec.backoffLimit == 0 and
  .spec.template.spec.automountServiceAccountToken == false and
  .spec.template.spec.securityContext.runAsNonRoot == true and
  .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and
  .spec.template.spec.containers[0].command == ["/bin/sh"] and
  .spec.template.spec.containers[0].args == ["/scripts/install-access-sessions.sh"] and
  ([.spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.name] == [$cm]) and
  ([.spec.template.spec.containers[0].env[] | select(.name == "PGUSER") | .value] ==
    ["automation_data_backup"])
' >/dev/null || fail 'the install Job manifest is not the reviewed shape'

if AUTOMATION_DATA_SESSIONS_INSTALL_CONFIRM='' \
    scripts/operations/automation-data-sessions-install.sh "$temp_dir/missing" \
    >"$temp_dir/command.out" 2>"$temp_dir/command.err"; then
  fail 'the install command must require confirmation'
fi
rg -Fq 'AUTOMATION_DATA_SESSIONS_INSTALL_CONFIRM=install:automation-data:access-sessions' \
  "$temp_dir/command.err" || fail 'the install command must name its confirmation'
just --justfile kubernetes/mod.just --dry-run automation-data-sessions-install >/dev/null 2>&1 ||
  fail 'the automation-data-sessions-install recipe is missing'

# The restore cleanup Job runs the packaged wrapper as the backup identity.
automation_data_session_restore_cleanup_job_manifest automation-data-session-restore-run-1 \
  run-1 "$configmap" >"$temp_dir/cleanup.yaml"
yq -o=json "$temp_dir/cleanup.yaml" | jq -e --arg cm "$configmap" '
  .metadata.labels."homelab-talos/role" == "session-restore-cleanup" and
  .spec.template.spec.containers[0].args == ["/scripts/restore-session-logins.sh"] and
  ([.spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.name] == [$cm]) and
  ([.spec.template.spec.containers[0].env[] | select(.name == "PGUSER") | .value] ==
    ["automation_data_backup"])
' >/dev/null || fail 'the restore cleanup Job manifest is not the reviewed shape'
if AUTOMATION_DATA_SESSIONS_RESTORE_CLEANUP_CONFIRM='' \
    scripts/operations/automation-data-sessions-restore-cleanup.sh "$temp_dir/missing" \
    >"$temp_dir/command.out" 2>"$temp_dir/command.err"; then
  fail 'the restore cleanup command must require confirmation'
fi
rg -Fq 'AUTOMATION_DATA_SESSIONS_RESTORE_CLEANUP_CONFIRM=cleanup:automation-data:restored-sessions' \
  "$temp_dir/command.err" || fail 'the restore cleanup command must name its confirmation'
just --justfile kubernetes/mod.just --dry-run automation-data-sessions-restore-cleanup >/dev/null 2>&1 ||
  fail 'the automation-data-sessions-restore-cleanup recipe is missing'

uv run --locked python - <<'PYTHON' || fail 'discovery must classify the session identities as platform roles'
import sys
sys.path.insert(0, "scripts/lib")
from automation_data_inventory import PLATFORM_ROLES
assert {"automation_data_openbao_issuer", "automation_data_session_sweeper"} <= PLATFORM_ROLES
PYTHON

echo 'automation-data sessions install test passed'
