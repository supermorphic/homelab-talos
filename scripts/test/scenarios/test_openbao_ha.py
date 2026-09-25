"""Stateful fake cluster checks eviction safety and ordered member recovery."""

import copy
import importlib
import unittest

from scripts.test.scenarios.test_openbao_issuance import Clock


def state():
    return {
        "cluster_id": "synthetic-cluster",
        "owner_uid": "synthetic-sts",
        "leader": "openbao-0",
        "pods": {
            f"openbao-{i}": {
                "uid": f"pod-{i}",
                "resource_version": "10",
                "owner_uid": "synthetic-sts",
                "ready": True,
                "node": f"node-{i}",
                "image": "quay.io/openbao/openbao:2.6.0@sha256:" + "a" * 64,
                "revision": "old",
            }
            for i in range(3)
        },
        "members": {
            f"openbao-{i}": {"voter": True, "healthy": True, "leader": i == 0, "index": 100}
            for i in range(3)
        },
    }


class Cluster:
    def __init__(self):
        self.current = state()
        self.events = []
        self.reads = 0
        self.race = None
        self.recover = True
        self.target = None

    def snapshot(self):
        self.reads += 1
        if self.race:
            self.race(self)
        return copy.deepcopy(self.current)

    def check(self):
        self.events.append("guard")

    def probe(self):
        self.events.append("issuance")
        return self.recover

    def evict(self, name, uid, resource_version):
        assert self.current["pods"][name]["uid"] == uid
        self.events.append(("eviction", name))
        if self.recover:
            self.current["pods"][name]["uid"] = uid + "-new"
            if self.target:
                self.current["pods"][name].update(image=self.target, revision="new")
            if name == self.current["leader"]:
                self.transfer(name, {"openbao-1"})
        else:
            self.current["pods"][name]["ready"] = False

    def transfer(self, old, allowed):
        self.events.append(("transfer", old))
        leader = min(allowed)
        self.current["leader"] = leader
        for name, member in self.current["members"].items():
            member["leader"] = name == leader

    def upgrade_preconditions(self):
        return {"image": self.target, "revision": "new", "snapshot": "synthetic-snapshot"}


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(
            importlib.util.find_spec("scripts.openbao.maintenance"), "maintenance missing"
        )
        self.module = importlib.import_module("scripts.openbao.maintenance")
        self.cluster, self.clock = Cluster(), Clock()

    def replace(self, role="standby"):
        return self.module.replace_member(
            "pod-1" if role == "standby" else "pod-0", role, self.cluster, self.cluster, self.clock
        )

    def test_follower_and_leader_return_three_voters_using_eviction(self):
        for role in ("standby", "leader"):
            with self.subTest(role=role):
                self.cluster = Cluster()
                result = self.replace(role)
                self.assertEqual(result["status"], "pass")
                self.assertEqual(result["issuance_interruption_seconds"], 0)
                self.assertEqual(
                    len(
                        [
                            e
                            for e in self.cluster.events
                            if isinstance(e, tuple) and e[0] == "eviction"
                        ]
                    ),
                    1,
                )

    def test_fresh_uid_role_owner_or_quorum_changes_block_mutation(self):
        for field in ("uid", "leader", "owner", "health"):
            self.cluster = Cluster()

            def race(c, field=field):
                if c.reads != 2:
                    return
                if field == "uid":
                    c.current["pods"]["openbao-1"]["uid"] = "changed"
                if field == "leader":
                    c.transfer("openbao-0", {"openbao-1"})
                if field == "owner":
                    c.current["owner_uid"] = "different"
                if field == "health":
                    c.current["members"]["openbao-2"]["healthy"] = False

            self.cluster.race = race
            with self.subTest(field=field), self.assertRaises(self.module.MaintenanceError):
                self.replace()
            self.assertFalse(
                any(isinstance(e, tuple) and e[0] == "eviction" for e in self.cluster.events)
            )

    def test_timeout_stops_after_one_eviction_and_never_rolls_back(self):
        self.cluster.probe = lambda: True
        self.cluster.recover = False
        with self.assertRaises(self.module.MaintenanceError):
            self.replace()
        self.assertLessEqual(self.clock.now, 1182)
        self.assertEqual(
            [e for e in self.cluster.events if isinstance(e, tuple)], [("eviction", "openbao-1")]
        )

    def test_upgrade_replaces_standbys_transfers_then_old_leader(self):
        self.cluster.target = "quay.io/openbao/openbao:2.7.0@sha256:" + "b" * 64
        result = self.module.upgrade(self.cluster, self.cluster, self.clock)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(
            [e for e in self.cluster.events if isinstance(e, tuple)],
            [
                ("eviction", "openbao-1"),
                ("eviction", "openbao-2"),
                ("transfer", "openbao-0"),
                ("eviction", "openbao-0"),
            ],
        )

    def test_upgrade_rejects_downgrade_or_no_pending_revision(self):
        for tag in ("2.5.0", "2.6.0"):
            self.cluster.target = "quay.io/openbao/openbao:" + tag + "@sha256:" + "b" * 64
            with self.assertRaises(self.module.MaintenanceError):
                self.module.upgrade(self.cluster, self.cluster, self.clock)
        self.assertFalse(any(isinstance(e, tuple) for e in self.cluster.events))


