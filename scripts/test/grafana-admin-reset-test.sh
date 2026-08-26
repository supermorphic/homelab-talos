#!/usr/bin/env bash
# Offline behavior tests for the guarded Grafana database administrator reset.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
just_bin="$(mise exec -- which just)"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-grafana-admin-reset-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
stub_bin="$fixture/bin"
event_log="$fixture/kubectl.log"
mkdir -p "$stub_bin"

cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GRAFANA_RESET_TEST_EVENT_LOG:?}"
args=" $* "

if [[ "$args" == *' get pod '* &&
  "$args" == *' app.kubernetes.io/name=grafana '* ]]; then
  if [[ "${GRAFANA_RESET_TEST_POD_FOUND:-true}" == 'true' ]]; then
    printf 'grafana-fixture-0'
  fi
elif [[ "$args" == *' reset-admin-password '* ]]; then
  [[ "${GRAFANA_RESET_TEST_RESET_OK:-true}" == 'true' ]] && printf 'ok\n'
elif [[ "$args" == *'/api/search?limit=1'* ]]; then
  if [[ "${GRAFANA_RESET_TEST_AUTH_OK:-true}" == 'true' ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
else
  echo "Unexpected kubectl invocation: $*" >&2
  exit 64
fi
EOF
chmod +x "$stub_bin/kubectl"

case_name=''
OUT=''
STATUS=0

fail() {
  echo "FAIL [$case_name]: $1" >&2
  [[ ! -f "$event_log" ]] || sed -n '1,20p' "$event_log" >&2
  exit 1
}

run_reset() { # <confirmation|-> [pod-found] [auth-ok]
  local confirmation="$1"
  local pod_found="${2:-true}"
  local auth_ok="${3:-true}"

  : >"$event_log"
  set +e
  if [[ "$confirmation" == '-' ]]; then
    OUT="$(
      PATH="$stub_bin:$PATH" \
      GRAFANA_RESET_TEST_EVENT_LOG="$event_log" \
      GRAFANA_RESET_TEST_POD_FOUND="$pod_found" \
      GRAFANA_RESET_TEST_AUTH_OK="$auth_ok" \
        env -u GRAFANA_ADMIN_RESET_CONFIRM \
        "$just_bin" kube grafana-admin-reset 2>&1
    )"
  else
    OUT="$(
      PATH="$stub_bin:$PATH" \
      GRAFANA_RESET_TEST_EVENT_LOG="$event_log" \
      GRAFANA_RESET_TEST_POD_FOUND="$pod_found" \
      GRAFANA_RESET_TEST_AUTH_OK="$auth_ok" \
      GRAFANA_ADMIN_RESET_CONFIRM="$confirmation" \
        "$just_bin" kube grafana-admin-reset 2>&1
    )"
  fi
  STATUS="$?"
  set -e
}

assert_status() {
  [[ "$STATUS" -eq "$1" ]] || fail "expected status $1, got $STATUS: $OUT"
}

assert_contains() {
  rg -Fq -- "$1" <<<"$OUT" || fail "output missing '$1': $OUT"
}

exec_count() {
  awk '/ exec / {count++} END {print count + 0}' "$event_log"
}

reset_count() {
  awk '/ reset-admin-password / {count++} END {print count + 0}' "$event_log"
}

auth_count() {
  awk 'index($0, "/api/search?limit=1") {count++} END {print count + 0}' "$event_log"
}

expected_confirmation='reset:monitoring:grafana:admin-password'

case_name='missing confirmation'
run_reset -
assert_status 1
assert_contains "GRAFANA_ADMIN_RESET_CONFIRM='$expected_confirmation'"
[[ "$(exec_count)" == '0' ]] || fail 'missing confirmation reached a mutating pod exec'

case_name='wrong confirmation'
run_reset 'reset:monitoring:grafana:wrong'
assert_status 1
assert_contains "GRAFANA_ADMIN_RESET_CONFIRM='$expected_confirmation'"
[[ "$(exec_count)" == '0' ]] || fail 'wrong confirmation reached a mutating pod exec'

case_name='successful reset and read-back'
run_reset "$expected_confirmation"
assert_status 0
assert_contains 'Grafana DB admin password reset to match the grafana-admin Secret; API auth verified.'
[[ "$(reset_count)" == '1' ]] || fail 'reset did not execute exactly once'
[[ "$(auth_count)" == '1' ]] || fail 'authentication read-back did not execute exactly once'

case_name='failed authentication read-back'
run_reset "$expected_confirmation" true false
assert_status 1
assert_contains 'Grafana admin creds still fail to authenticate after reset.'
[[ "$(reset_count)" == '1' ]] || fail 'reset did not execute exactly once before read-back'
[[ "$(auth_count)" == '1' ]] || fail 'failed authentication read-back did not execute exactly once'

case_name='missing Grafana pod'
run_reset "$expected_confirmation" false
assert_status 1
assert_contains 'No grafana pod found in monitoring.'
[[ "$(exec_count)" == '0' ]] || fail 'missing pod reached a pod exec'

echo 'Grafana administrator reset guard tests passed.'
