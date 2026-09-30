import contextlib
import copy
import io
import unittest
from unittest.mock import Mock, patch

from scripts.openbao import issuer_rollout, maintenance
from scripts.test.scenarios.test_openbao_ha import Clock, Cluster


class RolloutTests(unittest.TestCase):
    def setUp(self):
        self.cluster = Cluster()
        self.clock = Clock()
        self.cluster.target = self.cluster.current["pods"]["openbao-0"]["image"]
        self.plan = {"image": self.cluster.target, "revision": "new", "pvc_uids": ["original"]}
        self.cluster.rollout_target = Mock(side_effect=lambda: copy.deepcopy(self.plan))

    def run_rollout(self):
        return issuer_rollout.replace_pending(self.cluster, copy.deepcopy(self.plan),
                                             self.cluster.snapshot(), self.clock, {})

    def test_expired_old_issuer_does_not_require_ha_test_or_config_write(self):
        result = self.run_rollout()
        self.assertEqual(result["status"], "pass")
        self.assertEqual([e for e in self.cluster.events if isinstance(e, tuple) and e[0] == "eviction"],
                         [("eviction", "openbao-1"), ("eviction", "openbao-2"), ("eviction", "openbao-0")])
        self.assertEqual({p["revision"] for p in self.cluster.current["pods"].values()}, {"new"})

    def test_partial_rollout_skips_member_already_on_reviewed_revision(self):
        self.cluster.current["pods"]["openbao-1"]["revision"] = "new"
        self.run_rollout()
        self.assertNotIn(("eviction", "openbao-1"), self.cluster.events)

    def test_changed_storage_or_source_prevents_any_eviction(self):
        original = copy.deepcopy(self.plan)
        self.plan["pvc_uids"] = ["replacement"]
        with self.assertRaises(maintenance.MaintenanceError):
            issuer_rollout.replace_pending(self.cluster, original, self.cluster.snapshot(), self.clock, {})
        self.assertFalse(any(isinstance(e, tuple) for e in self.cluster.events))

    def test_recovery_failure_stops_before_second_member(self):
        self.cluster.recover = False
        self.cluster.probe = lambda: True
        with self.assertRaises(maintenance.MaintenanceError):
            self.run_rollout()
        self.assertEqual([e for e in self.cluster.events if isinstance(e, tuple)], [("eviction", "openbao-1")])

    def test_changed_leader_or_uid_requires_new_plan(self):
        original = self.cluster.snapshot()
        self.cluster.current["pods"]["openbao-2"]["uid"] = "unexpected"
        with self.assertRaises(maintenance.MaintenanceError):
            issuer_rollout.replace_pending(self.cluster, self.plan, original, self.clock, {})
        self.assertFalse(any(isinstance(e, tuple) for e in self.cluster.events))


