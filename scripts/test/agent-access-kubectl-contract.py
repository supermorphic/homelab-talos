"""Check named authorization requests with the pinned kubectl client."""

from __future__ import annotations

import base64
import json
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar
from urllib.parse import urlsplit


class KubernetesStub(BaseHTTPRequestHandler):
    requests: ClassVar[list[bytes]] = []
    forwards: ClassVar[list[str]] = []
    credential_profiles: ClassVar[list[str]] = []

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def respond(self, body: dict[str, object]) -> None:
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/version":
            header = self.headers.get("Authorization", "")
            assert header.startswith("Bearer synthetic."), "exec token missing"
            part = header.split(".")[1]
            claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
            self.credential_profiles.append(claims["sub"].split(":")[-1])
            self.respond({"gitVersion": "v1.35.6"})
        elif path == "/api":
            self.respond(
                {"kind": "APIVersions", "versions": ["v1"], "serverAddressByClientCIDRs": []}
            )
        elif path == "/api/v1":
            self.respond(
                {
                    "kind": "APIResourceList",
                    "groupVersion": "v1",
                    "resources": [
                        {
                            "name": "pods",
                            "singularName": "pod",
                            "namespaced": True,
                            "kind": "Pod",
                            "verbs": ["get", "list"],
                        },
                        {
                            "name": "pods/portforward",
                            "singularName": "",
                            "namespaced": True,
                            "kind": "PodPortForwardOptions",
                            "verbs": ["create"],
                        },
                    ],
                }
            )
        elif path == "/apis":
            self.respond(
                {
                    "kind": "APIGroupList",
                    "groups": [
                        {
                            "name": "apps",
                            "versions": [{"groupVersion": "apps/v1", "version": "v1"}],
                            "preferredVersion": {"groupVersion": "apps/v1", "version": "v1"},
                        }
                    ],
                }
            )
        elif path == "/apis/apps/v1":
            self.respond(
                {
                    "kind": "APIResourceList",
                    "groupVersion": "apps/v1",
                    "resources": [
                        {
                            "name": "deployments",
                            "singularName": "",
                            "namespaced": True,
                            "kind": "Deployment",
                            "verbs": ["get", "list", "watch"],
                        }
                    ],
                }
            )
        elif path == "/api/v1/namespaces/automation-data/pods/automation-data-postgresql-0":
            self.respond(
                {
                    "apiVersion": "v1",
                    "kind": "Pod",
                    "metadata": {
                        "name": "automation-data-postgresql-0",
                        "namespace": "automation-data",
                    },
                    "status": {"phase": "Running"},
                    "spec": {
                        "containers": [{"name": "postgresql", "ports": [{"containerPort": 5432}]}]
                    },
                }
            )
        elif path.endswith("/pods/automation-data-postgresql-0/portforward"):
            self.forwards.append("GET " + path)
            self.send_error(403, "synthetic named GET denial")
        else:
            raise AssertionError(f"unexpected discovery request: {self.path}")

    def do_POST(self) -> None:
        if urlsplit(self.path).path.endswith("/pods/automation-data-postgresql-0/portforward"):
            self.forwards.append("POST " + urlsplit(self.path).path)
            self.send_error(400, "synthetic port-forward stop")
            return
        assert self.path == "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews", self.path
        if self.headers.get("Transfer-Encoding") == "chunked":
            chunks = []
            while size := int(self.rfile.readline().strip(), 16):
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
            self.rfile.readline()
            payload = b"".join(chunks)
        else:
            payload = self.rfile.read(int(self.headers["Content-Length"]))
        self.requests.append(payload)
        self.respond(
            {
                "apiVersion": "authorization.k8s.io/v1",
                "kind": "SelfSubjectAccessReview",
                "status": {"allowed": True},
            }
        )


