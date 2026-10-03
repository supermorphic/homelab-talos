"""Independent filesystem and SQLite invariants for the attended fixture probe."""

import base64
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mylar3_acceptance as scenario
from mylar3_acceptance import PROBE, Acceptance, ScenarioFailure, validate_fixture


class ReplacementSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.run_dir = Path(self.temp.name)
        self.acceptance = Acceptance("synthetic-config", {}, self.run_dir)
        self.deleted = False
        self.pod = {
            "metadata": {
                "name": "mylar3-original",
                "uid": "original",
                "ownerReferences": [
                    {"controller": True, "kind": "ReplicaSet", "name": "mylar3-rs", "uid": "rs"}
                ],
            },
            "spec": {"nodeName": "node-a"},
            "status": {"conditions": [{"type": "Ready", "status": "True"}]},
        }

    def call(self, *args, **kwargs):
        if args[0] == "auth":
            return "yes"
        if args[0] == "delete":
            self.deleted = True
            self.assertEqual(json.loads(kwargs["data"])["preconditions"], {"uid": "original"})
            raise ScenarioFailure("synthetic rejected deletion")
        if "pods" in args:
            return json.dumps({"items": [self.pod]})
        if "pvc" in args:
            return json.dumps(
                {
                    "spec": {"storageClassName": "longhorn", "volumeName": "volume"},
                    "status": {"phase": "Bound"},
                }
            )
        if "deployment" in args:
            return json.dumps(
                {
                    "metadata": {"uid": "deployment"},
                    "spec": {"replicas": 1, "strategy": {"type": "Recreate"}},
                }
            )
        if "replicaset" in args:
            return json.dumps(
                {
                    "metadata": {
                        "uid": "rs",
                        "ownerReferences": [
                            {"controller": True, "kind": "Deployment", "uid": "deployment"}
                        ],
                    }
                }
            )
        raise AssertionError(args)

    def test_failed_final_admission_prevents_deletion(self):
        with (
            patch.object(self.acceptance, "call", side_effect=self.call),
            patch.object(self.acceptance, "probe", return_value={}),
            patch.object(
                self.acceptance,
                "admit_deletion",
                side_effect=ScenarioFailure("admission changed"),
            ),
            patch.object(
                self.acceptance, "ready_after", side_effect=ScenarioFailure("no replacement")
            ),
            self.assertRaises(ScenarioFailure),
        ):
            self.acceptance.run()
        self.assertFalse(self.deleted)

    def test_rejected_delete_preserves_healthy_original(self):
        with (
            patch.object(self.acceptance, "call", side_effect=self.call),
            patch.object(self.acceptance, "probe", return_value={}),
            patch.object(self.acceptance, "admit_deletion"),
            patch.object(
                self.acceptance, "ready_after", side_effect=ScenarioFailure("no replacement")
            ),
            self.assertRaises(ScenarioFailure),
        ):
            self.acceptance.run()
        self.assertTrue(self.deleted)
        self.assertEqual(
            json.loads((self.run_dir / "recovery.json").read_text())["status"], "passed"
        )


class FixtureValidation(unittest.TestCase):
    def test_scoped_paths(self):
        valid = {
            "download_path": "/data/downloads/comics/fixture.cbz",
            "library_path": "/data/media/comics/fixture.cbz",
            "issue_id": "1",
        }
        self.assertEqual(validate_fixture(valid), valid)
        for replacement in (
            "/config/mylar/config.ini",
            "/data/downloads/comics-other/a.cbz",
            "/data/downloads/comics/../a.cbz",
            "/data/downloads/comics//a.cbz",
            "/data/downloads/comics/a.txt",
        ):
            with self.subTest(path=replacement), self.assertRaises(ScenarioFailure):
                validate_fixture(dict(valid, download_path=replacement))

    def test_private_input_schema(self):
        for value in ({}, None, {"apiKey": "synthetic"}):
            with self.subTest(value=value), self.assertRaises(ScenarioFailure):
                validate_fixture(value)


class IntegritySafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.run_dir = Path(self.temp.name)
        self.acceptance = Acceptance("synthetic-config", {}, self.run_dir)

    def test_read_only_verification_retains_no_digest_or_paths(self):
        calls = []

        def call(*args, **kwargs):
            calls.append(args)
            if args[0] == "auth":
                return "yes"
            raise AssertionError("unexpected operation")

        with (
            patch.object(self.acceptance, "call", side_effect=call),
            patch.object(self.acceptance, "pod", return_value={}),
            patch.object(
                self.acceptance,
                "probe",
                return_value={"digest": "private", "bytes": 1024, "pages": 2, "links": 2},
            ),
        ):
            self.acceptance.verify_integrity()
        evidence = (self.run_dir / "diagnostics" / "mylar3-integrity.json").read_text()
        self.assertNotIn("private", evidence)
        self.assertEqual(json.loads(evidence)["minimumLinkCount"], 2)
        self.assertEqual(
            calls,
            [("auth", "can-i", "create", "pods", "--subresource=exec", "-n", "media")],
        )

    def test_denied_exec_never_reads_fixture(self):
        with (
            patch.object(self.acceptance, "call", return_value="no"),
            patch.object(self.acceptance, "probe") as probe,
            self.assertRaises(ScenarioFailure),
        ):
            self.acceptance.verify_integrity()
        probe.assert_not_called()

    def test_replacement_checks_exec_subresource(self):
        with (
            patch.object(self.acceptance, "call", return_value="no") as call,
            self.assertRaises(ScenarioFailure),
        ):
            self.acceptance.run()
        self.assertEqual(
            call.call_args.args,
            ("auth", "can-i", "create", "pods", "--subresource=exec", "-n", "media"),
        )

    def test_integrity_entrypoint_never_replaces_pod(self):
        fixture = self.run_dir / "fixture.json"
        fixture.write_text(
            json.dumps(
                {
                    "download_path": "/data/downloads/comics/fixture.cbz",
                    "library_path": "/data/media/comics/fixture.cbz",
                    "issue_id": "1",
                }
            )
        )
        with (
            patch.object(sys, "argv", ["scenario", "synthetic", "--integrity-only"]),
            patch.dict(
                os.environ,
                {
                    "HOMELAB_TEST_RUN_DIR": str(self.run_dir),
                    "MYLAR_ACCEPTANCE_FIXTURE": str(fixture),
                },
            ),
            patch.object(scenario, "install_interrupt_handlers"),
            patch.object(Acceptance, "verify_integrity") as verify,
            patch.object(Acceptance, "run", side_effect=AssertionError("pod replacement")),
        ):
            self.assertEqual(scenario.main(), 0)
        verify.assert_called_once()

    def test_unknown_mode_never_runs_acceptance(self):
        with (
            patch.object(sys, "argv", ["scenario", "synthetic", "--unknown-mode"]),
            patch.dict(os.environ, {"HOMELAB_TEST_RUN_DIR": str(self.run_dir)}),
            patch.object(scenario, "install_interrupt_handlers"),
            patch.object(Acceptance, "verify_integrity") as verify,
            patch.object(Acceptance, "run") as replace,
        ):
            self.assertEqual(scenario.main(), 1)
        verify.assert_not_called()
        replace.assert_not_called()


class ProbeInvariants(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.downloads = self.root / "downloads"
        self.library = self.root / "library"
        self.downloads.mkdir()
        self.library.mkdir()
        self.source = self.downloads / "fixture.cbz"
        self.target = self.library / "fixture.cbz"
        # A synthetic one-pixel PNG, with an independently generated ZIP archive.
        png = base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
        )
        with zipfile.ZipFile(self.source, "w") as archive:
            archive.writestr("001.png", png)
        os.link(self.source, self.target)
        self.db = self.root / "mylar.db"
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute(
                "CREATE TABLE issues (IssueID TEXT, Status TEXT, Location TEXT, ComicID TEXT)"
            )
            connection.execute("CREATE TABLE comics (ComicID TEXT, ComicLocation TEXT)")
            connection.execute("INSERT INTO issues VALUES ('1', 'Downloaded', 'fixture.cbz', '1')")
            connection.execute("INSERT INTO comics VALUES ('1', ?)", (str(self.library),))
        self.probe = (
            PROBE.replace("/data/downloads/comics", str(self.downloads))
            .replace("/data/media/comics", str(self.library))
            .replace("/config/mylar/mylar.db", str(self.db))
        )

    def run_probe(self):
        payload = {
            "download_path": str(self.source),
            "library_path": str(self.target),
            "issue_id": "1",
        }
        return subprocess.run(
            [sys.executable, "-c", self.probe],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

    def test_real_hardlink_archive_and_downloaded_record(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads(result.stdout)
        self.assertEqual(evidence["pages"], 1)
        self.assertGreaterEqual(evidence["links"], 2)

    def test_identical_copy_is_not_a_hardlink(self):
        self.target.unlink()
        self.target.write_bytes(self.source.read_bytes())
        self.assertNotEqual(self.run_probe().returncode, 0)

    def test_snatched_is_not_downloaded(self):
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute("UPDATE issues SET Status = 'Snatched'")
        self.assertNotEqual(self.run_probe().returncode, 0)

    def test_symlink_is_rejected(self):
        self.target.unlink()
        self.target.symlink_to(self.source)
        self.assertNotEqual(self.run_probe().returncode, 0)

    def test_unrelated_issue_location_is_rejected(self):
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute("UPDATE issues SET Location = 'other.cbz'")
        self.assertNotEqual(self.run_probe().returncode, 0)


if __name__ == "__main__":
    unittest.main()
