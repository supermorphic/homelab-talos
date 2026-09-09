#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/lease.sh

state_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-lease-test.XXXXXX")"
trap 'rm -rf -- "$state_dir"' EXIT
state_file="$state_dir/lease.json"
force_create_error=false
force_get_error=false
operation_log="$state_dir/operations.log"

lease_kubectl() {
  local _kubeconfig="$1"
  shift
  local operation='' input existing_version input_version
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      get|create|replace)
        operation="$1"
        shift
        break
        ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$operation" >>"$operation_log"
  case "$operation" in
    get)
      [[ "$force_get_error" == 'false' ]] || return 1
      [[ -f "$state_file" ]] || return 1
      cat "$state_file"
      ;;
    create)
      if [[ "$force_create_error" == 'true' ]]; then
        echo 'API rejected test Lease fixture.' >&2
        return 1
      fi
      [[ ! -f "$state_file" ]] || return 1
      input="$(cat)"
      yq --output-format json '.metadata.resourceVersion = "1"' \
        <<<"$input" >"$state_file"
      ;;
    replace)
      [[ -f "$state_file" ]] || return 1
      input="$(cat)"
      existing_version="$(yq -r '.metadata.resourceVersion' "$state_file")"
      input_version="$(yq -r '.metadata.resourceVersion' - <<<"$input")"
      [[ "$input_version" == "$existing_version" ]] || return 1
      NEXT_VERSION="$((existing_version + 1))" \
        yq --output-format json \
          '.metadata.resourceVersion = strenv(NEXT_VERSION)' \
          <<<"$input" >"$state_file"
      ;;
    *) return 2 ;;
  esac
}

acquire_test_lease fake-kubeconfig run-one
verify_test_lease_holder fake-kubeconfig run-one
[[ "$(yq -r '.spec.holderIdentity' "$state_file")" == 'run-one' ]]
[[ "$(yq -r '.spec.acquireTime' "$state_file")" =~ \
  ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]]
[[ "$(yq -r '.spec.renewTime' "$state_file")" =~ \
  ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]]
if acquire_test_lease fake-kubeconfig run-two >/dev/null 2>&1; then
  echo 'A live Lease held by another run was acquired.' >&2
  exit 1
fi
if verify_test_lease_holder fake-kubeconfig run-two >/dev/null 2>&1; then
  echo 'A non-holder joined the test Lease.' >&2
  exit 1
fi

renew_test_lease fake-kubeconfig run-one
[[ "$(yq -r '.metadata.resourceVersion' "$state_file")" == '2' ]]
if release_test_lease fake-kubeconfig run-two >/dev/null 2>&1; then
  echo 'A non-holder released the test Lease.' >&2
  exit 1
fi
release_test_lease fake-kubeconfig run-one
[[ "$(yq -r '.spec.holderIdentity // ""' "$state_file")" == '' ]]

OLD_TIME='2000-01-01T00:00:00Z' \
  yq --output-format json '
    .spec.holderIdentity = "abandoned-run" |
    .spec.acquireTime = strenv(OLD_TIME) |
    .spec.renewTime = strenv(OLD_TIME) |
    .spec.leaseDurationSeconds = 1
  ' "$state_file" >"$state_dir/expired.json"
mv "$state_dir/expired.json" "$state_file"
acquire_test_lease fake-kubeconfig reclaimed-run
[[ "$(yq -r '.spec.holderIdentity' "$state_file")" == 'reclaimed-run' ]]

rm -f "$state_file"
force_create_error=true
if lease_error="$(acquire_test_lease fake-kubeconfig rejected-run 1 2>&1)"; then
  echo 'A rejected Lease create unexpectedly succeeded.' >&2
  exit 1
fi
rg -q 'API rejected test Lease fixture' <<<"$lease_error"
rg -q 'Could not acquire test Lease' <<<"$lease_error"

# Publication and other fixed-lock callers can require a Git-precreated Lease.
# A missing object or transient read error must never fall through to create,
# including when the supplied kubeconfig could create it.
: >"$operation_log"
if acquire_test_lease fake-kubeconfig existing-only-missing 1 existing-only \
  >"$state_dir/existing-only-missing.out" 2>&1; then
  echo 'Existing-only acquisition created a missing Lease.' >&2
  exit 1
fi
[[ "$(<"$operation_log")" == 'get' ]]

force_create_error=false
acquire_test_lease fake-kubeconfig existing-only-fixture
: >"$operation_log"
force_get_error=true
if acquire_test_lease fake-kubeconfig existing-only-transient 1 existing-only \
  >"$state_dir/existing-only-transient.out" 2>&1; then
  echo 'Existing-only acquisition accepted a failed Lease read.' >&2
  exit 1
fi
[[ "$(<"$operation_log")" == 'get' ]]
force_get_error=false

echo 'Kubernetes test Lease unit tests passed.'
