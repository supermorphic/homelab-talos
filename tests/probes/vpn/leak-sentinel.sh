#!/usr/bin/env bash
# Live entrypoint for the qBittorrent VPN leak sentinel (baseline: VPN up). Gathers the
# reference IPs (VPN public IP from the Gluetun control server; home/WAN from a throwaway
# --rm pod), captures a continuous in-netns egress timeline (capture.sh), and renders the
# no-leak verdict via the unit-tested Python analyzer (leak_sentinel.py). Records the
# timeline + verdict under .test-results/ (gitignored). Operator-run; not in `just ci`.
#
# Invoked as `just test probe vpn-leak` (run-probe.sh dispatches here from repo root).
# The VPN stop/recovery transition capture that wraps this is a future resilience
# scenario (item 4).
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: leak-sentinel.sh <kubeconfig>' >&2
  exit 2
}
kubeconfig="$1"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ns='media'
# Wall-clock capture window in seconds (per-tick egress latency through the tunnel
# dominates cadence, so bound by time, not tick count).
duration="${LEAK_SENTINEL_DURATION:-120}"

pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$pod" ]] || { echo 'No qbittorrent pod found (is Phase 12 bootstrapped?).' >&2; exit 1; }

gx() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c gluetun -- "$@"; }
apikey="$(gx sh -c 'grep -E "^apikey" /gluetun/auth/config.toml | sed -E "s/.*\"(.*)\".*/\1/"' 2>/dev/null | tr -d '\r')"
[[ -n "$apikey" ]] || { echo 'Could not read control-server apikey from /gluetun/auth/config.toml.' >&2; exit 1; }
vpn_ip="$(gx wget -qO- --header "X-API-Key: $apikey" http://localhost:8000/v1/publicip/ip 2>/dev/null | yq -r '.public_ip // ""' 2>/dev/null || true)"
[[ -n "$vpn_ip" ]] || { echo 'Could not read the VPN public IP from the control server.' >&2; exit 1; }

# Home/WAN reference: a throwaway no-VPN pod egresses via the node WAN (ephemeral --rm).
home_ip="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" run "qbsentinel-wan-$RANDOM" \
  --image=curlimages/curl:8.11.1 --restart=Never --rm -i --quiet \
  --command -- curl -sS -m 15 https://ifconfig.me/ip 2>/dev/null | tr -d '\r\n ' || true)"
[[ -n "$home_ip" ]] || { echo 'Could not determine the node WAN IP (leak reference).' >&2; exit 1; }

mkdir -p .test-results
run_ts="$(date -u +%Y%m%dT%H%M%SZ)"
short_revision="$(git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)"
run_dir="$(mktemp -d ".test-results/${run_ts}-${short_revision}-vpn-leak.XXXXXX")"
timeline="$run_dir/timeline.jsonl"
verdict="$run_dir/verdict.json"

echo "Capturing a ~${duration}s in-netns egress timeline (vpn_ip=$vpn_ip home_wan=$home_ip) -> $timeline"
"$here/capture.sh" "$kubeconfig" "$ns" "$pod" "$duration" >"$timeline"

set +e
uv run python "$here/leak_sentinel.py" --timeline "$timeline" --home-wan "$home_ip" --vpn-ip "$vpn_ip" | tee "$verdict"
rc="${PIPESTATUS[0]}"
set -e

echo "Evidence: $run_dir"
exit "$rc"
