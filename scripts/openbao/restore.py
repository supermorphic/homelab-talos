"""Attended scratch-only restore. Credentials stay in adapters, never in results."""

import copy
import hashlib
import importlib.util
import os
import re
import stat
import tempfile
from datetime import UTC, datetime
from pathlib import Path

import yaml

from .configuration import strict_json

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests/fixtures/openbao/restore"
OWNER = "homelab.supermorphic.com/test-run"
IMAGES = {
    "2.7.0": "quay.io/openbao/openbao:2.7.0@sha256:71156a1c6623a5fa3f5e61b0c6a8ead0faf0df29a778339188443551995d1315"
}
_spec = importlib.util.spec_from_file_location(
    "openbao_snapshot", ROOT / "kubernetes/apps/security/openbao/backup/scripts/snapshot.py"
)
_snapshot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_snapshot)


class RestoreError(Exception):
    """Fixed failure category; no supplied value is rendered."""


def namespace(run_id):
    if not isinstance(run_id, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}", run_id
    ):
        raise RestoreError()
    return "openbao-restore-" + hashlib.sha256(run_id.encode()).hexdigest()[:16]


def private_file(path, limit):
    """Reject symlink components and non-regular inputs; never resolve a metadata path."""
    path = Path(path).absolute()
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise RestoreError()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise RestoreError()
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise RestoreError()
    return data


def load_metadata(path, snapshot_path):
    try:
        path = Path(path).absolute()
        if path != Path(snapshot_path).absolute().parent / "metadata.json":
            raise RestoreError()
        return strict_json(private_file(path, 8192))
    except Exception:  # noqa: BLE001 -- Credential-bearing adapters cannot render exceptions.
        raise RestoreError() from None


