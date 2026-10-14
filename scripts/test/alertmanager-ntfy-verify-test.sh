#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/alertmanager-ntfy.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/alertmanager-ntfy-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' get kustomization alertmanager-ntfy '*) printf 'True\n' ;;
  *' get helmrelease alertmanager-ntfy '*) printf 'True\n' ;;
  *' rollout status deployment/alertmanager-ntfy '*) ;;
  *) echo "Unexpected kubectl request: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FAKE_CONFIG="$FAKE_ALERTMANAGER_CONFIG" yq --null-input --output-format json \
  '{"config": {"original": strenv(FAKE_CONFIG)}}'
EOF
chmod +x "$fixture/bin/curl"

cat >"$fixture/bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'kube foundation-verify' ]]
EOF
chmod +x "$fixture/bin/just"

valid_config=$'route:\n  routes:\n    - receiver: ntfy\nreceivers:\n  - name: ntfy\n    webhook_configs:\n      - url: <secret>'
PATH="$fixture/bin:$PATH" \
FAKE_ALERTMANAGER_CONFIG="$valid_config" \
  "$verifier" "$fixture/kubeconfig" >"$fixture/valid.out"
rg -q 'Alertmanager ntfy receiver and route are loaded' "$fixture/valid.out"

missing_route=$'route:\n  routes: []\nreceivers:\n  - name: ntfy\n    webhook_configs:\n      - url: <secret>'
if PATH="$fixture/bin:$PATH" \
  FAKE_ALERTMANAGER_CONFIG="$missing_route" \
    "$verifier" "$fixture/kubeconfig" >"$fixture/missing-route.out" 2>&1; then
  echo 'Alertmanager verifier accepted an ntfy receiver with no ntfy route.' >&2
  exit 1
fi
rg -q 'loaded config does not contain both the ntfy receiver and route' \
  "$fixture/missing-route.out"

echo 'Alertmanager redacted loaded-config verifier tests passed.'
