#!/usr/bin/env bash
# Phase helper for the Chainsaw qBittorrent VPN-disconnect resilience test.
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo 'Usage: qbittorrent-vpn-disconnect.sh <baseline|disrupt|assert-fail-closed|recover|verify> <kubeconfig>' >&2
  exit 2
}
phase="$1"
kubeconfig="$2"
repo_root="$(git rev-parse --show-toplevel)"
probe_dir="$repo_root/tests/probes/vpn"
ns='media'
selector='app.kubernetes.io/name=qbittorrent'
target='qbittorrent-vpn-disconnect'
baseline_s="${VPN_DISCONNECT_BASELINE_S:-15}"
outage_s="${VPN_DISCONNECT_OUTAGE_S:-30}"
settle_s="${VPN_DISCONNECT_SETTLE_S:-6}"
recovery_timeout_s="${VPN_DISCONNECT_RECOVERY_TIMEOUT_S:-240}"
run_dir="${HOMELAB_TEST_RUN_DIR:?HOMELAB_TEST_RUN_DIR is required}"
timeline_dir="$run_dir/diagnostics/timelines"
state="$run_dir/diagnostics/qbittorrent-vpn-disconnect-state.json"
mkdir -p "$timeline_dir"

k() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" "$@"; }
find_pod() { k get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
gx() { k exec "$1" -c gluetun -- "${@:2}"; }
read_apikey() {
  gx "$1" sh -c 'grep -E "^apikey" /gluetun/auth/config.toml | sed -E "s/.*\"(.*)\".*/\1/"' 2>/dev/null |
    tr -d '\r'
}
vpn_status() {
  gx "$1" wget -qO- --header "X-API-Key: $2" \
    http://localhost:8000/v1/vpn/status 2>/dev/null |
    yq -r '.status // "unknown"' 2>/dev/null || echo unknown
}
vpn_ip() {
  gx "$1" wget -qO- --header "X-API-Key: $2" \
    http://localhost:8000/v1/publicip/ip 2>/dev/null |
    yq -r '.public_ip // ""' 2>/dev/null || true
}
write_recovery() {
  STATUS="$1" REASON="$2" yq --null-input --output-format json \
    '{"status": strenv(STATUS), "reason": strenv(REASON)}' >"$run_dir/recovery.json"
}
read_state() { yq -r "$1" "$state"; }

case "$phase" in
  baseline)
    "$repo_root/scripts/test/safety/require-chaos-confirmation.sh" "$target"
    write_recovery not-attempted 'baseline established; recovery not yet attempted'
    pod="$(find_pod)"
    [[ -n "$pod" ]] || { echo 'No qBittorrent pod found.' >&2; exit 3; }
    apikey="$(read_apikey "$pod")"
    [[ -n "$apikey" ]] || { echo 'Could not read Gluetun control API key.' >&2; exit 3; }
    [[ "$(vpn_status "$pod" "$apikey")" == 'running' ]] || {
      echo 'VPN is not running at baseline.' >&2
      exit 3
    }
    baseline_ip="$(vpn_ip "$pod" "$apikey")"
    [[ -n "$baseline_ip" ]] || { echo 'No baseline VPN public IP.' >&2; exit 3; }
    "$repo_root/tests/probes/qbittorrent/probe.sh" "$kubeconfig"
    home_ip="$(k run "vpndis-wan-$RANDOM" \
      --image=curlimages/curl:8.11.1 --restart=Never --rm -i --quiet \
      --command -- curl -sS -m 15 https://ifconfig.me/ip 2>/dev/null |
      tr -d '\r\n ' || true)"
    [[ -n "$home_ip" ]] || { echo 'Could not determine node WAN IP.' >&2; exit 3; }
    POD="$pod" BASELINE_IP="$baseline_ip" HOME_IP="$home_ip" \
      yq --null-input --output-format json '{
        "pod": strenv(POD),
        "baselineVpnIp": strenv(BASELINE_IP),
        "homeWanIp": strenv(HOME_IP),
        "recovered": false,
        "verified": false
      }' >"$state"
    ;;
  disrupt)
    "$repo_root/scripts/test/safety/require-chaos-confirmation.sh" "$target"
    pod="$(read_state '.pod')"
    apikey="$(read_apikey "$pod")"
    outage_timeline="$timeline_dir/outage.jsonl"
    total_s=$((baseline_s + outage_s))
    "$probe_dir/capture.sh" "$kubeconfig" "$ns" "$pod" "$total_s" >"$outage_timeline" &
    capture_pid=$!
    sleep "$baseline_s"
    stop_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gx "$pod" wget -qO- --method=PUT --header "X-API-Key: $apikey" \
      --body-data '{"status":"stopped"}' \
      http://localhost:8000/v1/vpn/status >/dev/null 2>&1 || true
    wait "$capture_pid" || true
    STOP_TS="$stop_ts" yq -i '.stopTimestamp = strenv(STOP_TS)' "$state"
    ;;
  assert-fail-closed)
    pod="$(read_state '.pod')"
    apikey="$(read_apikey "$pod")"
    baseline_ip="$(read_state '.baselineVpnIp')"
    home_ip="$(read_state '.homeWanIp')"
    stop_ts="$(read_state '.stopTimestamp')"
    [[ "$(vpn_status "$pod" "$apikey")" != 'running' ]] || {
      echo 'VPN is still running after the stop request.' >&2
      exit 1
    }
    uv run --locked --no-dev python "$probe_dir/leak_sentinel.py" \
      --mode outage \
      --timeline "$timeline_dir/outage.jsonl" \
      --home-wan "$home_ip" \
      --vpn-ip "$baseline_ip" \
      --stop-ts "$stop_ts" \
      --settle "$settle_s" |
      tee "$timeline_dir/outage-verdict.json"
    ;;
  recover)
    recovered=false
    verified=false
    if [[ -f "$state" ]]; then
      recovered="$(read_state '.recovered // false')"
      verified="$(read_state '.verified // false')"
    fi
    if [[ "$recovered" == 'true' && "$verified" == 'true' ]]; then
      current="$(find_pod)"
      current_apikey="$(read_apikey "$current" || true)"
      current_ip="$(vpn_ip "$current" "$current_apikey")"
      if [[ -n "$current_apikey" && -n "$current_ip" &&
        "$(vpn_status "$current" "$current_apikey")" == 'running' ]]; then
        k rollout status deployment/qbittorrent --timeout="${recovery_timeout_s}s" >/dev/null
        write_recovery passed 'verified qBittorrent VPN remains healthy'
        exit 0
      fi
    fi
    current="$(find_pod || true)"
    if [[ -n "$current" ]]; then
      k delete pod "$current" --wait=false >/dev/null 2>&1 || true
    fi
    deadline=$((EPOCHSECONDS + recovery_timeout_s))
    while [[ "$EPOCHSECONDS" -lt "$deadline" ]]; do
      new_pod="$(find_pod)"
      if [[ -n "$new_pod" && "$new_pod" != "$current" ]]; then
        new_apikey="$(read_apikey "$new_pod" || true)"
        if [[ -n "$new_apikey" ]]; then
          new_ip="$(vpn_ip "$new_pod" "$new_apikey")"
          if [[ "$(vpn_status "$new_pod" "$new_apikey")" == 'running' && -n "$new_ip" ]]; then
            NEW_POD="$new_pod" NEW_IP="$new_ip" yq -i '
              .recovered = true |
              .verified = false |
              .recoveryPod = strenv(NEW_POD) |
              .recoveryVpnIp = strenv(NEW_IP)
            ' "$state"
            write_recovery passed "recovered on $new_pod through VPN"
            exit 0
          fi
        fi
      fi
      sleep 5
    done
    write_recovery failed "no healthy VPN tunnel within ${recovery_timeout_s}s"
    exit 1
    ;;
  verify)
    pod="$(read_state '.recoveryPod')"
    vpn_ip_after="$(read_state '.recoveryVpnIp')"
    home_ip="$(read_state '.homeWanIp')"
    "$probe_dir/capture.sh" "$kubeconfig" "$ns" "$pod" 20 >"$timeline_dir/recovery.jsonl"
    uv run --locked --no-dev python "$probe_dir/leak_sentinel.py" \
      --timeline "$timeline_dir/recovery.jsonl" \
      --home-wan "$home_ip" \
      --vpn-ip "$vpn_ip_after" |
      tee "$timeline_dir/recovery-verdict.json"
    "$repo_root/tests/probes/qbittorrent/probe.sh" "$kubeconfig"
    yq -i '.verified = true' "$state"
    cp "$state" "$run_dir/evidence.json"
    ;;
  *)
    echo "Unknown phase: $phase" >&2
    exit 2
    ;;
esac
