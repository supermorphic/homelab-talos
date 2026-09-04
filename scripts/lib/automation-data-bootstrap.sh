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
