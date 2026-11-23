#!/usr/bin/env bash
# Run one specification 036 session revocation phase for workstation revocation.
# Only `just kube openbao-workstation revoke` (scripts/openbao/workstation.py) runs
# this: "list" prints the ready capabilities, "suspend" suspends the listed ones, and
# "finish" revokes every registered temporary login and resumes the listed
# capabilities when allowed.
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/rollout.sh
source scripts/lib/lease.sh
source scripts/lib/n8n-verification.sh
source scripts/lib/automation-data-bootstrap.sh
source scripts/test/lib/job.sh
require_bash

listed='[a-z][a-z0-9_]{0,47}:[a-z][a-z0-9_]{0,23}'
[[ ("$#" -eq 2 && "$2" == list) ||
  ("$#" -ge 3 && ("$3" == '' || "$3" =~ ^$listed(,$listed)*$) &&
  (("$#" -eq 3 && "$2" == suspend) ||
  ("$#" -eq 4 && "$2" == finish && "$4" =~ ^(true|false)$))) ]] || {
  echo 'Usage: automation-data-sessions-revoke-all.sh <kubeconfig> list | suspend <capabilities> | finish <capabilities> <true|false>' >&2
  exit 2
}
[[ "${AUTOMATION_DATA_SESSIONS_REVOKE_ALL_CONFIRM:-}" == 'revoke:automation-data:all-sessions' ]] || {
  echo 'Run workstation revocation instead: just kube openbao-workstation revoke agent-workstation.' >&2
  exit 1
}
kubeconfig="$1"
phase="$2"
[[ -f "$kubeconfig" ]] || {
  echo 'Missing operator kubeconfig.' >&2
  exit 1
}
# Workstation revocation holds the shared run Lease for the whole command. Join it;
# acquiring it here would find it held.
lease_holder="${OPENBAO_LEASE_HOLDER:-}"
lease_failure="${OPENBAO_LEASE_FAILURE:-}"
[[ "$lease_holder" =~ ^openbao-[0-9a-f]+$ && "$lease_failure" == /* ]] || {
  echo "Session revocation runs only under workstation revocation's Lease." >&2
  exit 1
}
kc=(kubectl --kubeconfig "$kubeconfig" --namespace automation-data)
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)"
job="automation-data-session-revoke-${run_id,,}"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-session-revoke.XXXXXX")"
created_jobs=()

job_absent() { [[ -z "$("${kc[@]}" get job "$1" --ignore-not-found --output name)" ]]; }
verify_lease() {
  [[ ! -e "$lease_failure" ]] && verify_test_lease_holder "$kubeconfig" "$lease_holder"
}
source_guard() {
  local remote_ref remote_sha revision state
  local -a source_paths=(
    scripts/operations/automation-data-sessions-revoke-all.sh scripts/openbao scripts/lib
    scripts/verify/automation-data.sh scripts/test/lib/job.sh
    kubernetes/mod.just kubernetes/apps/automation-data/postgresql
  )
  require_deployed_source 'automation-data session revocation' "${source_paths[@]}"
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
  rm -rf -- "$temp_dir"
  if [[ "$cleanup_ok" != true ]]; then
    echo 'Session revocation cleanup failed; inspect run-owned Jobs.' >&2
    exit 1
  fi
  echo "session_revocation_cleanup=passed run=$run_id"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_lease
source_guard
scripts/verify/automation-data.sh "$kubeconfig"
verify_lease
source_guard
job_absent "$job" || {
  echo 'Refusing to adopt an existing session revocation Job.' >&2
  exit 1
}
configmap="$(automation_data_access_sessions_configmap "$temp_dir" "${kc[@]}")"
automation_data_session_revocation_job_manifest "$job" "$run_id" "$configmap" "${@:2}" \
  >"$temp_dir/revoke.yaml"
# Recheck the run Lease and Job absence immediately before the change.
verify_lease
job_absent "$job"
created_jobs+=("$job")
"${kc[@]}" create --filename "$temp_dir/revoke.yaml" >/dev/null
wait_for_job_terminal "$job" 300 2 "${kc[@]}"
result="$("${kc[@]}" logs "job/$job" --tail=1)"
if [[ "$phase" == list ]]; then
  [[ "$result" =~ ^session_revocation_ready=(${listed}(,${listed})*)?$ ]]
elif [[ "$phase" == suspend ]]; then
  [[ "$result" =~ ^session_revocation_suspended=(${listed}(,${listed})*)?$ ]]
else
  [[ "$result" =~ ^session_revocation\ revoked=[0-9]+\ failed=[0-9]+\ remaining=[0-9]+\ resumed=(${listed}(,${listed})*)?$ ]]
fi
echo "$result run=$run_id"
