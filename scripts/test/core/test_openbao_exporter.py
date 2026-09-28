"""Reader evidence must be fresh, source-bound, sanitized and complete."""

import copy
import json
import unittest
from pathlib import Path

from scripts.openbao import verify
from scripts.openbao.configuration import SafeError

ROOT = Path(__file__).resolve().parents[3]
DESIRED = ROOT / "kubernetes/apps/security/openbao/config/desired.json"


class ReaderBoundaryTest(unittest.TestCase):
    def test_observer_has_no_server_exec_implementation(self):
        source = (ROOT / "scripts/openbao/reader.py").read_text()
        self.assertNotIn("'exec'", source)
        self.assertNotIn("homelab-diagnostic", source)

    def test_configuration_comparison_is_independent_of_kubernetes(self):
        self.assertTrue(callable(getattr(verify, "compare_configuration", None)))


class EvidenceTest(unittest.TestCase):
    def setUp(self):
        from scripts.openbao import exporter

        self.api = exporter
        self.digest = exporter.source_digest(DESIRED)
        self.result = {"status": "pass", "differences": []}

    def evidence(self, result=None, collected=1000):
        metrics = self.api.metric_rows(
            result or self.result, self.digest, "ready", collected, desired=DESIRED
        )
        return {
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [
                    {
                        "metric": {
                            "__name__": "openbao_configuration_observation",
                            "namespace": "openbao",
                            "service": "openbao-config-reader",
                            "endpoint": "metrics",
                            **labels,
                        },
                        "value": [1010, str(value)],
                    }
                    for labels, value in metrics
                ],
            },
        }

    def test_fresh_complete_evidence_passes(self):
        self.assertEqual(
            self.api.decode_observation(self.evidence(), DESIRED, now=1020)["status"], "pass"
        )

    def test_prometheus_omitted_empty_labels_are_accepted(self):
        evidence = self.evidence()
        for sample in evidence["data"]["result"]:
            sample["metric"] = {
                key: value for key, value in sample["metric"].items() if value != ""
            }
        self.assertEqual(
            self.api.decode_observation(evidence, DESIRED, now=1020)["status"], "pass"
        )

    def test_stale_future_duplicate_and_mismatched_evidence_fail(self):
        cases = [self.evidence(collected=1), self.evidence(collected=2000)]
        for field, value in [("digest", "b" * 64), ("state", "arbitrary-private-text")]:
            altered = self.evidence()
            altered["data"]["result"][0]["metric"][field] = value
            cases.append(altered)
        duplicate = self.evidence()
        duplicate["data"]["result"] *= 2
        cases.append(duplicate)
        empty = self.evidence()
        empty["data"]["result"] = []
        cases.append(empty)
        for case in cases:
            with self.subTest(case=case), self.assertRaises(SafeError):
                self.api.decode_observation(case, DESIRED, now=1020)

    def test_drift_details_are_bounded_by_source(self):
        result = {
            "status": "drift",
            "differences": [
                {
                    "kind": "policy",
                    "name": "openbao-backup",
                    "state": "changed",
                    "field": "policy",
                },
                {"kind": "issuance-role", "state": "unexpected", "count": 1},
            ],
        }
        decoded = self.api.decode_observation(self.evidence(result), DESIRED, now=1020)
        self.assertEqual(decoded["differences"], result["differences"])
        raw = copy.deepcopy(result)
        raw["differences"][0]["name"] = "private-marker"
        with self.assertRaises(SafeError):
            self.api.metric_rows(raw, self.digest, "ready", 1000, desired=DESIRED)

    def test_new_failure_replaces_previous_success(self):
        result = {"status": "inaccessible", "differences": []}
        self.assertEqual(
            self.api.decode_observation(self.evidence(result), DESIRED, now=1020)["status"],
            "inaccessible",
        )

    def test_collection_time_not_scrape_time_controls_freshness(self):
        value = self.evidence(collected=500)
        value["data"]["result"][0]["value"][0] = 1019
        with self.assertRaises(SafeError):
            self.api.decode_observation(value, DESIRED, now=1020)

    def test_json_and_policy_source_change_digest(self):
        import shutil
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "config"
            shutil.copytree(DESIRED.parent, target)
            original = self.api.source_digest(target / "desired.json")
            policy = target / "policies/backup.json"
            policy.write_text(policy.read_text() + "\n")
            self.assertNotEqual(original, self.api.source_digest(target / "desired.json"))


