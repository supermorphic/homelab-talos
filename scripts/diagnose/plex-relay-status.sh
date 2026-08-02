#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: plex-relay-status.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
kc=(kubectl --kubeconfig "$kubeconfig")
if "${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1; then
  kc+=(--context homelab-diagnostic)
fi

pod="$("${kc[@]}" --namespace media get pods \
  --selector app.kubernetes.io/name=plex \
  --field-selector status.phase=Running \
  --output jsonpath='{.items[0].metadata.name}')"
[[ -n "$pod" ]] || {
  echo 'No running Plex pod found in namespace media.' >&2
  exit 1
}

# This single-quoted program expands only inside the Plex container.
# shellcheck disable=SC2016
raw_status="$("${kc[@]}" --namespace media exec "$pod" -c app -- \
  /bin/bash -ceu '
    uid="$(id -u)"
    user="$(getent passwd "$uid" | cut -d: -f1)"
    [[ "$uid" == "568" && "$user" == "plex" ]]
    printf "relay_current_uid=%s\n" "$uid"
    printf "relay_current_user=%s\n" "$user"

    key_file="/config/Library/Application Support/Plex Media Server/Cache/relayHostKey.txt"
    [[ -r "$key_file" ]]
    echo "relay_key_cache_readable=yes"

    prefs_file="/config/Library/Application Support/Plex Media Server/Preferences.xml"
    secure_connections="$(xmlstarlet sel -T -t -v "/Preferences/@secureConnections" "$prefs_file")"
    [[ "$secure_connections" == "1" || "$secure_connections" == "2" ]]
    echo "relay_secure_connections_eligible=yes"

    tail -n 5000 "/config/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log"
  ' 2>&1)"

printf '%s\n' "$raw_status" | sed -E \
  -e 's/(PLEXTOKEN=)[^[:space:]]+/\1<redacted>/g' \
  -e 's/(X-Plex-Token=)[^&[:space:]]+/\1<redacted>/g' \
  -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<redacted-email>/g' |
  rg -i '^relay_|startRelay|Relay: starting relay|PlexRelay.*(Authenticated|Allocated port|exited)' || true
