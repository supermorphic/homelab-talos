"""Offline tests for the qbit_manage real-download E2E orchestrator."""

from __future__ import annotations

import contextlib
import copy
import io
import json
import os
import re
import sys
import tempfile
import unittest
from collections import UserDict, UserList
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "helpers"))

import qbit_manage_policy as qbm
import qbit_manage_policy_api as qbm_api

RUN_ID = "abc12345def67890"
SOURCE_YAML = """\
qbt:
  host: http://qbittorrent.media.svc.cluster.local:8080
  user: !ENV QBT_USER
  pass: !ENV QBT_PASS
directory:
  root_dir: /data/downloads
recyclebin:
  enabled: true
  empty_after_x_days: 7
  save_torrents: true
"""


class IdentityAndPathTests(unittest.TestCase):
    def setUp(self):
        self.identity = qbm.RunIdentity(RUN_ID)

    def test_run_id_accepts_only_bounded_lowercase_alphanumeric(self):
        qbm.validate_run_id(RUN_ID)
        for value in (
            "",
            "short",
            "ABC12345",
            "abc_12345",
            "abc/12345",
            "abc1234567890123456789012x",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                qbm.validate_run_id(value)

    def test_relative_payload_validation(self):
        qbm.validate_relative_payload("e2e-qbm/file.mp4")
        for value in ("", "/absolute", "../escape", "path/../escape", "path/.."):
            with self.subTest(value=value), self.assertRaises(ValueError):
                qbm.validate_relative_payload(value)

    def test_owned_path_validation(self):
        safe = (
            self.identity.download_root,
            f"{self.identity.download_root}/payload",
            self.identity.media_path,
            f"/data/downloads/.RecycleBin/e2e-qbm-{RUN_ID}",
        )
        for value in safe:
            with self.subTest(value=value):
                qbm.validate_owned_path(self.identity, value)
        unsafe = (
            "",
            "/",
            "/data/downloads",
            "/data/media",
            "/data/downloads/.e2e-qbit-manage-other",
            f"{self.identity.download_root}/../other",
            "/data/downloads/.RecycleBin/unrelated",
        )
        for value in unsafe:
            with self.subTest(value=value), self.assertRaises(ValueError):
                qbm.validate_owned_path(self.identity, value)

    def test_preexisting_qbittorrent_objects_are_rejected(self):
        qbm.validate_no_qbit_collisions(self.identity, [], {}, [])
        cases = (
            ([{"hash": qbm.FIXTURE_HASH}], {}, []),
            ([], {self.identity.category: {}}, []),
            ([], {}, [self.identity.run_tag]),
            ([], {}, [self.identity.group_tag]),
        )
        for fixture, categories, tags in cases:
            with (
                self.subTest(fixture=fixture, categories=categories, tags=tags),
                self.assertRaises(qbm.AssertionFailure),
            ):
                qbm.validate_no_qbit_collisions(self.identity, fixture, categories, tags)


class PolicyConfigTests(unittest.TestCase):
    def setUp(self):
        self.identity = qbm.RunIdentity(RUN_ID)
        self.source = qbm.load_policy_yaml(SOURCE_YAML)

    def test_env_tags_round_trip_and_both_cleanup_modes_validate(self):
        for cleanup in (False, True):
            with self.subTest(cleanup=cleanup):
                config = qbm.PolicyConfig.build(self.source, self.identity, cleanup)
                qbm.PolicyConfig.validate(config, self.identity, cleanup)
                rendered = qbm.dump_policy_yaml(config)
                self.assertIn("user: !ENV 'QBT_USER'", rendered)
                self.assertIn("pass: !ENV 'QBT_PASS'", rendered)
                reparsed = qbm.load_policy_yaml(rendered)
                qbm.PolicyConfig.validate(reparsed, self.identity, cleanup)

    def test_unsafe_mutations_are_rejected(self):
        mutations = {
            "tag update": lambda c: c["commands"].__setitem__("tag_update", True),
            "orphan removal": lambda c: c["commands"].__setitem__("rem_orphaned", True),
            "extra command": lambda c: c["commands"].__setitem__("extra", False),
            "global defaults": lambda c: c["settings"].__setitem__(
                "disable_qbt_default_share_limits", True
            ),
            "shared tag": lambda c: c["settings"].__setitem__("share_limits_tag", "~shared"),
            "wrong category": lambda c: c["share_limits"][self.identity.group].__setitem__(
                "categories", ["movies"]
            ),
            "unexpected include tag": lambda c: c["share_limits"][self.identity.group].__setitem__(
                "include_all_tags", ["e2e-qbm-extra"]
            ),
            "missing private exclusion": lambda c: c["share_limits"][
                self.identity.group
            ].__setitem__("exclude_any_tags", []),
            "wrong cleanup": lambda c: c["share_limits"][self.identity.group].__setitem__(
                "cleanup", True
            ),
            "extra group": lambda c: c["share_limits"].__setitem__("unrelated", {"priority": 2}),
        }
        base = qbm.PolicyConfig.build(self.source, self.identity, False)
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                candidate = copy.deepcopy(base)
                mutate(candidate)
                with self.assertRaises(ValueError):
                    qbm.PolicyConfig.validate(candidate, self.identity, False)

    def test_production_isolation_allows_additional_private_exclusions(self):
        config = {
            "commands": {"tag_update": True, "share_limits": True},
            "settings": {"private_tag": "tracker-private"},
            "directory": {"root_dir": "/data/downloads"},
            "share_limits": {
                "public": {
                    "categories": ["movies", "tv"],
                    "exclude_any_tags": ["tracker-private", "tracker-czteam"],
                }
            },
        }
        qbm.validate_production_isolation(config)

    def test_production_isolation_rejects_unsafe_drift(self):
        base = {
            "commands": {"tag_update": True, "share_limits": True},
            "settings": {"private_tag": "tracker-private"},
            "directory": {"root_dir": "/data/downloads"},
            "share_limits": {
                "public": {
                    "categories": ["movies", "tv"],
                    "exclude_any_tags": ["tracker-private"],
                }
            },
        }
        mutations = {
            "classification disabled": lambda c: c["commands"].__setitem__("tag_update", False),
            "private auto-tag missing": lambda c: c["settings"].__setitem__(
                "private_tag", "other"
            ),
            "category added": lambda c: c["share_limits"]["public"].__setitem__(
                "categories", ["movies", "tv", "music"]
            ),
            "private exclusion missing": lambda c: c["share_limits"]["public"].__setitem__(
                "exclude_any_tags", ["tracker-czteam"]
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                candidate = copy.deepcopy(base)
                mutate(candidate)
                with self.assertRaises(qbm.AssertionFailure):
                    qbm.validate_production_isolation(candidate)

    def test_job_manifest_is_restricted_and_never_mounts_media(self):
        manifest = qbm.job_manifest(
            self.identity,
            "limits",
            qbm.QBM_IMAGE,
            f"qbm-e2e-{RUN_ID}-limits",
        )
        spec = manifest["spec"]["template"]["spec"]
        app = next(item for item in spec["containers"] if item["name"] == "app")
        self.assertEqual(manifest["kind"], "Job")
        self.assertEqual(manifest["spec"]["activeDeadlineSeconds"], 120)
        self.assertFalse(spec["automountServiceAccountToken"])
        self.assertEqual(app["args"], ["python3", "qbit_manage.py", "--run"])
        self.assertEqual(app["envFrom"], [{"secretRef": {"name": "qbit-manage-secret"}}])
        mounts = {item["mountPath"] for item in app["volumeMounts"]}
        self.assertIn("/data/downloads", mounts)
        self.assertNotIn("/data/media", mounts)
        serialized = json.dumps(manifest)
        for forbidden in (
            "QBT_SHARE_LIMITS",
            "QBT_TAG_UPDATE",
            "QBT_REM_",
            "QBT_DRY_RUN",
        ):
            self.assertNotIn(forbidden, serialized)


class ApiBridgeTests(unittest.TestCase):
    def test_qbittorrent_user_collections_normalize_to_plain_json_values(self):
        response = UserList(
            [
                UserDict(
                    {
                        "hash": qbm.FIXTURE_HASH,
                        "progress": 1.0,
                        "tags": ["tracker-public"],
                    }
                )
            ]
        )
        self.assertEqual(
            qbm_api.normalize_json(response),
            [
                {
                    "hash": qbm.FIXTURE_HASH,
                    "progress": 1.0,
                    "tags": ["tracker-public"],
                }
            ],
        )


class DownloadResilienceTests(unittest.TestCase):
    """The download step must trust fixture registration, not the add-response body."""

    class _FakeQbit:
        def __init__(self, identity, *, add_response, register_after=0, complete=True):
            self.identity = identity
            self.add_response = add_response
            self.register_after = register_after
            self.complete = complete
            self.info_calls = 0
            self.add_args = None

        def add(self, url, save_path, category, name):
            self.add_args = (url, save_path, category, name)
            return self.add_response

        def info(self, _info_hash):
            self.info_calls += 1
            if self.info_calls <= self.register_after:
                return []
            return [
                {
                    "hash": qbm.FIXTURE_HASH,
                    "category": self.identity.category,
                    "save_path": self.identity.download_root,
                    "progress": 1 if self.complete else 0,
                    "amount_left": 0 if self.complete else 1,
                    "size": 4321,
                    "completion_on": 1700000000,
                }
            ]

        def files(self, _info_hash):
            return [{"progress": 1, "size": 4321}]

    def _scenario(self, directory, fake):
        clock = {"t": 0.0}
        run_dir = Path(directory) / RUN_ID
        run_dir.mkdir()
        scenario = qbm.Scenario(
            Path(directory),
            "unused-kubeconfig",
            run_dir,
            sleeper=lambda interval: clock.__setitem__("t", clock["t"] + interval),
            monotonic=lambda: clock["t"],
        )
        scenario.qbit = fake
        return scenario

    def test_non_ok_add_response_is_verified_by_registration_not_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            identity = qbm.RunIdentity(RUN_ID)
            fake = self._FakeQbit(identity, add_response="Fails.", register_after=2)
            scenario = self._scenario(directory, fake)
            info, files = scenario.download()
            self.assertEqual(info[0]["hash"], qbm.FIXTURE_HASH)
            self.assertTrue(files)
            self.assertIsNotNone(fake.add_args)
            status = json.loads(
                (Path(directory) / RUN_ID / "external-dependency.json").read_text(encoding="utf-8")
            )
            self.assertEqual(status["status"], "passed")

    def test_fixture_that_never_registers_is_an_external_dependency_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            identity = qbm.RunIdentity(RUN_ID)
            fake = self._FakeQbit(identity, add_response="Fails.", register_after=10_000)
            scenario = self._scenario(directory, fake)
            with self.assertRaises(qbm.ExternalDependencyFailure):
                scenario.download()


class ResultRecorderTests(unittest.TestCase):
    def test_status_and_evidence_writes_are_valid_json(self):
        with tempfile.TemporaryDirectory() as directory:
            identity = qbm.RunIdentity(RUN_ID)
            recorder = qbm.ResultRecorder(Path(directory), identity)
            recorder.phase("sample", {"status": "passed"})
            recorder.job("limits", "job-name")
            evidence = json.loads((Path(directory) / "evidence.json").read_text(encoding="utf-8"))
            self.assertEqual(evidence["phases"]["sample"]["status"], "passed")
            self.assertEqual(evidence["jobs"]["limits"]["name"], "job-name")
            self.assertFalse(list(Path(directory).glob(".evidence.json.*")))


class FailureController:
    def __init__(self, fail_on: str | None = None):
        self.fail_on = fail_on
        self.calls: list[str] = []

    def call(self, name: str) -> None:
        self.calls.append(name)
        if self.fail_on == name:
            raise RuntimeError(f"injected failure: {name}")


class FakeQbit:
    def __init__(
        self,
        controller: FailureController,
        identity: qbm.RunIdentity,
        *,
        owned_fixture: bool = True,
    ):
        self.controller = controller
        self.identity = identity
        self.fixture_present = True
        self.owned_fixture = owned_fixture
        self.category_present = True
        self.tags_present = set(identity.owned_tags)

    def info(self, info_hash):
        self.controller.call("qbit.info")
        if not self.fixture_present:
            return []
        return [
            {
                "hash": info_hash,
                "category": (self.identity.category if self.owned_fixture else "movies"),
                "save_path": (
                    self.identity.download_root if self.owned_fixture else "/data/downloads/movies"
                ),
            }
        ]

    def delete(self, _info_hash):
        self.controller.call("qbit.delete")
        self.fixture_present = False

    def remove_category(self, _category):
        self.controller.call("qbit.remove_category")
        self.category_present = False

    def categories(self):
        self.controller.call("qbit.categories")
        return {self.identity.category: {}} if self.category_present else {}

    def delete_tags(self, _tags):
        self.controller.call("qbit.delete_tags")
        self.tags_present.clear()

    def tags(self):
        self.controller.call("qbit.tags")
        return sorted(self.tags_present)


class FakeFilesystem:
    def __init__(self, controller: FailureController, identity: qbm.RunIdentity):
        self.controller = controller
        self.identity = identity
        self.paths = {identity.download_root, identity.media_root}
        self.recycle = [f"/data/downloads/.RecycleBin/e2e-qbm-{identity.run_id}"]

    def remove(self, _identity, path):
        self.controller.call(f"fs.remove:{path}")
        self.paths.discard(path)
        if path in self.recycle:
            self.recycle.remove(path)

    def discover_recycle(self, _run_id):
        self.controller.call("fs.discover")
        return list(self.recycle)

    def verify_cleanup(self, paths, _run_id, check_recycle):
        self.controller.call("fs.verify")
        if set(paths).intersection(self.paths) or (check_recycle and self.recycle):
            raise RuntimeError("state remains")


class FakeKube:
    def __init__(self, controller: FailureController):
        self.controller = controller
        self.resources = True

    def delete_labeled(self, _selector):
        self.controller.call("kube.delete")
        self.resources = False

    def labeled_names(self, _selector):
        self.controller.call("kube.verify")
        return ["pod/remains"] if self.resources else []


class TeardownTests(unittest.TestCase):
    def make_teardown(
        self,
        directory: str,
        controller: FailureController,
        *,
        ledger: qbm.OwnershipLedger | None = None,
        owned_fixture: bool = True,
    ):
        identity = qbm.RunIdentity(RUN_ID)
        recorder = qbm.ResultRecorder(Path(directory), identity)
        ledger = ledger or qbm.OwnershipLedger(
            fixture_attempted=True,
            category_attempted=True,
            tags_attempted=True,
            download_path_attempted=True,
            media_path_attempted=True,
            recycle_attempted=True,
            resources_attempted=True,
        )
        qbit = FakeQbit(controller, identity, owned_fixture=owned_fixture)
        filesystem = FakeFilesystem(controller, identity)
        kube = FakeKube(controller)
        teardown = qbm.Teardown(
            identity,
            ledger,
            recorder,
            kube,
            qbit=qbit,
            filesystem=filesystem,
        )
        return teardown, qbit, filesystem, kube

    def test_full_teardown_removes_only_exact_owned_state(self):
        with tempfile.TemporaryDirectory() as directory:
            controller = FailureController()
            teardown, qbit, filesystem, kube = self.make_teardown(directory, controller)
            self.assertTrue(teardown.run())
            self.assertFalse(qbit.fixture_present)
            self.assertFalse(qbit.category_present)
            self.assertFalse(qbit.tags_present)
            self.assertFalse(filesystem.paths)
            self.assertFalse(filesystem.recycle)
            self.assertFalse(kube.resources)
            recovery = json.loads((Path(directory) / "recovery.json").read_text(encoding="utf-8"))
            self.assertEqual(recovery["status"], "passed")

    def test_preflight_collision_with_no_ownership_is_never_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            controller = FailureController()
            empty = qbm.OwnershipLedger()
            teardown, qbit, filesystem, kube = self.make_teardown(
                directory, controller, ledger=empty
            )
            self.assertTrue(teardown.run())
            self.assertTrue(qbit.fixture_present)
            self.assertTrue(qbit.category_present)
            self.assertTrue(qbit.tags_present)
            self.assertTrue(filesystem.paths)
            self.assertTrue(kube.resources)
            self.assertEqual(controller.calls, [])

    def test_wrong_fixture_ownership_markers_refuse_deletion(self):
        with tempfile.TemporaryDirectory() as directory:
            controller = FailureController()
            teardown, qbit, _, _ = self.make_teardown(directory, controller, owned_fixture=False)
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertFalse(teardown.run())
            self.assertTrue(qbit.fixture_present)
            self.assertNotIn("qbit.delete", controller.calls)

    def test_every_injected_cleanup_failure_is_visible_and_later_groups_continue(self):
        failure_points = (
            "qbit.info",
            "qbit.delete",
            "qbit.remove_category",
            "qbit.categories",
            "qbit.delete_tags",
            "qbit.tags",
            f"fs.remove:/data/downloads/.e2e-qbit-manage-{RUN_ID}",
            f"fs.remove:/data/media/.e2e-qbit-manage-{RUN_ID}",
            "fs.discover",
            f"fs.remove:/data/downloads/.RecycleBin/e2e-qbm-{RUN_ID}",
            "fs.verify",
            "kube.delete",
            "kube.verify",
        )
        for failure in failure_points:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                controller = FailureController(failure)
                teardown, _, _, _ = self.make_teardown(directory, controller)
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertFalse(teardown.run())
                self.assertIn("kube.delete", controller.calls)
                recovery = json.loads(
                    (Path(directory) / "recovery.json").read_text(encoding="utf-8")
                )
                self.assertEqual(recovery["status"], "failed")


class GuardTests(unittest.TestCase):
    def test_exact_confirmation_is_required(self):
        with mock.patch.dict(
            os.environ,
            {"CLUSTER_E2E_CONFIRM": "e2e:qbit-manage-policy"},
            clear=False,
        ):
            qbm.require_confirmation()
        for value in ("", "e2e:wrong-target", "chaos:qbit-manage-policy"):
            with (
                self.subTest(value=value),
                mock.patch.dict(os.environ, {"CLUSTER_E2E_CONFIRM": value}, clear=False),
                self.assertRaises(qbm.ScenarioFailure),
            ):
                qbm.require_confirmation()

    def test_sigterm_is_converted_to_a_teardown_safe_exception(self):
        with mock.patch.object(qbm.signal, "signal") as register:
            qbm.install_termination_handler()
        registered_signal, handler = register.call_args.args
        self.assertEqual(registered_signal, qbm.signal.SIGTERM)
        with self.assertRaises(qbm.TerminationRequested):
            handler(qbm.signal.SIGTERM, None)


class RepositorySafetyTests(unittest.TestCase):
    def test_host_commands_use_argument_vectors_without_a_shell(self):
        completed = qbm.subprocess.CompletedProcess(
            ["kubectl", "get", "pod"], 0, stdout="ok\n", stderr=""
        )
        with mock.patch.object(qbm.subprocess, "run", return_value=completed) as execute:
            self.assertEqual(qbm.run_command(["kubectl", "get", "pod"]), "ok\n")
        args, kwargs = execute.call_args
        self.assertEqual(args[0], ["kubectl", "get", "pod"])
        self.assertNotIn("shell", kwargs)

    def test_api_command_failure_classifier_exposes_only_fixed_labels(self):
        cases = {
            "Traceback: ModuleNotFoundError: private detail": "missing-client-module",
            "SyntaxError: private detail": "helper-syntax",
            "error: unknown flag: --stdin": "kubectl-stdin-unsupported",
            "error: unable to upgrade connection: private detail": "exec-transport",
            'Traceback:\n  File "<stdin>", line 51\nValueError: private detail': (
                "python-ValueError-L51"
            ),
            "command terminated with exit code 1": "helper-process",
            "password=must-not-surface": "unclassified-command",
        }
        for stderr, expected in cases.items():
            with self.subTest(expected=expected):
                error = qbm.CommandFailure(["kubectl", "exec"], 1, stderr)
                self.assertEqual(qbm.classify_api_command_failure(error), expected)
                self.assertNotIn("private detail", qbm.classify_api_command_failure(error))

    def test_in_pod_api_helper_keeps_credentials_out_of_output(self):
        root = Path(__file__).resolve().parents[3]
        helper = (root / "scripts/test/helpers/qbit_manage_policy_api.py").read_text(
            encoding="utf-8"
        )
        self.assertIn('os.environ.get("QBT_USER")', helper)
        self.assertIn('os.environ.get("QBT_PASS")', helper)
        self.assertIn('"errorType": type(error).__name__', helper)
        self.assertIn('"categories": (0, client.torrents_categories)', helper)
        self.assertIn('"tags": (0, client.torrents_tags)', helper)
        forbidden = re.compile(
            r"printenv|os\.environ(?!\.get)|"
            r"print\([^)]*(?:username|password|QBT_(?:USER|PASS))"
        )
        self.assertIsNone(forbidden.search(helper))

    def test_api_helper_source_is_streamed_to_the_existing_container(self):
        kube = mock.Mock()
        kube.exec.return_value = "[]"
        client = qbm.QbitClient(kube, "qbit-manage-pod", "helper source")
        self.assertEqual(client.call("info", qbm.FIXTURE_HASH), "[]")
        kube.exec.assert_called_once_with(
            "qbit-manage-pod",
            ["python3", "-", "info", qbm.FIXTURE_HASH],
            container="app",
            input_text="helper source",
            timeout=45,
        )

    def test_orchestrator_never_collects_application_logs(self):
        source = Path(qbm.__file__).read_text(encoding="utf-8")
        self.assertNotRegex(source, r"\.(?:call|exec)\([^)]*[\"']logs[\"']")
        self.assertNotIn("podLogs", source)


if __name__ == "__main__":
    unittest.main()