class ReaderManifestTest(unittest.TestCase):
    def test_reader_is_separate_and_has_no_issuer_or_seal_mount(self):
        import yaml

        path = ROOT / "kubernetes/apps/security/openbao/monitoring/reader.yaml"
        self.assertTrue(path.exists(), "Separate reader workload is required")
        docs = list(yaml.safe_load_all(path.read_text()))
        deployment = next(d for d in docs if d["kind"] == "Deployment")
        pod = deployment["spec"]["template"]["spec"]
        self.assertEqual(pod["serviceAccountName"], "openbao-config-reader")
        self.assertIs(pod["automountServiceAccountToken"], False)
        self.assertEqual(deployment["spec"]["replicas"], 1)
        self.assertFalse(
            any(
                "secret" in v or "hostPath" in v or "persistentVolumeClaim" in v
                for v in pod["volumes"]
            )
        )
        projected = [v for v in pod["volumes"] if "projected" in v]
        self.assertEqual(len(projected), 1)
        token = projected[0]["projected"]["sources"][0]["serviceAccountToken"]
        self.assertEqual(token["audience"], "openbao-config-verification")
        role = next(
            o
            for o in json.loads(DESIRED.read_text())["objects"]
            if o["kind"] == "jwt-role" and o["name"] == "openbao-config-reader"
        )
        self.assertEqual(
            role["fields"]["bound_subject"], "system:serviceaccount:openbao:openbao-config-reader"
        )


class CollectionTest(unittest.TestCase):
    def test_real_comparison_is_used_and_session_closed_on_failure(self):
        from scripts.openbao.exporter import collect
        from scripts.test.core.test_openbao_verify import FakeReader

        class FixtureReader(FakeReader):
            def login(self):
                return "ready"

            def close(self):
                self.closed = True

        reader = FixtureReader()
        result, health = collect(DESIRED, Path("unused"), lambda *_: reader)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(health, "ready")
        self.assertTrue(reader.closed)
        reader.fail_path = "sys/auth"
        result, health = collect(DESIRED, Path("unused"), lambda *_: reader)
        self.assertEqual(result["status"], "inaccessible")
        self.assertEqual(health, "inaccessible")
        self.assertTrue(reader.closed)

    def test_transport_rejects_unlisted_and_write_requests(self):
        from scripts.openbao.exporter import ConfigurationReader

        reader = ConfigurationReader(DESIRED, Path("unused"))
        for method, path in [
            ("POST", "sys/auth"),
            ("GET", "sys/raw/config"),
            ("POST", "kubernetes/creds/openbao-acceptance"),
        ]:
            with self.subTest(path=path), self.assertRaises(SafeError):
                reader.request(method, path)

    def test_peer_transport_uses_verified_certificate_name(self):
        from unittest.mock import Mock, patch

        from scripts.openbao.exporter import SERVER_NAME, PeerConnection

        connection = PeerConnection("openbao-0.openbao-internal.openbao.svc")
        tls = Mock()
        connection._context = tls
        with patch("socket.create_connection") as connect:
            connection.connect()
        tls.wrap_socket.assert_called_once_with(connect.return_value, server_hostname=SERVER_NAME)

    def test_bad_peer_responses_never_expose_body(self):
        from unittest.mock import Mock, patch

        from scripts.openbao.exporter import PEERS, ConfigurationReader

        reader = ConfigurationReader(DESIRED, Path("unused"))
        for status, body in [
            (403, b"private-marker"),
            (307, b"private-marker"),
            (200, b'{"data":'),
            (200, b"x" * 1048577),
        ]:
            response = Mock(status=status)
            response.read.return_value = body
            connection = Mock()
            connection.getresponse.return_value = response
            with (
                patch("scripts.openbao.exporter.PeerConnection", return_value=connection),
                self.assertRaises(SafeError) as caught,
            ):
                reader.exchange(PEERS[0], "GET", "sys/leader")
            self.assertNotIn("private-marker", str(caught.exception))
            connection.close.assert_called_once()

class MalformedRecoveryTest(unittest.TestCase):
    def test_malformed_envelope_fails_closed_and_next_collection_recovers(self):
        from scripts.openbao.exporter import ConfigurationReader, collect
        from scripts.test.core.test_openbao_verify import FakeReader
        class TransientReader(ConfigurationReader):
            broken = True
            def login(self):
                self.token = 'synthetic'; self.peer = 'openbao-0.openbao-internal.openbao.svc'
                return 'ready'
            def exchange(self, peer, method, path, payload=None):
                if self.broken:
                    self.broken = False
                    return []
                return {'data': FakeReader().request(method, path)}
            def close(self):
                self.token = None
        reader = TransientReader(DESIRED, Path('unused'))
        failed, health = collect(DESIRED, Path('unused'), lambda *_: reader)
        self.assertEqual(failed['status'], 'inaccessible')
        self.assertEqual(health, 'inaccessible')
        recovered, health = collect(DESIRED, Path('unused'), lambda *_: reader)
        self.assertEqual(recovered['status'], 'pass')
        self.assertEqual(health, 'ready')
