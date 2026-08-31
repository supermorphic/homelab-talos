#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/flux-alerts.sh
source scripts/lib/network.sh
# shellcheck source=scripts/test/lib/job.sh
source scripts/test/lib/job.sh
source scripts/test/lib/lease.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: n8n-persistence.sh <kubeconfig>' >&2
  exit 2
}

# This guard must run before kubeconfig inspection or any Kubernetes request. The
# catalog coordinator checks the same value before it acquires the shared Lease.
expected_confirmation='chaos:n8n-persistence'
[[ "${CLUSTER_CHAOS_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing n8n persistence disruption: set CLUSTER_CHAOS_CONFIRM=$expected_confirmation after reviewing the recovery procedure." >&2
  exit 1
}

kubeconfig="$1"
run_dir="${HOMELAB_TEST_RUN_DIR:-}"
[[ -n "$run_dir" && -d "$run_dir" ]] || {
  echo 'Refusing n8n persistence disruption outside the catalog run coordinator.' >&2
  exit 1
}
token="${N8N_CANARY_TOKEN:-}"
[[ "$token" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
  echo 'N8N_CANARY_TOKEN must use only A-Z, a-z, 0-9, _, and -, with at least 32 characters.' >&2
  exit 1
}
[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

namespace='automation'
run_id="$(basename "$run_dir")"
run_hash="$(printf '%s' "$run_id" | shasum -a 256 | cut -c1-12)"
lease_holder="${TEST_CAMPAIGN_LEASE_HOLDER:-$run_id}"
job_prefix="n8n-persistence-$run_hash"
writer_job="$job_prefix-write"
reader_job="$job_prefix-verify"
cleanup_job="$job_prefix-cleanup"
sentinel="/data/.homelab-n8n-persistence-$run_hash"
sentinel_value="homelab-n8n-persistence-$run_hash"
kc=(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace")
tmp_dir=''
sentinel_possible=false
disruption_started=false

write_phase() {
  local phase="$1" phase_status="$2" reason="$3"
  PHASE_STATUS="$phase_status" PHASE_REASON="$reason" \
    yq --null-input --output-format json '{
      "status": strenv(PHASE_STATUS),
      "reason": strenv(PHASE_REASON)
    }' >"$run_dir/$phase.json"
}

write_phase assertion not-classified 'scenario has not completed its primary assertion'
write_phase cleanup not-classified 'cleanup has not run'
write_phase recovery not-required 'no workload disruption has started'

verify_lease() {
  verify_test_lease_holder "$kubeconfig" "$lease_holder" || {
    echo 'The shared state-changing test Lease is absent, expired, or owned by another run.' >&2
    return 1
  }
}

current_n8n_node() {
  "${kc[@]}" get pods --selector app.kubernetes.io/name=n8n --output json |
    yq -r '[.items[] | select(
      ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "") == "True"
    ) | .spec.nodeName] | if length == 1 then .[0] else "" end'
}

