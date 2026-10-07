"""Exercise the Homepage credential writer using a disposable age identity."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
WRITER = ROOT / "scripts/repository/homepage-freshrss-secrets.sh"
BASE = Path("kubernetes/apps/monitoring/homepage/app")


class HomepageSecretsTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(WRITER.is_file(), "Homepage FreshRSS Secret writer is missing")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / BASE
        self.app.mkdir(parents=True)
        self.deployment = self.app / "deployment.yaml"
        self.deployment.write_text(
            "spec:\n  template:\n    metadata:\n      annotations: {existing: keep}\n"
        )
        self.selection = self.app / "kustomization.yaml"
        self.selection.write_text("resources: [./deployment.yaml]\n")
        self.secret = self.app / "homepage-freshrss.sops.yaml"
        self.key = self.root / "synthetic-age-key"
        subprocess.run(["age-keygen", "-o", str(self.key)], capture_output=True, check=True)
        recipient = subprocess.check_output(["age-keygen", "-y", str(self.key)], text=True).strip()
        (self.root / ".sops.yaml").write_text(
            yaml.safe_dump(
                {
                    "creation_rules": [
                        {
                            "path_regex": r"^kubernetes/.*\.sops\.yaml$",
                            "age": recipient,
                            "encrypted_regex": "^(data|stringData)$",
                        }
                    ]
                }
            )
        )
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("SOPS_AGE_")}
        self.password = "SyntheticAPI!@#$%^&*()_+-=[]{};:'\"\\|,<.>/?" * 2
        self.env.update(
            HOMEPAGE_FRESHRSS_SECRETS_CONFIRM="write:monitoring:homepage-freshrss:sops",
            NEWS_OPERATOR_NAME="reader",
            NEWS_API_PASSWORD=self.password,
        )

    def write(self, **changes):
        result = subprocess.run(
            ["bash", str(WRITER)],
            cwd=self.root,
            env=self.env | changes,
            capture_output=True,
            check=False,
        )
        self.assertNotIn(self.password.encode(), result.stdout + result.stderr)
        return result

    def snapshot(self):
        return [
            p.read_bytes() if p.exists() else None
            for p in (self.secret, self.deployment, self.selection)
        ]

    def test_real_encryption_enrollment_and_rotation(self):
        result = self.write()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        encrypted = yaml.safe_load(self.secret.read_bytes())
        self.assertEqual(
            encrypted["metadata"], {"name": "homepage-freshrss", "namespace": "homepage"}
        )
        self.assertNotIn(self.password.encode(), self.secret.read_bytes())
        plaintext = subprocess.check_output(
            ["sops", "--decrypt", str(self.secret)],
            env=self.env | {"SOPS_AGE_KEY_FILE": str(self.key)},
        )
        self.assertEqual(
            yaml.safe_load(plaintext)["stringData"],
            {"username": "reader", "password": self.password},
        )
        first = self.secret.read_bytes()
        self.assertEqual(self.write().returncode, 0)
        self.assertNotEqual(first, self.secret.read_bytes())
        resources = yaml.safe_load(self.selection.read_bytes())["resources"]
        self.assertEqual(resources, ["./deployment.yaml", "./homepage-freshrss.sops.yaml"])
        annotations = yaml.safe_load(self.deployment.read_bytes())["spec"]["template"]["metadata"][
            "annotations"
        ]
        self.assertEqual(annotations["existing"], "keep")
        revision = subprocess.check_output(
            ["git", "hash-object", str(self.secret)], text=True
        ).strip()
        self.assertEqual(annotations["homepage-freshrss-sops-hash"], revision)

    def test_invalid_intent_or_credentials_preserve_files(self):
        before = self.snapshot()
        for changes in (
            {"HOMEPAGE_FRESHRSS_SECRETS_CONFIRM": ""},
            {"NEWS_OPERATOR_NAME": ""},
            {"NEWS_OPERATOR_NAME": "invalid/user"},
            {"NEWS_API_PASSWORD": ""},
            {"NEWS_API_PASSWORD": "short"},
            {"NEWS_API_PASSWORD": "A" * 32 + "\n"},
        ):
            with self.subTest(changes=list(changes)):
                self.assertNotEqual(self.write(**changes).returncode, 0)
                self.assertEqual(self.snapshot(), before)

    def test_failed_encryption_preserves_existing_revision_and_withholds_output(self):
        self.assertEqual(self.write().returncode, 0)
        before = self.snapshot()
        binary = self.root / "bin"
        binary.mkdir()
        fake = binary / "sops"
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$NEWS_API_PASSWORD" >&2\nexit 1\n')
        fake.chmod(0o755)
        self.assertNotEqual(
            self.write(PATH=str(binary) + os.pathsep + self.env["PATH"]).returncode, 0
        )
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
