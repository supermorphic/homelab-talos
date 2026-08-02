#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/plex-relay-status-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

fake_bin="$temp_dir/bin"
fake_log="$temp_dir/kubectl.log"
output="$temp_dir/output"
mkdir -p "$fake_bin"

cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=("$@")
operation=''

if [[ "${args[4]:-} ${args[5]:-}" == 'get pods' ]]; then
  [[ "$#" -eq 12 \
    && "${args[0]}" == '--kubeconfig' \
    && "${args[2]}" == '--namespace' \
    && "${args[3]}" == 'media' \
    && "${args[6]}" == '--selector' \
    && "${args[7]}" == 'app.kubernetes.io/name=plex' \
    && "${args[8]}" == '--field-selector' \
    && "${args[9]}" == 'status.phase=Running' \
    && "${args[10]}" == '--output' \
    && "${args[11]}" == "jsonpath={.items[0].metadata.name}" ]] || {
      echo "Unexpected get pods invocation: $*" >&2
      exit 9
    }
  operation='get pods'
elif [[ "${args[4]:-}" == 'exec' ]]; then
  [[ "$#" -eq 12 \
    && "${args[0]}" == '--kubeconfig' \
    && "${args[2]}" == '--namespace' \
    && "${args[3]}" == 'media' \
    && "${args[5]}" == 'plex-test-pod' \
    && "${args[6]}" == '-c' \
    && "${args[7]}" == 'app' \
    && "${args[8]}" == '--' \
    && "${args[9]}" == '/bin/bash' \
    && "${args[10]}" == '-ceu' \
    && -n "${args[11]}" ]] || {
      echo "Unexpected exec invocation: $*" >&2
      exit 9
    }
  operation='exec'
else
  echo "Unexpected kubectl invocation: $*" >&2
  exit 9
fi

printf '%s kubectl ' "$operation" >>"$FAKE_KUBECTL_LOG"
printf '%q ' "$@" >>"$FAKE_KUBECTL_LOG"
printf '\n' >>"$FAKE_KUBECTL_LOG"

case "$operation" in
  'get pods')
    printf 'plex-test-pod'
    ;;
  exec)
    printf '%s\n' \
      'relay_current_uid=568' \
      'relay_current_user=plex' \
      'relay_key_cache_readable=yes' \
      'relay_secure_connections_eligible=yes' \
      'Aug 02 DEBUG - Relay: starting relay PLEXTOKEN=secret-value' \
      'Aug 02 DEBUG - [PlexRelay] Authenticated to 203.0.113.10 user@example.com' \
      'Aug 02 INFO - [PlexRelay] Allocated port 31157 for remote forward to 127.0.0.1:32401'
    ;;
esac
EOF
chmod +x "$fake_bin/kubectl"

touch "$temp_dir/kubeconfig"

PATH="$fake_bin:$PATH" FAKE_KUBECTL_LOG="$fake_log" \
  scripts/diagnose/plex-relay-status.sh "$temp_dir/kubeconfig" >"$output" 2>&1

rg -q '^relay_current_uid=568$' "$output"
rg -q '^relay_current_user=plex$' "$output"
rg -q '^relay_key_cache_readable=yes$' "$output"
rg -q '^relay_secure_connections_eligible=yes$' "$output"
rg -q 'Authenticated to 203\.0\.113\.10' "$output"
rg -q 'Allocated port 31157' "$output"
if rg -q 'secret-value|user@example\.com' "$output"; then
  echo 'Relay status output exposed fixture credentials.' >&2
  exit 1
fi

mapfile -t commands <"$fake_log"
[[ "${#commands[@]}" -eq 2 ]]
[[ "${commands[0]}" == 'get pods kubectl '* ]]
[[ "${commands[1]}" == 'exec kubectl '* ]]
if rg -v '^(get pods|exec) kubectl ' "$fake_log"; then
  echo 'Relay status used an unexpected kubectl operation.' >&2
  exit 1
fi
if rg -q -e '(^|[[:space:]])(patch|apply|rollout|suspend|resume|delete|create|replace|scale)([[:space:]]|$)' "$fake_log"; then
  echo 'Relay status attempted a mutating kubectl operation.' >&2
  exit 1
fi
if rg -qi 'PLEXTOKEN|X-Plex-Token|secret-value' "$fake_log"; then
  echo 'Relay status passed credential material to kubectl.' >&2
  exit 1
fi

echo 'Plex Relay status diagnostic tests passed.'
