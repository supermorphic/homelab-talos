#!/usr/bin/env python3
"""Fixed PostgreSQL tunnel and protected profile behavior."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import automation_data_access as access
import automation_data_client as client
from automation_data_inventory import validate_observation

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

    def test_canonical_exec_config_is_accepted_and_altered_launcher_is_rejected(self):
        root = Path(__file__).resolve().parents[2]
        sys.path.insert(0, str(root))
        from scripts.openbao import credentials, guards, workstation
        from scripts.test.core.test_openbao_credentials import state

        repo = self.directory.resolve() / "checkout"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        launcher = repo / credentials.LAUNCHER
        launcher.parent.mkdir(parents=True)
        launcher.write_text("#!/bin/sh\nexit 0\n")
        launcher.chmod(0o755)
        auth = self.directory.resolve() / "auth"
        auth.mkdir(mode=0o700)
        local = state()
        workstation.write_private(auth / "cluster.json", local["cluster"])
        workstation.write_private(auth / "workstation.json", {
            **{k: v for k, v in local.items() if k != "cluster"}, "schema_version": 1,
            "cluster_digest": guards.digest(local["cluster"]),
        })
        config = credentials.install_kubeconfig(repo, auth)
        with mock.patch.object(client, "__file__", str(repo / "scripts/lib/automation_data_client.py")), \
                mock.patch.object(workstation, "DIRECTORY", auth):
            self.assertEqual(client.scoped_kubeconfig(config), config)
            changed = json.loads(config.read_text())
            changed["users"][0]["user"]["exec"]["command"] = "/unapproved/plugin"
            config.write_text(json.dumps(changed))
            with self.assertRaises(client.PrivateTunnelUnavailable):
                client.scoped_kubeconfig(config)

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


class AutomaticConnectTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.root.chmod(0o700)
        self.config_root = self.root / "homelab" / "automation-data"
        self.config_root.mkdir(parents=True, mode=0o700)
        self.app = self.root / "applications"
        self.migrators = self.root / "migrators"
        for directory in [self.app, self.migrators]:
            directory.mkdir(mode=0o700)
        fixture_spec = importlib.util.spec_from_file_location(
            "discovery_test_fixtures",
            Path(__file__).with_name("automation-data-discovery-command-test.py"),
        )
        fixture_module = importlib.util.module_from_spec(fixture_spec)
        fixture_spec.loader.exec_module(fixture_module)
        self.raw = fixture_module.fixtures()
        self.role = fixture_module.APP_ROLE
        self.write(self.config_root / "inventory-auth", "SYNTHETIC_INVENTORY_ONLY")
        self.write(
            self.config_root / "access.json",
            json.dumps(
                {
                    "schemaVersion": 1,
                    "inventoryAuthFile": str(self.config_root / "inventory-auth"),
                    "applicationProfileRoot": str(self.app),
                    "migratorProfileRoot": str(self.migrators),
                }
            ),
        )
        environment = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.root)}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        self.fetch = mock.patch.object(
            access,
            "fetch_observations",
            side_effect=lambda *_: [
                validate_observation(raw, source) for source, raw in self.raw.items()
            ],
        )
        self.fetch.start()
        self.addCleanup(self.fetch.stop)
        self.install_application()
        self.install_migrator()

    def write(self, path, value):
        path.write_text(value)
        path.chmod(0o600)

    def service(self, directory, role, passfile, section):
        self.write(passfile, f"127.0.0.1:15432:sample:{role}:SYNTHETIC_SECRET_ONLY\n")
        self.write(
            directory / "service.conf",
            f"[{section}]\nhost=127.0.0.1\nport=15432\n"
            f"dbname=sample\nuser={role}\npassfile={passfile}\nsslmode=disable\n",
        )

    def install_application(self):
        directory = self.app / "sample" / "interview"
        directory.mkdir(parents=True, mode=0o700)
        directory.parent.chmod(0o700)
        version = directory / "generation-2"
        version.mkdir(mode=0o700)
        self.service(
            directory,
            self.role,
            version / "credential.pgpass",
            f"automation_data_sample_{self.role}",
        )
        self.write(
            directory / "binding.json",
            json.dumps(
                {
                    "domain": "sample",
                    "database": "sample",
                    "application": "interview",
                    "schema": "consumer_schema",
                    "role": self.role,
                    "credentialGeneration": 2,
                    "localPort": 15432,
                }
            ),
        )
        self.application_directory = directory

    def install_migrator(self):
        directory = self.migrators / "sample"
        directory.mkdir(mode=0o700)
        self.service(
            directory, "sample_migrator", directory / "credential.pgpass", "retained_migrator"
        )
        domain = self.raw["platform"]["objects"][0]
        self.write(
            directory / "binding.json",
            json.dumps(
                {
                    "domain": "sample",
                    "database": "sample",
                    "role": "sample_migrator",
                    "credentialId": domain["migratorCredentialId"],
                    "credentialUpdatedAt": domain["migratorUpdatedAt"],
                    "localPort": 15432,
                    "service": "retained_migrator",
                }
            ),
        )
        self.migrator_directory = directory

    def test_ready_connections_need_no_terminal_or_password_prompt(self):
        for identity, role in [
            ("application/interview", self.role),
            ("migrator", "sample_migrator"),
        ]:
            output = io.StringIO()
            with (
                mock.patch.object(
                    command, "private_database_tunnel", return_value=contextlib.nullcontext(15432)
                ) as tunnel,
                mock.patch.object(command, "authenticate_candidate") as authenticate,
                mock.patch.object(command.time, "sleep", side_effect=KeyboardInterrupt),
                mock.patch("builtins.input", side_effect=AssertionError("prompt forbidden")),
                mock.patch.object(sys, "stdin", io.StringIO()),
                contextlib.redirect_stdout(output),
            ):
                self.assertEqual(command.main(["sample", identity]), 0)
            tunnel.assert_called_once()
            self.assertEqual(authenticate.call_args.args[:3], (15432, "sample", role))
            self.assertNotIn("SYNTHETIC_SECRET", output.getvalue())

    def test_generation_change_after_selection_stops_before_secret_use(self):
        self.assertTrue(callable(getattr(access, "select_connection_profile", None)))
        selection = access.select_connection_profile("sample", "application/interview")
        app = next(o for o in self.raw["platform"]["objects"] if o["kind"] == "application")
        app["credentialGeneration"] = 3
        with (
            mock.patch.object(
                command,
                "validate_service_profile",
                side_effect=AssertionError("secret read forbidden"),
            ),
            self.assertRaises(client.PrivateFileError),
        ):
            command.selected_profile("sample", "application/interview", 15432, selection)

    def test_profile_replacement_after_selection_stops_before_secret_use(self):
        self.assertTrue(callable(getattr(access, "select_connection_profile", None)))
        selection = access.select_connection_profile("sample", "application/interview")
        path = self.application_directory / "service.conf"
        replacement = path.with_name("replacement.conf")
        self.write(replacement, path.read_text())
        replacement.replace(path)
        with (
            mock.patch.object(
                command,
                "validate_service_profile",
                side_effect=AssertionError("secret read forbidden"),
            ),
            self.assertRaises(client.PrivateFileError),
        ):
            command.selected_profile("sample", "application/interview", 15432, selection)

    def test_pending_and_unavailable_inventory_never_fall_back(self):
        pending = self.application_directory / "pending"
        pending.mkdir(mode=0o700)
        self.write(pending / "operation.json", "{}")
        for identity in ["application/interview", "migrator"]:
            if identity == "migrator":
                self.raw["platform"] = {
                    "source": "platform",
                    "status": "unavailable",
                    "complete": False,
                }
            with (
                mock.patch.object(command, "private_database_tunnel") as tunnel,
                contextlib.redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(command.main(["sample", identity]), 1)
            tunnel.assert_not_called()

    def test_partial_explicit_override_is_an_error(self):
        self.assertTrue(callable(getattr(access, "select_connection_profile", None)))
        with (
            mock.patch.dict(
                os.environ,
                {"AUTOMATION_DATA_SERVICE_FILE": str(self.migrator_directory / "service.conf")},
            ),
            mock.patch.object(access, "fetch_observations") as fetch,
            self.assertRaises(client.PrivateFileError),
        ):
            access.select_connection_profile("sample", "migrator")
        fetch.assert_not_called()

    def test_explicit_profile_works_when_inventory_is_unavailable(self):
        with (
            mock.patch.dict(
                os.environ,
                {
                    "AUTOMATION_DATA_SERVICE_FILE": str(self.migrator_directory / "service.conf"),
                    "AUTOMATION_DATA_SERVICE": "retained_migrator",
                },
            ),
            mock.patch.object(
                access, "fetch_observations", side_effect=AssertionError("discovery forbidden")
            ),
        ):
            self.assertEqual(
                command.selected_profile("sample", "migrator", 15432)[0], "sample_migrator"
            )

    def test_wrong_service_and_passfile_target_cannot_authenticate(self):
        for old, new in [
            ("dbname=sample", "dbname=other"),
            (
                f"passfile={self.migrator_directory / 'credential.pgpass'}",
                f"passfile={self.application_directory / 'generation-2/credential.pgpass'}",
            ),
        ]:
            service = self.migrator_directory / "service.conf"
            original = service.read_text()
            self.write(service, original.replace(old, new))
            with (
                mock.patch.object(
                    command, "private_database_tunnel", return_value=contextlib.nullcontext(15432)
                ),
                mock.patch.object(command, "authenticate_candidate") as authenticate,
                contextlib.redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(command.main(["sample", "migrator"]), 1)
            authenticate.assert_not_called()
            self.write(service, original)

    def test_local_change_during_secret_read_stops_before_authentication(self):
        original = command.validate_service_profile

        def replace_after_read(*args):
            result = original(*args)
            pending = self.application_directory / "pending"
            pending.mkdir(mode=0o700)
            self.write(pending / "operation.json", "{}")
            return result

        with (
            mock.patch.object(
                command, "private_database_tunnel", return_value=contextlib.nullcontext(15432)
            ),
            mock.patch.object(command, "validate_service_profile", side_effect=replace_after_read),
            mock.patch.object(command, "authenticate_candidate") as authenticate,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(command.main(["sample", "application/interview"]), 1)
        authenticate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
