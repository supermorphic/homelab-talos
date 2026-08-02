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

if [[ "${args[2]:-}" == 'config' && "${args[3]:-}" == 'get-contexts' ]]; then
  [[ "$#" -eq 6 \
    && "${args[0]}" == '--kubeconfig' \
    && "${args[1]}" == "$FAKE_KUBECONFIG" \
    && "${args[4]}" == 'homelab-diagnostic' \
    && "${args[5]}" == '--no-headers' ]] || {
      echo "Unexpected context lookup: $*" >&2
      exit 9
    }
  operation='context lookup'
elif [[ "${args[4]:-} ${args[5]:-}" == 'get pods' || "${args[6]:-} ${args[7]:-}" == 'get pods' ]]; then
  context_args=0
  if [[ "${args[2]:-}" == '--context' ]]; then
    [[ "${args[3]:-}" == 'homelab-diagnostic' ]] || exit 9
    context_args=2
  fi
  [[ ( "$FAKE_KUBECONFIG_LAYOUT" == 'scoped' && "$context_args" -eq 2 ) || ( "$FAKE_KUBECONFIG_LAYOUT" == 'operator' && "$context_args" -eq 0 ) ]] || {
      echo "Unexpected context selection for $FAKE_KUBECONFIG_LAYOUT kubeconfig: $*" >&2
      exit 9
    }
  [[ "$#" -eq $((12 + context_args)) \
    && "${args[0]}" == '--kubeconfig' \
    && "${args[1]}" == "$FAKE_KUBECONFIG" \
    && "${args[$((2 + context_args))]}" == '--namespace' \
    && "${args[$((3 + context_args))]}" == 'media' \
    && "${args[$((6 + context_args))]}" == '--selector' \
    && "${args[$((7 + context_args))]}" == 'app.kubernetes.io/name=plex' \
    && "${args[$((8 + context_args))]}" == '--field-selector' \
    && "${args[$((9 + context_args))]}" == 'status.phase=Running' \
    && "${args[$((10 + context_args))]}" == '--output' \
    && "${args[$((11 + context_args))]}" == "jsonpath={.items[0].metadata.name}" ]] || {
      echo "Unexpected get pods invocation: $*" >&2
      exit 9
    }
  operation='get pods'
elif [[ "${args[4]:-}" == 'exec' || "${args[6]:-}" == 'exec' ]]; then
  context_args=0
  if [[ "${args[2]:-}" == '--context' ]]; then
    [[ "${args[3]:-}" == 'homelab-diagnostic' ]] || exit 9
    context_args=2
  fi
  [[ ( "$FAKE_KUBECONFIG_LAYOUT" == 'scoped' && "$context_args" -eq 2 ) || ( "$FAKE_KUBECONFIG_LAYOUT" == 'operator' && "$context_args" -eq 0 ) ]] || {
      echo "Unexpected context selection for $FAKE_KUBECONFIG_LAYOUT kubeconfig: $*" >&2
      exit 9
    }
  [[ "$#" -eq $((12 + context_args)) \
    && "${args[0]}" == '--kubeconfig' \
    && "${args[1]}" == "$FAKE_KUBECONFIG" \
    && "${args[$((2 + context_args))]}" == '--namespace' \
    && "${args[$((3 + context_args))]}" == 'media' \
    && "${args[$((5 + context_args))]}" == 'plex-test-pod' \
    && "${args[$((6 + context_args))]}" == '-c' \
    && "${args[$((7 + context_args))]}" == 'app' \
    && "${args[$((8 + context_args))]}" == '--' \
    && "${args[$((9 + context_args))]}" == '/bin/bash' \
    && "${args[$((10 + context_args))]}" == '-ceu' \
    && -n "${args[$((11 + context_args))]}" ]] || {
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
  'context lookup')
    [[ "$FAKE_KUBECONFIG_LAYOUT" == 'scoped' ]] || exit 1
    ;;
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
    printf '%s\n' \
      'Aug 02 DEBUG - Relay: starting relay PLEXTOKEN=stderr-token-leak' \
      'Aug 02 DEBUG - [PlexRelay] Authenticated to 198.51.100.20 stderr-account@example.net' >&2
    ;;
esac
EOF
chmod +x "$fake_bin/kubectl"

run_case() {
  local layout="$1"
  : >"$fake_log"
  PATH="$fake_bin:$PATH" FAKE_KUBECTL_LOG="$fake_log" \
    FAKE_KUBECONFIG="$temp_dir/kubeconfig" FAKE_KUBECONFIG_LAYOUT="$layout" \
    scripts/diagnose/plex-relay-status.sh "$temp_dir/kubeconfig" >"$output" 2>&1

rg -q '^relay_current_uid=568$' "$output"
rg -q '^relay_current_user=plex$' "$output"
rg -q '^relay_key_cache_readable=yes$' "$output"
rg -q '^relay_secure_connections_eligible=yes$' "$output"
rg -q 'Authenticated to 203\.0\.113\.10' "$output"
rg -q 'Authenticated to 198\.51\.100\.20' "$output"
rg -q 'Allocated port 31157' "$output"
if rg -q 'secret-value|user@example\.com|stderr-token-leak|stderr-account@example\.net' "$output"; then
  echo 'Relay status output exposed fixture credentials.' >&2
  exit 1
fi

  mapfile -t commands <"$fake_log"
  [[ "${#commands[@]}" -eq 3 ]]
  [[ "${commands[0]}" == 'context lookup kubectl '* ]]
  [[ "${commands[1]}" == 'get pods kubectl '* ]]
  [[ "${commands[2]}" == 'exec kubectl '* ]]
  if rg -v '^(context lookup|get pods|exec) kubectl ' "$fake_log"; then
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
}

touch "$temp_dir/kubeconfig"

run_case scoped
run_case operator

echo 'Plex Relay status diagnostic tests passed.'
