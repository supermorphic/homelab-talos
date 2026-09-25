"""Non-secret source and target identity checks for attended OpenBao mutations."""

import hashlib
import os
import re
import subprocess
from pathlib import Path

from .configuration import SafeError, canonical_json, strict_json

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "kubernetes/apps/security/openbao"


def digest(value: object) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def confirmation(phase: str, source_sha: str, target_digest: str) -> str:
    if (
        phase not in {"prepare", "initialize", "config-apply"}
        or not re.fullmatch("[0-9a-f]{40}", source_sha)
        or not re.fullmatch("[0-9a-f]{64}", target_digest)
    ):
        raise SafeError("invalid-source")
    return f"{phase}:openbao:{source_sha}:{target_digest}"


def command(argv, *, input_bytes=None):
    try:
        return subprocess.run(
            argv, cwd=ROOT, input=input_bytes, capture_output=True, check=True, timeout=60
        ).stdout
    except (OSError, subprocess.SubprocessError):
        raise SafeError("read-denied") from None


def kube(kubeconfig, *args):
    return strict_json(
        command(["kubectl", "--kubeconfig", str(kubeconfig), "--request-timeout=15s", *args]),
        "invalid-response",
    )


def _get(kubeconfig, namespace, kind, name):
    items = kube(
        kubeconfig, "-n", namespace, "get", kind, name, "--ignore-not-found", "-o", "json"
    )
    return items


def source_revision() -> str:
    if command(["git", "status", "--porcelain"]).strip():
        raise SafeError("source-mismatch")
    revision = command(["git", "rev-parse", "HEAD"]).decode().strip()
    remote = (
        command(["git", "ls-remote", "--exit-code", "origin", "refs/heads/main"]).decode().split()
    )
    if not remote or remote[0] != revision:
        raise SafeError("source-mismatch")
    return revision


def assert_mutation_allowed(kubeconfig) -> None:
    holder = os.environ.get("OPENBAO_LEASE_HOLDER", "")
    marker = os.environ.get("OPENBAO_LEASE_FAILURE", "")
    if not holder or not marker or Path(marker).exists():
        raise SafeError("source-mismatch")
    command(["bash", str(ROOT / "scripts/openbao/lock.sh"), "check", str(kubeconfig), holder])


def contains_source(expected, actual):
    """Kubernetes may add defaults and generated named volumes to reviewed specs."""
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            k in actual and contains_source(v, actual[k]) for k, v in expected.items()
        )
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return False
        if expected and all(isinstance(v, dict) and "name" in v for v in expected):
            if not all(isinstance(v, dict) and "name" in v for v in actual):
                return False
            named = {v["name"]: v for v in actual}
            return len(named) == len(actual) and all(
                v["name"] in named and contains_source(v, named[v["name"]]) for v in expected
            )
        return len(expected) == len(actual) and all(
            contains_source(a, b) for a, b in zip(expected, actual)
        )
    return expected == actual


