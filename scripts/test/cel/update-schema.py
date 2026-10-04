"""Refresh the offline schema fixture from the pinned Kubernetes release.

Run: mise exec -- uv run --locked python scripts/test/cel/update-schema.py
Only refresh needs network access; compiler tests use the checked-in fixture.
"""

import hashlib
import json
import subprocess
from pathlib import Path
from urllib.request import urlopen

import yaml

ROOT = Path(__file__).resolve().parents[3]
PACKAGES = (
    "kubernetes/apps/kube-system/agent-access/app",
    "kubernetes/apps/monitoring/test-reports/app",
)


def main():
    version = yaml.safe_load((ROOT / "talos/talconfig.yaml").read_text())["kubernetesVersion"]
    source = f"https://raw.githubusercontent.com/kubernetes/kubernetes/{version}/api/openapi-spec/swagger.json"
    with urlopen(source, timeout=30) as response:
        raw = response.read()
    swagger = json.loads(raw)
    requested, params = set(), set()
    for package in PACKAGES:
        rendered = subprocess.check_output(["kustomize", "build", str(ROOT / package)], text=True)
        for doc in yaml.safe_load_all(rendered):
            if not doc or doc.get("kind") != "ValidatingAdmissionPolicy":
                continue
            if param := doc["spec"].get("paramKind"):
                group, _, api_version = param["apiVersion"].rpartition("/")
                params.add((group, api_version, param["kind"]))
            for rule in doc["spec"]["matchConstraints"]["resourceRules"]:
                for group in rule["apiGroups"]:
                    for api_version in rule["apiVersions"]:
                        for resource in rule["resources"]:
                            requested.add((group, api_version, resource.split("/")[0]))

    resources, roots = [], set()
    for path, entry in swagger["paths"].items():
        if not path.endswith("/{name}") or "/watch/" in path:
            continue
        operation = entry.get("get", {})
        gvk = operation.get("x-kubernetes-group-version-kind")
        if not gvk:
            continue
        resource = path.split("/")[-2]
        if (gvk["group"], gvk["version"], resource) not in requested and (
            gvk["group"],
            gvk["version"],
            gvk["kind"],
        ) not in params:
            continue
        ref = operation["responses"]["200"]["schema"]["$ref"].removeprefix("#/definitions/")
        item = {**gvk, "resource": resource, "definition": ref}
        if item not in resources:
            if any(
                (r["group"], r["version"], r["kind"])
                == (gvk["group"], gvk["version"], gvk["kind"])
                for r in resources
            ):
                raise ValueError(f"Ambiguous resource schema for {gvk}")
            resources.append(item)
        roots.add(ref)

    kept = {}

    def strip_prose(node):
        if isinstance(node, dict):
            if "$ref" in node:
                collect(node["$ref"].removeprefix("#/definitions/"))
            return {k: strip_prose(v) for k, v in node.items() if k != "description"}
        if isinstance(node, list):
            return [strip_prose(v) for v in node]
        return node

    def collect(ref):
        if ref not in kept:
            kept[ref] = None  # Break recursive references before traversing dependencies.
            kept[ref] = strip_prose(swagger["definitions"][ref])

    for ref in roots:
        collect(ref)
    fixture = {
        "source": source,
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "license": "Apache-2.0",
        "transformation": "Selected built-in policy resource schemas and transitive references; descriptions omitted.",
        "resources": sorted(
            resources, key=lambda item: (item["group"], item["version"], item["resource"])
        ),
        "definitions": kept,
    }
    Path(__file__).with_name("kubernetes-schema.json").write_text(
        json.dumps(fixture, indent=2, sort_keys=True) + "\n"
    )


if __name__ == "__main__":
    main()
