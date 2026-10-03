#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/n8n-verification.sh
# shellcheck source=scripts/test/lib/job.sh
source scripts/test/lib/job.sh
source scripts/test/lib/owned-resources.sh
# shellcheck source=scripts/test/lib/n8n-restore-command.sh
source scripts/test/lib/n8n-restore-command.sh
source scripts/lib/lease.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: n8n-restore-drill.sh <kubeconfig>' >&2
  exit 2
}

# Refuse before kubeconfig inspection or any Kubernetes request. The catalog
# coordinator enforces the same exact confirmation before it acquires the Lease.
expected_confirmation='restore:n8n-postgresql:temporary'
[[ "${N8N_RESTORE_DRILL_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing n8n restore drill: set N8N_RESTORE_DRILL_CONFIRM=$expected_confirmation after reviewing the temporary-database cleanup procedure." >&2
  exit 1
}

kubeconfig="$1"
run_dir="${HOMELAB_TEST_RUN_DIR:-}"
[[ -n "$run_dir" && -d "$run_dir" ]] || {
  echo 'Refusing n8n restore drill outside the catalog run coordinator.' >&2
  exit 1
}
[[ -f "$kubeconfig" ]] || {
  echo 'The restore drill requires the selected invocation config.' >&2
  exit 1
}

run_id="$(basename "$run_dir")"
run_hash="$(printf '%s' "$run_id" | shasum -a 256 | cut -c1-12)"
lease_holder="${TEST_CAMPAIGN_LEASE_HOLDER:-$run_id}"
database_name="n8n_restore_$run_hash"
resource_prefix="n8n-restore-$run_hash"
restore_job="$resource_prefix-load"
drop_job="$resource_prefix-drop"
deployment="$resource_prefix"
service="$resource_prefix"
automation_policy="$resource_prefix-automation"
request_policy="$resource_prefix-request"
request_job="$resource_prefix-request"
automation_namespace='automation'
request_namespace='gatus'
k_auto=(kubectl --kubeconfig "$kubeconfig" --namespace "$automation_namespace")
k_request=(kubectl --kubeconfig "$kubeconfig" --namespace "$request_namespace")
k_cluster=(kubectl --kubeconfig "$kubeconfig")
database_possible=false
ledger="$run_dir/diagnostics/n8n-owned.jsonl"
[[ ! -e "$ledger" ]] || {
  echo 'Refusing to overwrite prior restore ownership evidence.' >&2
  exit 1
}
: >"$ledger"

automation_resource_absent() {
  local target="$1" resource
  resource="$("${k_auto[@]}" get "$target" --ignore-not-found --output name)" || return 1
  [[ -z "$resource" ]]
}

request_resource_absent() {
  local target="$1" resource
  resource="$("${k_request[@]}" get "$target" --ignore-not-found --output name)" || return 1
  [[ -z "$resource" ]]
}

write_phase() {
  local phase="$1" phase_status="$2" reason="$3"
  PHASE_STATUS="$phase_status" PHASE_REASON="$reason" \
    yq --null-input --output-format json '{
      "status": strenv(PHASE_STATUS),
      "reason": strenv(PHASE_REASON)
    }' >"$run_dir/$phase.json"
}

write_phase assertion not-classified 'restore validation has not completed'
write_phase cleanup not-classified 'cleanup has not run'
write_phase recovery not-required 'the production database and workloads are not modified by this drill'

verify_lease() {
  verify_test_lease_holder "$kubeconfig" "$lease_holder" || {
    echo 'The shared state-changing test Lease is absent, expired, or owned by another run.' >&2
    return 1
  }
}

