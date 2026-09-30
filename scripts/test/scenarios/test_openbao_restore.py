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
    def test_rejected_snapshot_password_can_be_corrected_once_without_restore_retry(self):
        from scripts.test.scenarios import openbao_restore as scenario

        calls = []
        responses = iter([(400, {"authentication_failed": True}),
                          (200, {"auth": {"client_token": MARKER}}),
                          (400, {"authentication_failed": True})])

        def http(method, path, **kwargs):
            calls.append((method, path, kwargs))
            return next(responses)

        client = scenario.ScratchClient(type("Kube", (), {"http": staticmethod(http)})(),
                                        "synthetic-mistyped-password")
        client.wait_unsealed = lambda: None
        with patch.object(scenario, "private_prompt", return_value="synthetic-correct-password") as prompt:
            client.login_retained()
            self.assertEqual(client.token, MARKER)
            self.assertEqual(client.password, "synthetic-correct-password")
            with self.assertRaises(scenario.guards.SafeError) as raised:
                client.login_retained()
            self.assertEqual(str(raised.exception), "authentication-failed")
            self.assertEqual(prompt.call_count, 1)
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(method == "POST" and path ==
                            "auth/homelab-userpass/login/openbao-operator"
                            and kwargs.get("token") is None for method, path, kwargs in calls))

    def test_password_correction_requires_exact_rejection_and_nonempty_input(self):
        from scripts.test.scenarios import openbao_restore as scenario

        for status, body in ((400, {}), (403, {"authentication_failed": True}),
                             (500, {"authentication_failed": True})):
            kube = type("Kube", (), {"http": lambda *a, status=status, body=body, **kw: (status, body)})()
            client = scenario.ScratchClient(kube, MARKER)
            client.wait_unsealed = lambda: None
            with patch.object(scenario, "private_prompt") as prompt, self.assertRaises(restore.RestoreError):
                client.login_retained()
            prompt.assert_not_called()
        kube = type("Kube", (), {"http": lambda *a, **kw: (400, {"authentication_failed": True})})()
        client = scenario.ScratchClient(kube, MARKER)
        client.wait_unsealed = lambda: None
        with patch.object(scenario, "private_prompt", return_value=""), self.assertRaises(scenario.guards.SafeError):
            client.login_retained()

    def test_bridge_sanitizes_only_exact_userpass_rejection(self):
        from scripts.test.scenarios import openbao_restore as scenario

        login = "auth/homelab-userpass/login/openbao-operator"
        for status, errors, method, path, expected in (
            (400, ["invalid username or password"], "POST", login, {"authentication_failed": True}),
            (400, [MARKER], "POST", login, {}),
            (400, ["invalid username or password"], "GET", login, {}),
            (400, ["invalid username or password"], "POST", "sys/init", {}),
            (403, ["invalid username or password"], "POST", login, {}),
        ):
            response = type("Response", (), {"status": status,
                "read": lambda self, limit, errors=errors: json.dumps({"errors": errors}).encode()})()
            connection = type("Connection", (), {"request": lambda *a: None,
                "getresponse": lambda self, response=response: response})()
            source = io.TextIOWrapper(io.BytesIO(
                json.dumps({"method": method, "path": path}).encode() + b"\n"))
            output = io.StringIO()
            with patch("sys.stdin", source), patch("sys.stdout", output), patch("http.client.HTTPConnection", return_value=connection):
                exec(scenario.BRIDGE, {})  # noqa: S102 -- Synthetic transport only.
            self.assertEqual(json.loads(output.getvalue())["body"], expected)
            self.assertNotIn(MARKER, output.getvalue())

    def test_scratch_probe_retains_status_and_seal_flags_without_body_or_token(self):
        from scripts.test.scenarios import openbao_restore as scenario

        kube = scenario.ScratchKube(Path("/synthetic/config"), RUN, {}, b"x" * 32)
        kube.assert_pod = lambda uid: None
        response = {"status": 200, "body": {
            "initialized": True, "sealed": True, "cluster_id": MARKER, "token": MARKER}}
        kube.command = lambda *args, **kwargs: json.dumps(response).encode()
        kube.http("GET", "sys/seal-status", token=MARKER)
        self.assertEqual(getattr(kube, "probe", None), {
            "method": "GET", "status": 200, "initialized": True, "sealed": True})
        response["status"] = 403
        kube.http("POST", "auth/homelab-userpass/login/openbao-operator",
                  payload={"password": MARKER})
        self.assertEqual(kube.probe, {"method": "POST", "status": 403})

        def fail(*args, **kwargs):
            raise RuntimeError(MARKER)

        kube.command = fail
        with self.assertRaises(RuntimeError):
            kube.http("GET", "sys/seal-status")
        self.assertEqual(kube.probe, {"method": "GET"})
        self.assertNotIn(MARKER, json.dumps(kube.probe))

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
                "getresponse": lambda self, response=response: response})()
            source = io.TextIOWrapper(io.BytesIO(
                json.dumps({"method": "GET", "path": path}).encode() + b"\n"))
            output = io.StringIO()
            with (patch("sys.stdin", source), patch("sys.stdout", output),
                  patch("http.client.HTTPConnection", return_value=connection)):
                exec(scenario.BRIDGE, {})  # noqa: S102 -- Repository bridge against synthetic transport only.
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

    def test_failure_identifies_operation_without_private_exception_or_response(self):
        for operation, stage in (
            ("initialize", "initialize-scratch"),
            ("wait_unsealed", "initial-unseal"),
            ("force_restore", "force-restore"),
            ("login_retained", "restored-login"),
            ("restored_configuration", "restored-configuration"),
        ):
            with self.subTest(operation=operation):
                self.kube = Cluster()
                self.client = Client(self.kube)

                def fail(*args):
                    raise RuntimeError(MARKER)

                setattr(self.client, operation, fail)
                result = self.run_drill()
                self.assertEqual(result.get("stage"), stage)
                self.assertEqual(result["cleanup"], "passed")
                self.assertNotIn(MARKER, json.dumps(result))

    def test_failure_retains_only_fixed_transport_classification(self):
        from scripts.openbao.configuration import SafeError

        def fail(*args):
            raise SafeError("timeout")

        self.client.force_restore = fail
        result = self.run_drill()
        self.assertEqual(result.get("classification"), "timeout")
        self.assertEqual(result["cleanup"], "passed")

    def test_failed_report_filters_probe_values_and_extra_fields(self):
        def fail(*args):
            raise RuntimeError(MARKER)

        self.client.force_restore = fail
        for status, expected in ((403, {"status": 403}), (True, {}), (MARKER, {})):
            self.kube.probe = {
                "method": "POST", "status": status, "sealed": MARKER,
                "initialized": True, "body": MARKER, "token": MARKER, "path": MARKER,
            }
            self.kube.objects.clear()
            result = self.run_drill()
            self.assertEqual(result.get("last_http_probe"), {
                "method": "POST", "initialized": True, **expected})
            self.assertNotIn(MARKER, json.dumps(result))

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

    def test_cleanup_accepts_only_cilium_endpoint_for_the_current_scratch_pod(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, b"x" * 32)
        cluster.pod_uid = "current-scratch-pod"
        cluster.command = lambda *a, **kw: b"ciliumendpoints.cilium.io\n"
        # Cilium's real Pod owner shape omits controller and blockOwnerDeletion.
        endpoint = {"apiVersion": "cilium.io/v2", "kind": "CiliumEndpoint", "metadata": {
            "name": "scratch-0", "namespace": cluster.namespace, "uid": "endpoint-fixture",
            "ownerReferences": [{"apiVersion": "v1", "kind": "Pod", "name": "scratch-0",
                                 "uid": cluster.pod_uid}]}}
        value = copy.deepcopy(endpoint)
        cluster.json = lambda *a: {"items": [value]}
        cluster.cleanup_inventory()
        for mutation in (
            lambda m: m["metadata"].update(name="other-pod"),
            lambda m: m["metadata"].update(namespace="other-namespace"),
            lambda m: m["metadata"]["ownerReferences"][0].update(uid="previous-scratch-pod"),
            lambda m: m["metadata"].update(annotations={restore.OWNER: "other-run"}),
            lambda m: m.update(kind="OtherResource"),
            lambda m: m.update(apiVersion="other.example/v1"),
            lambda m: m["metadata"].update(ownerReferences=[]),
        ):
            value = copy.deepcopy(endpoint)
            mutation(value)
            with self.subTest(metadata=value["metadata"]), self.assertRaises(restore.RestoreError):
                cluster.cleanup_inventory()
        value = copy.deepcopy(endpoint)
        cluster.command = lambda *a, **kw: b"jobs.batch\n"
        with self.assertRaises(restore.RestoreError):
            cluster.cleanup_inventory()

    def test_cleanup_ignores_metrics_view_but_still_checks_the_stored_pod(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, None)
        cluster.pod_uid = "current-scratch-pod"
        cluster.command = lambda *a, **kw: b"pods.metrics.k8s.io\npods\n"
        listed = []
        def objects(*args):
            kind = args[3]
            listed.append(kind)
            if kind == "pods.metrics.k8s.io":
                return {"items": [{"apiVersion": "metrics.k8s.io/v1beta1", "kind": "PodMetrics",
                                   "metadata": {"name": "scratch-0", "namespace": cluster.namespace}}]}
            return {"items": [{"kind": "Pod", "metadata": {"name": "scratch-0",
                "uid": cluster.pod_uid, "annotations": {restore.OWNER: RUN}}}]}
        cluster.json = objects
        cluster.cleanup_inventory()
        self.assertEqual(listed, ["pods"])
        cluster.json = lambda *a: {"items": [{"kind": "Pod", "metadata": {
            "name": "foreign", "uid": "foreign-uid"}}]}
        with self.assertRaises(restore.RestoreError):
            cluster.cleanup_inventory()
        self.assertEqual(cluster.cleanup_resource, "pods")

    def test_cleanup_retry_returns_resource_context_without_adapter_exception_text(self):
        from scripts.test.scenarios import openbao_restore as scenario

        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp).resolve() / "config"
            config.write_text("synthetic")
            cluster = scenario.ScratchKube(config, RUN, {}, None)
            def reject(kube):
                kube.cleanup_stage = "inventory"
                kube.cleanup_resource = "jobs.batch"
                raise RuntimeError(MARKER)
            with patch.dict("os.environ", {"OPENBAO_OPERATOR_KUBECONFIG": str(config)}), patch.object(scenario.guards, "source_revision", return_value="a" * 40), patch.object(scenario.guards, "require_deployed_revision"), patch.object(scenario, "ScratchKube", return_value=cluster), patch.object(scenario, "cleanup_target", side_effect=reject), patch("builtins.print") as output:
                self.assertEqual(scenario.cleanup_main(RUN), 1)
            result = json.loads(output.call_args.args[0])
            self.assertEqual(result["stage"], "inventory")
            self.assertEqual(result["cleanup_resource"], "jobs.batch")
            self.assertNotIn(MARKER, json.dumps(result))

    def test_recorded_restore_keeps_sanitized_cleanup_context(self):
        fixture = RestoreTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.kube.fail_cleanup = True
        fixture.kube.cleanup_stage = "inventory"
        fixture.kube.cleanup_resource = "jobs.batch"
        result = fixture.run_drill()
        self.assertEqual(result["cleanup"], "failed")
        self.assertEqual(result["cleanup_stage"], "inventory")
        self.assertEqual(result["cleanup_resource"], "jobs.batch")
        self.assertNotIn(MARKER, json.dumps(result))

    def test_cleanup_retry_reconstructs_only_reviewed_owned_objects(self):
        from scripts.test.scenarios import openbao_restore as scenario

        cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, None)
        actual = {}
        for document in restore.documents(RUN, "2.7.0"):
            value = copy.deepcopy(document)
            value["metadata"]["uid"] = document["kind"] + "-fixture"
            actual[(document["kind"], document["metadata"]["name"])] = value
        for kind, name in (("Secret", "scratch-seal"), ("ConfigMap", "scratch-config")):
            actual[(kind, name)] = {"kind": kind, "apiVersion": "v1", "immutable": True,
                "metadata": {"name": name, "namespace": cluster.namespace, "uid": name + "-fixture",
                             "annotations": {restore.OWNER: RUN}}, "data": {"private": MARKER}}
        cluster.read = lambda d: copy.deepcopy(actual[(d["kind"], d["metadata"]["name"])])
        cluster.json = lambda *a: {"metadata": {"uid": "current-scratch-pod"}}
        checks = []
        cluster.assert_pod = lambda uid: checks.append(("pod", uid))
        cluster.assert_storage = lambda: checks.append(("storage", None))
        cluster.cleanup_inventory = lambda: checks.append(("inventory", None))
        documents = scenario.cleanup_target(cluster)
        self.assertEqual(len(documents), 5)
        self.assertEqual(cluster.pod_uid, "current-scratch-pod")
        self.assertEqual(checks, [("pod", "current-scratch-pod"), ("storage", None), ("inventory", None)])
        self.assertNotIn(MARKER, json.dumps(cluster.created))
        actual[("Namespace", cluster.namespace)]["metadata"]["annotations"][restore.OWNER] = "other-run"
        with self.assertRaises(restore.RestoreError):
            scenario.cleanup_target(cluster)

    def test_cleanup_retry_refuses_spec_changes_or_nonimmutable_private_objects(self):
        from scripts.test.scenarios import openbao_restore as scenario

        for changed_kind in ("StatefulSet", "Secret"):
            with self.subTest(kind=changed_kind):
                cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, None)
                def read(document, changed_kind=changed_kind):
                    value = copy.deepcopy(document)
                    value["metadata"]["uid"] = "synthetic-" + document["kind"]
                    if document["kind"] == changed_kind:
                        if changed_kind == "StatefulSet":
                            value["spec"]["template"]["spec"]["automountServiceAccountToken"] = True
                        else:
                            value["immutable"] = False
                    return value
                cluster.read = read
                with self.assertRaises(restore.RestoreError):
                    scenario.cleanup_target(cluster)

    def test_cleanup_retry_requires_bound_confirmation_and_never_rewrites_evidence(self):
        from scripts.test.scenarios import openbao_restore as scenario

        for correct in (False, True):
            with self.subTest(confirmation=correct), tempfile.TemporaryDirectory() as temp:
                config = Path(temp).resolve() / "operator-config"
                config.write_text("synthetic-config")
                cluster = scenario.ScratchKube(config, RUN, {}, None)
                documents = restore.documents(RUN, "2.7.0")
                for document in documents:
                    document["metadata"]["uid"] = "synthetic-" + document["kind"]
                cluster.created = documents
                cluster.pod_uid = "synthetic-pod"
                target = {"objects": [d["metadata"] for d in documents], "pod_uid": cluster.pod_uid,
                          "pv_uid": None, "volume_uid": None}
                confirmation = f"cleanup:openbao-restore:{RUN}:{scenario.guards.digest(target)}"
                with patch.dict("os.environ", {"OPENBAO_OPERATOR_KUBECONFIG": str(config)}), patch.object(scenario.guards, "source_revision", return_value="a" * 40), patch.object(scenario.guards, "require_deployed_revision"), patch.object(scenario, "ScratchKube", return_value=cluster), patch.object(scenario, "cleanup_target", return_value=documents), patch("builtins.input", return_value=confirmation if correct else "incorrect"), patch("builtins.print"), patch.object(cluster, "cleanup") as cleanup, patch.object(scenario, "atomic_write_json") as evidence:
                    self.assertEqual(scenario.cleanup_main(RUN), 0 if correct else 1)
                self.assertEqual(cleanup.call_count, 1 if correct else 0)
                evidence.assert_not_called()

    def test_cleanup_rechecks_approved_specs_and_uids_before_deletion(self):
        from scripts.test.scenarios import openbao_restore as scenario

        for changed in ("spec", "uid"):
            with self.subTest(changed=changed):
                cluster = scenario.ScratchKube(Path("/synthetic/operator-config"), RUN, {}, None)
                documents = restore.documents(RUN, "2.7.0")
                documents = [d for d in documents if d["kind"] in {"Namespace", "StatefulSet"}]
                for d in documents:
                    d["metadata"]["uid"] = "original-" + d["kind"]
                cluster.created = copy.deepcopy(documents)
                actual = copy.deepcopy(documents)
                if changed == "spec":
                    actual[1]["spec"]["template"]["spec"]["automountServiceAccountToken"] = True
                else:
                    actual[1]["metadata"]["uid"] = "replacement-sts"
                cluster.read = lambda d, actual=actual: next(a for a in actual if a["kind"] == d["kind"])
                cluster.cleanup_inventory = lambda: None
                cluster.command = lambda *a, **kw: b""
                with patch.object(restore, "recheck"), patch.object(cluster, "delete") as delete, self.assertRaises(restore.RestoreError):
                    cluster.cleanup(documents, RUN)
                delete.assert_not_called()

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
        for document in documents:
            document["metadata"]["annotations"] = {restore.OWNER: RUN}
        cluster.read = lambda expected: copy.deepcopy(expected)
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