def _exec_contract(server: ThreadingHTTPServer, directory: Path) -> None:
    """Pinned kubectl consumes the real issuer's v1 pipe, using synthetic auth."""
    root = Path(__file__).resolve().parents[2]
    plugin = directory / "synthetic-exec.py"
    plugin.write_text(
        "import base64, json, os, sys, time\n"
        f"sys.path.insert(0, {str(root)!r})\n"
        "from scripts.openbao import credentials, guards, issuance, workstation\n"
        "now = int(time.time())\n"
        "profile = sys.argv[1]\n"
        "info = json.loads(os.environ['KUBERNETES_EXEC_INFO'])\n"
        "assert info['apiVersion'] == credentials.API_VERSION and info['spec']['interactive'] is False\n"
        "class Broker:\n"
        " def post(self, path, payload, token=None):\n"
        "  if path == workstation.LOGIN_PATH:\n"
        "   return {'auth': {'client_token': 'synthetic-session', 'entity_id': 'synthetic-entity', "
        "'policies': ['agent-profiles'], 'token_policies': ['agent-profiles'], "
        "'lease_duration': 60, 'token_type': 'service'}}\n"
        "  if path == 'auth/token/revoke-self': return {}\n"
        "  account = credentials.PROFILES[profile]\n"
        "  claims = {'sub': 'system:serviceaccount:kube-system:' + account, "
        "'aud': [issuance.AUDIENCE], 'iat': now, 'exp': now + 600}\n"
        "  part = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=')\n"
        "  return {'data': {'service_account_name': account, 'service_account_namespace': 'kube-system', "
        "'service_account_token': 'synthetic.' + part + '.synthetic'}}\n"
        "state = {'role_id': 'synthetic-role', 'secret_id': 'synthetic-secret', 'entity_id': 'synthetic-entity', "
        "'expires_at': now + 7776000, 'cluster': {'schema_version': 1, 'server': issuance.AUDIENCE, "
        "'certificate_authority_data': base64.b64encode(b'-----BEGIN CERTIFICATE-----').decode(), "
        "'openbao_server': workstation.ENDPOINT, 'profiles': list(credentials.PROFILES)}}\n"
        "print(json.dumps(credentials.issue_exec_credential(profile, state, client=Broker(), now=now)))\n"
    )
    profiles = ("observer", "diagnostic", "publisher", "campaign-coordinator")
    configs = []
    for profile in profiles:
        config = directory / (profile + ".json")
        config.write_text(
            json.dumps(
                {
                    "apiVersion": "v1",
                    "kind": "Config",
                    "current-context": "stub",
                    "clusters": [
                        {
                            "name": "stub",
                            "cluster": {
                                "server": f"https://127.0.0.1:{server.server_port}",
                                "certificate-authority-data": base64.b64encode(
                                    (directory / "tls.crt").read_bytes()
                                ).decode(),
                            },
                        }
                    ],
                    "contexts": [{"name": "stub", "context": {"cluster": "stub", "user": "stub"}}],
                    "users": [
                        {
                            "name": "stub",
                            "user": {
                                "exec": {
                                    "apiVersion": "client.authentication.k8s.io/v1",
                                    "command": sys.executable,
                                    "args": [str(plugin), profile],
                                    "interactiveMode": "Never",
                                }
                            },
                        }
                    ],
                }
            )
        )
        configs.append(config)

    def invoke(config: Path) -> None:
        result = subprocess.run(
            ["kubectl", "--kubeconfig", str(config), "get", "--raw=/version"],
            cwd=directory,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == {"gitVersion": "v1.35.6"}

    for config in configs:
        invoke(config)
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(invoke, configs))
    assert sorted(KubernetesStub.credential_profiles) == sorted(
        [
            "homelab-observer",
            "homelab-diagnostic",
            "homelab-report-publisher",
            "homelab-campaign-coordinator",
        ]
        * 2
    )


def exec_contract(directory: Path) -> None:
    # client-go intentionally ignores exec auth on plaintext HTTP. A temporary
    # trusted loopback certificate is required to exercise actual consumption.
    config = directory / "tls.cnf"
    config.write_text(
        "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n"
        "[dn]\nCN=127.0.0.1\n[ext]\nsubjectAltName=IP:127.0.0.1\n"
    )
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-config",
            str(config),
            "-keyout",
            str(directory / "tls.key"),
            "-out",
            str(directory / "tls.crt"),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(directory / "tls.crt", directory / "tls.key")
    with ThreadingHTTPServer(("127.0.0.1", 0), KubernetesStub) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            _exec_contract(server, directory)
        finally:
            server.shutdown()
            thread.join()