policy_manifest() {
  # shellcheck disable=SC2016 # yq evaluates strenv; generated policy values are literal.
  AUTOMATION_POLICY_NAME="$automation_policy" REQUEST_POLICY_NAME="$request_policy" \
  RUN_HASH="$run_hash" \
    yq --null-input --output-format yaml --expression '
      [{
        "apiVersion": "cilium.io/v2",
        "kind": "CiliumNetworkPolicy",
        "metadata": {
          "name": strenv(AUTOMATION_POLICY_NAME),
          "namespace": "automation",
          "labels": {
            "homelab-talos/test": "n8n-restore-drill",
            "homelab-talos/run-id": strenv(RUN_HASH)
          }
        },
        "specs": [
          {
            "endpointSelector": {"matchLabels": {
              "homelab-talos/test": "n8n-restore-drill",
              "homelab-talos/run-id": strenv(RUN_HASH),
              "homelab-talos/role": "n8n"
            }},
            "ingress": [{
              "fromEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "gatus",
                "homelab-talos/test": "n8n-restore-drill",
                "homelab-talos/run-id": strenv(RUN_HASH),
                "homelab-talos/role": "request"
              }}],
              "toPorts": [{"ports": [{"port": "5678", "protocol": "TCP"}]}]
            }],
            "egress": [
              {
                "toEndpoints": [{"matchLabels": {
                  "k8s:io.kubernetes.pod.namespace": "kube-system",
                  "k8s:k8s-app": "kube-dns"
                }}],
                "toPorts": [{"ports": [
                  {"port": "53", "protocol": "UDP"},
                  {"port": "53", "protocol": "TCP"}
                ]}]
              },
              {
                "toEndpoints": [{"matchLabels": {
                  "k8s:io.kubernetes.pod.namespace": "automation",
                  "app.kubernetes.io/name": "n8n-postgresql"
                }}],
                "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}]
              }
            ]
          },
          {
            "endpointSelector": {"matchLabels": {
              "homelab-talos/test": "n8n-restore-drill",
              "homelab-talos/run-id": strenv(RUN_HASH),
              "homelab-talos/role": "database-helper"
            }},
            "ingress": [],
            "egress": [
              {
                "toEndpoints": [{"matchLabels": {
                  "k8s:io.kubernetes.pod.namespace": "kube-system",
                  "k8s:k8s-app": "kube-dns"
                }}],
                "toPorts": [{"ports": [
                  {"port": "53", "protocol": "UDP"},
                  {"port": "53", "protocol": "TCP"}
                ]}]
              },
              {
                "toEndpoints": [{"matchLabels": {
                  "k8s:io.kubernetes.pod.namespace": "automation",
                  "app.kubernetes.io/name": "n8n-postgresql"
                }}],
                "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}]
              }
            ]
          },
          {
            "endpointSelector": {"matchLabels": {
              "app.kubernetes.io/name": "n8n-postgresql"
            }},
            "ingress": [{
              "fromEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "automation",
                "homelab-talos/test": "n8n-restore-drill",
                "homelab-talos/run-id": strenv(RUN_HASH)
              }}],
              "toPorts": [{"ports": [{"port": "5432", "protocol": "TCP"}]}]
            }]
          }
        ]
      },
      {
        "apiVersion": "cilium.io/v2",
        "kind": "CiliumNetworkPolicy",
        "metadata": {
          "name": strenv(REQUEST_POLICY_NAME),
          "namespace": "gatus",
          "labels": {
            "homelab-talos/test": "n8n-restore-drill",
            "homelab-talos/run-id": strenv(RUN_HASH)
          }
        },
        "spec": {
          "endpointSelector": {"matchLabels": {
            "homelab-talos/test": "n8n-restore-drill",
            "homelab-talos/run-id": strenv(RUN_HASH),
            "homelab-talos/role": "request"
          }},
          "ingress": [],
          "egress": [
            {
              "toEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "kube-system",
                "k8s:k8s-app": "kube-dns"
              }}],
              "toPorts": [{"ports": [
                {"port": "53", "protocol": "UDP"},
                {"port": "53", "protocol": "TCP"}
              ]}]
            },
            {
              "toEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "automation",
                "homelab-talos/test": "n8n-restore-drill",
                "homelab-talos/run-id": strenv(RUN_HASH),
                "homelab-talos/role": "n8n"
              }}],
              "toPorts": [{"ports": [{"port": "5678", "protocol": "TCP"}]}]
            }
          ]
        }
      }] | .[] | split_doc'
}

