#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/tautulli.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/tautulli-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

if [[ " $* " == *' config get-contexts homelab-diagnostic --no-headers '* ]]; then
  [[ "$FAKE_LAYOUT" == named ]]
  exit
fi

case " $* " in
  *' get kustomization tautulli '*)
    printf 'True\n'
    ;;
  *' get helmrelease tautulli '*)
    printf 'True\n'
    ;;
  *' rollout status deployment/tautulli '*)
    ;;
  *' get httproute tautulli '*)
    printf 'True\n'
    ;;
  *' exec deployment/tautulli --container app -- curl '*)
    [[ " $* " == *' --write-out %{http_code} '* ]]
    [[ " $* " == *' --max-time 15 --max-redirs 0 '* ]]
    [[ " $* " == *' http://tautulli.media.svc.cluster.local:8181/status '* ]]
    printf '200'
    ;;
  *' proxy '*)
    echo 'kubectl proxy is not an application Service oracle.' >&2
    exit 64
    ;;
  *)
    echo "Unexpected kubectl request: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '192.168.90.30\n'
EOF
chmod +x "$fixture/bin/dig"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *' --write-out %{http_code} '* ]]
[[ " $* " == *' --resolve tautulli.lab.supermorphic.com:443:192.168.90.30 '* ]]
[[ " $* " == *' https://tautulli.lab.supermorphic.com/status '* ]]
printf '200'
EOF
chmod +x "$fixture/bin/curl"

run_layout() {
  local layout="$1"
  local log="$fixture/$layout.log"
  : >"$log"
  PATH="$fixture/bin:$PATH" FAKE_LAYOUT="$layout" FAKE_CALL_LOG="$log" \
    "$verifier" "$fixture/kubeconfig" >"$fixture/$layout.out"
  printf '%s\n' "$log"
}

named_log="$(run_layout named)"
rg -q -- '--context homelab-diagnostic' "$named_log"
rg -q -- 'exec deployment/tautulli --container app -- curl' "$named_log"
rg -q -- 'http://tautulli.media.svc.cluster.local:8181/status' "$named_log"
if rg -q -- ' proxy ' "$named_log"; then
  echo 'Named-context verification unexpectedly used kubectl proxy.' >&2
  exit 1
fi

admin_log="$(run_layout admin)"
if rg -q -- '--context' "$admin_log"; then
  echo 'Admin fallback unexpectedly selected a scoped context.' >&2
  exit 1
fi
rg -q -- 'exec deployment/tautulli --container app -- curl' "$admin_log"

echo 'Tautulli Service and gateway verifier tests passed.'
