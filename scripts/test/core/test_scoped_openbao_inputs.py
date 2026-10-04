"""Scoped OpenBao tests keep Kubernetes selection separate from attended inputs."""

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.openbao import issuance, restore
from scripts.openbao.configuration import SafeError
from scripts.test import access
from scripts.test.scenarios import agent_credentials, openbao_issuance


class ScopedOpenBaoInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = self.directory / "selected-config"
        self.config.touch()
        self.run = self.directory / "synthetic-run"
        self.run.mkdir()
        self.environment = {
            "TEST_KUBECONFIG": str(self.config),
            "HOMELAB_TEST_RUN_DIR": str(self.run),
            # Deliberately invalid ambient operator input must not become a fallback.
            "OPENBAO_OPERATOR_KUBECONFIG": "/synthetic/unrelated/operator",
        }

    def test_issuance_uses_selected_config_without_operator_input(self):
        binding = {
            "suite_id": "test.openbao-issuance",
            "profile": "test-openbao-issuance",
            "run_id": self.run.name,
        }
        with (
            patch.dict(os.environ, self.environment, clear=True),
            patch.object(access, "validate_invocation", return_value=binding) as checked,
        ):
            scope, directory = openbao_issuance.run_scope()
        self.assertEqual(scope.kubeconfig, self.config)
        self.assertEqual(directory, self.run)
        checked.assert_called_once()

    def test_lifecycle_uses_selected_config_and_stays_standalone(self):
        binding = {
            "suite_id": "test.agent-credentials",
            "profile": "test-openbao-lifecycle",
            "run_id": self.run.name,
        }
        with (
            patch.dict(os.environ, self.environment, clear=True),
            patch.object(access, "validate_invocation", return_value=binding),
        ):
            config, directory = agent_credentials.run_inputs()
            self.assertEqual((config, directory), (self.config, self.run))
            os.environ["TEST_CAMPAIGN_LEASE_HOLDER"] = "unrelated-campaign"
            with self.assertRaises(SafeError):
                agent_credentials.run_inputs()

    def test_wrong_suite_run_or_auxiliary_binding_is_rejected_before_scope_use(self):
        base = {"suite_id": "test.openbao-issuance", "run_id": self.run.name}
        for change in (
            {"suite_id": "test.openbao-ha"},
            {"run_id": "another-run"},
            {"profile_check": "observer"},
            {"purpose": "campaign-observer"},
        ):
            with (
                self.subTest(change=change),
                patch.dict(os.environ, self.environment, clear=True),
                patch.object(access, "validate_invocation", return_value={**base, **change}),
                self.assertRaises(issuance.AcceptanceError),
            ):
                openbao_issuance.run_scope()

    def test_restore_namespace_is_fixed_but_each_run_has_fresh_workloads(self):
        for run in ("synthetic-run-a", "synthetic-run-b"):
            self.assertEqual(restore.namespace(run), "openbao-restore-test")
            documents = restore.documents(run, "2.7.0")
            self.assertEqual(
                {document["kind"] for document in documents},
                {"PersistentVolumeClaim", "StatefulSet"},
            )
            for document in documents:
                self.assertEqual(document["metadata"]["namespace"], "openbao-restore-test")
                self.assertEqual(document["metadata"]["annotations"][restore.OWNER], run)


