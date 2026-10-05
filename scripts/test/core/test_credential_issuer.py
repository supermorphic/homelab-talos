"""Issuer slices prove authenticated requests without full application acceptance."""

import re
import unittest
from pathlib import Path
from unittest.mock import Mock
from xml.etree import ElementTree as ET

from scripts.openbao.configuration import SafeError
from scripts.test import access
from scripts.test.core import test_dedicated_profiles as helpers

ROOT = Path(__file__).resolve().parents[3]


class IssuerSliceTests(unittest.TestCase):
    def test_native_selector_matches_scenarios_and_excludes_other_cases(self):
        from scripts.test.scenarios import credential_issuer as issuer

        args = issuer.cilium_arguments(Path("/synthetic/run"))
        selector = re.compile(args[args.index("--test") + 1])
        for name in (
            "no-policies",
            "client-ingress",
            "client-ingress-knp",
            "pod-to-pod-encryption-v2",
            "ingress-from-specific-namespace-ccnp",
        ):
            self.assertIsNotNone(selector.search(name + "/native-scenario"))
        for name in ("no-policies-extra/native", "check-log-errors/native", "foreign/no-policies"):
            self.assertIsNone(selector.search(name))

    def test_slices_bind_only_their_existing_dedicated_identity(self):
        for target, profile in (
            ("cilium", "test-cilium-connectivity"),
            ("openbao-ha", "test-openbao-ha"),
            ("openbao-restore", "test-openbao-restore"),
        ):
            with self.subTest(target=target):
                binding = access.resolve_suite_access(ROOT, "test.credential-issuer." + target)
                self.assertEqual(binding["profile"], profile)
                self.assertNotIn("openbao-operator", binding["prerequisites"])
                self.assertNotIn("openbao-recovery", binding["prerequisites"])

    def test_allowed_requests_are_server_dry_runs_for_exact_native_fixtures(self):
        from scripts.test.scenarios import credential_issuer as issuer

        for target, kind, namespace in (
            ("openbao-ha", "Pod", "openbao-acceptance"),
            ("openbao-restore", "ConfigMap", "openbao-restore-test"),
        ):
            client = Mock()
            path, document = issuer.allowed_request(target, "synthetic-run")
            self.assertTrue(path.endswith("?dryRun=All"))
            self.assertEqual(document["kind"], kind)
            self.assertEqual(document["metadata"]["namespace"], namespace)
            client.request.return_value = (201, document)
            issuer.prove_allowed(client, target, "synthetic-run")
            self.assertEqual(client.request.call_args.args[1], path)
            for reply in (
                (403, {"reason": "Forbidden"}),
                (200, document),
                (201, {**document, "kind": "Secret"}),
                (201, {**document, "metadata": {"name": "foreign", "namespace": namespace}}),
            ):
                client.request.return_value = reply
                with self.assertRaises(SafeError):
                    issuer.prove_allowed(client, target, "synthetic-run")
        with self.assertRaises(SafeError):
            issuer.allowed_request("observer", "synthetic-run")

    def test_native_cilium_requires_all_selected_cases_and_a_late_authenticated_case(self):
        from scripts.test.scenarios import credential_issuer as issuer

        root = ET.Element("testsuite")
        properties = ET.SubElement(root, "properties")
        interval = ET.SubElement(
            properties, "property", name="Args", value="--post-test-sleep|6s|--verbose"
        )
        console = "[.] Action [ingress-from-specific-namespace-ccnp/ccnp-client-to-client:ping-synthetic: peers]"
        selected = {
            0: "no-policies",
            4: "client-ingress",
            5: "client-ingress-knp",
            56: "pod-to-pod-encryption-v2",
            129: "ingress-from-specific-namespace-ccnp",
        }
        for i in range(132):
            case = ET.SubElement(root, "testcase", name=selected.get(i, "synthetic-" + str(i)))
            if i not in selected:
                ET.SubElement(case, "skipped")
        result = issuer.cilium_window(root, 1200, console)
        self.assertEqual(result["status"], "pass")
        self.assertGreaterEqual(result["minimum_late_case_seconds"], 695)
        with self.assertRaises(SafeError):
            issuer.cilium_window(root, 694, console)
        with self.assertRaises(SafeError):
            issuer.cilium_window(root, 1200, "")
        interval.set("value", "--post-test-sleep|1s")
        with self.assertRaises(SafeError):
            issuer.cilium_window(root, 1200, console)
        interval.set("value", "--post-test-sleep|6s|--verbose")
        late = root[-3]
        root.remove(late)
        root.insert(101, late)
        with self.assertRaises(SafeError):
            issuer.cilium_window(root, 1200, console)
        root.remove(late)
        root.insert(130, late)
        ET.SubElement(late, "skipped")
        with self.assertRaises(SafeError):
            issuer.cilium_window(root, 1200, console)


class IssuerRequestPolicyTests(unittest.TestCase):
    setUpClass = classmethod(helpers.DedicatedFluxMutationTests.setUpClass.__func__)
    policy = helpers.DedicatedFluxMutationTests.policy
    evaluate = helpers.DedicatedFluxMutationTests.evaluate
    admits = helpers.DedicatedFluxMutationTests.admits

    def request(self, target, document):
        return {
            "operation": "CREATE",
            "namespace": document["metadata"]["namespace"],
            "name": document["metadata"]["name"],
            "subResource": "",
            "resource": {
                "group": "",
                "version": "v1",
                "resource": "pods" if target == "openbao-ha" else "configmaps",
            },
            "userInfo": {"username": "system:serviceaccount:kube-system:homelab-test-" + target},
        }

    def test_positive_fixture_shapes_pass_independent_admission(self):
        from scripts.test.scenarios import credential_issuer as issuer

        for target, policy in (
            ("openbao-ha", "homelab-test-openbao-probe-pods"),
            ("openbao-restore", "homelab-test-openbao-restore-private"),
        ):
            _, doc = issuer.allowed_request(target, "synthetic-run")
            self.assertTrue(self.admits(policy, self.request(target, doc), doc))

    def test_restore_denial_has_only_a_forbidden_target_not_an_invalid_program(self):
        from scripts.test import scoped_access_acceptance as acceptance

        client = acceptance.LiveClient(Path("/synthetic/config"), lambda: None)
        client.request = Mock(return_value=(403, {}))
        client.admission_denial("test-openbao-restore")
        doc = client.request.call_args.kwargs["payload"]
        policy = "homelab-test-openbao-restore-private"
        self.assertFalse(self.admits(policy, self.request("openbao-restore", doc), doc))
        doc["metadata"]["name"] = "scratch-config"
        self.assertTrue(self.admits(policy, self.request("openbao-restore", doc), doc))


if __name__ == "__main__":
    unittest.main()
