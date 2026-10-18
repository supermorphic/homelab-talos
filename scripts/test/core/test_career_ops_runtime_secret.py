"""Runtime Secret enrollment tests use synthetic private profiles only."""

import contextlib
import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.repository import career_ops_runtime_secret as runtime


class RuntimeSecretTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / runtime.TARGET.parent).mkdir(parents=True)
        (self.root / ".sops.yaml").write_text(
            "creation_rules:\n- path_regex: '^kubernetes/.*'\n"
            "  age: age1synthetic\n  encrypted_regex: '^(data|stringData)$'\n"
        )
        self.binding = {
            "domain": "career_ops",
            "application": "cv_render",
            "database": "career_ops",
            "schema": "cv_render",
            "role": runtime.ROLE,
            "credentialGeneration": 1,
        }
        self.password = "synthetic-runtime-candidate-" + "q" * 32
        self.calls = []

    def encrypt(self, command, **kwargs):
        self.calls.append((command, kwargs))
        document = yaml.safe_load(kwargs["input"])
        self.assertEqual(
            document["metadata"], {"name": "cv-render-database", "namespace": "career-ops"}
        )
        self.assertEqual(json.loads(document["stringData"]["binding.json"]), self.binding)
        self.assertEqual(document["stringData"]["username"], runtime.ROLE)
        self.assertEqual(document["stringData"]["password"], self.password)
        document["stringData"] = {
            key: f"ENC[AES256_GCM,synthetic-generation-{self.binding['credentialGeneration']}]"
            for key in document["stringData"]
        }
        document["sops"] = {
            "age": [{"recipient": "age1synthetic"}],
            "encrypted_regex": "^(data|stringData)$",
            "mac": "ENC[AES256_GCM,synthetic]",
        }
        return subprocess.CompletedProcess(command, 0, yaml.safe_dump(document).encode(), b"")

    def install(self, runner=None, material=None, **options):
        @contextlib.contextmanager
        def credential():
            yield material or (self.binding, self.password)

        return runtime.install(
            self.root,
            options.pop("confirmation", runtime.CONFIRMATION),
            credential=credential,
            runner=runner or self.encrypt,
            **options,
        )

    def replacement(self):
        self.install()
        target = self.root / runtime.TARGET
        checksum = hashlib.sha256(target.read_bytes()).hexdigest()
        self.binding["credentialGeneration"] = 2
        self.password = "synthetic-rotated-candidate-" + "r" * 32
        self.calls.clear()
        return {
            "confirmation": "replace:career-ops:cv-render-database",
            "replace_sha256": checksum,
            "expected_generation": 2,
        }

    def test_replacement_requires_reviewed_ciphertext_and_current_new_generation(self):
        options = self.replacement()
        result = self.install(**options)
        self.assertEqual(result["credentialGeneration"], 2)
        self.assertEqual(result["replaced_ciphertext_sha256"], options["replace_sha256"])
        self.assertEqual(len(self.calls), 1)
        self.assertNotIn(self.password, (self.root / runtime.TARGET).read_text())
        self.assertNotEqual(
            hashlib.sha256((self.root / runtime.TARGET).read_bytes()).hexdigest(),
            options["replace_sha256"],
        )

    def test_invalid_replacement_guards_preserve_existing_ciphertext_before_credentials(self):
        options = self.replacement()
        target = self.root / runtime.TARGET
        original = target.read_bytes()
        cases = [
            options | {"confirmation": runtime.CONFIRMATION},
            options | {"replace_sha256": "0" * 64},
            options | {"replace_sha256": None},
            options | {"replace_sha256": "not-a-digest"},
            options | {"expected_generation": None},
            options | {"expected_generation": 1},
            options | {"expected_generation": True},
        ]
        @contextlib.contextmanager
        def unread():
            self.fail("Credentials accessed before replacement preflight")
            yield
        for case in cases:
            with self.subTest(case=case), self.assertRaises(runtime.EnrollmentError):
                confirmation = case.pop("confirmation")
                runtime.install(self.root, confirmation, credential=unread, **case)
            self.assertEqual(target.read_bytes(), original)

    def test_wrong_generation_and_encryption_failure_preserve_replacement_target(self):
        options = self.replacement()
        target = self.root / runtime.TARGET
        original = target.read_bytes()
        with self.assertRaises(runtime.EnrollmentError):
            self.install(**(options | {"expected_generation": 3}))
        self.assertEqual(self.calls, [])
        with self.assertRaises(runtime.EnrollmentError):
            self.install(runner=lambda *a, **kw: subprocess.CompletedProcess(a, 1, b"", b""), **options)
        self.assertEqual(target.read_bytes(), original)

    def test_concurrent_change_during_replacement_is_preserved(self):
        options = self.replacement()
        def changed(command, **kwargs):
            result = self.encrypt(command, **kwargs)
            (self.root / runtime.TARGET).write_bytes(b"independent ciphertext change")
            return result
        with self.assertRaises(runtime.EnrollmentError):
            self.install(runner=changed, **options)
        self.assertEqual((self.root / runtime.TARGET).read_bytes(), b"independent ciphertext change")

    def test_replacement_rejects_symlink_and_missing_target(self):
        options = self.replacement()
        target = self.root / runtime.TARGET
        original = target.read_bytes()
        target.unlink()
        with self.assertRaises(runtime.EnrollmentError):
            self.install(**options)
        elsewhere = target.parent / "other.yaml"
        elsewhere.write_bytes(original)
        target.symlink_to(elsewhere)
        with self.assertRaises(runtime.EnrollmentError):
            self.install(**options)
        self.assertEqual(elsewhere.read_bytes(), original)
        self.assertEqual(self.calls, [])

    def test_stages_only_ciphertext_without_selecting_or_activating_resources(self):
        result = self.install()
        target = self.root / runtime.TARGET
        self.assertTrue(target.exists())
        self.assertNotIn(self.password, target.read_text())
        self.assertEqual(result["credentialGeneration"], 1)
        self.assertNotIn("password", json.dumps(result))
        self.assertFalse((target.parent / "kustomization.yaml").exists())
        command, arguments = self.calls[0]
        self.assertIn("/dev/stdin", command)
        self.assertNotIn(self.password, " ".join(command))
        self.assertFalse(any(k.startswith("SOPS_AGE_") for k in arguments["env"]))
        with self.assertRaises(runtime.EnrollmentError):
            self.install()

    def test_package_login_stages_only_its_own_secret_and_binding(self):
        login = runtime.LOGINS["application_packages"]
        self.assertEqual(
            login.role, "app_187a49fe010fd1f0424566c383befb58_integration"
        )
        package = {
            "domain": "career_ops",
            "application": "application_packages",
            "database": "career_ops",
            "schema": "package_access",
            "role": login.role,
            "credentialGeneration": 1,
        }
        (self.root / runtime.TARGET).write_bytes(b"existing runtime ciphertext")

        def encrypt(command, **kwargs):
            document = yaml.safe_load(kwargs["input"])
            self.assertEqual(
                document["metadata"],
                {"name": "application-packages-database", "namespace": "career-ops"},
            )
            self.assertEqual(document["stringData"]["username"], login.role)
            self.assertIn(login.target.as_posix(), command)
            document["stringData"] = {
                key: "ENC[AES256_GCM,synthetic]" for key in document["stringData"]
            }
            document["sops"] = {
                "age": [{"recipient": "age1synthetic"}],
                "encrypted_regex": "^(data|stringData)$",
                "mac": "ENC[AES256_GCM,synthetic]",
            }
            return subprocess.CompletedProcess(command, 0, yaml.safe_dump(document).encode(), b"")

        @contextlib.contextmanager
        def credential(material):
            yield material

        for confirmation, material in (
            (runtime.CONFIRMATION, (package, self.password)),
            (login.confirmation, (self.binding, self.password)),
        ):
            with self.subTest(confirmation=confirmation), self.assertRaises(runtime.EnrollmentError):
                runtime.install(
                    self.root, confirmation, credential=lambda m=material: credential(m),
                    runner=encrypt, login=login,
                )
        self.assertFalse((self.root / login.target).exists())
        result = runtime.install(
            self.root, login.confirmation,
            credential=lambda: credential((package, self.password)), runner=encrypt, login=login,
        )
        self.assertEqual(result["path"], login.target.as_posix())
        self.assertEqual((self.root / runtime.TARGET).read_bytes(), b"existing runtime ciphertext")

    def test_rejects_wrong_binding_generation_and_extra_fields(self):
        for change in (
            {"schema": "app"},
            {"role": "career_ops_migrator"},
            {"credentialGeneration": True},
            {"credentialGeneration": 0},
            {"password": self.password},
        ):
            with self.subTest(change=change), self.assertRaises(runtime.EnrollmentError):
                self.install(material=(self.binding | change, self.password))
        self.assertEqual(self.calls, [])

    def test_failed_encryption_and_plaintext_output_are_not_installed_or_echoed(self):
        for code in (0, 1):

            def bad(command, code=code, **kwargs):
                return subprocess.CompletedProcess(
                    command, code, kwargs["input"], self.password.encode()
                )

            with self.assertRaises(runtime.EnrollmentError) as error:
                self.install(runner=bad)
            self.assertNotIn(self.password, str(error.exception))
            self.assertFalse((self.root / runtime.TARGET).exists())

    def test_concurrent_target_is_never_replaced(self):
        def racing(command, **kwargs):
            result = self.encrypt(command, **kwargs)
            (self.root / runtime.TARGET).write_bytes(b"concurrent ciphertext")
            return result

        with self.assertRaises(runtime.EnrollmentError):
            self.install(runner=racing)
        self.assertEqual((self.root / runtime.TARGET).read_bytes(), b"concurrent ciphertext")

    def test_rejects_profile_override_before_reading_credentials(self):
        with (
            patch.dict("os.environ", {"AUTOMATION_DATA_SERVICE_FILE": "/synthetic"}),
            self.assertRaises(runtime.EnrollmentError),
            runtime.runtime_credential(),
        ):
            self.fail("Explicit profile override accepted")

    def test_real_sops_encrypts_all_application_keys_with_public_recipient(self):
        if not shutil.which("sops"):
            self.skipTest("Run through the pinned mise toolchain for real SOPS coverage")
        repository = Path(__file__).resolve().parents[3]
        (self.root / ".sops.yaml").write_bytes((repository / ".sops.yaml").read_bytes())
        result = self.install(runner=subprocess.run)
        encrypted = yaml.safe_load((self.root / runtime.TARGET).read_bytes())
        self.assertEqual(set(encrypted["stringData"]), {"username", "password", "binding.json"})
        self.assertTrue(
            all(v.startswith("ENC[AES256_GCM,") for v in encrypted["stringData"].values())
        )
        self.assertEqual(result["status"], "ciphertext-staged")
        old_sha256 = result["ciphertext_sha256"]
        self.binding["credentialGeneration"] = 2
        rotated = self.install(
            runner=subprocess.run,
            confirmation="replace:career-ops:cv-render-database",
            replace_sha256=old_sha256,
            expected_generation=2,
        )
        self.assertEqual(rotated["credentialGeneration"], 2)
        self.assertEqual(rotated["replaced_ciphertext_sha256"], old_sha256)
        self.assertNotEqual(rotated["ciphertext_sha256"], old_sha256)

    def test_changed_profile_after_encryption_prevents_installation(self):
        @contextlib.contextmanager
        def changed():
            yield self.binding, self.password
            raise runtime.EnrollmentError("Profile changed")

        with self.assertRaises(runtime.EnrollmentError):
            runtime.install(
                self.root, runtime.CONFIRMATION, credential=changed, runner=self.encrypt
            )
        self.assertFalse((self.root / runtime.TARGET).exists())

    def test_changed_profile_during_replacement_preserves_existing_ciphertext(self):
        options = self.replacement()
        target = self.root / runtime.TARGET
        original = target.read_bytes()
        @contextlib.contextmanager
        def changed():
            yield self.binding, self.password
            raise runtime.EnrollmentError("Profile changed")
        with self.assertRaises(runtime.EnrollmentError):
            runtime.install(
                self.root, options.pop("confirmation"), credential=changed,
                runner=self.encrypt, **options,
            )
        self.assertEqual(target.read_bytes(), original)

    def test_wrong_sops_policy_and_symlink_target_fail_before_password_access(self):
        @contextlib.contextmanager
        def unread():
            self.fail("Password accessed before filesystem preflight")
            yield

        (self.root / ".sops.yaml").write_text("creation_rules: []\n")
        with self.assertRaises(runtime.EnrollmentError):
            runtime.install(self.root, runtime.CONFIRMATION, credential=unread)
        (self.root / runtime.TARGET).symlink_to(self.root / "absent")
        with self.assertRaises(runtime.EnrollmentError):
            runtime.install(self.root, runtime.CONFIRMATION, credential=unread)

    def test_sops_policy_change_during_encryption_prevents_installation(self):
        def changed(command, **kwargs):
            result = self.encrypt(command, **kwargs)
            policy = self.root / ".sops.yaml"
            policy.write_bytes(policy.read_bytes() + b"\n")
            return result

        with self.assertRaises(runtime.EnrollmentError):
            self.install(runner=changed)
        self.assertFalse((self.root / runtime.TARGET).exists())

    def test_real_profile_parser_and_authentication_fail_closed(self):
        from automation_data_access import ProfileMetadata

        with tempfile.TemporaryDirectory() as private:
            directory = Path(private).resolve()
            directory.chmod(0o700)
            generation = directory / "generation-1"
            generation.mkdir(mode=0o700)
            passfile = generation / "credential.pgpass"
            passfile.write_text(f"127.0.0.1:15432:career_ops:{runtime.ROLE}:{self.password}\n")
            passfile.chmod(0o600)
            service = directory / "service.conf"
            section = f"automation_data_career_ops_{runtime.ROLE}"
            service.write_text(
                f"[{section}]\nhost=127.0.0.1\nport=15432\n"
                f"dbname=career_ops\nuser={runtime.ROLE}\n"
                f"passfile={passfile}\nsslmode=disable\n"
            )
            service.chmod(0o600)
            selected = ProfileMetadata(
                "ready",
                service,
                section,
                15432,
                self.binding,
                automatic=True,
            )
            with (
                patch.object(runtime, "select_connection_profile", return_value=selected),
                patch.object(runtime, "revalidate_connection_profile"),
                patch.object(runtime, "assert_profile_unchanged"),
                patch.object(
                    runtime, "private_database_tunnel", return_value=contextlib.nullcontext(15432)
                ),
                patch.object(runtime, "authenticate_candidate") as authenticate,
            ):
                with runtime.runtime_credential() as material:
                    self.assertEqual(material, (self.binding, self.password))
                authenticate.assert_called_once_with(
                    15432, "career_ops", runtime.ROLE, self.password
                )
                authenticate.side_effect = runtime.EnrollmentError("Authentication failed")
                with self.assertRaises(runtime.EnrollmentError):
                    runtime.install(self.root, runtime.CONFIRMATION, runner=self.encrypt)
                self.assertEqual(self.calls, [])
                self.assertFalse((self.root / runtime.TARGET).exists())


if __name__ == "__main__":
    unittest.main()
