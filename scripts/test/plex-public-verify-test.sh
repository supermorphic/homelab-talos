#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/plex-public.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/plex-public-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

if [[ " $* " == *' config get-contexts homelab-diagnostic --no-headers '* ]]; then
  exit 0
fi

case " $* " in
  *' --namespace flux-system get kustomization public-gateway --output json '*)
    cat <<'JSON'
{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"name":"public-gateway","namespace":"flux-system"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}
JSON
    ;;
  *' --namespace networking-public get certificate plex-lab-supermorphic-com --output json '*)
    cat <<'JSON'
{"apiVersion":"cert-manager.io/v1","kind":"Certificate","metadata":{"name":"plex-lab-supermorphic-com","namespace":"networking-public"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}
JSON
    ;;
  *' --namespace metallb-system get ipaddresspool public --output json '*)
    cat <<'JSON'
{"apiVersion":"metallb.io/v1beta1","kind":"IPAddressPool","metadata":{"name":"public","namespace":"metallb-system"},"spec":{"addresses":["192.168.90.39/32"],"autoAssign":false}}
JSON
    ;;
  *' --namespace metallb-system get ipaddresspool internal --output json '*)
    if [[ "$FAKE_LAYOUT" == wide-internal-pool ]]; then
      addresses='["192.168.90.30-192.168.90.39"]'
    else
      addresses='["192.168.90.30-192.168.90.38"]'
    fi
    cat <<JSON
{"apiVersion":"metallb.io/v1beta1","kind":"IPAddressPool","metadata":{"name":"internal","namespace":"metallb-system"},"spec":{"addresses":$addresses,"autoAssign":false}}
JSON
    ;;
  *' get gatewayclass public --output json '*)
    cat <<'JSON'
{"apiVersion":"gateway.networking.k8s.io/v1","kind":"GatewayClass","metadata":{"name":"public"},"status":{"conditions":[{"type":"Accepted","status":"True"}]}}
JSON
    ;;
  *' --namespace networking-public get gateway public --output json '*)
    cat <<'JSON'
{"apiVersion":"gateway.networking.k8s.io/v1","kind":"Gateway","metadata":{"name":"public","namespace":"networking-public"},"status":{"addresses":[{"type":"IPAddress","value":"192.168.90.39"}],"conditions":[{"type":"Programmed","status":"True"}],"listeners":[{"name":"https","conditions":[{"type":"Accepted","status":"True"}]}]}}
JSON
    ;;
  *' --namespace envoy-gateway-system get deployments --selector gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public --output json '*)
    cat <<'JSON'
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"envoy-public","namespace":"envoy-gateway-system","labels":{"gateway.envoyproxy.io/owning-gateway-namespace":"networking-public","gateway.envoyproxy.io/owning-gateway-name":"public"}},"spec":{"replicas":2},"status":{"availableReplicas":2}}]}
JSON
    ;;
  *' --namespace envoy-gateway-system get services --selector gateway.envoyproxy.io/owning-gateway-namespace=networking-public,gateway.envoyproxy.io/owning-gateway-name=public --output json '*)
    if [[ "$FAKE_LAYOUT" == extra-service-port ]]; then
      ports='[{"name":"https","port":443,"protocol":"TCP"},{"name":"admin","port":9901,"protocol":"TCP"}]'
    else
      ports='[{"name":"https","port":443,"protocol":"TCP"}]'
    fi
    printf '{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Service","metadata":{"name":"envoy-public","namespace":"envoy-gateway-system","labels":{"gateway.envoyproxy.io/owning-gateway-namespace":"networking-public","gateway.envoyproxy.io/owning-gateway-name":"public"}},"spec":{"type":"LoadBalancer","ports":%s},"status":{"loadBalancer":{"ingress":[{"ip":"192.168.90.39"}]}}}]}\n' "$ports"
    ;;
  *' --namespace media get httproute plex-public --output json '*)
    cat <<'JSON'
{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"plex-public","namespace":"media"},"status":{"parents":[{"parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","namespace":"networking-public","name":"public","sectionName":"https"},"conditions":[{"type":"Accepted","status":"True"},{"type":"ResolvedRefs","status":"True"}]}]}}
JSON
    ;;
  *' --namespace media get httproute plex --output json '*)
    cat <<'JSON'
{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"plex","namespace":"media"},"status":{"parents":[{"parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","namespace":"networking","name":"internal","sectionName":"https"},"conditions":[{"type":"Accepted","status":"True"},{"type":"ResolvedRefs","status":"True"}]}]}}
JSON
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
printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"
printf '192.168.90.30\n'
EOF
chmod +x "$fixture/bin/dig"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

