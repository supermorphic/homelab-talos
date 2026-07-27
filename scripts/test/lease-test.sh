#!/usr/bin/env bash
set -euo pipefail

source scripts/test/lib/lease.sh

state_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-lease-test.XXXXXX")"
trap 'rm -rf -- "$state_dir"' EXIT
state_file="$state_dir/lease.json"

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
  case "$operation" in
    get)
      [[ -f "$state_file" ]] || return 1
      cat "$state_file"
      ;;
    create)
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
[[ "$(yq -r '.spec.holderIdentity' "$state_file")" == 'run-one' ]]
if acquire_test_lease fake-kubeconfig run-two >/dev/null 2>&1; then
  echo 'A live Lease held by another run was acquired.' >&2
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

echo 'Kubernetes test Lease unit tests passed.'
