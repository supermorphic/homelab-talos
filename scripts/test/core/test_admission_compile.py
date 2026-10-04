"""Kubernetes compilation complements the existing CEL request evaluation tests."""

import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]


class AdmissionCompileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.binary = str(Path(cls.temporary.name) / "admission-compile")
        subprocess.run(
            ["go", "build", "-mod=readonly", "-o", cls.binary, "."],
            cwd=ROOT / "scripts/test/cel",
            check=True,
        )

    def compile(self, policies):
        return subprocess.run(
            [self.binary], input=json.dumps(policies), capture_output=True, text=True, check=False
        )

    def test_rendered_admission_policies_compile(self):
        policies = []
        for relative in (
            "kubernetes/apps/kube-system/agent-access/app",
            "kubernetes/apps/monitoring/test-reports/app",
        ):
            rendered = subprocess.run(
                ["kustomize", "build", str(ROOT / relative)],
                capture_output=True,
                text=True,
                check=True,
            )
            policies.extend(
                doc
                for doc in yaml.safe_load_all(rendered.stdout)
                if doc and doc.get("kind") == "ValidatingAdmissionPolicy"
            )
        self.assertGreater(len(policies), 0)
        result = self.compile(policies)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_compiler_dependency_matches_deployed_kubernetes_version(self):
        cluster = yaml.safe_load((ROOT / "talos/talconfig.yaml").read_text())
        _, minor, patch = cluster["kubernetesVersion"].removeprefix("v").split(".")
        module = (ROOT / "scripts/test/cel/go.mod").read_text()
        compiler = (ROOT / "scripts/test/cel/main.go").read_text()
        for dependency in ("api", "apimachinery", "apiserver"):
            self.assertRegex(module, rf"(?m)^\s*k8s\.io/{dependency} v0\.{minor}\.{patch}$")
        self.assertEqual(
            re.findall(r"version\.MajorMinor\((\d+), (\d+)\)", compiler), [("1", minor)]
        )

    def test_compiler_enforces_homogeneous_literals_and_variable_types(self):
        for expression in (
            '{"selector": {"app": "fixture"}, "rules": [{"port": 80}]} == object.spec',
            'variables.count == "wrong-type"',
        ):
            with self.subTest(expression=expression):
                result = self.compile(
                    [
                        {
                            "metadata": {"name": "compiler-negative-control"},
                            "spec": {
                                "variables": [{"name": "count", "expression": "1"}],
                                "validations": [{"expression": expression}],
                            },
                        }
                    ]
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("compiler-negative-control: validations[0]", result.stderr)

    def test_message_expression_cannot_use_authorizer(self):
        result = self.compile(
            [
                {
                    "metadata": {"name": "message-negative-control"},
                    "spec": {
                        "validations": [
                            {
                                "expression": "true",
                                "messageExpression": 'authorizer.requestResource.check("get").allowed() ? "ok" : "denied"',
                            }
                        ]
                    },
                }
            ]
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("validations[0].messageExpression", result.stderr)
        self.assertIn("undeclared reference to 'authorizer'", result.stderr)


if __name__ == "__main__":
    unittest.main()
