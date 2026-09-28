"""Attended reset of unused staged OpenBao Raft state after ambiguous init."""

import copy
import json
import os
import re
import sys
import time
from pathlib import Path

import yaml

from . import guards, secrets
from .client import AmbiguousWrite
from .configuration import SafeError, canonical_json


def validate_staged_inventory(target: dict, items: list, pvs: list) -> dict:
    """Require exactly the staged server workload and its three retained claims."""
    expected = {
        "HelmRelease": {"openbao"},
        "StatefulSet": {"openbao"},
        "Pod": set(target["pod_uids"]),
        "PersistentVolumeClaim": set(target["pvc_uids"]),
    }
    grouped = {kind: {} for kind in expected}
    for item in items:
        kind = item.get("kind")
        name = item.get("metadata", {}).get("name")
        if kind not in grouped or name not in expected[kind] or name in grouped[kind]:
            raise SafeError("source-mismatch")
        grouped[kind][name] = item
    if any(set(grouped[kind]) != names for kind, names in expected.items()):
        raise SafeError("source-mismatch")
    reviewed = yaml.safe_load((guards.PACKAGE / "app/helmrelease.yaml").read_bytes())
    actual_spec = copy.deepcopy(grouped["HelmRelease"]["openbao"].get("spec", {}))
    chart_spec = actual_spec.get("chart", {}).get("spec", {})
    if chart_spec.get("reconcileStrategy", "ChartVersion") != "ChartVersion":
        raise SafeError("source-mismatch")
    chart_spec.pop("reconcileStrategy", None)
    if actual_spec != reviewed["spec"]:
        raise SafeError("source-mismatch")
    if grouped["StatefulSet"]["openbao"]["metadata"].get("uid") != target["statefulset_uid"]:
        raise SafeError("source-mismatch")
    for kind, field in (("Pod", "pod_uids"), ("PersistentVolumeClaim", "pvc_uids")):
        for name, uid in target[field].items():
            if grouped[kind][name]["metadata"].get("uid") != uid:
                raise SafeError("source-mismatch")
    matched_pvs = {}
    for name, uid in target["pvc_uids"].items():
        claim = grouped["PersistentVolumeClaim"][name]
        matches = [pv for pv in pvs if pv["metadata"]["name"] == claim["spec"].get("volumeName")]
        if (
            len(matches) != 1
            or matches[0]["spec"].get("persistentVolumeReclaimPolicy") != "Delete"
            or matches[0]["spec"].get("claimRef", {}).get("uid") != uid
        ):
            raise SafeError("source-mismatch")
        matched_pvs[name] = {
            "name": matches[0]["metadata"]["name"],
            "uid": matches[0]["metadata"]["uid"],
        }
    return {"helmrelease": grouped["HelmRelease"]["openbao"], "pvs": matched_pvs}


def delete_exact(kubeconfig: Path, path: str, uid: str, resource_version: str) -> None:
    """Use server-enforced identity preconditions for a single API DELETE."""
    if (
        not re.fullmatch(
            r"/apis/helm\.toolkit\.fluxcd\.io/v2/namespaces/openbao/helmreleases/openbao"
            r"|/api/v1/namespaces/openbao/persistentvolumeclaims/data-openbao-[0-2]",
            path,
        )
        or not uid
        or not resource_version
    ):
        raise SafeError("invalid-source")
    body = canonical_json(
        {
            "apiVersion": "meta.k8s.io/v1",
            "kind": "DeleteOptions",
            "preconditions": {"uid": uid, "resourceVersion": resource_version},
            "propagationPolicy": "Foreground",
        }
    )
    try:
        guards.command(
            [
                "kubectl",
                "--kubeconfig",
                str(kubeconfig),
                "--request-timeout=30s",
                "delete",
                "--raw",
                path,
                "-f",
                "-",
            ],
            input_bytes=body,
            timeout=35,
        )
    except SafeError:
        # A missing HTTP response cannot prove whether the delete committed.
        raise AmbiguousWrite("ambiguous-write") from None


