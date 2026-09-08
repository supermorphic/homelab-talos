#!/usr/bin/env bash
# Prove the installed platform revision and a complete post-upgrade logical backup.
set -euo pipefail
set +x

[[ "$#" -eq 1 ]] || {
  echo 'Usage: platform-preflight.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
namespace='automation-data'
job_name=''
expected_revision='026-nocodb-v1'
temp_dir=''
run_marker=''
job_cleanup_pending=false

job_name_if_present() {
  local found
  found="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job \
    "$job_name" --ignore-not-found --output name 2>/dev/null)" || {
    echo "Could not determine whether $namespace/$job_name exists." >&2
    return 1
  }
  case "$found" in
    '') ;;
    job.batch/"$job_name") printf '%s\n' "$found" ;;
    *)
      echo "Unexpected identity returned for $namespace/$job_name." >&2
      return 1
      ;;
  esac
}

delete_owned_job() {
  local job_json remaining
  job_json="$(kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" get job \
    "$job_name" --ignore-not-found --output json 2>/dev/null)" || {
    echo "Could not inspect run-owned Job $namespace/$job_name." >&2
    return 1
  }
  [[ -n "$job_json" ]] || return 0
  jq -e --arg marker "$run_marker" --arg name "$job_name" '
    .metadata.name == $name and
    .metadata.labels."homelab-talos/role" == "nocodb-platform-preflight" and
    .metadata.labels."homelab-talos/run-id" == $marker
  ' >/dev/null <<<"$job_json" || {
    echo "Refusing to delete $namespace/$job_name because its run ownership differs." >&2
    return 1
  }
  kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" delete job \
    "$job_name" --wait=true --timeout=2m >/dev/null || return 1
  remaining="$(job_name_if_present)" || return 1
  [[ -z "$remaining" ]] || {
    echo "Failed to prove removal of run-owned Job $namespace/$job_name." >&2
    return 1
  }
}

cleanup_preflight() {
  local original_exit="$?" cleanup_failed=false
  trap - EXIT
  set +e
  if [[ "$job_cleanup_pending" == true ]]; then
    delete_owned_job || cleanup_failed=true
  fi
  [[ -z "$temp_dir" ]] || rm -rf -- "$temp_dir" || cleanup_failed=true
  set -e
  if [[ "$cleanup_failed" == true ]]; then
    echo "Failed to remove the run-owned Job $namespace/$job_name." >&2
    exit 1
  fi
  exit "$original_exit"
}
trap cleanup_preflight EXIT

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-platform-preflight.XXXXXX")"
chmod 700 "$temp_dir"
run_suffix="${temp_dir##*.}"
run_suffix="${run_suffix,,}"
run_marker="preflight-${run_suffix}-$$"
run_marker="${run_marker//_/-}"
job_name="nocodb-platform-${run_marker}"

[[ -z "$(job_name_if_present)" ]] || {
  echo "Refusing NocoDB platform preflight: $namespace/$job_name already exists." >&2
  exit 1
}

render_job() {
  local metadata_body_md5
  metadata_body_md5="$(awk '
    /^AS \$function\$/ { body = 1; print ""; next }
    /^\$function\$;/ { body = 0 }
    body { print }
  ' kubernetes/apps/automation-data/postgresql/app/scripts/nocodb-metadata.sql |
    openssl dgst -md5 -r | awk '{print $1}')"
  [[ "$metadata_body_md5" =~ ^[0-9a-f]{32}$ ]] || return 1
  # shellcheck disable=SC2016 # yq renders the fixed in-container shell and SQL literals.
  JOB_NAME="$job_name" RUN_ID="$run_marker" METADATA_BODY_MD5="$metadata_body_md5" yq --null-input --output-format yaml '
    {
      "apiVersion": "batch/v1",
      "kind": "Job",
      "metadata": {
        "name": strenv(JOB_NAME),
        "namespace": "automation-data",
        "labels": {
          "app.kubernetes.io/name": "automation-data-postgresql-backup",
          "homelab-talos/role": "nocodb-platform-preflight",
          "homelab-talos/run-id": strenv(RUN_ID)
        }
      },
      "spec": {
        "activeDeadlineSeconds": 120,
        "backoffLimit": 0,
        "template": {
          "metadata": {"labels": {
            "app.kubernetes.io/name": "automation-data-postgresql-backup",
            "homelab-talos/role": "nocodb-platform-preflight",
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
              "name": "preflight",
              "image": "postgres:17.11-alpine3.24",
              "imagePullPolicy": "IfNotPresent",
              "command": ["/bin/sh", "-ceu"],
              "args": [
                "result=\"$(psql --no-psqlrc --quiet --no-align --tuples-only --set=ON_ERROR_STOP=1 <<'\''SQL'\''\n\\getenv expected_metadata_body NOCODB_METADATA_BODY_MD5\nBEGIN TRANSACTION READ ONLY;\nSELECT oracle.revision || '\''|'\'' ||\n  CASE WHEN backup.completed_at >= revision.installed_at THEN '\''true'\'' ELSE '\''false'\'' END\nFROM (SELECT platform_operations.read_platform_revision() AS revision) AS oracle\nJOIN platform_operations.platform_schema_revision AS revision\n  ON revision.singleton AND revision.revision = oracle.revision\nJOIN platform_operations.logical_backup_status AS backup ON backup.singleton\nWHERE (SELECT md5(prosrc) FROM pg_proc\n  WHERE oid = '\''platform_operations.provision_nocodb_metadata(text)'\''::regprocedure) = :'\''expected_metadata_body'\'';\nCOMMIT;\nSQL\n)\"\nresult=\"$(printf '\''%s\\n'\'' \"$result\" | sed '\''/^$/d'\'')\"\n[ \"$result\" = '\''026-nocodb-v1|true'\'' ]\nprintf '\''%s\\n'\'' '\''installed_revision=026-nocodb-v1'\'' '\''post_upgrade_backup=true'\''"
              ],
              "env": [
                {"name": "NOCODB_METADATA_BODY_MD5", "value": strenv(METADATA_BODY_MD5)},
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
              }
            }]
          }
        }
      }
    }
  '
}

job_cleanup_pending=true
if ! render_job | kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" \
  create --filename - >/dev/null; then
  echo 'The fixed NocoDB platform preflight Job create response was ambiguous.' >&2
  exit 1
fi

if ! kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" wait \
  --for=condition=Complete "job/$job_name" --timeout=2m >/dev/null; then
  echo 'The fixed NocoDB platform preflight Job did not complete.' >&2
  exit 1
fi

job_output="$temp_dir/job-output"
kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" logs "job/$job_name" \
  --container=preflight >"$job_output"
[[ "$(cat "$job_output")" == $'installed_revision=026-nocodb-v1\npost_upgrade_backup=true' ]] || {
  echo 'The NocoDB platform preflight did not prove the fixed revision and post-upgrade backup.' >&2
  exit 1
}

delete_owned_job
job_cleanup_pending=false
trap - EXIT
rm -rf -- "$temp_dir"
temp_dir=''
printf 'installed_revision=%s\n' "$expected_revision"
printf '%s\n' 'post_upgrade_backup=true'
