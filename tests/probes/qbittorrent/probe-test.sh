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

echo "qBittorrent probe unit tests: ${pass} passed, ${fail} failed."
[[ "$fail" -eq 0 ]]
