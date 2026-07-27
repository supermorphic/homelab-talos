#!/usr/bin/env bash
# Controlled qBittorrent VPN stop/recovery orchestrator (resilience item 4). DESTRUCTIVE:
# stops the live VPN and recreates the pod. Reuses the leak sentinel (capture.sh +
# leak_sentinel.py) for CONTINUOUS transition evidence and the killswitch's control-server
# mechanics. Invoked by the thin Chainsaw resilience scenario; also runnable directly.
#
# Flow: baseline (VPN up) -> single continuous in-netns capture spanning the stop ->
# outage-mode verdict (pre=via VPN, during=all-blocked, no home-WAN leak) -> recover via
# pod recreation (the killswitch-proven path; in-place restart loops on Gluetun's DNS
# healthcheck) -> fresh capture verifies recovery. Recovery outcome is written to
# recovery.json so the runner records it SEPARATELY from the primary assertion.
set -euo pipefail

[[ "$#" -eq 1 ]] || { echo 'Usage: orchestrate-vpn-disconnect.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git rev-parse --show-toplevel)"
ns='media'
target='qbittorrent-vpn-disconnect'

baseline_s="${VPN_DISCONNECT_BASELINE_S:-15}"
outage_s="${VPN_DISCONNECT_OUTAGE_S:-30}"
settle_s="${VPN_DISCONNECT_SETTLE_S:-6}"
recovery_timeout_s="${VPN_DISCONNECT_RECOVERY_TIMEOUT_S:-240}"

# Guard step 2: the scenario's first operation re-invokes the chaos guard before mutating.
"$repo_root/scripts/test/safety/require-chaos-confirmation.sh" "$target"

run_dir="${HOMELAB_TEST_RUN_DIR:-}"
if [[ -z "$run_dir" ]]; then
  mkdir -p "$repo_root/.test-results"
  run_dir="$(mktemp -d "$repo_root/.test-results/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=12 HEAD)-vpn-disconnect.XXXXXX")"
fi
timeline_dir="$run_dir/diagnostics/timelines"
mkdir -p "$timeline_dir"
write_recovery() { printf '{"status":"%s","reason":"%s"}\n' "$1" "$2" >"$run_dir/recovery.json"; }
write_recovery 'not-attempted' 'orchestrator started'

find_pod() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
pod="$(find_pod)"
[[ -n "$pod" ]] || { echo 'No qbittorrent pod found (is Phase 12 bootstrapped?).' >&2; exit 1; }

