#!/usr/bin/env bash
# Fixed non-VPN measurement shared by the two probes and VPN resilience scenario.

# shellcheck source=scripts/lib/lease.sh
source scripts/lib/lease.sh
# shellcheck source=scripts/test/lib/owned-resources.sh
source scripts/test/lib/owned-resources.sh

wan_reference_manifest() { # <name> <run-hash>
  [[ "$1" =~ ^(qbprobe|qbsentinel|vpndis)-wan-[0-9]{1,10}$ && "$2" =~ ^[0-9a-f]{12}$ ]] || return 2
  jq -n --arg name "$1" --arg run "$2" '{apiVersion:"v1",kind:"Pod",
    metadata:{name:$name,namespace:"media",labels:{"homelab-talos/test":"vpn-wan-reference","homelab-talos/run-id":$run}},
    spec:{activeDeadlineSeconds:60,restartPolicy:"Never",automountServiceAccountToken:false,
      securityContext:{runAsNonRoot:true,runAsUser:10001,runAsGroup:10001,seccompProfile:{type:"RuntimeDefault"}},
      containers:[{name:"reference",image:"curlimages/curl:8.11.1",
        command:["curl","-sS","-m","15","https://ifconfig.me/ip"],
        resources:{requests:{cpu:"10m",memory:"16Mi"},limits:{memory:"64Mi"}},
        securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}'
}

wan_reference_ip() ( # <kubeconfig> <name>; subshell keeps the caller's traps intact.
  set -euo pipefail
  local config="$1" name="$2" run_dir="${HOMELAB_TEST_RUN_DIR:-}" run_id run_hash holder
  [[ -f "$config" && -d "$run_dir" ]] || {
    echo 'The WAN reference requires its catalog run and selected kubeconfig.' >&2
    return 1
  }
  run_id="$(basename "$run_dir")"
  [[ "$run_id" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 2
  run_hash="$(printf '%s' "$run_id" | shasum -a 256 | cut -c1-12)"
  holder="${TEST_CAMPAIGN_LEASE_HOLDER:-$run_id}"
  local kc=(kubectl --kubeconfig "$config" --namespace media)
  local temporary ledger manifest result='' cleanup_status creation_attempted=false
  umask 077
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/homelab-wan-reference.XXXXXX")" || return 1
  ledger="$temporary/owned.jsonl"
  manifest="$temporary/pod.json"
  # shellcheck disable=SC2329 # Called by the EXIT trap.
  cleanup_reference() {
    local original="$?" okay=true
    trap - EXIT INT TERM
    set +e
    if [[ -s "$ledger" ]]; then
      verify_test_lease_holder "$config" "$holder" &&
        test_delete_owned "$ledger" Pod media "$name" "${kc[@]}" || okay=false
    elif [[ "$creation_attempted" == true ]]; then
      # An uncertain API write without a creation UID cannot be adopted for cleanup.
      okay=false
    fi
    rm -rf -- "$temporary" || okay=false
    if [[ "$okay" == true ]]; then cleanup_status=passed; else cleanup_status=failed; fi
    # Several reference measurements can share one run. Never erase an earlier failure.
    if [[ -f "$run_dir/cleanup.json" ]] &&
      [[ "$(jq -r '.status' "$run_dir/cleanup.json")" == failed ]]; then cleanup_status=failed; fi
    jq -n --arg status "$cleanup_status" '{status:$status,reason:"WAN reference creation-owned Pod cleanup"}' \
      >"$run_dir/cleanup.json" || okay=false
    if [[ "$okay" != true ]]; then
      echo 'WAN reference cleanup failed its Lease or creation-ownership check.' >&2
      [[ "$original" != 0 ]] || original=1
    fi
    if [[ "$original" == 0 ]]; then printf '%s\n' "$result"; fi
    exit "$original"
  }
  trap cleanup_reference EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  wan_reference_manifest "$name" "$run_hash" >"$manifest" || return 1
  verify_test_lease_holder "$config" "$holder" || return 1
  creation_attempted=true
  test_create_owned "$ledger" "$manifest" "${kc[@]}" || return 1
  "${kc[@]}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=90s >/dev/null || return 1
  result="$("${kc[@]}" logs "pod/$name" --container reference --tail=1 | tr -d '\r\n ')" || return 1
  printf '%s' "$result" | mise exec -- python3 -c '
import ipaddress, sys
try:
    ipaddress.ip_address(sys.stdin.read())
except ValueError:
    sys.exit(1)
' || return 1
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "$#" == 2 ]] || exit 2
  wan_reference_ip "$1" "$2"
fi
