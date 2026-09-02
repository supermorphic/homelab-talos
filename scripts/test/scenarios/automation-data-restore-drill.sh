#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
# shellcheck source=scripts/lib/n8n-verification.sh
source scripts/lib/n8n-verification.sh
# shellcheck source=scripts/test/lib/job.sh
source scripts/test/lib/job.sh
# shellcheck source=scripts/test/lib/lease.sh
source scripts/test/lib/lease.sh
# shellcheck source=scripts/test/lib/n8n-restore-command.sh
source scripts/test/lib/n8n-restore-command.sh
# shellcheck source=scripts/test/lib/automation-data-restore-command.sh
source scripts/test/lib/automation-data-restore-command.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: automation-data-restore-drill.sh <kubeconfig>' >&2
  exit 2
}

# Refuse before kubeconfig inspection or any Kubernetes request.
expected_confirmation='restore:automation-data:full-chain'
[[ "${AUTOMATION_DATA_RESTORE_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing full-chain restore drill: set AUTOMATION_DATA_RESTORE_CONFIRM=$expected_confirmation after reviewing its isolated storage and cleanup scope." >&2
  exit 1
}

kubeconfig="$1"
run_dir="${HOMELAB_TEST_RUN_DIR:-}"
[[ -n "$run_dir" && -d "$run_dir" ]] || {
  echo 'Refusing full-chain restore drill outside the catalog run coordinator.' >&2
  exit 1
}
[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

run_id="$(basename "$run_dir")"
run_hash="$(printf '%s' "$run_id" | shasum -a 256 | cut -c1-12)"
lease_holder="${TEST_CAMPAIGN_LEASE_HOLDER:-$run_id}"
prefix="ad-restore-$run_hash"
ad_namespace='automation-data'
n8n_namespace='automation'
request_namespace='gatus'
ad_database="$prefix-db"
ad_service="$prefix-db"
ad_data_pvc="$prefix-ad-data"
n8n_database="$prefix-n8n-db"
n8n_service="$prefix-n8n-db"
n8n_data_pvc="$prefix-n8n-data"
n8n_app="$prefix-n8n"
ad_restore_job="$prefix-ad-load"
n8n_restore_job="$prefix-n8n-load"
request_job="$prefix-request"
ad_policy="$prefix-ad-policy"
n8n_policy="$prefix-n8n-policy"
request_policy="$prefix-request-policy"
k_ad=(kubectl --kubeconfig "$kubeconfig" --namespace "$ad_namespace")
k_n8n=(kubectl --kubeconfig "$kubeconfig" --namespace "$n8n_namespace")
k_request=(kubectl --kubeconfig "$kubeconfig" --namespace "$request_namespace")
k_cluster=(kubectl --kubeconfig "$kubeconfig")

write_phase() {
  local phase="$1" phase_status="$2" reason="$3"
  PHASE_STATUS="$phase_status" PHASE_REASON="$reason" \
    yq --null-input --output-format json '{
      "status": strenv(PHASE_STATUS),
      "reason": strenv(PHASE_REASON)
    }' >"$run_dir/$phase.json"
}

write_phase assertion not-classified 'full-chain restore assertions have not completed'
write_phase cleanup not-classified 'run-owned workloads and storage have not been removed'
write_phase recovery not-required 'production workloads and databases are not modified'

verify_lease() {
  verify_test_lease_holder "$kubeconfig" "$lease_holder" || {
    echo 'The shared state-changing test Lease is absent, expired, or owned by another run.' >&2
    return 1
  }
}

resource_absent() {
  local namespace="$1" target="$2" resource
  resource="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
    get "$target" --ignore-not-found --output name)" || return 1
  [[ -z "$resource" ]]
}

