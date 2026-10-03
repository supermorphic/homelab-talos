"""Non-secret source and target identity checks for attended OpenBao mutations."""

import copy
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

from .configuration import SafeError, canonical_json, strict_json

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "kubernetes/apps/security/openbao"


def digest(value: object) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def confirmation(phase: str, source_sha: str, target_digest: str) -> str:
    if (
        phase not in {"prepare", "initialize", "config-apply", "reset-staged", "finalize", "restart-staged"}
        or not re.fullmatch("[0-9a-f]{40}", source_sha)
        or not re.fullmatch("[0-9a-f]{64}", target_digest)
    ):
        raise SafeError("invalid-source")
    return f"{phase}:openbao:{source_sha}:{target_digest}"


def command(argv, *, input_bytes=None, timeout=60):
    try:
        return subprocess.run(
            argv, cwd=ROOT, input=input_bytes, capture_output=True, check=True, timeout=timeout
        ).stdout
    except subprocess.TimeoutExpired:
        raise SafeError("timeout") from None
    except subprocess.CalledProcessError as error:
        # Classify the CLI deadline without exposing command output or credentials.
        if b"context deadline exceeded" in (error.stderr or b""):
            raise SafeError("timeout") from None
        raise SafeError("read-denied") from None
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


def contains_statefulset_source(expected, actual):
    """The API omits the PodSpec hostNetwork field when its value is false."""
    defaulted = copy.deepcopy(actual)
    try:
        defaulted["template"]["spec"].setdefault("hostNetwork", False)
    except (KeyError, TypeError, AttributeError):
        return False
    return contains_source(expected, defaulted)


def _agent_profile_source():
    """Render reviewed permissions and fixed programs without decrypting Secrets."""
    import yaml

    access_kinds = {
        "ServiceAccount",
        "Role",
        "RoleBinding",
        "ClusterRole",
        "ClusterRoleBinding",
        "ValidatingAdmissionPolicy",
        "ValidatingAdmissionPolicyBinding",
        "Lease",
    }
    packages = [
        (ROOT / "kubernetes/apps/kube-system/agent-access/app", access_kinds),
        (ROOT / "kubernetes/apps/monitoring/test-reports/app", {"Role", "RoleBinding"}),
        (PACKAGE / "acceptance", {"ServiceAccount", "Role", "RoleBinding"}),
        (PACKAGE / "restore-test", {"Namespace", "ServiceAccount", "CiliumNetworkPolicy"}),
    ]
    programs = {
        "automation/n8n": "n8n-test-helpers-v1",
        "automation-data/postgresql": "automation-data-test-helpers-v1",
        "automation-data/nocodb": "nocodb-test-helpers-v1",
        "monitoring/gatus": "n8n-test-request-helpers-v1",
        "media/qbit-manage": "qbit-manage-test-helpers-v1",
    }
    result = []
    for package, kinds in packages:
        result.extend(
            d
            for d in yaml.safe_load_all(command(["kustomize", "build", str(package)]))
            if d and d.get("kind") in kinds
        )
    for package, name in programs.items():
        rendered = yaml.safe_load_all(
            command(["kustomize", "build", str(ROOT / "kubernetes/apps" / package / "app")])
        )
        matches = [
            d
            for d in rendered
            if d
            and d.get("kind") == "ConfigMap"
            and d["metadata"]["name"] == name
            and d.get("immutable") is True
        ]
        if len(matches) != 1:
            raise SafeError("invalid-source")
        result.extend(matches)
    return result


def _controlled_body(document):
    """Exact security fields, allowing only documented API defaults."""
    body = copy.deepcopy({k: v for k, v in document.items() if k not in {"metadata", "status"}})
    kind = body["kind"]
    if kind in {"RoleBinding", "ClusterRoleBinding"}:
        for subject in body.get("subjects", []):
            if subject.get("kind") == "ServiceAccount" and subject.get("apiGroup") == "":
                subject.pop("apiGroup")
    elif kind == "ServiceAccount":
        body.setdefault("secrets", [])
        body.setdefault("imagePullSecrets", [])
    elif kind == "ConfigMap":
        body.setdefault("binaryData", {})
    elif kind == "Namespace":
        body.setdefault("spec", {"finalizers": ["kubernetes"]})
    elif kind == "Lease":
        # The fixed Lease is a prerequisite; its current holder is deliberately mutable.
        body.pop("spec", None)
    elif kind in {"ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"}:
        spec = body["spec"]
        if kind == "ValidatingAdmissionPolicy":
            spec.setdefault("failurePolicy", "Fail")
            match = spec["matchConstraints"]
        else:
            match = spec.setdefault("matchResources", {})
        match.setdefault("matchPolicy", "Equivalent")
        match.setdefault("namespaceSelector", {})
        match.setdefault("objectSelector", {})
        for group in ("resourceRules", "excludeResourceRules"):
            for rule in match.get(group, []):
                rule.setdefault("scope", "*")
    return body


