#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-disruption-admission-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

layout="$test_root/layout"
mkdir -p "$layout/lib"
cp "$repo_root/scripts/lib/disruption-admission.sh" "$layout/lib/disruption-admission.sh"
# shellcheck source=scripts/lib/disruption-admission.sh
source "$layout/lib/disruption-admission.sh"

[[ ! -e "$layout/scripts/node" ]] || fail 'The admission helper fixture unexpectedly contains node lifecycle code.'
[[ ! -e "$layout/lib/node-lifecycle-state.sh" ]] || fail 'The admission helper fixture unexpectedly contains lifecycle-state code.'
[[ ! -e "$layout/homelab-playbook" ]] || fail 'The admission helper fixture unexpectedly contains a playbook checkout.'

nodes="$test_root/nodes.json"
calls="$test_root/kubectl.calls"
export DISRUPTION_KUBECTL="$repo_root/tests/fixtures/disruption-admission/fake-kubectl.sh"
export DISRUPTION_TEST_NODES="$nodes"
export DISRUPTION_TEST_CALL_LOG="$calls"

expect_guard() {
  local label="$1" guard="$2" expected="$3" body="$4"
  printf '%s\n' "$body" >"$nodes"
  : >"$calls"
  local status=0
  "$guard" fixture-kubeconfig >/dev/null 2>&1 || status=$?
  if [[ "$expected" == pass && "$status" -ne 0 ]]; then
    fail "$label: expected $guard to pass, got $status."
  fi
  if [[ "$expected" == refuse && "$status" -eq 0 ]]; then
    fail "$label: expected $guard to refuse."
  fi
  [[ "$(cat "$calls")" == '--kubeconfig fixture-kubeconfig get nodes --output json' ]] ||
    fail "$label: $guard used an unexpected Kubernetes request: $(cat "$calls")"
}

ready='{"items":[{"metadata":{"name":"node-a","annotations":{}},"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
unrelated='{"items":[{"metadata":{"name":"node-a","annotations":{"example.invalid/owner":"fixture"}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'

for guard in assert_no_node_containment assert_established_disruption_admissible; do
  expect_guard 'healthy inventory' "$guard" pass "$ready"
  expect_guard 'unrelated annotation' "$guard" pass "$unrelated"

  for record in \
    '' \
    'not-json' \
    '{"schemaVersion":1,"kind":"reboot"}' \
    '{"schemaVersion":1,"kind":"abrupt-loss"}' \
    '{"schemaVersion":1,"kind":"maintenance"}' \
    '{"schemaVersion":999,"kind":"future"}'; do
    RECORD="$record" yq --null-input --output-format json '{
      "items": [{
        "metadata": {
          "name": "node-a",
          "annotations": {"homelab.supermorphic.com/node-lifecycle": strenv(RECORD)}
        },
        "spec": {"unschedulable": false},
        "status": {"conditions": [{"type": "Ready", "status": "True"}]}
      }]
    }' >"$nodes"
    expect_guard "present lifecycle annotation '$record'" "$guard" refuse "$(cat "$nodes")"
  done
done

annotation_only_cases=(
  '{"items":[{"metadata":{"name":"node-a","annotations":{}},"spec":{},"status":{"conditions":[]}}]}'
  '{"items":[{"metadata":{"name":"node-a","annotations":{}},"spec":{"unschedulable":true},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}'
)
for body in "${annotation_only_cases[@]}"; do
  expect_guard 'annotation-only ignores readiness and cordon' assert_no_node_containment pass "$body"
done

established_refusals=(
  '{"items":[{"metadata":{"name":"node-a","annotations":{}},"spec":{},"status":{"conditions":[]}}]}'
  '{"items":[{"metadata":{"name":"node-a","annotations":{}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}'
  '{"items":[{"metadata":{"name":"node-a","annotations":{}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"Unknown"}]}}]}'
  '{"items":[{"metadata":{"name":"node-a","annotations":{}},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"},{"type":"Ready","status":"True"}]}}]}'
  '{"items":[{"metadata":{"name":"node-a","annotations":{}},"spec":{"unschedulable":true},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
  '{"items":[{"metadata":{"name":"node-a","annotations":{}},"spec":{"unschedulable":"false"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
)
for body in "${established_refusals[@]}"; do
  expect_guard 'non-established node' assert_established_disruption_admissible refuse "$body"
done

invalid_inventories=(
  'not-json'
  '{}'
  '{"items":null}'
  '{"items":{}}'
  '{"items":[]}'
  '{"items":[null]}'
  '{"items":[{"metadata":null}]}'
  '{"items":[{"metadata":{"name":""}}]}'
  '{"items":[{"metadata":{"name":"node-a","annotations":[]}}]}'
)
for body in "${invalid_inventories[@]}"; do
  for guard in assert_no_node_containment assert_established_disruption_admissible; do
    expect_guard "malformed inventory '$body'" "$guard" refuse "$body"
  done
done

for guard in assert_no_node_containment assert_established_disruption_admissible; do
  : >"$calls"
  if DISRUPTION_TEST_API_FAILURE=true "$guard" fixture-kubeconfig >/dev/null 2>&1; then
    fail "$guard accepted an API read failure."
  fi
  if "$guard" >/dev/null 2>&1 || "$guard" one two >/dev/null 2>&1; then
    fail "$guard accepted an invalid argument count."
  fi
done

echo 'Disruption admission guard tests passed.'