platform_manifests() {
  # shellcheck disable=SC2016 # yq evaluates its own variables.
  AD_DATABASE="$ad_database" AD_SERVICE="$ad_service" AD_DATA_PVC="$ad_data_pvc" \
    N8N_DATABASE="$n8n_database" N8N_SERVICE="$n8n_service" \
    N8N_DATA_PVC="$n8n_data_pvc" RUN_HASH="$run_hash" \
    yq --null-input --output-format yaml '
      {
        "homelab-talos/test": "automation-data-restore-drill",
        "homelab-talos/run-id": strenv(RUN_HASH)
      } as $run_labels |
      [
        {
          "apiVersion": "v1", "kind": "PersistentVolumeClaim",
          "metadata": {"name": strenv(AD_DATA_PVC), "namespace": "automation-data", "labels": ($run_labels * {"homelab-talos/role": "ad-data"})},
          "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": "longhorn", "resources": {"requests": {"storage": "20Gi"}}}
        },
        {
          "apiVersion": "v1", "kind": "PersistentVolumeClaim",
          "metadata": {"name": strenv(N8N_DATA_PVC), "namespace": "automation", "labels": ($run_labels * {"homelab-talos/role": "n8n-data"})},
          "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": "longhorn", "resources": {"requests": {"storage": "20Gi"}}}
        },
        {
          "apiVersion": "v1", "kind": "Service",
          "metadata": {"name": strenv(AD_SERVICE), "namespace": "automation-data", "labels": ($run_labels * {"homelab-talos/role": "ad-database"})},
          "spec": {"type": "ClusterIP", "selector": ($run_labels * {"homelab-talos/role": "ad-database"}), "ports": [{"name": "postgresql", "port": 5432, "targetPort": "postgresql"}]}
        },
        {
          "apiVersion": "v1", "kind": "Service",
          "metadata": {"name": strenv(N8N_SERVICE), "namespace": "automation", "labels": ($run_labels * {"homelab-talos/role": "n8n-database"})},
          "spec": {"type": "ClusterIP", "selector": ($run_labels * {"homelab-talos/role": "n8n-database"}), "ports": [{"name": "postgresql", "port": 5432, "targetPort": "postgresql"}]}
        },
        {
          "apiVersion": "apps/v1", "kind": "StatefulSet",
          "metadata": {"name": strenv(AD_DATABASE), "namespace": "automation-data", "labels": ($run_labels * {"homelab-talos/role": "ad-database"})},
          "spec": {
            "replicas": 1, "serviceName": strenv(AD_SERVICE),
            "selector": {"matchLabels": ($run_labels * {"homelab-talos/role": "ad-database"})},
            "template": {
              "metadata": {"labels": ($run_labels * {"homelab-talos/role": "ad-database"})},
              "spec": {
                "automountServiceAccountToken": false,
                "securityContext": {"fsGroup": 70, "fsGroupChangePolicy": "OnRootMismatch", "seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{
                  "name": "postgresql", "image": "postgres:17.11-alpine3.24", "imagePullPolicy": "IfNotPresent",
                  "env": [
                    {"name": "PGDATA", "value": "/var/lib/postgresql/data/pgdata"},
                    {"name": "POSTGRES_DB", "value": "postgres"},
                    {"name": "POSTGRES_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "postgresql-credentials", "key": "postgres-superuser-password"}}}
                  ],
                  "ports": [{"name": "postgresql", "containerPort": 5432}],
                  "readinessProbe": {"exec": {"command": ["pg_isready", "--username=postgres", "--dbname=postgres"]}, "periodSeconds": 5, "failureThreshold": 60},
                  "resources": {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"memory": "1Gi"}},
                  "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "readOnlyRootFilesystem": true, "runAsNonRoot": true, "runAsUser": 70, "runAsGroup": 70},
                  "volumeMounts": [
                    {"name": "data", "mountPath": "/var/lib/postgresql/data"},
                    {"name": "run", "mountPath": "/var/run/postgresql"},
                    {"name": "tmp", "mountPath": "/tmp"}
                  ]
                }],
                "volumes": [
                  {"name": "data", "persistentVolumeClaim": {"claimName": strenv(AD_DATA_PVC)}},
                  {"name": "run", "emptyDir": {}}, {"name": "tmp", "emptyDir": {}}
                ]
              }
            }
          }
        },
        {
          "apiVersion": "apps/v1", "kind": "StatefulSet",
          "metadata": {"name": strenv(N8N_DATABASE), "namespace": "automation", "labels": ($run_labels * {"homelab-talos/role": "n8n-database"})},
          "spec": {
            "replicas": 1, "serviceName": strenv(N8N_SERVICE),
            "selector": {"matchLabels": ($run_labels * {"homelab-talos/role": "n8n-database"})},
            "template": {
              "metadata": {"labels": ($run_labels * {"homelab-talos/role": "n8n-database"})},
              "spec": {
                "automountServiceAccountToken": false,
                "securityContext": {"fsGroup": 70, "fsGroupChangePolicy": "OnRootMismatch", "seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{
                  "name": "postgresql", "image": "postgres:17.11-alpine3.24", "imagePullPolicy": "IfNotPresent",
                  "env": [
                    {"name": "PGDATA", "value": "/var/lib/postgresql/data/pgdata"},
                    {"name": "POSTGRES_DB", "value": "postgres"},
                    {"name": "POSTGRES_USER", "value": "n8n"},
                    {"name": "POSTGRES_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "postgresql-credentials", "key": "n8n-password"}}}
                  ],
                  "ports": [{"name": "postgresql", "containerPort": 5432}],
                  "readinessProbe": {"exec": {"command": ["pg_isready", "--username=n8n", "--dbname=postgres"]}, "periodSeconds": 5, "failureThreshold": 60},
                  "resources": {"requests": {"cpu": "50m", "memory": "128Mi"}, "limits": {"memory": "1Gi"}},
                  "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "readOnlyRootFilesystem": true, "runAsNonRoot": true, "runAsUser": 70, "runAsGroup": 70},
                  "volumeMounts": [
                    {"name": "data", "mountPath": "/var/lib/postgresql/data"},
                    {"name": "run", "mountPath": "/var/run/postgresql"},
                    {"name": "tmp", "mountPath": "/tmp"}
                  ]
                }],
                "volumes": [
                  {"name": "data", "persistentVolumeClaim": {"claimName": strenv(N8N_DATA_PVC)}},
                  {"name": "run", "emptyDir": {}}, {"name": "tmp", "emptyDir": {}}
                ]
              }
            }
          }
        }
      ] | .[] | split_doc'
}

