#!/usr/bin/env bash
# Offline unit tests for the pure check_* logic in isolation.sh. Runs in `just ci`
# (no cluster); sources isolation.sh (live main is BASH_SOURCE-guarded).
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/probes/dns/isolation.sh
source "$here/isolation.sh"

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

expect_pass 'configured resolver is Gluetun loopback'  check_configured_resolver 127.0.0.1
expect_fail 'configured resolver is cluster CoreDNS'    check_configured_resolver 10.96.0.10
expect_fail 'configured resolver is empty'              check_configured_resolver ''

expect_pass 'gluetun resolves ok'                       check_gluetun_resolves ok
expect_fail 'gluetun resolution failed'                 check_gluetun_resolves fail

expect_pass 'LAN resolver blocked'                      check_resolver_blocked '192.168.90.2 (LAN/home)' blocked
expect_fail 'LAN resolver reachable is a leak'          check_resolver_blocked '192.168.90.2 (LAN/home)' resolved
expect_pass 'cluster resolver blocked'                  check_resolver_blocked '10.96.0.10 (cluster CoreDNS)' blocked
expect_fail 'cluster resolver reachable is a leak'      check_resolver_blocked '10.96.0.10 (cluster CoreDNS)' resolved

echo "DNS isolation unit tests: ${pass} passed, ${fail} failed."
[[ "$fail" -eq 0 ]]
