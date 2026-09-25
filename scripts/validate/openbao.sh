#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/security/openbao'
temp_dir="$(mktemp -d /tmp/homelab-talos-openbao-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for part in namespace app access acceptance; do
  kustomize build "$base/$part" >"$temp_dir/$part.yaml"
done
kustomize build kubernetes/apps/security >"$temp_dir/security.yaml"
helm template openbao oci://ghcr.io/openbao/charts/openbao@sha256:98c8fc901e2579ac6da9a805537fcd7a19525ef8e563ae8737dc16fc8f641e3e \
  --namespace openbao \
  --values "$base/app/values.yaml" >"$temp_dir/rendered.yaml"

uv run --locked python - "$temp_dir" <<'PY'
import pathlib
import sys
import yaml
from scripts.openbao.manifests import (
    validate_documents, validate_issuance_role, validate_gateway_namespace,
    validate_network_policy, validate_tokenrequest_binding, validate_flux_units,
)

root = pathlib.Path(sys.argv[1])
def docs(name):
    return [item for item in yaml.safe_load_all((root / f"{name}.yaml").read_text()) if item]
def one(items, kind, name):
    found = [d for d in items if d.get("kind") == kind and d.get("metadata", {}).get("name") == name]
    assert len(found) == 1, f"expected one {kind}/{name}, found {len(found)}"
    return found[0]

rendered = docs("rendered")
app = docs("app")
acceptance = docs("acceptance")
security = docs("security")
failures = validate_documents(rendered + [one(app, "PodDisruptionBudget", "openbao")])
assert not failures, f"rendered OpenBao invariants: {failures}"
assert not validate_issuance_role(one(acceptance, "Role", "openbao-tokenrequest"))
assert not validate_tokenrequest_binding(one(acceptance, "RoleBinding", "openbao-tokenrequest"))
assert not validate_flux_units(security)
assert not validate_gateway_namespace(one(docs("namespace"), "Namespace", "openbao"))
release = one(app, "HelmRelease", "openbao")
assert release["spec"]["chart"]["spec"]["version"] == "0.29.6"
assert release["spec"]["install"]["disableWait"] is True
assert "remediation" not in release["spec"].get("install", {})
assert "remediation" not in release["spec"].get("upgrade", {})
sts = one(rendered, "StatefulSet", "openbao")
pod = sts["spec"]["template"]["spec"]
claims = sts["spec"]["volumeClaimTemplates"]
assert len(claims) == 1 and claims[0]["metadata"]["name"] == "data"
assert claims[0]["spec"] == {"accessModes": ["ReadWriteOnce"],
                              "resources": {"requests": {"storage": "10Gi"}},
                              "storageClassName": "longhorn"}
container = next(c for c in pod["containers"] if c["name"] == "openbao")
assert container["image"] == "quay.io/openbao/openbao:2.7.0@sha256:71156a1c6623a5fa3f5e61b0c6a8ead0faf0df29a778339188443551995d1315"
assert pod["serviceAccountName"] == "openbao"
assert one(app, "ServiceAccount", "openbao")["automountServiceAccountToken"] is False
assert container["readinessProbe"]["exec"]["command"][-1].startswith("bao status")
assert any(m["name"] == "openbao-tls" and m["mountPath"] == "/openbao/tls" and
           "subPath" not in m for m in container["volumeMounts"])
assert any(v["name"] == "openbao-seal" and v["secret"]["secretName"] == "openbao-seal"
           for v in pod["volumes"])
