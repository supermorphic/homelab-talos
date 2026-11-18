#!/usr/bin/env bash
# Register a specification 036 access capability through the provisioner, or re-read
# an identical registration, and print its validation.
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/rollout.sh
source scripts/lib/lease.sh
source scripts/lib/n8n-verification.sh
source scripts/lib/automation-data-bootstrap.sh
source scripts/test/lib/job.sh
require_bash

[[ "$#" -eq 5 ]] || {
  echo 'Usage: automation-data-capability-register.sh <kubeconfig> <domain> <capability> <schemas> <max-ttl-seconds>' >&2
  exit 2
}
domain="$2" capability="$3" schemas="$4" max_ttl="$5"
if ! [[ "$domain" =~ ^[a-z][a-z0-9_]{0,47}$ && "$capability" =~ ^[a-z][a-z0-9_]{0,23}$ &&
  "$schemas" =~ ^[a-z_][a-z0-9_]{0,62}(,[a-z_][a-z0-9_]{0,62}){0,15}$ &&
  "$max_ttl" =~ ^[1-9][0-9]{1,2}$ ]] || (( max_ttl < 60 || max_ttl > 600 )); then
  echo 'Invalid arguments: schemas is a comma-separated list; max-ttl-seconds is 60-600.' >&2
  exit 2
fi
[[ "${AUTOMATION_DATA_CAPABILITY_REGISTER_CONFIRM:-}" == "register:automation-data:$domain:$capability" ]] || {
  echo "Operator registration requires AUTOMATION_DATA_CAPABILITY_REGISTER_CONFIRM=register:automation-data:$domain:$capability." >&2
  exit 1
}
kubeconfig="$1"
[[ -f "$kubeconfig" ]] || {
  echo 'Missing operator kubeconfig.' >&2
  exit 1
}
kc=(kubectl --kubeconfig "$kubeconfig" --namespace automation-data)
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)"
job="automation-data-capability-${run_id,,}"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-capability.XXXXXX")"
lease_acquired=false
created_jobs=()

job_absent() { [[ -z "$("${kc[@]}" get job "$1" --ignore-not-found --output name)" ]]; }
verify_lease() {
  [[ ! -e "$temp_dir/lease-failed" ]] && verify_test_lease_holder "$kubeconfig" "$run_id"
}
source_guard() {
  local remote_ref remote_sha revision state
  local -a source_paths=(
    scripts/operations/automation-data-capability-register.sh scripts/lib
    scripts/verify/automation-data.sh scripts/test/lib/job.sh
    kubernetes/mod.just kubernetes/apps/automation-data/postgresql
  )
  require_deployed_source 'automation-data access capability registration' "${source_paths[@]}"
  remote_ref="$(git ls-remote --exit-code origin refs/heads/main)"
  read -r remote_sha _ <<<"$remote_ref"
  git diff --quiet "$remote_sha" -- "${source_paths[@]}"
  revision="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
    get gitrepository flux-system --output jsonpath='{.status.artifact.revision}')"
  [[ "$remote_sha" =~ ^[0-9a-f]{40}$ && "${revision##*:}" == "$remote_sha" ]]
  state="$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system \
    get kustomization automation-data-postgresql --output json)"
  n8n_flux_resource_current_ready <(printf '%s\n' "$state")
  [[ "$(yq -r '.status.lastAppliedRevision' <<<"$state")" == *"$remote_sha" ]]
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
    echo 'Command cleanup failed; inspect run-owned Jobs and Lease.' >&2
    exit 1
  fi
  echo "access_capability_cleanup=passed run=$run_id"
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
job_absent "$job" || {
  echo 'Refusing to adopt an existing registration Job.' >&2
  exit 1
}
configmap="$(automation_data_access_sessions_configmap "$temp_dir" "${kc[@]}")"
# Recheck the run Lease and Job absence immediately before registration.
verify_lease
job_absent "$job"
automation_data_capability_register_job_manifest "$job" "$run_id" "$configmap" "$domain" \
  "$capability" "$schemas" "$max_ttl" >"$temp_dir/register.yaml"
created_jobs+=("$job")
"${kc[@]}" create --filename "$temp_dir/register.yaml" >/dev/null
wait_for_job_terminal "$job" 300 2 "${kc[@]}"
# A failed Job already printed its fixed failure reason. The result is metadata only.
"${kc[@]}" logs "job/$job" --tail=1 | jq -ce 'select(.domain and .capability and has("valid"))'
