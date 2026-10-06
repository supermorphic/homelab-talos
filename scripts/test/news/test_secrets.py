"""Use disposable age identities and real SOPS; never load the operator's key."""

import contextlib
import importlib.util
import io
import os
import subprocess
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "scripts/repository/news_secrets.py"
DB = Path("kubernetes/apps/news/postgresql/app/postgresql-credentials.sops.yaml")
APP = Path("kubernetes/apps/news/freshrss/app/freshrss-runtime.sops.yaml")


class NewsSecretsTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.is_file(), "guarded news Secret writer is missing")
        spec = importlib.util.spec_from_file_location("news_secrets", MODULE)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for path in (DB, APP):
            (self.root / path).parent.mkdir(parents=True)
        self.kustomization = self.root / DB.parent / "kustomization.yaml"
        self.kustomization.write_text("resources: [./statefulset.yaml]\n")
        self.app_selection = self.root / APP.parent / "kustomization.yaml"
        self.app_selection.write_text("resources: [./deployment.yaml]\n")
        self.key = self.root / "synthetic-age-key"
        result = subprocess.run(
            ["age-keygen", "-o", str(self.key)], capture_output=True, check=True
        )
        del result
        self.recipient = subprocess.run(
            ["age-keygen", "-y", str(self.key)], capture_output=True, text=True, check=True
        ).stdout.strip()
        self.policy = {
            "creation_rules": [
                {
                    "path_regex": r"^kubernetes/.*\.sops\.yaml$",
                    "age": self.recipient,
                    "encrypted_regex": "^(data|stringData)$",
                }
            ]
        }
        (self.root / ".sops.yaml").write_text(yaml.safe_dump(self.policy))
        self.environment = {
            "NEWS_SECRETS_CONFIRM": "write:news:bootstrap:sops",
            "NEWS_POSTGRES_PASSWORD": "SyntheticAdmin" + "A" * 32,
            "NEWS_DB_PASSWORD": "SyntheticApp" + "B" * 32,
            "NEWS_BACKUP_PASSWORD": "SyntheticBackup" + "C" * 32,
            "NEWS_MONITORING_PASSWORD": "SyntheticMonitor" + "D" * 32,
            "NEWS_OPERATOR_NAME": "reader",
            "NEWS_OPERATOR_PASSWORD": "SyntheticReader" + "E" * 32,
            "NEWS_API_PASSWORD": "SyntheticAPI" + "F" * 32,
        }

    def write(self, **kwargs):
        self.module.write_secrets(self.root, self.environment, **kwargs)

    def decrypt(self, path):
        environment = {
            key: value for key, value in os.environ.items() if not key.startswith("SOPS_AGE_")
        }
        environment["SOPS_AGE_KEY_FILE"] = str(self.key)
        result = subprocess.run(
            ["sops", "-d", str(self.root / path)], capture_output=True, check=True, env=environment
        )
        return yaml.safe_load(result.stdout)

    def test_real_encryption_roundtrip_and_atomic_rotation(self):
        self.write()
        db, app = self.decrypt(DB), self.decrypt(APP)
        self.assertEqual(
            yaml.safe_load(self.kustomization.read_text())["resources"],
            ["./statefulset.yaml", "./postgresql-credentials.sops.yaml"],
        )
        self.assertEqual(
            yaml.safe_load(self.app_selection.read_text())["resources"],
            ["./deployment.yaml", "./freshrss-runtime.sops.yaml"],
        )
        self.assertEqual(
            db["metadata"], {"name": "news-postgresql-credentials", "namespace": "news"}
        )
        self.assertEqual(
            db["stringData"],
            {
                "postgres-superuser-password": self.environment["NEWS_POSTGRES_PASSWORD"],
                "freshrss-password": self.environment["NEWS_DB_PASSWORD"],
                "backup-password": self.environment["NEWS_BACKUP_PASSWORD"],
                "monitoring-password": self.environment["NEWS_MONITORING_PASSWORD"],
            },
        )
        self.assertEqual(app["metadata"], {"name": "freshrss-runtime", "namespace": "news"})
        self.assertEqual(
            app["stringData"],
            {
                "db-password": self.environment["NEWS_DB_PASSWORD"],
                "operator-name": "reader",
                "operator-password": self.environment["NEWS_OPERATOR_PASSWORD"],
                "api-password": self.environment["NEWS_API_PASSWORD"],
            },
        )
        for path in (DB, APP):
            ciphertext = (self.root / path).read_bytes()
            for key, value in self.environment.items():
                if key.endswith("PASSWORD"):
                    self.assertNotIn(value.encode(), ciphertext)
            manifest = yaml.safe_load(ciphertext)
            self.assertEqual([r["recipient"] for r in manifest["sops"]["age"]], [self.recipient])
            self.assertEqual((self.root / path).stat().st_mode & 0o777, 0o600)
        self.environment["NEWS_API_PASSWORD"] = "SyntheticRotation" + "G" * 32
        self.write()
        self.assertEqual(
            self.decrypt(APP)["stringData"]["api-password"], self.environment["NEWS_API_PASSWORD"]
        )

    def test_invalid_intent_and_values_leave_no_files(self):
        cases = [
            ("NEWS_SECRETS_CONFIRM", ""),
            ("NEWS_DB_PASSWORD", "short"),
            ("NEWS_OPERATOR_NAME", "../reader"),
            ("NEWS_API_PASSWORD", self.environment["NEWS_OPERATOR_PASSWORD"]),
        ]
        for key, value in cases:
            with self.subTest(key=key):
                environment = self.environment | {key: value}
                with self.assertRaises(self.module.SecretWriteError):
                    self.module.write_secrets(self.root, environment)
                self.assertFalse((self.root / DB).exists())
                self.assertFalse((self.root / APP).exists())

    def test_selects_app_secret_from_previous_database_only_writer(self):
        self.write()
        self.app_selection.write_text("resources: [./deployment.yaml]\n")
        self.write()
        self.assertIn(
            "./freshrss-runtime.sops.yaml",
            yaml.safe_load(self.app_selection.read_text())["resources"],
        )

    def test_ambiguous_recipient_policy_is_refused(self):
        self.policy["creation_rules"].append(self.policy["creation_rules"][0])
        (self.root / ".sops.yaml").write_text(yaml.safe_dump(self.policy))
        with self.assertRaises(self.module.SecretWriteError):
            self.write()
        self.assertFalse((self.root / DB).exists())

    def test_plaintext_or_partial_existing_pair_is_refused(self):
        self.write()
        original = (self.root / APP).read_bytes()
        (self.root / DB).write_text("kind: Secret\nstringData: {password: plaintext}\n")
        with self.assertRaises(self.module.SecretWriteError):
            self.write()
        self.assertEqual((self.root / APP).read_bytes(), original)
        (self.root / DB).unlink()
        with self.assertRaises(self.module.SecretWriteError):
            self.write()
        self.assertEqual((self.root / APP).read_bytes(), original)

    def test_failed_second_replacement_rolls_back_first(self):
        self.write()
        originals = {path: (self.root / path).read_bytes() for path in (DB, APP)}
        count = 0

        def fail_second(source, destination):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError("synthetic replacement failure")
            os.replace(source, destination)

        with self.assertRaises(self.module.SecretWriteError):
            self.write(replace=fail_second)
        for path, content in originals.items():
            self.assertEqual((self.root / path).read_bytes(), content)

    def test_failed_app_selection_restores_both_secrets_and_database_selection(self):
        originals = {p: p.read_bytes() for p in (self.kustomization, self.app_selection)}

        def fail_app_selection(source, destination):
            if destination == self.app_selection:
                raise OSError("synthetic selection failure")
            os.replace(source, destination)

        with self.assertRaises(self.module.SecretWriteError):
            self.write(replace=fail_app_selection)
        for path, content in originals.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertFalse((self.root / DB).exists())
        self.assertFalse((self.root / APP).exists())

    def test_external_app_selection_edit_is_preserved_during_install(self):
        external = b"resources: [./deployment.yaml, ./operator-resource.yaml]\n"
        original_db = self.kustomization.read_bytes()

        def edit_selection(source, destination):
            os.replace(source, destination)
            if destination == self.root / APP:
                self.app_selection.write_bytes(external)

        with self.assertRaises(self.module.SecretWriteError):
            self.write(replace=edit_selection)
        self.assertEqual(self.app_selection.read_bytes(), external)
        self.assertEqual(self.kustomization.read_bytes(), original_db)
        self.assertFalse((self.root / DB).exists())
        self.assertFalse((self.root / APP).exists())

    def test_encryption_failure_hides_raw_stderr_and_preserves_files(self):
        self.write()
        originals = {path: (self.root / path).read_bytes() for path in (DB, APP)}

        def fail(command, **kwargs):
            return subprocess.CompletedProcess(
                command, 1, b"", self.environment["NEWS_DB_PASSWORD"].encode()
            )

        with self.assertRaises(self.module.SecretWriteError) as raised:
            self.write(runner=fail)
        self.assertNotIn(self.environment["NEWS_DB_PASSWORD"], str(raised.exception))
        for path, content in originals.items():
            self.assertEqual((self.root / path).read_bytes(), content)

    def test_concurrent_change_is_preserved(self):
        self.write()
        concurrent = b"operator modified file"

        def modify(command, **kwargs):
            kwargs.pop("check", None)
            result = subprocess.run(command, check=False, **kwargs)
            (self.root / APP).write_bytes(concurrent)
            return result

        with self.assertRaises(self.module.SecretWriteError):
            self.write(runner=modify)
        self.assertEqual((self.root / APP).read_bytes(), concurrent)

    def test_policy_edit_after_encryption_prevents_installation(self):
        self.write()
        originals = {path: (self.root / path).read_bytes() for path in (DB, APP)}
        count = 0

        def modify_policy(command, **kwargs):
            nonlocal count
            kwargs.pop("check", None)
            result = subprocess.run(command, check=False, **kwargs)
            count += 1
            if count == 2:
                with (self.root / ".sops.yaml").open("a") as stream:
                    stream.write("# operator changed policy during encryption\n")
            return result

        with self.assertRaises(self.module.SecretWriteError):
            self.write(runner=modify_policy)
        for path, content in originals.items():
            self.assertEqual((self.root / path).read_bytes(), content)

    def test_edit_between_replacements_is_preserved(self):
        self.write()
        original_db = (self.root / DB).read_bytes()
        concurrent = b"operator edit between replacements"

        def modify_after_first(source, destination):
            os.replace(source, destination)
            if destination == self.root / DB:
                (self.root / APP).write_bytes(concurrent)

        with self.assertRaises(self.module.SecretWriteError):
            self.write(replace=modify_after_first)
        self.assertEqual((self.root / APP).read_bytes(), concurrent)
        self.assertEqual((self.root / DB).read_bytes(), original_db)

    def test_competing_writers_leave_a_matched_pair(self):
        self.write()
        first_ready, second_db_written, first_done = (threading.Event() for _ in range(3))
        second_environment = self.environment | {
            "NEWS_DB_PASSWORD": "SyntheticCompeting" + "Z" * 32
        }

        def first_replace(source, destination):
            if destination == self.root / DB:
                first_ready.set()
                second_db_written.wait(timeout=2)
            os.replace(source, destination)

        def second_replace(source, destination):
            os.replace(source, destination)
            if destination == self.root / DB:
                second_db_written.set()
                first_done.wait(timeout=5)

        def first_writer():
            try:
                self.write(replace=first_replace)
            finally:
                first_done.set()

        with ThreadPoolExecutor(max_workers=2) as executor:
            first = executor.submit(first_writer)
            self.assertTrue(first_ready.wait(timeout=5), "first writer did not reach installation")
            second = executor.submit(
                self.module.write_secrets, self.root, second_environment, replace=second_replace
            )
            first.result(timeout=10)
            second.result(timeout=10)
        self.assertTrue(
            self.decrypt(DB)["stringData"]["freshrss-password"]
            == self.decrypt(APP)["stringData"]["db-password"],
            "competing writers left mismatched passwords",
        )
        self.assertEqual(
            self.decrypt(DB)["stringData"]["freshrss-password"],
            second_environment["NEWS_DB_PASSWORD"],
        )

    def test_rollback_failure_requests_operator_review_without_raw_output(self):
        self.write()
        count = 0

        def fail_rollback(source, destination):
            nonlocal count
            count += 1
            if count > 1:
                raise OSError(self.environment["NEWS_DB_PASSWORD"])
            os.replace(source, destination)

        with self.assertRaises(self.module.SecretWriteError) as raised:
            self.write(replace=fail_rollback)
        self.assertIn("operator review required", str(raised.exception))
        self.assertNotIn(self.environment["NEWS_DB_PASSWORD"], str(raised.exception))

    def test_cli_preserves_safe_partial_installation_diagnostic(self):
        message = "incomplete rollback; operator review required"
        error = io.StringIO()
        with (
            patch.object(
                self.module, "write_secrets", side_effect=self.module.SecretWriteError(message)
            ),
            contextlib.redirect_stderr(error),
        ):
            self.assertEqual(self.module.main(), 1)
        self.assertIn(message, error.getvalue())

    def test_symlink_target_is_refused(self):
        victim = self.root / "other-task"
        victim.write_text("preserve")
        (self.root / DB).symlink_to(victim)
        with self.assertRaises(self.module.SecretWriteError):
            self.write()
        self.assertEqual(victim.read_text(), "preserve")


if __name__ == "__main__":
    unittest.main()
