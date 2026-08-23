#!/usr/bin/env bash
# qBittorrent/Gluetun active DNS-isolation probe (Required follow-up sequence item 3).
# Reads-only. Proves — by ACTIVE resolution, not just /etc/resolv.conf inspection — that
# DNS resolves ONLY via Gluetun's in-netns loopback resolver (127.0.0.1 DoT over the
# tunnel) and that the LAN/home and cluster resolvers are unreachable, so DNS queries
# cannot take a non-tunnel path.
#
# Live observation informing the design: the kill switch blocks non-tunnel egress, so
# the LAN Pi-hole (192.168.90.2) and cluster CoreDNS (10.96.0.10) are unreachable — but a
# PUBLIC resolver (8.8.8.8) IS reachable via the tunnel. Reaching a public resolver over
# the VPN is expected (egress == VPN IP, a home-WAN leak is the leak-sentinel's job), so
# 8.8.8.8 is recorded as informational, NOT gated. The isolation invariant is that the
# LAN/home and cluster resolvers stay blocked.
#
# Pure check_* functions take plain strings and never touch Kubernetes, so isolation-test.sh
# unit-tests them offline in `just ci`. The live main is BASH_SOURCE-guarded.
set -euo pipefail

source scripts/lib/network.sh

# The Gluetun in-netns resolver, and the two non-tunnel resolvers that MUST stay blocked.
GLUETUN_RESOLVER='127.0.0.1'
LAN_RESOLVER="$HOMELAB_DNS_RESOLVER"   # home/LAN Pi-hole
CLUSTER_RESOLVER='10.96.0.10'   # Kubernetes CoreDNS ClusterIP

# --- pure, cluster-free assertions (unit-tested by isolation-test.sh) --------------

# check_configured_resolver <nameserver>
check_configured_resolver() {
  [[ "$1" == "$GLUETUN_RESOLVER" ]] || {
    echo "App resolv.conf nameserver is '$1', expected the Gluetun loopback $GLUETUN_RESOLVER." >&2
    return 1
  }
}

# check_gluetun_resolves <loopback-result>   ("ok" required)
check_gluetun_resolves() {
  [[ "$1" == 'ok' ]] || {
    echo 'In-netns DNS via the Gluetun resolver failed (VPN/DoT down?); cannot confirm isolation.' >&2
    return 1
  }
}

# check_resolver_blocked <label> <result>    ("blocked" required; "resolved" == leak)
check_resolver_blocked() {
  [[ "$2" == 'blocked' ]] || {
    echo "DNS ISOLATION LEAK: direct query to $1 resolved — DNS can take a non-Gluetun path." >&2
    return 1
  }
}

# --- live measurement (operator-run; never invoked in CI) --------------------------

probe_main() {
  local kubeconfig="$1"
  local ns='media' pod
  pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$pod" ]] || { echo 'No qbittorrent pod found (is qBittorrent deployed?).' >&2; exit 1; }

  # One exec: read the configured resolver, then actively resolve via the default
  # (Gluetun) resolver and directly against each non-tunnel resolver. Each direct query
  # is time-bounded so a blocked resolver reports quickly instead of hanging.
  # The heredoc is quoted so its $(...) stays pod-side; the LAN resolver is therefore
  # passed in as $1 (the pod has no access to this host-side constant).
  local remote
  remote="$(cat <<'REMOTE'
printf 'nameserver=%s\n' "$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"
timeout 8 nslookup github.com           >/dev/null 2>&1 && echo 'loopback=ok'       || echo 'loopback=fail'
timeout 8 nslookup github.com "$1"      >/dev/null 2>&1 && echo 'lan=resolved'      || echo 'lan=blocked'
timeout 8 nslookup github.com 10.96.0.10 >/dev/null 2>&1 && echo 'cluster=resolved' || echo 'cluster=blocked'
timeout 8 nslookup github.com 8.8.8.8   >/dev/null 2>&1 && echo 'public=resolved'   || echo 'public=blocked'
REMOTE
)"
  local results
  results="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c app -- sh -c "$remote" sh "$LAN_RESOLVER")"

  local nameserver loopback lan cluster public
  nameserver="$(grep -m1 '^nameserver=' <<<"$results" | cut -d= -f2)"
  loopback="$(grep -m1 '^loopback=' <<<"$results" | cut -d= -f2)"
  lan="$(grep -m1 '^lan=' <<<"$results" | cut -d= -f2)"
  cluster="$(grep -m1 '^cluster=' <<<"$results" | cut -d= -f2)"
  public="$(grep -m1 '^public=' <<<"$results" | cut -d= -f2)"

  echo "resolv.conf nameserver=$nameserver loopback=$loopback lan($LAN_RESOLVER)=$lan cluster($CLUSTER_RESOLVER)=$cluster public(8.8.8.8)=$public [public via tunnel is informational, not gated]"
  check_configured_resolver "$nameserver"
  check_gluetun_resolves "$loopback"
  check_resolver_blocked "$LAN_RESOLVER (LAN/home)" "$lan"
  check_resolver_blocked "$CLUSTER_RESOLVER (cluster CoreDNS)" "$cluster"
  echo 'DNS isolation passed: resolves only via the Gluetun loopback resolver (127.0.0.1); LAN/home and cluster resolvers are unreachable; public DNS egresses via the tunnel.'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  [[ "$#" -eq 1 ]] || { echo 'Usage: isolation.sh <kubeconfig>' >&2; exit 2; }
  probe_main "$1"
fi