job_manifest() {
  local name="$1" node="$2" operation="$3" job_command
  case "$operation" in
    write)
      # shellcheck disable=SC2016 # The helper Job expands these environment variables.
      job_command='umask 077; printf %s "$SENTINEL_VALUE" >"$SENTINEL"; sync; test "$(cat "$SENTINEL")" = "$SENTINEL_VALUE"'
      ;;
    verify-remove)
      # shellcheck disable=SC2016 # The helper Job expands these environment variables.
      job_command='test "$(cat "$SENTINEL")" = "$SENTINEL_VALUE"; rm -f -- "$SENTINEL"; test ! -e "$SENTINEL"'
      ;;
    cleanup)
      # shellcheck disable=SC2016 # The helper Job expands these environment variables.
      job_command='rm -f -- "$SENTINEL"; test ! -e "$SENTINEL"'
      ;;
    *) return 2 ;;
  esac
  # shellcheck disable=SC2016 # yq and the generated Job shell expand these variables.
  JOB_NAME="$name" RUN_HASH="$run_hash" NODE_NAME="$node" \
  SENTINEL="$sentinel" SENTINEL_VALUE="$sentinel_value" JOB_COMMAND="$job_command" \
    yq --null-input --output-format yaml --expression '
      {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
          "name": strenv(JOB_NAME),
          "namespace": "automation",
          "labels": {
            "homelab-talos/test": "n8n-persistence",
            "homelab-talos/run-id": strenv(RUN_HASH)
          }
        },
        "spec": {
          "activeDeadlineSeconds": 300,
          "backoffLimit": 0,
          "template": {
            "metadata": {"labels": {
              "homelab-talos/test": "n8n-persistence",
              "homelab-talos/run-id": strenv(RUN_HASH)
            }},
            "spec": {
              "automountServiceAccountToken": false,
              "nodeName": strenv(NODE_NAME),
              "restartPolicy": "Never",
              "securityContext": {
                "fsGroup": 1000,
                "fsGroupChangePolicy": "OnRootMismatch",
                "seccompProfile": {"type": "RuntimeDefault"}
              },
              "containers": [{
                "name": "sentinel",
                "image": "docker.n8n.io/n8nio/n8n:2.36.7",
                "imagePullPolicy": "IfNotPresent",
                "command": ["/bin/sh", "-ceu"],
                "args": [strenv(JOB_COMMAND)],
                "env": [
                  {"name": "SENTINEL", "value": strenv(SENTINEL)},
                  {"name": "SENTINEL_VALUE", "value": strenv(SENTINEL_VALUE)}
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
                "volumeMounts": [{"name": "data", "mountPath": "/data"}]
              }],
              "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "n8n-data"}}]
            }
          }
        }
      }'
}

job_absent() {
  local name="$1" resource
  resource="$("${kc[@]}" get job "$name" --ignore-not-found --output name)" || return 1
  [[ -z "$resource" ]]
}

run_sentinel_job() {
  local name="$1" node="$2" operation="$3"
  verify_lease
  [[ -n "$node" ]] || {
    echo "Cannot schedule $name because n8n has no single Ready pod node." >&2
    return 1
  }
  job_absent "$name" || {
    echo "Refusing to adopt Job $namespace/$name or proceed without proving its absence." >&2
    return 1
  }
  job_manifest "$name" "$node" "$operation" | "${kc[@]}" create --filename - >/dev/null
  wait_for_job_terminal "$name" 300 2 "${kc[@]}"
  "${kc[@]}" delete job "$name" --wait=true --timeout=2m >/dev/null
  job_absent "$name"
}

canary_check() {
  local correlation response_file curl_config
  correlation="n8n-persistence-$run_hash-$(date -u +%Y%m%dT%H%M%SZ)"
  response_file="$tmp_dir/canary-response.json"
  curl_config="$tmp_dir/canary.curl"
  {
    printf '%s\n' 'silent' 'show-error' 'fail' 'max-time = 30' 'request = "POST"'
    printf 'resolve = "hooks.lab.supermorphic.com:443:%s"\n' "$HOMELAB_PUBLIC_GATEWAY_VIP"
    printf '%s\n' 'header = "Content-Type: application/json"'
    printf 'header = "X-Platform-Canary: %s"\n' "$token"
    printf 'data = "{\\"correlation\\":\\"%s\\"}"\n' "$correlation"
    printf '%s\n' 'url = "https://hooks.lab.supermorphic.com/webhook/platform-canary"'
    printf 'output = "%s"\n' "$response_file"
  } >"$curl_config"
  curl --config "$curl_config"
  [[ "$(yq -r '.status // ""' "$response_file")" == 'ok' && \
    "$(yq -r '.correlation // ""' "$response_file")" == "$correlation" && \
    -n "$(yq -r '.executionId // ""' "$response_file")" ]]
}

