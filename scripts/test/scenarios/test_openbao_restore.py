"""Offline restore invariants, synthetic archives and stateful cluster doubles."""

import copy
import hashlib
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.openbao import restore

RUN = "20260925T010000Z-openbao-restore-fixture"
MARKER = "synthetic-private-value-never-report"


def archive(extra=None):
    # Independently construct the upstream archive; no production writer is called.
    values = {"meta.json": b'{"Index":42,"Size":5}', "state.bin": b"state"}
    values["SHA256SUMS"] = b"".join(
        hashlib.sha256(v).hexdigest().encode() + b"  " + k.encode() + b"\n"
        for k, v in values.items()
    )
    values["SHA256SUMS.sealed"] = b"sealed-fixture"
    if extra:
        values[extra] = b"poison"
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as tar:
        for name, value in values.items():
            info = tarfile.TarInfo(name)
            info.size = len(value)
            tar.addfile(info, io.BytesIO(value))
    return output.getvalue()


class Cluster:
    """Models create-only storage and ownership changes independently of orchestration."""

    def __init__(self):
        self.recovery_metadata = {
            "seal_key_id": "openbao-static-seal-v1",
            "recovery_generation": "1",
        }
        self.objects = {}
        self.events = []
        self.blocked = True
        self.fail_cleanup = False
        self.guard_count = 0
        self.race = None

    def create(self, document):
        name = document["kind"]
        if name == "StatefulSet":
            assert "CiliumNetworkPolicy" in self.objects and "policy-read" in self.events
        assert name not in self.objects
        value = copy.deepcopy(document)
        value["metadata"]["uid"] = name + "-fixture-uid"
        self.objects[name] = value
        self.events.append(name)
        return copy.deepcopy(value)

    def read(self, document):
        self.events.append("policy-read" if document["kind"] == "CiliumNetworkPolicy" else "read")
        return copy.deepcopy(self.objects[document["kind"]])

    def provision_private(self, namespace, run_id):
        self.events.append("private-input")

    def wait_pod(self, namespace):
        self.events.append("pod")
        return "pod-fixture-uid"

    def isolation(self, namespace, run_id, pod_uid):
        self.events.append("network-probe")
        return {"loopback": True, "api_denied": self.blocked, "peers_denied": self.blocked}

    def inventory(self, namespace, run_id):
        self.guard_count += 1
        if self.race and self.guard_count == 2:
            self.race(self)
            self.race = None

    def restart(self, namespace, run_id, pod_uid):
        self.events.append("restart")
        return "new-pod-fixture-uid"

    def cleanup(self, documents, run_id):
        self.events.append("cleanup")
        if self.fail_cleanup:
            raise RuntimeError(MARKER)
        self.objects.clear()


class Client:
    def __init__(self, cluster):
        self.cluster = cluster
        self.events = cluster.events
        self.initialized = False
        self.good_config = True
        self.issuance_status = 500
        self.secret = MARKER

    def bind(self, namespace, pod_uid):
        self.events.append("bind")

    def state(self):
        return {
            "initialized": self.initialized,
            "sealed": False,
            "version": "2.7.0",
            "cluster_id": "scratch-id",
        }

    def initialize(self):
        self.events.append("init")
        self.initialized = True

    def wait_unsealed(self):
        return self.state()

    def force_restore(self, data):
        self.events.append("force-restore")

    def login_retained(self):
        self.events.append("retained-login")

    def restored_configuration(self):
        self.events.append("configuration")
        return self.good_config

    def issuance_denied(self):
        self.events.append("issuance")
        return self.issuance_status == 500

    def close(self):
        self.secret = None