policy_manifests() {
  # shellcheck disable=SC2016 # yq evaluates its own variables.
  AD_POLICY="$ad_policy" N8N_POLICY="$n8n_policy" REQUEST_POLICY="$request_policy" \
    RUN_HASH="$run_hash" yq --null-input --output-format yaml '
      {
        "homelab-talos/test": "automation-data-restore-drill",
        "homelab-talos/run-id": strenv(RUN_HASH)
      } as $run_labels |
      {"toEndpoints": [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "kube-system", "k8s:k8s-app": "kube-dns"}}], "toPorts": [{"ports": [{"port": "53", "protocol": "TCP"}, {"port": "53", "protocol": "UDP"}]}]} as $dns |
      [
        {
          "apiVersion": "cilium.io/v2", "kind": "CiliumNetworkPolicy",
          "metadata": {"name": strenv(AD_POLICY), "namespace": "automation-data", "labels": ($run_labels * {"homelab-talos/role": "policy"})},
          "specs": [
            {"endpointSelector": {"matchLabels": ($run_labels * {"homelab-talos/role": "ad-database"})}, "ingress": [{"fromEndpoints": [
              {"matchLabels": ($run_labels * {"homelab-talos/role": "ad-restore", "k8s:io.kubernetes.pod.namespace": "automation-data"})},
              {"matchLabels": ($run_labels * {"homelab-talos/role": "n8n", "k8s:io.kubernetes.pod.namespace": "automation"})}
            ], "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}]}], "egress": []},
            {"endpointSelector": {"matchLabels": ($run_labels * {"homelab-talos/role": "ad-restore"})}, "ingress": [], "egress": [$dns, {"toEndpoints": [{"matchLabels": ($run_labels * {"homelab-talos/role": "ad-database"})}], "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}]}]}
          ]
        },
        {
          "apiVersion": "cilium.io/v2", "kind": "CiliumNetworkPolicy",
          "metadata": {"name": strenv(N8N_POLICY), "namespace": "automation", "labels": ($run_labels * {"homelab-talos/role": "policy"})},
          "specs": [
            {"endpointSelector": {"matchLabels": ($run_labels * {"homelab-talos/role": "n8n-database"})}, "ingress": [{"fromEndpoints": [
              {"matchLabels": ($run_labels * {"homelab-talos/role": "n8n-restore"})}, {"matchLabels": ($run_labels * {"homelab-talos/role": "n8n"})}
            ], "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}]}], "egress": []},
            {"endpointSelector": {"matchLabels": ($run_labels * {"homelab-talos/role": "n8n-restore"})}, "ingress": [], "egress": [$dns, {"toEndpoints": [{"matchLabels": ($run_labels * {"homelab-talos/role": "n8n-database"})}], "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}]}]},
            {"endpointSelector": {"matchLabels": ($run_labels * {"homelab-talos/role": "n8n"})}, "ingress": [{"fromEndpoints": [{"matchLabels": ($run_labels * {"homelab-talos/role": "request", "k8s:io.kubernetes.pod.namespace": "gatus"})}], "toPorts": [{"ports": [{"port": "5678", "protocol": "TCP"}]}]}], "egress": [
              $dns,
              {"toEndpoints": [{"matchLabels": ($run_labels * {"homelab-talos/role": "n8n-database"})}], "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}]},
              {"toEndpoints": [{"matchLabels": ($run_labels * {"homelab-talos/role": "ad-database", "k8s:io.kubernetes.pod.namespace": "automation-data"})}], "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}]}
            ]}
          ]
        },
        {
          "apiVersion": "cilium.io/v2", "kind": "CiliumNetworkPolicy",
          "metadata": {"name": strenv(REQUEST_POLICY), "namespace": "gatus", "labels": ($run_labels * {"homelab-talos/role": "policy"})},
          "spec": {"endpointSelector": {"matchLabels": ($run_labels * {"homelab-talos/role": "request"})}, "ingress": [], "egress": [$dns, {"toEndpoints": [{"matchLabels": ($run_labels * {"homelab-talos/role": "n8n", "k8s:io.kubernetes.pod.namespace": "automation"})}], "toPorts": [{"ports": [{"port": "5678", "protocol": "TCP"}]}]}]}
        }
      ] | .[] | split_doc'
}

restore_job_manifest() {
  local kind="$1" name command namespace role host user secret_name secret_key mounts volumes extra_env
  case "$kind" in
    automation-data)
      name="$ad_restore_job"; command="$(automation_data_restore_job_command)"
      namespace="$ad_namespace"; role='ad-restore'; host="$ad_service"
      user='postgres'; secret_name='postgresql-credentials'; secret_key='postgres-superuser-password'
      mounts='[{"name":"backups","mountPath":"/backups","readOnly":true},{"name":"post-recovery","mountPath":"/post-recovery"},{"name":"scripts","mountPath":"/scripts/backup.sh","subPath":"backup.sh","readOnly":true},{"name":"scripts","mountPath":"/scripts/update-backup-status.sql","subPath":"update-backup-status.sql","readOnly":true},{"name":"tmp","mountPath":"/tmp"}]'
      volumes='[{"name":"backups","persistentVolumeClaim":{"claimName":"automation-data-postgresql-backups","readOnly":true}},{"name":"post-recovery","emptyDir":{}},{"name":"scripts","configMap":{"name":"automation-data-postgresql-backup","defaultMode":365}},{"name":"tmp","emptyDir":{}}]'
      extra_env='[{"name":"BACKUP_DIR","value":"/backups"},{"name":"POST_RECOVERY_BACKUP_DIR","value":"/post-recovery"},{"name":"AUTOMATION_DATA_BACKUP_PASSWORD","valueFrom":{"secretKeyRef":{"name":"postgresql-credentials","key":"backup-password"}}}]'
      ;;
    n8n)
      name="$n8n_restore_job"; command="$(n8n_restore_job_command)"
      namespace="$n8n_namespace"; role='n8n-restore'; host="$n8n_service"
      user='n8n'; secret_name='postgresql-credentials'; secret_key='n8n-password'
      mounts='[{"name":"backups","mountPath":"/backups","readOnly":true},{"name":"tmp","mountPath":"/tmp"}]'
      volumes='[{"name":"backups","persistentVolumeClaim":{"claimName":"n8n-postgresql-backups","readOnly":true}},{"name":"tmp","emptyDir":{}}]'
      extra_env='[{"name":"RESTORE_DATABASE","value":"n8n"}]'
      ;;
    *) return 2 ;;
  esac
  JOB_NAME="$name" NAMESPACE="$namespace" ROLE="$role" RUN_HASH="$run_hash" \
    JOB_COMMAND="$command" PGHOST_VALUE="$host" PGUSER_VALUE="$user" \
    SECRET_NAME="$secret_name" SECRET_KEY="$secret_key" \
    MOUNTS="$mounts" VOLUMES="$volumes" EXTRA_ENV="$extra_env" \
    yq --null-input --output-format yaml '
      {
        "apiVersion": "batch/v1", "kind": "Job",
        "metadata": {"name": strenv(JOB_NAME), "namespace": strenv(NAMESPACE), "labels": {
          "homelab-talos/test": "automation-data-restore-drill", "homelab-talos/run-id": strenv(RUN_HASH), "homelab-talos/role": strenv(ROLE)
        }},
        "spec": {"activeDeadlineSeconds": 1800, "backoffLimit": 0, "template": {
          "metadata": {"labels": {"homelab-talos/test": "automation-data-restore-drill", "homelab-talos/run-id": strenv(RUN_HASH), "homelab-talos/role": strenv(ROLE)}},
          "spec": {
            "automountServiceAccountToken": false, "restartPolicy": "Never",
            "securityContext": {"fsGroup": 70, "fsGroupChangePolicy": "OnRootMismatch", "runAsNonRoot": true, "runAsUser": 70, "runAsGroup": 70, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [{
              "name": "restore", "image": "postgres:17.11-alpine3.24", "imagePullPolicy": "IfNotPresent",
              "command": ["/bin/sh", "-ceu"], "args": [strenv(JOB_COMMAND)],
              "env": ([
                {"name": "PGHOST", "value": strenv(PGHOST_VALUE)}, {"name": "PGPORT", "value": "5432"},
                {"name": "PGUSER", "value": strenv(PGUSER_VALUE)},
                {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {"name": strenv(SECRET_NAME), "key": strenv(SECRET_KEY)}}}
              ] + (strenv(EXTRA_ENV) | from_json)),
              "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"memory": "512Mi"}},
              "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "readOnlyRootFilesystem": true},
              "volumeMounts": (strenv(MOUNTS) | from_json)
            }],
            "volumes": (strenv(VOLUMES) | from_json)
          }
        }}
      }'
}

n8n_application_manifests() {
  local ad_cluster_ip="$1"
  # shellcheck disable=SC2016 # yq evaluates its own variables.
  APP_NAME="$n8n_app" N8N_DB_SERVICE="$n8n_service" AD_CLUSTER_IP="$ad_cluster_ip" \
    RUN_HASH="$run_hash" yq --null-input --output-format yaml '
      {"homelab-talos/test": "automation-data-restore-drill", "homelab-talos/run-id": strenv(RUN_HASH), "homelab-talos/role": "n8n"} as $run_labels |
      [
        {
          "apiVersion": "apps/v1", "kind": "Deployment",
          "metadata": {"name": strenv(APP_NAME), "namespace": "automation", "labels": $run_labels},
          "spec": {"replicas": 1, "strategy": {"type": "Recreate"}, "selector": {"matchLabels": $run_labels}, "template": {
            "metadata": {"labels": $run_labels}, "spec": {
              "automountServiceAccountToken": false,
              "hostAliases": [{"ip": strenv(AD_CLUSTER_IP), "hostnames": ["automation-data-postgresql", "automation-data-postgresql.automation-data.svc.cluster.local"]}],
              "securityContext": {"fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
              "containers": [{
                "name": "n8n", "image": "docker.n8n.io/n8nio/n8n:2.36.7", "imagePullPolicy": "IfNotPresent",
                "ports": [{"name": "http", "containerPort": 5678}],
                "env": [
                  {"name": "DB_TYPE", "value": "postgresdb"}, {"name": "DB_POSTGRESDB_HOST", "value": strenv(N8N_DB_SERVICE)},
                  {"name": "DB_POSTGRESDB_PORT", "value": "5432"}, {"name": "DB_POSTGRESDB_DATABASE", "value": "n8n"},
                  {"name": "DB_POSTGRESDB_USER", "value": "n8n"}, {"name": "DB_POSTGRESDB_SCHEMA", "value": "public"},
                  {"name": "DB_POSTGRESDB_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "postgresql-credentials", "key": "n8n-password"}}},
                  {"name": "N8N_ENCRYPTION_KEY", "valueFrom": {"secretKeyRef": {"name": "n8n-runtime", "key": "N8N_ENCRYPTION_KEY"}}},
                  {"name": "N8N_PORT", "value": "5678"}, {"name": "N8N_PROTOCOL", "value": "http"},
                  {"name": "N8N_HOST", "value": (strenv(APP_NAME) + ".automation.svc.cluster.local")},
                  {"name": "N8N_WEBHOOK_URL", "value": ("http://" + strenv(APP_NAME) + ".automation.svc.cluster.local:5678/")},
                  {"name": "N8N_EDITOR_BASE_URL", "value": ("http://" + strenv(APP_NAME) + ".automation.svc.cluster.local:5678/")},
                  {"name": "N8N_DIAGNOSTICS_ENABLED", "value": "false"}, {"name": "N8N_VERSION_NOTIFICATIONS_ENABLED", "value": "false"},
                  {"name": "N8N_PERSONALIZATION_ENABLED", "value": "false"}
                ],
                "readinessProbe": {"httpGet": {"path": "/healthz", "port": "http"}, "periodSeconds": 5, "failureThreshold": 120},
                "resources": {"requests": {"cpu": "100m", "memory": "256Mi"}, "limits": {"memory": "1Gi"}},
                "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "runAsNonRoot": true, "runAsUser": 1000, "runAsGroup": 1000},
                "volumeMounts": [{"name": "data", "mountPath": "/home/node/.n8n"}]
              }],
              "volumes": [{"name": "data", "emptyDir": {}}]
            }
          }}
        },
        {
          "apiVersion": "v1", "kind": "Service",
          "metadata": {"name": strenv(APP_NAME), "namespace": "automation", "labels": $run_labels},
          "spec": {"type": "ClusterIP", "selector": $run_labels, "ports": [{"name": "http", "port": 5678, "targetPort": "http"}]}
        }
      ] | .[] | split_doc'
}

request_job_manifest() {
  local request_script
  request_script="$(cat <<'EOF'
const endpoint = `http://${process.env.APP_NAME}.automation.svc.cluster.local:5678/webhook/automation-data-recovery-canary`;
const response = await fetch(endpoint, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Platform-Canary': process.env.CANARY_TOKEN}, body: '{}', signal: AbortSignal.timeout(60000)});
if (!response.ok) throw new Error(`Recovery canary returned HTTP ${response.status}`);
const body = await response.json();
const keys = Object.keys(body).sort();
if (JSON.stringify(keys) !== JSON.stringify(['database','executionId','role','status'])) throw new Error('Unexpected recovery response keys');
if (body.status !== 'ok' || body.database !== 'issue317_acceptance' || body.role !== 'issue317_acceptance_runtime' || typeof body.executionId !== 'string' || body.executionId.length === 0) throw new Error('Restored runtime identity mismatch');
console.log('restored_runtime_credential=authenticated');
EOF
)"
  REQUEST_JOB="$request_job" APP_NAME="$n8n_app" RUN_HASH="$run_hash" \
    REQUEST_SCRIPT="$request_script" \
    yq --null-input --output-format yaml '
      {
        "apiVersion": "batch/v1", "kind": "Job",
        "metadata": {"name": strenv(REQUEST_JOB), "namespace": "gatus", "labels": {
          "homelab-talos/test": "automation-data-restore-drill", "homelab-talos/run-id": strenv(RUN_HASH), "homelab-talos/role": "request"
        }},
        "spec": {"activeDeadlineSeconds": 300, "backoffLimit": 0, "template": {
          "metadata": {"labels": {"homelab-talos/test": "automation-data-restore-drill", "homelab-talos/run-id": strenv(RUN_HASH), "homelab-talos/role": "request"}},
          "spec": {"automountServiceAccountToken": false, "restartPolicy": "Never", "securityContext": {"runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [{
              "name": "request", "image": "docker.n8n.io/n8nio/n8n:2.36.7", "imagePullPolicy": "IfNotPresent",
              "command": ["node", "--input-type=module", "--eval"],
              "args": [strenv(REQUEST_SCRIPT)],
              "env": [
                {"name": "APP_NAME", "value": strenv(APP_NAME)},
                {"name": "CANARY_TOKEN", "valueFrom": {"secretKeyRef": {"name": "n8n-canary", "key": "token"}}},
                {"name": "HOME", "value": "/tmp"}
              ],
              "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "128Mi"}},
              "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "readOnlyRootFilesystem": true, "runAsNonRoot": true, "runAsUser": 1000, "runAsGroup": 1000},
              "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}]
            }], "volumes": [{"name": "tmp", "emptyDir": {}}]
          }
        }}
      }'
}

cleanup() {
  local original_exit="$?" cleanup_ok=true
  trap - EXIT INT TERM
  set +e
  "${k_request[@]}" delete job "$request_job" --ignore-not-found --wait=true --timeout=2m >/dev/null 2>&1 || cleanup_ok=false
  "${k_n8n[@]}" delete deployment "$n8n_app" --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || cleanup_ok=false
  for namespace_and_targets in \
    "$ad_namespace job/$ad_restore_job statefulset/$ad_database service/$ad_service ciliumnetworkpolicy/$ad_policy pvc/$ad_data_pvc" \
    "$n8n_namespace job/$n8n_restore_job statefulset/$n8n_database service/$n8n_service service/$n8n_app ciliumnetworkpolicy/$n8n_policy pvc/$n8n_data_pvc" \
    "$request_namespace ciliumnetworkpolicy/$request_policy"; do
    read -r target_namespace rest <<<"$namespace_and_targets"
    for target in $rest; do
      kubectl --kubeconfig "$kubeconfig" --namespace "$target_namespace" delete "$target" \
        --ignore-not-found --wait=true --timeout=5m >/dev/null 2>&1 || cleanup_ok=false
    done
  done
  for namespace_and_targets in \
    "$ad_namespace job/$ad_restore_job statefulset/$ad_database service/$ad_service ciliumnetworkpolicy/$ad_policy pvc/$ad_data_pvc" \
    "$n8n_namespace job/$n8n_restore_job statefulset/$n8n_database service/$n8n_service deployment/$n8n_app service/$n8n_app ciliumnetworkpolicy/$n8n_policy pvc/$n8n_data_pvc" \
    "$request_namespace job/$request_job ciliumnetworkpolicy/$request_policy"; do
    read -r target_namespace rest <<<"$namespace_and_targets"
    for target in $rest; do
      resource_absent "$target_namespace" "$target" >/dev/null 2>&1 || cleanup_ok=false
    done
  done
  if [[ "$cleanup_ok" == 'true' ]]; then
    write_phase cleanup passed 'all run-owned workloads, policies, Services, Jobs, and PVCs are absent'
  else
    write_phase cleanup failed 'one or more run-owned restore resources remain'
  fi
  [[ "$cleanup_ok" == 'true' ]] || exit 1
  exit "$original_exit"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_lease
routes_json="$(kubectl --kubeconfig "$kubeconfig" get \
  httproutes.gateway.networking.k8s.io --all-namespaces --output json)"
if n8n_routes_target_service "$n8n_namespace" "$n8n_app" \
  <(printf '%s\n' "$routes_json"); then
  echo 'Refusing restore drill because an HTTPRoute already targets its temporary Service name.' >&2
  exit 1
fi
for namespace_and_targets in \
  "$ad_namespace job/$ad_restore_job statefulset/$ad_database service/$ad_service ciliumnetworkpolicy/$ad_policy pvc/$ad_data_pvc" \
  "$n8n_namespace job/$n8n_restore_job statefulset/$n8n_database service/$n8n_service deployment/$n8n_app service/$n8n_app ciliumnetworkpolicy/$n8n_policy pvc/$n8n_data_pvc" \
  "$request_namespace job/$request_job ciliumnetworkpolicy/$request_policy"; do
  read -r target_namespace rest <<<"$namespace_and_targets"
  for target in $rest; do
    resource_absent "$target_namespace" "$target" || {
      echo "Refusing to adopt existing $target_namespace/$target." >&2
      exit 1
    }
  done
done

verify_lease
policy_manifests | "${k_cluster[@]}" create --filename - >/dev/null
platform_manifests | "${k_cluster[@]}" create --filename - >/dev/null
"${k_ad[@]}" rollout status "statefulset/$ad_database" --timeout=10m >/dev/null
"${k_n8n[@]}" rollout status "statefulset/$n8n_database" --timeout=10m >/dev/null

verify_lease
restore_job_manifest automation-data | "${k_ad[@]}" create --filename - >/dev/null
wait_for_job_terminal "$ad_restore_job" 1800 5 "${k_ad[@]}"
ad_restore_output="$("${k_ad[@]}" logs "job/$ad_restore_job" --tail=20)"
selected_bundle="$(sed -n 's/^selected_bundle=//p' <<<"$ad_restore_output" | tail -n 1)"
post_recovery_bundle="$(sed -n 's/^post_recovery_bundle=//p' <<<"$ad_restore_output" | tail -n 1)"
[[ "$selected_bundle" =~ ^automation-data-[0-9]{8}T[0-9]{6}Z$ && \
  "$post_recovery_bundle" =~ ^automation-data-[0-9]{8}T[0-9]{6}Z$ ]] || {
  echo 'The automation-data restore Job omitted bounded bundle evidence.' >&2
  exit 1
}

verify_lease
restore_job_manifest n8n | "${k_n8n[@]}" create --filename - >/dev/null
wait_for_job_terminal "$n8n_restore_job" 1800 5 "${k_n8n[@]}"
selected_n8n_dump="$("${k_n8n[@]}" logs "job/$n8n_restore_job" --tail=20 | sed -n 's/^selected_dump=//p' | tail -n 1)"
[[ "$selected_n8n_dump" =~ ^n8n-postgresql-[0-9]{8}T[0-9]{6}Z\.dump$ ]] || {
  echo 'The n8n restore Job omitted bounded dump evidence.' >&2
  exit 1
}

ad_cluster_ip="$("${k_ad[@]}" get service "$ad_service" --output jsonpath='{.spec.clusterIP}')"
[[ "$ad_cluster_ip" =~ ^[0-9a-fA-F:.]+$ && "$ad_cluster_ip" != 'None' ]] || {
  echo 'The isolated automation-data Service has no usable ClusterIP.' >&2
  exit 1
}

verify_lease
n8n_application_manifests "$ad_cluster_ip" | "${k_n8n[@]}" create --filename - >/dev/null
"${k_n8n[@]}" rollout status "deployment/$n8n_app" --timeout=20m >/dev/null

# This drill creates no HTTPRoute. Recheck after Service creation so the restored
# n8n instance remains internal even if unrelated cluster state changed mid-run.
routes_json="$(kubectl --kubeconfig "$kubeconfig" get \
  httproutes.gateway.networking.k8s.io --all-namespaces --output json)"
if n8n_routes_target_service "$n8n_namespace" "$n8n_app" \
  <(printf '%s\n' "$routes_json"); then
  echo 'Restore drill Service gained an HTTPRoute after creation.' >&2
  exit 1
fi

verify_lease
request_job_manifest | "${k_request[@]}" create --filename - >/dev/null
wait_for_job_terminal "$request_job" 600 5 "${k_request[@]}"
[[ "$("${k_request[@]}" logs "job/$request_job" --tail=1)" == \
  'restored_runtime_credential=authenticated' ]] || {
  echo 'The restored recovery canary did not return bounded authentication evidence.' >&2
  exit 1
}

RUN_HASH="$run_hash" SELECTED_N8N_DUMP="$selected_n8n_dump" \
  SELECTED_AUTOMATION_BUNDLE="$selected_bundle" POST_RECOVERY_BUNDLE="$post_recovery_bundle" \
  yq --null-input --output-format json '{
    "runHash": strenv(RUN_HASH),
    "selectedN8nDump": strenv(SELECTED_N8N_DUMP),
    "selectedAutomationDataBundle": strenv(SELECTED_AUTOMATION_BUNDLE),
    "restoredRuntimeCredentialAuthenticated": true,
    "restoredPermissionSeparationValidated": true,
    "postRecoveryBundle": strenv(POST_RECOVERY_BUNDLE),
    "productionMutation": false
  }' >"$run_dir/automation-data-restore-evidence.json"
write_phase assertion passed 'isolated n8n and automation-data restores, credential authentication, permission separation, and fresh backup passed'
echo "automation-data full-chain restore drill passed with $selected_n8n_dump and $selected_bundle; $post_recovery_bundle was created after recovery. Cleanup will remove all run-owned resources and PVCs."
