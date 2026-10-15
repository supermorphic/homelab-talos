"""Invariants that keep acceptance fixtures out of production traffic and data."""

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import yaml

from scripts.test.news.production_acceptance import (
    cold_policy,
    load_live_references,
    validate_native,
    worker_fixture,
)

ROOT = Path(__file__).resolve().parents[3]


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.deployment = yaml.safe_load(
            (ROOT / "kubernetes/apps/news/graby/app/deployment.yaml").read_text()
        )

    def test_worker_keeps_runtime_restrictions_but_cannot_become_service_ready(self):
        pod = worker_fixture(self.deployment, "a" * 12, "cold")
        source = self.deployment["spec"]["template"]["spec"]
        self.assertEqual(pod["metadata"]["namespace"], "news")
        self.assertEqual(
            pod["spec"]["readinessGates"],
            [{"conditionType": "homelab.supermorphic.com/acceptance"}],
        )
        self.assertEqual(pod["spec"]["restartPolicy"], "Never")
        self.assertEqual(pod["spec"]["containers"], source["containers"])
        self.assertEqual(pod["spec"]["initContainers"], source["initContainers"])
        self.assertFalse(pod["spec"]["automountServiceAccountToken"])
        self.assertTrue(
            all(set(v) <= {"name", "configMap", "emptyDir"} for v in pod["spec"]["volumes"])
        )

    def test_cold_policy_cannot_select_the_real_or_recovery_worker(self):
        policy = cold_policy("b" * 12)
        selector = policy["spec"]["endpointSelector"]["matchLabels"]
        for phase, matches in (("cold", True), ("recovered", False)):
            pod = worker_fixture(self.deployment, "b" * 12, phase)
            labels = pod["metadata"]["labels"]
            self.assertEqual(all(labels.get(k) == v for k, v in selector.items()), matches)
        live = self.deployment["spec"]["template"]["metadata"]["labels"]
        self.assertFalse(all(live.get(k) == v for k, v in selector.items()))
        self.assertEqual(policy["spec"]["egressDeny"], [{"toEntities": ["world"]}])

    def test_fixture_refuses_foreign_names_or_sensitive_volumes(self):
        for run, phase in (("../foreign", "cold"), ("a" * 12, "production")):
            with self.assertRaises(ValueError):
                worker_fixture(self.deployment, run, phase)
        for volume in (
            {"name": "data", "persistentVolumeClaim": {"claimName": "production"}},
            {"name": "credentials", "secret": {"secretName": "production"}},
        ):
            deployment = copy.deepcopy(self.deployment)
            deployment["spec"]["template"]["spec"]["volumes"].append(volume)
            with self.assertRaises(ValueError):
                worker_fixture(deployment, "a" * 12, "cold")
        for mutate in (
            lambda d: d["spec"]["template"]["metadata"]["labels"].update(
                {"homelab-talos/news-acceptance": "foreign"}
            ),
            lambda d: d["spec"]["template"]["spec"].update(hostNetwork=True),
            lambda d: d["spec"]["template"]["spec"]["containers"][0]["securityContext"].update(
                privileged=True
            ),
        ):
            deployment = copy.deepcopy(self.deployment)
            mutate(deployment)
            with self.assertRaises(ValueError):
                worker_fixture(deployment, "a" * 12, "cold")

    def test_native_acceptance_requires_each_actual_observation(self):
        required = (
            "clean_account",
            "complete_text",
            "images",
            "captions",
            "structure",
            "links",
            "light",
            "dark",
            "read_sync_both_directions",
            "favorite_sync_both_directions",
            "reader_view_summary_tested",
            "cache_behavior_observed",
            "client_account_removed",
        )
        receipt = {
            "client": "NetNewsWire",
            "version": "7.1.5",
            "reader_view_result": "rendered",
            "cached_summary_updated": False,
            **dict.fromkeys(required, True),
        }
        self.assertFalse(validate_native(receipt)["cached_summary_updated"])
        for key in required:
            for value in (False, "true", None):
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    validate_native({**receipt, key: value})

    def test_live_references_bind_new_identity_source_and_independent_review(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.html"
            source.write_text("<article><p>Independent synthetic revision.</p></article>")
            reference = {"blocks": [{"tag": "p", "text": "Independent synthetic revision."}]}
            source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            ref_hash = hashlib.sha256(
                json.dumps(
                    reference, sort_keys=True, ensure_ascii=False, separators=(",", ":")
                ).encode()
            ).hexdigest()
            case = {
                "id": "synthetic-live-v2",
                "replaces_case_id": "synthetic-v1",
                "url": "https://example.com/article",
                "source": "source.html",
                "source_sha256": source_hash,
                "reference": reference,
                "review": {
                    "status": "reviewed",
                    "source_sha256": source_hash,
                    "reference_sha256": ref_hash,
                    "schema_segments_missing": 0,
                },
            }
            document = {"schema": 1, "corpus_sha256": "a" * 64, "cases": [case]}
            path = root / "live.json"
            path.write_text(json.dumps(document))
            originals = {"synthetic-v1": {"url": case["url"]}}
            loaded = load_live_references(path, "a" * 64, originals)
            self.assertEqual(loaded["synthetic-v1"]["id"], "synthetic-live-v2")
            for field, value in (
                ("id", "synthetic-v1"),
                ("url", "https://example.com/other"),
                ("source", "../foreign.html"),
                ("source_sha256", "0" * 64),
                ("review", {}),
            ):
                invalid = copy.deepcopy(document)
                invalid["cases"][0][field] = value
                path.write_text(json.dumps(invalid))
                with self.subTest(field=field), self.assertRaises(ValueError):
                    load_live_references(path, "a" * 64, originals)


if __name__ == "__main__":
    unittest.main()
