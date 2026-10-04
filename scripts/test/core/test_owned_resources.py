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
  get) if [ -f "$FIXTURE_DIR/state.json" ]; then
    cat "$FIXTURE_DIR/state.json"
    if [ -f "$FIXTURE_DIR/replace-during-wait" ]; then
      cp "$FIXTURE_DIR/replacement.json" "$FIXTURE_DIR/state.json"
      rm "$FIXTURE_DIR/replace-during-wait"
    fi
    if [ -f "$FIXTURE_DIR/gc-pending" ]; then rm "$FIXTURE_DIR/state.json"; fi
  fi ;;
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

    def test_cleanup_refuses_a_live_object_without_a_resource_version(self):
        current = json.loads(self.state.read_text())
        del current["metadata"]["resourceVersion"]
        self.state.write_text(json.dumps(current))
        result = self.run_shell(
            'source "$1"; test_create_owned "$2" "$3" "$4"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_registered_disruption_deletes_only_the_observed_pod_uid(self):
        result = self.run_shell(
            'source "$1"; test_delete_pod_instance synthetic-owned media synthetic-probe "$4"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.ledger.exists())
        options = json.loads(self.log.read_text())
        self.assertEqual(
            options["preconditions"], {"uid": "synthetic-owned", "resourceVersion": "12"}
        )

    def test_registered_disruption_refuses_a_replaced_pod_without_deleting_it(self):
        result = self.run_shell(
            'source "$1"; test_delete_pod_instance earlier-observed-uid media synthetic-probe "$4"'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.state.exists())
        self.assertFalse(self.log.exists())

    def test_registered_disruption_cannot_prove_deletion_from_invalid_pod_identity(self):
        self.fake.write_text("""#!/bin/sh
case "$1" in
  get) cat "$FIXTURE_DIR/state.json" ;;
  delete) printf '%s\\n' '{"kind":"Pod","metadata":{}}' >"$FIXTURE_DIR/state.json" ;;
  *) exit 2 ;;
esac
""")
        result = self.run_shell(
            'source "$1"; test_delete_pod_instance synthetic-owned media synthetic-probe "$4"'
        )
        self.assertNotEqual(result.returncode, 0)

    def test_manifest_stream_creates_individually_and_records_each_api_uid(self):
        objects = [json.loads(self.manifest.read_text()), json.loads(self.manifest.read_text())]
        objects[1]["metadata"]["name"] = "synthetic-other"
        self.manifest.write_text(json.dumps(objects))
        self.fake.write_text("""#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == create && "$2" == --filename && "$4" == --output && "$5" == json ]]
printf 'create\\n' >>"$FIXTURE_DIR/creates"
yq -o=json '.metadata.uid = ("api-" + .metadata.name) | .metadata.resourceVersion = "1"' "$3"
""")
        result = self.run_shell('source "$1"; test_create_owned_stream "$2" "$4" <"$3"')
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in self.ledger.read_text().splitlines()]
        self.assertEqual(len(records), 2)
        self.assertEqual(
            [record["metadata"]["uid"] for record in records],
            ["api-synthetic-probe", "api-synthetic-other"],
        )
        self.assertEqual((self.directory / "creates").read_text(), "create\ncreate\n")

    def test_failed_stream_does_not_lose_ownership_of_previously_created_objects(self):
        obj = json.loads(self.manifest.read_text())
        self.manifest.write_text(json.dumps([obj, obj]))
        result = self.run_shell('source "$1"; test_create_owned_stream "$2" "$4" <"$3"')
        self.assertNotEqual(result.returncode, 0)
        records = [json.loads(line) for line in self.ledger.read_text().splitlines()]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["metadata"]["uid"], "synthetic-owned")

    def test_replacement_is_not_adopted_or_deleted(self):
        self.created["metadata"]["uid"] = "synthetic-replacement"
        self.state.write_text(json.dumps(self.created))
        result = self.run_shell(
            'source "$1"; test_create_owned "$2" "$3" "$4"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_cleanup_resumes_waiting_for_an_already_deleting_owned_object(self):
        pending = json.loads(self.state.read_text())
        pending["metadata"].update(
            deletionTimestamp="2026-10-02T12:00:00Z", finalizers=["foregroundDeletion"]
        )
        self.state.write_text(json.dumps(pending))
        (self.directory / "gc-pending").touch()
        result = self.run_shell(
            'source "$1"; test_create_owned "$2" "$3" "$4"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())

    def test_pending_cleanup_rejects_a_replacement_during_the_wait(self):
        pending = json.loads(self.state.read_text())
        pending["metadata"]["deletionTimestamp"] = "2026-10-02T12:00:00Z"
        self.state.write_text(json.dumps(pending))
        replacement = json.loads(self.state.read_text())
        replacement["metadata"]["uid"] = "synthetic-replacement"
        (self.directory / "replacement.json").write_text(json.dumps(replacement))
        (self.directory / "replace-during-wait").touch()
        result = self.run_shell(
            'source "$1"; test_create_owned "$2" "$3" "$4"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different object", result.stderr)
        self.assertFalse(self.log.exists())

    def test_pending_cleanup_timeout_reports_failure_without_deleting_again(self):
        pending = json.loads(self.state.read_text())
        pending["metadata"]["deletionTimestamp"] = "2026-10-02T12:00:00Z"
        self.state.write_text(json.dumps(pending))
        result = self.run_shell(
            'source "$1"; sleep() { SECONDS=$((SECONDS + 301)); }; test_create_owned "$2" "$3" "$4"; test_delete_owned "$2" Pod media synthetic-probe "$4"'
        )
        self.assertEqual(result.returncode, 124, result.stderr)
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
