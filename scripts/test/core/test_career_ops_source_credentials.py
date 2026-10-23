"""Credential enrollment invariants; all credential values are synthetic."""

import copy
import json
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.repository import career_ops_source_credentials as source


class SourceCredentialTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        (self.root / source.TARGET.parent).mkdir(parents=True)
        self.selection = self.root / source.SELECTION
        self.selection.write_text(
            "resources:\n- ./gitrepository.yaml\n- ./application-kustomization.yaml\n"
        )
        self.git = self.selection.parent / "gitrepository.yaml"
        self.git.write_text(
            yaml.safe_dump(
                {
                    "metadata": {"name": "career-ops", "namespace": "career-ops"},
                    "spec": {
                        "suspend": True,
                        "url": source.ORIGIN + "/supermorphic/career-ops.git",
                        "ref": {"branch": "main"},
                        "secretRef": {"name": "career-ops-source"},
                    },
                }
            )
        )
        (self.selection.parent / "application-kustomization.yaml").write_text(
            yaml.safe_dump(
                {
                    "metadata": {"name": "career-ops-apps", "namespace": "career-ops"},
                    "spec": {
                        "suspend": True,
                        "path": "./deploy/",
                        "targetNamespace": "career-ops",
                        "sourceRef": {"kind": "GitRepository", "name": "career-ops"},
                        "serviceAccountName": "career-ops-reconciler",
                    },
                }
            )
        )
        (self.root / ".sops.yaml").write_text(
            "creation_rules:\n- path_regex: '^kubernetes/.*'\n"
            "  age: age1synthetic\n  encrypted_regex: '^(data|stringData)$'\n"
        )
        self.receipt = {
            "origin": source.ORIGIN,
            "username": "synthetic-reader",
            "password": "a" * 40,
            "token": {
                "id": 123,
                "name": "career-ops-flux-synthetic",
                "scopes": ["read:repository"],
                "repositories": ["supermorphic/career-ops"],
            },
        }
        self.name = self.receipt["token"]["name"]
        self.calls = []

    def encrypt(self, command, **kwargs):
        self.calls.append((command, kwargs))
        document = yaml.safe_load(kwargs["input"])
        document["stringData"] = {
            key: "ENC[AES256_GCM,synthetic]" for key in ("username", "password")
        }
        document["sops"] = {
            "age": [{"recipient": "age1synthetic"}],
            "encrypted_regex": "^(data|stringData)$",
            "mac": "ENC[AES256_GCM,synthetic]",
        }
        return subprocess.CompletedProcess(command, 0, yaml.safe_dump(document).encode(), b"")

    def install(self, receipt=None, runner=None):
        return source.install(
            self.root,
            receipt or self.receipt,
            self.name,
            source.CONFIRMATION,
            runner=runner or self.encrypt,
        )

    def test_installs_only_encrypted_secret_and_selects_it_without_unsuspending(self):
        result = self.install()
        target = self.root / source.TARGET
        manifest = yaml.safe_load(target.read_bytes())
        self.assertEqual(
            manifest["metadata"], {"name": "career-ops-source", "namespace": "career-ops"}
        )
        self.assertNotIn(self.receipt["password"], target.read_text())
        self.assertNotIn("password", result)
        self.assertEqual(result["token"], self.receipt["token"])
        self.assertEqual(
            yaml.safe_load(self.selection.read_bytes())["resources"][-1], source.RESOURCE
        )
        for name in ("gitrepository.yaml", "application-kustomization.yaml"):
            self.assertTrue(
                yaml.safe_load((self.selection.parent / name).read_bytes())["spec"]["suspend"]
            )
        command, kwargs = self.calls[0]
        self.assertIn("/dev/stdin", command)
        self.assertFalse(any(key.startswith("SOPS_AGE_") for key in kwargs["env"]))
        with self.assertRaises(source.EnrollmentError):
            self.install()

    def test_preparation_mode_is_removed(self):
        self.assertFalse(hasattr(source, "PREPARATION_TARGET"))
        with (
            patch("sys.argv", ["prog", "discover", "--preparation"]),
            patch("sys.stderr"),
            self.assertRaises(SystemExit) as raised,
        ):
            source.main()
        self.assertEqual(raised.exception.code, 2)
        with self.assertRaises(TypeError):
            source.install(
                self.root, self.receipt, self.name, source.CONFIRMATION, preparation=True
            )

    def test_rejects_broader_or_unbound_credentials_before_encryption(self):
        for changes in (
            {"scopes": ["write:repository"]},
            {"scopes": ["read:repository", "read:user"]},
            {"repositories": []},
            {"repositories": ["supermorphic/career-ops", "supermorphic/homelab-talos"]},
            {"name": "another-purpose"},
            {"id": True},
        ):
            receipt = copy.deepcopy(self.receipt)
            receipt["token"].update(changes)
            with self.subTest(changes=changes), self.assertRaises(source.EnrollmentError):
                self.install(receipt)
        self.assertEqual(self.calls, [])

    def test_wrong_origin_token_or_username_is_rejected_without_echo(self):
        for key, value in (
            ("origin", "https://example.invalid"),
            ("password", "bad-secret"),
            ("username", "a\nb"),
        ):
            receipt = copy.deepcopy(self.receipt)
            receipt[key] = value
            with self.assertRaises(source.EnrollmentError) as error:
                self.install(receipt)
            self.assertNotIn(value, str(error.exception))

    def test_failed_encryption_preserves_selection_and_hides_process_output(self):
        original = self.selection.read_bytes()

        def fail(command, **kwargs):
            return subprocess.CompletedProcess(
                command, 1, self.receipt["password"].encode(), b"sensitive"
            )

        with self.assertRaises(source.EnrollmentError) as error:
            self.install(runner=fail)
        self.assertNotIn(self.receipt["password"], str(error.exception))
        self.assertEqual(self.selection.read_bytes(), original)
        self.assertFalse((self.root / source.TARGET).exists())

    def test_confirmation_symlink_and_active_source_stop_before_secret_consumption(self):
        with self.assertRaises(source.EnrollmentError):
            source.install(self.root, self.receipt, self.name, "wrong", runner=self.encrypt)
        original = self.git.read_bytes()
        modified = yaml.safe_load(original)
        modified["spec"]["suspend"] = False
        self.git.write_text(yaml.safe_dump(modified))
        with self.assertRaises(source.EnrollmentError):
            self.install()
        self.git.write_bytes(original)
        self.selection.rename(self.selection.with_suffix(".saved"))
        self.selection.symlink_to(self.selection.with_suffix(".saved"))
        with self.assertRaises(source.EnrollmentError):
            self.install()
        self.assertEqual(self.calls, [])

    def test_wrong_source_binding_stops_before_encryption(self):
        manifest = yaml.safe_load(self.git.read_bytes())
        manifest["spec"]["url"] = "https://example.invalid/other.git"
        self.git.write_text(yaml.safe_dump(manifest))
        with self.assertRaises(source.EnrollmentError):
            self.install()
        self.assertEqual(self.calls, [])

    def test_changed_source_during_encryption_stops_before_selection(self):
        def changed(command, **kwargs):
            result = self.encrypt(command, **kwargs)
            manifest = yaml.safe_load(self.git.read_bytes())
            manifest["spec"]["ref"] = {"branch": "other"}
            self.git.write_text(yaml.safe_dump(manifest))
            return result

        with self.assertRaises(source.EnrollmentError):
            self.install(runner=changed)
        self.assertFalse((self.root / source.TARGET).exists())

    def test_ciphertext_contract_rejects_plaintext_wrong_recipient_and_wrong_secret(self):
        for field, replacement in (
            ("stringData", {"password": "plaintext", "username": "plaintext"}),
            ("metadata", {"name": "other", "namespace": "career-ops"}),
            ("sops", {"age": [{"recipient": "wrong"}]}),
        ):

            def corrupt(command, field=field, replacement=replacement, **kwargs):
                result = self.encrypt(command, **kwargs)
                document = yaml.safe_load(result.stdout)
                document[field] = replacement
                result.stdout = yaml.safe_dump(document).encode()
                return result

            with self.subTest(field=field), self.assertRaises(source.EnrollmentError):
                self.install(runner=corrupt)
            self.assertFalse((self.root / source.TARGET).exists())

    def test_fifo_rejects_regular_files_and_times_out_without_plaintext_artifact(self):
        path = self.root / "receipt.fifo"
        path.write_text(json.dumps(self.receipt))
        with self.assertRaises(source.EnrollmentError):
            source.read_fifo(path, timeout=0.01)
        path.unlink()
        os.mkfifo(path, 0o600)
        with self.assertRaises(source.EnrollmentError):
            source.read_fifo(path, timeout=0.01)
        self.assertFalse(path.exists())

    def test_streamed_receipt_is_read_once_and_fifo_is_removed(self):
        path = self.root / "receipt.fifo"
        os.mkfifo(path, 0o600)

        def send():
            with path.open("w") as stream:
                json.dump(self.receipt, stream)

        worker = threading.Thread(target=send)
        worker.start()
        try:
            self.assertEqual(source.read_fifo(path, timeout=2), self.receipt)
        finally:
            worker.join(timeout=2)
        self.assertFalse(path.exists())

    def test_selection_failure_rolls_back_new_ciphertext(self):
        original = self.selection.read_bytes()
        with (
            patch.object(source.os, "replace", side_effect=OSError("sensitive")),
            self.assertRaises(source.EnrollmentError),
        ):
            self.install()
        self.assertEqual(self.selection.read_bytes(), original)
        self.assertFalse((self.root / source.TARGET).exists())

    def test_concurrent_enrollment_is_blocked_before_creation(self):
        private = self.root / "private"
        private.mkdir(mode=0o700)
        with (
            source.enrollment_lock(private),
            self.assertRaises(source.EnrollmentError),
            source.enrollment_lock(private),
        ):
            self.fail("concurrent receiver acquired the enrollment lock")

    def test_resume_uses_the_recorded_name_instead_of_minting_a_new_token(self):
        private = self.root / "private"
        private.mkdir(mode=0o700)
        name = source.enrollment_name(private, "career-ops-flux-synthetic", "")
        self.assertEqual(name, "career-ops-flux-synthetic")
        self.assertEqual(source.enrollment_name(private, "career-ops-flux-different", name), name)
        with self.assertRaises(source.EnrollmentError):
            source.enrollment_name(private, "career-ops-flux-different", "career-ops-flux-unknown")

    def test_failed_sealing_then_resumed_delivery_installs_same_token(self):
        private = self.root / "private"
        private.mkdir(mode=0o700)
        name = source.enrollment_name(private, self.name, "")

        def fail(command, **kwargs):
            return subprocess.CompletedProcess(command, 1, b"", b"withheld")

        with self.assertRaises(source.EnrollmentError):
            self.install(runner=fail)
        resumed = source.enrollment_name(private, "career-ops-flux-other", name)
        result = source.install(
            self.root, self.receipt, resumed, source.CONFIRMATION, runner=self.encrypt
        )
        self.assertEqual(result["token"]["id"], self.receipt["token"]["id"])


if __name__ == "__main__":
    unittest.main()
