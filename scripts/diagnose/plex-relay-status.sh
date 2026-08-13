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
#
# It reports facts instead of asserting them. An earlier version ran under `-ceu` and
# treated every check as a preconditionse, so a single unmet condition killed the program
# and the command substitution below discarded everything it had already produced. The
# script then exited 1 with no output at all, which reads as "nothing wrong" precisely
# when something is.
# shellcheck disable=SC2016
inner_program='
    uid="$(id -u)"
    user="$(getent passwd "$uid" | cut -d: -f1)"
    printf "relay_current_uid=%s\n" "$uid"
    printf "relay_current_user=%s\n" "$user"
    if [[ "$uid" == "568" && "$user" == "plex" ]]; then
      echo "relay_runtime_identity=ok"
    else
      echo "relay_runtime_identity=unexpected"
    fi

    key_file="/config/Library/Application Support/Plex Media Server/Cache/relayHostKey.txt"
    if [[ -r "$key_file" ]]; then
      echo "relay_key_cache_readable=yes"
    else
      echo "relay_key_cache_readable=no"
    fi

    prefs_file="/config/Library/Application Support/Plex Media Server/Preferences.xml"
    secure_connections="$(xmlstarlet sel -T -t -v "/Preferences/@secureConnections" "$prefs_file" 2>/dev/null)"
    # Plex omits any preference left at its default, so an absent attribute means the
    # default rather than an error. Treating absence as failure is the specific defect
    # that made this diagnostic exit silently: Secure connections sits at Preferred,
    # which is the default, so the attribute is simply not written.
    [[ -n "$secure_connections" ]] || secure_connections="default"
    printf "relay_secure_connections=%s\n" "$secure_connections"
    case "$secure_connections" in
      1 | 2 | default) echo "relay_secure_connections_eligible=yes" ;;
      *) echo "relay_secure_connections_eligible=no" ;;
    esac

    log_file="/config/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log"
    if [[ -r "$log_file" ]]; then
      echo "relay_log_readable=yes"
      tail -n 5000 "$log_file"
    else
      echo "relay_log_readable=no"
    fi
'

# Keep the output even when the exec fails, then report the failure separately.
set +e
raw_status="$("${kc[@]}" --namespace media exec "$pod" -c app -- \
  /bin/bash -cu "$inner_program" 2>&1)"
exec_status="$?"
set -e

redacted="$(printf '%s\n' "$raw_status" | sed -E \
  -e 's/(PLEXTOKEN=)[^[:space:]]+/\1<redacted>/g' \
  -e 's/(X-Plex-Token=)[^&[:space:]]+/\1<redacted>/g' \
  -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<redacted-email>/g')"

printf '%s\n' "$redacted" | rg -i '^relay_|startRelay|Relay: starting relay|PlexRelay.*(Authenticated|Allocated port|exited)' || true

if [[ "$exec_status" -ne 0 ]]; then
  echo "plex-relay-status: the in-container program exited ${exec_status}; output above is what it produced before failing." >&2
  exit "$exec_status"
fi
