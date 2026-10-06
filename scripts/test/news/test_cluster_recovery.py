"""Independent invariants for disposable, loopback-only recovery resources."""

import copy
import importlib
import json
import unittest


class ClusterRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.module = importlib.import_module("scripts.test.news.cluster_recovery")

    def test_resource_graph_uses_only_run_storage_and_secret_references(self):
        resources = self.module.resources("abcdef123456")
        claims = {o["metadata"]["name"] for o in resources if o["kind"] == "PersistentVolumeClaim"}
        self.assertEqual(len(claims), 5)
        pod = self.module.pod("abcdef123456", "source")
        spec = pod["spec"]
        self.assertFalse(spec["automountServiceAccountToken"])
        self.assertEqual(spec["restartPolicy"], "Never")
        self.assertLessEqual(spec["activeDeadlineSeconds"], 1800)
        self.assertFalse(spec.get("hostNetwork", False))
        self.assertNotIn("hostAliases", spec)
        for container in spec["containers"]:
            security = container["securityContext"]
            self.assertFalse(security["allowPrivilegeEscalation"])
            self.assertTrue(security["readOnlyRootFilesystem"])
            self.assertEqual(security["capabilities"]["drop"], ["ALL"])
            self.assertGreater(security["runAsUser"], 0)
            for env in container.get("env", []):
                if "PASSWORD" in env["name"]:
                    self.assertNotIn("value", env)
                    self.assertEqual(
                        env["valueFrom"]["secretKeyRef"]["name"],
                        "news-drill-abcdef123456-credentials",
                    )
        self.assertTrue(
            all(
                v["persistentVolumeClaim"]["claimName"] in claims
                for v in spec["volumes"]
                if "persistentVolumeClaim" in v
            )
        )

    def test_recovery_shares_only_the_read_only_paired_backup_claim(self):
        source = self.module.pod("abcdef123456", "source")["spec"]
        target = self.module.pod("abcdef123456", "restored", "set-1234567890-ABC123")["spec"]

        def claims(pod):
            return {
                v["persistentVolumeClaim"]["claimName"]
                for v in pod["volumes"]
                if "persistentVolumeClaim" in v
            }

        self.assertEqual(claims(source) & claims(target), {"news-drill-abcdef123456-backups"})
        helper = next(c for c in target["containers"] if c["name"] == "helper")
        self.assertTrue(
            next(v for v in helper["volumeMounts"] if v["name"] == "backups")["readOnly"]
        )
        app = next(c for c in target["containers"] if c["name"] == "app")
        self.assertIn({"name": "NEWS_POLLING_ENABLED", "value": "false"}, app["env"])

    def test_fresh_filesystem_root_entries_are_outside_article_data(self):
        import tempfile
        from pathlib import Path, PurePosixPath

        spec = self.module.pod("abcdef123456", "restored", "set-1234567890-ABC123")["spec"]
        relative_paths = []
        for container in spec["containers"]:
            if container["name"] not in {"app", "helper"}:
                continue
            mount = next(m for m in container["volumeMounts"] if m["name"] == "app-data")
            data = next(e["value"] for e in container["env"] if e["name"] == "DATA_PATH")
            relative = PurePosixPath(data).relative_to(mount["mountPath"])
            relative_paths.append(relative)
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "lost+found").mkdir()
                target = root / relative
                target.mkdir(exist_ok=True)
                self.assertEqual(list(target.iterdir()), [])
        self.assertEqual(relative_paths[0], relative_paths[1])

    def test_invalid_resource_inputs_fail_before_any_client_call(self):
        for run, phase, selected in (
            ("../outside", "source", ""),
            ("abcdef123456", "production", ""),
            ("abcdef123456", "restored", "../set-123-ABC123"),
        ):
            with self.subTest(run=run, phase=phase), self.assertRaises(ValueError):
                self.module.pod(run, phase, selected)

    def test_public_config_contains_no_generated_passwords(self):
        resources = self.module.resources("abcdef123456")
        secret = next(o for o in resources if o["kind"] == "Secret")
        public = json.dumps([o for o in resources if o["kind"] != "Secret"])
        for value in secret["stringData"].values():
            if value != "reader":
                self.assertNotIn(value, public)


class NewsAdmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests

        TestAccessPolicyTests.setUpClass()
        cls.documents = TestAccessPolicyTests.documents
        cls.env = TestAccessPolicyTests.env
        cls.programs = {}

    def policy(self, name):
        from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests

        return TestAccessPolicyTests.policy(self, name)

    def evaluate(self, expression, activation):
        from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests

        return TestAccessPolicyTests.evaluate(self, expression, activation)

    def admits(self, name, obj, operation="CREATE"):
        from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests

        resource = {
            "Pod": "pods",
            "Secret": "secrets",
            "ConfigMap": "configmaps",
            "PersistentVolumeClaim": "persistentvolumeclaims",
        }[obj["kind"]]
        request = {
            "operation": operation,
            "namespace": obj["metadata"]["namespace"],
            "name": obj["metadata"]["name"],
            "subResource": "",
            "resource": {"group": "", "version": "v1", "resource": resource},
            "userInfo": {"username": "system:serviceaccount:kube-system:homelab-test-runner"},
        }
        return TestAccessPolicyTests.admits(
            self,
            name,
            request,
            obj if operation != "DELETE" else None,
            obj if operation == "DELETE" else None,
        )

    def test_fixed_pods_allow_phases_and_reject_boundary_changes(self):
        from scripts.test.news import cluster_recovery as module

        for phase, selected in (("source", ""), ("restored", "set-1234567890-ABC123")):
            obj = module.pod("abcdef123456", phase, selected)
            self.assertTrue(self.admits("homelab-test-news-pods", obj))
            for key, value in (
                ("hostNetwork", True),
                ("automountServiceAccountToken", True),
                ("nodeName", "synthetic-node"),
                ("serviceAccountName", "privileged"),
            ):
                bad = copy.deepcopy(obj)
                bad["spec"][key] = value
                self.assertFalse(self.admits("homelab-test-news-pods", bad), key)
            bad = copy.deepcopy(obj)
            bad["spec"]["containers"][0]["command"] = ["sh", "-c", "arbitrary"]
            self.assertFalse(self.admits("homelab-test-news-pods", bad))
            bad = copy.deepcopy(obj)
            bad["spec"]["volumes"][0] = {"name": "app-data", "hostPath": {"path": "/"}}
            self.assertFalse(self.admits("homelab-test-news-pods", bad))
            bad = copy.deepcopy(obj)
            bad["spec"]["containers"][0]["env"][6]["valueFrom"]["secretKeyRef"]["name"] = (
                "production"
            )
            self.assertFalse(self.admits("homelab-test-news-pods", bad))

    def test_core_api_converted_pods_are_admitted(self):
        import subprocess
        import tempfile
        from pathlib import Path

        from scripts.test.news import cluster_recovery as module

        with tempfile.TemporaryDirectory() as temporary:
            binary = str(Path(temporary) / "pod-unstructured")
            subprocess.run(
                ["go", "build", "-mod=readonly", "-o", binary, "./pod-unstructured"],
                cwd=module.ROOT / "scripts/test/cel",
                check=True,
                capture_output=True,
            )
            for phase, selected in (("source", ""), ("restored", "set-1234567890-ABC123")):
                pod = module.pod("abcdef123456", phase, selected)
                converted = json.loads(
                    subprocess.check_output([binary], input=json.dumps(pod).encode())
                )
                self.assertTrue(self.admits("homelab-test-news-pods", converted), phase)

    def test_claims_cannot_adopt_existing_storage(self):
        from scripts.test.news import cluster_recovery as module

        obj = next(
            o for o in module.resources("abcdef123456") if o["kind"] == "PersistentVolumeClaim"
        )
        self.assertTrue(self.admits("homelab-test-news-inputs", obj))
        for key, value in (
            ("volumeName", "production-volume"),
            ("dataSource", {"kind": "PersistentVolumeClaim", "name": "production"}),
            ("storageClassName", "other"),
        ):
            bad = copy.deepcopy(obj)
            bad["spec"][key] = value
            self.assertFalse(self.admits("homelab-test-news-inputs", bad), key)
        self.assertFalse(self.admits("homelab-test-news-inputs", obj, "UPDATE"))

    def test_new_claims_accept_api_protection_but_reject_other_mutations(self):
        from scripts.test.news import cluster_recovery as module

        claim = module.resources("abcdef123456")[0]
        # StorageObjectInUseProtection adds this before validating admission.
        claim["metadata"]["finalizers"] = ["kubernetes.io/pvc-protection"]
        claim["spec"]["volumeMode"] = "Filesystem"
        self.assertTrue(self.admits("homelab-test-news-inputs", claim))
        self.assertFalse(self.admits("homelab-test-news-inputs", claim, "UPDATE"))
        for finalizers in (
            ["synthetic.example/protection"],
            ["kubernetes.io/pvc-protection", "synthetic.example/protection"],
            ["kubernetes.io/pvc-protection", "kubernetes.io/pvc-protection"],
        ):
            bad = copy.deepcopy(claim)
            bad["metadata"]["finalizers"] = finalizers
            self.assertFalse(self.admits("homelab-test-news-inputs", bad), finalizers)
        for field, value in (
            ("volumeName", "synthetic-existing-volume"),
            ("dataSource", {"kind": "PersistentVolumeClaim", "name": "synthetic-existing"}),
        ):
            bad = copy.deepcopy(claim)
            bad["spec"][field] = value
            self.assertFalse(self.admits("homelab-test-news-inputs", bad), field)
        for other in module.resources("abcdef123456")[-2:]:
            other["metadata"]["finalizers"] = ["kubernetes.io/pvc-protection"]
            self.assertFalse(self.admits("homelab-test-news-inputs", other), other["kind"])
        other = module.pod("abcdef123456", "source")
        other["metadata"]["finalizers"] = ["kubernetes.io/pvc-protection"]
        self.assertFalse(self.admits("homelab-test-news-pods", other))

    def test_server_defaulted_pod_and_bound_claim_allow_owned_deletion(self):
        from scripts.test.news import cluster_recovery as module

        obj = module.pod("abcdef123456", "source")
        obj["spec"].update(
            dnsPolicy="ClusterFirst",
            schedulerName="default-scheduler",
            serviceAccountName="default",
            serviceAccount="default",
            priority=0,
            preemptionPolicy="PreemptLowerPriority",
        )
        obj["spec"]["containers"][0]["readinessProbe"].update(timeoutSeconds=1, successThreshold=1)
        for container in obj["spec"]["containers"]:
            container.update(
                terminationMessagePath="/dev/termination-log", terminationMessagePolicy="File"
            )
        obj["spec"]["tolerations"] = [
            {"key": key, "operator": "Exists", "effect": "NoExecute", "tolerationSeconds": 300}
            for key in ("node.kubernetes.io/not-ready", "node.kubernetes.io/unreachable")
        ]
        self.assertTrue(self.admits("homelab-test-news-pods", obj))
        obj["metadata"]["uid"] = "synthetic-uid"
        obj["spec"]["nodeName"] = "synthetic-node"
        self.assertTrue(self.admits("homelab-test-news-pods", obj, "DELETE"))
        claim = module.resources("abcdef123456")[0]
        claim["metadata"].update(
            uid="synthetic-claim-uid", finalizers=["kubernetes.io/pvc-protection"]
        )
        claim["spec"].update(volumeName="synthetic-bound-volume", volumeMode="Filesystem")
        self.assertTrue(self.admits("homelab-test-news-inputs", claim, "DELETE"))

    def test_immutable_inputs_are_bounded_and_deletable(self):
        import base64

        from scripts.test.news import cluster_recovery as module

        for obj in module.resources("abcdef123456")[-2:]:
            self.assertTrue(self.admits("homelab-test-news-inputs", obj))
            obj["metadata"]["uid"] = "synthetic-uid"
            if obj["kind"] == "Secret":
                obj["data"] = {
                    k: base64.b64encode(v.encode()).decode()
                    for k, v in obj.pop("stringData").items()
                }
            self.assertTrue(self.admits("homelab-test-news-inputs", obj, "DELETE"))
            for change in ("mutable", "extra-key", "oversized", "foreign-name"):
                bad = copy.deepcopy(obj)
                if change == "mutable":
                    bad["immutable"] = False
                elif change == "extra-key":
                    bad["data"]["unexpected"] = "x"
                elif change == "oversized":
                    bad["data"][next(iter(bad["data"]))] = "x" * 65537
                else:
                    bad["metadata"]["name"] = "production"
                self.assertFalse(self.admits("homelab-test-news-inputs", bad), change)

    def test_exec_restricts_container_command_and_streams(self):
        from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests

        request = {
            "operation": "CONNECT",
            "namespace": "news-recovery-test",
            "name": "news-drill-abcdef123456-source",
            "subResource": "exec",
            "resource": {"group": "", "version": "v1", "resource": "pods"},
            "userInfo": {"username": "system:serviceaccount:kube-system:homelab-test-runner"},
        }
        obj = {
            "container": "app",
            "command": ["php", "/opt/news/drill.php", "source"],
            "stdout": True,
            "stderr": True,
            "stdin": False,
            "tty": False,
        }

        def admits(o):
            return TestAccessPolicyTests.admits(self, "homelab-test-news-exec", request, o, None)

        self.assertTrue(admits(obj))
        for field, value in (
            ("container", "database"),
            ("command", ["sh"]),
            ("stdin", True),
            ("tty", True),
        ):
            self.assertFalse(admits(dict(obj, **{field: value})))
        request["name"] = "news-drill-abcdef123456-restored"
        obj.update(command=["php", "/opt/news/drill.php", "restored"], stdin=True)
        self.assertTrue(admits(obj))