def main() -> None:
    with ThreadingHTTPServer(("127.0.0.1", 0), KubernetesStub) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="agent-access-kubectl-") as directory:
                exec_contract(Path(directory))
                config = Path(directory) / "config"
                config.write_text(
                    "apiVersion: v1\nkind: Config\nclusters:\n"
                    f"- name: stub\n  cluster:\n    server: http://127.0.0.1:{server.server_port}\n"
                    "contexts:\n- name: stub\n  context:\n    cluster: stub\n    user: stub\n"
                    "current-context: stub\nusers:\n- name: stub\n  user: {}\n",
                    encoding="utf-8",
                )
                result = subprocess.run(
                    [
                        "kubectl",
                        "--kubeconfig",
                        str(config),
                        "auth",
                        "can-i",
                        "get",
                        "deployments.apps/test-reports",
                        "--namespace",
                        "contract-space",
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                assert result.returncode == 0, result.stderr
                assert result.stdout.strip() == "yes", result.stdout
                assert len(KubernetesStub.requests) == 1, KubernetesStub.requests
                # kubectl uses protobuf for this request; distinct values prove that
                # TYPE/NAME was sent as a named authorization review.
                request = KubernetesStub.requests[0]
                for value in (b"contract-space", b"get", b"apps", b"deployments", b"test-reports"):
                    assert value in request, (value, request)
                named_forward = subprocess.run(
                    [
                        "kubectl",
                        "--kubeconfig",
                        str(config),
                        "auth",
                        "can-i",
                        "create",
                        "pods/automation-data-postgresql-0",
                        "--subresource",
                        "portforward",
                        "--namespace",
                        "automation-data",
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                assert named_forward.returncode == 0, named_forward.stderr
                assert named_forward.stdout.strip() == "yes", named_forward.stdout
                assert len(KubernetesStub.requests) == 2, KubernetesStub.requests
                forward_review = KubernetesStub.requests[1]
                for value in (
                    b"automation-data",
                    b"create",
                    b"pods",
                    b"portforward",
                    b"automation-data-postgresql-0",
                ):
                    assert value in forward_review, (value, forward_review)
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", 0))
                    port = listener.getsockname()[1]
                try:
                    forward_result = subprocess.run(
                        [
                            "kubectl",
                            "--kubeconfig",
                            str(config),
                            "--context",
                            "stub",
                            "--namespace",
                            "automation-data",
                            "port-forward",
                            "--address",
                            "127.0.0.1",
                            "pod/automation-data-postgresql-0",
                            f"{port}:5432",
                        ],
                        text=True,
                        capture_output=True,
                        check=False,
                        timeout=4,
                    )
                except subprocess.TimeoutExpired as exc:
                    forward_result = exc
                assert KubernetesStub.forwards, (
                    "kubectl never requested the named Pod port-forward",
                    forward_result,
                )
                assert all(
                    path.endswith(
                        "/namespaces/automation-data/pods/automation-data-postgresql-0/portforward"
                    )
                    for path in KubernetesStub.forwards
                ), KubernetesStub.forwards
                assert KubernetesStub.forwards[-1].startswith("POST "), KubernetesStub.forwards
                unsupported = subprocess.run(
                    [
                        "kubectl",
                        "--kubeconfig",
                        str(config),
                        "auth",
                        "can-i",
                        "get",
                        "deployments.apps",
                        "--resource-name",
                        "test-reports",
                        "--namespace",
                        "contract-space",
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                assert unsupported.returncode != 0, unsupported
                assert "unknown flag: --resource-name" in unsupported.stderr, unsupported.stderr
                assert len(KubernetesStub.requests) == 2, KubernetesStub.requests
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
