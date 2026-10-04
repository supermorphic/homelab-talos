"""Independent fixture parsing and negative contracts for Komga acceptance."""

import copy
import io
import json
import tempfile
import unittest
import urllib.error
import zipfile
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import Mock, patch
from xml.etree import ElementTree

from scripts.test.scenarios import komga_acceptance as subject


def fixture():
    return {
        "schema_version": 1,
        "books": {"cbz": "CBZ1", "cbr": "CBR1"},
        "expected_cbr_pages": 2,
        "collection_id": "COLLECTION1",
        "repeat_scan": True,
        "panels": {
            "version": "3.0.0",
            "integration": "opds_v1",
            "trusted_https": True,
            "browsing": True,
            "reading": True,
            "streaming": True,
            "offline_download": True,
            "resume": True,
            "server_progress": "unsupported",
        },
        "mylar_to_library": True,
    }


class FakeApi:
    def __init__(self):
        self.calls = []
        self.account = {"id": "USER1", "email": "reader@example.invalid"}
        self.collection = {
            "id": "COLLECTION1",
            "name": "Private collection",
            "ordered": True,
            "seriesIds": ["SERIES1", "SERIES2"],
        }
        self.books = {}
        for kind, book_id, media_type in (
            ("cbz", "CBZ1", "application/zip"),
            ("cbr", "CBR1", "application/x-rar-compressed"),
        ):
            self.books[book_id] = {
                "id": book_id,
                "seriesId": "SERIES1" if kind == "cbz" else "SERIES2",
                "deleted": False,
                "fileHash": "private-content-hash",
                "sizeBytes": 1000,
                "media": {"status": "READY", "mediaType": media_type, "pagesCount": 2},
                "metadata": {
                    "title": "Acceptance CBZ title" if kind == "cbz" else "Private book",
                    "summary": "Synthetic ComicInfo metadata" if kind == "cbz" else "",
                    "number": "1",
                    "authors": [{"name": "Acceptance writer"}],
                },
                "readProgress": {"page": 1, "completed": False},
            }

    def json(self, path):
        self.calls.append(path)
        if path == "/api/v2/users/me":
            return copy.deepcopy(self.account)
        if path.startswith("/api/v1/books/"):
            return copy.deepcopy(self.books[path.rsplit("/", 1)[-1]])
        if path.startswith("/api/v1/collections/"):
            return copy.deepcopy(self.collection)
        if path == "/api/v1/series/SERIES1":
            return {"metadata": {"publisher": "Acceptance publisher"}}
        raise AssertionError(path)

    def page(self, book_id, page):
        self.calls.append((book_id, page))
        return subject.fixture_page(page - 1), "image/png"


class FixtureTests(unittest.TestCase):
    def test_generated_cbz_and_mylar_metadata_parse_independently(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "fixture"
            subject.generate(root)
            with zipfile.ZipFile(root / "content" / "acceptance.cbz") as archive:
                self.assertEqual(
                    sorted(archive.namelist()), ["001.png", "002.png", "ComicInfo.xml"]
                )
                xml = ElementTree.fromstring(archive.read("ComicInfo.xml"))
                self.assertEqual(xml.findtext("Title"), "Acceptance CBZ title")
                self.assertEqual(xml.findtext("Writer"), "Acceptance writer")
                for name in ["001.png", "002.png"]:
                    self.assertEqual(archive.read(name)[:8], b"\x89PNG\r\n\x1a\n")
            sidecar = json.loads((root / "content" / "series.json").read_text())
            self.assertEqual(sidecar["metadata"]["publisher"], "Acceptance publisher")
            self.assertEqual(sidecar["metadata"]["type"], "comicSeries")
            self.assertEqual(sidecar["metadata"]["volume"], 1)
            self.assertEqual((root / "fixture.json").stat().st_mode & 0o777, 0o600)
            self.assertFalse(json.loads((root / "fixture.json").read_text())["mylar_to_library"])

    def test_generate_preserves_an_existing_operator_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "keep").write_text("operator data")
            with self.assertRaises(subject.Failure):
                subject.generate(root)
            self.assertEqual((root / "keep").read_text(), "operator data")

    def test_fixture_rejects_duplicate_and_unsafe_book_ids(self):
        for value in ["CBZ1", "../private", "", "CBR1?key=secret"]:
            data = fixture()
            data["books"]["cbr"] = value
            with self.subTest(value=value), self.assertRaises(subject.Failure):
                subject.validate_fixture(data)

    def test_private_reader_rejects_public_permissions_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / "fixture.json"
            target.write_text(json.dumps(fixture()))
            target.chmod(0o644)
            with self.assertRaises(subject.Failure):
                subject.read_private(target)
            target.chmod(0o600)
            self.assertEqual(subject.read_private(target)["schema_version"], 1)
            link = root / "link.json"
            link.symlink_to(target)
            with self.assertRaises(subject.Failure):
                subject.read_private(link)


