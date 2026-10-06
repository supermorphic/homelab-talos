"""Use disposable age identities and real SOPS; never load the operator's key."""

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

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
        self.root = Path(self.temp.name)
        for path in (DB, APP):
            (self.root / path).parent.mkdir(parents=True)
        self.kustomization = self.root / DB.parent / "kustomization.yaml"
        self.kustomization.write_text("resources: [./statefulset.yaml]\n")
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

    def test_symlink_target_is_refused(self):
        victim = self.root / "other-task"
        victim.write_text("preserve")
        (self.root / DB).symlink_to(victim)
        with self.assertRaises(self.module.SecretWriteError):
            self.write()
        self.assertEqual(victim.read_text(), "preserve")


if __name__ == "__main__":
    unittest.main()