def require_agent_profiles_ready(kubeconfig):
    """Fail before issuance changes if Git-defined safeguards are not deployed."""
    expected = _agent_profile_source()
    actual = []
    # Batch non-secret inventories; fixed programs are read only by exact name.
    for kinds in (
        "serviceaccounts,roles,rolebindings,leases",
        "clusterroles,clusterrolebindings,validatingadmissionpolicies,validatingadmissionpolicybindings",
        "namespaces",
    ):
        actual.extend(kube(kubeconfig, "get", kinds, "--all-namespaces", "-o", "json")["items"])
    for item in expected:
        if item["kind"] in {"ConfigMap", "CiliumNetworkPolicy"}:
            actual.append(
                kube(
                    kubeconfig,
                    "-n",
                    item["metadata"]["namespace"],
                    "get",
                    item["kind"].lower(),
                    item["metadata"]["name"],
                    "-o",
                    "json",
                )
            )
    uids = {}
    try:
        binding_kinds = {"RoleBinding", "ClusterRoleBinding"}
        binding_ids = {
            (d["kind"], d["metadata"].get("namespace", ""), d["metadata"]["name"])
            for d in expected
            if d["kind"] in binding_kinds
        }
        accounts = {
            (d["metadata"].get("namespace", ""), d["metadata"]["name"])
            for d in expected
            if d["kind"] == "ServiceAccount"
        } | {
            (s["namespace"], s["name"])
            for d in expected
            if d["kind"] in binding_kinds
            for s in d.get("subjects", [])
            if s.get("kind") == "ServiceAccount"
        }
        for binding in actual:
            if binding.get("kind") not in binding_kinds:
                continue
            meta = binding["metadata"]
            identity = (binding["kind"], meta.get("namespace", ""), meta["name"])
            controlled_subject = any(
                s.get("kind") == "ServiceAccount"
                and (s.get("namespace"), s.get("name")) in accounts
                for s in binding.get("subjects", [])
            )
            fixture_role = binding.get("roleRef", {}).get("name") in {
                "homelab-test-cilium-fixtures-1",
                "homelab-test-cilium-fixtures-ccnp",
            }
            if fixture_role or (controlled_subject and identity not in binding_ids):
                raise SafeError("source-mismatch")
        for item in expected:
            metadata = item["metadata"]
            identity = (item["kind"], metadata.get("namespace", ""), metadata["name"])
            matches = [
                d
                for d in actual
                if (
                    d.get("kind"),
                    d.get("metadata", {}).get("namespace", ""),
                    d.get("metadata", {}).get("name"),
                )
                == identity
            ]
            if len(matches) != 1:
                raise SafeError("source-mismatch")
            deployed = matches[0]
            meta = deployed["metadata"]
            if (
                not isinstance(meta.get("uid"), str)
                or not meta["uid"]
                or not contains_source(metadata.get("labels", {}), meta.get("labels", {}))
                or not contains_source(
                    metadata.get("annotations", {}), meta.get("annotations", {})
                )
                or _controlled_body(item) != _controlled_body(deployed)
            ):
                raise SafeError("source-mismatch")
            if item["kind"] == "ClusterRole" and any(
                k.startswith("rbac.authorization.k8s.io/aggregate-to-")
                for k in meta.get("labels", {})
            ):
                raise SafeError("source-mismatch")
            if item["kind"] == "ValidatingAdmissionPolicy":
                status = deployed.get("status", {})
                if (
                    not isinstance(meta.get("generation"), int)
                    or status.get("observedGeneration") != meta["generation"]
                    or not isinstance(status.get("typeChecking"), dict)
                    or status["typeChecking"].get("expressionWarnings", [])
                ):
                    raise SafeError("source-mismatch")
            uids["/".join(identity)] = meta["uid"]
    except (KeyError, TypeError, AttributeError, ValueError):
        raise SafeError("source-mismatch") from None
    # kubectl's template emits only this fixture's metadata and type, never data.
    template = (
        '{"name":{{printf "%q" .metadata.name}},'
        '"namespace":{{printf "%q" .metadata.namespace}},'
        '"uid":{{printf "%q" .metadata.uid}},"type":{{printf "%q" .type}},'
        '"label":{{printf "%q" (index .metadata.labels "homelab-talos/test")}}}'
    )
    fixture = kube(
        kubeconfig,
        "-n",
        "automation-data",
        "get",
        "secret",
        "nocodb-restore-application-credential",
        "-o",
        "go-template",
        "--template",
        template,
    )
    uid = fixture.get("uid")
    if (
        not isinstance(uid, str)
        or not uid
        or {k: v for k, v in fixture.items() if k != "uid"}
        != {
            "name": "nocodb-restore-application-credential",
            "namespace": "automation-data",
            "type": "Opaque",
            "label": "nocodb-restore-extension",
        }
    ):
        raise SafeError("source-mismatch")
    uids["Secret/automation-data/nocodb-restore-application-credential"] = uid
    return {"source_digest": digest(expected), "object_uids": uids}