def _snapshot(kubeconfig: Path, recipient: str) -> tuple[dict, dict]:
    target = guards.freeze_target(kubeconfig, "initialize")
    if target["recipient"] != recipient:
        raise SafeError("source-mismatch")
    units = guards.kube(kubeconfig, "-n", "flux-system", "get", "kustomizations", "-o", "json")[
        "items"
    ]
    for name, uid in target["flux_unit_uids"].items():
        matches = [u for u in units if u["metadata"]["name"] == name]
        if (
            len(matches) != 1
            or matches[0]["metadata"].get("uid") != uid
            or matches[0]["spec"].get("suspend") is not True
        ):
            raise SafeError("source-mismatch")
    items = guards.kube(
        kubeconfig,
        "-n",
        "openbao",
        "get",
        "helmreleases,statefulsets,pods,pvc,deployments,daemonsets,jobs,cronjobs,httproutes,ingresses",
        "-o",
        "json",
    )["items"]
    pvs = guards.kube(kubeconfig, "get", "pv", "-o", "json")["items"]
    live = validate_staged_inventory(target, items, pvs)
    helm = live["helmrelease"]
    snapshot = {
        "target": target,
        "helmrelease_uid": helm["metadata"]["uid"],
        "pvs": live["pvs"],
    }
    return snapshot, helm


def _remaining(kubeconfig: Path, snapshot: dict) -> dict:
    """Inspect each known identity after HelmRelease deletion; reject replacements."""
    target = snapshot["target"]
    if guards.source_revision() != target["source_revision"]:
        raise SafeError("source-mismatch")
    guards.require_deployed_revision(kubeconfig, target["source_revision"])
    for name, uid in (
        ("kube-system", target["cluster_uid"]),
        ("openbao", target["namespace_uid"]),
    ):
        namespace = guards.kube(kubeconfig, "get", "namespace", name, "-o", "json")
        if namespace["metadata"].get("uid") != uid:
            raise SafeError("source-mismatch")
    units = guards.kube(kubeconfig, "-n", "flux-system", "get", "kustomizations", "-o", "json")[
        "items"
    ]
    for name, uid in target["flux_unit_uids"].items():
        matches = [u for u in units if u["metadata"]["name"] == name]
        if (
            len(matches) != 1
            or matches[0]["metadata"].get("uid") != uid
            or matches[0]["spec"].get("suspend") is not True
        ):
            raise SafeError("source-mismatch")
    items = guards.kube(
        kubeconfig,
        "-n",
        "openbao",
        "get",
        "helmreleases,statefulsets,pods,pvc,deployments,daemonsets,jobs,cronjobs,httproutes,ingresses",
        "-o",
        "json",
    )["items"]
    identities = {
        "HelmRelease": {"openbao": snapshot["helmrelease_uid"]},
        "StatefulSet": {"openbao": target["statefulset_uid"]},
        "Pod": target["pod_uids"],
        "PersistentVolumeClaim": target["pvc_uids"],
    }
    found = {kind: {} for kind in identities}
    for item in items:
        kind = item.get("kind")
        metadata = item.get("metadata", {})
        name = metadata.get("name")
        if (
            kind not in found
            or name not in identities[kind]
            or metadata.get("uid") != identities[kind][name]
            or name in found[kind]
        ):
            raise SafeError("source-mismatch")
        found[kind][name] = item
    pvs = guards.kube(kubeconfig, "get", "pv", "-o", "json")["items"]
    present_pvs = {}
    for claim_name, expected in snapshot["pvs"].items():
        matches = [p for p in pvs if p["metadata"]["name"] == expected["name"]]
        if len(matches) > 1:
            raise SafeError("source-mismatch")
        if matches:
            pv = matches[0]
            if (
                pv["metadata"].get("uid") != expected["uid"]
                or pv["spec"].get("persistentVolumeReclaimPolicy") != "Delete"
                or pv["spec"].get("claimRef", {}).get("uid") != target["pvc_uids"][claim_name]
            ):
                raise SafeError("source-mismatch")
            present_pvs[claim_name] = pv
        claim = found["PersistentVolumeClaim"].get(claim_name)
        if claim and (not matches or claim["spec"].get("volumeName") != expected["name"]):
            raise SafeError("source-mismatch")
    return {
        "helmrelease": found["HelmRelease"].get("openbao"),
        "statefulset": found["StatefulSet"].get("openbao"),
        "pods": found["Pod"],
        "claims": found["PersistentVolumeClaim"],
        "pvs": present_pvs,
    }


def _wait_helm_absent(kubeconfig: Path, snapshot: dict) -> None:
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        guards.assert_mutation_allowed(kubeconfig)
        observed = _remaining(kubeconfig, snapshot)
        if set(observed["claims"]) != set(snapshot["target"]["pvc_uids"]) or set(
            observed["pvs"]
        ) != set(snapshot["pvs"]):
            raise SafeError("source-mismatch")
        if not observed["helmrelease"] and not observed["statefulset"] and not observed["pods"]:
            return
        time.sleep(2)
    raise SafeError("timeout")


