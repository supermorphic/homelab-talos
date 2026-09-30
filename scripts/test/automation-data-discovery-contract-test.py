#!/usr/bin/env python3
"""Metadata schema, bounds, and stability invariants."""

import copy
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
MODULE = ROOT / "scripts/lib/automation_data_inventory.py"


class DiscoveryContractTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.is_file(), "metadata contract implementation missing")
        self.api = __import__("automation_data_inventory")
        self.raw = {
            "source": "n8n",
            "schemaRevision": "n8n-2.36.7-v1",
            "observedAt": "2026-09-30T00:00:00Z",
            "status": "ok",
            "complete": True,
            "objects": [
                {
                    "kind": "credential",
                    "id": "synthetic-runtime",
                    "name": "automation-data/sample/runtime",
                    "type": "postgres",
                    "updatedAt": "2026-09-30T00:00:00Z",
                },
                {
                    "kind": "binding",
                    "id": "synthetic-binding",
                    "workflowId": "synthetic-workflow",
                    "node": "Read",
                    "credentialId": "synthetic-runtime",
                    "credentialType": "postgres",
                    "published": True,
                },
            ],
        }

    def test_complete_and_partial_are_distinct(self):
        observed = self.api.validate_observation(self.raw, "n8n")
        self.assertTrue(observed.complete)
        self.assertEqual(len(observed.objects), 2)
        partial = {
            "source": "n8n",
            "status": "unavailable",
            "complete": False,
            "errorCode": "source_unavailable",
        }
        observed = self.api.validate_observation(partial, "n8n")
        self.assertFalse(observed.complete)
        self.assertIsNone(observed.fingerprint)
        self.assertEqual(observed.objects, [])

    def test_unknown_schema_or_fields_do_not_echo_raw_secrets(self):
        for change in [
            {"schemaRevision": "unknown"},
            {"headers": "SENTINEL_SECRET"},
            {"objects": [{"kind": "credential", "id": "fixture", "data": "SENTINEL_SECRET"}]},
        ]:
            raw = self.raw | change
            with self.assertRaises(self.api.InventoryError) as caught:
                self.api.validate_observation(raw, "n8n")
            self.assertNotIn("SENTINEL_SECRET", str(caught.exception))

    def test_fingerprint_ignores_order_and_collection_time(self):
        first = self.api.validate_observation(self.raw, "n8n")
        other = copy.deepcopy(self.raw)
        other["observedAt"] = "2026-09-30T00:00:01Z"
        other["objects"].reverse()
        self.assertEqual(
            first.fingerprint, self.api.validate_observation(other, "n8n").fingerprint
        )

    def test_deletion_and_published_binding_change_fingerprint(self):
        first = self.api.validate_observation(self.raw, "n8n").fingerprint
        other = copy.deepcopy(self.raw)
        other["objects"].pop()
        self.assertNotEqual(first, self.api.validate_observation(other, "n8n").fingerprint)
        other = copy.deepcopy(self.raw)
        other["objects"][1]["credentialId"] = "synthetic-other"
        self.assertNotEqual(first, self.api.validate_observation(other, "n8n").fingerprint)

    def test_duplicate_ids_overflow_and_malformed_boolean_are_rejected(self):
        variants = [
            self.raw | {"complete": 1},
            self.raw | {"objects": self.raw["objects"] * 501},
            self.raw | {"objects": [self.raw["objects"][0]] * 2},
        ]
        for raw in variants:
            with self.assertRaises(self.api.InventoryError):
                self.api.validate_observation(raw, "n8n")

    def test_multibyte_byte_limit_is_enforced(self):
        raw = self.raw | {"padding": "é" * 600000}
        with self.assertRaises(self.api.InventoryError) as caught:
            self.api.validate_observation(raw, "n8n")
        self.assertEqual(str(caught.exception), "limit_exceeded")


if __name__ == "__main__":
    unittest.main()
