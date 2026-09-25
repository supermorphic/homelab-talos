"""Operator-only restore drill; the catalog owns the run ID and evidence directory."""

import base64
import ipaddress
import json
import os
import re
import sys
import time
from pathlib import Path

# Permit catalog direct dispatch as well as module execution.
ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.openbao import apply, guards, restore
from scripts.openbao.configuration import strict_json
from scripts.openbao.operator import private_prompt
from scripts.test.scenarios.resilience_support import atomic_write_json, install_interrupt_handlers

# Only loopback is addressable by the credential-bearing bridge. No redirects,
# retries, shell, response-body logging, or environment-carried tokens.
BRIDGE = """
import http.client, json, sys
try:
    args = json.loads(sys.stdin.buffer.readline(65536))
    connection = http.client.HTTPConnection("127.0.0.1", 8200, timeout=30)
    headers = {"Content-Type": "application/json", "X-Vault-No-Request-Forwarding": "true"}
    if args.get("token"):
        headers["X-Vault-Token"] = args["token"]
    if "length" in args:
        headers["Content-Length"] = str(args["length"])
        headers["Content-Type"] = "application/octet-stream"
        body = sys.stdin.buffer
    else:
        body = json.dumps(args["payload"]).encode() if args.get("payload") is not None else None
    connection.request(args["method"], "/v1/" + args["path"], body, headers)
    response = connection.getresponse()
    data = response.read(1048577)
    if len(data) > 1048576:
        raise ValueError()
    body = json.loads(data) if data and 200 <= response.status < 300 else {}
    if (response.status == 500 and args["method"] == "GET"
            and args["path"] == "auth/homelab-jwt/config"
            and json.loads(data) == {"errors": [EXPECTED_PROVIDER_ERROR]}):
        body = {"provider_unavailable": True}
    print(json.dumps({"status": response.status, "body": body}))
except Exception:
    sys.exit(1)
""".replace("EXPECTED_PROVIDER_ERROR", repr(restore.PROVIDER_UNAVAILABLE))

PROBE = """
import errno, json, socket, sys
try:
    targets = json.load(sys.stdin)
    with socket.create_connection(("127.0.0.1", 8200), timeout=3):
        pass
    result = {"loopback": True}
    for group, endpoints in targets.items():
        denied = bool(endpoints)
        for address, port in endpoints:
            try:
                with socket.create_connection((address, port), timeout=3):
                    denied = False
            except OSError as error:
                # Refusal, DNS failure, and unreachable routes are not proof of
                # enforcement. Only a timed-out connection meets this oracle.
                if not isinstance(error, TimeoutError) and error.errno != errno.ETIMEDOUT:
                    denied = False
        result[group] = denied
    print(json.dumps(result))
except Exception:
    sys.exit(1)
"""


