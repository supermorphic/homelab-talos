"""Attended reset of the specification 036 database issuer credential."""

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
        self.enabled = []
        self.patches = [
            patch("scripts.openbao.guards.assert_mutation_allowed"),
            patch("scripts.openbao.guards.source_revision", return_value="a" * 40),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in self.patches:
            item.stop()

    def enable(self, kubeconfig, password):
        self.client.events.append(("enable", None))
        self.enabled.append(password)

    def run_reset(self, confirm):
        output = io.StringIO()
        with redirect_stdout(output):
            result = database_issuer.execute(
                self.client,
                Path("/synthetic"),
                token="synthetic-token",
                confirm=lambda: confirm,
                enable=self.enable,
                desired_path=DESIRED,
            )
        return result, output.getvalue()

    def required(self):
        _, output = self.run_reset("wrong")
        return (
            next(line for line in output.splitlines() if "confirmation-required" in line)
            .split('"confirmation": "')[1]
            .split('"')[0]
        )

    def test_missing_connection_is_created_with_a_fresh_password_then_rotated(self):
        del self.client.state[CONNECTION]
        required = self.required()
        self.assertTrue(required.startswith("issuer-reset:automation-data:"))
        self.assertEqual(self.enabled, [])
        result, output = self.run_reset(required)
        self.assertEqual(result, {"status": "pass", "connection": "created", "issuer": "rotated"})
        self.assertEqual(
            self.client.events,
            [
                ("enable", None),
                ("post", "automation-data/config/automation-data"),
                ("post", ROTATE),
            ],
        )
        [password] = self.enabled
        self.assertGreaterEqual(len(password), 32)
        self.assertEqual(self.client.password_received, password)
        self.assertNotIn(password, output + str(result))

    def test_existing_connection_gets_a_new_password_each_run(self):
        first = self.required()
        self.run_reset(first)
        self.client.events.clear()
        result, _ = self.run_reset(self.required())
        self.assertEqual(result["connection"], "replaced")
        self.assertEqual(len(set(self.enabled)), 2)

    def test_wrong_confirmation_changes_nothing(self):
        result, _ = self.run_reset("issuer-reset:automation-data:other")
        self.assertEqual(result["status"], "confirmation-required")
        self.assertEqual(self.enabled, [])
        self.assertEqual(self.client.writes, [])

    def test_other_configuration_drift_refuses_before_any_change(self):
        self.client.state[("database-role", "career-ops-read")]["max_ttl"] = 3600
        with self.assertRaisesRegex(SafeError, "source-mismatch"):
            self.run_reset("anything")
        self.assertEqual(self.enabled, [])
        self.assertEqual(self.client.writes, [])

    def test_rotation_failure_reports_unknown_issuer_state(self):
        required = self.required()
        self.client.fail_rotation = True
        result, output = self.run_reset(required)
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["issuer_state"], "unknown")
        self.assertNotIn(self.enabled[-1], output + str(result))

    def test_failed_enable_never_writes_the_connection(self):
        required = self.required()

        def failing(kubeconfig, password):
            raise SafeError("source-mismatch")

        with redirect_stdout(io.StringIO()), self.assertRaisesRegex(SafeError, "source-mismatch"):
            database_issuer.execute(
                self.client,
                Path("/synthetic"),
                token="synthetic-token",
                confirm=lambda: required,
                enable=failing,
                desired_path=DESIRED,
            )
        self.assertEqual(self.client.writes, [])


if __name__ == "__main__":
    unittest.main()
