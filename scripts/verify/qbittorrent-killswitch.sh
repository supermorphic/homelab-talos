#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: qbittorrent-killswitch.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='media'
pod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$pod" ]] || { echo 'No qbittorrent pod found (is Phase 12 bootstrapped?).' >&2; exit 1; }

gx() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c gluetun -- "$@"; }
gapp() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" exec "$pod" -c app -- "$@"; }
apikey="$(gx sh -c 'grep -E "^apikey" /gluetun/auth/config.toml | sed -E "s/.*\"(.*)\".*/\1/"' 2>/dev/null | tr -d "\r")"
[[ -n "$apikey" ]] || { echo 'Could not read control-server apikey from /gluetun/auth/config.toml.' >&2; exit 1; }
ctl() { gx wget -qO- --header "X-API-Key: $apikey" "$@" 2>/dev/null; }
ctl_put() { gx wget -qO- --method=PUT --header "X-API-Key: $apikey" --body-data "$2" "$1" >/dev/null 2>&1 || true; }
vpn_status()  { ctl http://localhost:8000/v1/vpn/status    | yq -r '.status // "unknown"' 2>/dev/null || echo unknown; }
vpn_ip()      { ctl http://localhost:8000/v1/publicip/ip   | yq -r '.public_ip // ""' 2>/dev/null || true; }
vpn_country() { ctl http://localhost:8000/v1/publicip/ip   | yq -r '.country // ""' 2>/dev/null || true; }
fport()       { ctl http://localhost:8000/v1/portforward   | yq -r '.port // ""' 2>/dev/null || true; }
listen_port() { gapp sh -c 'wget -qO- -T 6 http://127.0.0.1:8080/api/v2/app/preferences 2>/dev/null' | yq -r '.listen_port // ""' 2>/dev/null || true; }

# On a failed/interrupted run, reset to a clean pod (fresh netns + tunnel) rather than
# a control-API `PUT running`, which re-establishes in-place and can loop on Gluetun's
# healthcheck DNS. On success the pod was already recreated healthy in step 3.
passed=false
trap '[[ "$passed" == "true" ]] || kubectl --kubeconfig "$kubeconfig" --namespace "$ns" delete pod "$pod" --wait=false >/dev/null 2>&1 || true' EXIT

# The app container needs wget (BusyBox) to probe egress from qBittorrent's OWN netns.
gapp sh -c 'command -v wget >/dev/null' || { echo 'app container lacks wget; cannot probe qBittorrent egress.' >&2; exit 1; }

# Independent home/WAN reference: a throwaway pod with NO VPN egresses via the node WAN.
home_ip="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" run "kswan-$RANDOM" --image=curlimages/curl:8.11.1 --restart=Never --rm -i --quiet --command -- curl -sS -m 15 https://ifconfig.me/ip 2>/dev/null | tr -d '\r\n ' || true)"
[[ -n "$home_ip" ]] || { echo 'Could not determine the node WAN IP (needed as the leak reference).' >&2; exit 1; }
echo "Reference home/WAN IP (must NEVER appear as qBittorrent egress): $home_ip"

# Egress FROM qBittorrent's netns: prints the observed public IP, or empty if blocked.
# ifconfig.me/ip returns a plain IP for any User-Agent (the bare host serves HTML to
# wget), so egress parsing is UA-independent.
app_egress() { gapp sh -c 'wget -qO- -T 6 https://ifconfig.me/ip 2>/dev/null || true' | tr -d '\r\n '; }
# Route-level probe bypassing DNS (connect to Cloudflare by IP): non-empty if reachable.
app_route()  { gapp sh -c 'wget -qO- -T 6 https://1.1.1.1/ 2>/dev/null | head -c 1 || true' | tr -d '\r\n '; }
leak_guard() { [[ -n "$1" && "$1" == "$home_ip" ]] && { echo "LEAK ($2): qBittorrent egress IP == home WAN IP $home_ip." >&2; exit 1; }; return 0; }

echo '== 1. Baseline (VPN up, must be Sweden, not home) =='
[[ "$(vpn_status)" == 'running' ]] || { echo 'VPN is not running at baseline.' >&2; exit 1; }
vip="$(vpn_ip)"; country="$(vpn_country)"; fp="$(fport)"
[[ -n "$vip" ]] || { echo 'No VPN public IP from the control server.' >&2; exit 1; }
echo "VPN public IP=$vip country=$country forwarded_port=$fp"
[[ "$vip" != "$home_ip" ]] || { echo 'LEAK: VPN public IP equals the home WAN IP.' >&2; exit 1; }
printf '%s' "$country" | grep -qi 'sweden' || { echo "VPN egress country is '$country', not Sweden (SERVER_COUNTRIES=Sweden not honored)." >&2; exit 1; }
be="$(app_egress)"; echo "qBittorrent egress IP=$be"
leak_guard "$be" 'baseline'
[[ "$be" == "$vip" ]] || { echo "qBittorrent egress ($be) != VPN IP ($vip)." >&2; exit 1; }
[[ -n "$fp" && "$fp" != '0' ]] || { echo 'No active forwarded port at baseline.' >&2; exit 1; }
lp="$(listen_port)"
[[ "$lp" == "$fp" ]] || { echo "qBittorrent listen_port ($lp) != forwarded port ($fp). Enable localhost auth bypass + confirm the UP command ran." >&2; exit 1; }
echo "listen_port matches forwarded port ($fp)."
# DNS isolation (structural, cache-proof): the app must resolve ONLY via Gluetun's
# in-netns resolver (127.0.0.1 DoT over the tunnel), never the node/cluster resolver,
# so DNS queries cannot reach the ISP even when the tunnel drops.
ns_list="$(gapp sh -c 'grep "^nameserver" /etc/resolv.conf' 2>/dev/null | sed -E 's/^nameserver[[:space:]]+//' | tr -d '\r')"
echo "app resolver(s): $(printf '%s' "$ns_list" | tr '\n' ' ')"
[[ -n "$ns_list" ]] || { echo 'Could not read app /etc/resolv.conf.' >&2; exit 1; }
while read -r n; do
  if [[ -n "$n" && "$n" != '127.0.0.1' ]]; then echo "DNS LEAK RISK: app resolver '$n' is not Gluetun's loopback (127.0.0.1)." >&2; exit 1; fi
done <<< "$ns_list"

echo '== 2. Kill switch: polite stop (VPN held down) =='
ctl_put http://localhost:8000/v1/vpn/status '{"status":"stopped"}'
sleep 3
[[ "$(vpn_status)" != 'running' ]] || { echo 'VPN still running after stop request.' >&2; exit 1; }
for _ in 1 2 3 4 5; do
  out="$(app_egress)"; leak_guard "$out" 'vpn-stopped'
  [[ -z "$out" ]] || { echo "LEAK: qBittorrent reached the internet ($out) with the VPN stopped." >&2; exit 1; }
  [[ -z "$(app_route)" ]] || { echo 'LEAK: route-level egress (1.1.1.1) succeeded with the VPN stopped.' >&2; exit 1; }
  sleep 3
done
echo 'Kill switch holds: no IP egress and no route-level egress while the VPN is stopped (DNS is isolated to Gluetun per the baseline resolver check).'

echo '== 3. Recovery via pod recreation (the node-reschedule path) =='
# NB: a gluetun *container* crash cannot be injected from `kubectl exec` — the kernel
# blocks same-PID-namespace SIGKILL to PID 1 (verified: restartCount stays 0). And
# Gluetun's in-place restart after a control-server stop can loop on healthcheck DNS
# timeouts. The robust, realistic recovery is pod recreation (exactly what a node
# reschedule does): a fresh netns + tunnel. During the recreate gap there is no pod,
# hence no possible egress, so fail-closed is preserved by construction. Fail-closed on
# an in-place gluetun crash is structural anyway: qBittorrent holds no NET_ADMIN, so it
# cannot restore routes, and Gluetun's firewall DROP rules persist in the netns.
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
sleep 20
back=false
for _ in {1..48}; do
  newpod="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$newpod" ]] || { sleep 5; continue; }
  pod="$newpod"  # rebind so gx/gapp target the fresh pod
  [[ "$(vpn_status)" == 'running' && -n "$(vpn_ip)" ]] && { back=true; break; }
  sleep 5
done
[[ "$back" == 'true' ]] || { echo 'VPN did not recover to a healthy tunnel within ~4m after pod recreation.' >&2; exit 1; }
rip="$(vpn_ip)"; rc="$(vpn_country)"; leak_guard "$rip" 'recovery'
printf '%s' "$rc" | grep -qi 'sweden' || { echo "Recovered country '$rc' is not Sweden." >&2; exit 1; }
be="$(app_egress)"; leak_guard "$be" 'post-recovery'
[[ "$be" == "$rip" ]] || { echo "Post-recovery qBittorrent egress ($be) != VPN IP ($rip)." >&2; exit 1; }
rport=''; for _ in {1..24}; do rport="$(fport)"; [[ -n "$rport" && "$rport" != '0' ]] && break; sleep 5; done
[[ -n "$rport" && "$rport" != '0' ]] || { echo 'Forwarded port not reacquired after recovery.' >&2; exit 1; }
rlp=''; for _ in {1..18}; do rlp="$(listen_port)"; [[ "$rlp" == "$rport" ]] && break; sleep 5; done
[[ "$rlp" == "$rport" ]] || { echo "After recovery, listen_port ($rlp) != forwarded port ($rport) (UP command did not reapply)." >&2; exit 1; }
echo "Recovered via pod recreation: IP=$rip country=$rc forwarded_port=$rport reapplied to listen_port; no home-IP leak."

echo '== 4. Final state =='
[[ "$(vpn_status)" == 'running' ]] || { echo 'VPN not running at final check.' >&2; exit 1; }
fip="$(vpn_ip)"; fc="$(vpn_country)"; fe="$(app_egress)"; leak_guard "$fe" 'final'
[[ "$fe" == "$fip" ]] || { echo "Final qBittorrent egress ($fe) != VPN IP ($fip)." >&2; exit 1; }
printf '%s' "$fc" | grep -qi 'sweden' || { echo "Final country '$fc' not Sweden." >&2; exit 1; }
passed=true
echo "PASS: kill switch is bulletproof — egress only via ProtonVPN Sweden ($fip); fail-closed on VPN stop (no IP/route/DNS egress); DNS isolated; recovers to Sweden via pod recreation with the forwarded port reacquired+reapplied; home WAN IP ($home_ip) never leaked. Safe to flip suspend: false."
