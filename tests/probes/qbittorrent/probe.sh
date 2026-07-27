#!/usr/bin/env bash
# qBittorrent/Gluetun read-only network probe (Required follow-up sequence item 1,
# probe half). Reuses the NON-destructive baseline of the
# qbittorrent-vpn-disconnect resilience scenario:
# it only reads live state (no VPN stop, no pod recreation) and asserts the
# forwarded-port agreement and VPN egress invariants.
#
# The pure check_* functions below take plain strings and never touch Kubernetes, so
# probe-test.sh sources this file and unit-tests them offline (in `just ci`). The live
# `main` is guarded by the BASH_SOURCE check so sourcing never contacts a cluster.
#
# This is one specialized measurement, invoked interactively via `just test probe
# qbittorrent`. It is not an assurance tier; a future e2e/resilience Chainsaw scenario
# may orchestrate this same script as a `command`/`script` operation (the smoke tier
# cannot — safety.rego forbids command/script there).
set -euo pipefail

# --- pure, cluster-free assertions (unit-tested by probe-test.sh) -----------------

# check_vpn_running <status>
check_vpn_running() {
  [[ "$1" == 'running' ]] || { echo "VPN status is '$1', expected 'running'." >&2; return 1; }
}

# check_country_sweden <country>
check_country_sweden() {
  printf '%s' "$1" | grep -qi 'sweden' || { echo "VPN egress country is '$1', not Sweden." >&2; return 1; }
}

# check_port_agreement <forwarded_port> <listen_port>
check_port_agreement() {
  local forwarded="$1" listen="$2"
  [[ -n "$forwarded" && "$forwarded" != '0' ]] || { echo "No active forwarded port ('$forwarded')." >&2; return 1; }
  [[ "$listen" == "$forwarded" ]] || { echo "qBittorrent listen_port ('$listen') != forwarded port ('$forwarded')." >&2; return 1; }
}

# check_egress_matches_vpn <app_egress_ip> <vpn_ip>
check_egress_matches_vpn() {
  local egress="$1" vpn="$2"
  [[ -n "$egress" ]] || { echo 'qBittorrent produced no egress IP.' >&2; return 1; }
  [[ "$egress" == "$vpn" ]] || { echo "qBittorrent egress ('$egress') != VPN IP ('$vpn')." >&2; return 1; }
}

# check_no_home_leak <observed_ip> <home_wan_ip> <context>
# A leak is an observed egress IP that equals the home/WAN reference. An empty observed
# IP means egress was blocked (not a leak). An empty home reference cannot be evaluated.
check_no_home_leak() {
  local observed="$1" home="$2" context="$3"
  [[ -n "$home" ]] || { echo "Home/WAN reference IP is empty; cannot evaluate leak ($context)." >&2; return 1; }
  [[ -z "$observed" || "$observed" != "$home" ]] || { echo "LEAK ($context): observed IP == home WAN IP $home." >&2; return 1; }
}

# check_loopback_resolvers <newline-separated nameservers>
check_loopback_resolvers() {
  local resolvers="$1" resolver
  [[ -n "$resolvers" ]] || {
    echo 'Could not read qBittorrent /etc/resolv.conf nameservers.' >&2
    return 1
  }
  while IFS= read -r resolver; do
    [[ -z "$resolver" || "$resolver" == '127.0.0.1' ]] || {
      echo "DNS leak risk: qBittorrent resolver '$resolver' is not Gluetun loopback (127.0.0.1)." >&2
      return 1
    }
  done <<<"$resolvers"
}

# --- live measurement (operator-run; never invoked in CI) --------------------------

probe_main() {
  local kubeconfig="$1"
  local ns='media' pod
  pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$pod" ]] || { echo 'No qbittorrent pod found (is Phase 12 bootstrapped?).' >&2; exit 1; }

  gx() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c gluetun -- "$@"; }
  gapp() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c app -- "$@"; }

  local apikey
  apikey="$(gx sh -c 'grep -E "^apikey" /gluetun/auth/config.toml | sed -E "s/.*\"(.*)\".*/\1/"' 2>/dev/null | tr -d '\r')"
  [[ -n "$apikey" ]] || { echo 'Could not read control-server apikey from /gluetun/auth/config.toml.' >&2; exit 1; }
  ctl() { gx wget -qO- --header "X-API-Key: $apikey" "$@" 2>/dev/null; }

  local vpn_status vpn_ip vpn_country forwarded listen egress home_ip resolvers
  vpn_status="$(ctl http://localhost:8000/v1/vpn/status  | yq -r '.status // "unknown"' 2>/dev/null || echo unknown)"
  vpn_ip="$(ctl http://localhost:8000/v1/publicip/ip     | yq -r '.public_ip // ""' 2>/dev/null || true)"
  vpn_country="$(ctl http://localhost:8000/v1/publicip/ip | yq -r '.country // ""' 2>/dev/null || true)"
  forwarded="$(ctl http://localhost:8000/v1/portforward  | yq -r '.port // ""' 2>/dev/null || true)"
  listen="$(gapp sh -c 'wget -qO- -T 6 http://127.0.0.1:8080/api/v2/app/preferences 2>/dev/null' | yq -r '.listen_port // ""' 2>/dev/null || true)"
  egress="$(gapp sh -c 'wget -qO- -T 6 https://ifconfig.me/ip 2>/dev/null || true' | tr -d '\r\n ')"
  resolvers="$(gapp sh -c 'grep "^nameserver" /etc/resolv.conf' 2>/dev/null |
    sed -E 's/^nameserver[[:space:]]+//' | tr -d '\r')"

  # Home/WAN reference: a throwaway no-VPN pod egresses via the node WAN. Ephemeral
  # (--rm); the only non-read action, and it changes no persistent cluster state.
  home_ip="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" run "qbprobe-wan-$RANDOM" \
    --image=curlimages/curl:8.11.1 --restart=Never --rm -i --quiet \
    --command -- curl -sS -m 15 https://ifconfig.me/ip 2>/dev/null | tr -d '\r\n ' || true)"
  [[ -n "$home_ip" ]] || { echo 'Could not determine the node WAN IP (leak reference).' >&2; exit 1; }

  echo "vpn_status=$vpn_status country=$vpn_country vpn_ip=$vpn_ip forwarded_port=$forwarded listen_port=$listen app_egress=$egress home_wan=$home_ip resolvers=$(tr '\n' ',' <<<"$resolvers")"
  check_vpn_running "$vpn_status"
  check_country_sweden "$vpn_country"
  check_no_home_leak "$vpn_ip" "$home_ip" 'vpn-ip'
  check_port_agreement "$forwarded" "$listen"
  check_egress_matches_vpn "$egress" "$vpn_ip"
  check_no_home_leak "$egress" "$home_ip" 'app-egress'
  check_loopback_resolvers "$resolvers"
  echo 'qBittorrent probe passed: VPN running via Sweden, egress == VPN IP (not home WAN), forwarded port agrees with qBittorrent listen_port, and DNS uses only Gluetun loopback.'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ "$#" -eq 1 ]] || { echo 'Usage: probe.sh <kubeconfig>' >&2; exit 2; }
  probe_main "$1"
fi
