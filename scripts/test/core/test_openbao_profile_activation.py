"""Issuance activation requires deployed guards, exact grants and fixed programs."""

import copy
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.openbao import guards
from scripts.openbao.configuration import SafeError


class AgentProfileActivationTests(unittest.TestCase):
    def setUp(self):
        self.expected = [
            {
                "apiVersion": "v1",
                "kind": "ServiceAccount",
                "metadata": {"name": "homelab-test-runner", "namespace": "kube-system"},
                "automountServiceAccountToken": False,
            },
            {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "Role",
                "metadata": {"name": "fixture", "namespace": "automation"},
                "rules": [
                    {"apiGroups": ["batch"], "resources": ["jobs"], "verbs": ["create", "delete"]}
                ],
            },
            {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "RoleBinding",
                "metadata": {"name": "fixture", "namespace": "automation"},
                "roleRef": {
                    "apiGroup": "rbac.authorization.k8s.io",
                    "kind": "Role",
                    "name": "fixture",
                },
                "subjects": [
                    {
                        "kind": "ServiceAccount",
                        "name": "homelab-test-runner",
                        "namespace": "kube-system",
                    }
                ],
            },
            {
                "apiVersion": "admissionregistration.k8s.io/v1",
                "kind": "ValidatingAdmissionPolicy",
                "metadata": {"name": "fixture"},
                "spec": {
                    "failurePolicy": "Fail",
                    "matchConstraints": {
                        "resourceRules": [
                            {
                                "apiGroups": ["batch"],
                                "apiVersions": ["v1"],
                                "operations": ["CREATE"],
                                "resources": ["jobs"],
                            }
                        ]
                    },
                    "matchConditions": [
                        {
                            "name": "identity",
                            "expression": "request.userInfo.username == 'system:serviceaccount:kube-system:homelab-test-runner'",
                        }
                    ],
                    "validations": [{"expression": "object.metadata.name == 'fixture'"}],
                },
            },
            {
                "apiVersion": "admissionregistration.k8s.io/v1",
                "kind": "ValidatingAdmissionPolicyBinding",
                "metadata": {"name": "fixture"},
                "spec": {"policyName": "fixture", "validationActions": ["Deny"]},
            },
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {"name": "n8n-test-helpers-v1", "namespace": "automation"},
                "immutable": True,
                "data": {"fixed.sh": "#!/bin/sh\nexit 0\n"},
            },
            {
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": {
                    "name": "openbao-restore-test",
                    "labels": {"pod-security.kubernetes.io/enforce": "restricted"},
                },
            },
            {
                "apiVersion": "cilium.io/v2",
                "kind": "CiliumNetworkPolicy",
                "metadata": {"name": "isolation", "namespace": "openbao-restore-test"},
                "spec": {
                    "endpointSelector": {},
                    "ingressDeny": [{"fromEntities": ["all"]}],
                    "egressDeny": [{"toEntities": ["all"]}],
                },
            },
        ]
        self.actual = copy.deepcopy(self.expected)
        for index, item in enumerate(self.actual):
            item["metadata"].update(uid=f"synthetic-{index}", resourceVersion="1")
            if item["kind"] == "ValidatingAdmissionPolicy":
                item["metadata"]["generation"] = 2
                item["status"] = {"observedGeneration": 2, "typeChecking": {}}
                item["spec"]["matchConstraints"].update(
                    matchPolicy="Equivalent", namespaceSelector={}, objectSelector={}
                )
                item["spec"]["matchConstraints"]["resourceRules"][0]["scope"] = "*"
            if item["kind"] == "RoleBinding":
                item["subjects"][0]["apiGroup"] = ""
            if item["kind"] == "Namespace":
                item["metadata"]["labels"]["kubernetes.io/metadata.name"] = "openbao-restore-test"
                item["spec"] = {"finalizers": ["kubernetes"]}
        self.calls = []

    def kube(self, config, *args):
        self.calls.append(args)
        if "secret" in args:
            self.assertIn("go-template", args)
            self.assertNotIn("json", args)
            return {
                "name": "nocodb-restore-application-credential",
                "namespace": "automation-data",
                "uid": "synthetic-secret",
                "type": "Opaque",
                "label": "nocodb-restore-extension",
            }
        kinds = args[args.index("get") + 1].split(",")
        aliases = {
            "serviceaccounts": "ServiceAccount",
            "roles": "Role",
            "rolebindings": "RoleBinding",
            "leases": "Lease",
            "clusterroles": "ClusterRole",
            "clusterrolebindings": "ClusterRoleBinding",
            "validatingadmissionpolicies": "ValidatingAdmissionPolicy",
            "validatingadmissionpolicybindings": "ValidatingAdmissionPolicyBinding",
            "namespaces": "Namespace",
            "configmap": "ConfigMap",
            "ciliumnetworkpolicy": "CiliumNetworkPolicy",
        }
        found = [d for d in self.actual if d["kind"] in {aliases[k] for k in kinds}]
        if "--all-namespaces" in args or len(kinds) > 1 or kinds[0] == "namespaces":
            return {"items": found}
        namespace = args[args.index("-n") + 1]
        name = args[args.index("get") + 2]
        found = [
            d
            for d in found
            if d["metadata"].get("namespace") == namespace and d["metadata"]["name"] == name
        ]
        return found[0] if len(found) == 1 else {}

    def run_guard(self):
        with (
            patch.object(guards, "_agent_profile_source", return_value=self.expected),
            patch.object(guards, "kube", side_effect=self.kube),
        ):
            return guards.require_agent_profiles_ready(Path("/synthetic/operator"))

    def test_exact_deployed_controls_allow_known_api_defaults_without_secret_values(self):
        result = self.run_guard()
        self.assertEqual(len(result["object_uids"]), len(self.expected) + 1)
        self.assertEqual(len(result["source_digest"]), 64)
        self.assertFalse(any("secrets" in call for call in self.calls))

    def test_missing_object_extra_grants_or_bypassed_admission_block_activation(self):
        mutations = [
            lambda docs: docs.pop(0),
            lambda docs: docs[1]["rules"][0]["verbs"].append("patch"),
            lambda docs: docs[1].update(aggregationRule={"clusterRoleSelectors": [{}]}),
            lambda docs: docs[2]["subjects"].append(
                {"kind": "ServiceAccount", "name": "other", "namespace": "kube-system"}
            ),
            lambda docs: docs[3]["spec"].update(failurePolicy="Ignore"),
            lambda docs: docs[3]["spec"]["matchConstraints"].update(
                excludeResourceRules=[
                    {
                        "apiGroups": ["*"],
                        "apiVersions": ["*"],
                        "resources": ["*"],
                        "operations": ["*"],
                    }
                ]
            ),
            lambda docs: docs[4]["spec"].update(
                matchResources={"namespaceSelector": {"matchLabels": {"bypass": "true"}}}
            ),
            lambda docs: docs[4]["spec"].update(validationActions=["Warn"]),
            lambda docs: docs[5]["data"].update({"fixed.sh": "changed"}),
            lambda docs: docs[5].update(immutable=False),
            lambda docs: docs[0].update(automountServiceAccountToken=True),
            lambda docs: docs[0].update(secrets=[{"name": "unexpected"}]),
            lambda docs: docs[7]["spec"].update(egress=[{"toEntities": ["all"]}]),
        ]
        original = copy.deepcopy(self.actual)
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                self.actual = copy.deepcopy(original)
                mutate(self.actual)
                with self.assertRaises(SafeError):
                    self.run_guard()

    def test_completed_warning_free_typechecking_allows_omitted_empty_result(self):
        # The status controller advances observedGeneration after checking; the
        # API can omit the empty result when earlier warnings have been cleared.
        for result in ({}, {"typeChecking": {}}, {"typeChecking": {"expressionWarnings": []}}):
            with self.subTest(result=result):
                self.actual[3]["status"] = {"observedGeneration": 2, **result}
                self.assertIn("object_uids", self.run_guard())

    def test_omitted_empty_variables_preserve_exact_policy_comparison(self):
        self.expected[3]["spec"]["variables"] = []
        self.assertIn("object_uids", self.run_guard())
        self.actual[3]["spec"]["variables"] = [{"name": "unexpected", "expression": "true"}]
        with self.assertRaises(SafeError):
            self.run_guard()

    def test_current_generation_and_warning_free_typechecking_are_required(self):
        for status in (
            {},
            {"observedGeneration": 1},
            {"observedGeneration": 1, "typeChecking": {}},
            {"observedGeneration": "2", "typeChecking": {}},
            {"observedGeneration": 2, "typeChecking": None},
            {"observedGeneration": 2, "typeChecking": []},
            {"observedGeneration": 2, "typeChecking": {"expressionWarnings": {}}},
            {"observedGeneration": 2, "typeChecking": {"expressionWarnings": None}},
            {
                "observedGeneration": 2,
                "typeChecking": {
                    "expressionWarnings": [
                        {"fieldRef": "spec.validations[0]", "warning": "invalid"}
                    ]
                },
            },
        ):
            with self.subTest(status=status):
                self.actual[3]["status"] = status
                with self.assertRaises(SafeError):
                    self.run_guard()

    def test_invalid_policy_generations_do_not_prove_completed_checks(self):
        for generation in (None, True, 0, -1, "2"):
            with self.subTest(generation=generation):
                self.actual[3]["metadata"]["generation"] = generation
                self.actual[3]["status"] = {"observedGeneration": generation, "typeChecking": {}}
                with self.assertRaises(SafeError):
                    self.run_guard()

    def test_replaced_object_changes_frozen_target(self):
        first = self.run_guard()
        self.actual[0]["metadata"]["uid"] = "replacement"
        self.assertNotEqual(first, self.run_guard())

    def test_additional_binding_to_a_registered_account_blocks_activation(self):
        self.actual.append(
            {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "ClusterRoleBinding",
                "metadata": {"name": "unexpected", "uid": "unexpected"},
                "roleRef": {
                    "apiGroup": "rbac.authorization.k8s.io",
                    "kind": "ClusterRole",
                    "name": "cluster-admin",
                },
                "subjects": [
                    {
                        "kind": "ServiceAccount",
                        "name": "homelab-test-runner",
                        "namespace": "kube-system",
                    }
                ],
            }
        )
        with self.assertRaises(SafeError):
            self.run_guard()

    def test_credential_fixture_metadata_must_match_without_returning_data(self):
        original = self.kube
        for change in (
            {"type": "kubernetes.io/service-account-token"},
            {"uid": ""},
            {"label": "other"},
        ):

            def wrong_metadata(config, *args, change=change):
                result = original(config, *args)
                return {**result, **change} if "secret" in args else result

            with (
                patch.object(guards, "_agent_profile_source", return_value=self.expected),
                patch.object(guards, "kube", side_effect=wrong_metadata),
                self.assertRaises(SafeError),
            ):
                guards.require_agent_profiles_ready(Path("/synthetic/operator"))