read_apikey() { gx sh -c 'grep -E "^apikey" /gluetun/auth/config.toml | sed -E "s/.*\"(.*)\".*/\1/"' 2>/dev/null | tr -d '\r'; }
gx() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c gluetun -- "$@"; }
apikey="$(read_apikey)"
[[ -n "$apikey" ]] || { echo 'Could not read the Gluetun control-server apikey.' >&2; exit 1; }
ctl() { gx wget -qO- --header "X-API-Key: $apikey" "$@" 2>/dev/null; }
ctl_put() { gx wget -qO- --method=PUT --header "X-API-Key: $apikey" --body-data "$2" "$1" >/dev/null 2>&1 || true; }
vpn_status() { ctl http://localhost:8000/v1/vpn/status | yq -r '.status // "unknown"' 2>/dev/null || echo unknown; }
vpn_ip() { ctl http://localhost:8000/v1/publicip/ip | yq -r '.public_ip // ""' 2>/dev/null || true; }

# Self-healing recovery via pod recreation (fresh netns + tunnel). Rebinds gx/ctl to the
# new pod and re-reads its apikey. Records the outcome to recovery.json either way.
recover() {
  local why="$1" cur newpod status ip
  cur="$(find_pod)"
  echo "Recovery (${why}): recreating pod ${cur:-<none>} for a fresh netns + tunnel."
  if [[ -n "$cur" ]]; then
    kubectl --kubeconfig "$kubeconfig" --namespace "$ns" delete pod "$cur" --wait=false >/dev/null 2>&1 || true
  fi
  local deadline=$(( $(date +%s) + recovery_timeout_s ))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    newpod="$(find_pod)"
    if [[ -n "$newpod" && "$newpod" != "$cur" ]]; then
      pod="$newpod"
      apikey="$(read_apikey || true)"
      if [[ -n "$apikey" ]]; then
        status="$(vpn_status)"; ip="$(vpn_ip)"
        if [[ "$status" == 'running' && -n "$ip" ]]; then
          write_recovery 'passed' "recovered on ${newpod}, VPN ${ip}"
          echo "Recovered: pod ${newpod} VPN=${ip}."
          return 0
        fi
      fi
    fi
    sleep 5
  done
  write_recovery 'failed' "no healthy tunnel within ${recovery_timeout_s}s"
  echo "Recovery FAILED: no healthy tunnel within ${recovery_timeout_s}s." >&2
  return 1
}

passed=false
trap '[[ "$passed" == true ]] || recover "cleanup-trap" || true' EXIT

# Baseline references.
[[ "$(vpn_status)" == 'running' ]] || { echo 'VPN is not running at baseline.' >&2; exit 1; }
vpn_ip_baseline="$(vpn_ip)"
[[ -n "$vpn_ip_baseline" ]] || { echo 'No baseline VPN public IP.' >&2; exit 1; }
"$repo_root/tests/probes/qbittorrent/probe.sh" "$kubeconfig"
home_ip="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" run "vpndis-wan-$RANDOM" \
  --image=curlimages/curl:8.11.1 --restart=Never --rm -i --quiet \
  --command -- curl -sS -m 15 https://ifconfig.me/ip 2>/dev/null | tr -d '\r\n ' || true)"
[[ -n "$home_ip" ]] || { echo 'Could not determine the node WAN IP (leak reference).' >&2; exit 1; }

# Phase 1: ONE continuous capture spanning baseline -> stop -> outage (the app container
# and its netns survive the VPN stop; only Gluetun's tunnel drops).
outage_timeline="$timeline_dir/outage.jsonl"
total_capture_s=$(( baseline_s + outage_s ))
echo "Phase 1: continuous capture ${total_capture_s}s (baseline ${baseline_s}s + outage ${outage_s}s); vpn=${vpn_ip_baseline} home=${home_ip}"
"$here/capture.sh" "$kubeconfig" "$ns" "$pod" "$total_capture_s" >"$outage_timeline" &
capture_pid=$!
sleep "$baseline_s"
stop_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Stopping VPN at ${stop_ts} (PUT /v1/vpn/status stopped)."
ctl_put http://localhost:8000/v1/vpn/status '{"status":"stopped"}'
wait "$capture_pid" || true
[[ "$(vpn_status)" != 'running' ]] || { echo 'VPN still running after the stop request.' >&2; exit 1; }

echo "Phase 1 outage verdict (stop_ts=${stop_ts} settle=${settle_s}s):"
uv run python "$here/leak_sentinel.py" --mode outage --timeline "$outage_timeline" \
  --home-wan "$home_ip" --vpn-ip "$vpn_ip_baseline" --stop-ts "$stop_ts" --settle "$settle_s" \
  | tee "$timeline_dir/outage-verdict.json"
[[ "${PIPESTATUS[0]}" -eq 0 ]] || { echo 'Outage verdict FAILED: the kill switch did not hold.' >&2; exit 1; }

# Phase 2: recovery via pod recreation.
recover "post-outage" || exit 1

# Phase 3: recovery verification — fresh capture on the new pod, baseline mode.
recovery_timeline="$timeline_dir/recovery.jsonl"
new_vpn_ip="$(vpn_ip)"
echo "Phase 3: recovery verification capture (20s) on ${pod}; new vpn=${new_vpn_ip}"
"$here/capture.sh" "$kubeconfig" "$ns" "$pod" 20 >"$recovery_timeline"
uv run python "$here/leak_sentinel.py" --timeline "$recovery_timeline" \
  --home-wan "$home_ip" --vpn-ip "$new_vpn_ip" | tee "$timeline_dir/recovery-verdict.json"
[[ "${PIPESTATUS[0]}" -eq 0 ]] || { echo 'Recovery verification FAILED: post-recovery egress not clean via VPN.' >&2; exit 1; }
"$repo_root/tests/probes/qbittorrent/probe.sh" "$kubeconfig"

passed=true
trap - EXIT
echo "PASS: kill switch held across the VPN stop (no home-WAN leak; egress blocked during the outage), recovered via pod recreation to VPN ${new_vpn_ip}. Evidence: ${run_dir}"
