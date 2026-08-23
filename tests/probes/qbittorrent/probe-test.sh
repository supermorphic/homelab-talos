#!/usr/bin/env bash
# Offline unit tests for the pure check_* logic in probe.sh. Runs in `just ci` (no
# cluster). It sources probe.sh (whose live main is BASH_SOURCE-guarded) and exercises
# the comparison functions with inline fixtures.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/probes/qbittorrent/probe.sh
source "$here/probe.sh"

pass=0
fail=0
expect_pass() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else echo "expected PASS but failed: ${desc}" >&2; fail=$((fail + 1)); fi
}
expect_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "expected FAIL but passed: ${desc}" >&2; fail=$((fail + 1)); else pass=$((pass + 1)); fi
}
expect_redacted() {
  local desc="$1" expected_status="$2" expected_text="$3" forbidden_one="$4" forbidden_two="$5"
  local output='' actual_status=0
  shift 5

  output="$("$@" 2>&1)" || actual_status=$?
  if [[ "$actual_status" -ne "$expected_status" ]]; then
    echo "unexpected status for redacted-output case: ${desc}" >&2
    fail=$((fail + 1))
    return
  fi
  if [[ "$output" != *"$expected_text"* ]]; then
    echo "missing redacted outcome for case: ${desc}" >&2
    fail=$((fail + 1))
    return
  fi
  if [[ -n "$forbidden_one" && "$output" == *"$forbidden_one"* ]] ||
    [[ -n "$forbidden_two" && "$output" == *"$forbidden_two"* ]]; then
    echo "raw measured value appeared in output for case: ${desc}" >&2
    fail=$((fail + 1))
    return
  fi
  pass=$((pass + 1))
}

expect_pass 'vpn running'                 check_vpn_running running
expect_fail 'vpn stopped'                 check_vpn_running stopped
expect_fail 'vpn unknown'                 check_vpn_running unknown

expect_pass 'country Sweden'              check_country_sweden Sweden
expect_pass 'country sweden lowercase'    check_country_sweden sweden
expect_fail 'country Netherlands'         check_country_sweden Netherlands
expect_fail 'country empty'               check_country_sweden ''

expect_pass 'ports agree'                 check_port_agreement 49103 49103
expect_fail 'forwarded port zero'         check_port_agreement 0 0
expect_fail 'forwarded port empty'        check_port_agreement '' 6881
expect_fail 'ports disagree'              check_port_agreement 49103 6881

expect_pass 'egress equals vpn'           check_egress_matches_vpn 1.2.3.4 1.2.3.4
expect_fail 'egress empty'                check_egress_matches_vpn '' 1.2.3.4
expect_fail 'egress differs from vpn'     check_egress_matches_vpn 9.9.9.9 1.2.3.4

# 192.0.2.1 is an RFC 5737 documentation address standing in for the home WAN IP,
# which the live probe discovers at runtime and never commits.
expect_pass 'no leak: differs from home'  check_no_home_leak 1.2.3.4 192.0.2.1 vpn-ip
expect_pass 'no leak: egress blocked'     check_no_home_leak '' 192.0.2.1 app-egress
expect_fail 'leak: equals home'           check_no_home_leak 192.0.2.1 192.0.2.1 app-egress
expect_fail 'no home reference'           check_no_home_leak 1.2.3.4 '' vpn-ip

expect_pass 'single loopback resolver'    check_loopback_resolvers '127.0.0.1'
expect_pass 'repeated loopback resolvers' check_loopback_resolvers $'127.0.0.1\n127.0.0.1'
expect_fail 'cluster resolver'            check_loopback_resolvers '10.96.0.10'
expect_fail 'mixed resolver set'          check_loopback_resolvers $'127.0.0.1\n192.168.90.2'
expect_fail 'empty resolver set'          check_loopback_resolvers ''

# The catalog runner retains this probe's combined stdout/stderr as publishable
# evidence. Use distinctive RFC 5737 addresses to prove that both successful live
# output and comparison failures retain conclusions without exposing measured values.
fixture_vpn_ip='198.51.100.77'
fixture_home_ip='203.0.113.88'
kubectl() {
  local command_line="$*"
  if [[ "$command_line" == *' get pod -l app.kubernetes.io/name=qbittorrent '* ]]; then
    printf 'qbittorrent-fixture'
  elif [[ "$command_line" == *'/gluetun/auth/config.toml'* ]]; then
    printf 'fixture-api-key'
  elif [[ "$command_line" == *'/v1/vpn/status'* ]]; then
    printf '{"status":"running"}'
  elif [[ "$command_line" == *'/v1/publicip/ip'* ]]; then
    printf '{"public_ip":"%s","country":"Sweden"}' "$fixture_vpn_ip"
  elif [[ "$command_line" == *'/v1/portforward'* ]]; then
    printf '{"port":49103}'
  elif [[ "$command_line" == *'/api/v2/app/preferences'* ]]; then
    printf '{"listen_port":49103}'
  elif [[ "$command_line" == *' exec '*'-c app '*https://ifconfig.me/ip* ]]; then
    printf '%s' "$fixture_vpn_ip"
  elif [[ "$command_line" == *'/etc/resolv.conf'* ]]; then
    printf 'nameserver 127.0.0.1\n'
  elif [[ "$command_line" == *' run qbprobe-wan-'* ]]; then
    printf '%s' "$fixture_home_ip"
  else
    echo 'Unexpected kubectl fixture command.' >&2
    return 64
  fi
}

expect_redacted \
  'live success hides VPN and home/WAN addresses' 0 \
  'qBittorrent probe passed: VPN running via Sweden' \
  "$fixture_vpn_ip" "$fixture_home_ip" \
  probe_main fixture-kubeconfig

expect_redacted \
  'egress mismatch hides application and VPN addresses' 1 \
  'qBittorrent egress does not match the VPN IP.' \
  '192.0.2.45' '198.51.100.46' \
  check_egress_matches_vpn '192.0.2.45' '198.51.100.46'

expect_redacted \
  'home leak hides the home/WAN address' 1 \
  'LEAK (app-egress): observed egress matches the home/WAN reference.' \
  '203.0.113.91' '' \
  check_no_home_leak '203.0.113.91' '203.0.113.91' app-egress

expect_redacted \
  'non-loopback resolver failure hides the resolver address' 1 \
  'DNS leak risk: qBittorrent resolver is not Gluetun loopback.' \
  '192.0.2.200' '' \
  check_loopback_resolvers '192.0.2.200'

expect_redacted \
  'port mismatch hides both measured ports' 1 \
  'qBittorrent listen port does not match the forwarded port.' \
  '49103' '6881' \
  check_port_agreement 49103 6881

echo "qBittorrent probe unit tests: ${pass} passed, ${fail} failed."
[[ "$fail" -eq 0 ]]
