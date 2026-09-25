"""Explicit operator credentials, bounded verified tunnels, and sanitized CLI output."""

import getpass
import http.client
import json
import os
import secrets as random
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import urlsplit

from . import apply, bootstrap, guards
from .client import BaoClient, NotFound
from .configuration import SafeError, canonical_json

HOST = "openbao.lab.supermorphic.com"


class Tunnel:
    def __init__(self, kubeconfig, pod):
        self.process = None
        self.port = None
        self.kubeconfig = kubeconfig
        self.pod = pod

    def start(self):
        self.process = subprocess.Popen(
            [
                "kubectl",
                "--kubeconfig",
                str(self.kubeconfig),
                "-n",
                "openbao",
                "port-forward",
                "--address=127.0.0.1",
                f"pod/{self.pod}",
                ":8200",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 15
        output = bytearray()
        while time.monotonic() < deadline and self.process.poll() is None:
            if not select.select([self.process.stdout], [], [], 0.2)[0]:
                continue
            output.extend(os.read(self.process.stdout.fileno(), 1024))
            if len(output) > 4096:
                break
            import re

            match = re.search(rb"Forwarding from 127\.0\.0\.1:(\d+) -> 8200", output)
            if match:
                self.port = int(match[1])
                return
        self.close()
        raise SafeError("timeout")

    def open(self, request, timeout):
        if self.process is None or self.process.poll() is not None:
            raise OSError("tunnel unavailable")
        connection = http.client.HTTPSConnection(
            HOST, context=ssl.create_default_context(), timeout=timeout
        )
        # TCP connects only to the owned loopback tunnel; HTTPS still verifies HOST.
        connection._create_connection = lambda address, timeout, source_address: (
            socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
        )
        connection.request(
            request.get_method(),
            urlsplit(request.full_url).path,
            body=request.data,
            headers=dict(request.header_items()),
        )
        response = connection.getresponse()
        if not 200 <= response.status < 300:
            status = response.status
            response.close()
            connection.close()
            raise urllib.error.HTTPError(request.full_url, status, "request failed", {}, None)

        class Response:
            status = response.status
            headers = response.headers

            def geturl(self):
                return request.full_url

            def read(self, size):
                return response.read(size)

            def __enter__(self):
                return self

            def __exit__(self, *_):
                response.close()
                connection.close()

        return Response()

    def close(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.process.stdout.close()
            self.process = None


class OperatorClient:
    def __init__(self, kubeconfig):
        self.kubeconfig = kubeconfig
        self.tunnels = {}
        self.clients = {}
        self.active = "openbao-0"
        self.token = None

    def set_token(self, token):
        self.token = token

    def peer(self, name):
        if name not in self.clients:
            tunnel = Tunnel(self.kubeconfig, name)
            tunnel.start()
            self.tunnels[name] = tunnel
            self.clients[name] = BaoClient(f"https://{HOST}", opener=tunnel.open)
        return self.clients[name]

    def states_now(self):
        pods = guards.kube(
            self.kubeconfig, "-n", "openbao", "get", "pods", "-l", "component=server", "-o", "json"
        )["items"]
        if not pods:
            return []
        if {p["metadata"]["name"] for p in pods} != {"openbao-0", "openbao-1", "openbao-2"}:
            raise SafeError("source-mismatch")
        return [self.peer(f"openbao-{i}").read("sys/init") for i in range(3)]

    def read(self, path, token=None):
        return self.peer(self.active).read(path, token=token)

    def request(self, method, path):
        try:
            value = self.peer(self.active).read(
                path, token=self.token, list_request=method == "LIST"
            )
        except NotFound:
            if method == "LIST":
                return {"keys": []}
            return None
        if not isinstance(value, dict) or not isinstance(value.get("data"), dict):
            raise SafeError("invalid-response")
        return value["data"]

    def post(self, path, payload, token=None):
        if path == "sys/init":
            return self.peer("openbao-0").post(path, payload)
        return self.peer(self.active).post(path, payload, token=token)

    def wait_quorum(self, token):
        self.token = token
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                statuses = [self.peer(f"openbao-{i}").read("sys/seal-status") for i in range(3)]
                if (
                    all(
                        s.get("initialized") is True and s.get("sealed") is False for s in statuses
                    )
                    and len({s.get("cluster_id") for s in statuses}) == 1
                    and all(s.get("cluster_id") for s in statuses)
                ):
                    leaders = [
                        f"openbao-{i}"
                        for i in range(3)
                        if self.peer(f"openbao-{i}").read("sys/leader").get("is_self") is True
                    ]
                    if len(leaders) == 1:
                        self.active = leaders[0]
                        raft = self.read("sys/storage/raft/configuration", token=token)
                        peers = raft["data"]["config"]["servers"]
                        if (
                            len(peers) == 3
                            and {p["node_id"] for p in peers}
                            == {"openbao-0", "openbao-1", "openbao-2"}
                            and all(p["voter"] is True for p in peers)
                            and [p["node_id"] for p in peers if p["leader"] is True] == leaders
                        ):
                            return
            except (SafeError, KeyError, TypeError):
                pass
            time.sleep(2)
        raise SafeError("timeout")

    def prepare(self):
        owned = []
        try:
            for name in ("openbao-prerequisites", "openbao"):
                guards.assert_mutation_allowed(self.kubeconfig)
                unit = guards.kube(
                    self.kubeconfig,
                    "-n",
                    "flux-system",
                    "get",
                    "kustomization",
                    name,
                    "-o",
                    "json",
                )
                if unit["spec"].get("suspend") is not True:
                    raise SafeError("source-mismatch")
                patch = [
                    {"op": "test", "path": "/metadata/uid", "value": unit["metadata"]["uid"]},
                    {
                        "op": "test",
                        "path": "/metadata/resourceVersion",
                        "value": unit["metadata"]["resourceVersion"],
                    },
                    {"op": "test", "path": "/spec/suspend", "value": True},
                    {"op": "replace", "path": "/spec/suspend", "value": False},
                ]
                # Record intent before mutation so a lost response still triggers containment.
                owned.append((name, unit["metadata"]["uid"]))
                guards.command(
                    [
                        "kubectl",
                        "--kubeconfig",
                        str(self.kubeconfig),
                        "-n",
                        "flux-system",
                        "patch",
                        "kustomization",
                        name,
                        "--type=json",
                        "-p",
                        canonical_json(patch).decode(),
                    ]
                )
                guards.command(
                    [
                        "flux",
                        "--kubeconfig",
                        str(self.kubeconfig),
                        "-n",
                        "flux-system",
                        "reconcile",
                        "kustomization",
                        name,
                        "--timeout=45s",
                    ]
                )
        finally:
            failed = False
            for name, uid in reversed(owned):
                try:
                    guards.assert_mutation_allowed(self.kubeconfig)
                    patch = [
                        {"op": "test", "path": "/metadata/uid", "value": uid},
                        {"op": "replace", "path": "/spec/suspend", "value": True},
                    ]
                    guards.command(
                        [
                            "kubectl",
                            "--kubeconfig",
                            str(self.kubeconfig),
                            "-n",
                            "flux-system",
                            "patch",
                            "kustomization",
                            name,
                            "--type=json",
                            "-p",
                            canonical_json(patch).decode(),
                        ]
                    )
                except SafeError:
                    failed = True
            if failed:
                raise SafeError("source-mismatch")
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                guards.freeze_target(self.kubeconfig, "initialize")
                bootstrap._uninitialized(self)
                return
            except SafeError:
                time.sleep(2)
        raise SafeError("timeout")

    def close(self):
        self.token = None
        for tunnel in self.tunnels.values():
            tunnel.close()


@contextmanager
def lease(kubeconfig):
    with tempfile.TemporaryDirectory(prefix="openbao-lock-") as directory:
        marker = str(Path(directory) / "renewal-failed")
        holder = "openbao-" + random.token_hex(16)
        process = subprocess.Popen(
            [
                "bash",
                str(guards.ROOT / "scripts/openbao/lock.sh"),
                "hold",
                str(kubeconfig),
                holder,
                marker,
            ],
            cwd=guards.ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        try:
            if (
                not select.select([process.stdout], [], [], 30)[0]
                or process.stdout.readline() != b"locked\n"
            ):
                raise SafeError("read-denied")
            os.environ["OPENBAO_LEASE_HOLDER"] = holder
            os.environ["OPENBAO_LEASE_FAILURE"] = marker
            yield
        finally:
            process.stdin.close()
            try:
                result = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.terminate()
                result = 1
                process.wait(timeout=5)
            process.stdout.close()
            os.environ.pop("OPENBAO_LEASE_HOLDER", None)
            os.environ.pop("OPENBAO_LEASE_FAILURE", None)
            if result != 0:
                raise SafeError("read-denied")


def main(argv):
    client = None
    try:
        if len(argv) != 2 or argv[1] not in {"prepare", "initialize", "config-apply"}:
            raise SafeError("invalid-source")
        phase = argv[1]
        selected = os.environ.get("OPENBAO_OPERATOR_KUBECONFIG", "")
        kubeconfig = Path(selected)
        if not selected or not kubeconfig.is_absolute() or not kubeconfig.is_file():
            raise SafeError("invalid-source")
        # Never adopt .kube/config or ambient administrative credentials implicitly.
        guards.freeze_target(kubeconfig, phase)
        client = OperatorClient(kubeconfig)
        inputs = {"client": client, "kubeconfig": kubeconfig, "journal": []}
        if phase == "config-apply":
            token = getpass.getpass("Existing authorized OpenBao token: ")
            if not token:
                raise SafeError("authentication-failed")
            client.wait_quorum(token)
            inputs["token"] = token
            operation = lambda confirm: apply.run(confirm=confirm, **inputs)
            supplied = os.environ.get("OPENBAO_CONFIG_CONFIRM", "")
        else:
            inputs.update(
                recovery_directory=Path(os.environ.get("OPENBAO_RECOVERY_DIRECTORY", "")),
                recipient=os.environ.get("OPENBAO_RECOVERY_RECIPIENT", ""),
            )
            operation = lambda confirm: bootstrap.run(phase, confirm=confirm, **inputs)
            supplied = os.environ.get("OPENBAO_BOOTSTRAP_CONFIRM", "")
        plan = operation("")
        if supplied != plan.get("confirmation"):
            print(json.dumps(plan, sort_keys=True))
            return 2
        if phase == "config-apply" and any(
            change["kind"] == "userpass-user" for change in plan.get("changes", [])
        ):
            _, current = apply.snapshot(apply.DESIRED, client)
            if current[("userpass-user", "openbao-operator")][0] is None:
                password = getpass.getpass("Retained operator password for missing account: ")
                if not password:
                    raise SafeError("authentication-failed")
                inputs["operator_password"] = password
        with lease(kubeconfig):
            result = operation(supplied)
        print(json.dumps(result, sort_keys=True))
        return 0 if result["status"] in {"pass", "prepared"} else 1
    except Exception:  # noqa: BLE001 -- Never render exceptions from credential-bearing operations.
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
        if client:
            client.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
