#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/rollout.sh
source scripts/lib/lease.sh
source scripts/lib/n8n-verification.sh
source scripts/lib/automation-data-bootstrap.sh
source scripts/test/lib/job.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: automation-data-control-migrate.sh <kubeconfig>' >&2
  exit 2
}
[[ "${AUTOMATION_DATA_CONTROL_MIGRATE_CONFIRM:-}" == 'migrate:automation-data:control' ]] || {
  echo 'Deactivate the provisioning workflow and drain its executions, then set AUTOMATION_DATA_CONTROL_MIGRATE_CONFIRM=migrate:automation-data:control.' >&2
  exit 1
}
kubeconfig="$1"
[[ -f "$kubeconfig" ]] || {
  echo 'Missing task kubeconfig.' >&2
  exit 1
}
kc=(kubectl --kubeconfig "$kubeconfig" --namespace automation-data)
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)"
job="automation-data-control-${run_id,,}"
backup_job="automation-data-before-control-${run_id,,}"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-migrate.XXXXXX")"
lease_acquired=false
created_jobs=()

job_absent() { [[ -z "$("${kc[@]}" get job "$1" --ignore-not-found --output name)" ]]; }
verify_lease() {
  [[ ! -e "$temp_dir/lease-failed" ]] && verify_test_lease_holder "$kubeconfig" "$run_id"
}
source_guard() {
  local remote_ref remote_sha revision state
  local -a source_paths=(
    scripts/operations/automation-data-control-migrate.sh scripts/lib
    scripts/verify/automation-data.sh scripts/test/lib/job.sh
    kubernetes/mod.just kubernetes/apps/automation-data kubernetes/apps/automation/n8n
  )
  require_deployed_source 'automation-data control migration' "${source_paths[@]}"
  remote_ref="$(git ls-remote --exit-code origin refs/heads/main)"
  read -r remote_sha _ <<<"$remote_ref"
  git diff --quiet "$remote_sha" -- "${source_paths[@]}"
  revision="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
    get gitrepository flux-system --output jsonpath='{.status.artifact.revision}')"
  [[ "$remote_sha" =~ ^[0-9a-f]{40}$ && "${revision##*:}" == "$remote_sha" ]]
  for name in automation-data-postgresql n8n; do
    state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$name" --output json)"
    n8n_flux_resource_current_ready <(printf '%s\n' "$state")
    [[ "$(yq -r '.status.lastAppliedRevision' <<<"$state")" == *"$remote_sha" ]]
  done
}
cleanup() {
  local result="$?" name state cleanup_ok=true
  trap - EXIT INT TERM
  set +e
  for name in "${created_jobs[@]}"; do
    state="$("${kc[@]}" get job "$name" --ignore-not-found --output json)" || {
      cleanup_ok=false
      continue
    }
    if [[ -n "$state" ]]; then
      [[ "$(yq -r '.metadata.labels."homelab-talos/run-id"' <<<"$state")" == "$run_id" ]] || {
        cleanup_ok=false
        continue
      }
      "${kc[@]}" delete job "$name" --wait=true --timeout=2m >/dev/null || cleanup_ok=false
    fi
    job_absent "$name" || cleanup_ok=false
  done
  if [[ "$lease_acquired" == true ]]; then release_test_lease "$kubeconfig" "$run_id" >/dev/null || cleanup_ok=false; fi
  rm -rf -- "$temp_dir"
  if [[ "$cleanup_ok" != true ]]; then
    echo 'Migration cleanup failed; inspect run-owned Jobs and Lease.' >&2
    exit 1
  fi
  echo "control_migration_cleanup=passed run=$run_id"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source_guard
acquire_test_lease "$kubeconfig" "$run_id" >/dev/null
lease_acquired=true
start_test_lease_renewal "$kubeconfig" "$run_id" "$temp_dir/lease-failed"
scripts/verify/automation-data.sh "$kubeconfig"
verify_lease
source_guard
for name in "$backup_job" "$job"; do
  job_absent "$name" || {
    echo 'Refusing to adopt an existing migration Job.' >&2
    exit 1
  }
done
[[ "$("${kc[@]}" get jobs --selector app.kubernetes.io/name=automation-data-postgresql-backup \
  --output json | yq '[.items[] | select((.status.active // 0) > 0)] | length')" == 0 ]] || {
  echo 'An active backup Job prevents the migration backup.' >&2
  exit 1
}
"${kc[@]}" create job "$backup_job" --from=cronjob/automation-data-postgresql-backup \
  --dry-run=client --output yaml |
  RUN_ID="$run_id" yq '
    .metadata.labels."homelab-talos/run-id" = strenv(RUN_ID) |
    .spec.template.metadata.labels."homelab-talos/run-id" = strenv(RUN_ID)
  ' >"$temp_dir/backup.yaml"
created_jobs+=("$backup_job")
"${kc[@]}" create --filename "$temp_dir/backup.yaml" >/dev/null
wait_for_job_terminal "$backup_job" 1800 5 "${kc[@]}"

verify_lease
source_guard
state="$("${kc[@]}" get statefulset automation-data-postgresql --output json)"
n8n_statefulset_current_ready <(printf '%s\n' "$state")
init_configmap="$(yq -r '.spec.template.spec.volumes[] | select(.name == "init") | .configMap.name' <<<"$state")"
[[ "$init_configmap" =~ ^automation-data-postgresql-init-[a-z0-9]+$ ]]
"${kc[@]}" get configmap "$init_configmap" --output json >"$temp_dir/init.json"
python - "$temp_dir/init.json" <<'PYTHON'
import json
import sys
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text())["data"]
base = Path("kubernetes/apps/automation-data/postgresql/app/scripts")
for name in ("platform-control.sql", "migrate-control.sh"):
    if config.get(name) != (base / name).read_text():
        raise SystemExit("Deployed migration inputs differ from reviewed source.")
PYTHON
# Recheck the exact fresh backup and Job absence immediately before SQL mutation.
"${kc[@]}" get job "$backup_job" --output json >"$temp_dir/backup.json"
RUN_ID="$run_id" yq -e '
  .metadata.labels."homelab-talos/run-id" == strenv(RUN_ID) and
  ([.status.conditions[] | select(.type == "Complete" and .status == "True")] | length) == 1
' "$temp_dir/backup.json" >/dev/null
verify_lease
job_absent "$job"
automation_data_control_migration_job_manifest "$job" "$run_id" "$init_configmap" >"$temp_dir/migration.yaml"
created_jobs+=("$job")
"${kc[@]}" create --filename "$temp_dir/migration.yaml" >/dev/null
wait_for_job_terminal "$job" 300 2 "${kc[@]}"
[[ "$("${kc[@]}" logs "job/$job" --tail=1)" == 'control_migration=applied' ]]
echo "control_migration=applied run=$run_id; import the workflow and run attended acceptance before closeout"