class ScratchKube:
    def __init__(self, kubeconfig, run_id, recovery_metadata, seal):
        self.kubeconfig = kubeconfig
        self.run_id = run_id
        self.namespace = restore.namespace(run_id)
        self.recovery_metadata = recovery_metadata
        self.seal = seal
        self.pod_uid = None
        self.extra = []
        self.created = []
        self.pv_uid = None
        self.volume_uid = None

    def command(self, *args, input_bytes=None):
        return guards.command(
            ["kubectl", "--kubeconfig", str(self.kubeconfig), "--request-timeout=15s", *args],
            input_bytes=input_bytes,
        )

    def json(self, *args):
        return strict_json(self.command(*args))

    def create(self, document):
        if document["kind"] != "Namespace":
            self.assert_namespace()
        actual = strict_json(
            self.command(
                "create", "-f", "-", "-o", "json", input_bytes=json.dumps(document).encode()
            )
        )
        # Keep only metadata for secret bodies. Recovery values never enter evidence.
        expected = json.loads(json.dumps(document))
        expected["metadata"]["uid"] = actual["metadata"]["uid"]
        if document["kind"] == "Secret":
            expected.pop("data", None)
        self.created.append(expected)
        return actual

    def read(self, document):
        args = [] if document["kind"] == "Namespace" else ["-n", self.namespace]
        return self.json(
            *args, "get", document["kind"], document["metadata"]["name"], "-o", "json"
        )

    def assert_namespace(self):
        if not self.created or self.created[0]["kind"] != "Namespace":
            raise restore.RestoreError()
        restore.owned(self.created[0], self.read(self.created[0]), self.run_id)

    def provision_private(self, namespace, run_id):
        self.assert_namespace()
        if namespace != self.namespace or run_id != self.run_id:
            raise restore.RestoreError()
        metadata = {"namespace": namespace, "annotations": {restore.OWNER: run_id}}
        seal = {
            "apiVersion": "v1",
            "kind": "Secret",
            "type": "Opaque",
            "immutable": True,
            "metadata": {**metadata, "name": "scratch-seal"},
            "data": {"key": base64.b64encode(self.seal).decode()},
        }
        self.create(seal)
        self.extra.append(self.created[-1])
        self.seal = None
        config = """disable_mlock = true
raw_storage_endpoint = true
api_addr = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"
listener "tcp" {
  address = "127.0.0.1:8200"
  cluster_address = "127.0.0.1:8201"
  tls_disable = true
}
storage "raft" {
  path = "/openbao/data"
  node_id = "scratch"
}
seal "static" {
  current_key_id = "SEAL_ID"
  current_key = "file:///scratch-seal/key"
}
""".replace("SEAL_ID", self.recovery_metadata["seal_key_id"])
        self.create(
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "immutable": True,
                "metadata": {**metadata, "name": "scratch-config"},
                "data": {"server.hcl": config},
            }
        )
        self.extra.append(self.created[-1])

    def wait_pod(self, namespace):
        if namespace != self.namespace:
            raise restore.RestoreError()
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            pods = self.json("-n", namespace, "get", "pods", "-o", "json")["items"]
            if len(pods) == 1 and pods[0].get("status", {}).get("phase") == "Running":
                self.pod_uid = pods[0]["metadata"]["uid"]
                self.assert_pod(self.pod_uid)
                return self.pod_uid
            time.sleep(2)
        raise restore.RestoreError()

    def assert_pod(self, pod_uid):
        self.assert_namespace()
        pod = self.json("-n", self.namespace, "get", "pod", "scratch-0", "-o", "json")
        sts = next(d for d in self.created if d["kind"] == "StatefulSet")
        spec = pod["spec"]
        template = sts["spec"]["template"]["spec"]
        if (
            pod["metadata"].get("uid") != pod_uid
            or pod["metadata"].get("deletionTimestamp")
            or pod["metadata"].get("annotations", {}).get(restore.OWNER) != self.run_id
            or not any(
                o.get("uid") == sts["metadata"]["uid"] and o.get("controller") is True
                for o in pod["metadata"].get("ownerReferences", [])
            )
            or spec.get("automountServiceAccountToken") is not False
            or spec.get("enableServiceLinks") is not False
            or spec.get("hostNetwork", False)
            or spec.get("hostPID", False)
            or spec.get("hostIPC", False)
            or spec.get("initContainers")
            or spec.get("ephemeralContainers")
            or any(
                c.get("securityContext", {}).get("privileged", False)
                or c.get("securityContext", {}).get("procMount", "Default") != "Default"
                or c.get("env")
                or c.get("envFrom")
                for c in spec.get("containers", [])
            )
            or len(spec.get("containers", [])) != 2
            or len(spec.get("volumes", [])) != len(template["volumes"])
            or not guards.contains_source(template, spec)
        ):
            raise restore.RestoreError()
        return pod

    def http(self, method, path, *, payload=None, token=None, data=None):
        self.assert_pod(self.pod_uid)
        if (
            method not in {"GET", "LIST", "POST"}
            or not path
            or path.startswith("/")
            or ".." in path
        ):
            raise restore.RestoreError()
        message = {"method": method, "path": path, "payload": payload, "token": token}
        if data is not None:
            message["length"] = len(data)
        wire = json.dumps(message).encode() + b"\n" + (data or b"")
        response = strict_json(
            self.command(
                "-n",
                self.namespace,
                "exec",
                "-i",
                "scratch-0",
                "-c",
                "runner",
                "--",
                "python",
                "-c",
                BRIDGE,
                input_bytes=wire,
            )
        )
        return response["status"], response["body"]

    def assert_storage(self):
        expected = next(d for d in self.created if d["kind"] == "PersistentVolumeClaim")
        claim = self.read(expected)
        restore.owned(expected, claim, self.run_id)
        if not guards.contains_source(expected["spec"], claim["spec"]):
            raise restore.RestoreError()
        name = "pvc-" + expected["metadata"]["uid"]
        if (
            claim["spec"].get("volumeName") != name
            or claim["spec"].get("dataSource")
            or claim["spec"].get("dataSourceRef")
            or claim["spec"].get("selector")
        ):
            raise restore.RestoreError()
        pv = self.json("get", "pv", name, "-o", "json")
        ref = pv["spec"].get("claimRef", {})
        if (
            ref.get("uid") != expected["metadata"]["uid"]
            or ref.get("namespace") != self.namespace
            or ref.get("name") != "scratch-data"
            or pv["spec"].get("csi", {}).get("driver") != "driver.longhorn.io"
            or pv["spec"].get("csi", {}).get("volumeHandle") != name
            or pv["spec"].get("persistentVolumeReclaimPolicy") != "Delete"
            or (self.pv_uid is not None and pv["metadata"]["uid"] != self.pv_uid)
        ):
            raise restore.RestoreError()
        self.pv_uid = pv["metadata"]["uid"]
        volume = self.json(
            "-n", "longhorn-system", "get", "volumes.longhorn.io", name, "-o", "json"
        )
        meta = volume["metadata"]
        if (
            meta.get("name") != name
            or meta.get("namespace") != "longhorn-system"
            or not meta.get("uid")
            or (self.volume_uid is not None and meta["uid"] != self.volume_uid)
        ):
            raise restore.RestoreError()
        self.volume_uid = meta["uid"]

    def inventory(self, namespace, run_id):
        if namespace != self.namespace or run_id != self.run_id:
            raise restore.RestoreError()
        self.assert_namespace()
        # Forbid authority and alternate paths regardless of ownership labels.
        for kind in ("rolebindings", "roles", "services", "httproutes", "networkpolicies"):
            if self.json("-n", namespace, "get", kind, "-o", "json")["items"]:
                raise restore.RestoreError()
        bindings = self.json("get", "clusterrolebindings", "-o", "json")["items"]
        if any(
            s.get("namespace") == namespace
            or s.get("name") == f"system:serviceaccounts:{namespace}"
            for b in bindings
            for s in b.get("subjects", [])
        ):
            raise restore.RestoreError()
        for expected in self.extra:
            actual = self.read(expected)
            restore.owned(expected, actual, run_id)
            if actual.get("immutable") is not True:
                raise restore.RestoreError()
        for kind in ("StatefulSet", "PersistentVolumeClaim", "CiliumNetworkPolicy", "Secret"):
            expected = {d["metadata"]["name"] for d in self.created if d["kind"] == kind}
            actual = self.json("-n", namespace, "get", kind, "-o", "json")["items"]
            if {d["metadata"]["name"] for d in actual} != expected:
                raise restore.RestoreError()
        if self.pod_uid:
            self.assert_pod(self.pod_uid)
            self.assert_storage()

    def isolation(self, namespace, run_id, pod_uid):
        self.assert_pod(pod_uid)
        if namespace != self.namespace or run_id != self.run_id:
            raise restore.RestoreError()
        # API health and Ready production peers provide a live availability control.
        if self.command("get", "--raw=/readyz").strip() != b"ok":
            raise restore.RestoreError()
        service = self.json("-n", "default", "get", "service", "kubernetes", "-o", "json")
        endpoints = self.json("-n", "default", "get", "endpoints", "kubernetes", "-o", "json")
        api = [(str(ipaddress.ip_address(service["spec"]["clusterIP"])), 443)]
        api.extend(
            (str(ipaddress.ip_address(a["ip"])), p["port"])
            for s in endpoints["subsets"]
            for a in s.get("addresses", [])
            for p in s["ports"]
        )
        pods = self.json("-n", "openbao", "get", "pods", "-l", "component=server", "-o", "json")[
            "items"
        ]
        if len(pods) != 3 or any(
            not any(
                c.get("type") == "Ready" and c.get("status") == "True"
                for c in p.get("status", {}).get("conditions", [])
            )
            for p in pods
        ):
            raise restore.RestoreError()
        peers = [
            (str(ipaddress.ip_address(p["status"]["podIP"])), port)
            for p in pods
            for port in (8200, 8201)
        ]
        targets = {"api_denied": api, "peers_denied": peers}
        return strict_json(
            self.command(
                "-n",
                namespace,
                "exec",
                "-i",
                "scratch-0",
                "-c",
                "runner",
                "--",
                "python",
                "-c",
                PROBE,
                input_bytes=json.dumps(targets).encode(),
            )
        )

    def delete(self, expected):
        actual = self.read(expected)
        restore.owned(expected, actual, self.run_id)
        kind = expected["kind"]
        plural = {"Namespace": "namespaces", "Pod": "pods"}[kind]
        prefix = "/api/v1/" + (f"namespaces/{self.namespace}/" if kind == "Pod" else "")
        # UID and resourceVersion are atomic deletion preconditions, closing the
        # gap between the ownership read and the apiserver's DELETE operation.
        body = {
            "apiVersion": "v1",
            "kind": "DeleteOptions",
            "preconditions": {
                "uid": actual["metadata"]["uid"],
                "resourceVersion": actual["metadata"]["resourceVersion"],
            },
        }
        self.command(
            "delete",
            "--raw",
            prefix + plural + "/" + actual["metadata"]["name"],
            "-f",
            "-",
            input_bytes=json.dumps(body).encode(),
        )

    def restart(self, namespace, run_id, pod_uid):
        self.inventory(namespace, run_id)
        pod = self.assert_pod(pod_uid)
        self.delete(pod)
        self.pod_uid = None
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            pods = self.json("-n", namespace, "get", "pods", "-o", "json")["items"]
            if len(pods) == 1 and pods[0]["metadata"]["uid"] != pod_uid:
                return self.wait_pod(namespace)
            time.sleep(2)
        raise restore.RestoreError()

    def cleanup_inventory(self):
        # Namespace deletion is recursive. Inspect every discoverable API kind,
        # so an unrelated Job or custom resource is never silently removed.
        kinds = (
            self.command("api-resources", "--verbs=list", "--namespaced=true", "-o", "name")
            .decode()
            .splitlines()
        )
        known = {d["metadata"]["uid"] for d in self.created}
        if self.pod_uid:
            known.add(self.pod_uid)
        for kind in kinds:
            if kind in {"events", "events.events.k8s.io"}:
                continue
            for item in self.json("-n", self.namespace, "get", kind, "-o", "json")["items"]:
                meta = item["metadata"]
                annotations = meta.get("annotations", {})
                if restore.OWNER in annotations and annotations[restore.OWNER] != self.run_id:
                    raise restore.RestoreError()
                if meta.get("uid") in known:
                    if meta.get("annotations", {}).get(restore.OWNER) != self.run_id:
                        raise restore.RestoreError()
                    continue
                if (kind, meta["name"]) in {
                    ("serviceaccounts", "default"),
                    ("configmaps", "kube-root-ca.crt"),
                }:
                    continue
                if any(
                    o.get("uid") in known and o.get("controller") is True
                    for o in meta.get("ownerReferences", [])
                ):
                    continue
                raise restore.RestoreError()

    def storage_removed(self):
        claims = [d for d in self.created if d["kind"] == "PersistentVolumeClaim"]
        if not claims:
            return True
        name = "pvc-" + claims[0]["metadata"]["uid"]
        removed = True
        for prefix, kind, uid in (
            ([], "pv", self.pv_uid),
            (["-n", "longhorn-system"], "volumes.longhorn.io", self.volume_uid),
        ):
            value = self.command(*prefix, "get", kind, name, "--ignore-not-found", "-o", "json")
            if not value.strip():
                continue
            meta = strict_json(value)["metadata"]
            if not uid or meta.get("uid") != uid:
                raise restore.RestoreError()
            annotations = meta.get("annotations", {})
            if restore.OWNER in annotations and annotations[restore.OWNER] != self.run_id:
                raise restore.RestoreError()
            removed = False
        return removed

    def cleanup(self, documents, run_id):
        self.cleanup_inventory()
        restore.recheck(self, documents, run_id)
        self.delete(documents[0])
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            value = self.command(
                "get", "namespace", self.namespace, "--ignore-not-found", "-o", "name"
            )
            if not value.strip() and self.storage_removed():
                return
            time.sleep(2)
        raise restore.RestoreError()