database_job_manifest() {
  local name="$1" operation="$2" helper volume_mounts_json volumes_json
  if [[ "$operation" == 'restore' ]]; then
    helper='/helpers/n8n-restore-load.sh'
    volume_mounts_json='[{"name":"helpers","mountPath":"/helpers","readOnly":true},{"name":"backups","mountPath":"/backups","readOnly":true},{"name":"tmp","mountPath":"/tmp"}]'
    volumes_json='[{"name":"helpers","configMap":{"name":"n8n-test-helpers-v1"}},{"name":"backups","persistentVolumeClaim":{"claimName":"n8n-postgresql-backups","readOnly":true}},{"name":"tmp","emptyDir":{}}]'
  elif [[ "$operation" == 'drop' ]]; then
    helper='/helpers/n8n-restore-drop.sh'
    volume_mounts_json='[{"name":"helpers","mountPath":"/helpers","readOnly":true},{"name":"tmp","mountPath":"/tmp"}]'
    volumes_json='[{"name":"helpers","configMap":{"name":"n8n-test-helpers-v1"}},{"name":"tmp","emptyDir":{}}]'
  else
    return 2
  fi
  # shellcheck disable=SC2016 # yq emits literal environment and fixture references.
  JOB_NAME="$name" OPERATION="$operation" RUN_HASH="$run_hash" \
  DATABASE_NAME="$database_name" HELPER="$helper" \
  VOLUME_MOUNTS_JSON="$volume_mounts_json" VOLUMES_JSON="$volumes_json" \
    yq --null-input --output-format yaml --expression '
      {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
          "name": strenv(JOB_NAME),
          "namespace": "automation",
          "labels": {
            "homelab-talos/test": "n8n-restore-drill",
            "homelab-talos/run-id": strenv(RUN_HASH),
            "homelab-talos/role": "database-helper"
          }
        },
        "spec": {
          "activeDeadlineSeconds": 1800,
          "backoffLimit": 0,
          "template": {
            "metadata": {"labels": {
              "homelab-talos/test": "n8n-restore-drill",
              "homelab-talos/run-id": strenv(RUN_HASH),
              "homelab-talos/role": "database-helper"
            }},
            "spec": {
              "automountServiceAccountToken": false,
              "restartPolicy": "Never",
              "securityContext": {
                "fsGroup": 70,
                "fsGroupChangePolicy": "OnRootMismatch",
                "runAsGroup": 70,
                "runAsNonRoot": true,
                "runAsUser": 70,
                "seccompProfile": {"type": "RuntimeDefault"}
              },
              "containers": [{
                "name": "restore",
                "image": "postgres:17.11-alpine3.24",
                "imagePullPolicy": "IfNotPresent",
                "command": ["/bin/sh", "-eu", strenv(HELPER)],
                "env": [
                  {"name": "PGHOST", "value": "n8n-postgresql.automation.svc.cluster.local"},
                  {"name": "PGPORT", "value": "5432"},
                  {"name": "PGUSER", "value": "postgres"},
                  {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {
                    "name": "postgresql-credentials",
                    "key": "postgres-superuser-password"
                  }}},
                  {"name": "RESTORE_DATABASE", "value": strenv(DATABASE_NAME)}
                ],
                "resources": {
                  "requests": {"cpu": "50m", "memory": "64Mi"},
                  "limits": {"memory": "512Mi"}
                },
                "securityContext": {
                  "allowPrivilegeEscalation": false,
                  "capabilities": {"drop": ["ALL"]},
                  "readOnlyRootFilesystem": true
                },
                "volumeMounts": (strenv(VOLUME_MOUNTS_JSON) | from_json)
              }],
              "volumes": (strenv(VOLUMES_JSON) | from_json)
            }
          }
        }
      }'
}

