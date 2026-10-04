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
        fixture = json.loads((ROOT / "scripts/test/cel/kubernetes-schema.json").read_text())
        resource_types = {
            (item["group"], item["version"], item["resource"]) for item in fixture["resources"]
        }
        parameter_types = {
            (item["group"], item["version"], item["kind"]) for item in fixture["resources"]
        }
        # These CRD schemas are checked by the deployed status guard. Require an
        # explicit decision for new groups instead of silently skipping a type.
        custom_groups = {
            "cilium.io",
            "kustomize.toolkit.fluxcd.io",
            "policy.networking.k8s.io",
            "source.toolkit.fluxcd.io",
        }
        for policy in policies:
            for rule in policy["spec"]["matchConstraints"]["resourceRules"]:
                for group in rule["apiGroups"]:
                    if group in custom_groups or "*" in group:
                        continue
                    for version in rule["apiVersions"]:
                        for resource in rule["resources"]:
                            if "*" not in version + resource and "/" not in resource:
                                self.assertIn((group, version, resource), resource_types)
            if param := policy["spec"].get("paramKind"):
                group, _, version = param["apiVersion"].rpartition("/")
                self.assertIn((group, version, param["kind"]), parameter_types)
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
        fixture = json.loads((ROOT / "scripts/test/cel/kubernetes-schema.json").read_text())
        self.assertIn(f"/v1.{minor}.{patch}/", fixture["source"])

    def test_schema_checker_rejects_iteration_over_typed_resources(self):
        for group, resource in (("", "namespaces"), ("", "nodes"), ("apps", "deployments")):
            with self.subTest(resource=resource):
                policy = {
                    "metadata": {"name": "schema-negative-control"},
                    "spec": {
                        "matchConstraints": {
                            "resourceRules": [
                                {
                                    "apiGroups": [group],
                                    "apiVersions": ["v1"],
                                    "resources": [resource],
                                    "operations": ["UPDATE"],
                                }
                            ]
                        },
                        "validations": [{"expression": "object.metadata.all(k, true)"}],
                    },
                }
                result = self.compile([policy])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cannot be range of a comprehension", result.stderr)
                policy["spec"]["validations"][0]["expression"] = (
                    "dyn(object).metadata.all(k, true)"
                )
                result = self.compile([policy])
                self.assertEqual(result.returncode, 0, result.stderr)

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
