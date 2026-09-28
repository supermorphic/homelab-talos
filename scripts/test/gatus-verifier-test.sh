#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *' rollout status '* ]]; then exit 0; fi
if [[ " $* " == *' get httproute '* ]]; then
  printf '%s\n' '{"status":{"parents":[{"conditions":[{"type":"Accepted","status":"True"}]}]}}'
else
  printf 'True'
fi
EOF
cat >"$work/bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$GATUS_TEST_VIP"
EOF
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *'/health'* ]]; then exit 0; fi
if [[ " $* " == *'gatus_results_total'* ]]; then
  printf '{"status":"success","data":{"result":[{"metric":{},"value":[%s,"%s"]}]}}\n' \
    "$GATUS_TEST_SAMPLE_TIME" "$GATUS_TEST_ACTIVITY"
  exit 0
fi
if [[ " $* " == *'name="echo"'* ]]; then
  name=echo
  value=1
else
  name=openbao
  value="$GATUS_TEST_OPENBAO_VALUE"
fi
if [[ "$value" == missing ]]; then
  printf '%s\n' '{"status":"success","data":{"result":[]}}'
else
  printf '{"status":"success","data":{"result":[{"metric":{"group":"Platform","name":"%s"},"value":[%s,"%s"]}]}}\n' \
    "$name" "$GATUS_TEST_SAMPLE_TIME" "$value"
fi
EOF
cat >"$work/bin/just" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$work/bin/"*

export PATH="$work/bin:$PATH"
export GATUS_TEST_VIP="$HOMELAB_GATEWAY_VIP"
GATUS_TEST_SAMPLE_TIME="$(date -u +%s)"
export GATUS_TEST_SAMPLE_TIME
export GATUS_TEST_ACTIVITY=1

GATUS_TEST_OPENBAO_VALUE=1 bash scripts/verify/gatus.sh "$work/kubeconfig" >"$work/output"
for value in 0 missing; do
  if GATUS_TEST_OPENBAO_VALUE="$value" bash scripts/verify/gatus.sh "$work/kubeconfig" >"$work/output" 2>&1; then
    echo "Gatus verification accepted OpenBao probe state: $value" >&2
    exit 1
  fi
done
GATUS_TEST_ACTIVITY=0 GATUS_TEST_OPENBAO_VALUE=1 \
  bash scripts/verify/gatus.sh "$work/kubeconfig" >"$work/output" 2>&1 && {
    echo 'Gatus verification accepted an OpenBao probe without recent execution.' >&2
    exit 1
  }

echo 'Gatus verification accepts only a fresh successful OpenBao probe.'