application_manifests() {
  # shellcheck disable=SC2016 # yq evaluates strenv; generated env values are literal.
  APP_NAME="$deployment" RUN_HASH="$run_hash" DATABASE_NAME="$database_name" \
    yq --null-input --output-format yaml --expression '
      [{
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
          "name": strenv(APP_NAME),
          "namespace": "automation",
          "labels": {"homelab-talos/test": "n8n-restore-drill", "homelab-talos/run-id": strenv(RUN_HASH), "homelab-talos/role": "n8n"}
        },
        "spec": {
          "replicas": 1,
          "strategy": {"type": "Recreate"},
          "selector": {"matchLabels": {
            "homelab-talos/test": "n8n-restore-drill",
            "homelab-talos/run-id": strenv(RUN_HASH),
            "homelab-talos/role": "n8n"
          }},
          "template": {
            "metadata": {"labels": {
              "homelab-talos/test": "n8n-restore-drill",
              "homelab-talos/run-id": strenv(RUN_HASH),
              "homelab-talos/role": "n8n"
            }},
            "spec": {
              "automountServiceAccountToken": false,
              "securityContext": {"fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
              "containers": [{
                "name": "n8n",
                "image": "docker.n8n.io/n8nio/n8n:2.36.7",
                "imagePullPolicy": "IfNotPresent",
                "ports": [{"name": "http", "containerPort": 5678, "protocol": "TCP"}],
                "env": [
                  {"name": "DB_TYPE", "value": "postgresdb"},
                  {"name": "DB_POSTGRESDB_HOST", "value": "n8n-postgresql.automation.svc.cluster.local"},
                  {"name": "DB_POSTGRESDB_PORT", "value": "5432"},
                  {"name": "DB_POSTGRESDB_DATABASE", "value": strenv(DATABASE_NAME)},
                  {"name": "DB_POSTGRESDB_USER", "value": "n8n"},
                  {"name": "DB_POSTGRESDB_SCHEMA", "value": "public"},
                  {"name": "DB_POSTGRESDB_PASSWORD", "valueFrom": {"secretKeyRef": {
                    "name": "postgresql-credentials", "key": "n8n-password"
                  }}},
                  {"name": "N8N_ENCRYPTION_KEY", "valueFrom": {"secretKeyRef": {
                    "name": "n8n-runtime", "key": "N8N_ENCRYPTION_KEY"
                  }}},
                  {"name": "N8N_PORT", "value": "5678"},
                  {"name": "N8N_PROTOCOL", "value": "http"},
                  {"name": "N8N_HOST", "value": (strenv(APP_NAME) + ".automation.svc.cluster.local")},
                  {"name": "N8N_WEBHOOK_URL", "value": ("http://" + strenv(APP_NAME) + ".automation.svc.cluster.local:5678/")},
                  {"name": "N8N_EDITOR_BASE_URL", "value": ("http://" + strenv(APP_NAME) + ".automation.svc.cluster.local:5678/")},
                  {"name": "N8N_DIAGNOSTICS_ENABLED", "value": "false"},
                  {"name": "N8N_VERSION_NOTIFICATIONS_ENABLED", "value": "false"},
                  {"name": "N8N_PERSONALIZATION_ENABLED", "value": "false"}
                ],
                "readinessProbe": {"httpGet": {"path": "/healthz", "port": "http"}, "periodSeconds": 5, "failureThreshold": 60},
                "resources": {
                  "requests": {"cpu": "100m", "memory": "256Mi"},
                  "limits": {"memory": "1Gi"}
                },
                "securityContext": {
                  "allowPrivilegeEscalation": false,
                  "capabilities": {"drop": ["ALL"]},
                  "runAsGroup": 1000,
                  "runAsNonRoot": true,
                  "runAsUser": 1000
                },
                "volumeMounts": [{"name": "data", "mountPath": "/home/node/.n8n"}]
              }],
              "volumes": [{"name": "data", "emptyDir": {}}]
            }
          }
        }
      },
      {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
          "name": strenv(APP_NAME),
          "namespace": "automation",
          "labels": {"homelab-talos/test": "n8n-restore-drill", "homelab-talos/run-id": strenv(RUN_HASH), "homelab-talos/role": "n8n"}
        },
        "spec": {
          "type": "ClusterIP",
          "selector": {
            "homelab-talos/test": "n8n-restore-drill",
            "homelab-talos/run-id": strenv(RUN_HASH),
            "homelab-talos/role": "n8n"
          },
          "ports": [{"name": "http", "port": 5678, "targetPort": "http", "protocol": "TCP"}]
        }
      }] | .[] | split_doc'
}

