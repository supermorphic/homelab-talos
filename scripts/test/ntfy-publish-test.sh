#!/usr/bin/env bash
# Offline behavior tests for the exact-confirmed positive ntfy publish scenario.
# PATH stubs exercise the real verifier and scenario without cluster access, credentials,
# or live notifications.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

scenario='scripts/test/scenarios/ntfy-publish.sh'
[[ -x "$scenario" ]] || {
  echo "Missing executable ntfy publish scenario: $scenario" >&2
  exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-ntfy-publish-test-fixture.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
stub_bin="$fixture/bin"
event_log="$fixture/events.log"
kubeconfig="$fixture/kubeconfig"
mkdir -p "$stub_bin"
touch "$kubeconfig"

seerr_token='tk_fixture_seerr_not_a_live_secret'
alertmanager_token='tk_fixture_alertmanager_not_a_live_secret'
homepage_token='tk_fixture_homepage_not_a_live_secret'
export NTFY_TEST_EVENT_LOG="$event_log"
export NTFY_TEST_SEERR_TOKEN="$seerr_token"
export NTFY_TEST_ALERTMANAGER_TOKEN="$alertmanager_token"
export NTFY_TEST_HOMEPAGE_TOKEN="$homepage_token"

cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'observation' >>"$NTFY_TEST_EVENT_LOG"
case " $* " in
  *' config get-contexts homelab-diagnostic --no-headers '*) ;;
  *' --namespace flux-system get kustomization ntfy '*) printf 'True\n' ;;
  *' --namespace ntfy get helmrelease ntfy '*) printf 'True\n' ;;
  *' --namespace ntfy rollout status deployment/ntfy '*) ;;
  *' --namespace ntfy get pvc ntfy '*) printf 'Bound\n' ;;
  *' --namespace ntfy exec deployment/ntfy -c app -- ntfy --log-level=ERROR access '*)
    printf '%s\n' \
      'user subscriber (role: user, tier: none, server config)' \
      '- read-only access to topic critical (server config)' \
      '- read-only access to topic homelab (server config)' \
      '- read-only access to topic media (server config)'
    ;;
  *' --namespace ntfy exec deployment/ntfy -c app -- sh -c '*)
    printf 'alertmanager:%s,seerr:%s,homepage:%s' \
      "$NTFY_TEST_ALERTMANAGER_TOKEN" "$NTFY_TEST_SEERR_TOKEN" "$NTFY_TEST_HOMEPAGE_TOKEN"
    ;;
  *' --namespace homepage exec deployment/homepage -c homepage -- sh -c '*)
    printf '%s' "$NTFY_TEST_HOMEPAGE_TOKEN"
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$stub_bin/kubectl"

cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == '--config' ]]; then
  config="${2:-}"
  [[ -f "$config" ]] || exit 64
  url="$(awk -F'"' '/^url = / {print $2}' "$config")"
  topic="${url##*/}"
  printf 'publish:%s\n' "$topic" >>"$NTFY_TEST_EVENT_LOG"
  if [[ "$topic" == "${NTFY_TEST_FAIL_TOPIC:-}" ]]; then
    printf '503'
  else
    printf '200'
  fi
  exit 0
fi

url="${*: -1}"
case "$url" in
  */v1/health) printf '{"healthy":true}\n' ;;
  */critical/json* )
    if [[ " $* " == *"$NTFY_TEST_HOMEPAGE_TOKEN"* ]]; then printf '200'; else printf '403'; fi
    ;;
  */homelab/json*|*/media/json*) printf '403' ;;
  */critical) printf '403' ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$stub_bin/curl"

cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'kube foundation-verify' ]] || exit 64
printf '%s\n' 'verification-complete' >>"$NTFY_TEST_EVENT_LOG"
EOF
chmod +x "$stub_bin/just"

case_name=''
OUT=''
STATUS=0
fail() {
  echo "FAIL [$case_name]: $1" >&2
  exit 1
}

run_publish() { # <confirmation|-for-unset> [failed-topic]
  local confirmation="$1" failed_topic="${2:-}"
  : >"$event_log"
  set +e
  if [[ "$confirmation" == '-' ]]; then
    OUT="$(PATH="$stub_bin:$PATH" NTFY_TEST_FAIL_TOPIC="$failed_topic" \
      env -u NTFY_PUBLISH_TEST_CONFIRM "$scenario" "$kubeconfig" 2>&1)"
  else
    OUT="$(PATH="$stub_bin:$PATH" NTFY_TEST_FAIL_TOPIC="$failed_topic" \
      NTFY_PUBLISH_TEST_CONFIRM="$confirmation" "$scenario" "$kubeconfig" 2>&1)"
  fi
  STATUS=$?
  set -e
}

assert_status() {
  [[ "$STATUS" -eq "$1" ]] || fail "expected status $1, got $STATUS: $OUT"
}
assert_contains() {
  rg -Fq -- "$1" <<<"$OUT" || fail "output missing '$1': $OUT"
}
assert_no_sensitive_output() {
  local sensitive
  for sensitive in \
    "$seerr_token" \
    "$alertmanager_token" \
    "$homepage_token" \
    'seerr->media positive ACL test' \
    'alertmanager->critical positive ACL test' \
    'alertmanager->homelab positive ACL test'; do
    ! rg -Fq -- "$sensitive" <<<"$OUT" || fail "output exposed sensitive value: $sensitive"
  done
}

case_name='missing confirmation'
run_publish -
assert_status 1
assert_contains "set NTFY_PUBLISH_TEST_CONFIRM='test:ntfy:publish:media-critical-homelab'"
[[ ! -s "$event_log" ]] || fail 'missing confirmation reached verifier or publish commands'
assert_no_sensitive_output

case_name='wrong confirmation'
run_publish 'test:ntfy:publish:wrong'
assert_status 1
assert_contains "set NTFY_PUBLISH_TEST_CONFIRM='test:ntfy:publish:media-critical-homelab'"
[[ ! -s "$event_log" ]] || fail 'wrong confirmation reached verifier or publish commands'
assert_no_sensitive_output

case_name='three positive publishes'
run_publish 'test:ntfy:publish:media-critical-homelab'
assert_status 0
assert_contains 'ntfy positive publish test passed; three test notifications were delivered.'
[[ "$(rg -c '^publish:' "$event_log")" == '3' ]] || fail 'expected exactly three POSTs'
[[ "$(rg '^publish:' "$event_log")" == $'publish:media\npublish:critical\npublish:homelab' ]] ||
  fail 'positive POST topics or order changed'
verification_line="$(rg -n '^verification-complete$' "$event_log" | cut -d: -f1)"
first_publish_line="$(rg -n '^publish:' "$event_log" | head -1 | cut -d: -f1)"
[[ -n "$verification_line" && "$verification_line" -lt "$first_publish_line" ]] ||
  fail 'positive POST ran before the observational verifier completed'
assert_no_sensitive_output

case_name='non-200 publish response'
run_publish 'test:ntfy:publish:media-critical-homelab' critical
assert_status 1
assert_contains 'alertmanager could not publish the positive ACL test to critical.'
[[ "$(rg '^publish:' "$event_log")" == $'publish:media\npublish:critical' ]] ||
  fail 'publish did not stop at the first non-200 response'
assert_no_sensitive_output

echo 'ntfy positive publish scenario tests passed.'