class ScratchClient:
    def __init__(self, kube, password):
        self.kube = kube
        self.password = password
        self.token = None

    def bind(self, namespace, pod_uid):
        if namespace != self.kube.namespace:
            raise restore.RestoreError()
        self.kube.assert_pod(pod_uid)
        self.kube.pod_uid = pod_uid
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                state = self.state()
                if isinstance(state.get("initialized"), bool):
                    return
            except (restore.RestoreError, guards.SafeError):
                pass
            time.sleep(2)
        raise restore.RestoreError()

    def api(self, method, path, payload=None):
        status, body = self.kube.http(method, path, payload=payload, token=self.token)
        if not 200 <= status < 300:
            raise restore.RestoreError()
        return body

    def state(self):
        return self.api("GET", "sys/seal-status")

    def initialize(self):
        body = self.api("POST", "sys/init", {"recovery_shares": 1, "recovery_threshold": 1})
        self.token = body["root_token"]
        if not isinstance(self.token, str) or not self.token:
            raise restore.RestoreError()

    def wait_unsealed(self):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                state = self.state()
                if state.get("initialized") is True and state.get("sealed") is False:
                    return state
            except (restore.RestoreError, guards.SafeError):
                pass
            time.sleep(2)
        raise restore.RestoreError()

    def force_restore(self, data):
        status, _ = self.kube.http(
            "POST", "sys/storage/raft/snapshot-force", token=self.token, data=data
        )
        self.token = None  # Scratch bootstrap credential must never be reused.
        if status not in (200, 204):
            raise restore.RestoreError()

    def login_retained(self):
        self.wait_unsealed()
        body = self.api(
            "POST", "auth/homelab-userpass/login/openbao-operator", {"password": self.password}
        )
        self.token = body["auth"]["client_token"]
        if not isinstance(self.token, str) or not self.token:
            raise restore.RestoreError()

    def request(self, method, path):
        status, body = self.kube.http(method, path, token=self.token)
        if method == "GET" and path == "auth/homelab-jwt/config":
            # The restored Kubernetes provider cannot initialize without its
            # production ServiceAccount files. Prove that exact failure, then
            # inspect only its stored config with the retained operator policy.
            if status != 500 or body != {"provider_unavailable": True}:
                raise restore.RestoreError()
            mount = self.request("GET", "sys/auth").get("homelab-jwt/", {})
            uid = mount.get("uuid")
            if (mount.get("type") != "jwt" or not isinstance(uid, str)
                    or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", uid)):
                raise restore.RestoreError()
            return restore.stored_jwt_configuration(
                self.request("GET", f"sys/raw/auth/{uid}/config")
            )
        if status == 404:
            return {"keys": []} if method == "LIST" else None
        if status != 200 or not isinstance(body.get("data"), dict):
            raise restore.RestoreError()
        return body["data"]

    def restored_configuration(self):
        _, states = apply.snapshot(apply.DESIRED, self)
        # The exact source-owned acceptance issuance role and ACL are the
        # non-secret canary. Compare actual restored API reads, never a hash.
        if (
            not apply.audit_state(self)
            or not states
            or any(differences for _, differences in states.values())
        ):
            return False
        peers = self.api("GET", "sys/storage/raft/configuration")["data"]["config"]["servers"]
        return (
            len(peers) == 1
            and peers[0].get("node_id") == "scratch"
            and peers[0].get("voter") is True
            and peers[0].get("leader") is True
        )

    def issuance_denied(self):
        status, _ = self.kube.http(
            "POST",
            "kubernetes/creds/openbao-acceptance",
            payload={"kubernetes_namespace": "openbao-acceptance"},
            token=self.token,
        )
        # A forbidden login, wrong path, unhealthy server, or timeout does not
        # establish backend denial. Independent TCP probes also have to pass.
        return status == 500

    def close(self):
        self.token = None
        self.password = None
        self.kube.seal = None


def main():
    result = {"status": "fail", "phases": [], "cleanup": "not-required"}
    run_dir = None
    try:
        selected = os.environ.get("OPENBAO_OPERATOR_KUBECONFIG", "")
        if not selected or not Path(selected).is_absolute() or not Path(selected).is_file():
            raise restore.RestoreError()
        # The catalog coordinator must use the explicitly selected identity too.
        if os.environ.get("TEST_KUBECONFIG") != selected:
            raise restore.RestoreError()
        run_dir = Path(os.environ["HOMELAB_TEST_RUN_DIR"])
        if not run_dir.is_dir():
            raise restore.RestoreError()
        run_id = run_dir.name
        snapshot = Path(os.environ["OPENBAO_RESTORE_SNAPSHOT"])
        metadata = restore.load_metadata(snapshot.parent / "metadata.json", snapshot)
        recovery = {
            "seal_key_id": os.environ["OPENBAO_RESTORE_SEAL_ID"],
            "recovery_generation": os.environ["OPENBAO_RESTORE_GENERATION"],
        }
        restore.validate_snapshot(snapshot, metadata, recovery)
        required = f"restore:openbao:{metadata['sha256']}:{run_id}"
        supplied = os.environ.get("OPENBAO_RESTORE_CONFIRM") or private_prompt(
            f"Exact confirmation {required}: "
        )
        if supplied != required:
            raise restore.RestoreError()
        os.environ["OPENBAO_RESTORE_CONFIRM"] = required
        seal = base64.b64decode(
            private_prompt("Matching static seal key (base64): "), validate=True
        )
        password = private_prompt("Retained OpenBao operator password: ")
        if len(seal) != 32 or not password:
            raise restore.RestoreError()
        kube = ScratchKube(Path(selected), run_id, recovery, seal)
        install_interrupt_handlers()
        result = restore.run(snapshot, metadata, run_id, ScratchClient(kube, password), kube)
    except Exception:  # noqa: BLE001 -- Never render private input failures.
        result["status"] = "fail"
    finally:
        if run_dir is not None and run_dir.is_dir():
            atomic_write_json(run_dir / "diagnostics/openbao-restore.json", result)
            atomic_write_json(
                run_dir / "cleanup.json",
                {"status": result["cleanup"], "reason": "scratch cleanup"},
            )
            atomic_write_json(
                run_dir / "recovery.json",
                {"status": result["cleanup"], "reason": "scratch recovery"},
            )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
