"""Cleanup must use the UID returned by creation, never adopt a named replacement."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / "scripts/test/lib/owned-resources.sh"


class OwnedResourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.manifest = self.directory / "manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "apiVersion": "v1",
                    "kind": "Pod",
                    "metadata": {
                        "name": "synthetic-probe",
                        "namespace": "media",
                        "labels": {"homelab-talos/run-id": "abc12345"},
                    },
                }
            )
        )
        self.created = json.loads(self.manifest.read_text())
        self.created["metadata"].update(uid="synthetic-owned", resourceVersion="12")
        (self.directory / "created.json").write_text(json.dumps(self.created))
        self.state = self.directory / "state.json"
        self.state.write_text(json.dumps(self.created))
        self.ledger = self.directory / "ledger.jsonl"
        self.log = self.directory / "calls.jsonl"
        fake = self.directory / "fake-kubectl"
        fake.write_text("""#!/bin/sh
case "$1" in
  create) cat "$FIXTURE_DIR/created.json" ;;
  get) [ ! -f "$FIXTURE_DIR/state.json" ] || cat "$FIXTURE_DIR/state.json" ;;
  delete) printf '%s\\n' "$*" >>"$FIXTURE_DIR/commands"; cat >>"$FIXTURE_DIR/calls.jsonl"; rm "$FIXTURE_DIR/state.json" ;;
  *) exit 2 ;;
esac
""")
        fake.chmod(0o700)
        self.fake = fake

    def run_shell(self, body):
        return subprocess.run(
            [
                "bash",
                "-eu",
                "-c",
                body,
                "test",
                str(HELPER),
                str(self.ledger),
                str(self.manifest),
                str(self.fake),
            ],
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "FIXTURE_DIR": str(self.directory)},
        )

    def test_create_records_only_metadata_and_cleanup_has_atomic_preconditions(self):
        self.created["data"] = {"sensitive": "SYNTHETIC_SECRET_DO_NOT_RETAIN"}
        (self.directory / "created.json").write_text(json.dumps(self.created))
        result = self.run_shell(
            'source "$1"; test_create_owned "$2" "$3" "$4"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(
            "SYNTHETIC_SECRET", self.ledger.read_text() + result.stdout + result.stderr
        )
        options = json.loads(self.log.read_text())
        self.assertEqual(
            options["preconditions"], {"uid": "synthetic-owned", "resourceVersion": "12"}
        )
        self.assertEqual(options["propagationPolicy"], "Foreground")
        self.assertIn(
            "/api/v1/namespaces/media/pods/synthetic-probe",
            (self.directory / "commands").read_text(),
        )

    def test_replacement_is_not_adopted_or_deleted(self):
        self.created["metadata"]["uid"] = "synthetic-replacement"
        self.state.write_text(json.dumps(self.created))
        result = self.run_shell(
            'source "$1"; test_create_owned "$2" "$3" "$4"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_unrecorded_name_requires_no_cluster_request(self):
        result = self.run_shell(
            'source "$1"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())

    def test_repeated_cleanup_of_a_deleted_object_is_safe(self):
        result = self.run_shell(
            'source "$1"; test_create_owned "$2" "$3" "$4"; test_delete_owned "$2" Pod media synthetic-probe "$4"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_duplicate_creation_intent_is_rejected(self):
        result = self.run_shell(
            'source "$1"; test_create_owned "$2" "$3" "$4"; test_create_owned "$2" "$3" "$4"'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.ledger.read_text().splitlines()), 1)

    def test_corrupt_ownership_record_is_a_cleanup_failure(self):
        self.ledger.write_text("corrupt\n")
        result = self.run_shell(
            'source "$1"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())