class AdapterTests(unittest.TestCase):
    def test_eviction_uses_core_pod_subresource_and_both_preconditions(self):
        import json
        from unittest.mock import Mock

        from scripts.test.scenarios import openbao_ha as live

        scope = Mock()
        cluster = live.LiveCluster(scope, None, None)
        cluster.evict("openbao-1", "fixture-uid", "42")
        args, kwargs = scope.command.call_args
        self.assertEqual(
            args,
            ("create", "--raw", "/api/v1/namespaces/openbao/pods/openbao-1/eviction", "-f", "-"),
        )
        body = json.loads(kwargs["input_bytes"])
        self.assertEqual(body["apiVersion"], "policy/v1")
        self.assertEqual(
            body["deleteOptions"]["preconditions"], {"uid": "fixture-uid", "resourceVersion": "42"}
        )

    def test_snapshot_requires_archive_checksum_and_freshness(self):
        from unittest.mock import patch

        from scripts.test.scenarios import openbao_ha as live

        metadata = {
            "created_at": "1970-01-01T00:00:00Z",
            "sha256": "a" * 64,
            "openbao_version": "2.7.0",
            "raft_index": 10,
        }
        with (
            patch.object(live.restore, "load_metadata", return_value=metadata),
            patch.object(live.restore, "validate_snapshot") as validate,
        ):
            with self.assertRaises(live.maintenance.MaintenanceError):
                live.snapshot_evidence("/synthetic/snapshot.snap", 4000, "2.7.0")
            validate.assert_called_once()