request_job_manifest() {
  # shellcheck disable=SC2016 # yq emits this shell program for the request Job.
  REQUEST_NAME="$request_job" APP_NAME="$service" RUN_HASH="$run_hash" \
    yq --null-input --output-format yaml --expression '
      {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
          "name": strenv(REQUEST_NAME),
          "namespace": "gatus",
          "labels": {
            "homelab-talos/test": "n8n-restore-drill",
            "homelab-talos/run-id": strenv(RUN_HASH),
            "homelab-talos/role": "request"
          }
        },
        "spec": {
          "activeDeadlineSeconds": 300,
          "backoffLimit": 0,
          "template": {
            "metadata": {"labels": {
              "homelab-talos/test": "n8n-restore-drill",
              "homelab-talos/run-id": strenv(RUN_HASH),
              "homelab-talos/role": "request"
            }},
            "spec": {
              "automountServiceAccountToken": false,
              "restartPolicy": "Never",
              "securityContext": {"runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}},
              "containers": [{
                "name": "request",
                "image": "docker.n8n.io/n8nio/n8n:2.36.7",
                "imagePullPolicy": "IfNotPresent",
                "command": ["node", "/helpers/n8n-restore-request.mjs"],
                "env": [
                  {"name": "APP_NAME", "value": strenv(APP_NAME)},
                  {"name": "RUN_HASH", "value": strenv(RUN_HASH)},
                  {"name": "CANARY_TOKEN", "valueFrom": {"secretKeyRef": {
                    "name": "n8n-canary", "key": "token"
                  }}},
                  {"name": "HOME", "value": "/tmp"}
                ],
                "resources": {
                  "requests": {"cpu": "10m", "memory": "32Mi"},
                  "limits": {"memory": "128Mi"}
                },
                "securityContext": {
                  "allowPrivilegeEscalation": false,
                  "capabilities": {"drop": ["ALL"]},
                  "readOnlyRootFilesystem": true,
                  "runAsGroup": 1000,
                  "runAsNonRoot": true,
                  "runAsUser": 1000
                },
                "volumeMounts": [{"name": "helpers", "mountPath": "/helpers", "readOnly": true}, {"name": "tmp", "mountPath": "/tmp"}]
              }],
              "volumes": [{"name": "helpers", "configMap": {"name": "n8n-test-request-helpers-v1"}}, {"name": "tmp", "emptyDir": {}}]
            }
          }
        }
      }'
}