assert any(v["name"] == "kubernetes-api-token" and "projected" in v for v in pod["volumes"])
token_volume = next(v for v in pod["volumes"] if v["name"] == "kubernetes-api-token")
sources = token_volume["projected"]["sources"]
assert any(s.get("serviceAccountToken", {}).get("expirationSeconds") == 600 for s in sources)
assert any(s.get("configMap", {}).get("name") == "kube-root-ca.crt" for s in sources)
assert len([c for c in pod["containers"] if c["name"] == "openbao"]) == 1
config = one(rendered, "ConfigMap", "openbao-config")["data"]["extraconfig-from-values.hcl"]
for fragment in ['seal "static"', 'file:///openbao/seal/key', 'tls_auto_reload = true',
                 'disable_mlock = true', 'leader_tls_servername = "openbao.lab.supermorphic.com"',
                 'openbao-0.openbao-internal.openbao.svc', 'openbao-1.openbao-internal.openbao.svc',
                 'openbao-2.openbao-internal.openbao.svc']:
    assert fragment in config, f"missing config fragment: {fragment}"
assert 'service_registration' not in config
route = one(docs("access"), "HTTPRoute", "openbao")
assert route["spec"]["hostnames"] == ["openbao.lab.supermorphic.com"]
assert route["spec"]["parentRefs"] == [{"group": "gateway.networking.k8s.io",
    "kind": "Gateway", "name": "internal", "namespace": "networking", "sectionName": "https"}]
assert route["metadata"]["annotations"]["external-dns.k8s.io/audience"] == "internal"
assert route["spec"]["rules"][0]["backendRefs"] == [
    {"kind": "Service", "name": "openbao", "port": 8200}]
policy = one(docs("access"), "BackendTLSPolicy", "openbao")
assert policy["spec"]["validation"] == {"hostname": "openbao.lab.supermorphic.com",
                                           "wellKnownCACertificates": "System"}
assert policy["spec"]["targetRefs"] == [{"group": "", "kind": "Service", "name": "openbao"}]
network = one(app, "CiliumNetworkPolicy", "openbao")["spec"]
assert not validate_network_policy(one(app, "CiliumNetworkPolicy", "openbao"))
assert network["endpointSelector"]["matchLabels"] == {
    "app.kubernetes.io/name": "openbao", "app.kubernetes.io/instance": "openbao",
    "component": "server"}
def port_set(rules):
    return {p["port"] for rule in rules for item in rule.get("toPorts", [])
            for p in item["ports"]}
assert port_set(network["ingress"]) == {"8200", "8201", "8203"}
assert port_set(network["egress"]) == {"53", "443", "8200", "8201"}
for rule in network["ingress"]:
    assert "fromCIDR" not in rule and "fromCIDRSet" not in rule
    assert "fromEntities" in rule or "fromEndpoints" in rule
    for endpoint in rule.get("fromEndpoints", []):
        labels = endpoint.get("matchLabels", {})
        assert labels.get("k8s:io.kubernetes.pod.namespace") in {
            "envoy-gateway-system", "openbao", "openbao-acceptance", "monitoring"}
        assert "app.kubernetes.io/name" in labels or "gateway.envoyproxy.io/owning-gateway-name" in labels
for rule in network["egress"]:
    assert "toCIDR" not in rule and "toCIDRSet" not in rule
    assert "toEntities" in rule or "toEndpoints" in rule
assert any(rule.get("toEntities") == ["kube-apiserver"] and
           rule["toPorts"][0]["ports"] == [{"port": "443", "protocol": "TCP"}]
           for rule in network["egress"])
assert any(rule.get("fromEndpoints", [{}])[0].get("matchLabels", {}).get("app.kubernetes.io/name") ==
           "openbao" and rule["toPorts"][0]["ports"] == [{"port": "8201", "protocol": "TCP"}]
           for rule in network["ingress"])
assert all("fromEntities" not in rule for rule in network["ingress"])
metrics = one(docs("access"), "Service", "openbao-monitoring")
assert metrics["spec"]["ports"] == [{"name": "monitoring", "port": 8203,
                                     "targetPort": "monitoring", "protocol": "TCP"}]
assert metrics["spec"]["selector"] == network["endpointSelector"]["matchLabels"]
assert any(p.get("name") == "monitoring" and p.get("containerPort") == 8203
           for p in container["ports"])
print("OpenBao source, exact TokenRequest role, and official chart render passed validation.")
PY
