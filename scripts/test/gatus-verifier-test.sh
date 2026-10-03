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
name=''
for probe in echo openbao caddy semaphore forgejo; do
  if [[ " $* " == *"name=\"$probe\""* ]]; then name="$probe"; break; fi
done
[[ -n "$name" ]] || exit 2
value=1
sample_time="$GATUS_TEST_SAMPLE_TIME"
if [[ "$name" == "${GATUS_TEST_PROBE:-}" ]]; then
  value="$GATUS_TEST_VALUE"
  sample_time="$((sample_time + ${GATUS_TEST_TIME_OFFSET:-0}))"
fi
if [[ " $* " == *'gatus_results_total'* ]]; then
  if [[ "$name" == "${GATUS_TEST_PROBE:-}" ]]; then value="$GATUS_TEST_ACTIVITY"; fi
  printf '{"status":"success","data":{"result":[{"metric":{},"value":[%s,"%s"]}]}}\n' \
    "$sample_time" "$value"
  exit 0
fi
if [[ "$value" == missing ]]; then
  printf '%s\n' '{"status":"success","data":{"result":[]}}'
else
  printf '{"status":"success","data":{"result":[{"metric":{"group":"Platform","name":"%s"},"value":[%s,"%s"]}]}}\n' \
    "$name" "$sample_time" "$value"
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
export GATUS_TEST_VALUE=1

bash scripts/verify/gatus.sh "$work/kubeconfig" >"$work/output"
for probe in echo openbao caddy semaphore forgejo; do
  export GATUS_TEST_PROBE="$probe"
  for value in 0 missing; do
    if GATUS_TEST_VALUE="$value" bash scripts/verify/gatus.sh "$work/kubeconfig" >"$work/output" 2>&1; then
      echo "Gatus verification accepted $probe probe state: $value" >&2
      exit 1
    fi
  done
  for offset in -300 300; do
    if GATUS_TEST_TIME_OFFSET="$offset" bash scripts/verify/gatus.sh "$work/kubeconfig" >"$work/output" 2>&1; then
      echo "Gatus verification accepted $probe probe timestamp offset: $offset" >&2
      exit 1
    fi
  done
  if [[ "$probe" != echo ]] && GATUS_TEST_ACTIVITY=0 \
    bash scripts/verify/gatus.sh "$work/kubeconfig" >"$work/output" 2>&1; then
    echo "Gatus verification accepted $probe without recent execution." >&2
    exit 1
  fi
done

echo 'Gatus verification requires fresh successful echo, OpenBao, Caddy, Semaphore, and Forgejo probes, with recent application and off-cluster executions.'
