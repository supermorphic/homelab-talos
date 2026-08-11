#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/verify/plex.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/plex-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/remote-bin" "$fixture/remote-config"
touch "$fixture/kubeconfig" "$fixture/remote-media"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *' config get-contexts homelab-diagnostic '* ]]; then
  exit 1
fi

case " $* " in
  *' --namespace flux-system get kustomization plex '*)
    printf 'True'
    ;;
  *' --namespace media get helmrelease plex '*)
    printf 'True'
    ;;
  *' --namespace media rollout status deployment/plex '*)
    printf '%s\n' 'deployment "plex" successfully rolled out'
    ;;
  *' --namespace media get pods '*)
    printf 'plex-test-pod'
    ;;
  *' --namespace media exec plex-test-pod -c app -- /bin/bash -ceu '*)
    printf '%s\n' exec >>"$FAKE_EXEC_LOG"
    program="${*: -1}"
    program="${program//\/var\/run\/secrets\/kubernetes.io\/serviceaccount\/token/$FAKE_REMOTE_TOKEN}"
    program="${program//\/Volumes\/Prometheus/$FAKE_REMOTE_MEDIA}"
    program="${program//\/config/$FAKE_REMOTE_CONFIG}"
    PATH="$FAKE_REMOTE_BIN" /bin/bash -ceu "$program"
    ;;
  *' --namespace media get service plex --output json '*)
    if [[ "${FAKE_LAYOUT:-}" == service-wrong-address ]]; then
      printf '{"spec":{"type":"LoadBalancer","externalTrafficPolicy":"Local"},"status":{"loadBalancer":{"ingress":[{"ip":"192.168.90.32"}]}}}\n'
    else
      printf '{"spec":{"type":"LoadBalancer","externalTrafficPolicy":"Local"},"status":{"loadBalancer":{"ingress":[{"ip":"192.168.90.31"}]}}}\n'
    fi
    ;;
  *' --namespace media get httproute plex '*)
    printf 'True'
    ;;
  *)
    echo "Unexpected kubectl invocation: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '192.168.90.30'
EOF
chmod +x "$fixture/bin/dig"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fixture/bin/curl"

cat >"$fixture/remote-bin/id" <<'EOF'
#!/bin/bash
[[ "${1:-}" == '-u' ]] || exit 64
printf '568\n'
EOF
chmod +x "$fixture/remote-bin/id"

cat >"$fixture/remote-bin/getent" <<'EOF'
#!/bin/bash
[[ "$*" == 'passwd 568' ]] || exit 64
printf '%s\n' 'plex:x:568:568:Plex Media Server:/config:/usr/sbin/nologin'
EOF
chmod +x "$fixture/remote-bin/getent"

cat >"$fixture/remote-bin/cut" <<'EOF'
#!/bin/bash
exec /usr/bin/cut "$@"
EOF
chmod +x "$fixture/remote-bin/cut"

cat >"$fixture/remote-bin/findmnt" <<'EOF'
#!/bin/bash
[[ "$*" == '-n -o OPTIONS '* ]] || exit 64
printf '%s\n' "$FAKE_MOUNT_OPTIONS"
EOF
chmod +x "$fixture/remote-bin/findmnt"

cat >"$fixture/remote-bin/tr" <<'EOF'
#!/bin/bash
exec /usr/bin/tr "$@"
EOF
chmod +x "$fixture/remote-bin/tr"

output="$fixture/output"
exec_log="$fixture/exec.log"

run_verifier() {
  local mount_options="$1"
  local layout="${2:-}"
  PATH="$fixture/bin:$PATH" \
    FAKE_EXEC_LOG="$exec_log" \
    FAKE_MOUNT_OPTIONS="$mount_options" \
    FAKE_LAYOUT="$layout" \
    FAKE_REMOTE_BIN="$fixture/remote-bin" \
    FAKE_REMOTE_CONFIG="$fixture/remote-config" \
    FAKE_REMOTE_MEDIA="$fixture/remote-media" \
    FAKE_REMOTE_TOKEN="$fixture/absent-service-account-token" \
    "$verifier" "$fixture/kubeconfig"
}

: >"$exec_log"
set +e
run_verifier 'ro,relatime' >"$output" 2>&1
verifier_status="$?"
set -e
if [[ "$verifier_status" -ne 0 ]]; then
  echo 'Plex verifier failed when the application container lacked ripgrep.' >&2
  cat "$output" >&2
  exit 1
fi

[[ "$(wc -l <"$exec_log" | tr -d ' ')" == '1' ]]
rg -q 'Phase 11 Plex acceptance passed' "$output"

for mount_options in 'rw,relatime' 'rw,errors=remount-ro'; do
  : >"$exec_log"
  set +e
  run_verifier "$mount_options" >"$output" 2>&1
  verifier_status="$?"
  set -e
  if [[ "$verifier_status" -eq 0 ]]; then
    echo "Plex verifier accepted writable media mount options: $mount_options" >&2
    cat "$output" >&2
    exit 1
  fi
  [[ "$(wc -l <"$exec_log" | tr -d ' ')" == '1' ]]
done

: >"$exec_log"
set +e
run_verifier 'ro,relatime' service-wrong-address >"$output" 2>&1
verifier_status="$?"
set -e
if [[ "$verifier_status" -eq 0 ]]; then
  echo 'Plex verifier accepted a Service that does not hold 192.168.90.31.' >&2
  cat "$output" >&2
  exit 1
fi
rg -qx 'Plex Service does not hold exactly 192.168.90.31.' "$output" || {
  echo 'Plex verifier failed the wrong-address case, but not with the expected message.' >&2
  cat "$output" >&2
  exit 1
}

echo 'Plex verifier minimal-container test passed.'