backup_freshness_check() {
  local response
  response="$(
    flux_alerts_prometheus_query \
      'https://prometheus.lab.supermorphic.com' \
      "prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}" \
      'n8n_postgresql_backup_last_success_timestamp_seconds{namespace="automation",service="n8n-postgresql"}'
  )"
  # shellcheck disable=SC2016 # yq evaluates $value.
  [[ "$(yq -r '.status // ""' <<<"$response")" == 'success' && \
    "$(yq -r '.data.result | length' <<<"$response")" == '1' && \
    "$(yq -r '.data.result[0].value[1] | tonumber as $value |
      ($value >= (now | to_unix) - 129600 and $value <= (now | to_unix))' \
      <<<"$response")" == 'true' ]]
}

pvc_uids() {
  "${kc[@]}" get persistentvolumeclaims \
    n8n-data n8n-postgresql-data n8n-postgresql-backups --output json |
    yq -r '[.items[] | select(.status.phase == "Bound") | (.metadata.name + "=" + .metadata.uid)] | sort | .[]'
}

cleanup() {
  local original_exit="$?" cleanup_ok=true recovery_ok=true node
  trap - EXIT INT TERM
  set +e

  for job in "$writer_job" "$reader_job" "$cleanup_job"; do
    "${kc[@]}" delete job "$job" --ignore-not-found --wait=true --timeout=2m >/dev/null 2>&1 || cleanup_ok=false
  done
  if [[ "$sentinel_possible" == 'true' ]]; then
    node="$(current_n8n_node 2>/dev/null)"
    if [[ -n "$node" ]]; then
      job_manifest "$cleanup_job" "$node" cleanup | "${kc[@]}" create --filename - >/dev/null 2>&1 &&
        wait_for_job_terminal "$cleanup_job" 300 2 "${kc[@]}" >/dev/null 2>&1 &&
        "${kc[@]}" delete job "$cleanup_job" --wait=true --timeout=2m >/dev/null 2>&1 || cleanup_ok=false
    else
      cleanup_ok=false
    fi
  fi
  for job in "$writer_job" "$reader_job" "$cleanup_job"; do
    job_absent "$job" >/dev/null 2>&1 || cleanup_ok=false
  done

  "${kc[@]}" rollout status deployment/n8n --timeout=10m >/dev/null 2>&1 || recovery_ok=false
  "${kc[@]}" rollout status statefulset/n8n-postgresql --timeout=10m >/dev/null 2>&1 || recovery_ok=false
  if [[ -n "${initial_pvc_uids:-}" ]]; then
    [[ "$(pvc_uids 2>/dev/null)" == "$initial_pvc_uids" ]] || recovery_ok=false
  fi
  if [[ -n "$tmp_dir" ]]; then
    rm -rf -- "$tmp_dir" || cleanup_ok=false
    [[ ! -e "$tmp_dir" ]] || cleanup_ok=false
  fi

  if [[ "$cleanup_ok" == 'true' ]]; then
    write_phase cleanup passed 'all run-owned helper Jobs, the exact sentinel, and the permission-restricted token workspace are absent'
  else
    write_phase cleanup failed 'a run-owned helper resource, exact sentinel, or permission-restricted token workspace could not be removed'
  fi
  if [[ "$disruption_started" == 'false' ]]; then
    write_phase recovery not-required 'the scenario stopped before deleting a workload pod'
  elif [[ "$recovery_ok" == 'true' ]]; then
    write_phase recovery passed 'n8n and PostgreSQL are rolled out and all three claim UIDs are unchanged'
  else
    write_phase recovery failed 'a disrupted workload or retained claim did not recover to its original contract'
  fi
  set -e

  if [[ "$cleanup_ok" != 'true' || "$recovery_ok" != 'true' ]]; then
    exit 1
  fi
  exit "$original_exit"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_lease
initial_pvc_uids="$(pvc_uids)"
[[ "$(wc -l <<<"$initial_pvc_uids" | tr -d ' ')" == '3' ]] || {
  echo 'The three retained n8n claims are not all Bound with stable UIDs.' >&2
  exit 1
}
"${kc[@]}" rollout status deployment/n8n --timeout=10m >/dev/null
"${kc[@]}" rollout status statefulset/n8n-postgresql --timeout=10m >/dev/null

umask 077
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-n8n-persistence.XXXXXX")"
canary_check
backup_freshness_check

n8n_pod_json="$("${kc[@]}" get pods --selector app.kubernetes.io/name=n8n --output json)"
n8n_pod="$(yq -r '.items | if length == 1 then .[0].metadata.name else "" end' - <<<"$n8n_pod_json")"
n8n_uid="$(yq -r '.items | if length == 1 then .[0].metadata.uid else "" end' - <<<"$n8n_pod_json")"
n8n_node="$(yq -r '.items | if length == 1 then .[0].spec.nodeName else "" end' - <<<"$n8n_pod_json")"
[[ -n "$n8n_pod" && -n "$n8n_uid" && -n "$n8n_node" ]] || {
  echo 'Expected exactly one n8n pod before the disruption.' >&2
  exit 1
}

sentinel_possible=true
run_sentinel_job "$writer_job" "$n8n_node" write
verify_lease
disruption_started=true
"${kc[@]}" delete pod "$n8n_pod" --wait=true --timeout=5m >/dev/null
"${kc[@]}" rollout status deployment/n8n --timeout=10m >/dev/null
new_n8n_json="$("${kc[@]}" get pods --selector app.kubernetes.io/name=n8n --output json)"
new_n8n_uid="$(yq -r '.items | if length == 1 then .[0].metadata.uid else "" end' - <<<"$new_n8n_json")"
new_n8n_node="$(yq -r '.items | if length == 1 then .[0].spec.nodeName else "" end' - <<<"$new_n8n_json")"
[[ -n "$new_n8n_uid" && "$new_n8n_uid" != "$n8n_uid" && -n "$new_n8n_node" ]] || {
  echo 'n8n did not return as a new pod after deletion.' >&2
  exit 1
}
run_sentinel_job "$reader_job" "$new_n8n_node" verify-remove
sentinel_possible=false
canary_check
backup_freshness_check

postgresql_json="$("${kc[@]}" get pods --selector app.kubernetes.io/name=n8n-postgresql --output json)"
postgresql_pod="$(yq -r '.items | if length == 1 then .[0].metadata.name else "" end' - <<<"$postgresql_json")"
postgresql_uid="$(yq -r '.items | if length == 1 then .[0].metadata.uid else "" end' - <<<"$postgresql_json")"
[[ -n "$postgresql_pod" && -n "$postgresql_uid" ]] || {
  echo 'Expected exactly one n8n PostgreSQL pod before the disruption.' >&2
  exit 1
}
verify_lease
"${kc[@]}" delete pod "$postgresql_pod" --wait=true --timeout=5m >/dev/null
"${kc[@]}" rollout status statefulset/n8n-postgresql --timeout=10m >/dev/null
new_postgresql_uid="$("${kc[@]}" get pods --selector app.kubernetes.io/name=n8n-postgresql \
  --output json | yq -r '.items | if length == 1 then .[0].metadata.uid else "" end')"
[[ -n "$new_postgresql_uid" && "$new_postgresql_uid" != "$postgresql_uid" ]] || {
  echo 'n8n PostgreSQL did not return as a new pod after deletion.' >&2
  exit 1
}
[[ "$(pvc_uids)" == "$initial_pvc_uids" ]] || {
  echo 'A retained n8n claim UID changed during persistence recovery.' >&2
  exit 1
}
canary_check
backup_freshness_check

RUN_HASH="$run_hash" OLD_N8N_UID="$n8n_uid" NEW_N8N_UID="$new_n8n_uid" \
OLD_POSTGRESQL_UID="$postgresql_uid" NEW_POSTGRESQL_UID="$new_postgresql_uid" \
PVC_UIDS="$initial_pvc_uids" yq --null-input --output-format json '{
  "runHash": strenv(RUN_HASH),
  "n8nPod": {"oldUid": strenv(OLD_N8N_UID), "newUid": strenv(NEW_N8N_UID)},
  "postgresqlPod": {"oldUid": strenv(OLD_POSTGRESQL_UID), "newUid": strenv(NEW_POSTGRESQL_UID)},
  "pvcUids": (strenv(PVC_UIDS) | split("\n"))
}' >"$run_dir/evidence.json"
write_phase assertion passed 'sentinel, authenticated canary, PostgreSQL recovery, and retained claim UID checks passed'
echo "n8n persistence recovery passed; evidence is recorded in $run_dir."