class FixedRestoreAdapterTests(unittest.TestCase):
    def setUp(self):
        import copy

        from scripts.test.scenarios import openbao_restore

        self.adapter = openbao_restore
        self.cluster = openbao_restore.ScratchKube(
            Path("/synthetic/selected"), "synthetic-run", {}, None
        )
        self.baseline = {}
        documents = [
            {
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": {
                    "name": "openbao-restore-test",
                    "labels": {"pod-security.kubernetes.io/enforce": "restricted"},
                },
            },
            {
                "apiVersion": "v1",
                "kind": "ServiceAccount",
                "metadata": {"name": "scratch", "namespace": "openbao-restore-test"},
                "automountServiceAccountToken": False,
            },
            {
                "apiVersion": "cilium.io/v2",
                "kind": "CiliumNetworkPolicy",
                "metadata": {"name": "scratch-isolation", "namespace": "openbao-restore-test"},
                "spec": {
                    "endpointSelector": {},
                    "ingressDeny": [{"fromEntities": ["all"]}],
                    "egressDeny": [{"toEntities": ["all"]}],
                },
            },
            {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "RoleBinding",
                "metadata": {
                    "name": "homelab-test-openbao-restore-runtime",
                    "namespace": "openbao-restore-test",
                },
                "roleRef": {
                    "apiGroup": "rbac.authorization.k8s.io",
                    "kind": "Role",
                    "name": "homelab-test-openbao-restore-runtime",
                },
                "subjects": [
                    {
                        "kind": "ServiceAccount",
                        "name": "homelab-test-openbao-restore",
                        "namespace": "kube-system",
                    }
                ],
            },
        ]
        for document in documents:
            document["metadata"].update(uid="baseline-" + document["kind"], resourceVersion="12")
            self.baseline[(document["kind"], document["metadata"]["name"])] = document
        self.cluster.read = lambda expected: copy.deepcopy(
            self.baseline[(expected["kind"], expected["metadata"]["name"])]
        )

    def test_fixed_baseline_rejects_replaced_uid_policy_or_scratch_authority(self):
        import copy

        self.cluster.verify_baseline()
        for key, mutation in (
            (
                ("Namespace", "openbao-restore-test"),
                lambda d: d["metadata"].update(uid="replacement"),
            ),
            (("CiliumNetworkPolicy", "scratch-isolation"), lambda d: d["spec"].update(egress=[])),
            (("ServiceAccount", "scratch"), lambda d: d.update(automountServiceAccountToken=True)),
            (
                ("RoleBinding", "homelab-test-openbao-restore-runtime"),
                lambda d: d["subjects"].append(
                    {
                        "kind": "ServiceAccount",
                        "name": "scratch",
                        "namespace": "openbao-restore-test",
                    }
                ),
            ),
        ):
            with self.subTest(key=key):
                original = copy.deepcopy(self.baseline[key])
                mutation(self.baseline[key])
                with self.assertRaises(restore.RestoreError):
                    self.cluster.verify_baseline()
                self.baseline[key] = original

    def test_individual_deletions_keep_fixed_baseline_and_use_uid_resource_version(self):
        import copy

        self.cluster.verify_baseline()
        saved = copy.deepcopy(self.baseline)
        calls = []
        self.cluster.check = lambda: calls.append("fresh-lease")
        self.cluster.command = lambda *args, **kwargs: calls.append((args, kwargs))
        for kind, name, prefix in (
            (
                "StatefulSet",
                "scratch",
                "/apis/apps/v1/namespaces/openbao-restore-test/statefulsets/",
            ),
            (
                "PersistentVolumeClaim",
                "scratch-data",
                "/api/v1/namespaces/openbao-restore-test/persistentvolumeclaims/",
            ),
            ("Secret", "scratch-seal", "/api/v1/namespaces/openbao-restore-test/secrets/"),
            ("ConfigMap", "scratch-config", "/api/v1/namespaces/openbao-restore-test/configmaps/"),
        ):
            document = {
                "kind": kind,
                "metadata": {
                    "name": name,
                    "namespace": "openbao-restore-test",
                    "uid": "run-" + kind,
                    "resourceVersion": "99",
                    "annotations": {restore.OWNER: "synthetic-run"},
                },
            }
            self.baseline[(kind, name)] = document
            self.cluster.delete(document)
            import json

            body = json.loads(calls[-1][1]["input_bytes"])
            self.assertEqual(
                body["preconditions"], {"uid": "run-" + kind, "resourceVersion": "99"}
            )
            self.assertEqual(body["propagationPolicy"], "Foreground")
            self.assertIn(prefix + name, calls[-1][0])
            self.assertEqual(calls[-2], "fresh-lease")
        self.assertEqual({key: self.baseline[key] for key in saved}, saved)
        with self.assertRaises(restore.RestoreError):
            self.cluster.delete(saved[("Namespace", "openbao-restore-test")])