class OperatorBoundaryTests(unittest.TestCase):
    def test_confirmation_and_usable_credential_precede_any_eviction(self):
        for confirmation, credential_ok in (("wrong", True), ("exact", False), ("exact", True)):
            with self.subTest(confirmation=confirmation, credential_ok=credential_ok):
                cluster = Mock()
                cluster.snapshot.return_value = Cluster().snapshot()
                cluster.rollout_target.return_value = {"revision": "new"}

                def check(cluster=cluster, credential_ok=credential_ok):
                    if cluster.credential_probe is not None and not credential_ok:
                        raise maintenance.MaintenanceError()

                cluster.credential_probe = None
                cluster.check.side_effect = check
                scope = Mock(run_id="synthetic-run")
                scope.create.side_effect = lambda pod: pod
                progress = {}
                with (
                    patch.object(issuer_rollout, "IssuerCluster", return_value=cluster),
                    patch.object(issuer_rollout.guards, "source_revision", return_value="source"),
                    patch.object(issuer_rollout.guards, "digest", return_value="digest"),
                    patch.object(issuer_rollout.apply, "verify_configuration"),
                    patch.object(issuer_rollout.apply, "require_audit"),
                    patch.object(issuer_rollout.issuer, "server_processes"),
                    patch.object(issuer_rollout.issuance, "acceptance", side_effect=RuntimeError()),
                    patch.object(issuer_rollout, "install_interrupt_handlers"),
                    patch.object(issuer_rollout, "replace_pending", return_value={"status": "pass"}) as replace,
                    patch.dict("os.environ", {"OPENBAO_ISSUER_CONFIRM": confirmation}),
                    patch.object(issuer_rollout, "private_prompt", side_effect=AssertionError()),
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    if confirmation == "exact":
                        issuer_rollout.os.environ["OPENBAO_ISSUER_CONFIRM"] = "issuer-rollout:openbao:digest:synthetic-run"
                    failure = RuntimeError if confirmation == "exact" and credential_ok else maintenance.MaintenanceError
                    with self.assertRaises(failure):
                        issuer_rollout.execute(scope, Mock(), progress)
                    self.assertEqual(replace.call_count, int(confirmation == "exact" and credential_ok))
                    if confirmation == "wrong":
                        scope.create.assert_not_called()
                    if confirmation == "exact" and credential_ok:
                        # A final issuance error cannot become a successful repair.
                        self.assertEqual(progress["stage"], "issuance")

    def test_quorum_probe_does_not_require_a_working_expired_issuer(self):
        cluster = object.__new__(issuer_rollout.IssuerCluster)
        cluster.snapshot = Mock(return_value=Cluster().snapshot())
        cluster.workload = Mock()
        self.assertTrue(cluster.probe())
        cluster.workload.assert_not_called()
        cluster.snapshot.return_value["pods"]["openbao-1"]["ready"] = False
        self.assertFalse(cluster.probe())


class TargetTests(unittest.TestCase):
    def setUp(self):
        self.cluster = object.__new__(issuer_rollout.IssuerCluster)
        self.cluster.source = "synthetic-source"
        self.volume = issuer_rollout.issuer.volume()
        self.expected = {"kind": "StatefulSet", "spec": {"template": {"spec": {
            "serviceAccountName": "openbao",
            "containers": [{"name": "openbao", "image": "official-pinned"}],
            "volumes": [self.volume]}}}}
        self.config = {"kind": "ConfigMap", "metadata": {"name": "openbao-config"},
                       "data": {"config": "reviewed"}}
        self.cluster.rendered = [{"Pulled": "official-chart", "Digest": "synthetic"}, self.expected, self.config]
        self.sts = {**copy.deepcopy(self.expected),
                    "metadata": {"uid": "owner", "generation": 2},
                    "status": {"observedGeneration": 2, "updateRevision": "new"}}
        self.pods = {}
        self.claims = {}
        self.account = {"automountServiceAccountToken": False}
        for name in maintenance.NAMES:
            old_volume = copy.deepcopy(self.volume)
            old_volume["projected"]["defaultMode"] = 420
            old_volume["projected"]["sources"][0] = {
                "serviceAccountToken": {"path": "token", "expirationSeconds": 600}}
            self.pods[name] = {"metadata": {"labels": {"controller-revision-hash": "old"}},
                               "spec": {"serviceAccountName": "openbao", "nodeName": "synthetic-node",
                                        "containers": [{"name": "openbao", "image": "official-pinned"}],
                                        "volumes": [old_volume, {"name": "data", "persistentVolumeClaim": {
                                            "claimName": "data-" + name}}]}}
            self.claims["data-" + name] = {"metadata": {"uid": "pvc-" + name},
                "status": {"phase": "Bound"},
                "spec": {"storageClassName": "longhorn", "accessModes": ["ReadWriteOnce"]}}
        self.cluster.get = lambda kind, name: {
            "statefulset": {"openbao": self.sts}, "configmap": {"openbao-config": self.config},
            "serviceaccount": {"openbao": self.account}, "pvc": self.claims, "pod": self.pods,
        }[kind][name]

    def test_api_defaulted_old_projection_is_the_only_permitted_source_difference(self):
        with patch.object(issuer_rollout.LiveCluster, "check"):
            self.assertEqual(self.cluster.rollout_target()["pvc_uids"],
                             {name: "pvc-" + name for name in maintenance.NAMES})
            self.pods["openbao-1"]["spec"]["containers"][0]["image"] = "different"
            with self.assertRaises(maintenance.MaintenanceError):
                self.cluster.rollout_target()

    def test_adopted_revision_cannot_keep_old_mount(self):
        self.pods["openbao-1"]["metadata"]["labels"]["controller-revision-hash"] = "new"
        with patch.object(issuer_rollout.LiveCluster, "check"), self.assertRaises(maintenance.MaintenanceError):
            self.cluster.rollout_target()

    def test_serviceaccount_automount_or_legacy_token_reference_blocks_rollout(self):
        for account in ({}, {"automountServiceAccountToken": True},
                        {"automountServiceAccountToken": False, "secrets": [{"name": "unexpected"}]}):
            self.account = account
            with self.subTest(account=account), patch.object(issuer_rollout.LiveCluster, "check"), self.assertRaises(maintenance.MaintenanceError):
                self.cluster.rollout_target()

    def test_old_volume_permissions_or_additional_secret_fields_are_refused(self):
        for extra in ({"defaultMode": 511}, {"unexpected": True}):
            with self.subTest(extra=extra):
                self.setUp()
                self.pods["openbao-1"]["spec"]["volumes"][0]["projected"].update(extra)
                with patch.object(issuer_rollout.LiveCluster, "check"), self.assertRaises(maintenance.MaintenanceError):
                    self.cluster.rollout_target()

    def test_api_and_statefulset_defaults_do_not_require_unreviewed_permissions(self):
        spec = self.pods["openbao-1"]["spec"]
        spec.update(dnsPolicy="ClusterFirst", restartPolicy="Always", schedulerName="default-scheduler",
                    enableServiceLinks=True, serviceAccount="openbao", priority=0,
                    preemptionPolicy="PreemptLowerPriority", hostname="openbao-1", subdomain="openbao-internal")
        spec["tolerations"] = [{"key": "node.kubernetes.io/not-ready", "operator": "Exists",
                               "effect": "NoExecute", "tolerationSeconds": 300}]
        spec["containers"][0].update(terminationMessagePath="/dev/termination-log", terminationMessagePolicy="File")
        with patch.object(issuer_rollout.LiveCluster, "check"):
            self.cluster.rollout_target()
            spec["tolerations"][0]["operator"] = "Equal"
            with self.assertRaises(maintenance.MaintenanceError):
                self.cluster.rollout_target()

    def test_nonissuer_source_mount_change_and_unobserved_template_are_refused(self):
        with patch.object(issuer_rollout.LiveCluster, "check"):
            self.sts["status"]["observedGeneration"] = 1
            with self.assertRaises(maintenance.MaintenanceError):
                self.cluster.rollout_target()
            self.sts["status"]["observedGeneration"] = 2
            self.pods["openbao-1"]["spec"]["volumes"][0]["projected"]["sources"][1]["configMap"]["name"] = "other"
            with self.assertRaises(maintenance.MaintenanceError):
                self.cluster.rollout_target()


    def test_extra_template_or_pod_authority_is_refused_before_rollout(self):
        mutations = (
            lambda p: p["containers"].append({"name": "sidecar", "image": "unexpected"}),
            lambda p: p["volumes"].append({"name": "unexpected", "secret": {"secretName": "other"}}),
            lambda p: p["containers"][0].update(volumeMounts=[{"name": "kubernetes-api-token", "mountPath": "/extra"}]),
            lambda p: p["containers"][0].update(envFrom=[{"secretRef": {"name": "other"}}]),
            lambda p: p["containers"][0].update(securityContext={"privileged": True}),
            lambda p: p.update(initContainers=[{"name": "injected", "image": "unexpected"}]),
        )
        for template in (True, False):
            for mutation in mutations:
                with self.subTest(template=template, mutation=mutation):
                    self.setUp()
                    mutation(self.sts["spec"]["template"]["spec"] if template else self.pods["openbao-1"]["spec"])
                    with patch.object(issuer_rollout.LiveCluster, "check"), self.assertRaises(maintenance.MaintenanceError):
                        self.cluster.rollout_target()


if __name__ == "__main__":
    unittest.main()