class ControllerTests(unittest.TestCase):
    def test_preflight_checks_the_campaign_or_standalone_lease_holder(self):
        import datetime
        import os
        import sys
        import tempfile
        from pathlib import Path
        from unittest.mock import patch

        import yaml

        from scripts.test.news import cluster_recovery as module

        baseline = list(
            yaml.safe_load_all(
                (module.ROOT / "kubernetes/apps/news/recovery/app/namespace.yaml").read_text()
            )
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child = root / "synthetic-child"
            child.mkdir()
            fixture = root / "objects.json"
            calls = root / "calls.jsonl"
            executable = root / "kubectl"
            executable.write_text(
                f"#!{sys.executable}\n"
                "import json, pathlib, sys\n"
                f"root = pathlib.Path({str(root)!r})\n"
                "args = sys.argv[1:]\n"
                "with (root / 'calls.jsonl').open('a') as stream:\n"
                "    stream.write(json.dumps(args) + '\\n')\n"
                "if 'get' not in args: sys.exit(9)\n"
                "kind = args[args.index('get') + 1]\n"
                "print(json.dumps(json.loads((root / 'objects.json').read_text())[kind]))\n"
            )
            executable.chmod(0o700)
            now = datetime.datetime.now(datetime.UTC)
            for campaign, actual, age, admitted in (
                ("campaign:synthetic-parent", "campaign:synthetic-parent", 0, True),
                ("", "synthetic-child", 0, True),
                ("campaign:synthetic-parent", "synthetic-child", 0, False),
                ("campaign:synthetic-parent", "campaign:synthetic-parent", 120, False),
            ):
                with self.subTest(campaign=campaign, actual=actual, age=age):
                    objects = {
                        "lease": {
                            "spec": {
                                "holderIdentity": actual,
                                "renewTime": (now - datetime.timedelta(seconds=age)).strftime(
                                    "%Y-%m-%dT%H:%M:%S.000000Z"
                                ),
                                "leaseDurationSeconds": 90,
                            }
                        },
                        "namespace": {
                            "metadata": {
                                "labels": {"pod-security.kubernetes.io/enforce": "restricted"}
                            }
                        },
                        "ciliumnetworkpolicy": next(
                            o for o in baseline if o["kind"] == "CiliumNetworkPolicy"
                        ),
                        "resourcequota": next(o for o in baseline if o["kind"] == "ResourceQuota"),
                    }
                    fixture.write_text(json.dumps(objects))
                    calls.unlink(missing_ok=True)
                    with patch.dict(
                        os.environ,
                        {
                            "PATH": str(root) + os.pathsep + os.environ["PATH"],
                            "TEST_LEASE_KUBECTL": str(executable),
                            "TEST_CAMPAIGN_LEASE_HOLDER": campaign,
                        },
                    ):
                        client = module.Cluster(Path("synthetic-kubeconfig"), child)
                        if admitted:
                            client.preflight()
                        else:
                            with self.assertRaises(RuntimeError):
                                client.preflight()
                    requests = [json.loads(line) for line in calls.read_text().splitlines()]
                    self.assertEqual(len(requests), 4 if admitted else 1)
                    self.assertTrue(all("get" in request for request in requests))

    def test_failed_source_deletion_prevents_recovery_and_still_cleans_up(self):
        import tempfile
        from pathlib import Path
        from unittest.mock import Mock

        from scripts.test.news import cluster_recovery as module

        with tempfile.TemporaryDirectory() as directory:
            client = Mock(directory=Path(directory))
            client.execute.return_value = json.dumps(
                {
                    "set": "set-1234567890-ABC123",
                    "items_sha256": "a" * 64,
                    "subscriptions_sha256": "b" * 64,
                    "articles": 3,
                    "subscriptions": 2,
                }
            )
            client.delete_source.side_effect = RuntimeError("deletion failed")
            with self.assertRaises(RuntimeError):
                module.run_drill(client)
            client.create_pod.assert_called_once_with("source")
            client.cleanup.assert_called_once()
            report = json.loads((client.directory / "diagnostics/news-recovery.json").read_text())
            self.assertEqual(report["assertions"], "failed")
            self.assertEqual(report["cleanup"], "passed")

    def test_missing_confirmation_refuses_before_credential_lookup(self):
        from unittest.mock import patch

        from scripts.test.news import cluster_recovery as module

        with (
            patch.dict("os.environ", {}, clear=True),
            patch("scripts.test.access.suite_inputs") as lookup,
        ):
            with self.assertRaises(ValueError):
                module.main()
            lookup.assert_not_called()

    def test_generated_admission_matches_current_templates(self):
        import yaml

        from scripts.test.news import generate_admission as generator

        self.assertEqual(
            list(yaml.safe_load_all(generator.TARGET.read_text())), generator.documents()
        )

    def test_cleanup_attempts_all_recorded_resources_and_reports_failure(self):
        import tempfile
        from pathlib import Path
        from unittest.mock import Mock

        from scripts.test.news import cluster_recovery as module

        with tempfile.TemporaryDirectory() as directory:
            client = module.Cluster(Path("synthetic-kubeconfig"), Path(directory))
            client.ledger.write_text(
                "\n".join(
                    json.dumps(
                        {
                            "kind": "PersistentVolumeClaim",
                            "metadata": {"name": "synthetic-" + str(i)},
                        }
                    )
                    for i in range(3)
                )
            )
            client.owned = Mock(side_effect=[RuntimeError("changed ownership"), "", ""])
            with self.assertRaises(RuntimeError):
                client.cleanup()
            self.assertEqual(client.owned.call_count, 3)

    def test_preflight_refuses_changed_network_baseline(self):
        import tempfile
        from pathlib import Path
        from unittest.mock import Mock

        from scripts.test.news import cluster_recovery as module

        with tempfile.TemporaryDirectory() as directory:
            client = module.Cluster(Path("synthetic-kubeconfig"), Path(directory))
            client.call = Mock(
                side_effect=[
                    "",
                    json.dumps(
                        {
                            "metadata": {
                                "labels": {"pod-security.kubernetes.io/enforce": "restricted"}
                            }
                        }
                    ),
                    json.dumps({"spec": {"endpointSelector": {}, "egress": []}}),
                ]
            )
            with self.assertRaises(ValueError):
                client.preflight()
            self.assertEqual(client.call.call_count, 3)

    def test_recovery_namespace_has_no_external_network_or_production_activation(self):
        import yaml

        from scripts.test.news import cluster_recovery as module

        objects = list(
            yaml.safe_load_all(
                (module.ROOT / "kubernetes/apps/news/recovery/app/namespace.yaml").read_text()
            )
        )
        policy = next(o for o in objects if o["kind"] == "CiliumNetworkPolicy")
        self.assertEqual(policy["metadata"]["namespace"], module.NAMESPACE)
        self.assertEqual(
            policy["spec"],
            {
                "endpointSelector": {},
                "ingressDeny": [{"fromEntities": ["all"]}],
                "egressDeny": [{"toEntities": ["all"]}],
            },
        )
        root = yaml.safe_load((module.ROOT / "kubernetes/apps/kustomization.yaml").read_text())
        self.assertIn("./news/recovery/ks.yaml", root["resources"])
        self.assertNotIn("./news", root["resources"])
        role_objects = list(
            yaml.safe_load_all(
                (
                    module.ROOT
                    / "kubernetes/apps/kube-system/agent-access/app/news-recovery-rbac.yaml"
                ).read_text()
            )
        )
        self.assertTrue(all(o["metadata"]["namespace"] == module.NAMESPACE for o in role_objects))
        role = next(o for o in role_objects if o["kind"] == "Role")
        self.assertTrue(
            all(
                not (set(r["verbs"]) & {"patch", "update", "list", "watch"}) for r in role["rules"]
            )
        )
