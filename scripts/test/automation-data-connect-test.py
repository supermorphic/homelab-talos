#!/usr/bin/env python3
"""Fixed PostgreSQL tunnel and protected profile behavior."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import automation_data_client as client

CONNECT_PATH = Path(__file__).resolve().parents[1] / "operations" / "automation-data-connect.py"
SPEC = importlib.util.spec_from_file_location("automation_data_connect", CONNECT_PATH)
assert SPEC and SPEC.loader
command = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(command)
LOGIN_PATH = Path(__file__).resolve().parents[1] / "operations" / "automation-data-login.py"
LOGIN_SPEC = importlib.util.spec_from_file_location("automation_data_login_for_tunnel", LOGIN_PATH)
assert LOGIN_SPEC and LOGIN_SPEC.loader
login_command = importlib.util.module_from_spec(LOGIN_SPEC)
LOGIN_SPEC.loader.exec_module(login_command)


class FakeProcess:
    def __init__(self, output="Forwarding from 127.0.0.1:15432 -> 5432\n", exited=False):
        self.stdout = io.StringIO(output)
        self.stderr = io.StringIO("")
        self.exited = exited
        self.terminated = False
        self.killed = False

    def poll(self):
        return 1 if self.exited or self.terminated else None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        return 0


class ConnectTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="automation-data-connect-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.directory.chmod(0o700)
        self.config = self.directory / "kubeconfig"
        self.config.write_text("apiVersion: v1\nkind: Config\n")
        self.config.chmod(0o600)

    def test_only_fixed_pod_is_forwarded_and_only_loopback_is_bound(self):
        process = FakeProcess()
        with mock.patch.object(client, "scoped_kubeconfig", return_value=self.config), \
                mock.patch.object(client, "assert_scoped_identity"), \
                mock.patch.object(client, "read_fixed_pod", return_value="fixed-uid"), \
                mock.patch.object(client, "assert_named_forward_allowed"), \
                mock.patch.object(client, "wait_for_forward"), \
                mock.patch.object(client, "start_pod_watcher", return_value=(mock.Mock(), mock.Mock())), \
                mock.patch.object(client.subprocess, "Popen", return_value=process) as spawn:
            with client.private_database_tunnel(self.config, 15432) as port:
                self.assertEqual(port, 15432)
            argv = spawn.call_args.args[0]
            self.assertEqual(argv[-5:], ["port-forward", "--address", "127.0.0.1",
                                         "pod/automation-data-postgresql-0", "15432:5432"])
            self.assertIn("homelab-diagnostic", argv)
            self.assertIn("automation-data", argv)
            self.assertTrue(process.terminated)

    def test_no_broader_context_fallback(self):
        config = {"apiVersion": "v1", "kind": "Config", "current-context": "homelab-admin",
                  "contexts": [{"name": "homelab-admin", "context": {
                      "cluster": "homelab", "user": "homelab-admin"}}],
                  "users": [{"name": "homelab-admin", "user": {"token": "t" * 40}}]}
        self.config.write_text(json.dumps(config))
        with self.assertRaises(client.PrivateTunnelUnavailable):
            client.scoped_kubeconfig(self.config)
        with mock.patch.object(client, "_run_kubectl", return_value=json.dumps({
            "status": {"userInfo": {"username": "system:masters"}}})), \
                self.assertRaises(client.PrivateTunnelUnavailable):
            client.assert_scoped_identity(self.config)

    def test_pod_must_be_ready_and_owned_by_fixed_statefulset(self):
        pod = {"metadata": {"name": "automation-data-postgresql-0",
                            "namespace": "automation-data",
                            "uid": "00000000-0000-4000-8000-000000000301",
                            "ownerReferences": [{"kind": "StatefulSet",
                                                 "name": "automation-data-postgresql",
                                                 "controller": True}]},
               "status": {"phase": "Running", "conditions": [
                   {"type": "Ready", "status": "True"}]}}
        with mock.patch.object(client, "_run_kubectl", return_value=json.dumps(pod)):
            self.assertEqual(client.read_fixed_pod(self.config), pod["metadata"]["uid"])
        pod["metadata"]["ownerReferences"][0]["name"] = "another-statefulset"
        with mock.patch.object(client, "_run_kubectl", return_value=json.dumps(pod)), \
                self.assertRaises(client.PrivateTunnelUnavailable):
            client.read_fixed_pod(self.config)

    def test_port_collision_does_not_kill_foreign_process(self):
        process = FakeProcess(output="", exited=True)
        with mock.patch.object(client.subprocess, "Popen", return_value=process), \
                mock.patch.object(client, "wait_for_forward", side_effect=
                                  client.PrivateTunnelUnavailable("port_unavailable")), \
                self.assertRaises(client.PrivateTunnelUnavailable):
            client.start_fixed_forward(self.config, 15432)
        self.assertFalse(process.killed)
        self.assertTrue(process.exited)

    def test_pod_replacement_invalidates_session(self):
        process = FakeProcess()
        with mock.patch.object(client, "read_fixed_pod", return_value="replacement"):
            thread, stop = client.start_pod_watcher(self.config, "initial", process)
            thread.join(timeout=3)
            stop.set()
        self.assertTrue(process.terminated)

    def test_interrupt_removes_only_owned_tunnel(self):
        process = FakeProcess()
        with mock.patch.object(client, "scoped_kubeconfig", return_value=self.config), \
                mock.patch.object(client, "assert_scoped_identity"), \
                mock.patch.object(client, "read_fixed_pod", return_value="fixed-uid"), \
                mock.patch.object(client, "assert_named_forward_allowed"), \
                mock.patch.object(client, "wait_for_forward"), \
                mock.patch.object(client, "start_pod_watcher", return_value=(mock.Mock(), mock.Mock())), \
                mock.patch.object(client.subprocess, "Popen", return_value=process), \
                self.assertRaises(KeyboardInterrupt), \
                client.private_database_tunnel(self.config, 15432):
            raise KeyboardInterrupt
        self.assertTrue(process.terminated)

    def test_profile_rejects_inline_password_and_wrong_binding(self):
        service = self.directory / "service.conf"
        passfile = self.directory / "credential.pgpass"
        passfile.write_text("127.0.0.1:15432:sample:sample_migrator:synthetic\n")
        passfile.chmod(0o600)
        section = "automation_data_sample_sample_migrator"
        service.write_text(f"[{section}]\nhost=127.0.0.1\nport=15432\n"
                           f"dbname=sample\nuser=sample_migrator\npassfile={passfile}\n"
                           "sslmode=disable\npassword=bad\n")
        service.chmod(0o600)
        with self.assertRaises(client.PrivateFileError):
            client.validate_service_profile(service, section, "sample", "sample_migrator", 15432)
        service.write_text(service.read_text().replace("password=bad\n", ""))
        with self.assertRaises(client.PrivateFileError):
            client.validate_service_profile(service, section, "other", "sample_migrator", 15432)

    def test_application_profile_requires_matching_binding(self):
        role = "app_" + hashlib.md5(
            b"sample:interview", usedforsecurity=False).hexdigest() + "_integration"
        directory = self.directory / "application"
        directory.mkdir(mode=0o700)
        version = directory / "generation-1"
        version.mkdir(mode=0o700)
        password_file = version / "credential.pgpass"
        password_file.write_text(f"127.0.0.1:15432:sample:{role}:synthetic-password\n")
        password_file.chmod(0o600)
        service_file = directory / "service.conf"
        section = f"automation_data_sample_{role}"
        service_file.write_text(f"[{section}]\nhost=127.0.0.1\nport=15432\n"
                                f"dbname=sample\nuser={role}\npassfile={password_file}\n"
                                "sslmode=disable\n")
        service_file.chmod(0o600)
        binding = directory / "binding.json"
        binding.write_text(json.dumps({"domain": "sample", "database": "sample",
                                       "application": "interview", "role": role,
                                       "schema": "interview_api", "localPort": 15432,
                                       "credentialGeneration": 1}))
        binding.chmod(0o600)
        with mock.patch.dict(os.environ, {"AUTOMATION_DATA_SERVICE_FILE": str(service_file),
                                       "AUTOMATION_DATA_SERVICE": section}):
            self.assertEqual(command.selected_profile("sample", "application/interview", 15432)[0],
                             role)
            with self.assertRaises(client.PrivateFileError):
                command.selected_profile("other", "application/interview", 15432)
            with self.assertRaises(ValueError):
                command.selected_profile("sample", "source/reader", 15432)
            binding.write_text(binding.read_text().replace('"interview"', '"another"'))
            with self.assertRaises(client.PrivateFileError):
                command.selected_profile("sample", "application/interview", 15432)

    def test_candidate_installation_uses_owned_tunnel_before_mutation(self):
        role = "app_" + hashlib.md5(
            b"sample:interview", usedforsecurity=False).hexdigest() + "_integration"
        operation_ids = []

        def request(payload):
            if payload["operation"] == "login-validate":
                return {"ok": True, "domain": "sample", "application": "interview",
                        "database": "sample", "schema": "interview_api", "role": role,
                        "state": "awaiting_grants", "credentialGeneration": 0, "valid": True}
            self.assertIn(15432, client._ACTIVE_TUNNELS)
            operation_ids.append(payload["operationId"])
            generation = 1
            return {"ok": True, "domain": "sample", "application": "interview",
                    "database": "sample", "schema": "interview_api", "role": role,
                    "state": "activating" if payload["operation"] == "login-activate" else "ready",
                    "credentialGeneration": generation, "operationId": payload["operationId"]}

        process = FakeProcess()
        output = io.StringIO()
        with mock.patch.dict(os.environ, {"AUTOMATION_DATA_LOGIN_DIRECTORY": str(self.directory),
                                       "AUTOMATION_DATA_PROVISIONING_TOKEN": "s" * 40,
                                       "AUTOMATION_DATA_LOGIN_ACTIVATE_CONFIRM":
                                       "activate:automation-data:sample:interview"}), \
                mock.patch.object(login_command, "send_request", side_effect=request), \
                mock.patch.object(login_command, "require_deployed_login_sources"), \
                mock.patch.object(login_command, "authenticate_candidate"), \
                mock.patch.object(client, "scoped_kubeconfig", return_value=self.config), \
                mock.patch.object(client, "assert_scoped_identity"), \
                mock.patch.object(client, "assert_named_forward_allowed"), \
                mock.patch.object(client, "read_fixed_pod", return_value="fixed-uid"), \
                mock.patch.object(client, "wait_for_forward"), \
                mock.patch.object(client, "start_pod_watcher", return_value=(mock.Mock(), mock.Mock())), \
                mock.patch.object(client.subprocess, "Popen", return_value=process), \
                contextlib.redirect_stdout(output):
            self.assertEqual(login_command.main(["activate", "sample", "interview"]), 0)
        self.assertEqual(len(operation_ids), 2)
        self.assertEqual(operation_ids[0], operation_ids[1])
        self.assertTrue(process.terminated)
        self.assertTrue((self.directory / "sample" / "interview" / "binding.json").is_file())
        self.assertNotIn("password", output.getvalue())


if __name__ == "__main__":
    unittest.main()