class IsolatedTests(unittest.TestCase):
    def test_scope_guard_rejects_production_and_missing_ownership_before_write(self):
        from unittest.mock import Mock

        from scripts.openbao import maintenance

        sandbox = Mock()
        sandbox.namespace = "openbao"
        sandbox.run_id = "synthetic-run"
        with self.assertRaises(maintenance.MaintenanceError):
            maintenance.isolated_scope(sandbox)
        sandbox.rotate_certificate.assert_not_called()

    def test_drift_injection_requires_each_real_difference_and_reader_denial(self):
        from unittest.mock import Mock

        from scripts.openbao import maintenance

        sandbox = Mock()
        sandbox.namespace = "openbao-isolated-synthetic"
        sandbox.run_id = "synthetic-run"
        sandbox.namespace_state.return_value = {
            "metadata": {
                "name": sandbox.namespace,
                "uid": "synthetic-namespace",
                "annotations": {"homelab.supermorphic.com/test-run": sandbox.run_id},
            }
        }
        sandbox.snapshot.return_value = state()
        values = {
            "sys/auth/homelab-jwt/tune": {"description": "Machine JWT"},
            "sys/policies/acl/openbao-acceptance": {"policy": "acceptance-fixture"},
            "kubernetes/roles/openbao-acceptance": {"token_default_ttl": 600},
            "sys/policies/acl/openbao-config-reader": {"policy": "reader-fixture"},
        }
        saved = copy.deepcopy(values)
        writes = []

        def request(method, path, payload=None):
            if method == "POST":
                writes.append((path, payload))
                values[path].update(payload)
                return 204, {}
            return 200, {"data": copy.deepcopy(values[path])}

        sandbox.request.side_effect = request

        def observe():
            return [
                kind
                for path, kind in [
                    ("sys/auth/homelab-jwt/tune", "auth-method"),
                    ("sys/policies/acl/openbao-acceptance", "policy"),
                    ("kubernetes/roles/openbao-acceptance", "issuance-role"),
                ]
                if values[path] != saved[path]
            ]

        sandbox.observe_drift.side_effect = observe
        sandbox.reader_request.side_effect = lambda *a: (
            403
            if values["sys/policies/acl/openbao-config-reader"]
            != saved["sys/policies/acl/openbao-config-reader"]
            else 200,
            {},
        )
        result = maintenance.isolated_drift(sandbox)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(values, saved)
        self.assertEqual(len(writes), 8)
        sandbox.observe_drift.side_effect = list
        with self.assertRaises(maintenance.MaintenanceError):
            maintenance.isolated_drift(sandbox)
        self.assertEqual(values, saved)

    def test_renewal_observes_actual_verified_tls_certificate_change(self):
        import hashlib
        import shutil
        import socket
        import ssl
        import subprocess
        import tempfile
        import threading
        from pathlib import Path
        from unittest.mock import Mock

        from scripts.openbao import maintenance

        if not shutil.which("openssl"):
            self.skipTest("openssl unavailable for ephemeral synthetic TLS fixture")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            certs = []
            for serial in (1, 2):
                cert, key = root / f"cert-{serial}.pem", root / f"key-{serial}.pem"
                subprocess.run(
                    [
                        "openssl",
                        "req",
                        "-x509",
                        "-newkey",
                        "rsa:2048",
                        "-nodes",
                        "-keyout",
                        str(key),
                        "-out",
                        str(cert),
                        "-days",
                        "1",
                        "-subj",
                        f"/CN=synthetic-{serial}",
                        "-addext",
                        "subjectAltName=DNS:localhost",
                        "-set_serial",
                        str(serial),
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                certs.append((cert, key))
            trust = root / "trust.pem"
            trust.write_bytes(certs[0][0].read_bytes() + certs[1][0].read_bytes())
            client_context = ssl.create_default_context(cafile=str(trust))
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(5)
            current = [0]
            errors = []

            def serve():
                try:
                    for _ in range(2):
                        connection, _ = listener.accept()
                        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                        context.load_cert_chain(*map(str, certs[current[0]]))
                        with context.wrap_socket(connection, server_side=True):
                            pass
                except OSError as error:
                    errors.append(type(error).__name__)

            thread = threading.Thread(target=serve)
            thread.start()
            sandbox = Mock()
            sandbox.namespace, sandbox.run_id = "openbao-isolated-synthetic", "synthetic-run"
            sandbox.namespace_state.return_value = {
                "metadata": {
                    "name": sandbox.namespace,
                    "uid": "synthetic-namespace",
                    "annotations": {"homelab.supermorphic.com/test-run": sandbox.run_id},
                }
            }
            sandbox.snapshot.return_value = state()

            def connect():
                raw = socket.create_connection(listener.getsockname(), timeout=3)
                return client_context.wrap_socket(raw, server_hostname="localhost")

            sandbox.connect_tls.side_effect = connect

            def rotate():
                current[0] = 1
                return hashlib.sha256(
                    ssl.PEM_cert_to_DER_cert(certs[1][0].read_text())
                ).hexdigest()

            sandbox.rotate_certificate.side_effect = rotate
            try:
                self.assertEqual(maintenance.isolated_renewal(sandbox, Clock())["status"], "pass")
            finally:
                thread.join(timeout=7)
                listener.close()
            self.assertFalse(errors)


class RecoveryTests(unittest.TestCase):
    setUp = MaintenanceTests.setUp
    replace = MaintenanceTests.replace

    def test_replacement_waits_for_replicated_progress_and_measures_interruption(self):
        probes = iter([True, False, True])
        self.cluster.probe = lambda: next(probes)

        def progress(cluster):
            if cluster.reads == 3:
                cluster.current["members"]["openbao-1"]["index"] = 99
            if cluster.reads == 4:
                cluster.current["members"]["openbao-1"]["index"] = 100

        self.cluster.race = progress
        result = self.replace()
        self.assertEqual(result["recovery_seconds"], 2)
        self.assertEqual(result["issuance_interruption_seconds"], 2)

    def test_leadership_transfer_failure_never_evicts_old_leader(self):
        self.cluster.target = "quay.io/openbao/openbao:2.7.0@sha256:" + "b" * 64
        self.cluster.transfer = lambda old, allowed: None
        with self.assertRaises(self.module.MaintenanceError):
            self.module.upgrade(self.cluster, self.cluster, self.clock)
        self.assertEqual(
            [e for e in self.cluster.events if isinstance(e, tuple)],
            [("eviction", "openbao-1"), ("eviction", "openbao-2")],
        )

    def test_source_guard_change_is_observed_before_eviction(self):
        def guard():
            self.cluster.current["pods"]["openbao-1"]["uid"] = "changed-at-guard"

        self.cluster.check = guard
        with self.assertRaises(self.module.MaintenanceError):
            self.replace()
        self.assertFalse(any(isinstance(e, tuple) for e in self.cluster.events))

    def test_recovery_cannot_pass_after_its_deadline(self):
        probes = [0]

        def probe():
            probes[0] += 1
            if probes[0] > 1:
                self.clock.now += 181
            return True

        self.cluster.probe = probe
        with self.assertRaises(self.module.MaintenanceError):
            self.replace()


class CommandTests(unittest.TestCase):
    def test_unknown_mode_refuses_before_reading_credentials(self):
        import os
        import subprocess
        import sys

        result = subprocess.run(
            [sys.executable, "-m", "scripts.test.scenarios.openbao_ha", "unknown-mode"],
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "OPENBAO_OPERATOR_KUBECONFIG": "/nonexistent"},
            timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout.strip(), '{"status": "refused"}')
        self.assertEqual(result.stderr, "")