def require_deployed_revision(kubeconfig, revision):
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


def package_digest():
    files = sorted(path for path in PACKAGE.rglob("*") if path.is_file())
    return digest(
        {str(p.relative_to(PACKAGE)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    )


def require_api_egress(kubeconfig, expected):
    """Require the reviewed policy and the translated Kubernetes API backend."""
    from .manifests import validate_network_policy

    actual = kube(kubeconfig, "-n", "openbao", "get", "ciliumnetworkpolicy", "openbao", "-o", "json")
    endpoints = kube(kubeconfig, "-n", "default", "get", "endpointslices",
                     "-l", "kubernetes.io/service-name=kubernetes", "-o", "json")
    backend_ports = {(p.get("port"), p.get("protocol"))
                     for item in endpoints.get("items", []) for p in item.get("ports", [])}
    if (validate_network_policy(expected) or actual.get("spec") != expected.get("spec")
            or backend_ports != {(6443, "TCP")}):
        raise SafeError("source-mismatch")
    return digest(actual["spec"])


def preparation_unit(kubeconfig, approved, name):
    """Refresh source and the exact suspended Flux unit immediately before resume."""
    import yaml

    if name not in {"openbao-prerequisites", "openbao"}:
        raise SafeError("invalid-source")
    revision = source_revision()
    if revision != approved["source_revision"] or package_digest() != approved["package_digest"]:
        raise SafeError("source-mismatch")
    require_deployed_revision(kubeconfig, revision)
    cluster = kube(kubeconfig, "get", "namespace", "kube-system", "-o", "json")
    if cluster["metadata"]["uid"] != approved["cluster_uid"]:
        raise SafeError("source-mismatch")
    expected = next(
        u
        for u in yaml.safe_load_all((PACKAGE / "ks.yaml").read_bytes())
        if u["metadata"]["name"] == name
    )
    actual = kube(kubeconfig, "-n", "flux-system", "get", "kustomization", name, "-o", "json")
    if (
        actual["metadata"]["uid"] != approved["flux_unit_uids"][name]
        or expected["spec"].get("suspend") is not True
        or not contains_source(expected["spec"], actual["spec"])
    ):
        raise SafeError("source-mismatch")
    return actual


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
    if not recipient:
        print(
            "Set OPENBAO_RECOVERY_RECIPIENT to the public age recipient in the seal artifact. "
            "For agent setup, use: mise exec -- just bootstrap openbao-agent <path>",
            file=sys.stderr,
        )
    validate_recipient(recipient)
    require_deployed_revision(kubeconfig, revision)
    package_hash = package_digest()
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
            or (phase == "prepare" and actual["spec"].get("suspend") is not
                (expected["metadata"]["name"] != "openbao-restore-test"))
        ):
            raise SafeError("source-mismatch")
    target = {
        "source_revision": revision,
        "package_digest": package_hash,
        "flux_unit_uids": {
            u["metadata"]["name"]: u["metadata"]["uid"]
            for u in units
            if u["metadata"]["name"] in {e["metadata"]["name"] for e in desired_units}
        },
        "cluster_uid": cluster["metadata"]["uid"],
        "recipient": recipient,
        "seal_key_id": "openbao-static-seal-v1",
    }
    if phase == "config-apply":
        target["agent_profiles"] = require_agent_profiles_ready(kubeconfig)
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
    if not contains_statefulset_source(expected_sts["spec"], sts["spec"]):
        raise SafeError("source-mismatch")
    config = kube(kubeconfig, "-n", "openbao", "get", "configmap", "openbao-config", "-o", "json")
    if config["data"] != expected_config["data"]:
        raise SafeError("source-mismatch")
    target["configuration_digest"] = digest(config["data"])
    target["network_policy_digest"] = require_api_egress(
        kubeconfig, yaml.safe_load((PACKAGE / "app/ciliumnetworkpolicy.yaml").read_bytes())
    )
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