cleanup() {
  local original_exit="$?" cleanup_ok=true
  trap - EXIT INT TERM
  set +e

  test_delete_owned "$ledger" Job "$request_namespace" "$request_job" "${k_request[@]}" || cleanup_ok=false
  test_delete_owned "$ledger" Deployment "$automation_namespace" "$deployment" "${k_auto[@]}" || cleanup_ok=false
  test_delete_owned "$ledger" Service "$automation_namespace" "$service" "${k_auto[@]}" || cleanup_ok=false

  if [[ "$database_possible" == true ]]; then
    if verify_lease &&
      database_job_manifest "$drop_job" drop | test_create_owned_stream "$ledger" "${k_auto[@]}" &&
      wait_for_job_terminal "$drop_job" 600 2 "${k_auto[@]}" >/dev/null 2>&1; then
      :
    else
      cleanup_ok=false
    fi
  fi

  for job in "$restore_job" "$drop_job"; do
    test_delete_owned "$ledger" Job "$automation_namespace" "$job" "${k_auto[@]}" || cleanup_ok=false
  done
  test_delete_owned "$ledger" CiliumNetworkPolicy "$request_namespace" "$request_policy" "${k_request[@]}" || cleanup_ok=false
  test_delete_owned "$ledger" CiliumNetworkPolicy "$automation_namespace" "$automation_policy" "${k_auto[@]}" || cleanup_ok=false

  request_resource_absent "job/$request_job" >/dev/null 2>&1 || cleanup_ok=false
  request_resource_absent "ciliumnetworkpolicy/$request_policy" >/dev/null 2>&1 || cleanup_ok=false
  for target in "job/$restore_job" "job/$drop_job" "deployment/$deployment" "service/$service" "ciliumnetworkpolicy/$automation_policy"; do
    automation_resource_absent "$target" >/dev/null 2>&1 || cleanup_ok=false
  done

  if [[ "$cleanup_ok" == 'true' ]]; then
    write_phase cleanup passed 'temporary database and every run-owned Kubernetes resource are absent'
  else
    write_phase cleanup failed 'temporary database or one or more run-owned Kubernetes resources could not be removed'
  fi
  set -e
  if [[ "$cleanup_ok" != true && "$original_exit" == 0 ]]; then original_exit=1; fi
  exit "$original_exit"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_lease
for target in "job/$restore_job" "job/$drop_job" "deployment/$deployment" "service/$service" "ciliumnetworkpolicy/$automation_policy"; do
  automation_resource_absent "$target" || {
    echo "Refusing to adopt $automation_namespace/$target or proceed without proving its absence." >&2
    exit 1
  }
done
request_resource_absent "job/$request_job" || {
  echo "Refusing to adopt $request_namespace/job/$request_job or proceed without proving its absence." >&2
  exit 1
}
request_resource_absent "ciliumnetworkpolicy/$request_policy" || {
  echo "Refusing to adopt $request_namespace/ciliumnetworkpolicy/$request_policy or proceed without proving its absence." >&2
  exit 1
}

# There is deliberately no HTTPRoute manifest. Refuse any existing route that
# already targets this run-owned Service name before creating the Service.
routes_json="$(kubectl --kubeconfig "$kubeconfig" get httproutes.gateway.networking.k8s.io --all-namespaces --output json)"
if n8n_routes_target_service automation "$service" <(printf '%s\n' "$routes_json"); then
  echo 'Refusing restore drill because an HTTPRoute already targets its temporary Service name.' >&2
  exit 1
fi

policy_manifest | test_create_owned_stream "$ledger" "${k_cluster[@]}"
verify_lease
database_possible=true
database_job_manifest "$restore_job" restore | test_create_owned_stream "$ledger" "${k_auto[@]}"
wait_for_job_terminal "$restore_job" 1800 2 "${k_auto[@]}"
selected_dump="$("${k_auto[@]}" logs "job/$restore_job" | sed -n 's/^selected_dump=//p' | tail -n 1)"
[[ "$selected_dump" =~ ^n8n-postgresql-[0-9]{8}T[0-9]{6}Z\.dump$ ]] || {
  echo 'The restore Job did not report one checksum-valid final dump.' >&2
  exit 1
}

verify_lease
application_manifests | test_create_owned_stream "$ledger" "${k_auto[@]}"
"${k_auto[@]}" rollout status "deployment/$deployment" --timeout=20m >/dev/null

# Recheck after Service creation. The drill must remain cluster-internal and does
# not create, own, or accept any HTTPRoute.
routes_json="$(kubectl --kubeconfig "$kubeconfig" get httproutes.gateway.networking.k8s.io --all-namespaces --output json)"
if n8n_routes_target_service automation "$service" <(printf '%s\n' "$routes_json"); then
  echo 'Restore drill Service gained an HTTPRoute after creation.' >&2
  exit 1
fi

verify_lease
request_job_manifest | test_create_owned_stream "$ledger" "${k_request[@]}"
wait_for_job_terminal "$request_job" 600 2 "${k_request[@]}"

RUN_HASH="$run_hash" DATABASE_NAME="$database_name" SELECTED_DUMP="$selected_dump" \
  yq --null-input --output-format json '{
    "runHash": strenv(RUN_HASH),
    "temporaryDatabase": strenv(DATABASE_NAME),
    "selectedDump": strenv(SELECTED_DUMP),
    "httpRouteCreated": false,
    "credentialDecryptionProvedByAuthenticatedCanary": true
  }' >"$run_dir/evidence.json"
write_phase assertion passed 'newest checksum-valid dump restored; exact workflow credential binding and negative/authenticated restored canary passed'
echo "n8n temporary restore drill passed with $selected_dump; cleanup will remove the temporary database and run-owned resources."
