#!/usr/bin/env python3
"""Validate source invariants for the private web research platform."""

import argparse
import re
from pathlib import Path

import yaml

BASE = Path("kubernetes/apps/web-research")


def quantity(value):
    match = re.fullmatch(r"(\d+)(Ki|Mi|Gi)?", str(value))
    if not match:
        raise ValueError("unsupported memory quantity")
    return int(match[1]) * {None: 1, "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3}[match[2]]


def ui_errors(route):
    errors = []
    spec = route.get("spec", {})
    refs = spec.get("parentRefs", [])
    if len(refs) != 1 or any(
        refs[0].get(k) != v
        for k, v in {"name": "internal", "namespace": "networking", "sectionName": "https"}.items()
    ):
        errors.append("SearXNG must use the private HTTPS Gateway")
    annotations = route.get("metadata", {}).get("annotations", {})
    if annotations.get("external-dns.k8s.io/audience") != "internal":
        errors.append("SearXNG DNS must remain internal")
    if annotations.get("gethomepage.dev/group") != "Platform":
        errors.append("SearXNG Homepage tile must use Platform")
    if spec.get("hostnames") != ["searxng.lab.supermorphic.com"]:
        errors.append("unexpected SearXNG private hostname")
    return errors


def credential_mount_errors(deployment):
    errors = []
    spec = deployment["spec"]
    if spec.get("replicas") != 1 or spec.get("strategy", {}).get("type") != "Recreate":
        errors.append("native key cutover requires one Recreate replica")
    pod = spec["template"]["spec"]
    volumes = {v["name"]: v for v in pod["volumes"]}
    agent = next(c for c in pod["containers"] if c["name"] == "credential-agent")
    keys = set()
    for mount in agent["volumeMounts"]:
        volume = volumes[mount["name"]]
        secret = volume.get("secret")
        if secret is not None:
            keys.update(item["key"] for item in secret.get("items", []))
            if not secret.get("items") or mount.get("subPath"):
                errors.append("credential projection must be restricted and refreshable")
    if keys != {"api_token"}:
        errors.append("credential agent must receive only api_token")
    if pod.get("automountServiceAccountToken") is not False:
        errors.append("native pod must not mount Kubernetes API credentials")
    for container in pod["containers"]:
        for item in container.get("env", []):
            if any(k in item["name"] for k in ("TOKEN", "SECRET", "PASSWORD")):
                errors.append("bootstrap must use mounted files, not environment snapshots")
    return errors


def auth_errors(policy):
    errors = []
    auth = policy.get("spec", {}).get("extAuth", {})
    if auth.get("failOpen") is not False or auth.get("statusOnError") != 503:
        errors.append("authentication must fail closed with 503")
    http = auth.get("http", {})
    if (
        http.get("headersToBackend") != ["Authorization"]
        or http.get("pathOverride") != "/authorize"
    ):
        errors.append("Envoy must replace Authorization through the exact agent operation")
    if auth.get("bodyToExtAuth"):
        errors.append("crawl bodies must not be sent to the credential agent")
    return errors


def buffer_errors(policy, proxy, sizing):
    errors = []
    try:
        spec = policy["spec"]
        connection = spec["connection"]
        limit = connection["connectionLimit"]
        count = limit["value"]
        h2 = spec["http2"]
        cap = sizing["response_cap_bytes"]
        if (
            count < 1
            or limit.get("maxRequestsPerConnection") != 1
            or h2.get("maxConcurrentStreams") != 1
        ):
            errors.append("one request and one HTTP/2 stream per connection required")
        if (
            quantity(connection["bufferLimit"]) != cap
            or quantity(h2["initialStreamWindowSize"]) != cap
        ):
            errors.append("HTTP/1 and HTTP/2 response buffers must match the cap")
        if quantity(h2["initialConnectionWindowSize"]) < cap:
            errors.append("HTTP/2 connection window must cover the stream window")
        container = proxy["spec"]["provider"]["kubernetes"]["envoyDeployment"]["container"]
        budget = quantity(container["resources"]["limits"]["memory"])
        overhead = sizing["loaded_overhead_budget_bytes"]
        margin = sizing["safety_margin_bytes"]
        if min(cap, overhead, margin) <= 0 or cap * count + overhead + margin > budget:
            errors.append("aggregate buffering exceeds Envoy memory limit")
        deployment = proxy["spec"]["provider"]["kubernetes"]["envoyDeployment"]
        patch = deployment["patch"]
        if patch["type"] != "StrategicMerge":
            errors.append("shutdown-manager resource patch must preserve the generated container")
        sidecars = patch["value"]["spec"]["template"]["spec"]["containers"]
        sidecar = next(item for item in sidecars if item["name"] == "shutdown-manager")
        sidecar_limit = quantity(sidecar["resources"]["limits"]["memory"])
        if (
            sidecar_limit != sizing["shutdown_manager_memory_limit_bytes"]
            or sidecar_limit <= 0
            or budget + sidecar_limit > sizing["proxy_pod_memory_limit_bytes"]
        ):
            errors.append("all proxy containers must fit the aggregate Pod memory ceiling")
    except (KeyError, TypeError, ValueError, StopIteration):
        errors.append("missing or invalid aggregate buffering controls")
    return errors


def controller_access_errors(policy, controllers):
    """Use the pinned chart's actual pod labels as the network-policy oracle."""
    for controller in controllers:
        if controller.get("kind") != "Deployment":
            continue
        labels = controller["spec"]["template"]["metadata"]["labels"]
        if labels.get("control-plane") != "envoy-gateway":
            continue
        labels = {
            **labels,
            "k8s:io.kubernetes.pod.namespace": controller["metadata"]["namespace"],
        }
        for rule in policy["spec"].get("egress", []):
            ports = [p for group in rule.get("toPorts", []) for p in group.get("ports", [])]
            if {"port": "18000", "protocol": "TCP"} not in ports:
                continue
            for endpoint in rule.get("toEndpoints", []):
                selector = endpoint.get("matchLabels", {})
                if selector and all(labels.get(key) == value for key, value in selector.items()):
                    return []
    return ["dedicated Envoy must reach the pinned controller's xDS port"]


def monitoring_errors(alerts_active, native_active, resources, selected, expected):
    errors = []
    if resources.count("./credentials.yaml") != 1 or set(resources) - {
        "./credentials.yaml",
        "./gatus.yaml",
    }:
        errors.append("credential alerts require their canonical resource selection")
    if alerts_active != native_active:
        errors.append("native Crawl4AI and credential alerts must activate together")
    gatus_count = resources.count("./gatus.yaml")
    if gatus_count not in (0, 1) or (gatus_count and not alerts_active):
        errors.append("Gatus alert selection requires an active alerts application")
    if gatus_count:
        if sorted(selected, key=lambda value: value["name"]) != sorted(
            expected, key=lambda value: value["name"]
        ):
            errors.append("active monitoring requires the four exact approved Gatus endpoints")
    elif selected:
        errors.append("Gatus checks and their alert rules must activate together")
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--controller-manifest", required=True, type=Path)
    args = parser.parse_args()

    def read(path):
        with (BASE / path).open() as stream:
            return yaml.safe_load(stream)

    errors = ui_errors(read("searxng/app/httproute.yaml"))
    errors += credential_mount_errors(read("crawl4ai/app/deployment.yaml"))
    errors += auth_errors(read("crawl4ai/proxy/securitypolicy.yaml"))
    errors += buffer_errors(
        read("crawl4ai/proxy/clienttrafficpolicy.yaml"),
        read("crawl4ai/proxy/envoyproxy.yaml"),
        read("crawl4ai/proxy/sizing.yaml"),
    )
    with args.controller_manifest.open() as stream:
        controllers = [item for item in yaml.safe_load_all(stream) if item]
    errors += controller_access_errors(
        read("crawl4ai/proxy/ciliumnetworkpolicy.yaml"), controllers
    )
    rule = read("crawl4ai/proxy/httproute.yaml")["spec"]["rules"]
    if len(rule) != 1 or rule[0].get("matches") != [
        {"method": "POST", "path": {"type": "Exact", "value": "/crawl"}}
    ]:
        errors.append("bounded route must expose only exact POST /crawl")
    endpoints = read("monitoring/gatus-endpoints.yaml")["config"]["endpoints"]
    intervals = {
        "searxng": "1m",
        "crawl4ai-readiness": "1m",
        "crawl4ai-e2e": "15m",
        "searxng-search-e2e": "30m",
    }
    if len(endpoints) != 4 or {e["name"]: e["interval"] for e in endpoints} != intervals:
        errors.append("four approved Gatus checks and cadences are required")
    for endpoint in endpoints:
        if endpoint.get("group") != "Automation" or "Authorization" in endpoint.get("headers", {}):
            errors.append("Gatus must use Automation without Crawl4AI credentials")
    live_values = yaml.safe_load(
        Path("kubernetes/apps/monitoring/gatus/app/values.yaml").read_text()
    )
    selected_endpoints = [
        endpoint
        for endpoint in live_values["config"]["endpoints"]
        if endpoint["name"] in intervals
    ]
    # Staging requires no credential object. Activation requires an operator-produced
    # encrypted artifact selected by the app; validation never decrypts it.
    entrypoints = list(yaml.safe_load_all((BASE / "crawl4ai/ks.yaml").read_text()))
    native = next(e for e in entrypoints if e["metadata"]["name"] == "crawl4ai")
    errors.extend(
        monitoring_errors(
            read("alerts/ks.yaml")["spec"].get("suspend") is not True,
            native["spec"].get("suspend") is not True,
            read("alerts/app/kustomization.yaml")["resources"],
            selected_endpoints,
            endpoints,
        )
    )
    if "kube-prometheus-stack" not in {item["name"] for item in native["spec"]["dependsOn"]}:
        errors.append("native monitoring resources require the monitoring CRD dependency")
    secret = BASE / "crawl4ai/app/bootstrap.sops.yaml"
    selected = "./bootstrap.sops.yaml" in read("crawl4ai/app/kustomization.yaml")["resources"]
    if secret.exists() != selected:
        errors.append("bootstrap ciphertext and its resource selection must appear together")
    if native["spec"].get("suspend") is not True and not selected:
        errors.append("native activation requires encrypted bootstrap")
    if secret.exists():
        document = yaml.safe_load(secret.read_text())
        values = document.get("stringData", {})
        if (
            set(values) != {"api_token", "signing_key"}
            or not document.get("sops")
            or any(
                not isinstance(v, str) or not v.startswith("ENC[AES256_GCM,")
                for v in values.values()
            )
        ):
            errors.append("bootstrap must contain only encrypted platform credentials")
    if errors:
        raise SystemExit("\n".join(errors))
    print(
        "Web research private UI, authentication, buffering, credential projection and staged monitoring invariants passed."
    )


if __name__ == "__main__":
    main()
