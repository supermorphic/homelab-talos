#!/usr/bin/env python3
"""Private application credential command regressions."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "operations"))
import automation_data_access as access
import automation_data_client as client
from automation_data_inventory import validate_observation

COMMAND_PATH = Path(__file__).resolve().parents[1] / "operations" / "automation-data-login.py"
SPEC = importlib.util.spec_from_file_location("automation_data_login", COMMAND_PATH)
assert SPEC and SPEC.loader
command = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(command)
REAL_SEND_REQUEST = command.send_request


ROLE = (
    "app_" + hashlib.md5(b"sample:interview", usedforsecurity=False).hexdigest() + "_integration"
)
SENTINEL = "synthetic-secret-never-print-1234567890"


class LoginCommandTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="automation-data-login-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.directory.chmod(0o700)
        self.environment = mock.patch.dict(os.environ, {
            "AUTOMATION_DATA_LOGIN_DIRECTORY": str(self.directory),
            "AUTOMATION_DATA_PROVISIONING_TOKEN": "s" * 40,
            "AUTOMATION_DATA_LOGIN_ACTIVATE_CONFIRM": "activate:automation-data:sample:interview",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.requests = []
        self.fail_install = False
        guard = mock.patch.object(command, "require_deployed_login_sources")
        guard.start()
        self.addCleanup(guard.stop)

        def request(payload):
            self.requests.append(payload.copy())
            if payload["operation"] == "login-validate":
                return self.response(state="awaiting_grants", generation=0, valid=True)
            if payload["operation"] == "login-activate":
                pending = self.directory / "sample" / "interview" / "pending"
                self.assertEqual(stat.S_IMODE((pending / "candidate.pgpass").stat().st_mode), 0o600)
                record = json.loads((pending / "operation.json").read_text())
                self.assertEqual(record["operationId"], payload["operationId"])
                self.assertNotIn(payload["password"], (pending / "operation.json").read_text())
                if self.fail_install:
                    raise command.RequestError("request_failed")
                return self.response(state="activating", generation=1,
                                     operation_id=payload["operationId"])
            if payload["operation"] == "login-complete":
                return self.response(state="ready", generation=1,
                                     operation_id=payload["operationId"])
            raise AssertionError(payload)

        self.request_patch = mock.patch.object(command, "send_request", side_effect=request)
        self.request_patch.start()
        self.addCleanup(self.request_patch.stop)
        tunnel = mock.patch.object(command, "private_database_tunnel", return_value=
                                   contextlib.nullcontext(15432))
        tunnel.start()
        self.addCleanup(tunnel.stop)
        auth = mock.patch.object(command, "authenticate_candidate", return_value=None)
        auth.start()
        self.addCleanup(auth.stop)

    @staticmethod
    def response(state, generation, operation_id=None, valid=None):
        result = {"ok": True, "domain": "sample", "application": "interview",
                  "database": "sample", "schema": "interview_api", "role": ROLE,
                  "state": state, "credentialGeneration": generation,
                  "operationId": operation_id, "expectedGeneration": generation - 1
                  if operation_id else None}
        if valid is not None:
            result["valid"] = valid
        return result

    def run_command(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = command.main(["activate", "sample", "interview"])
        return result, stdout.getvalue(), stderr.getvalue()

    def test_candidate_is_durable_before_request(self):
        result, output, errors = self.run_command()
        self.assertEqual(result, 0, errors)
        self.assertEqual([item["operation"] for item in self.requests],
                         ["login-validate", "login-activate", "login-complete"])
        self.assertNotIn(self.requests[1]["password"], output + errors)
        selected = self.directory / "sample" / "interview"
        self.assertTrue((selected / "service.conf").exists())
        binding = json.loads((selected / "binding.json").read_text())
        self.assertEqual(binding["application"], "interview")
        self.assertEqual(binding["credentialGeneration"], 1)

    def test_ambiguous_failure_retains_candidate(self):
        self.fail_install = True
        result, output, errors = self.run_command()
        self.assertEqual(result, 1)
        pending = self.directory / "sample" / "interview" / "pending"
        self.assertTrue((pending / "candidate.pgpass").is_file())
        self.assertTrue((pending / "operation.json").is_file())
        self.assertNotIn(self.requests[-1]["password"], output + errors)

    def test_retry_uses_same_candidate_and_operation(self):
        self.fail_install = True
        self.run_command()
        first = self.requests[-1]
        self.fail_install = False
        result, _, errors = self.run_command()
        self.assertEqual(result, 0, errors)
        retry = next(item for item in self.requests[2:] if item["operation"] == "login-activate")
        self.assertEqual(retry["operationId"], first["operationId"])
        self.assertEqual(retry["password"], first["password"])

    def test_missing_candidate_requires_explicit_rotation(self):
        self.fail_install = True
        self.run_command()
        pending = self.directory / "sample" / "interview" / "pending"
        (pending / "candidate.pgpass").unlink()
        result, _, _ = self.run_command()
        self.assertEqual(result, 1)
        os.environ["AUTOMATION_DATA_LOGIN_ROTATE_CONFIRM"] = \
            "rotate:automation-data:sample:interview"

        def request(payload):
            if payload["operation"] == "login-validate":
                return self.response(state="activating", generation=1, valid=True)
            if payload["operation"] == "login-rotate":
                return self.response(state="rotating", generation=2,
                                     operation_id=payload["operationId"])
            if payload["operation"] == "login-complete":
                return self.response(state="ready", generation=2,
                                     operation_id=payload["operationId"])
            raise AssertionError(payload)

        with mock.patch.object(command, "send_request", side_effect=request), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(command.main(["rotate", "sample", "interview"]), 0)
        directory = self.directory / "sample" / "interview"
        self.assertTrue((directory / "generation-2" / "credential.pgpass").exists())
        self.assertEqual(len(list(directory.glob("recovery-*"))), 1)

    def test_symlinks_and_unsafe_ownership_are_rejected(self):
        secret = self.directory / "secret"
        secret.write_text(SENTINEL)
        secret.chmod(0o600)
        link = self.directory / "link"
        link.symlink_to(secret)
        with self.assertRaises(client.PrivateFileError):
            client.validate_private_file(link)
        secret.chmod(0o644)
        with self.assertRaises(client.PrivateFileError):
            client.validate_private_file(secret)
        with self.assertRaises(client.PrivateFileError):
            client.write_private_file_exclusive(link, b"other")

    def test_stderr_cannot_leak_response_credentials(self):
        self.fail_install = True
        with mock.patch.object(command, "send_request", side_effect=
                               command.RequestError(SENTINEL)):
            result, output, errors = self.run_command()
        self.assertEqual(result, 1)
        self.assertNotIn(SENTINEL, output + errors)

    def test_slow_inventory_readback_preserves_each_successful_mutation(self):
        graph = json.loads((Path(__file__).resolve().parents[2] /
            "kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json").read_text())
        readback_budget = next(node for node in graph["nodes"]
            if node["name"] == "Observe Mutation Inventory")["parameters"]["options"]["timeout"] / 1000
        for operation in ["login-register", "login-activate", "login-rotate", "login-complete"]:
            calls = []
            def delayed_response(request, timeout, operation=operation, calls=calls):
                calls.append(json.loads(request.data))
                # Simulate committed mutation + delayed optional metadata; no sleeping
                # or private endpoint. A socket budget below this point loses the result.
                if timeout <= 25:
                    raise urllib.error.URLError("synthetic slow inventory readback")
                self.assertGreaterEqual(timeout, 20 + readback_budget)
                return io.BytesIO(json.dumps({"ok": True, "operation": operation,
                    "inventoryReadback": {"status": "unavailable", "observedAt": None,
                                          "errorCode": "source_unavailable"}}).encode())
            with mock.patch.object(command.WEBHOOK_OPENER, "open", side_effect=delayed_response):
                result = REAL_SEND_REQUEST({"domain": "sample", "operation": operation,
                                           "application": "interview"})
            self.assertTrue(result["ok"])
            self.assertEqual(result["inventoryReadback"]["status"], "unavailable")
            self.assertEqual(len(calls), 1)

    def test_webhook_target_and_http_error_are_bounded(self):
        def reject(request, timeout):
            self.assertEqual(request.full_url, command.WEBHOOK)
            self.assertEqual(timeout, 20)
            self.assertEqual(dict(request.header_items())["X-automation-data-provisioning"],
                             "s" * 40)
            raise urllib.error.HTTPError(command.WEBHOOK, 500, SENTINEL, {}, io.BytesIO(
                SENTINEL.encode()))

        with mock.patch.object(command.WEBHOOK_OPENER, "open", side_effect=reject), \
                self.assertRaises(command.RequestError) as raised:
            REAL_SEND_REQUEST({"domain": "sample", "operation": "login-validate",
                               "application": "interview"})
        self.assertNotIn(SENTINEL, str(raised.exception))

    def test_redirect_never_sends_a_second_authenticated_request(self):
        requests = []

        class Redirect(BaseHTTPRequestHandler):
            def do_POST(self):
                requests.append(self.path)
                self.rfile.read(int(self.headers.get("Content-Length", "0")))
                self.send_response(302)
                self.send_header("Location", "/other")
                self.end_headers()

            def do_GET(self):
                requests.append(self.path)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"ok":true}')

            def log_message(self, *_args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Redirect)
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}/start"
        with mock.patch.object(command, "WEBHOOK", url), \
                mock.patch.dict(os.environ, {"AUTOMATION_DATA_PROVISIONING_URL": url}), \
                self.assertRaises(command.RequestError):
            REAL_SEND_REQUEST({"domain": "sample", "operation": "login-validate"})
        self.assertEqual(requests, ["/start"])

    def test_inherited_pg_variables_cannot_redirect(self):
        fake_connection = mock.MagicMock()
        cursor = fake_connection.__enter__.return_value.cursor.return_value.__enter__.return_value
        cursor.fetchone.return_value = ("sample", ROLE, ROLE)
        def fixed_connect(**kwargs):
            self.assertNotIn("PGHOSTADDR", os.environ)
            self.assertNotIn("PGPORT", os.environ)
            return fake_connection

        with mock.patch.dict(os.environ, {"PGHOSTADDR": "203.0.113.7", "PGPORT": "9999"}), \
                mock.patch.object(client.psycopg, "connect", side_effect=fixed_connect) as connect:
            client.authenticate_candidate(15432, "sample", ROLE, SENTINEL)
            self.assertEqual(connect.call_args.kwargs["host"], "127.0.0.1")
            self.assertEqual(connect.call_args.kwargs["port"], 15432)
            self.assertNotIn("PGHOSTADDR", connect.call_args.kwargs)
            self.assertIn("PGHOSTADDR", os.environ)
        cursor.fetchone.return_value = ("other", ROLE, ROLE)
        with self.assertRaises(ValueError):
            client.validate_session_identity(fake_connection.__enter__.return_value,
                                             "sample", ROLE)


class MigratorEnrollmentTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.root.chmod(0o700)
        self.directory = self.root / "sample"
        self.directory.mkdir(mode=0o700)
        self.passfile = self.directory / "credential.pgpass"
        self.service = self.directory / "service.conf"
        self.write(
            self.passfile, "127.0.0.1:15432:sample:sample_migrator:SYNTHETIC_RETAINED_SECRET\n"
        )
        self.write(
            self.service,
            f"[retained_migrator]\nhost=127.0.0.1\nport=15432\ndbname=sample\n"
            f"user=sample_migrator\npassfile={self.passfile}\nsslmode=disable\n",
        )
        self.retained = (self.service.read_bytes(), self.passfile.read_bytes())
        fixture_spec = importlib.util.spec_from_file_location(
            "enrollment_fixtures",
            Path(__file__).with_name("automation-data-discovery-command-test.py"),
        )
        fixture_module = importlib.util.module_from_spec(fixture_spec)
        fixture_spec.loader.exec_module(fixture_module)
        self.raw = fixture_module.fixtures()
        env = mock.patch.dict(
            os.environ,
            {
                "AUTOMATION_DATA_SERVICE_FILE": str(self.service),
                "AUTOMATION_DATA_SERVICE": "retained_migrator",
                "AUTOMATION_DATA_LOGIN_ENROLL_CONFIRM": "enroll:automation-data:sample:migrator",
            },
            clear=True,
        )
        env.start()
        self.addCleanup(env.stop)
        config = access.AccessConfig(self.root / "inventory-auth", self.root, self.root)
        for mocked in [
            mock.patch.object(command, "load_access_config", return_value=config, create=True),
            mock.patch.object(
                command,
                "fetch_observations",
                side_effect=lambda *_: [
                    validate_observation(raw, source) for source, raw in self.raw.items()
                ],
                create=True,
            ),
            mock.patch.object(command, "require_deployed_enrollment_sources", create=True),
            mock.patch.object(
                command, "private_database_tunnel", return_value=contextlib.nullcontext(15432)
            ),
        ]:
            mocked.start()
            self.addCleanup(mocked.stop)

    def write(self, path, value):
        path.write_text(value)
        path.chmod(0o600)

    def invoke(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = command.main(["enroll-migrator", "sample"])
        self.assertNotIn("SYNTHETIC_RETAINED_SECRET", output.getvalue())
        self.assertEqual((self.service.read_bytes(), self.passfile.read_bytes()), self.retained)
        return result, output.getvalue()

    def test_attended_enrollment_authenticates_and_binds_without_export_or_mutation(self):
        with (
            mock.patch.object(command, "authenticate_candidate") as authenticate,
            mock.patch.object(
                command, "send_request", side_effect=AssertionError("mutation forbidden")
            ),
        ):
            result, output = self.invoke()
        self.assertEqual(result, 0, output)
        self.assertEqual(authenticate.call_args.args[:3], (15432, "sample", "sample_migrator"))
        binding = json.loads((self.directory / "binding.json").read_text())
        self.assertEqual(binding["credentialId"], "fixture-migrator")
        self.assertNotIn("credentialGeneration", binding)
        self.assertEqual(stat.S_IMODE((self.directory / "binding.json").stat().st_mode), 0o600)

    def test_confirmation_and_authentication_failure_preserve_unbound_files(self):
        with (
            mock.patch.dict(os.environ, {"AUTOMATION_DATA_LOGIN_ENROLL_CONFIRM": "wrong"}),
            mock.patch.object(command, "authenticate_candidate") as authenticate,
        ):
            self.assertEqual(self.invoke()[0], 1)
        authenticate.assert_not_called()
        with mock.patch.object(
            command, "authenticate_candidate", side_effect=ValueError(SENTINEL)
        ):
            result, output = self.invoke()
        self.assertEqual(result, 1)
        self.assertNotIn(SENTINEL, output)
        self.assertFalse((self.directory / "binding.json").exists())

    def test_marker_changes_during_authentication_do_not_bind_stale_material(self):
        def change(*_):
            self.raw["platform"]["objects"][0]["migratorCredentialId"] = "replacement-fixture"

        with mock.patch.object(command, "authenticate_candidate", side_effect=change):
            self.assertEqual(self.invoke()[0], 1)
        self.assertFalse((self.directory / "binding.json").exists())



class MigratorRecoveryTest(unittest.TestCase):
    setUp = MigratorEnrollmentTest.setUp
    write = MigratorEnrollmentTest.write

    def prepare(self):
        self.service.unlink()
        self.passfile.unlink()
        self.requests = []
        self.fail_request = False
        self.authenticated = []
        os.environ["AUTOMATION_DATA_LOGIN_RECOVER_CONFIRM"] = "recover:automation-data:sample:migrator"
        guard = mock.patch.object(command, "require_deployed_recovery_sources", create=True)
        guard.start()
        self.addCleanup(guard.stop)

        def request(payload):
            self.requests.append(payload.copy())
            pending = self.directory / "pending"
            self.assertEqual(stat.S_IMODE((pending / "candidate.pgpass").stat().st_mode), 0o600)
            self.assertNotIn(payload["password"], (pending / "operation.json").read_text())
            if self.fail_request:
                raise command.RequestError("synthetic failure")
            self.password = payload["password"]
            marker = "2026-10-02T00:00:00+00:00"
            self.raw["platform"]["objects"][0]["migratorUpdatedAt"] = marker
            credential = next(x for x in self.raw["n8n"]["objects"] if x["id"] == "fixture-migrator")
            credential["updatedAt"] = marker
            return {"ok": True, "domain": "sample", "operation": "rotate", "state": "ready",
                    "migratorCredentialId": "fixture-migrator", "migratorCredentialUpdatedAt": marker}

        def authenticate(port, domain, role, password):
            self.assertEqual((port, domain, role), (15432, "sample", "sample_migrator"))
            self.assertEqual(password, self.password)
            self.authenticated.append(password)

        for patched in [mock.patch.object(command, "send_request", side_effect=request),
                        mock.patch.object(command, "authenticate_candidate", side_effect=authenticate)]:
            patched.start()
            self.addCleanup(patched.stop)

    def invoke_recovery(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = command.main(["recover-migrator", "sample"])
        for request in self.requests:
            self.assertNotIn(request["password"], output.getvalue())
        return result, output.getvalue()

    def test_recovery_retains_authenticates_and_installs_fixed_profile(self):
        self.prepare()
        result, output = self.invoke_recovery()
        self.assertEqual(result, 0, output)
        self.assertEqual(len(self.authenticated), 1)
        self.assertIn("sample_migrator", self.passfile.read_text())
        self.assertIn(self.requests[0]["password"], self.passfile.read_text())
        binding = json.loads((self.directory / "binding.json").read_text())
        self.assertEqual(binding["credentialId"], "fixture-migrator")
        self.assertFalse((self.directory / "pending").exists())
        self.assertEqual(stat.S_IMODE(self.service.stat().st_mode), 0o600)

    def test_ambiguous_failure_retries_same_password(self):
        self.prepare()
        self.fail_request = True
        self.assertEqual(self.invoke_recovery()[0], 1)
        first = self.requests[0].copy()
        self.assertFalse(self.service.exists())
        self.fail_request = False
        result, output = self.invoke_recovery()
        self.assertEqual(result, 0, output)
        self.assertEqual(self.requests[1], first)

    def test_equivalent_response_timestamp_installs_ready_profile(self):
        self.prepare()
        original = command.send_request

        def respond(payload):
            result = original(payload)
            credential = next(x for x in self.raw["n8n"]["objects"]
                              if x["id"] == "fixture-migrator")
            credential["updatedAt"] = "2026-10-02T00:00:00.000Z"
            return result

        with mock.patch.object(command, "send_request", side_effect=respond):
            result, output = self.invoke_recovery()
        self.assertEqual(result, 0, output)
        self.assertTrue(self.service.exists())
        self.assertFalse((self.directory / "pending").exists())
        binding = json.loads((self.directory / "binding.json").read_text())
        self.assertEqual(binding["credentialUpdatedAt"], "2026-10-02T00:00:00.000Z")

    def test_different_response_timestamp_prevents_installation(self):
        self.prepare()
        original = command.send_request

        def respond(payload):
            result = original(payload)
            result["migratorCredentialUpdatedAt"] = "2026-10-02T00:00:00.001Z"
            return result

        with mock.patch.object(command, "send_request", side_effect=respond):
            self.assertEqual(self.invoke_recovery()[0], 1)
        self.assertFalse(self.service.exists())
        self.assertFalse((self.directory / "binding.json").exists())
        self.assertTrue((self.directory / "pending" / "candidate.pgpass").exists())

    def test_missing_candidate_does_not_generate_or_mutate_again(self):
        self.prepare()
        self.fail_request = True
        self.invoke_recovery()
        (self.directory / "pending" / "candidate.pgpass").unlink()
        self.fail_request = False
        self.assertEqual(self.invoke_recovery()[0], 1)
        self.assertEqual(len(self.requests), 1)

    def test_auth_failure_retains_candidate_and_prevents_profile_install(self):
        self.prepare()
        with mock.patch.object(command, "authenticate_candidate", side_effect=ValueError("wrong identity")):
            self.assertEqual(self.invoke_recovery()[0], 1)
        self.assertTrue((self.directory / "pending" / "candidate.pgpass").exists())
        self.assertFalse(self.service.exists())
        self.assertFalse((self.directory / "binding.json").exists())

    def test_completed_remote_rotation_is_reconciled_without_repeating_mutation(self):
        self.prepare()
        with mock.patch.object(command, "authenticate_candidate", side_effect=ValueError("interrupted read")):
            self.assertEqual(self.invoke_recovery()[0], 1)
        result, output = self.invoke_recovery()
        self.assertEqual(result, 0, output)
        self.assertEqual(len(self.requests), 1)

    def test_metadata_change_during_authentication_prevents_binding(self):
        self.prepare()
        original = command.authenticate_candidate
        def changed(*args):
            original(*args)
            self.raw["platform"]["objects"][0]["migratorCredentialId"] = "replacement-fixture"
        with mock.patch.object(command, "authenticate_candidate", side_effect=changed):
            self.assertEqual(self.invoke_recovery()[0], 1)
        self.assertFalse(self.service.exists())

    def test_changed_marker_with_wrong_candidate_stops_before_retry(self):
        self.prepare()
        self.fail_request = True
        self.invoke_recovery()
        marker = "2026-10-03T00:00:00+00:00"
        self.raw["platform"]["objects"][0]["migratorUpdatedAt"] = marker
        next(x for x in self.raw["n8n"]["objects"] if x["id"] == "fixture-migrator")["updatedAt"] = marker
        with mock.patch.object(command, "authenticate_candidate", side_effect=ValueError("candidate no longer current")):
            self.assertEqual(self.invoke_recovery()[0], 1)
        self.assertEqual(len(self.requests), 1)
        self.assertFalse(self.service.exists())

    def test_partial_remote_rotation_retries_retained_candidate(self):
        self.prepare()
        with mock.patch.object(command, "authenticate_candidate", side_effect=ValueError("interrupted")):
            self.assertEqual(self.invoke_recovery()[0], 1)
        self.raw["platform"]["objects"][0]["state"] = "error"
        first = self.requests[0]["password"]
        original = command.send_request
        def complete(payload):
            self.raw["platform"]["objects"][0]["state"] = "ready"
            return original(payload)
        with mock.patch.object(command, "send_request", side_effect=complete):
            result, output = self.invoke_recovery()
        self.assertEqual(result, 0, output)
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(self.requests[1]["password"], first)

    def test_partial_local_installation_retries_without_rotation(self):
        self.prepare()
        original = command.write_private_file_exclusive
        def interrupt(path, data):
            if Path(path) == self.service:
                raise client.PrivateFileError("interrupted installation")
            return original(path, data)
        with mock.patch.object(command, "write_private_file_exclusive", side_effect=interrupt):
            self.assertEqual(self.invoke_recovery()[0], 1)
        self.assertTrue(self.passfile.exists())
        self.assertFalse(self.service.exists())
        result, output = self.invoke_recovery()
        self.assertEqual(result, 0, output)
        self.assertEqual(len(self.requests), 1)

    def test_symlink_pending_material_is_rejected(self):
        self.prepare()
        self.fail_request = True
        self.invoke_recovery()
        pending = self.directory / "pending" / "candidate.pgpass"
        saved = self.directory / "saved"
        pending.rename(saved)
        pending.symlink_to(saved)
        self.assertEqual(self.invoke_recovery()[0], 1)
        self.assertEqual(len(self.requests), 1)
        self.assertFalse(self.service.exists())

    def test_candidate_directory_entries_are_durable_before_mutation(self):
        self.prepare()
        self.directory.rmdir()
        flushed = set()
        pending_parent_flushed = []
        original_fsync = os.fsync
        original_send = command.send_request
        def fsync(descriptor):
            info = os.fstat(descriptor)
            if stat.S_ISDIR(info.st_mode):
                flushed.add((info.st_dev, info.st_ino))
                if (self.directory / "pending").exists():
                    parent = self.directory.stat()
                    if (info.st_dev, info.st_ino) == (parent.st_dev, parent.st_ino):
                        pending_parent_flushed.append(True)
            original_fsync(descriptor)
        def send(payload):
            self.assertTrue(pending_parent_flushed)
            for path in [self.root, self.directory, self.directory / "pending"]:
                info = path.stat()
                self.assertIn((info.st_dev, info.st_ino), flushed)
            return original_send(payload)
        with mock.patch.object(os, "fsync", side_effect=fsync), \
                mock.patch.object(command, "send_request", side_effect=send):
            result, output = self.invoke_recovery()
        self.assertEqual(result, 0, output)

    def test_confirmation_precedes_requests(self):
        self.prepare()
        os.environ["AUTOMATION_DATA_LOGIN_RECOVER_CONFIRM"] = "wrong"
        self.assertEqual(self.invoke_recovery()[0], 1)
        self.assertEqual(self.requests, [])

    def test_existing_unbound_files_are_preserved(self):
        self.prepare()
        self.service.write_text("existing profile\n")
        self.service.chmod(0o600)
        self.assertEqual(self.invoke_recovery()[0], 1)
        self.assertEqual(self.service.read_text(), "existing profile\n")
        self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main()