def freeze_target(kubeconfig, phase) -> dict:
    """Read metadata/configuration only; never request a Kubernetes Secret value."""
    import yaml

    from .manifests import validate_documents
    from .reader import placement_ready
    from .secrets import validate_recipient

    if phase not in {"prepare", "initialize", "config-apply"}:
        raise SafeError("invalid-source")
    revision = source_revision()
    recipient = os.environ.get("OPENBAO_RECOVERY_RECIPIENT", "")
    validate_recipient(recipient)
    source = kube(
        kubeconfig, "-n", "flux-system", "get", "gitrepository", "flux-system", "-o", "json"
    )
    applied = kube(
        kubeconfig, "-n", "flux-system", "get", "kustomization", "cluster-apps", "-o", "json"
    )
    if (
        source.get("status", {}).get("artifact", {}).get("revision") != f"main@sha1:{revision}"
        or applied.get("status", {}).get("lastAppliedRevision") != f"main@sha1:{revision}"
    ):
        raise SafeError("source-mismatch")
    files = sorted(path for path in PACKAGE.rglob("*") if path.is_file())
    package_digest = digest(
        {str(p.relative_to(PACKAGE)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    )
    seal_path = PACKAGE / "app/openbao-seal.sops.yaml"
    try:
        seal = yaml.safe_load(seal_path.read_bytes())
        kustomization = yaml.safe_load((PACKAGE / "app/kustomization.yaml").read_bytes())
        if (
            seal_path.is_symlink()
            or seal["metadata"] != {"name": "openbao-seal", "namespace": "openbao"}
            or not seal["data"]["key"].startswith("ENC[AES256_GCM,")
            or {a["recipient"] for a in seal["sops"]["age"]} != {recipient}
            or not any(
                str(r).removeprefix("./") == seal_path.name for r in kustomization["resources"]
            )
        ):
            raise SafeError("invalid-source")
    except (OSError, KeyError, TypeError, ValueError):
        raise SafeError("invalid-source") from None
    cluster = kube(kubeconfig, "get", "namespace", "kube-system", "-o", "json")
    units = kube(kubeconfig, "-n", "flux-system", "get", "kustomizations", "-o", "json")["items"]
    desired_units = list(yaml.safe_load_all((PACKAGE / "ks.yaml").read_bytes()))
    for expected in desired_units:
        matches = [u for u in units if u["metadata"]["name"] == expected["metadata"]["name"]]
        if len(matches) != 1:
            raise SafeError("source-mismatch")
        actual = matches[0]
        if (
            actual["spec"]["path"] != expected["spec"]["path"]
            or actual["spec"]["sourceRef"] != expected["spec"]["sourceRef"]
            or (phase == "prepare" and actual["spec"].get("suspend") is not True)
        ):
            raise SafeError("source-mismatch")
    target = {
        "source_revision": revision,
        "package_digest": package_digest,
        "cluster_uid": cluster["metadata"]["uid"],
        "recipient": recipient,
        "seal_key_id": "openbao-static-seal-v1",
    }
    namespaces = kube(kubeconfig, "get", "namespaces", "-o", "json")["items"]
    ns = [n for n in namespaces if n["metadata"]["name"] == "openbao"]
    if not ns and phase == "prepare":
        return target
    if len(ns) != 1:
        raise SafeError("source-mismatch")
    target["namespace_uid"] = ns[0]["metadata"]["uid"]
    workloads = kube(kubeconfig, "-n", "openbao", "get", "statefulsets", "-o", "json")["items"]
    if not workloads and phase == "prepare":
        return target
    if len(workloads) != 1 or workloads[0]["metadata"]["name"] != "openbao":
        raise SafeError("source-mismatch")
    sts = workloads[0]
    if (
        sts["metadata"].get("annotations", {}).get("meta.helm.sh/release-name") != "openbao"
        or sts["metadata"].get("annotations", {}).get("meta.helm.sh/release-namespace")
        != "openbao"
    ):
        raise SafeError("source-mismatch")
    pdb = kube(kubeconfig, "-n", "openbao", "get", "pdb", "openbao", "-o", "json")
    if validate_documents([sts, pdb]):
        raise SafeError("source-mismatch")
    rendered = list(
        yaml.safe_load_all(
            command(
                [
                    "helm",
                    "template",
                    "openbao",
                    "oci://ghcr.io/openbao/charts/openbao@sha256:98c8fc901e2579ac6da9a805537fcd7a19525ef8e563ae8737dc16fc8f641e3e",
                    "--namespace",
                    "openbao",
                    "--values",
                    str(PACKAGE / "app/values.yaml"),
                ]
            )
        )
    )
    expected_sts = next(d for d in rendered if d and d.get("kind") == "StatefulSet")
    expected_config = next(
        d
        for d in rendered
        if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "openbao-config"
    )
    if not contains_source(expected_sts["spec"], sts["spec"]):
        raise SafeError("source-mismatch")
    config = kube(kubeconfig, "-n", "openbao", "get", "configmap", "openbao-config", "-o", "json")
    if config["data"] != expected_config["data"]:
        raise SafeError("source-mismatch")
    target["configuration_digest"] = digest(config["data"])
    target["statefulset_uid"] = sts["metadata"]["uid"]
    pods = kube(
        kubeconfig, "-n", "openbao", "get", "pods", "-l", "component=server", "-o", "json"
    )["items"]
    if not placement_ready(pods):
        raise SafeError("source-mismatch")
    target["pod_uids"] = {}
    expected_pod = expected_sts["spec"]["template"]["spec"]
    for pod in pods:
        if (
            not any(
                o.get("uid") == target["statefulset_uid"] and o.get("controller") is True
                for o in pod["metadata"].get("ownerReferences", [])
            )
            or not contains_source(
                expected_sts["spec"]["template"]["spec"]["containers"], pod["spec"]["containers"]
            )
            or not contains_source(
                expected_sts["spec"]["template"]["spec"]["volumes"], pod["spec"]["volumes"]
            )
        ):
            raise SafeError("source-mismatch")
        if (
            pod["spec"].get("serviceAccountName") != expected_pod["serviceAccountName"]
            or len(pod["spec"]["containers"]) != len(expected_pod["containers"])
            or not any(
                v.get("name") == "data"
                and v.get("persistentVolumeClaim", {}).get("claimName")
                == f"data-{pod['metadata']['name']}"
                for v in pod["spec"]["volumes"]
            )
        ):
            raise SafeError("source-mismatch")
        target["pod_uids"][pod["metadata"]["name"]] = pod["metadata"]["uid"]
    claims = kube(kubeconfig, "-n", "openbao", "get", "pvc", "-o", "json")["items"]
    target["pvc_uids"] = {}
    for index in range(3):
        name = f"data-openbao-{index}"
        matches = [p for p in claims if p["metadata"]["name"] == name]
        if (
            len(matches) != 1
            or matches[0]["status"]["phase"] != "Bound"
            or matches[0]["spec"]["storageClassName"] != "longhorn"
            or matches[0]["spec"]["accessModes"] != ["ReadWriteOnce"]
        ):
            raise SafeError("source-mismatch")
        target["pvc_uids"][name] = matches[0]["metadata"]["uid"]
    certificate = kube(kubeconfig, "-n", "openbao", "get", "certificate", "openbao", "-o", "json")
    if not any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in certificate.get("status", {}).get("conditions", [])
    ):
        raise SafeError("source-mismatch")
    return target