class AgentProfileSourceTests(unittest.TestCase):
    def test_rendered_activation_inventory_has_all_identities_programs_and_restore_baseline(self):
        documents = guards._agent_profile_source()
        self.assertEqual(
            {
                d["metadata"]["name"]
                for d in documents
                if d["kind"] == "ServiceAccount"
                and d["metadata"].get("namespace") == "kube-system"
            },
            {
                "homelab-observer",
                "homelab-diagnostic",
                "homelab-test-runner",
                "homelab-report-publisher",
                "homelab-campaign-coordinator",
                "homelab-test-flux-restart",
                "homelab-test-cilium-connectivity",
                "homelab-test-node-reschedule",
                "homelab-test-conformance",
                "homelab-test-openbao-issuance",
                "homelab-test-openbao-ha",
                "homelab-test-openbao-restore",
                "homelab-test-openbao-lifecycle",
            },
        )
        self.assertEqual(
            {d["metadata"]["name"] for d in documents if d["kind"] == "ConfigMap"},
            {
                "n8n-test-helpers-v1",
                "automation-data-test-helpers-v1",
                "nocodb-test-helpers-v1",
                "n8n-test-request-helpers-v1",
                "qbit-manage-test-helpers-v1",
            },
        )
        self.assertEqual(
            {
                d["kind"]
                for d in documents
                if d["metadata"].get("namespace", d["metadata"]["name"]) == "openbao-restore-test"
            },
            {"Namespace", "ServiceAccount", "CiliumNetworkPolicy", "Role", "RoleBinding"},
        )
        self.assertFalse(any(d["kind"] == "Secret" for d in documents))


