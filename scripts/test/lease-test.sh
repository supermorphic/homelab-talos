#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/lease.sh

state_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-lease-test.XXXXXX")"
trap 'rm -rf -- "$state_dir"' EXIT
state_file="$state_dir/lease.json"
force_create_error=false
force_replace_conflict="$state_dir/force-replace-conflict"

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
      if [[ -f "$force_replace_conflict" ]]; then
        rm -f "$force_replace_conflict"
        LIVE_TIME="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)" \
          yq --output-format json '
            .metadata.resourceVersion = "8" |
            .spec.holderIdentity = "node:reboot:node-b:fresh-run" |
            .spec.acquireTime = strenv(LIVE_TIME) |
            .spec.renewTime = strenv(LIVE_TIME) |
            .spec.leaseDurationSeconds = 90
          ' "$state_file" >"$state_dir/conflicting.json"
        mv "$state_dir/conflicting.json" "$state_file"
        return 1
      fi
      [[ "$input_version" == "$existing_version" ]] || return 1
      NEXT_VERSION="$((existing_version + 1))" \
        yq --output-format json \
          '.metadata.resourceVersion = strenv(NEXT_VERSION)' \
          <<<"$input" >"$state_file"
      ;;
    *) return 2 ;;
  esac
}

seed_foreign_lease() {
  local holder="$1" timestamp="$2" resource_version="${3:-7}"
  HOLDER="$holder" TIMESTAMP="$timestamp" RESOURCE_VERSION="$resource_version" \
    yq --null-input --output-format json '{
      "apiVersion": "coordination.k8s.io/v1",
      "kind": "Lease",
      "metadata": {
        "namespace": "flux-system",
        "name": "homelab-test-run-lock",
        "resourceVersion": strenv(RESOURCE_VERSION)
      },
      "spec": {
        "holderIdentity": strenv(HOLDER),
        "leaseDurationSeconds": 90,
        "acquireTime": strenv(TIMESTAMP),
        "renewTime": strenv(TIMESTAMP)
      }
    }' >"$state_file"
}

live_time="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
seed_foreign_lease node:maintenance:node-a:run-42 "$live_time"
cp "$state_file" "$state_dir/before-live-denial.json"
if acquire_test_lease fake-kubeconfig local:run >/dev/null 2>&1; then
  echo 'A live foreign Lease was acquired.' >&2
  exit 1
fi
cmp "$state_dir/before-live-denial.json" "$state_file"

seed_foreign_lease node:maintenance:node-a:run-42 \
  '2000-01-01T00:00:00.000000Z'
acquire_test_lease fake-kubeconfig local:reclaimed
[[ "$(yq -r '.metadata.resourceVersion' "$state_file")" == 8 ]]
[[ "$(yq -r '.spec.holderIdentity' "$state_file")" == local:reclaimed ]]

seed_foreign_lease node:maintenance:node-a:run-42 \
  '2000-01-01T00:00:00.000000Z'
: >"$force_replace_conflict"
if acquire_test_lease fake-kubeconfig local:conflicted >/dev/null 2>&1; then
  echo 'A conflicting expired-Lease takeover overwrote the fresh holder.' >&2
  exit 1
fi
[[ "$(yq -r '.metadata.resourceVersion' "$state_file")" == 8 ]]
[[ "$(yq -r '.spec.holderIdentity' "$state_file")" == \
  node:reboot:node-b:fresh-run ]]

acquire_test_lease fake-kubeconfig node:reboot:node-b:fresh-run
verify_test_lease_holder fake-kubeconfig node:reboot:node-b:fresh-run
[[ "$(yq -r '.spec.acquireTime' "$state_file")" =~ \
  ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]]
before_renew_version="$(yq -r '.metadata.resourceVersion' "$state_file")"
renew_test_lease fake-kubeconfig node:reboot:node-b:fresh-run
[[ "$(yq -r '.metadata.resourceVersion' "$state_file")" == \
  "$((before_renew_version + 1))" ]]
[[ "$(yq -r '.spec.renewTime' "$state_file")" =~ \
  ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]]
cp "$state_file" "$state_dir/before-wrong-owner.json"
if renew_test_lease fake-kubeconfig local:not-owner >/dev/null 2>&1; then
  echo 'A non-owner renewed the disruption Lease.' >&2
  exit 1
fi
cmp "$state_dir/before-wrong-owner.json" "$state_file"
if release_test_lease fake-kubeconfig local:not-owner >/dev/null 2>&1; then
  echo 'A non-owner released the disruption Lease.' >&2
  exit 1
fi
cmp "$state_dir/before-wrong-owner.json" "$state_file"

seed_foreign_lease local:expired-owner '2000-01-01T00:00:00.000000Z'
if verify_test_lease_holder fake-kubeconfig local:expired-owner >/dev/null 2>&1; then
  echo 'An expired same-owner Lease was accepted.' >&2
  exit 1
fi

seed_foreign_lease local:release-owner "$live_time"
release_test_lease fake-kubeconfig local:release-owner
[[ -f "$state_file" ]]
[[ "$(yq -r '.spec.holderIdentity // ""' "$state_file")" == '' ]]
[[ "$(yq -r '.metadata.resourceVersion' "$state_file")" == 8 ]]

sleep_calls="$state_dir/sleep.calls"
fake_sleep="$state_dir/fake-sleep"
cat >"$fake_sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${LEASE_TEST_SLEEP_CALLS:?}"
EOF
chmod +x "$fake_sleep"
seed_foreign_lease node:maintenance:node-a:run-42 "$live_time"
renewal_failure="$state_dir/renewal-failed"
LEASE_TEST_SLEEP_CALLS="$sleep_calls" TEST_LEASE_SLEEP="$fake_sleep" \
  start_test_lease_renewal fake-kubeconfig local:renewal "$renewal_failure"
wait "$TEST_LEASE_RENEW_PID" || true
TEST_LEASE_RENEW_PID=''
[[ -f "$renewal_failure" ]]
[[ "$(cat "$sleep_calls")" == 30 ]]

rm -f "$state_file"
force_create_error=true
if lease_error="$(acquire_test_lease fake-kubeconfig rejected-run 1 2>&1)"; then
  echo 'A rejected Lease create unexpectedly succeeded.' >&2
  exit 1
fi
rg -q 'API rejected test Lease fixture' <<<"$lease_error"
rg -q 'Could not acquire test Lease' <<<"$lease_error"

echo 'Kubernetes test Lease unit tests passed.'
