import copy
import os
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from scripts.openbao import restart
from scripts.openbao.configuration import SafeError


class StagedRestartTest(unittest.TestCase):
    def setUp(self):
        self.target = {"source_revision": "a" * 40, "pvc_uids": {"data": "retained"},
                       "pod_uids": {f"openbao-{i}": f"old-{i}" for i in range(3)}}
        self.state = {"leader": "openbao-1", "pods": {
            n: {"uid": uid} for n, uid in self.target["pod_uids"].items()}}
        self.client = Mock()
        self.inputs = dict(client=self.client, token="synthetic", kubeconfig=Path("/synthetic"), journal=[])
        self.replaced = []
        for name, kwargs in (
            ("scripts.openbao.restart.require_staged", {}),
            ("scripts.openbao.guards.freeze_target", {"side_effect": lambda *_: copy.deepcopy(self.target)}),
            ("scripts.openbao.apply.verify_configuration", {}),
            ("scripts.openbao.apply.require_audit", {}),
            ("scripts.openbao.guards.assert_mutation_allowed", {}),
            ("scripts.openbao.maintenance.healthy", {"return_value": True}),
            ("scripts.test.scenarios.openbao_ha.LiveCluster.check", {}),
            ("scripts.test.scenarios.openbao_ha.LiveCluster.snapshot", {"side_effect": lambda: copy.deepcopy(self.state)}),
        ):
            p = patch(name, **kwargs)
            p.start()
            self.addCleanup(p.stop)

    def replace(self, uid, role, kube, bao, clock):
        name = next(n for n, p in self.state["pods"].items() if p["uid"] == uid)
        self.replaced.append((name, role))
        kube.check()
        self.state["pods"][name]["uid"] += "-new"
        self.target["pod_uids"][name] += "-new"
        return {"member": name, "role": role, "recovery_seconds": 1}

    def test_read_only_plan_then_standbys_and_leader_restart_without_storage_change(self):
        with patch("scripts.openbao.maintenance.replace_member", side_effect=self.replace) as replace:
            plan = restart.run(**self.inputs)
            replace.assert_not_called()
            self.assertEqual([a["pod"] for a in plan["actions"]], ["openbao-0", "openbao-2", "openbao-1"])
            result = restart.run(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(self.replaced, [("openbao-0", "standby"), ("openbao-2", "standby"), ("openbao-1", "leader")])
        self.assertEqual(self.target["pvc_uids"], {"data": "retained"})
        self.client.post.assert_not_called()

    def test_storage_identity_change_stops_after_first_replacement(self):
        plan = restart.run(**self.inputs)
        def replace(*args):
            result = self.replace(*args)
            self.target["pvc_uids"]["data"] = "unexpected"
            return result
        with patch("scripts.openbao.maintenance.replace_member", side_effect=replace), self.assertRaises(SafeError):
            restart.run(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(len(self.replaced), 1)

    def test_failed_recovery_never_replaces_a_second_member(self):
        plan = restart.run(**self.inputs)
        with patch("scripts.openbao.maintenance.replace_member", side_effect=SafeError("timeout")) as replace:
            with self.assertRaises(SafeError):
                restart.run(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(replace.call_count, 1)

    def test_eviction_scope_uses_operator_lease_without_test_harness_environment(self):
        plan = restart.run(**self.inputs)
        def replace(uid, role, kube, bao, clock):
            kube.scope.check()
            return self.replace(uid, role, kube, bao, clock)
        with (patch.dict(os.environ, {"OPENBAO_LEASE_HOLDER": "synthetic-holder"}, clear=True),
              patch("scripts.openbao.guards.assert_mutation_allowed") as check,
              patch("scripts.openbao.maintenance.replace_member", side_effect=replace)):
            self.assertEqual(restart.run(confirm=plan["confirmation"], **self.inputs)["status"], "pass")
        self.assertEqual(check.call_count, 3)

    def test_failed_audit_readback_cannot_report_success(self):
        plan = restart.run(**self.inputs)
        with (patch("scripts.openbao.maintenance.replace_member", side_effect=self.replace),
              patch("scripts.openbao.apply.require_audit", side_effect=SafeError("audit-unavailable")),
              self.assertRaises(SafeError)):
            restart.run(confirm=plan["confirmation"], **self.inputs)

    def test_changed_target_requires_new_confirmation_without_eviction(self):
        plan = restart.run(**self.inputs)
        self.target["pvc_uids"]["data"] = "changed"
        with patch("scripts.openbao.maintenance.replace_member") as replace:
            result = restart.run(confirm=plan["confirmation"], **self.inputs)
            self.assertEqual(result["status"], "confirmation-required")
            replace.assert_not_called()

    def test_configuration_or_quorum_failure_prevents_restart(self):
        for target in ("scripts.openbao.apply.verify_configuration", "scripts.openbao.maintenance.healthy"):
            with (self.subTest(target=target),
                  patch(target, side_effect=SafeError("source-mismatch")),
                  patch("scripts.openbao.maintenance.replace_member") as replace,
                  self.assertRaises(SafeError)):
                restart.run(**self.inputs)
            replace.assert_not_called()


class StagingBoundaryTest(unittest.TestCase):
    def test_live_activation_of_any_integration_refuses_restart(self):
        import yaml
        source = list(yaml.safe_load_all((restart.guards.PACKAGE / "ks.yaml").read_text()))
        with patch("scripts.openbao.guards.kube", return_value={"items": source}):
            restart.require_staged(Path("/synthetic"))
        for name in ("openbao-access", "openbao-acceptance", "openbao-backup", "openbao-monitoring"):
            changed = copy.deepcopy(source)
            next(u for u in changed if u["metadata"]["name"] == name)["spec"]["suspend"] = False
            with (self.subTest(name=name),
                  patch("scripts.openbao.guards.kube", return_value={"items": changed}),
                  self.assertRaises(SafeError)):
                restart.require_staged(Path("/synthetic"))


if __name__ == "__main__":
    unittest.main()
