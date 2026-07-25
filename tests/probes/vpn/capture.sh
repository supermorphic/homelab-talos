#!/usr/bin/env bash
# Continuous in-netns egress capture for the VPN leak sentinel. Runs a single bounded
# loop INSIDE the qBittorrent app container (one long-running `kubectl exec`, not
# intermittent sampling — see Decision 8) and streams a JSONL timeline to stdout:
#   {"ts":...,"type":"egress","ip":"<ip>"}       # "" == blocked / no egress this tick
#   {"ts":...,"type":"structural","default_route_iface":"tun0","resolver":"127.0.0.1"}
# The pure analysis + verdict live in leak_sentinel.py; this only measures.
set -euo pipefail

[[ "$#" -eq 4 ]] || {
  echo 'Usage: capture.sh <kubeconfig> <namespace> <pod> <duration-seconds>' >&2
  exit 2
}
kubeconfig="$1"
namespace="$2"
pod="$3"
duration="$4"

# Quoted heredoc: passed verbatim to the in-container busybox sh (no host expansion).
# $1 is the wall-clock capture window in seconds — bounded by time, not tick count,
# because per-tick egress latency through the tunnel dominates the cadence (~5-10s).
# A structural snapshot is emitted every 10th tick.
remote="$(cat <<'REMOTE'
duration="$1"
end=$(( $(date +%s) + duration ))
i=0
while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ip=$(wget -qO- -T 2 https://ifconfig.me/ip 2>/dev/null | tr -d '\r\n ')
  printf '{"ts":"%s","type":"egress","ip":"%s"}\n' "$ts" "$ip"
  if [ $(( i % 10 )) -eq 0 ]; then
    iface=$(awk '$2=="00000000"{print $1; exit}' /proc/net/route)
    resolver=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
    printf '{"ts":"%s","type":"structural","default_route_iface":"%s","resolver":"%s"}\n' "$ts" "$iface" "$resolver"
  fi
  i=$((i + 1))
  sleep 1
done
REMOTE
)"

exec kubectl --kubeconfig "$kubeconfig" --namespace "$namespace" exec "$pod" -c app -- \
  sh -c "$remote" sh "$duration"
