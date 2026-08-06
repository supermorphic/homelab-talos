#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
checker="$repo_root/kubernetes/apps/monitoring/plex-ddns-drift/app/check.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/plex-ddns-drift-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/metrics"

cat >"$fixture/bin/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_CALL_LOG"
[[ " $* " == ' -qO- -T 10 https://api.ipify.org ' ]]
case "$FAKE_LAYOUT" in
  wan-error) exit 1 ;;
  invalid-wan) printf '999.1.2.3\n' ;;
  multi-wan) printf '203.0.113.42\n203.0.113.42\n' ;;
  success-then-error)
    count="$(<"$FAKE_WGET_COUNT")"
    printf '%s' "$((count + 1))" >"$FAKE_WGET_COUNT"
    [[ "$count" == 0 ]] && printf '203.0.113.42\n' || exit 1
    ;;
  *) printf '203.0.113.42\n' ;;
esac
EOF
chmod +x "$fixture/bin/wget"

cat >"$fixture/bin/nslookup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_CALL_LOG"
[[ " $* " == ' plex.lab.supermorphic.com 1.1.1.1 ' ]]
[[ "$FAKE_LAYOUT" != dns-error ]] || exit 1
case "$FAKE_LAYOUT" in
  mismatch) answer='198.51.100.19' ;;
  invalid-dns) answer='300.1.2.3' ;;
  multi-dns)
    printf 'Server: 1.1.1.1\nAddress: 1.1.1.1:53\n\nName: plex.lab.supermorphic.com\nAddress: 203.0.113.42\nAddress: 203.0.113.42\n'
    exit 0
    ;;
  *) answer='203.0.113.42' ;;
esac
printf 'Server: 1.1.1.1\nAddress: 1.1.1.1:53\n\nNon-authoritative answer:\nName: plex.lab.supermorphic.com\nAddress: %s\n' "$answer"
EOF
chmod +x "$fixture/bin/nslookup"

cat >"$fixture/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '+%s' ]]
printf '1700000000\n'
EOF
chmod +x "$fixture/bin/date"

cat >"$fixture/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'mv %s\n' "$*" >>"$FAKE_CALL_LOG"
/bin/mv "$@"
EOF
chmod +x "$fixture/bin/mv"

cat >"$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >>"$FAKE_CALL_LOG"
[[ "$*" == '300' ]]
if [[ "$FAKE_LAYOUT" == success-then-error ]]; then
  count="$(<"$FAKE_SLEEP_COUNT")"
  printf '%s' "$((count + 1))" >"$FAKE_SLEEP_COUNT"
  [[ "$count" == 0 ]] && exit 0
fi
exit 42
EOF
chmod +x "$fixture/bin/sleep"

run_case() {
  local layout="$1"
  rm -rf -- "$fixture/metrics"
  mkdir -p "$fixture/metrics"
  printf 'prior incomplete metrics\n' >"$fixture/metrics/metrics.prom"
  : >"$fixture/calls.log"
  printf '0' >"$fixture/wget-count"
  printf '0' >"$fixture/sleep-count"
  set +e
  PATH="$fixture/bin:$PATH" \
    FAKE_LAYOUT="$layout" \
    FAKE_CALL_LOG="$fixture/calls.log" \
    FAKE_WGET_COUNT="$fixture/wget-count" \
    FAKE_SLEEP_COUNT="$fixture/sleep-count" \
    PLEX_DDNS_METRICS_DIR="$fixture/metrics" \
    "$checker" >"$fixture/$layout.out" 2>"$fixture/$layout.err"
  status="$?"
  set -e
  [[ "$status" == 42 ]] || {
    echo "$layout exited $status instead of the fake sleep sentinel 42." >&2
    cat "$fixture/$layout.err" >&2
    exit 1
  }
  [[ ! -s "$fixture/$layout.err" ]]
  if rg -q '203\.0\.113\.42|198\.51\.100\.19|999\.1\.2\.3|300\.1\.2\.3' "$fixture/$layout.out" "$fixture/$layout.err"; then
    echo "$layout leaked an address to output." >&2
    exit 1
  fi
  [[ "$(find "$fixture/metrics" -maxdepth 1 -type f -name '*.tmp*' | wc -l | tr -d ' ')" == '0' ]]
  rg -q '^mv .*metrics\.prom\.tmp\..* .*metrics/metrics\.prom$' "$fixture/calls.log"
}

assert_metrics() {
  local success="$1" match="$2" last_success="$3"
  metrics="$fixture/metrics/metrics.prom"
  [[ "$(rg -c '^plex_ddns_' "$metrics")" == '3' ]]
  rg -F -q "plex_ddns_check_success $success" "$metrics"
  rg -F -q "plex_ddns_addresses_match $match" "$metrics"
  rg -F -q "plex_ddns_last_success_unixtime $last_success" "$metrics"
  if rg -q 'prior incomplete|203\.0\.113\.42|198\.51\.100\.19' "$metrics"; then
    echo 'Published metrics contain stale content or an address.' >&2
    exit 1
  fi
}

run_case match
assert_metrics 1 1 1700000000
[[ "$(<"$fixture/match.out")" == 'success' ]]

run_case mismatch
assert_metrics 1 0 1700000000
[[ "$(<"$fixture/mismatch.out")" == 'mismatch' ]]

for layout in wan-error dns-error invalid-wan invalid-dns multi-wan multi-dns; do
  run_case "$layout"
  assert_metrics 0 0 0
  [[ "$(<"$fixture/$layout.out")" == 'error' ]]
done

run_case success-then-error
assert_metrics 0 0 1700000000
[[ "$(sed -n '1p' "$fixture/success-then-error.out")" == 'success' ]]
[[ "$(sed -n '2p' "$fixture/success-then-error.out")" == 'error' ]]
[[ "$(rg -c '^sleep 300$' "$fixture/calls.log")" == '2' ]]

echo 'Plex DDNS drift checker tests passed.'
