"""Optional loopback-only contract test with the separately verified 2.7.0 binary.

CI always exercises the literal fixtures. Set OPENBAO_CONTRACT_BINARY to rerun
the upstream behavior check; this creates only an in-memory local dev server.
"""

import json
import os
import re
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.openbao import apply, restore, workstation
from scripts.openbao.client import AmbiguousWrite, NotFound
from scripts.openbao.configuration import SafeError, load_document
from scripts.test.scenarios.openbao_restore import ScratchClient
from scripts.test.scenarios.agent_credentials import BrokerScope

FIXTURES = Path(__file__).parent / "fixtures"


@unittest.skipUnless(os.environ.get("OPENBAO_CONTRACT_BINARY"), "local pinned binary not selected")
class PinnedServerContract(unittest.TestCase):
    def test_readback_and_isolated_jwt_storage_with_nonroot_operator(self):
        binary = str(Path(os.environ["OPENBAO_CONTRACT_BINARY"]).resolve())
        version = subprocess.check_output([binary, "version"], timeout=10).decode()
        self.assertTrue(version.startswith("OpenBao v2.7.0 ("))
        with tempfile.TemporaryDirectory(prefix="openbao-contract-") as directory:
            config = Path(directory) / "server.hcl"
            values = yaml.safe_load((apply.DESIRED.parents[1] / "app/values.yaml").read_text())
            audit = re.search(r'(?ms)^audit "file" "homelab" \{\n.*?^\}',
                              values["server"]["ha"]["raft"]["config"])
            self.assertIsNotNone(audit)
            config.write_text("raw_storage_endpoint = true\n" + audit.group(0) + "\n")
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
            # The actual server must load the production audit stanza. API creation
            # stays disabled; a fake API readback cannot establish this contract.
            status, audit_response = request("GET", "sys/audit")
            self.assertEqual(status, 200)
            self.assertEqual(set(audit_response["data"]), {"homelab/"})
            self.assertEqual(audit_response["data"]["homelab/"]["options"],
                             {"file_path": "stdout", "log_raw": "false", "hmac_accessor": "true"})
            self.assertEqual(request("POST", "sys/audit/forbidden", apply.AUDIT)[0], 400)

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
            status, session = request("POST", "auth/token/create",
                                      {"policies": ["openbao-config-reader"], "no_default_policy": True,
                                       "ttl": "5m"}, token=operator)
            self.assertEqual(status, 200)
            reader_token = session["auth"]["client_token"]
            self.assertEqual(request("GET", "sys/policies/acl/openbao-backup", token=reader_token)[0], 200)
            self.assertEqual(request("LIST", "sys/policies/acl", token=reader_token)[0], 200)
            for method, path, body in [
                ("POST", "kubernetes/creds/openbao-acceptance", {}),
                ("POST", "auth/homelab-jwt/config", {}),
                ("POST", "sys/policies/acl/openbao-backup", {"policy": ""}),
                ("GET", raw_path, None),
            ]:
                self.assertEqual(request(method, path, body, token=reader_token)[0], 403)
            self.assertEqual(request("POST", "auth/token/revoke-self", {}, token=reader_token)[0], 204)
            class LocalClient:
                token = "synthetic-local-root"

                def read(self, path, *, token=None, list_request=False):
                    status, body = request(
                        "LIST" if list_request else "GET", path, token=token or self.token
                    )
                    if status == 404:
                        raise NotFound()
                    if status != 200:
                        raise SafeError("read-denied")
                    return body

                def delete(self, path, *, token=None):
                    status, body = request("DELETE", path, token=token or self.token)
                    if status not in (200, 204):
                        raise AmbiguousWrite(http_status=status)
                    return body

                def post(self, path, payload, *, token=None):
                    status, body = request("POST", path, payload, token=token or self.token)
                    if status not in (200, 204):
                        raise AmbiguousWrite(http_status=status)
                    return body

            local_client = LocalClient()
            private = Path(directory).resolve() / "workstation"
            metadata = {
                "schema_version": 1,
                "server": "https://cluster.example.test:6443",
                "certificate_authority_data": "synthetic-ca",
                "openbao_server": workstation.ENDPOINT,
                "profiles": workstation.PROFILES,
            }
            with (
                patch(
                    "scripts.openbao.workstation.target",
                    return_value={"source_revision": "a" * 40, "cluster_uid": "synthetic-cluster"},
                ),
                patch(
                    "scripts.openbao.apply.verify_configuration", return_value={"differences": []}
                ),
                patch("scripts.openbao.guards.assert_mutation_allowed"),
                patch("scripts.openbao.workstation.cluster_metadata", return_value=metadata),
            ):
                args = dict(
                    directory=private, client=local_client, kubeconfig=Path("/synthetic/operator")
                )
                for action in ("enroll", "rotate"):
                    plan = workstation.run(action, workstation.ROLE, confirm="", **args)
                    result = workstation.run(
                        action, workstation.ROLE, confirm=plan["confirmation"], **args
                    )
                    self.assertEqual(result, {"status": "pass", "action": action})

            # The temporary acceptance lifecycle also matches pinned APIs, with
            # no real caller/network use. Only the cleanup wait uses a test clock.
            class CleanupClock:
                value = 1000
                def monotonic(self):
                    return self.value
                def sleep(self, seconds):
                    self.value += seconds

            acceptance_private = Path(directory).resolve() / "acceptance"
            workstation.ensure_private_directory(acceptance_private)
            approved = {"source_revision": "a" * 40, "cluster_uid": "synthetic-cluster"}
            scope = BrokerScope(Path("/synthetic/operator"), "synthetic-acceptance", acceptance_private,
                                local_client, approved, clock=CleanupClock())
            with (patch("scripts.openbao.guards.assert_mutation_allowed"),
                  patch("scripts.openbao.workstation.target", return_value=approved),
                  patch("scripts.test.scenarios.agent_credentials.credentials.issue_exec_credential", return_value={} )):
                for suffix in ("a", "b"):
                    scope.create(scope.actor(suffix), metadata)
                scope.cleanup()
                self.assertGreaterEqual(scope.clock.value, 1090)

            # Local AppRole contract: bound alias, exact session lifetime and
            # disabling the entity invalidates authority of an issued session.
            role_path = "auth/homelab-approle/role/agent-workstation"
            role_id = request("GET", role_path + "/role-id")[1]["data"]["role_id"]
            secret = request("POST", role_path + "/secret-id", {})[1]["data"]
            self.assertEqual(secret["secret_id_ttl"], 7776000)
            self.assertEqual(secret["secret_id_num_uses"], 0)
            auth = request("POST", "auth/homelab-approle/login", {
                "role_id": role_id, "secret_id": secret["secret_id"]})[1]["auth"]
            self.assertEqual(auth["lease_duration"], 60)
            self.assertEqual(auth["policies"], ["agent-profiles"])
            self.assertEqual(auth.get("identity_policies", []), [])
            entity_id = auth["entity_id"]
            entity = request("GET", "identity/entity/id/" + entity_id)[1]["data"]
            self.assertEqual(entity["aliases"][0]["name"], role_id)
            self.assertEqual(entity["aliases"][0]["mount_path"], "auth/homelab-approle/")
            # Never reach the real cluster from a loopback server contract.
            self.assertEqual(request("POST", "kubernetes/config", {
                "kubernetes_host": "http://127.0.0.1:1",
                "service_account_jwt": "synthetic-local-issuer"})[0], 204)
            for profile in ("observer", "diagnostic", "publisher", "campaign-coordinator"):
                self.assertEqual(request("POST", "kubernetes/creds/" + profile,
                    {}, token=auth["client_token"])[0], 500)
            self.assertEqual(request("POST", "identity/entity/id/" + entity_id,
                                    {"disabled": True})[0], 204)
            for profile in ("observer", "diagnostic", "publisher", "campaign-coordinator"):
                self.assertEqual(request("POST", "kubernetes/creds/" + profile,
                    {}, token=auth["client_token"])[0], 403)
            # Applying source configuration touches roles, never entities.
            for spec in load_document(apply.DESIRED)["objects"]:
                if spec.kind == "approle-role":
                    apply._write(spec, request("GET", spec.path)[1]["data"], writer, "synthetic-local-root", "unused")
            self.assertTrue(request("GET", "identity/entity/id/" + entity_id)[1]["data"]["disabled"])
            # Restore the configuration readback for the original drift assertion.
            engine = next(o for o in load_document(apply.DESIRED)["objects"]
                          if o.kind == "kubernetes-config")
            apply._write(engine, None, writer, "synthetic-local-root", "unused")
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