class RestoredReadbackTests(unittest.TestCase):
    def test_isolated_provider_uses_exact_stored_configuration_and_fails_closed(self):
        from scripts.test.core.test_openbao_apply import StateClient
        from scripts.test.scenarios import openbao_restore as scenario

        fixtures = Path(__file__).parents[1] / "core/fixtures"
        raw = json.loads((fixtures / "openbao-2.7-jwt-stored-config.json").read_text())
        state = StateClient()
        calls = []
        response = [500, {"provider_unavailable": True}]
        raw_response = [200, raw]

        def http(method, path, **kwargs):
            calls.append((method, path))
            if path == "auth/homelab-jwt/config":
                return response
            if path == "sys/raw/auth/11111111-1111-4111-8111-111111111111/config":
                return raw_response
            if path == "sys/storage/raft/configuration":
                return 200, {"data": {"config": {"servers": [
                    {"node_id": "scratch", "voter": True, "leader": True}]}}}
            return 200, {"data": state.request(method, path)}

        cluster = type("Kube", (), {"http": staticmethod(http)})()
        client = scenario.ScratchClient(cluster, "synthetic-password")
        self.assertTrue(client.restored_configuration())
        self.assertIn(("GET", "sys/raw/auth/11111111-1111-4111-8111-111111111111/config"), calls)
        for status, body in ((403, {}), (404, {}), (500, {}), (200, {"data": {}})):
            response[:] = [status, body]
            with self.subTest(status=status), self.assertRaises(restore.RestoreError):
                client.restored_configuration()
        response[:] = [500, {"provider_unavailable": True}]
        for mutation in ({"bound_issuer": "https://other.example"},
                         {"oidc_client_secret": MARKER}, {"unreviewed": True}):
            value = json.loads(raw["data"]["value"])
            value.update(mutation)
            raw_response[:] = [200, {"data": {"value": json.dumps(value)}}]
            with self.subTest(mutation=list(mutation)):
                try:
                    passed = client.restored_configuration()
                except (restore.RestoreError, scenario.guards.SafeError):
                    passed = False
                self.assertFalse(passed)
        raw_response[:] = [403, {}]
        with self.assertRaises(restore.RestoreError):
            client.restored_configuration()
        raw_response[:] = [200, raw]
        for uid in (None, "", "../../other", ["one", "two"]):
            state.state[("auth-method", "homelab-jwt/")]["uuid"] = uid
            with self.subTest(uid=uid), self.assertRaises(restore.RestoreError):
                client.restored_configuration()

    def test_bridge_recognizes_only_literal_pinned_missing_provider_error(self):
        from scripts.test.scenarios import openbao_restore as scenario

        fixture = Path(__file__).parents[1] / "core/fixtures/openbao-2.7-jwt-provider-unavailable.json"
        expected = json.loads(fixture.read_text())
        for status, body, path, allowed in (
            (500, expected, "auth/homelab-jwt/config", True),
            (500, {"errors": [MARKER]}, "auth/homelab-jwt/config", False),
            (403, expected, "auth/homelab-jwt/config", False),
            (500, expected, "kubernetes/config", False),
        ):
            response = type("Response", (), {"status": status,
                "read": lambda self, limit, body=body: json.dumps(body).encode()})()
            connection = type("Connection", (), {"request": lambda *a: None,
                "getresponse": lambda self: response})()
            source = io.TextIOWrapper(io.BytesIO(
                json.dumps({"method": "GET", "path": path}).encode() + b"\n"))
            output = io.StringIO()
            with (patch("sys.stdin", source), patch("sys.stdout", output),
                  patch("http.client.HTTPConnection", return_value=connection)):
                exec(scenario.BRIDGE, {})
            self.assertEqual(json.loads(output.getvalue())["body"],
                             {"provider_unavailable": True} if allowed else {})
            self.assertNotIn(MARKER, output.getvalue())


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name).resolve() / "raft.snap"
        self.path.write_bytes(archive())
        self.metadata = {
            "created_at": "2026-09-25T01:00:00Z",
            "openbao_version": "2.7.0",
            "raft_index": 42,
            "seal_key_id": "openbao-static-seal-v1",
            "recovery_generation": "1",
            "sha256": hashlib.sha256(self.path.read_bytes()).hexdigest(),
        }
        self.kube = Cluster()
        self.client = Client(self.kube)

    def run_drill(self):
        with patch.dict(
            "os.environ",
            {"OPENBAO_RESTORE_CONFIRM": f"restore:openbao:{self.metadata['sha256']}:{RUN}"},
        ):
            return restore.run(self.path, self.metadata, RUN, self.client, self.kube)

    def test_success_orders_isolation_restore_restart_and_cleanup(self):
        result = self.run_drill()
        self.assertEqual(result["status"], "pass")
        events = self.kube.events
        self.assertLess(events.index("CiliumNetworkPolicy"), events.index("StatefulSet"))
        self.assertLess(events.index("network-probe"), events.index("init"))
        self.assertLess(events.index("retained-login"), events.index("configuration"))
        self.assertEqual(events.count("init"), 1)
        self.assertEqual(events.count("force-restore"), 1)
        self.assertGreaterEqual(events.count("configuration"), 2)
        self.assertGreaterEqual(events.count("network-probe"), 3)
        self.assertLess(events.index("restart"), events.index("cleanup"))
        self.assertNotIn(MARKER, json.dumps(result))
        self.assertIsNone(self.client.secret)

    def test_unconfirmed_run_performs_no_cluster_operation(self):
        result = restore.run(self.path, self.metadata, RUN, self.client, self.kube)
        self.assertEqual(result["status"], "refused")
        self.assertEqual(self.kube.events, [])

    def test_snapshot_and_generation_rejections_precede_resources(self):
        for field, value in [
            ("sha256", "0" * 64),
            ("openbao_version", "9.9.9"),
            ("seal_key_id", "wrong"),
            ("recovery_generation", "2"),
            ("raft_index", 99),
            ("snapshot_path", "/sensitive/path"),
        ]:
            with self.subTest(field=field):
                original = dict(self.metadata)
                self.metadata[field] = value
                self.assertEqual(self.run_drill()["status"], "fail")
                self.assertEqual(self.kube.events, [])
                self.metadata = original

    def test_archive_traversal_and_symlinks_fail_closed(self):
        self.path.write_bytes(archive("../escape"))
        self.metadata["sha256"] = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.assertEqual(self.run_drill()["status"], "fail")
        self.assertEqual(self.kube.events, [])
        self.path.unlink()
        self.path.symlink_to(Path(self.temp.name) / "missing")
        self.assertEqual(self.run_drill()["status"], "fail")

    def test_poisoned_metadata_path_is_never_followed(self):
        metadata_path = self.path.parent / "metadata.json"
        metadata_path.symlink_to("/not-a-snapshot-metadata-file")
        with self.assertRaises(restore.RestoreError):
            restore.load_metadata(metadata_path, self.path)

    def test_fresh_uid_and_ownership_changes_block_force_and_cleanup(self):
        for key in ("uid", "annotations"):
            with self.subTest(key=key):
                self.kube = Cluster()
                self.client = Client(self.kube)

                def race(cluster, key=key):
                    cluster.objects["PersistentVolumeClaim"]["metadata"][key] = (
                        "changed" if key == "uid" else {}
                    )

                self.kube.race = race
                result = self.run_drill()
                self.assertEqual(result["status"], "fail")
                self.assertNotIn("force-restore", self.kube.events)
                self.assertNotIn("cleanup", self.kube.events)
                self.assertEqual(result["cleanup"], "failed")

    def test_checksum_change_before_restore_blocks_write(self):
        self.client.initialize = lambda: self.path.write_bytes(b"changed")
        self.assertEqual(self.run_drill()["status"], "fail")
        self.assertNotIn("force-restore", self.kube.events)

    def test_actual_network_reachability_blocks_initialization(self):
        self.kube.blocked = False
        self.assertEqual(self.run_drill()["status"], "fail")
        self.assertNotIn("init", self.kube.events)

    def test_configuration_or_successful_issuance_fails_acceptance(self):
        for failure in ("good_config", "issuance_status"):
            with self.subTest(failure=failure):
                self.kube = Cluster()
                self.client = Client(self.kube)
                setattr(self.client, failure, False if failure == "good_config" else 200)
                self.assertEqual(self.run_drill()["status"], "fail")

    def test_cleanup_failure_is_separate_and_sanitized(self):
        self.kube.fail_cleanup = True
        result = self.run_drill()
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["cleanup"], "failed")
        self.assertNotIn(MARKER, json.dumps(result))

    def test_fixture_invariants(self):
        docs = restore.documents(RUN, "2.7.0")
        self.assertEqual(
            {d["kind"] for d in docs},
            {
                "Namespace",
                "CiliumNetworkPolicy",
                "ServiceAccount",
                "PersistentVolumeClaim",
                "StatefulSet",
            },
        )
        policy = next(d for d in docs if d["kind"] == "CiliumNetworkPolicy")
        self.assertEqual(policy["spec"]["egressDeny"], [{"toEntities": ["all"]}])
        self.assertEqual(policy["spec"]["ingressDeny"], [{"fromEntities": ["all"]}])
        pod = next(d for d in docs if d["kind"] == "StatefulSet")["spec"]["template"]["spec"]
        self.assertIs(pod["automountServiceAccountToken"], False)
        self.assertIs(pod["enableServiceLinks"], False)
        self.assertFalse(pod.get("hostNetwork", False))
        self.assertFalse(any("projected" in v or "hostPath" in v for v in pod["volumes"]))
        self.assertEqual(
            [
                v["persistentVolumeClaim"]["claimName"]
                for v in pod["volumes"]
                if "persistentVolumeClaim" in v
            ],
            ["scratch-data"],
        )


