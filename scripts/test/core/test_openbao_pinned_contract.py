"""Optional loopback-only contract test with the separately verified 2.7.0 binary.

CI always exercises the literal fixtures. Set OPENBAO_CONTRACT_BINARY to rerun
the upstream behavior check; this creates only an in-memory local dev server.
"""

import json
import os
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from scripts.openbao import apply, restore
from scripts.openbao.configuration import load_document
from scripts.test.scenarios.openbao_restore import ScratchClient

FIXTURES = Path(__file__).parent / "fixtures"


@unittest.skipUnless(os.environ.get("OPENBAO_CONTRACT_BINARY"), "local pinned binary not selected")
class PinnedServerContract(unittest.TestCase):
    def test_readback_and_isolated_jwt_storage_with_nonroot_operator(self):
        binary = str(Path(os.environ["OPENBAO_CONTRACT_BINARY"]).resolve())
        version = subprocess.check_output([binary, "version"], timeout=10).decode()
        self.assertTrue(version.startswith("OpenBao v2.7.0 ("))
        with tempfile.TemporaryDirectory(prefix="openbao-contract-") as directory:
            config = Path(directory) / "server.hcl"
            config.write_text("raw_storage_endpoint = true\n")
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            process = subprocess.Popen(
                [binary, "server", "-dev", "-dev-no-store-token",
                 "-dev-root-token-id=synthetic-local-root",
                 f"-dev-listen-address=127.0.0.1:{port}", "-config=" + str(config)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            self.addCleanup(self.stop, process)

            def request(method, path, payload=None, token="synthetic-local-root"):
                req = urllib.request.Request(
                    f"http://127.0.0.1:{port}/v1/{path}", method=method,
                    data=json.dumps(payload).encode() if payload is not None else None,
                    headers={"Content-Type": "application/json", "X-Vault-Token": token},
                )
                try:
                    with urllib.request.urlopen(req, timeout=5) as response:
                        return response.status, json.loads(response.read() or "{}")
                except urllib.error.HTTPError as error:
                    return error.code, json.loads(error.read())

            for _ in range(100):
                try:
                    if request("GET", "sys/health")[0] == 200:
                        break
                except OSError:
                    time.sleep(0.1)
            self.assertEqual(request("DELETE", "sys/mounts/secret")[0], 204)

            def post(path, payload, token=None):
                self.assertIn(request("POST", path, payload, token)[0], (200, 204))

            writer = type("Writer", (), {"post": staticmethod(post)})()
            stored = json.loads((FIXTURES / "openbao-2.7-jwt-stored-config.json").read_text())
            for spec in load_document(apply.DESIRED)["objects"]:
                if spec.kind == "jwt-config":
                    uid = request("GET", "sys/auth")[1]["data"]["homelab-jwt/"]["uuid"]
                    raw_path = f"sys/raw/auth/{uid}/config"
                    self.assertEqual(request("POST", raw_path, stored["data"])[0], 204)
                else:
                    apply._write(spec, None, writer, "synthetic-local-root",
                                 "synthetic-contract-password")
            status, login = request("POST", "auth/homelab-userpass/login/openbao-operator",
                                    {"password": "synthetic-contract-password"})
            self.assertEqual(status, 200)
            self.assertEqual(login["auth"]["policies"], ["openbao-operator"])
            operator = login["auth"]["client_token"]
            self.assertEqual(request("POST", "auth/token/revoke-self", {})[0], 204)
            self.assertEqual(request("GET", raw_path)[0], 403)
            raw_status, raw_body = request("GET", raw_path, token=operator)
            self.assertEqual(raw_status, 200)
            self.assertEqual(raw_body["data"], stored["data"])
            expected_error = json.loads(
                (FIXTURES / "openbao-2.7-jwt-provider-unavailable.json").read_text())
            self.assertEqual(request("GET", "auth/homelab-jwt/config", token=operator),
                             (500, expected_error))

            def http(method, path, **kwargs):
                status, body = request(method, path, token=operator)
                if status == 500 and body == {"errors": [restore.PROVIDER_UNAVAILABLE]}:
                    body = {"provider_unavailable": True}
                return status, body

            kube = type("Kube", (), {"http": staticmethod(http)})()
            client = ScratchClient(kube, "synthetic-contract-password")
            self.assertEqual(apply.verify_configuration(apply.DESIRED, client), {"differences": []})

    @staticmethod
    def stop(process):
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
