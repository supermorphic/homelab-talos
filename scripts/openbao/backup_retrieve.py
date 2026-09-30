"""Operator-only retrieval of one completed backup; no server exec or Secret reads."""

import copy
import json
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import yaml

from scripts.test.scenarios.openbao_issuance import safe_probe_spec
from scripts.test.scenarios.resilience_support import install_interrupt_handlers

from . import guards, restore
from .configuration import SafeError, strict_json

OWNER = "homelab.supermorphic.com/backup-retrieval"
IMAGE = yaml.safe_load((guards.PACKAGE / "backup/cronjob.yaml").read_text())["spec"][
    "jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["image"]

# Fixed code runs only in our read-only PVC reader. Nothing is extracted in cluster.
# Select by the completed Job's time window, never by the moving latest pointer.
COPY = r'''
import json, os, re, shutil, stat, sys
from pathlib import Path
def read(path, limit):
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    stream = os.fdopen(fd, 'rb')
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
        stream.close()
        raise ValueError()
    return stream, info.st_size
try:
    root, start, end = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    selected = []
    for pair in root.glob('snapshot-*'):
        if pair.is_symlink() or not re.fullmatch(r'snapshot-\d{4}-\d{2}-\d{2}T\d{6}Z', pair.name):
            raise ValueError()
        with read(pair / 'metadata.json', 8192)[0] as stream:
            raw = stream.read(8193)
        metadata = json.loads(raw)
        created = metadata['created_at']
        if pair.name != 'snapshot-' + created.replace(':', ''):
            raise ValueError()
        if start <= created <= end:
            selected.append((pair, raw))
    if len(selected) != 1:
        raise ValueError()
    pair, raw = selected[0]
    with read(pair / 'raft.snap', 2 * 1024**3)[0] as stream:
        sys.stdout.buffer.write(len(raw).to_bytes(4, 'big'))
        sys.stdout.buffer.write(raw)
        shutil.copyfileobj(stream, sys.stdout.buffer, 1024**2)
except Exception:
    sys.exit(1)
'''


def pod_document(name, node):
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "namespace": "openbao",
                     "annotations": {OWNER: name}, "labels": {OWNER: name}},
        "spec": {
            "nodeName": node, "serviceAccountName": "default",
            "automountServiceAccountToken": False, "enableServiceLinks": False,
            "restartPolicy": "Never", "activeDeadlineSeconds": 600,
            "securityContext": {"runAsNonRoot": True, "runAsUser": 1000,
                                "runAsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [{"name": "reader", "image": IMAGE,
                "command": ["python", "-c", "import time; time.sleep(600)"],
                "resources": {"requests": {"cpu": "10m", "memory": "32Mi"},
                              "limits": {"cpu": "200m", "memory": "128Mi"}},
                "securityContext": {"allowPrivilegeEscalation": False,
                                    "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                "volumeMounts": [{"name": "backup", "mountPath": "/backup", "readOnly": True}]}],
            "volumes": [{"name": "backup", "persistentVolumeClaim": {
                "claimName": "openbao-backup", "readOnly": True}}],
        },
    }


def matches_reader(expected, actual):
    wanted, observed = copy.deepcopy(expected["spec"]), copy.deepcopy(actual.get("spec", {}))
    if observed.get("nodeName") != wanted.pop("nodeName"):
        return False
    return safe_probe_spec(wanted, observed)


def prepare_destination(path):
    path = Path(path)
    if not path.is_absolute() or any(p.is_symlink() for p in (path, *path.parents)):
        raise SafeError("invalid-source")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.mkdir(mode=0o700)  # Refuse existing destination, even if empty.


class Reader:
    def __init__(self, kubeconfig):
        self.kubeconfig, self.objects = kubeconfig, []

    def command(self, *args, **kwargs):
        return guards.command(["kubectl", "--kubeconfig", str(self.kubeconfig),
                               "--request-timeout=15s", "-n", "openbao", *args], **kwargs)

    def get(self, kind, name):
        raw = self.command("get", kind, name, "--ignore-not-found", "-o", "json")
        return strict_json(raw) if raw.strip() else None

    def create(self, doc):
        if self.get(doc["kind"], doc["metadata"]["name"]):
            raise SafeError("source-mismatch")
        # Retain intent before an ambiguous create; cleanup requires our nonce.
        self.objects.append(doc)
        actual = strict_json(self.command("create", "-f", "-", "-o", "json",
                                         input_bytes=json.dumps(doc).encode()))
        doc["metadata"]["uid"] = actual["metadata"]["uid"]
        self.owned(doc)

    def owned(self, doc):
        actual = self.get(doc["kind"], doc["metadata"]["name"])
        if not actual:
            return None
        meta = actual["metadata"]
        if (meta.get("annotations", {}).get(OWNER) != doc["metadata"]["name"]
                or (doc["metadata"].get("uid") and meta["uid"] != doc["metadata"]["uid"])
                or (doc["kind"] == "Pod" and not matches_reader(doc, actual))
                or (doc["kind"] == "NetworkPolicy" and actual["spec"] != doc["spec"])):
            raise SafeError("source-mismatch")
        return actual

    def cleanup(self):
        for doc in reversed(self.objects):
            actual = self.owned(doc)
            if actual is None:
                continue
            meta = actual["metadata"]
            prefix, kind = (("/api/v1", "pods") if doc["kind"] == "Pod"
                            else ("/apis/networking.k8s.io/v1", "networkpolicies"))
            self.command("delete", "--raw", prefix + "/namespaces/openbao/" + kind + "/" + meta["name"],
                         "-f", "-", input_bytes=json.dumps({"apiVersion": "v1", "kind": "DeleteOptions",
                         "preconditions": {"uid": meta["uid"], "resourceVersion": meta["resourceVersion"]}}).encode())
            deadline = time.monotonic() + 90
            while self.get(doc["kind"], meta["name"]):
                if time.monotonic() >= deadline:
                    raise SafeError("timeout")
                time.sleep(1)


def target(reader, job_name):
    job = reader.get("job", job_name)
    claim = reader.get("pvc", "openbao-backup")
    if (not job or not claim or claim.get("status", {}).get("phase") != "Bound"
            or claim["spec"]["accessModes"] != ["ReadWriteOnce"]
            or claim["spec"]["storageClassName"] != "longhorn"
            or job.get("status", {}).get("succeeded") != 1
            or not any(c.get("type") == "Complete" and c.get("status") == "True"
                       for c in job["status"].get("conditions", []))):
        raise SafeError("invalid-response")
    pods = strict_json(reader.command("get", "pods", "-l", "job-name=" + job_name, "-o", "json"))["items"]
    successful = [p for p in pods if p.get("status", {}).get("phase") == "Succeeded"
                  and any(o.get("uid") == job["metadata"]["uid"] and o.get("kind") == "Job"
                          for o in p["metadata"].get("ownerReferences", []))]
    if len(successful) != 1:
        raise SafeError("invalid-response")
    pod = successful[0]
    if (not pod["spec"].get("nodeName")
            or not any(v.get("persistentVolumeClaim", {}).get("claimName") == "openbao-backup"
                       for v in pod["spec"].get("volumes", []))
            or pod["spec"]["containers"][0]["image"] != IMAGE):
        raise SafeError("source-mismatch")
    return {"job_uid": job["metadata"]["uid"], "pvc_uid": claim["metadata"]["uid"],
            "node": pod["spec"]["nodeName"], "start": job["status"]["startTime"],
            "end": job["status"]["completionTime"]}


def retrieve(reader, job_name, destination, selected):
    name = "openbao-backup-export-" + secrets.token_hex(8)
    policy = {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
        "metadata": {"name": name, "namespace": "openbao", "annotations": {OWNER: name}},
        "spec": {"podSelector": {"matchLabels": {OWNER: name}},
                 "policyTypes": ["Ingress", "Egress"]}}
    pod = pod_document(name, selected["node"])
    result = {"status": "incomplete", "cleanup": "incomplete", "stage": "preflight"}
    try:
        if target(reader, job_name) != selected:
            raise SafeError("source-mismatch")
        reader.create(policy)
        result["stage"] = "reader-startup"
        reader.create(pod)
        deadline = time.monotonic() + 180
        while True:
            actual = reader.owned(pod)
            if actual and any(c.get("type") == "Ready" and c.get("status") == "True"
                              for c in actual.get("status", {}).get("conditions", [])):
                break
            if time.monotonic() >= deadline:
                raise SafeError("timeout")
            time.sleep(1)
        if target(reader, job_name) != selected or not reader.owned(policy) or not reader.owned(pod):
            raise SafeError("source-mismatch")
        prepare_destination(destination)
        result["stage"] = "copy"
        # Binary stream goes directly into a mode-0600 file, never logs or evidence.
        with tempfile.TemporaryFile(dir=destination) as wire:
            process = subprocess.run(["kubectl", "--kubeconfig", str(reader.kubeconfig), "-n", "openbao",
                "exec", name, "-c", "reader", "--", "python", "-c", COPY, "/backup",
                selected["start"], selected["end"]], stdout=wire, stderr=subprocess.DEVNULL, timeout=180, check=False)
            if process.returncode or wire.tell() > restore._snapshot.MAX_SNAPSHOT_BYTES + 8196:
                raise SafeError("invalid-response")
            wire.seek(0)
            length = int.from_bytes(wire.read(4), "big")
            if not 1 <= length <= 8192:
                raise SafeError("invalid-response")
            metadata = strict_json(wire.read(length))
            for filename in ("metadata.json", "raft.snap"):
                fd = os.open(destination / filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "wb") as output:
                    if filename == "metadata.json":
                        output.write(json.dumps(metadata).encode() + b"\n")
                    else:
                        shutil.copyfileobj(wire, output, 1024**2)
            if not selected["start"] <= metadata["created_at"] <= selected["end"]:
                raise SafeError("invalid-response")
            result["stage"] = "validation"
            restore.validate_snapshot(destination / "raft.snap", metadata, metadata)
        if target(reader, job_name) != selected:
            raise SafeError("source-mismatch")
        result.update(status="pass", sha256=metadata["sha256"],
                      seal_key_id=metadata["seal_key_id"], recovery_generation=metadata["recovery_generation"])
    except SafeError as error:
        result.update(status="incomplete", classification=str(error))
    except Exception:  # noqa: BLE001 -- Do not render backup bytes, paths, or adapter errors.
        result["status"] = "incomplete"
    finally:
        try:
            reader.cleanup()
            result["cleanup"] = "passed"
        except Exception:  # noqa: BLE001 -- Ownership uncertainty requires operator review.
            result.update(status="incomplete", cleanup="incomplete")
    return result


def main():
    install_interrupt_handlers()
    os.umask(0o077)
    try:
        kubeconfig = Path(os.environ["OPENBAO_OPERATOR_KUBECONFIG"])
        job = os.environ["OPENBAO_BACKUP_JOB"]
        if not kubeconfig.is_absolute() or not kubeconfig.is_file() or not re.fullmatch(r"openbao-backup[-a-z0-9]*", job):
            raise SafeError("invalid-source")
        revision = guards.source_revision()
        guards.require_deployed_revision(kubeconfig, revision)
        reader = Reader(kubeconfig)
        selected = target(reader, job)
        destination = Path(os.environ.get("OPENBAO_BACKUP_DIRECTORY", str(
            Path.home() / ".local/share/homelab-recovery/openbao/snapshots" / job)))
        expected = "retrieve:openbao:" + job + ":" + guards.digest(selected)
        print("Copies one completed backup into operator-private storage; no server or Secret access.", flush=True)
        print("Destination: " + str(destination), flush=True)
        print("Exact confirmation: " + expected, flush=True)
        if input("Enter exact confirmation: ") != expected:
            raise SafeError("confirmation-required")
        result = retrieve(reader, job, destination, selected)
    except SafeError as error:
        result = {"status": "incomplete", "cleanup": "not-required", "classification": str(error)}
    except Exception:  # noqa: BLE001 -- Only fixed classifications leave private adapters.
        result = {"status": "incomplete", "cleanup": "not-required"}
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