class RestoreFixturePreparationTests(unittest.TestCase):
    def test_independent_restore_fixture_remains_active_while_server_units_are_staged(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            (package / "app").mkdir()
            recipient = "age1" + "a" * 58
            (package / "app/openbao-seal.sops.yaml").write_text(
                yaml.safe_dump(
                    {
                        "metadata": {"name": "openbao-seal", "namespace": "openbao"},
                        "data": {"key": "ENC[AES256_GCM,synthetic]"},
                        "sops": {"age": [{"recipient": recipient}]},
                    }
                )
            )
            (package / "app/kustomization.yaml").write_text(
                yaml.safe_dump({"resources": ["openbao-seal.sops.yaml"]})
            )
            units = [
                {
                    "metadata": {"name": name, "uid": name},
                    "spec": {
                        "path": f"./synthetic/{name}",
                        "sourceRef": {"kind": "GitRepository", "name": "flux-system"},
                        "suspend": name != "openbao-restore-test",
                    },
                }
                for name in ("openbao", "openbao-prerequisites", "openbao-restore-test")
            ]
            (package / "ks.yaml").write_text(yaml.safe_dump_all(units))

            def kube(config, *args):
                if "namespace" in args:
                    return {"metadata": {"uid": "synthetic-cluster"}}
                if "namespaces" in args:
                    return {"items": []}
                return {"items": units}

            with (
                patch.object(guards, "PACKAGE", package),
                patch.object(guards, "source_revision", return_value="a" * 40),
                patch.object(guards, "require_deployed_revision"),
                patch("scripts.openbao.secrets.validate_recipient"),
                patch.object(guards, "kube", side_effect=kube),
                patch.dict(os.environ, {"OPENBAO_RECOVERY_RECIPIENT": recipient}),
            ):
                self.assertEqual(
                    guards.freeze_target(Path("/synthetic/operator"), "prepare")["cluster_uid"],
                    "synthetic-cluster",
                )
                with (
                    patch.object(
                        guards,
                        "require_agent_profiles_ready",
                        side_effect=SafeError("read-denied"),
                    ) as activation,
                    self.assertRaisesRegex(SafeError, "read-denied"),
                ):
                    guards.freeze_target(Path("/synthetic/operator"), "config-apply")
                activation.assert_called_once_with(Path("/synthetic/operator"))
                units[0]["spec"]["suspend"] = False
                with self.assertRaises(SafeError):
                    guards.freeze_target(Path("/synthetic/operator"), "prepare")
