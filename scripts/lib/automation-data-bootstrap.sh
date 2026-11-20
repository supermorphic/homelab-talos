#!/usr/bin/env bash

automation_data_exporter_grant_job_manifest() {
  [[ "$#" -eq 2 ]] || {
    echo 'Usage: automation_data_exporter_grant_job_manifest <job-name> <run-id>' >&2
    return 2
  }

  local job_name="$1" run_id="$2"
  JOB_NAME="$job_name" RUN_ID="$run_id" yq --null-input --output-format yaml '
    {
      "apiVersion": "batch/v1",
      "kind": "Job",
      "metadata": {
        "name": strenv(JOB_NAME),
        "namespace": "automation-data",
        "labels": {
          "app.kubernetes.io/name": "automation-data-postgresql-backup",
          "homelab-talos/role": "exporter-monitor-grant",
          "homelab-talos/run-id": strenv(RUN_ID)
        }
      },
      "spec": {
        "activeDeadlineSeconds": 300,
        "backoffLimit": 0,
        "template": {
          "metadata": {"labels": {
            "app.kubernetes.io/name": "automation-data-postgresql-backup",
            "homelab-talos/role": "exporter-monitor-grant",
            "homelab-talos/run-id": strenv(RUN_ID)
          }},
          "spec": {
            "automountServiceAccountToken": false,
            "restartPolicy": "Never",
            "securityContext": {
              "runAsNonRoot": true,
              "runAsUser": 70,
              "runAsGroup": 70,
              "seccompProfile": {"type": "RuntimeDefault"}
            },
            "containers": [{
              "name": "grant-exporter-monitor",
              "image": "postgres:17.11-alpine3.24",
              "imagePullPolicy": "IfNotPresent",
              "command": ["psql"],
              "args": [
                "--no-psqlrc",
                "--set=ON_ERROR_STOP=1",
                "--command=ALTER ROLE automation_data_exporter INHERIT; GRANT pg_monitor TO automation_data_exporter;"
              ],
              "env": [
                {"name": "PGDATABASE", "value": "automation_data_control"},
                {"name": "PGHOST", "value": "automation-data-postgresql"},
                {"name": "PGPORT", "value": "5432"},
                {"name": "PGUSER", "value": "automation_data_backup"},
                {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {
                  "name": "postgresql-credentials", "key": "backup-password"
                }}}
              ],
              "resources": {
                "requests": {"cpu": "10m", "memory": "32Mi"},
                "limits": {"memory": "128Mi"}
              },
              "securityContext": {
                "allowPrivilegeEscalation": false,
                "capabilities": {"drop": ["ALL"]},
                "readOnlyRootFilesystem": true
              },
              "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}]
            }],
            "volumes": [{"name": "tmp", "emptyDir": {}}]
          }
        }
      }
    }'
}

# Reuse the hardened, pinned PostgreSQL Job and its existing backup Secret binding.
automation_data_access_sessions_job_manifest() {
  [[ "$#" -eq 3 && "$3" =~ ^automation-data-postgresql-access-sessions-[a-z0-9]+$ ]] || return 2
  automation_data_exporter_grant_job_manifest "$1" "$2" |
    SCRIPTS_CONFIGMAP="$3" yq '
      .metadata.labels."homelab-talos/role" = "access-sessions-install" |
      .spec.template.metadata.labels."homelab-talos/role" = "access-sessions-install" |
      .spec.template.spec.containers[0].name = "install-access-sessions" |
      .spec.template.spec.containers[0].command = ["/bin/sh"] |
      .spec.template.spec.containers[0].args = ["/scripts/install-access-sessions.sh"] |
      .spec.template.spec.containers[0].volumeMounts += [{
        "name": "scripts", "mountPath": "/scripts", "readOnly": true
      }] |
      .spec.template.spec.volumes += [{
        "name": "scripts", "configMap": {"name": strenv(SCRIPTS_CONFIGMAP)}
      }]
    '
}

# Print the one deployed access-sessions ConfigMap whose data equals the files that
# the reviewed package generates into it. Usage: <temp-dir> <kubectl command...>
automation_data_access_sessions_configmap() {
  local temp_dir="$1"
  shift
  "$@" get configmaps --output json |
    yq -o=json '[.items[] | select(.metadata.name |
      test("^automation-data-postgresql-access-sessions-[a-z0-9]+$"))]' \
      >"$temp_dir/access-sessions-configmaps.json"
  yq -o=json '[.configMapGenerator[] |
      select(.name == "automation-data-postgresql-access-sessions") | .files[]]' \
    kubernetes/apps/automation-data/postgresql/app/kustomization.yaml \
    >"$temp_dir/access-sessions-files.json"
  python3 - "$temp_dir/access-sessions-configmaps.json" \
    "$temp_dir/access-sessions-files.json" <<'PYTHON'
import json
import sys
from pathlib import Path

deployed = json.loads(Path(sys.argv[1]).read_text())
files = json.loads(Path(sys.argv[2]).read_text())
if len(deployed) != 1:
    raise SystemExit("Expected exactly one deployed access-sessions ConfigMap.")
base = Path("kubernetes/apps/automation-data/postgresql/app")
expected = {}
for entry in files:
    key, _, source = entry.partition("=")
    expected[key] = (base / source).read_text()
if not files or deployed[0].get("data") != expected:
    raise SystemExit("Deployed access-session inputs differ from reviewed source.")
