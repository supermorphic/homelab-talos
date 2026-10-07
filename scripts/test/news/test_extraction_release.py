"""Independent release and private corpus promotion invariants."""

from __future__ import annotations

import copy
import hashlib
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

from scripts.repository.news_extraction_release import verify_candidate
from scripts.test.news.extraction_corpus import (
    assess,
    export_archive,
    retrieve_archive,
    validate_corpus,
)


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.candidate = {
            "id": "a" * 64,
            "rules": {"commit": "b" * 40},
            "corpus": {
                "sha256": "c" * 64,
                "cases": ["original-1", "broader-1"],
                "quality": {
                    "original-1": {"blocks": 2, "images": 1, "captions": 1, "excluded": 0}
                },
            },
        }
        unsigned = {key: value for key, value in self.candidate.items() if key != "id"}
        self.candidate["id"] = hashlib.sha256(
            json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        self.evidence = {
            phase: {
                "schema": 1,
                "phase": phase,
                "status": "pass",
                "release_id": self.candidate["id"],
                "rules_commit": "b" * 40,
            }
            for phase in ("initialization", "runtime", "ingestion")
        }
        self.evidence["runtime"]["checks"] = ["fetch", "extraction", "service"]
        self.evidence["corpus"] = {
            **self.evidence["runtime"],
            "phase": "corpus",
            "corpus_sha256": "c" * 64,
            "cases": [
                {"id": case, "status": "pass"} for case in self.candidate["corpus"]["cases"]
            ],
        }
        self.evidence["corpus"]["cases"][0].update(
            {
                "pass": True,
                "editorial_blocks": 2,
                "editorial_images": 1,
                "editorial_captions": 1,
                "missing_blocks": 0,
                "unexpected_blocks": 0,
                "excluded_blocks_checked": 0,
                "missing_images": 0,
                "missing_captions": 0,
                "missing_structures": 0,
                "order_preserved": True,
            }
        )
        self.evidence["retention"] = {
            "status": "pass",
            "corpus_sha256": "c" * 64,
            "private": True,
            "durable": True,
            "retrieved_sha256": "c" * 64,
        }

    def test_complete_matching_gate(self):
        self.assertTrue(verify_candidate(self.candidate, self.evidence))

    def test_missing_failed_or_other_release_never_promotes(self):
        for phase in ("initialization", "runtime", "ingestion", "corpus", "retention"):
            evidence = copy.deepcopy(self.evidence)
            del evidence[phase]
            self.assertFalse(verify_candidate(self.candidate, evidence))
        for field, value in (
            ("status", "fail"),
            ("release_id", "d" * 64),
            ("rules_commit", "e" * 40),
        ):
            evidence = copy.deepcopy(self.evidence)
            evidence["runtime"][field] = value
            self.assertFalse(verify_candidate(self.candidate, evidence))

    def test_modified_code_member_with_old_identity_blocks(self):
        candidate = copy.deepcopy(self.candidate)
        candidate["files"] = {"runtime.php": "e" * 64}
        self.assertFalse(verify_candidate(candidate, self.evidence))

    def test_omitted_duplicate_or_failed_sample_blocks(self):
        for cases in (
            self.evidence["corpus"]["cases"][:1],
            self.evidence["corpus"]["cases"] * 2,
            [{"id": "original-1", "status": "fail"}, {"id": "broader-1", "status": "pass"}],
        ):
            evidence = copy.deepcopy(self.evidence)
            evidence["corpus"]["cases"] = cases
            self.assertFalse(verify_candidate(self.candidate, evidence))

    def test_partial_successful_looking_report_blocks(self):
        for field, value in (
            ("pass", False),
            ("missing_blocks", 1),
            ("editorial_blocks", 1),
            ("order_preserved", False),
        ):
            evidence = copy.deepcopy(self.evidence)
            evidence["corpus"]["cases"][0][field] = value
            self.assertFalse(verify_candidate(self.candidate, evidence))

    def test_local_retention_is_not_durable_acceptance(self):
        for field in ("private", "durable"):
            evidence = copy.deepcopy(self.evidence)
            evidence["retention"][field] = False
            self.assertFalse(verify_candidate(self.candidate, evidence))

    def test_complete_article_with_reviewed_chrome_or_comments_fails(self):
        reference = {
            "blocks": [{"tag": "p", "text": "Complete editorial paragraph."}],
            "excluded_blocks": [
                "Synthetic navigation directory and account controls.",
                "Off-topic reader discussion from the source page.",
            ],
        }
        body = "<p>Complete editorial paragraph.</p>"
        self.assertTrue(assess(body, reference)["pass"])
        for extra in (
            "<nav>Unrelated site directory</nav>",
            "<p>Synthetic navigation directory and account controls.</p>",
            "<p>Off-topic reader discussion from the source page.</p>",
        ):
            with self.subTest(extra=extra):
                self.assertFalse(assess(body + extra, reference)["pass"])

    def test_editorial_oracle_rejects_successful_partial_body(self):
        reference = {
            "blocks": [
                {"tag": "p", "text": "First editorial paragraph."},
                {"tag": "h2", "text": "Important heading"},
                {"tag": "p", "text": "Second editorial paragraph."},
            ],
            "images": ["/illustration.jpg"],
            "captions": ["Independent photographer credit."],
        }
        complete = '<h2>Important heading</h2><p>First editorial paragraph.</p><figure><img src="https://fixture.example/illustration.jpg"/><figcaption>Independent photographer credit.</figcaption></figure><p>Second editorial paragraph.</p>'
        self.assertTrue(assess(complete, reference)["pass"])
        self.assertFalse(
            assess(complete.replace("Second editorial paragraph.", ""), reference)["pass"]
        )
        self.assertFalse(
            assess(complete.replace("Independent photographer credit.", ""), reference)["pass"]
        )
        self.assertFalse(
            assess(complete.replace("/illustration.jpg", "/unrelated.jpg"), reference)["pass"]
        )

    def test_missing_or_tampered_corpus_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                validate_corpus(root)
            (root / "case.html").write_text("synthetic")
            manifest = {
                "schema": 1,
                "cases": [
                    {
                        "id": "fixture",
                        "html": "case.html",
                        "sha256": hashlib.sha256(b"synthetic").hexdigest(),
                    }
                ],
                "original_ids": ["fixture"],
                "reviews": {},
            }
            (root / "manifest.json").write_text(json.dumps(manifest))
            validate_corpus(root)
            (root / "case.html").write_text("changed")
            with self.assertRaises(ValueError):
                validate_corpus(root)

    def test_private_archive_round_trip_and_link_rejection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "input"
            root.mkdir()
            (root / "case.html").write_bytes(b"independent synthetic fixture")
            manifest = {
                "schema": 1,
                "cases": [
                    {
                        "id": "fixture",
                        "html": "case.html",
                        "sha256": hashlib.sha256(b"independent synthetic fixture").hexdigest(),
                    }
                ],
                "original_ids": ["fixture"],
                "reviews": {},
            }
            (root / "manifest.json").write_text(json.dumps(manifest))
            archive = root.parent / "private.tar.gz"
            receipt = export_archive(root, archive)
            retrieved = root.parent / "retrieved"
            result = retrieve_archive(archive, retrieved)
            self.assertEqual(
                (retrieved / "case.html").read_bytes(), b"independent synthetic fixture"
            )
            self.assertEqual(receipt["corpus_sha256"], result["retrieved_sha256"])
            self.assertFalse(result["durable"])
            self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
            unsafe = root.parent / "unsafe.tar.gz"
            with tarfile.open(unsafe, "w:gz") as stream:
                member = tarfile.TarInfo("../escape")
                member.size = 1
                stream.addfile(member, io.BytesIO(b"x"))
            with self.assertRaises(ValueError):
                retrieve_archive(unsafe, root.parent / "refused")
            self.assertFalse((root.parent / "escape").exists())


if __name__ == "__main__":
    unittest.main()
