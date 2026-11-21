"""Attended reset of the specification 036 database issuer credential."""

import base64
import hashlib
import hmac
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from test_openbao_apply import DESIRED, StateClient

from scripts.openbao import database_issuer
from scripts.openbao.configuration import SafeError

CONNECTION = ("database-connection", "automation-data")
ROTATE = "automation-data/rotate-root/automation-data"


def verifies(verifier, password):
    """RFC 7677 check, independent of the module: does the verifier accept the password?"""
    method, rest = verifier.split("$", 1)
    iterations_salt, keys = rest.split("$")
    iterations, salt = iterations_salt.split(":")
    stored_key, server_key = keys.split(":")
    salted = hashlib.pbkdf2_hmac(
        "sha256", password.encode(), base64.b64decode(salt), int(iterations)
    )
    client_key = hmac.new(salted, b"Client Key", "sha256").digest()
    return (
        method == "SCRAM-SHA-256"
        and int(iterations) >= 4096
        and len(base64.b64decode(salt)) >= 16
        and base64.b64decode(stored_key) == hashlib.sha256(client_key).digest()
        and base64.b64decode(server_key) == hmac.new(salted, b"Server Key", "sha256").digest()
    )


class IssuerClient(StateClient):
    def __init__(self):
        super().__init__()
        self.events = []
        self.fail_rotation = False

    def post(self, path, payload, token=None):
        self.events.append(("post", path))
        if path == ROTATE:
            self.writes.append(path)
            if self.fail_rotation:
                raise SafeError("ambiguous-write")
            return {}
        return super().post(path, payload, token)


class DatabaseIssuerTest(unittest.TestCase):
    def setUp(self):
        self.client = IssuerClient()
        self.verifiers = []
        self.patches = [
            patch("scripts.openbao.guards.assert_mutation_allowed"),
            patch("scripts.openbao.guards.source_revision", return_value="a" * 40),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in self.patches:
            item.stop()

    def enable(self, kubeconfig, verifier):
        self.client.events.append(("enable", None))
        self.verifiers.append(verifier)

    def run_reset(self, confirm=lambda required: required, enable=None):
        output = io.StringIO()
        with redirect_stdout(output):
            result = database_issuer.execute(
                self.client,
                Path("/synthetic"),
                token="synthetic-token",
                confirm=confirm,
                enable=enable or self.enable,
                desired_path=DESIRED,
            )
        return result, output.getvalue()

    def test_missing_connection_gets_a_verifier_in_postgresql_and_the_password_in_openbao(self):
        del self.client.state[CONNECTION]
        shown = []
        result, output = self.run_reset(lambda required: shown.append(required) or required)
        self.assertTrue(shown[0].startswith("issuer-reset:automation-data:"))
        self.assertEqual(result, {"status": "pass", "connection": "created", "issuer": "rotated"})
        self.assertEqual(
            self.client.events,
            [
                ("enable", None),
                ("post", "automation-data/config/automation-data"),
                ("post", ROTATE),
            ],
        )
        [verifier] = self.verifiers
        password = self.client.password_received
        self.assertGreaterEqual(len(password), 32)
        self.assertNotIn(password, verifier)
        self.assertTrue(verifies(verifier, password))
        self.assertNotIn(password, output + str(result))

    def test_every_run_needs_its_own_confirmation_and_password(self):
        shown = []
        self.run_reset(lambda required: shown.append(required) or required)
        result, _ = self.run_reset(lambda required: shown[0])
        self.assertEqual(result["status"], "confirmation-required")
        result, _ = self.run_reset()
        self.assertEqual(result["connection"], "replaced")
        self.assertEqual(len(set(self.verifiers)), 2)

    def test_wrong_confirmation_changes_nothing(self):
        result, _ = self.run_reset(lambda required: "issuer-reset:automation-data:other")
        self.assertEqual(result["status"], "confirmation-required")
        self.assertEqual(self.verifiers, [])
        self.assertEqual(self.client.writes, [])

    def test_connection_drift_is_repaired_by_the_reset(self):
        self.client.state[CONNECTION]["allowed_roles"] = ["other"]
        result, _ = self.run_reset()
        self.assertEqual(result["status"], "pass")
        self.assertEqual(self.client.state[CONNECTION]["allowed_roles"], ["career-ops-read"])

    def test_other_configuration_drift_refuses_before_any_change(self):
        self.client.state[("database-role", "career-ops-read")]["max_ttl"] = 3600
        with self.assertRaisesRegex(SafeError, "source-mismatch"):
            self.run_reset()
        self.assertEqual(self.verifiers, [])
        self.assertEqual(self.client.writes, [])

    def test_rotation_failure_reports_unknown_issuer_state(self):
        self.client.fail_rotation = True
        result, output = self.run_reset()
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["issuer_state"], "unknown")
        self.assertNotIn(self.client.password_received, output + str(result))

    def test_failed_enable_reports_unknown_state_and_cleanup_without_writing(self):
        for cleanup in ("passed", "failed"):
            with self.subTest(cleanup=cleanup):

                def failing(kubeconfig, verifier, cleanup=cleanup):
                    raise database_issuer.EnableFailed(cleanup)

                result, _ = self.run_reset(enable=failing)
                self.assertEqual(
                    result, {"status": "fail", "issuer_state": "unknown", "cleanup": cleanup}
                )
                self.assertEqual(self.client.writes, [])

    def test_lost_mutation_lease_after_the_password_change_is_unknown_state(self):
        with patch(
            "scripts.openbao.guards.assert_mutation_allowed",
            side_effect=[None, SafeError("source-mismatch")],
        ):
            result, _ = self.run_reset()
        self.assertEqual(result["issuer_state"], "unknown")
        self.assertEqual(self.client.writes, [])


class EnableLoginTest(unittest.TestCase):
    def test_helper_receives_only_the_verifier_and_reports_cleanup(self):
        script = (
            "import sys; data = sys.stdin.read(); "
            "print('openbao_issuer_login=enabled run=r' if data.startswith('SCRAM-SHA-256$') "
            "else 'bad'); print('openbao_issuer_cleanup=passed run=r')"
        )
        with patch.object(database_issuer, "HELPER", ["python3", "-c", script]):
            database_issuer.enable_login(Path("/synthetic"), "SCRAM-SHA-256$4096:x$y:z")
        failing = (
            "import sys; sys.stdin.read(); "
            "print('openbao_issuer_cleanup=failed run=r'); sys.exit(1)"
        )
        with (
            patch.object(database_issuer, "HELPER", ["python3", "-c", failing]),
            self.assertRaises(database_issuer.EnableFailed) as raised,
        ):
            database_issuer.enable_login(Path("/synthetic"), "SCRAM-SHA-256$4096:x$y:z")
        self.assertEqual(raised.exception.cleanup, "failed")


if __name__ == "__main__":
    unittest.main()
