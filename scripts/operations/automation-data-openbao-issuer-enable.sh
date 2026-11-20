#!/usr/bin/env bash
# Give the specification 036 OpenBao issuer a password login. Only the issuer reset
# command (scripts/openbao/database_issuer.py) runs this; it supplies the password on
# stdin and then has OpenBao rotate it. The value exists in the cluster only in a
# run-scoped Secret that cleanup deletes.
set -euo pipefail

source scripts/lib/common.sh
source scripts/lib/rollout.sh
source scripts/lib/lease.sh
source scripts/lib/n8n-verification.sh
source scripts/lib/automation-data-bootstrap.sh
source scripts/test/lib/job.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: automation-data-openbao-issuer-enable.sh <kubeconfig> < password' >&2
  exit 2
}
[[ "${AUTOMATION_DATA_OPENBAO_ISSUER_ENABLE_CONFIRM:-}" == 'enable:automation-data:openbao-issuer' ]] || {
  echo 'Run the issuer reset command instead: just kube automation-data-openbao-issuer-reset.' >&2
  exit 1
}
[[ ! -t 0 ]] || {
  echo 'The issuer password must arrive on stdin.' >&2
  exit 1
}
IFS= read -r password || true
[[ "${#password}" -ge 32 ]] || {
  echo 'The issuer enable step requires a password of at least 32 characters on stdin.' >&2
  exit 1
}
kubeconfig="$1"
[[ -f "$kubeconfig" ]] || {
  echo 'Missing operator kubeconfig.' >&2
  exit 1
}
kc=(kubectl --kubeconfig "$kubeconfig" --namespace automation-data)
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)"
job="automation-data-openbao-issuer-${run_id,,}"
secret="$job"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-openbao-issuer.XXXXXX")"
lease_acquired=false
created_jobs=()
secret_created=false

job_absent() { [[ -z "$("${kc[@]}" get job "$1" --ignore-not-found --output name)" ]]; }
verify_lease() {
  [[ ! -e "$temp_dir/lease-failed" ]] && verify_test_lease_holder "$kubeconfig" "$run_id"
}
source_guard() {
  local remote_ref remote_sha revision state
  local -a source_paths=(
    scripts/operations/automation-data-openbao-issuer-enable.sh scripts/openbao scripts/lib
    scripts/verify/automation-data.sh scripts/test/lib/job.sh
    kubernetes/mod.just kubernetes/apps/automation-data/postgresql
  )
  require_deployed_source 'automation-data OpenBao issuer enablement' "${source_paths[@]}"
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
  if [[ "$secret_created" == true ]]; then
    state="$("${kc[@]}" get secret "$secret" --ignore-not-found --output json)" || cleanup_ok=false
    if [[ -n "$state" && "$(yq -r '.metadata.labels."homelab-talos/run-id"' <<<"$state")" == "$run_id" ]]; then
      "${kc[@]}" delete secret "$secret" --wait=true --timeout=1m >/dev/null || cleanup_ok=false
    elif [[ -n "$state" ]]; then
      cleanup_ok=false
    fi
    [[ -z "$("${kc[@]}" get secret "$secret" --ignore-not-found --output name)" ]] || cleanup_ok=false
  fi
  if [[ "$lease_acquired" == true ]]; then release_test_lease "$kubeconfig" "$run_id" >/dev/null || cleanup_ok=false; fi
  rm -rf -- "$temp_dir"
  if [[ "$cleanup_ok" != true ]]; then
    echo 'Issuer enablement cleanup failed; inspect run-owned Jobs, Secrets and Lease.' >&2
    exit 1
  fi
  echo "openbao_issuer_cleanup=passed run=$run_id"
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
  echo 'Refusing to adopt an existing enablement Job.' >&2
  exit 1
}
[[ -z "$("${kc[@]}" get secret "$secret" --ignore-not-found --output name)" ]] || {
  echo 'Refusing to adopt an existing issuer password Secret.' >&2
  exit 1
}
configmap="$(automation_data_access_sessions_configmap "$temp_dir" "${kc[@]}")"
# Recheck the run Lease and Job absence immediately before the role change.
verify_lease
job_absent "$job"
# The password travels only through pipes, never argv or a file.
secret_created=true
printf '%s' "$password" |
  "${kc[@]}" create secret generic "$secret" --from-file=password=/dev/stdin \
    --dry-run=client --output json |
  RUN_ID="$run_id" yq -o=json '.metadata.labels."homelab-talos/run-id" = strenv(RUN_ID)' |
  "${kc[@]}" create --filename - >/dev/null
unset password
automation_data_openbao_issuer_enable_job_manifest "$job" "$run_id" "$configmap" "$secret" \
  >"$temp_dir/enable.yaml"
created_jobs+=("$job")
"${kc[@]}" create --filename "$temp_dir/enable.yaml" >/dev/null
wait_for_job_terminal "$job" 300 2 "${kc[@]}"
[[ "$("${kc[@]}" logs "job/$job" --tail=1)" == 'openbao_issuer_login=enabled' ]]
echo "openbao_issuer_login=enabled run=$run_id"
