#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

base='kubernetes/apps/media/qbittorrent'
ks="$base/ks.yaml"
hr="$base/app/helmrelease.yaml"
values="$base/app/values.yaml"
route="$base/app/httproute.yaml"
secret="$base/app/protonvpn.sops.yaml"
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
expected_recipient="$(yq -r '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age' .sops.yaml)"
temp_dir="$(mktemp -d /tmp/homelab-talos-qbt-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$values" "$route" "$secret" "$base/app/kustomization.yaml" "$oci"; do
  [[ -f "$f" ]] || {
    echo "Missing qBittorrent source: $f" >&2
    echo 'Run just repo protonvpn-secrets if the ProtonVPN Secret is missing.' >&2
    exit 1
  }
done

rg -qx '  - ./qbittorrent/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
  echo 'Refusing: ./qbittorrent/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,media-storage' ]]
[[ "$(yq -r '.spec.decryption.provider' "$ks")" == 'sops' ]]
[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

[[ "$(sops filestatus "$secret" | yq -r '.encrypted')" == 'true' ]]
[[ "$(yq -r '.sops.age[].recipient' "$secret" | sort -u)" == "$expected_recipient" ]]
[[ "$(yq -r '.metadata.name' "$secret")" == 'protonvpn' ]]
[[ "$(yq -r '.metadata.namespace' "$secret")" == 'media' ]]

# Both Secret consumers load their values only when the Pod starts: the WireGuard key
# is an environment variable and config.toml uses a subPath mount. Tie the encrypted
# Secret revision to the Pod template so a Git-managed rotation replaces the Pod.
secret_revision="$(git hash-object "$secret")"
rollout_revision="$(yq -r '.controllers.qbittorrent.pod.annotations."sops-hash" // ""' "$values")"
[[ "$rollout_revision" == "$secret_revision" ]] || {
  echo "qbittorrent pod annotation sops-hash ($rollout_revision) must equal git hash-object of protonvpn.sops.yaml ($secret_revision)." >&2
  exit 1
}

# Gluetun native sidecar + kill-switch essentials.
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.restartPolicy' "$values")" == 'Always' ]]
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.securityContext.capabilities.add[]' "$values" | tr '\n' ' ')" == 'NET_ADMIN ' ]]
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.VPN_SERVICE_PROVIDER' "$values")" == 'protonvpn' ]]
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.VPN_PORT_FORWARDING' "$values")" == 'on' ]]
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.PORT_FORWARD_ONLY' "$values")" == 'on' ]]
[[ -n "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.SERVER_COUNTRIES // ""' "$values")" ]]
# WebUI (8080) + control server (8000) admitted on the pod interface.
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.FIREWALL_INPUT_PORTS' "$values")" == '8000,8080' ]]
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH' "$values")" == '/gluetun/auth/config.toml' ]]
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.VPN_PORT_FORWARDING_UP_COMMAND' "$values")" != 'null' ]]
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.env.VPN_PORT_FORWARDING_DOWN_COMMAND' "$values")" != 'null' ]]
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.startup.spec.httpGet.port' "$values")" == '8000' ]]
# Deliberately-slow k8s liveness fallback: restart gluetun only after a sustained
# stuck-VPN state (running but no forwarded port). Public IP is deliberately not the
# signal: its one-shot metadata fetch can fail on an otherwise working tunnel.
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.enabled' "$values")" == 'true' ]]
[[ "$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.custom' "$values")" == 'true' ]]
probe_cmd="$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.spec.exec.command[2]' "$values")"
[[ "$probe_cmd" == *'/v1/portforward'* ]]
[[ "$probe_cmd" != *'/v1/publicip/ip'* ]]
[[ "$probe_cmd" == *'"status":"stopped"'* ]]
[[ "$probe_cmd" == *'"status":"running"'* ]]
[[ "$probe_cmd" == *'|| exit 1'* ]]
lft="$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.spec.failureThreshold' "$values")"
lps="$(yq -r '.controllers.qbittorrent.initContainers.gluetun.probes.liveness.spec.periodSeconds' "$values")"
[[ "$lft" =~ ^[0-9]+$ && "$lps" =~ ^[0-9]+$ && $(( lft * lps )) -ge 180 ]] || { echo 'gluetun liveness must be deliberately slow (failureThreshold*periodSeconds >= 180s).' >&2; exit 1; }
# Only Gluetun is privileged; qBittorrent drops all caps.
[[ "$(yq -r '.controllers.qbittorrent.containers.app.securityContext.capabilities.drop[]' "$values" | tr '\n' ' ')" == 'ALL ' ]]
# Device + auth config mounted; config on Longhorn RWO; shared /data.
[[ "$(yq -r '.persistence.tun.hostPath' "$values")" == '/dev/net/tun' ]]
[[ "$(yq -r '.persistence.tun.hostPathType' "$values")" == 'CharDevice' ]]
[[ "$(yq -r '.persistence."gluetun-auth".type' "$values")" == 'secret' ]]
[[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
[[ "$(yq -r '.persistence.data.existingClaim' "$values")" == 'media-data' ]]

[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'qbittorrent.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.username"' "$route")" == '{{HOMEPAGE_VAR_QBITTORRENT_USERNAME}}' ]]
[[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.password"' "$route")" == '{{HOMEPAGE_VAR_QBITTORRENT_PASSWORD}}' ]]

# Reactive VPN-down alerting: in-cluster control-server Service (no HTTPRoute) +
# a critical PrometheusRule fed by the Gatus health probe.
svc="$base/app/service-gluetun-control.yaml"
# The rule lives in the media alerts application; placement and wiring belong to
# `just kube alerts-validate media`. The content contract stays here.
rule='kubernetes/apps/media/alerts/app/qbittorrent.yaml'
[[ -f "$svc" && -f "$rule" ]] || {
  echo "Missing VPN-alert source ($svc / $rule)." >&2
  exit 1
}
[[ "$(yq -r '.kind' "$svc")" == 'Service' ]]
[[ "$(yq -r '.metadata.name' "$svc")" == 'qbittorrent-gluetun-control' ]]
[[ "$(yq -r '.spec.ports[0].port' "$svc")" == '8000' ]]
# The control server must never be routed to the gateway/LB.
assert_command_finds_nothing \
  'The Gluetun control service must not be exposed through the HTTPRoute.' \
  rg -qi 'gluetun-control' "$route"
[[ "$(yq -r '.kind' "$rule")" == 'PrometheusRule' ]]
[[ "$(yq -r '[.spec.groups[].rules[] | select(.alert == "QbittorrentVpnDown") | .labels.severity] | .[0]' "$rule")" == 'critical' ]]
[[ "$(yq -r '[.spec.groups[].rules[] | select(.alert == "QbittorrentGluetunRestartLoop") | .labels.severity] | .[0]' "$rule")" == 'critical' ]]
# The VPN kill switch is behaviorally unproven under an in-place Gluetun crash (item 6
# deferred), so guarantee the detect layer stays present: the probe-missing alert must not
# silently disappear alongside the two above.
[[ -n "$(yq -r '[.spec.groups[].rules[] | select(.alert == "QbittorrentVpnProbeMissing") | .alert] | .[0]' "$rule")" ]]
rg -q 'gatus_results_endpoint_success' "$rule"
rg -q 'kube_pod_init_container_status_restarts_total' "$rule"
# The Gatus health probe that feeds the rule must exist.
rg -q 'name: qbittorrent-vpn' kubernetes/apps/monitoring/gatus/app/values.yaml
rg -q 'status == running' kubernetes/apps/monitoring/gatus/app/values.yaml

chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
kustomize build "$base/app" >/dev/null
helm template qbittorrent "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
[[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'qbittorrent' ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."sops-hash"' "$temp_dir/render.yaml")" == "$secret_revision" ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.template.spec.initContainers[] | select(.name == "gluetun") | .restartPolicy' "$temp_dir/render.yaml")" == 'Always' ]]
yq -r 'select(.kind == "Deployment") | .spec.template.spec.initContainers[] | select(.name == "gluetun") | .livenessProbe.exec.command[]' "$temp_dir/render.yaml" | rg -q '/v1/portforward'

echo 'qBittorrent+Gluetun source, encrypted ProtonVPN Secret, sidecar/kill-switch config, dependency graph, and pinned render passed validation.'