def validate_snapshot(path, metadata, recovery_metadata):
    """Use the backup writer's actual metadata and archive contract, without extraction."""
    if not isinstance(metadata, dict) or set(metadata) != {
        "created_at",
        "openbao_version",
        "raft_index",
        "seal_key_id",
        "recovery_generation",
        "sha256",
    }:
        raise RestoreError()
    if (
        metadata["openbao_version"] not in IMAGES
        or not re.fullmatch(r"[0-9a-f]{64}", metadata["sha256"])
        or type(metadata["raft_index"]) is not int
        or metadata["raft_index"] <= 0
        or not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", metadata["seal_key_id"])
        or not re.fullmatch(r"[1-9][0-9]{0,9}", metadata["recovery_generation"])
        or any(
            metadata[k] != recovery_metadata.get(k) for k in ("seal_key_id", "recovery_generation")
        )
    ):
        raise RestoreError()
    datetime.strptime(metadata["created_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    data = private_file(path, _snapshot.MAX_SNAPSHOT_BYTES)
    if hashlib.sha256(data).hexdigest() != metadata["sha256"]:
        raise RestoreError()
    # Validate the exact immutable bytes that will be sent, rather than reopening
    # an operator-selected path while another process could replace its contents.
    # Only encrypted snapshot bytes enter this mode-0600 temporary file.
    with tempfile.NamedTemporaryFile(prefix="openbao-archive-") as saved:
        saved.write(data)
        saved.flush()
        if _snapshot.archive_index(Path(saved.name)) != metadata["raft_index"]:
            raise RestoreError()
    return data


def documents(run_id, version):
    ns = namespace(run_id)
    if version not in IMAGES:
        raise RestoreError()
    result = []
    for name in ("namespace", "ciliumnetworkpolicy", "serviceaccount", "pvc", "statefulset"):
        document = yaml.safe_load((FIXTURES / f"{name}.yaml").read_bytes())
        document["metadata"]["annotations"] = {OWNER: run_id}
        if name == "namespace":
            document["metadata"]["name"] = ns
        else:
            document["metadata"]["namespace"] = ns
        if name == "statefulset":
            document["spec"]["template"]["metadata"]["annotations"] = {OWNER: run_id}
            document["spec"]["template"]["spec"]["containers"][0]["image"] = IMAGES[version]
        result.append(document)
    return result


def owned(expected, actual, run_id):
    meta = actual.get("metadata", {})
    want = expected["metadata"]
    if (
        meta.get("name") != want["name"]
        or meta.get("namespace") != want.get("namespace")
        or meta.get("uid") != want.get("uid")
        or not meta.get("uid")
        or meta.get("annotations", {}).get(OWNER) != run_id
        or meta.get("deletionTimestamp")
    ):
        raise RestoreError()


def recheck(kube, created, run_id):
    # Inventory first, identities last: none of the returned objects is cached.
    kube.inventory(namespace(run_id), run_id)
    for expected in created:
        actual = kube.read(expected)
        owned(expected, actual, run_id)
        if expected["kind"] == "CiliumNetworkPolicy" and actual.get("spec") != expected["spec"]:
            raise RestoreError()


def isolated(kube, run_id, pod_uid):
    result = kube.isolation(namespace(run_id), run_id, pod_uid)
    if result != {"loopback": True, "api_denied": True, "peers_denied": True}:
        raise RestoreError()


def healthy(client, version):
    value = client.wait_unsealed()
    if (
        value.get("initialized") is not True
        or value.get("sealed") is not False
        or value.get("version") != version
        or not value.get("cluster_id")
    ):
        raise RestoreError()
    return value["cluster_id"]


def run(snapshot_path, metadata, run_id, client, kube):
    """Return fixed phases and separate cleanup status, never raw adapter responses."""
    result = {"status": "fail", "phases": [], "cleanup": "not-required"}
    created = []
    mutation_started = False
    try:
        ns = namespace(run_id)
        validate_snapshot(snapshot_path, metadata, kube.recovery_metadata)
        confirmation = f"restore:openbao:{metadata['sha256']}:{run_id}"
        if os.environ.get("OPENBAO_RESTORE_CONFIRM") != confirmation:
            result["status"] = "refused"
            return result
        result["phases"].append("snapshot-validated")
        for document in documents(run_id, metadata["openbao_version"]):
            if document["kind"] == "StatefulSet":
                kube.provision_private(ns, run_id)
            mutation_started = True
            actual = kube.create(document)
            expected = copy.deepcopy(document)
            expected["metadata"]["uid"] = actual["metadata"]["uid"]
            created.append(expected)
            owned(expected, actual, run_id)
            if document["kind"] == "CiliumNetworkPolicy":
                live = kube.read(expected)
                owned(expected, live, run_id)
                if live.get("spec") != document["spec"]:
                    raise RestoreError()
        pod_uid = kube.wait_pod(ns)
        client.bind(ns, pod_uid)
        isolated(kube, run_id, pod_uid)
        recheck(kube, created, run_id)
        result["phases"].append("isolated")
        if client.state().get("initialized") is not False:
            raise RestoreError()
        client.initialize()  # Exactly once; no response-lost retry.
        healthy(client, metadata["openbao_version"])
        data = validate_snapshot(snapshot_path, metadata, kube.recovery_metadata)
        isolated(kube, run_id, pod_uid)
        recheck(kube, created, run_id)  # Immediately before the sole force write.
        client.force_restore(data)
        del data
        client.login_retained()
        cluster_id = healthy(client, metadata["openbao_version"])
        isolated(kube, run_id, pod_uid)
        if client.restored_configuration() is not True or client.issuance_denied() is not True:
            raise RestoreError()
        result["phases"].append("restored")
        recheck(kube, created, run_id)
        next_uid = kube.restart(ns, run_id, pod_uid)
        if not next_uid or next_uid == pod_uid:
            raise RestoreError()
        client.bind(ns, next_uid)
        client.login_retained()
        if healthy(client, metadata["openbao_version"]) != cluster_id:
            raise RestoreError()
        isolated(kube, run_id, next_uid)
        if client.restored_configuration() is not True or client.issuance_denied() is not True:
            raise RestoreError()
        result["phases"].append("restart-verified")
        result["status"] = "pass"
    except Exception:  # noqa: BLE001 -- Credential-bearing adapters cannot render exceptions.
        result["status"] = "fail"
    finally:
        try:
            client.close()
        except Exception:  # noqa: BLE001 -- Continue cleanup without exposing adapter errors.
            result["status"] = "fail"
        if mutation_started and not created:
            result["cleanup"] = "failed"
        if created:
            try:
                recheck(kube, created, run_id)
                kube.cleanup(created, run_id)
                result["cleanup"] = "passed"
            except Exception:  # noqa: BLE001 -- Credential-bearing adapters cannot render exceptions.
                result["cleanup"] = "failed"
                result["status"] = "fail"
    return result
