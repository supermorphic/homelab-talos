#!/usr/bin/env python3
"""Verifier summaries retain completeness without publishing identity metadata."""

import contextlib
import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from automation_data_inventory import InventoryEnvelope

spec = importlib.util.spec_from_file_location(
    "discovery_summary", ROOT / "scripts/operations/automation-data-discovery-summary.py"
)
command = importlib.util.module_from_spec(spec)
spec.loader.exec_module(command)


class SummaryTests(unittest.TestCase):
    def test_partial_enumeration_cannot_report_complete_or_absent(self):
        sources = [
            {
                "source": source,
                "complete": source != "n8n",
                "objectCount": 2,
                "observedAt": "2026-09-30T00:00:00+00:00",
                "errorCode": None,
            }
            for source in ["platform", "nocodb", "n8n"]
        ]
        result = command.summarize(InventoryEnvelope(sources=sources))
        self.assertEqual(result["status"], "partial")
        self.assertFalse(result["sources"][-1]["complete"])

    def test_only_summary_fields_cross_verifier_boundary(self):
        sources = [
            {
                "source": source,
                "complete": True,
                "objectCount": 0,
                "observedAt": "2026-09-30T00:00:00+00:00",
                "errorCode": None,
                "id": "SENTINEL",
                "objects": [{"password": "SENTINEL"}],
            }
            for source in ["platform", "nocodb", "n8n"]
        ]
        result = command.summarize(
            InventoryEnvelope(
                sources=sources,
                items=[{"id": "SENTINEL"}],
                discrepancies=[{"identity": "SENTINEL"}],
            )
        )
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["discrepancyCount"], 1)
        self.assertNotIn("SENTINEL", json.dumps(result))
        self.assertEqual(set(result), {"schemaVersion", "status", "sources", "discrepancyCount"})

    def test_unenrolled_or_failed_transport_preserves_health_exit_and_fixed_diagnostic(self):
        output = io.StringIO()
        with (
            patch.object(command, "load_access_config", side_effect=RuntimeError("SENTINEL")),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(command.main(), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(len(result["sources"]), 3)
        self.assertNotIn("SENTINEL", output.getvalue())

    def test_both_existing_verifiers_observe_summary_separately(self):
        for name in ["automation-data", "nocodb"]:
            text = (ROOT / f"scripts/verify/{name}.sh").read_text()
            self.assertIn(
                "uv run --locked python scripts/operations/automation-data-discovery-summary.py",
                text,
            )
            self.assertIn("credential-discovery evidence", text)


if __name__ == "__main__":
    unittest.main()
