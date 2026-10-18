"""API credential delivery invariants; values are synthetic."""

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

from scripts.repository import career_ops_api_secret as api


class ApiSecretFixture(unittest.TestCase):
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


class ApiSecretTest(ApiSecretFixture):
    def test_protected_token_is_retained_but_only_hash_enters_encryption(self):
        receipt = self.stage()
        token = self.token.read_text().strip()
        self.assertGreaterEqual(len(token), 43)
        self.assertEqual(self.token.stat().st_mode & 0o777, 0o600)
        doc = self.calls[0]
        self.assertEqual(doc["metadata"], {"name": "cv-api-auth", "namespace": "career-ops"})
        principals = json.loads(doc["stringData"]["principals.json"])
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


class PackageEnrollmentTest(ApiSecretFixture):
    def setUp(self):
        super().setUp()
        self.stage()
        self.qualification = self.token.read_bytes()
        self.reviewed = hashlib.sha256((self.root / api.TARGET).read_bytes()).hexdigest()
        operators = self.root / "operator"
        operators.mkdir(mode=0o700)
        self.operator = operators / "token"
        self.calls.clear()

    def replace(self, **kwargs):
        return api.stage(
            self.root,
            self.token,
            kwargs.pop("confirmation", api.REPLACE_CONFIRMATION),
            operator_token_file=kwargs.pop("operator_token_file", self.operator),
            replace_sha256=kwargs.pop("replace_sha256", self.reviewed),
            runner=kwargs.pop("runner", self.encrypt),
        )

    def test_operator_principal_is_added_and_qualification_bearer_is_kept(self):
        receipt = self.replace()
        operator = self.operator.read_text().strip()
        self.assertEqual(self.operator.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.token.read_bytes(), self.qualification)
        principals = json.loads(self.calls[0]["stringData"]["principals.json"])
        self.assertEqual(
            principals,
            {
                "schemaVersion": 2,
                "principals": [
                    {
                        "principalId": "career-ops-qualification",
                        "tokenSha256": [hashlib.sha256(self.qualification.strip()).hexdigest()],
                        "capabilities": ["render"],
                    },
                    {
                        "principalId": "career-ops-operator",
                        "tokenSha256": [hashlib.sha256(operator.encode()).hexdigest()],
                        "capabilities": ["packages:read", "packages:write"],
                    },
                ],
            },
        )
        self.assertEqual(receipt["replaced_ciphertext_sha256"], self.reviewed)
        self.assertNotIn(operator, json.dumps(receipt))
        self.assertNotIn(operator, (self.root / api.TARGET).read_text())

    def test_unreviewed_or_incomplete_replacement_preserves_ciphertext_and_tokens(self):
        original = (self.root / api.TARGET).read_bytes()
        for case in (
            {"confirmation": api.CONFIRMATION},
            {"replace_sha256": "0" * 64},
            {"replace_sha256": None},
            {"replace_sha256": "not-a-digest"},
            {"operator_token_file": None},
            {"operator_token_file": self.token},
        ):
            with self.subTest(case=case), self.assertRaises(api.EnrollmentError):
                self.replace(**case)
            self.assertEqual((self.root / api.TARGET).read_bytes(), original)
        self.assertFalse(self.operator.exists())
        self.assertEqual(self.calls, [])

    def test_replacement_never_mints_a_qualification_bearer(self):
        self.token.unlink()
        with self.assertRaises(OSError):
            self.replace()
        self.assertFalse(self.token.exists())
        self.assertEqual(self.calls, [])

    def test_concurrent_ciphertext_change_is_preserved(self):
        def changed(command, **kwargs):
            result = self.encrypt(command, **kwargs)
            (self.root / api.TARGET).write_text("other-writer")
            return result

        with self.assertRaises(api.EnrollmentError):
            self.replace(runner=changed)
        self.assertEqual((self.root / api.TARGET).read_text(), "other-writer")


if __name__ == "__main__":
    unittest.main()