def _remove_claims(kubeconfig: Path, snapshot: dict) -> None:
    remaining = set(snapshot["target"]["pvc_uids"])
    for name in sorted(remaining):
        guards.assert_mutation_allowed(kubeconfig)
        observed = _remaining(kubeconfig, snapshot)
        if (
            observed["helmrelease"]
            or observed["statefulset"]
            or observed["pods"]
            or set(observed["claims"]) != remaining
            or set(observed["pvs"]) != remaining
        ):
            raise SafeError("source-mismatch")
        claim = observed["claims"][name]
        guards.assert_mutation_allowed(kubeconfig)
        delete_exact(
            kubeconfig,
            f"/api/v1/namespaces/openbao/persistentvolumeclaims/{name}",
            claim["metadata"]["uid"],
            claim["metadata"]["resourceVersion"],
        )
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            guards.assert_mutation_allowed(kubeconfig)
            observed = _remaining(kubeconfig, snapshot)
            if observed["helmrelease"] or observed["statefulset"] or observed["pods"]:
                raise SafeError("source-mismatch")
            if name not in observed["claims"] and name not in observed["pvs"]:
                break
            time.sleep(2)
        else:
            raise SafeError("timeout")
        remaining.remove(name)
    observed = _remaining(kubeconfig, snapshot)
    if any(observed.values()):
        raise SafeError("source-mismatch")


def run(
    *, kubeconfig: Path, client, recovery_directory: Path, recipient: str, confirm: str = ""
) -> dict:
    secrets.preflight_recovery(recovery_directory, recipient)
    snapshot, helm = _snapshot(kubeconfig, recipient)
    states = client.states_now()
    if len(states) != 3 or any(s.get("initialized") is not True for s in states):
        raise SafeError("source-mismatch")
    required = guards.confirmation(
        "reset-staged", snapshot["target"]["source_revision"], guards.digest(snapshot)
    )
    if confirm != required:
        return {"status": "confirmation-required", "confirmation": required}
    guards.assert_mutation_allowed(kubeconfig)
    secrets.preflight_recovery(recovery_directory, recipient)
    again, helm = _snapshot(kubeconfig, recipient)
    if again != snapshot:
        raise SafeError("source-mismatch")
    states = client.states_now()
    if len(states) != 3 or any(s.get("initialized") is not True for s in states):
        raise SafeError("source-mismatch")
    guards.assert_mutation_allowed(kubeconfig)
    delete_exact(
        kubeconfig,
        "/apis/helm.toolkit.fluxcd.io/v2/namespaces/openbao/helmreleases/openbao",
        snapshot["helmrelease_uid"],
        helm["metadata"]["resourceVersion"],
    )
    _wait_helm_absent(kubeconfig, snapshot)
    _remove_claims(kubeconfig, snapshot)
    return {"status": "pass"}


def main(argv: list[str]) -> int:
    """Require an explicit operator kubeconfig and target-bound confirmation."""
    from .operator import OperatorClient, lease

    client = None
    try:
        if argv != ["reset-staged"]:
            raise SafeError("invalid-source")
        selected = os.environ.get("OPENBAO_OPERATOR_KUBECONFIG", "")
        kubeconfig = Path(selected)
        if not selected or not kubeconfig.is_absolute() or not kubeconfig.is_file():
            raise SafeError("invalid-source")
        client = OperatorClient(kubeconfig)
        inputs = {
            "kubeconfig": kubeconfig,
            "client": client,
            "recovery_directory": Path(os.environ.get("OPENBAO_RECOVERY_DIRECTORY", "")),
            "recipient": os.environ.get("OPENBAO_RECOVERY_RECIPIENT", ""),
        }
        preview = run(confirm="", **inputs)
        supplied = os.environ.get("OPENBAO_RESET_CONFIRM", "")
        if supplied != preview["confirmation"]:
            print(json.dumps(preview, sort_keys=True))
            return 2
        with lease(kubeconfig):
            result = run(confirm=supplied, **inputs)
        print(json.dumps(result, sort_keys=True))
        return 0 if result["status"] == "pass" else 1
    except Exception:  # noqa: BLE001 -- Do not render credential-bearing exceptions.
        error = sys.exc_info()[1]
        print(
            json.dumps(
                {
                    "status": "incomplete",
                    "classification": str(error)
                    if isinstance(error, SafeError)
                    else "invalid-response",
                }
            )
        )
        return 1
    finally:
        if client is not None:
            client.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
