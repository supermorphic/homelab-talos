"""Offline tests for the guarded Crawl4AI bootstrap Secret writer."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "scripts/repository/crawl4ai_secrets.py"
SPEC = importlib.util.spec_from_file_location("crawl4ai_secrets", MODULE_PATH)
assert SPEC and SPEC.loader
crawl4ai_secrets = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(crawl4ai_secrets)

RECIPIENT = "age1syntheticcrawl4airecipient000000000000000000000000000000"
API_TOKEN = "A" * 32
SIGNING_KEY = "B" * 40
TARGET = Path("kubernetes/apps/web-research/crawl4ai/app/bootstrap.sops.yaml")
KUSTOMIZATION = Path("kubernetes/apps/web-research/crawl4ai/app/kustomization.yaml")
RESOURCE = "./bootstrap.sops.yaml"


def encrypted_manifest(
    *,
    name="crawl4ai-bootstrap",
    namespace="web-research",
    recipient=RECIPIENT,
    encrypted_regex="^(data|stringData)$",
    keys=("api_token", "signing_key"),
):
    return yaml.safe_dump(
        {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": name, "namespace": namespace},
            "type": "Opaque",
            "stringData": {key: f"ENC[AES256_GCM,data:{key},iv:x,tag:y,type:str]" for key in keys},
            "sops": {
                "age": [{"recipient": recipient, "enc": "-----BEGIN AGE ENCRYPTED FILE-----"}],
                "encrypted_regex": encrypted_regex,
                "version": "3.11.0",
            },
        },
        sort_keys=False,
    ).encode()


class FakeRunner:
    def __init__(self, ciphertext=None, *, guard_returncode=0, sops_returncode=0):
        self.ciphertext = ciphertext or encrypted_manifest()
        self.guard_returncode = guard_returncode
        self.sops_returncode = sops_returncode
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append((command, kwargs))
        if command[:3] == ["just", "repo", "secrets"]:
            return subprocess.CompletedProcess(command, self.guard_returncode, b"", b"failure")
        if command[0] == "sops":
            return subprocess.CompletedProcess(
                command,
                self.sops_returncode,
                self.ciphertext if self.sops_returncode == 0 else b"",
                b"synthetic sops failure",
            )
        raise AssertionError(f"unexpected command: {command}")


class Crawl4AISecretsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        app = self.root / KUSTOMIZATION.parent
        app.mkdir(parents=True)
        (self.root / ".sops.yaml").write_text(
            yaml.safe_dump(
                {
                    "creation_rules": [
                        {
                            "path_regex": r"^kubernetes/.*\.sops\.ya?ml$",
                            "age": RECIPIENT,
                            "encrypted_regex": "^(data|stringData)$",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        (self.root / KUSTOMIZATION).write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\n"
            "kind: Kustomization\n"
            "namespace: web-research\n"
            "resources:\n"
            "  - ./deployment.yaml\n",
            encoding="utf-8",
        )
        self.environment = {
            "CRAWL4AI_API_TOKEN": API_TOKEN,
            "CRAWL4AI_SIGNING_KEY": SIGNING_KEY,
            "CRAWL4AI_SECRETS_CONFIRM": "write:web-research:crawl4ai:sops",
        }

    def run_writer(self, runner=None, **kwargs):
        return crawl4ai_secrets.write_bootstrap_secret(
            self.root,
            self.environment,
            runner=runner or FakeRunner(),
            **kwargs,
        )

    def test_initial_write_installs_valid_ciphertext_and_selects_it_once(self):
        runner = FakeRunner()
        self.run_writer(runner)

        target = self.root / TARGET
        manifest = yaml.safe_load(target.read_bytes())
        resources = yaml.safe_load((self.root / KUSTOMIZATION).read_text())["resources"]
        self.assertEqual(
            manifest["metadata"],
            {"name": "crawl4ai-bootstrap", "namespace": "web-research"},
        )
        self.assertEqual(set(manifest["stringData"]), {"api_token", "signing_key"})
        self.assertEqual(resources.count(RESOURCE), 1)
        self.assertEqual(runner.calls[0][0], ["just", "repo", "secrets"])
        sops_command, sops_options = runner.calls[1]
        self.assertEqual(sops_command[0], "sops")
        self.assertEqual(
            sops_options["input"],
            yaml.safe_dump(
                {
                    "apiVersion": "v1",
                    "kind": "Secret",
                    "metadata": {
                        "name": "crawl4ai-bootstrap",
                        "namespace": "web-research",
                    },
                    "type": "Opaque",
                    "stringData": {
                        "api_token": API_TOKEN,
                        "signing_key": SIGNING_KEY,
                    },
                },
                sort_keys=False,
            ).encode(),
        )
        for path in self.root.rglob("*"):
            if path.is_file():
                content = path.read_bytes()
                self.assertNotIn(API_TOKEN.encode(), content)
                self.assertNotIn(SIGNING_KEY.encode(), content)

    def test_values_must_be_at_least_32_printable_ascii_characters(self):
        invalid_values = (
            "x" * 31,
            "x" * 4097,
            "x" * 31 + "\n",
            "x" * 31 + "\x7f",
            "x" * 31 + "é",
        )
        for suffix in ("API_TOKEN", "SIGNING_KEY"):
            variable = f"CRAWL4AI_{suffix}"
            for invalid in invalid_values:
                with self.subTest(variable=variable, invalid=repr(invalid)):
                    environment = dict(self.environment)
                    environment[variable] = invalid
                    runner = FakeRunner()
                    with self.assertRaises(crawl4ai_secrets.SecretWriteError) as caught:
                        crawl4ai_secrets.write_bootstrap_secret(
                            self.root, environment, runner=runner
                        )
                    self.assertNotIn(invalid, str(caught.exception))
                    self.assertEqual(runner.calls, [])
                    self.assertFalse((self.root / TARGET).exists())

    def test_values_at_the_4096_character_native_limit_are_accepted(self):
        self.environment["CRAWL4AI_API_TOKEN"] = "A" * 4096
        self.environment["CRAWL4AI_SIGNING_KEY"] = "B" * 4096
        self.run_writer()
        self.assertTrue((self.root / TARGET).is_file())

    def test_confirmation_must_match_exactly(self):
        for confirmation in (
            None,
            "write:web-research:crawl4ai",
            "write:web-research:crawl4ai:sops ",
        ):
            environment = dict(self.environment)
            if confirmation is None:
                environment.pop("CRAWL4AI_SECRETS_CONFIRM")
            else:
                environment["CRAWL4AI_SECRETS_CONFIRM"] = confirmation
            runner = FakeRunner()
            with self.assertRaisesRegex(crawl4ai_secrets.SecretWriteError, "confirmation"):
                crawl4ai_secrets.write_bootstrap_secret(self.root, environment, runner=runner)
            self.assertEqual(runner.calls, [])

    def test_inconsistent_existing_file_and_resource_selection_are_refused(self):
        cases = ((True, False), (False, True))
        for target_exists, resource_selected in cases:
            with self.subTest(target_exists=target_exists, resource_selected=resource_selected):
                if target_exists:
                    (self.root / TARGET).write_bytes(encrypted_manifest())
                kustomization = yaml.safe_load((self.root / KUSTOMIZATION).read_text())
                if resource_selected:
                    kustomization["resources"].append(RESOURCE)
                (self.root / KUSTOMIZATION).write_text(
                    yaml.safe_dump(kustomization), encoding="utf-8"
                )
                before = {
                    path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()
                }
                runner = FakeRunner()
                with self.assertRaisesRegex(crawl4ai_secrets.SecretWriteError, "inconsistent"):
                    self.run_writer(runner)
                self.assertEqual(runner.calls, [])
                self.assertEqual(
                    before,
                    {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()},
                )
                if target_exists:
                    (self.root / TARGET).unlink()
                clean = yaml.safe_load((self.root / KUSTOMIZATION).read_text())
                clean["resources"] = ["./deployment.yaml"]
                (self.root / KUSTOMIZATION).write_text(yaml.safe_dump(clean), encoding="utf-8")

    def test_equivalent_noncanonical_resource_path_is_refused(self):
        kustomization = yaml.safe_load((self.root / KUSTOMIZATION).read_text())
        kustomization["resources"].append("bootstrap.sops.yaml")
        (self.root / KUSTOMIZATION).write_text(yaml.safe_dump(kustomization), encoding="utf-8")
        runner = FakeRunner()
        with self.assertRaisesRegex(crawl4ai_secrets.SecretWriteError, "inconsistent"):
            self.run_writer(runner)
        self.assertEqual(runner.calls, [])
        self.assertFalse((self.root / TARGET).exists())

    def test_existing_artifact_must_match_the_repository_contract(self):
        (self.root / TARGET).write_bytes(encrypted_manifest(name="wrong-name"))
        kustomization = yaml.safe_load((self.root / KUSTOMIZATION).read_text())
        kustomization["resources"].append(RESOURCE)
        (self.root / KUSTOMIZATION).write_text(yaml.safe_dump(kustomization), encoding="utf-8")
        before = (self.root / TARGET).read_bytes()
        runner = FakeRunner()
        with self.assertRaisesRegex(crawl4ai_secrets.SecretWriteError, "existing"):
            self.run_writer(runner)
        self.assertEqual(runner.calls, [])
        self.assertEqual((self.root / TARGET).read_bytes(), before)

    def test_malformed_ciphertext_never_changes_existing_files(self):
        original_kustomization = (self.root / KUSTOMIZATION).read_bytes()
        bad_candidates = (
            encrypted_manifest(namespace="wrong"),
            encrypted_manifest(keys=("api_token", "signing_key", "consumer_jwt")),
            encrypted_manifest(recipient="age1wrong"),
            encrypted_manifest(encrypted_regex=".*"),
            encrypted_manifest().replace(
                b"ENC[AES256_GCM,data:api_token,iv:x,tag:y,type:str]",
                b"ENC[garbage]",
            ),
            encrypted_manifest() + API_TOKEN.encode(),
        )
        for candidate in bad_candidates:
            with self.subTest(candidate=candidate[-40:]):
                with self.assertRaisesRegex(crawl4ai_secrets.SecretWriteError, "ciphertext"):
                    self.run_writer(FakeRunner(candidate))
                self.assertFalse((self.root / TARGET).exists())
                self.assertEqual((self.root / KUSTOMIZATION).read_bytes(), original_kustomization)

    def test_external_change_to_existing_ciphertext_is_preserved(self):
        target = self.root / TARGET
        target.write_bytes(encrypted_manifest())
        kustomization = yaml.safe_load((self.root / KUSTOMIZATION).read_text())
        kustomization["resources"].append(RESOURCE)
        (self.root / KUSTOMIZATION).write_text(yaml.safe_dump(kustomization), encoding="utf-8")
        concurrent = encrypted_manifest().replace(b"api_token,iv", b"concurrent,iv")

        class ConcurrentRunner(FakeRunner):
            def __call__(runner_self, command, **kwargs):
                result = super().__call__(command, **kwargs)
                if command[0] == "sops":
                    target.write_bytes(concurrent)
                return result

        with self.assertRaisesRegex(crawl4ai_secrets.SecretWriteError, "changed"):
            self.run_writer(ConcurrentRunner())
        self.assertEqual(target.read_bytes(), concurrent)

    def test_external_change_to_kustomization_is_preserved(self):
        kustomization_path = self.root / KUSTOMIZATION
        concurrent = kustomization_path.read_bytes() + b"# concurrent edit\n"

        class ConcurrentRunner(FakeRunner):
            def __call__(runner_self, command, **kwargs):
                result = super().__call__(command, **kwargs)
                if command[0] == "sops":
                    kustomization_path.write_bytes(concurrent)
                return result

        with self.assertRaisesRegex(crawl4ai_secrets.SecretWriteError, "changed"):
            self.run_writer(ConcurrentRunner())
        self.assertEqual(kustomization_path.read_bytes(), concurrent)
        self.assertFalse((self.root / TARGET).exists())

    def test_external_command_failures_preserve_files_and_hide_command_output(self):
        original_kustomization = (self.root / KUSTOMIZATION).read_bytes()
        for runner, expected in (
            (FakeRunner(guard_returncode=1), "age-identity check failed"),
            (FakeRunner(sops_returncode=1), "SOPS encryption failed"),
        ):
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(crawl4ai_secrets.SecretWriteError, expected) as caught:
                    self.run_writer(runner)
                self.assertNotIn("synthetic sops failure", str(caught.exception))
                self.assertFalse((self.root / TARGET).exists())
                self.assertEqual((self.root / KUSTOMIZATION).read_bytes(), original_kustomization)

    def test_failed_second_install_rolls_back_the_initial_write(self):
        original_kustomization = (self.root / KUSTOMIZATION).read_bytes()
        real_replace = os.replace

        def fail_kustomization(source, destination):
            if Path(destination) == self.root / KUSTOMIZATION:
                raise OSError("synthetic replacement failure")
            real_replace(source, destination)

        with self.assertRaisesRegex(crawl4ai_secrets.SecretWriteError, "install"):
            self.run_writer(replace=fail_kustomization)
        self.assertFalse((self.root / TARGET).exists())
        self.assertEqual((self.root / KUSTOMIZATION).read_bytes(), original_kustomization)

    def test_existing_ciphertext_is_atomically_replaced_without_duplicate_resource(self):
        target = self.root / TARGET
        target.write_bytes(encrypted_manifest())
        kustomization = yaml.safe_load((self.root / KUSTOMIZATION).read_text())
        kustomization["resources"].append(RESOURCE)
        (self.root / KUSTOMIZATION).write_text(yaml.safe_dump(kustomization), encoding="utf-8")
        replacement = encrypted_manifest().replace(b"api_token,iv", b"replacement,iv")
        self.run_writer(FakeRunner(replacement))
        self.assertEqual(target.read_bytes(), replacement)
        resources = yaml.safe_load((self.root / KUSTOMIZATION).read_text())["resources"]
        self.assertEqual(resources.count(RESOURCE), 1)


if __name__ == "__main__":
    unittest.main()