class ApplicationTests(unittest.TestCase):
    def test_checks_both_formats_metadata_first_last_pages_and_real_progress(self):
        api = FakeApi()
        state = subject.application_state(api, fixture())
        self.assertEqual(state["account_id"], "USER1")
        self.assertIn(("CBZ1", 1), api.calls)
        self.assertIn(("CBR1", 2), api.calls)

    def test_rejects_wrong_format_unready_book_empty_pages_or_wrong_metadata(self):
        changes = [
            (
                "CBR1",
                "media",
                {"status": "READY", "mediaType": "application/zip", "pagesCount": 2},
            ),
            (
                "CBZ1",
                "media",
                {"status": "ERROR", "mediaType": "application/zip", "pagesCount": 2},
            ),
            (
                "CBZ1",
                "media",
                {"status": "READY", "mediaType": "application/zip", "pagesCount": 0},
            ),
            ("CBZ1", "metadata", {"title": "acceptance", "summary": "", "authors": []}),
        ]
        for book_id, field, value in changes:
            api = FakeApi()
            api.books[book_id][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(subject.Failure):
                subject.application_state(api, fixture())

    def test_rejects_success_status_with_corrupt_page_payload(self):
        api = FakeApi()
        api.page = lambda book_id, page: (b"not an image", "image/png")
        with self.assertRaises(subject.Failure):
            subject.application_state(api, fixture())

    def test_cbr_count_must_match_independently_inspected_sample(self):
        data = fixture()
        data["expected_cbr_pages"] = 3
        with self.assertRaisesRegex(subject.Failure, "CBR page count differs"):
            subject.application_state(FakeApi(), data)

    def test_standalone_human_acceptance_is_not_enrolled_in_campaigns(self):
        import yaml

        from scripts.test import catalog_validator

        catalog = yaml.safe_load((subject.ROOT / "tests/catalog.yaml").read_text())
        selected = next(
            item for item in catalog["suites"] if item["metadata"]["id"] == "test.komga-acceptance"
        )
        self.assertEqual(selected["metadata"]["execution_owner"], "human")
        self.assertFalse(selected["metadata"]["mutates_cluster"])
        self.assertEqual(selected["access"]["profile"], "observer")
        self.assertEqual(selected["access"]["prerequisites"], ["application-credential"])
        self.assertIn("test.komga-acceptance", catalog_validator.STANDALONE_SUITES)
        for campaign in catalog["campaigns"].values():
            self.assertNotIn("test.komga-acceptance", campaign.get("members", []))

    def test_rejects_empty_progress_and_unrelated_collection(self):
        for change in ["progress", "collection"]:
            api = FakeApi()
            if change == "progress":
                for book in api.books.values():
                    book["readProgress"] = None
            else:
                api.collection["seriesIds"] = ["UNRELATED"]
            with self.subTest(change=change), self.assertRaises(subject.Failure):
                subject.application_state(api, fixture())

    def test_capture_time_fields_do_not_change_the_state_digest(self):
        api = FakeApi()
        first = subject.application_state(api, fixture())
        api.books["CBR1"]["lastModified"] = "later"
        api.books["CBR1"]["readProgress"]["lastModified"] = "later"
        self.assertEqual(first, subject.application_state(api, fixture()))


class PersistenceAndAttendanceTests(unittest.TestCase):
    def baseline(self):
        return {
            "schema_version": 1,
            "pod_uid": "OLD",
            "pvc_uid": "PVC1",
            "volume": "VOLUME1",
            "state": subject.application_state(FakeApi(), fixture()),
        }

    def test_replacement_requires_new_pod_same_claim_and_identical_seeded_state(self):
        baseline = self.baseline()
        current = {"pod_uid": "NEW", "pvc_uid": "PVC1", "volume": "VOLUME1"}
        subject.compare(baseline, current, baseline["state"])
        for field, value in [("pod_uid", "OLD"), ("pvc_uid", "OTHER"), ("volume", "OTHER")]:
            changed = dict(current, **{field: value})
            with self.subTest(field=field), self.assertRaises(subject.Failure):
                subject.compare(baseline, changed, baseline["state"])

    def test_changed_account_or_progress_is_not_persistence_success(self):
        baseline = self.baseline()
        current = {"pod_uid": "NEW", "pvc_uid": "PVC1", "volume": "VOLUME1"}
        for change in ["account", "progress", "collection"]:
            api = FakeApi()
            if change == "account":
                api.account["id"] = "OTHER"
            elif change == "progress":
                api.books["CBR1"]["readProgress"]["completed"] = True
            else:
                api.collection["name"] = "Changed collection"
            with self.subTest(change=change), self.assertRaises(subject.Failure):
                subject.compare(baseline, current, subject.application_state(api, fixture()))

    def test_native_results_are_attended_and_missing_outcomes_fail_closed(self):
        subject.attendance(fixture())
        data = fixture()
        data["repeat_scan"] = False
        with self.assertRaises(subject.Failure):
            subject.attendance(data)
        for key in ["trusted_https", "browsing", "reading", "resume"]:
            data = fixture()
            data["panels"][key] = False
            with self.subTest(key=key), self.assertRaises(subject.Failure):
                subject.attendance(data)
        data = fixture()
        data["mylar_to_library"] = False
        with self.assertRaises(subject.Failure):
            subject.attendance(data)

    def test_not_tested_progress_and_no_delivery_method_fail(self):
        data = fixture()
        data["panels"]["server_progress"] = "not_tested"
        with self.assertRaises(subject.Failure):
            subject.attendance(data)
        data = fixture()
        data["panels"].update(streaming=False, offline_download=False)
        with self.assertRaises(subject.Failure):
            subject.attendance(data)


class BoundaryTests(unittest.TestCase):
    def test_cluster_read_uses_selected_config_without_context_switching(self):
        from types import SimpleNamespace

        selected = Path("/synthetic/invocations/run/config")
        with patch.object(
            subject.subprocess, "run", return_value=SimpleNamespace(stdout='{"items": []}')
        ) as run:
            self.assertEqual(subject.kube_json(selected, "media", "pods"), {"items": []})
        self.assertEqual(
            run.call_args.args[0],
            ["kubectl", "--kubeconfig", str(selected), "-n", "media", "get", "pods", "-o", "json"],
        )

    def test_api_uses_get_and_never_follows_a_redirect_with_the_key(self):
        api = subject.Api("synthetic-test-token")
        response = Mock()
        response.read.return_value = b"{}"
        response.headers.get_content_type.return_value = "application/json"
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        api.opener = Mock()
        api.opener.open.return_value = response
        api.json("/api/v2/users/me")
        request = api.opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(request.full_url, subject.BASE_URL + "/api/v2/users/me")
        self.assertEqual(request.get_header("X-api-key"), "synthetic-test-token")
        self.assertIsNone(
            subject.NoRedirect().redirect_request(
                request, None, 302, "Moved", {}, "https://example.invalid/private"
            )
        )

    def test_response_errors_redact_private_url_and_body(self):
        api = subject.Api("synthetic-test-token")
        api.opener = Mock()
        api.opener.open.side_effect = urllib.error.HTTPError(
            "https://example.invalid/private-title", 401, "private-body", {}, None
        )
        with self.assertRaises(subject.Failure) as caught:
            api.json("/api/v2/users/me")
        self.assertEqual(str(caught.exception), "Application request failed with HTTP 401.")
        with self.assertRaises(subject.Failure):
            api.request("//example.invalid/private", "application/json")

    def test_unexpected_private_response_never_enters_retained_stderr(self):
        output = io.StringIO()
        with (
            patch("sys.argv", ["komga_acceptance", "capture", ".kube/config"]),
            patch.dict(
                subject.os.environ,
                {"KOMGA_ACCEPTANCE_CONFIRM": "capture:media:komga:library-and-state"},
            ),
            patch.object(
                subject, "read_private", side_effect=ValueError("private-title-and-token")
            ),
            redirect_stderr(output),
        ):
            self.assertEqual(subject.main(), 1)
        self.assertNotIn("private-title-and-token", output.getvalue())
        self.assertNotIn("Traceback", output.getvalue())

    def test_capture_does_not_overwrite_existing_private_state(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "baseline.json"
            subject.write_private(path, {"original": True})
            with self.assertRaises(subject.Failure):
                subject.write_private(path, {"replacement": True})
            self.assertEqual(subject.read_private(path), {"original": True})

    def test_observation_requires_config_mount_backup_and_applied_revision(self):
        source = {
            "spec": {"url": subject.FORGEJO_URL},
            "status": {
                "conditions": [{"type": "Ready", "status": "True"}],
                "artifact": {"revision": "main@sha1:synthetic"},
            },
        }
        documents = {
            "pods": {
                "items": [
                    {
                        "metadata": {"uid": "POD1"},
                        "spec": {
                            "volumes": [
                                {"name": "config", "persistentVolumeClaim": {"claimName": "komga"}}
                            ],
                            "containers": [
                                {
                                    "name": "app",
                                    "volumeMounts": [{"name": "config", "mountPath": "/config"}],
                                }
                            ],
                        },
                        "status": {
                            "phase": "Running",
                            "containerStatuses": [{"name": "app", "ready": True}],
                        },
                    }
                ]
            },
            "pvc": {
                "metadata": {"uid": "PVC1"},
                "spec": {"volumeName": "VOLUME1"},
                "status": {"phase": "Bound"},
            },
            "volumes.longhorn.io": {
                "metadata": {"labels": {"recurring-job-group.longhorn.io/default": "enabled"}},
                "status": {"robustness": "healthy", "lastBackupAt": "", "lastBackup": ""},
            },
            "gitrepository": source,
            "kustomization": {
                "status": {
                    "lastAppliedRevision": "main@sha1:synthetic",
                    "conditions": [{"type": "Ready", "status": "True"}],
                }
            },
        }

        def observe():
            return subject.observe(
                subject.ROOT / ".kube/invocations/synthetic/config", need_backup=True
            )

        with patch.object(
            subject, "kube_json", side_effect=lambda kc, ns, *args: documents[args[0]]
        ):
            with self.assertRaisesRegex(subject.Failure, "No completed"):
                observe()
            documents["volumes.longhorn.io"]["status"].update(
                lastBackupAt="2026-01-01T00:00:00Z", lastBackup="BACKUP1"
            )
            self.assertEqual(observe()["pvc_uid"], "PVC1")
            documents["kustomization"]["status"]["lastAppliedRevision"] = "main@sha1:old"
            with self.assertRaisesRegex(subject.Failure, "not reconciled"):
                observe()
            documents["kustomization"]["status"]["lastAppliedRevision"] = "main@sha1:synthetic"
            documents["pods"]["items"][0]["spec"]["containers"][0]["volumeMounts"] = []
            with self.assertRaisesRegex(subject.Failure, "does not mount"):
                observe()


if __name__ == "__main__":
    unittest.main()