print(deployed[0]["metadata"]["name"])
PYTHON
}

automation_data_session_sweeper_enable_job_manifest() {
  automation_data_access_sessions_job_manifest "$@" |
    yq '
      .metadata.labels."homelab-talos/role" = "session-sweeper-enable" |
      .spec.template.metadata.labels."homelab-talos/role" = "session-sweeper-enable" |
      .spec.template.spec.containers[0].name = "enable-session-sweeper" |
      .spec.template.spec.containers[0].args = ["/scripts/enable-session-sweeper.sh"] |
      .spec.template.spec.containers[0].env += [{
        "name": "SWEEPER_PASSWORD",
        "valueFrom": {"secretKeyRef": {
          "name": "automation-data-session-sweeper", "key": "password"
        }}
      }]
    '
  return "${PIPESTATUS[0]}"
}

# Usage: <job> <run-id> <configmap> <run-scoped password Secret>
automation_data_openbao_issuer_enable_job_manifest() {
  [[ "$#" -eq 4 && "$4" =~ ^automation-data-openbao-issuer-[a-z0-9-]+$ ]] || return 2
  automation_data_access_sessions_job_manifest "$1" "$2" "$3" |
    PASSWORD_SECRET="$4" yq '
      .metadata.labels."homelab-talos/role" = "openbao-issuer-enable" |
      .spec.template.metadata.labels."homelab-talos/role" = "openbao-issuer-enable" |
      .spec.template.spec.containers[0].name = "enable-openbao-issuer" |
      .spec.template.spec.containers[0].args = ["/scripts/enable-openbao-issuer.sh"] |
      .spec.template.spec.containers[0].env += [{
        "name": "ISSUER_PASSWORD",
        "valueFrom": {"secretKeyRef": {"name": strenv(PASSWORD_SECRET), "key": "password"}}
      }]
    '
  return "${PIPESTATUS[0]}"
}

automation_data_session_restore_cleanup_job_manifest() {
  automation_data_access_sessions_job_manifest "$@" |
    yq '
      .metadata.labels."homelab-talos/role" = "session-restore-cleanup" |
      .spec.template.metadata.labels."homelab-talos/role" = "session-restore-cleanup" |
      .spec.template.spec.containers[0].name = "restore-session-logins" |
      .spec.template.spec.containers[0].args = ["/scripts/restore-session-logins.sh"]
    '
  return "${PIPESTATUS[0]}"
}

# Usage: <job> <run-id> <configmap> <domain> <capability> <schemas> <max-ttl-seconds>
automation_data_capability_register_job_manifest() {
  [[ "$#" -eq 7 && "$4" =~ ^[a-z][a-z0-9_]{0,47}$ && "$5" =~ ^[a-z][a-z0-9_]{0,23}$ &&
    "$6" =~ ^[a-z_][a-z0-9_]{0,62}(,[a-z_][a-z0-9_]{0,62}){0,15}$ &&
    "$7" =~ ^[1-9][0-9]{1,2}$ ]] || return 2
  automation_data_access_sessions_job_manifest "$1" "$2" "$3" |
    CAPABILITY_DOMAIN="$4" CAPABILITY_NAME="$5" CAPABILITY_SCHEMAS="$6" \
      CAPABILITY_MAX_TTL="$7" yq '
      .metadata.labels."homelab-talos/role" = "access-capability-register" |
      .spec.template.metadata.labels."homelab-talos/role" = "access-capability-register" |
      .spec.template.spec.containers[0].name = "register-access-capability" |
      .spec.template.spec.containers[0].args = ["/scripts/register-access-capability.sh"] |
      .spec.template.spec.containers[0].env |= map(
        select(.name != "PGUSER" and .name != "PGPASSWORD")) |
      .spec.template.spec.containers[0].env += [
        {"name": "PGUSER", "value": "automation_data_provisioner"},
        {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {
          "name": "postgresql-credentials", "key": "provisioner-password"
        }}},
        {"name": "CAPABILITY_DOMAIN", "value": strenv(CAPABILITY_DOMAIN)},
        {"name": "CAPABILITY_NAME", "value": strenv(CAPABILITY_NAME)},
        {"name": "CAPABILITY_SCHEMAS", "value": strenv(CAPABILITY_SCHEMAS)},
        {"name": "CAPABILITY_MAX_TTL", "value": strenv(CAPABILITY_MAX_TTL)}
      ]
    '
  return "${PIPESTATUS[0]}"
}

automation_data_control_migration_job_manifest() {
  [[ "$#" -eq 3 && "$3" =~ ^automation-data-postgresql-init-[a-z0-9]+$ ]] || return 2
  automation_data_exporter_grant_job_manifest "$1" "$2" |
    INIT_CONFIGMAP="$3" yq '
      .metadata.labels."homelab-talos/role" = "control-migration" |
      .spec.template.metadata.labels."homelab-talos/role" = "control-migration" |
      .spec.template.spec.containers[0].name = "migrate-control" |
      .spec.template.spec.containers[0].command = ["/bin/sh"] |
      .spec.template.spec.containers[0].args = ["/scripts/migrate-control.sh"] |
      .spec.template.spec.containers[0].volumeMounts += [{
        "name": "scripts", "mountPath": "/scripts", "readOnly": true
      }] |
      .spec.template.spec.volumes += [{
        "name": "scripts", "configMap": {"name": strenv(INIT_CONFIGMAP)}
      }]
    '
}
