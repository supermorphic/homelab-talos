"""Translate production Gateway policies with checksum-pinned egctl for local tests."""

import copy
import hashlib
import io
import platform
import subprocess
import tarfile
import urllib.request
from pathlib import Path

import yaml

VERSION = "1.8.2"
ARCHIVES = {
    ("darwin", "amd64"): "222f993fece1248741e97b9287e9a033df0152fc0bb713664d4e764d1ff70ad7",
    ("darwin", "arm64"): "d6244a9a845a213ba5e071222e13c21c88d59beb955d7fbdb2b762151cc9721b",
    ("linux", "amd64"): "706655cb53837e39a06b67981affac9c7d3ed95b9941f78be72f0134a1bf02e1",
    ("linux", "arm64"): "ddc4c653a8a3b951e293e12a4d764fe6bb79e797a4cd0460c0f5e581d46f758e",
}


def egctl(directory):
    system = platform.system().lower()
    machine = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[platform.machine()]
    digest = ARCHIVES[system, machine]
    archive_name = f"egctl_v{VERSION}_{system}_{machine}.tar.gz"
    url = f"https://github.com/envoyproxy/gateway/releases/download/v{VERSION}/{archive_name}"
    with urllib.request.urlopen(url, timeout=30) as response:
        archive = response.read(100 * 1024 * 1024 + 1)
    if len(archive) > 100 * 1024 * 1024 or hashlib.sha256(archive).hexdigest() != digest:
        raise ValueError("egctl archive checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
        member = bundle.getmember(f"bin/{system}/{machine}/egctl")
        if not member.isfile() or member.size > 512 * 1024 * 1024:
            raise ValueError("invalid egctl executable archive member")
        executable = Path(directory) / "egctl"
        with bundle.extractfile(member) as stream:
            executable.write_bytes(stream.read())
        executable.chmod(0o700)
    return executable


def translation_input(root):
    rendered = subprocess.check_output(
        ["kustomize", "build", str(root / "kubernetes/apps/web-research/crawl4ai/proxy")],
        text=True,
    )
    resources = [
        resource
        for resource in yaml.safe_load_all(rendered)
        if resource["apiVersion"] != "cilium.io/v2"
    ]
    resources.extend(
        [
            {
                "apiVersion": "gateway.networking.k8s.io/v1",
                "kind": "GatewayClass",
                "metadata": {"name": "internal"},
                "spec": {"controllerName": "gateway.envoyproxy.io/gatewayclass-controller"},
            },
            {
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": {"name": "web-research"},
            },
        ]
    )
    for name, port, address in (
        ("crawl4ai-native", 11235, "192.0.2.5"),
        ("crawl4ai-auth", 9000, "192.0.2.6"),
    ):
        resources.append(
            {
                "apiVersion": "v1",
                "kind": "Service",
                "metadata": {"name": name, "namespace": "web-research"},
                "spec": {"clusterIP": address, "ports": [{"port": port}]},
            }
        )
    return resources


def static_fixture(translated):
    """Replace service discovery with loopback, preserving translated route/filter controls."""
    dumps = translated["xds"]["web-research/crawl4ai"]["configs"]
    groups = {item["@type"].rsplit(".", 1)[-1]: item for item in dumps}

    def resource(value):
        result = copy.deepcopy(value)
        result.pop("@type", None)
        return result

    endpoints = {
        item["endpointConfig"]["clusterName"]: resource(item["endpointConfig"])
        for item in groups["EndpointsConfigDump"]["dynamicEndpointConfigs"]
    }
    for assignment in endpoints.values():
        for locality in assignment["endpoints"]:
            for endpoint in locality["lbEndpoints"]:
                address = endpoint["endpoint"]["address"]["socketAddress"]
                if address["address"] not in ("192.0.2.5", "192.0.2.6"):
                    raise ValueError("unexpected translated endpoint")
                address["address"] = "127.0.0.1"
    clusters = []
    for item in groups["ClustersConfigDump"]["dynamicActiveClusters"]:
        cluster = resource(item["cluster"])
        if "edsClusterConfig" in cluster:
            name = cluster.pop("edsClusterConfig")["serviceName"]
            cluster["loadAssignment"] = endpoints[name]
            cluster["type"] = "STATIC"
        clusters.append(cluster)
    routes = {
        item["routeConfig"]["name"]: resource(item["routeConfig"])
        for item in groups["RoutesConfigDump"]["dynamicRouteConfigs"]
    }
    listeners = []
    for item in groups["ListenersConfigDump"]["dynamicListeners"]:
        listener = resource(item["activeState"]["listener"])
        chains = listener.get("filterChains", [])
        if "defaultFilterChain" in listener:
            chains = [*chains, listener["defaultFilterChain"]]
        for chain in chains:
            for entry in chain["filters"]:
                if entry["name"] != "envoy.filters.network.http_connection_manager":
                    continue
                config = entry["typedConfig"]
                if "rds" in config:
                    config["routeConfig"] = routes[config.pop("rds")["routeConfigName"]]
        listeners.append(listener)
    return {
        "node": {"id": "web-research-disposable-fixture", "cluster": "web-research-test"},
        "static_resources": {"listeners": listeners, "clusters": clusters},
        "admin": {"address": {"socket_address": {"address": "127.0.0.1", "port_value": 19000}}},
    }


def translate(root, directory):
    directory = Path(directory)
    executable = egctl(directory)
    source = directory / "gateway-input.yaml"
    source.write_text(yaml.safe_dump_all(translation_input(root)))
    command = [
        str(executable),
        "x",
        "translate",
        "--from",
        "gateway-api",
        "--to",
        "gateway-api,xds",
        "--type",
        "all",
        "-o",
        "yaml",
        "-f",
        str(source),
    ]
    translated = yaml.safe_load(subprocess.check_output(command, text=True, timeout=60))
    for key in (
        "clientTrafficPolicies",
        "securityPolicies",
        "envoyExtensionPolicies",
        "httpRoutes",
    ):
        for policy in translated[key]:
            parents = policy.get("status", {}).get(
                "ancestors", policy.get("status", {}).get("parents", [])
            )
            accepted = [
                condition
                for parent in parents
                for condition in parent.get("conditions", [])
                if condition["type"] == "Accepted"
            ]
            if not accepted or any(condition["status"] != "True" for condition in accepted):
                raise ValueError("Gateway policy translation was not accepted")
    destination = directory / "envoy.yaml"
    destination.write_text(yaml.safe_dump(static_fixture(translated)))
    return destination
