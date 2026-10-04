"""Registered entrypoints carry invocation paths into direct and nested backends."""

import json
import os
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]


class RecipeRoutingTests(unittest.TestCase):
    def test_catalog_dispatch_never_selects_legacy_credentials(self):
        catalog = yaml.safe_load((ROOT / "tests/catalog.yaml").read_text())
        for entry in catalog["suites"]:
            for argument in entry.get("dispatch", {}).get("args", []):
                with self.subTest(suite=entry["metadata"]["id"]):
                    self.assertFalse(argument.endswith(".kube/config"))

    def test_conformance_public_recipe_does_not_choose_an_operator_config(self):
        result = subprocess.run(
            ["just", "--dry-run", "kube", "conformance"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertNotIn(".kube/config", result.stdout + result.stderr)

    def test_public_kube_wrappers_leave_credential_selection_to_coordinator(self):
        data = json.loads(
            subprocess.check_output(["just", "--dump", "--dump-format", "json"], cwd=ROOT)
        )
        checked = 0
        for name, recipe in data["modules"]["kube"]["recipes"].items():
            body = repr(recipe["body"])
            if "scripts/test/run-catalog-suite.sh" not in body:
                continue
            with self.subTest(recipe=name):
                self.assertNotIn("['variable', 'kubeconfig']", body)
                self.assertNotIn("TEST_KUBECONFIG=", body)
            checked += 1
        self.assertGreater(checked, 20)

    def test_komga_uses_registered_placeholder_and_openbao_tests_need_no_admin_config(self):
        recipes = json.loads(
            subprocess.check_output(["just", "--dump", "--dump-format", "json"], cwd=ROOT)
        )["modules"]["kube"]["recipes"]
        self.assertIn("['variable', 'test_kubeconfig']", repr(recipes["komga-acceptance"]["body"]))
        for name in (
            "openbao-restore-drill",
            "openbao-issuance-test",
            "openbao-ha-test",
            "agent-credentials-test",
        ):
            with self.subTest(recipe=name):
                self.assertNotIn("OPENBAO_OPERATOR_KUBECONFIG", repr(recipes[name]["body"]))

    def test_nested_just_backends_receive_selected_invocation_config(self):
        selected = "/synthetic/private/invocation/config"
        for name in ("_flux-restart-raw", "_flux-canary-test-raw"):
            with self.subTest(recipe=name):
                result = subprocess.run(
                    ["just", "--dry-run", "kube", name],
                    cwd=ROOT,
                    env={**os.environ, "TEST_KUBECONFIG": selected},
                    capture_output=True,
                    text=True,
                    check=True,
                )
                output = result.stdout + result.stderr
                self.assertIn(selected, output)
                self.assertNotIn(".kube/config", output)

    def test_chainsaw_script_branches_do_not_select_another_credential(self):
        def scripts(value):
            if isinstance(value, dict):
                operation = value.get("script")
                if isinstance(operation, dict) and "content" in operation:
                    yield operation["content"]
                for child in value.values():
                    yield from scripts(child)
            elif isinstance(value, list):
                for child in value:
                    yield from scripts(child)

        violations = []
        for path in (ROOT / "tests/chainsaw").rglob("chainsaw-test.yaml"):
            document = yaml.safe_load(path.read_text())
            for content in scripts(document):
                if any(
                    forbidden in content
                    for forbidden in (".kube/config", "--context", "use-context", "set-context")
                ):
                    violations.append(str(path.relative_to(ROOT)))
        self.assertEqual(violations, [], "Every try/catch/finally must retain selected access")


if __name__ == "__main__":
    unittest.main()
