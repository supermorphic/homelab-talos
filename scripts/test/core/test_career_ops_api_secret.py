"""API credential delivery invariants; values are synthetic."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

from scripts.repository import career_ops_api_secret as api


class ApiSecretTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / api.TARGET.parent).mkdir(parents=True)
        (self.root / ".sops.yaml").write_text(
            "creation_rules:\n- path_regex: '^kubernetes/.*'\n  age: age1synthetic\n  encrypted_regex: '^(data|stringData)$'\n"
        )
        self.private = self.root / "private"
        self.private.mkdir(mode=0o700)
        self.token = self.private / "token"
        self.calls = []

    def encrypt(self, command, **kwargs):
        document = yaml.safe_load(kwargs["input"])
        self.calls.append(json.loads(json.dumps(document)))
        document["stringData"] = {"principals.json": "ENC[AES256_GCM,synthetic]"}
        document["sops"] = {
            "age": [{"recipient": "age1synthetic"}],
            "encrypted_regex": "^(data|stringData)$",
            "mac": "ENC[AES256_GCM,synthetic]",
        }
        return subprocess.CompletedProcess(command, 0, yaml.safe_dump(document).encode(), b"")

    def stage(self, **kwargs):
        return api.stage(
            self.root,
            self.token,
            api.CONFIRMATION,
            runner=kwargs.pop("runner", self.encrypt),
            **kwargs,
        )

    def test_protected_token_is_retained_but_only_hash_enters_encryption(self):
        receipt = self.stage()
        token = self.token.read_text().strip()
        self.assertGreaterEqual(len(token), 43)
        self.assertEqual(self.token.stat().st_mode & 0o777, 0o600)
        doc = self.calls[0]
        self.assertEqual(doc["metadata"], {"name": "cv-api-auth", "namespace": "career-ops"})
        principals = json.loads(doc["stringData"]["principals.json"])
        import hashlib

        self.assertEqual(
            principals,
            {
                "schemaVersion": 1,
                "principals": [
                    {
                        "principalId": "career-ops-qualification",
                        "tokenSha256": [hashlib.sha256(token.encode()).hexdigest()],
                    }
                ],
            },
        )
        self.assertNotIn(token, json.dumps(receipt))
        self.assertNotIn(token, (self.root / api.TARGET).read_text())
        self.assertFalse((self.root / api.TARGET.parent / "kustomization.yaml").exists())
        with self.assertRaises(api.EnrollmentError):
            self.stage()

    def test_failed_encryption_keeps_same_token_for_retry_and_hides_output(self):
        def fail(command, **kwargs):
            return subprocess.CompletedProcess(command, 1, b"secret", b"sensitive")

        with self.assertRaises(api.EnrollmentError) as error:
            self.stage(runner=fail)
        self.assertNotIn("sensitive", str(error.exception))
        token = self.token.read_bytes()
        self.assertFalse((self.root / api.TARGET).exists())
        self.stage()
        self.assertEqual(self.token.read_bytes(), token)

    def test_refuses_unprotected_or_symlinked_token_without_consumption(self):
        self.token.write_text("x" * 43)
        self.token.chmod(0o644)
        with self.assertRaises(api.EnrollmentError):
            self.stage()
        self.token.unlink()
        other = self.private / "other"
        other.write_text("x" * 43)
        other.chmod(0o600)
        self.token.symlink_to(other)
        with self.assertRaises(api.EnrollmentError):
            self.stage()
        self.assertEqual(self.calls, [])

    def test_wrong_confirmation_never_generates_token(self):
        with self.assertRaises(api.EnrollmentError):
            api.stage(self.root, self.token, "wrong", runner=self.encrypt)
        self.assertFalse(self.token.exists())

    def test_ciphertext_cannot_contain_plaintext_or_wrong_identity(self):
        def corrupt(command, **kwargs):
            result = self.encrypt(command, **kwargs)
            d = yaml.safe_load(result.stdout)
            d["metadata"]["name"] = "other"
            result.stdout = yaml.safe_dump(d).encode()
            return result

        with self.assertRaises(api.EnrollmentError):
            self.stage(runner=corrupt)
        self.assertFalse((self.root / api.TARGET).exists())

    def test_concurrent_target_creation_is_never_overwritten(self):
        def changed(command, **kwargs):
            result = self.encrypt(command, **kwargs)
            (self.root / api.TARGET).write_text("other-writer")
            return result

        with self.assertRaises(api.EnrollmentError):
            self.stage(runner=changed)
        self.assertEqual((self.root / api.TARGET).read_text(), "other-writer")


if __name__ == "__main__":
    unittest.main()