class AdapterTests(unittest.TestCase):
    def test_bridge_keeps_credentials_off_argv_and_rejects_redirects(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, b"x" * 32)
        cluster.pod_uid = "expected-pod"
        calls = []
        cluster.assert_pod = lambda uid: None

        def command(args, *, input_bytes=None):
            calls.append((args, input_bytes))
            return b'{"status":307,"body":{}}'

        with patch.object(scenario.guards, "command", command):
            status, _body = cluster.http("POST", "sys/init", payload={"token": MARKER})
        self.assertEqual(status, 307)
        self.assertNotIn(MARKER, repr(calls[0][0]))
        self.assertIn(MARKER.encode(), calls[0][1])
        self.assertNotIn("port-forward", calls[0][0])

    def test_negative_issuance_requires_backend_failure_not_forbidden_or_success(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = type("HTTP", (), {})()
        client = scenario.ScratchClient(cluster, "synthetic-password")
        for status, expected in [
            (200, False),
            (403, False),
            (404, False),
            (500, True),
            (503, False),
        ]:
            cluster.http = lambda *a, status=status, **kw: (status, {})
            self.assertIs(client.issuance_denied(), expected)

    def test_initial_force_failure_is_never_retried(self):
        fixture = RestoreTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)

        def fail(data):
            fixture.kube.events.append("force-restore")
            raise RuntimeError(MARKER)

        fixture.client.force_restore = fail
        self.assertEqual(fixture.run_drill()["status"], "fail")
        self.assertEqual(fixture.kube.events.count("init"), 1)
        self.assertEqual(fixture.kube.events.count("force-restore"), 1)

    def test_namespace_delete_checks_uid_and_resource_version_atomically(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, b"x" * 32)
        document = {
            "kind": "Namespace",
            "metadata": {
                "name": restore.namespace(RUN),
                "uid": "namespace-fixture",
                "resourceVersion": "99",
                "annotations": {restore.OWNER: RUN},
            },
        }
        cluster.read = lambda expected: document
        calls = []
        cluster.command = lambda *args, **kw: calls.append((args, kw))
        cluster.delete(document)
        body = json.loads(calls[0][1]["input_bytes"])
        self.assertEqual(
            body["preconditions"], {"uid": "namespace-fixture", "resourceVersion": "99"}
        )
        self.assertIn("/api/v1/namespaces/" + restore.namespace(RUN), calls[0][0])

    def test_cleanup_refuses_an_unowned_object_of_another_api_kind(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, b"x" * 32)
        cluster.command = lambda *a, **kw: b"jobs.batch\n"
        cluster.json = lambda *a: {
            "items": [{"kind": "Job", "metadata": {"name": "foreign", "uid": "foreign-uid"}}]
        }
        with self.assertRaises(restore.RestoreError):
            cluster.cleanup_inventory()

    def test_client_close_error_cannot_skip_cleanup_or_leak(self):
        fixture = RestoreTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.client.close = lambda: (_ for _ in ()).throw(RuntimeError(MARKER))
        result = fixture.run_drill()
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["cleanup"], "passed")
        self.assertNotIn(MARKER, json.dumps(result))

    def test_storage_rejects_a_production_volume_reference(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, b"x" * 32)
        claim = {
            "kind": "PersistentVolumeClaim",
            "metadata": {
                "uid": "claim-fixture",
                "name": "scratch-data",
                "namespace": restore.namespace(RUN),
                "annotations": {restore.OWNER: RUN},
            },
            "spec": {"volumeName": "production-data"},
        }
        cluster.created = [claim]
        cluster.read = lambda expected: claim
        with self.assertRaises(restore.RestoreError):
            cluster.assert_storage()

    def test_ambiguous_namespace_creation_reports_cleanup_failure(self):
        fixture = RestoreTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.kube.create = lambda document: (_ for _ in ()).throw(RuntimeError(MARKER))
        result = fixture.run_drill()
        self.assertEqual(result["cleanup"], "failed")
        self.assertEqual(result["status"], "fail")

    def test_restored_configuration_requires_hashed_audit_device(self):
        from scripts.test.scenarios import openbao_restore as scenario

        client = scenario.ScratchClient(None, "synthetic-password")
        client.api = lambda *a: {
            "data": {
                "config": {"servers": [{"node_id": "scratch", "voter": True, "leader": True}]}
            }
        }
        with (
            patch.object(scenario.apply, "snapshot", return_value=({}, {"canary": ({}, [])})),
            patch.object(scenario.apply, "audit_state", return_value=False),
        ):
            self.assertIs(client.restored_configuration(), False)

    def test_bridge_discards_credential_bearing_error_body(self):
        from scripts.test.scenarios import openbao_restore as scenario

        response = type(
            "Response",
            (),
            {"status": 403, "read": lambda self, limit: json.dumps({"error": MARKER}).encode()},
        )()
        connection = type(
            "Connection", (), {"request": lambda *a: None, "getresponse": lambda self: response}
        )()
        source = io.TextIOWrapper(io.BytesIO(b'{"method":"GET","path":"sys/health"}\n'))
        output = io.StringIO()
        with (
            patch("sys.stdin", source),
            patch("sys.stdout", output),
            patch("http.client.HTTPConnection", return_value=connection),
        ):
            exec(compile(scenario.BRIDGE, "<synthetic-bridge>", "exec"), {})  # noqa: S102 -- Execute only the repository-owned bridge against synthetic transport.
        self.assertEqual(json.loads(output.getvalue()), {"status": 403, "body": {}})
        self.assertNotIn(MARKER, output.getvalue())

    def test_cleanup_rejects_conflicting_marker_on_controller_owned_descendant(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, b"x" * 32)
        cluster.created = [{"metadata": {"uid": "owned-statefulset"}}]
        cluster.command = lambda *a, **kw: b"controllerrevisions.apps\n"
        cluster.json = lambda *a: {
            "items": [
                {
                    "kind": "ControllerRevision",
                    "metadata": {
                        "name": "scratch-revision",
                        "uid": "revision-uid",
                        "annotations": {restore.OWNER: "another-run"},
                        "ownerReferences": [{"uid": "owned-statefulset", "controller": True}],
                    },
                }
            ]
        }
        with self.assertRaises(restore.RestoreError):
            cluster.cleanup_inventory()

    def cleanup_storage_fixture(self, pv, volume):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, b"x" * 32)
        documents = [
            {
                "kind": "Namespace",
                "metadata": {"name": restore.namespace(RUN), "uid": "namespace-uid"},
            },
            {
                "kind": "PersistentVolumeClaim",
                "metadata": {"name": "scratch-data", "uid": "claim-uid"},
            },
        ]
        cluster.created = documents
        cluster.pv_uid = "original-pv-uid"
        cluster.volume_uid = "original-volume-uid"
        cluster.cleanup_inventory = lambda: None
        deletes = []
        reads = []
        cluster.delete = lambda doc: deletes.append(doc["kind"])

        def command(*args, **kwargs):
            reads.append(args)
            if "namespace" in args:
                return b""
            if "pv" in args:
                return json.dumps(pv).encode() if pv else b""
            if "volumes.longhorn.io" in args:
                return json.dumps(volume).encode() if volume else b""
            self.fail("Unexpected cleanup command")

        cluster.command = command
        return scenario, cluster, documents, deletes, reads

    def test_cleanup_waits_for_recorded_pv_and_longhorn_volume_removal(self):
        for pv, volume in [
            ({"metadata": {"uid": "original-pv-uid"}}, None),
            (None, {"metadata": {"uid": "original-volume-uid"}}),
        ]:
            with self.subTest(pv=pv, volume=volume):
                scenario, cluster, docs, deletes, _ = self.cleanup_storage_fixture(pv, volume)
                with (
                    patch.object(restore, "recheck"),
                    patch.object(scenario.time, "monotonic", side_effect=[0, 0, 181]),
                    patch.object(scenario.time, "sleep"),
                    self.assertRaises(restore.RestoreError),
                ):
                    cluster.cleanup(docs, RUN)
                self.assertEqual(deletes, ["Namespace"])

    def test_cleanup_refuses_reused_pv_or_longhorn_volume_identity(self):
        for pv, volume in [
            ({"metadata": {"uid": "replacement-pv-uid"}}, None),
            (None, {"metadata": {"uid": "replacement-volume-uid"}}),
        ]:
            with self.subTest(pv=pv, volume=volume):
                scenario, cluster, docs, deletes, _ = self.cleanup_storage_fixture(pv, volume)
                with (
                    patch.object(restore, "recheck"),
                    patch.object(scenario.time, "monotonic", side_effect=[0, 0]),
                    self.assertRaises(restore.RestoreError),
                ):
                    cluster.cleanup(docs, RUN)
                self.assertEqual(deletes, ["Namespace"])

    def test_cleanup_succeeds_only_after_both_storage_objects_are_gone(self):
        scenario, cluster, docs, deletes, reads = self.cleanup_storage_fixture(None, None)
        with (
            patch.object(restore, "recheck"),
            patch.object(scenario.time, "monotonic", side_effect=[0, 0]),
        ):
            cluster.cleanup(docs, RUN)
        self.assertEqual(deletes, ["Namespace"])
        self.assertTrue(any("pv" in args and "pvc-claim-uid" in args for args in reads))
        self.assertTrue(
            any("volumes.longhorn.io" in args and "pvc-claim-uid" in args for args in reads)
        )

    def test_storage_records_longhorn_uid_and_refuses_identity_replacement(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, b"x" * 32)
        claim = {
            "kind": "PersistentVolumeClaim",
            "metadata": {
                "uid": "claim-uid",
                "name": "scratch-data",
                "namespace": restore.namespace(RUN),
                "annotations": {restore.OWNER: RUN},
            },
            "spec": {"volumeName": "pvc-claim-uid"},
        }
        pv = {
            "metadata": {"uid": "pv-uid"},
            "spec": {
                "claimRef": {
                    "uid": "claim-uid",
                    "namespace": restore.namespace(RUN),
                    "name": "scratch-data",
                },
                "csi": {"driver": "driver.longhorn.io", "volumeHandle": "pvc-claim-uid"},
                "persistentVolumeReclaimPolicy": "Delete",
            },
        }
        volume = {
            "metadata": {
                "name": "pvc-claim-uid",
                "namespace": "longhorn-system",
                "uid": "volume-uid",
            }
        }
        cluster.created = [claim]
        cluster.read = lambda expected: claim
        cluster.json = lambda *args: pv if "pv" in args else volume
        cluster.assert_storage()
        self.assertEqual(cluster.volume_uid, "volume-uid")
        volume["metadata"]["uid"] = "replacement-volume-uid"
        with self.assertRaises(restore.RestoreError):
            cluster.assert_storage()
        self.assertEqual(cluster.volume_uid, "volume-uid")