case " $* " in
  *'--resolve plex.lab.supermorphic.com:443:192.168.90.39'*'https://plex.lab.supermorphic.com/identity'*)
    printf '<MediaContainer machineIdentifier="fixture"/>\n'
    ;;
  *'--resolve echo.lab.supermorphic.com:443:192.168.90.39'*'https://echo.lab.supermorphic.com/'*)
    [[ "$FAKE_LAYOUT" == alternate-sni-serves ]]
    ;;
  *'http://192.168.90.39:443/'*)
    if [[ "$FAKE_LAYOUT" == raw-http-404 ]]; then
      [[ " $* " != *' --fail '* ]] || exit 22
      printf 'not found\n'
      exit 0
    fi
    [[ "$FAKE_LAYOUT" == raw-http-serves ]]
    ;;
  *)
    echo "Unexpected curl request: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/curl"

cat >"$fixture/bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"
case " $* " in
  ' kube foundation-verify '|' kube gatus-verify '|' kube plex-verify ')
    ;;
  *)
    echo "Unexpected just request: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/just"

tcp_probe() {
  printf 'tcp_probe %q %q\n' "$1" "$2" >>"$FAKE_CALL_LOG"
  [[ "$FAKE_LAYOUT" == "tcp-$2-serves" ]]
}
tls_without_sni() {
  printf 'tls_without_sni %q %q\n' "$1" "$2" >>"$FAKE_CALL_LOG"
  [[ "$FAKE_LAYOUT" == absent-sni-serves ]]
}
export -f tcp_probe tls_without_sni

run_layout() {
  local layout="$1"
  local log="$fixture/$layout.log"
  : >"$log"
  if ! PATH="$fixture/bin:$PATH" FAKE_LAYOUT="$layout" FAKE_CALL_LOG="$log" \
    "$verifier" "$fixture/kubeconfig" >"$fixture/$layout.out" 2>"$fixture/$layout.err"; then
    cat "$fixture/$layout.err" >&2
    exit 1
  fi
  printf '%s\n' "$log"
}

run_layout_expect_failure() {
  local layout="$1"
  local expected_error="$2"
  local log="$fixture/$layout.log"
  : >"$log"
  if PATH="$fixture/bin:$PATH" FAKE_LAYOUT="$layout" FAKE_CALL_LOG="$log" \
    "$verifier" "$fixture/kubeconfig" >"$fixture/$layout.out" 2>"$fixture/$layout.err"; then
    echo "$layout verification unexpectedly passed." >&2
    exit 1
  fi
  rg -F -q -- "$expected_error" "$fixture/$layout.err" || {
    cat "$fixture/$layout.err" >&2
    echo "$layout verification did not report: $expected_error" >&2
    exit 1
  }
}

happy_log="$(run_layout happy)"
rg -q -- '--context homelab-diagnostic' "$happy_log"
rg -F -q -- '--resolve plex.lab.supermorphic.com:443:192.168.90.39' "$happy_log"
rg -F -q -- '--resolve echo.lab.supermorphic.com:443:192.168.90.39' "$happy_log"
rg -q -- '--insecure .*--resolve echo\.lab\.supermorphic\.com:443:192\.168\.90\.39' "$happy_log"
rg -F -q -- 'tcp_probe 192.168.90.39 80' "$happy_log"
rg -F -q -- 'tcp_probe 192.168.90.39 32400' "$happy_log"
rg -F -q -- 'tcp_probe 192.168.90.39 9901' "$happy_log"
rg -F -q -- 'tcp_probe 192.168.90.39 19000' "$happy_log"
rg -F -q -- 'tls_without_sni 192.168.90.39 443' "$happy_log"
rg -F -q -- 'kube foundation-verify' "$happy_log"
rg -F -q -- 'kube gatus-verify' "$happy_log"
rg -F -q -- 'kube plex-verify' "$happy_log"

run_layout_expect_failure wide-internal-pool 'Internal IPAddressPool must exclude the public VIP.'
run_layout_expect_failure extra-service-port 'Public Envoy Service must expose only TCP 443.'
run_layout_expect_failure alternate-sni-serves 'Public Envoy served an alternate SNI hostname.'
run_layout_expect_failure absent-sni-serves 'Public Envoy completed TLS without SNI.'
run_layout_expect_failure raw-http-serves 'Public Envoy served raw-IP HTTP on TCP 443.'
run_layout_expect_failure raw-http-404 'Public Envoy served raw-IP HTTP on TCP 443.'
run_layout_expect_failure tcp-9901-serves 'Public gateway VIP unexpectedly accepted TCP 9901.'

echo 'Plex public isolation verifier tests passed.'
