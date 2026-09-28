"""Guarded recovery of a staged OpenBao initialization with no retained login."""

import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.openbao.client import AmbiguousWrite
from scripts.openbao.configuration import SafeError
from scripts.openbao.guards import PACKAGE


class ResetTest(unittest.TestCase):
    def test_cli_preview_does_not_acquire_mutation_lease(self):
        from scripts.openbao import reset

        with tempfile.TemporaryDirectory() as directory:
            kubeconfig = Path(directory) / "operator-kubeconfig"
            kubeconfig.write_text("synthetic")
            environment = {
                "OPENBAO_OPERATOR_KUBECONFIG": str(kubeconfig),
                "OPENBAO_RECOVERY_DIRECTORY": str(Path(directory) / "recovery"),
                "OPENBAO_RECOVERY_RECIPIENT": "synthetic-recipient",
            }
            with (
                patch.dict(os.environ, environment, clear=True),
                patch(
                    "scripts.openbao.reset.run",
                    return_value={
                        "status": "confirmation-required",
                        "confirmation": "reset-staged:openbao:synthetic",
                    },
                ),
                patch("scripts.openbao.operator.OperatorClient"),
                patch("scripts.openbao.operator.lease") as lease,
                redirect_stdout(io.StringIO()) as output,
            ):
                self.assertEqual(reset.main(["reset-staged"]), 2)
            lease.assert_not_called()
            self.assertEqual(json.loads(output.getvalue())["status"], "confirmation-required")

    def test_wait_for_helm_uninstall_requires_all_server_objects_gone(self):
        from scripts.openbao import reset

        claim_names = {f"data-openbao-{i}" for i in range(3)}
        snapshot = {
            "target": {"pvc_uids": {name: f"synthetic-{name}" for name in claim_names}},
            "pvs": {
                name: {"name": f"synthetic-pv-{name}", "uid": f"synthetic-pv-uid-{name}"}
                for name in claim_names
            },
        }
        waiting = {
            "helmrelease": None,
            "statefulset": object(),
            "pods": {"openbao-0": object()},
            "claims": dict.fromkeys(claim_names),
            "pvs": dict.fromkeys(claim_names),
        }
        complete = {**waiting, "statefulset": None, "pods": {}}
        with (
            patch("scripts.openbao.reset._remaining", side_effect=[waiting, complete]) as observe,
            patch("scripts.openbao.guards.assert_mutation_allowed"),
            patch("scripts.openbao.reset.time.sleep"),
        ):
            reset._wait_helm_absent(Path("/synthetic/operator-kubeconfig"), snapshot)
        self.assertEqual(observe.call_count, 2)

    def test_claim_deletes_start_only_after_helm_workload_is_absent(self):
        from scripts.openbao import reset

        claims = {
            f"data-openbao-{i}": {
                "metadata": {"uid": f"synthetic-pvc-{i}", "resourceVersion": "31"}
            }
            for i in range(3)
        }
        pvs = {name: {"metadata": {"uid": f"synthetic-pv-{name}"}} for name in claims}
        snapshot = {
            "target": {
                "pvc_uids": {name: claim["metadata"]["uid"] for name, claim in claims.items()}
            },
            "pvs": {
                name: {"name": f"synthetic-pv-{i}", "uid": f"synthetic-pv-{name}"}
                for i, name in enumerate(claims)
            },
        }
        state = {
            "helmrelease": object(),
            "statefulset": None,
            "pods": {},
            "claims": claims,
            "pvs": pvs,
        }
        deleted = []

        def delete(_, path, uid, rv):
            deleted.append((path, uid, rv))
            name = path.rsplit("/", 1)[-1]
            claims.pop(name)
            pvs.pop(name)

        with (
            patch("scripts.openbao.reset._remaining", side_effect=lambda *_: state),
            patch("scripts.openbao.reset.delete_exact", side_effect=delete),
            patch("scripts.openbao.guards.assert_mutation_allowed"),
        ):
            with self.assertRaises(SafeError):
                reset._remove_claims(Path("/synthetic/operator-kubeconfig"), snapshot)
            self.assertEqual(deleted, [])
            state["helmrelease"] = None
            reset._remove_claims(Path("/synthetic/operator-kubeconfig"), snapshot)
        self.assertEqual(len(deleted), 3)
        self.assertEqual(
            [path for path, _, _ in deleted],
            [
                f"/api/v1/namespaces/openbao/persistentvolumeclaims/data-openbao-{i}"
                for i in range(3)
            ],
        )
        self.assertEqual(claims, {})
        self.assertEqual(pvs, {})

    def test_post_uninstall_guard_refuses_recreated_server_or_claim(self):
        from scripts.openbao import reset

        names = (
            "openbao",
            "openbao-prerequisites",
            "openbao-acceptance",
            "openbao-access",
            "openbao-backup",
            "openbao-monitoring",
        )
        target = {
            "source_revision": "a" * 40,
            "cluster_uid": "synthetic-cluster",
            "namespace_uid": "synthetic-namespace",
            "statefulset_uid": "synthetic-sts",
            "pod_uids": {f"openbao-{i}": f"synthetic-pod-{i}" for i in range(3)},
            "pvc_uids": {f"data-openbao-{i}": f"synthetic-pvc-{i}" for i in range(3)},
            "flux_unit_uids": {name: f"synthetic-{name}" for name in names},
        }
        snapshot = {
            "target": target,
            "helmrelease_uid": "synthetic-helm",
            "pvs": {
                f"data-openbao-{i}": {"name": f"synthetic-pv-{i}", "uid": f"synthetic-pv-uid-{i}"}
                for i in range(3)
            },
        }
        units = [
            {"metadata": {"name": name, "uid": f"synthetic-{name}"}, "spec": {"suspend": True}}
            for name in names
        ]
        items = [
            {
                "kind": "PersistentVolumeClaim",
                "metadata": {"name": name, "uid": uid, "resourceVersion": "31"},
                "spec": {"volumeName": f"synthetic-pv-{i}"},
            }
            for i, (name, uid) in enumerate(target["pvc_uids"].items())
        ]
        pvs = [
            {
                "metadata": {"name": f"synthetic-pv-{i}", "uid": f"synthetic-pv-uid-{i}"},
                "spec": {
                    "persistentVolumeReclaimPolicy": "Delete",
                    "claimRef": {"uid": f"synthetic-pvc-{i}"},
                },
            }
            for i in range(3)
        ]

        def kube(_, *args):
            if args[:2] == ("get", "namespace"):
                return {
                    "metadata": {
                        "uid": "synthetic-cluster"
                        if args[2] == "kube-system"
                        else "synthetic-namespace"
                    }
                }
            if "kustomizations" in args:
                return {"items": units}
            if "pv" in args and args[0] == "get":
                return {"items": pvs}
            return {"items": items}

        with (
            patch("scripts.openbao.guards.source_revision", return_value="a" * 40),
            patch("scripts.openbao.guards.require_deployed_revision"),
            patch("scripts.openbao.guards.kube", side_effect=kube),
        ):
            self.assertEqual(
                len(reset._remaining(Path("/synthetic/operator-kubeconfig"), snapshot)["claims"]),
                3,
            )
            items.append(
                {"kind": "Pod", "metadata": {"name": "openbao-0", "uid": "replacement-pod"}}
            )
            with self.assertRaises(SafeError):
                reset._remaining(Path("/synthetic/operator-kubeconfig"), snapshot)
            items.pop()
            items[0]["metadata"]["uid"] = "replacement-claim"
            with self.assertRaises(SafeError):
                reset._remaining(Path("/synthetic/operator-kubeconfig"), snapshot)

    def test_snapshot_refuses_a_resumed_flux_unit(self):
        from scripts.openbao import reset

        names = (
            "openbao",
            "openbao-prerequisites",
            "openbao-acceptance",
            "openbao-access",
            "openbao-backup",
            "openbao-monitoring",
        )
        target = {
            "recipient": "synthetic-recipient",
            "flux_unit_uids": {name: f"synthetic-{name}" for name in names},
        }
        units = [
            {"metadata": {"name": name, "uid": f"synthetic-{name}"}, "spec": {"suspend": True}}
            for name in names
        ]
        helm = {"metadata": {"uid": "synthetic-helm", "resourceVersion": "17"}}

        def kube(_, *args):
            if "kustomizations" in args:
                return {"items": units}
            return {"items": []}

        with (
            patch("scripts.openbao.guards.freeze_target", return_value=target),
            patch("scripts.openbao.guards.kube", side_effect=kube),
            patch(
                "scripts.openbao.reset.validate_staged_inventory",
                return_value={"helmrelease": helm, "pvs": {}},
            ),
        ):
            snapshot, observed = reset._snapshot(
                Path("/synthetic/operator-kubeconfig"), "synthetic-recipient"
            )
            self.assertEqual(snapshot["helmrelease_uid"], "synthetic-helm")
            self.assertEqual(observed, helm)
            units[3]["spec"]["suspend"] = False
            with self.assertRaises(SafeError):
                reset._snapshot(Path("/synthetic/operator-kubeconfig"), "synthetic-recipient")

    def test_confirmation_precedes_every_delete_and_initialized_state_is_required(self):
        from scripts.openbao import reset

        target = {"source_revision": "a" * 40, "recipient": "synthetic-recipient"}
        snapshot = {"target": target, "helmrelease_uid": "synthetic-helm", "pvs": {}}
        helm = {"metadata": {"uid": "synthetic-helm", "resourceVersion": "17"}}

        class Client:
            states = [{"initialized": True}] * 3

            def states_now(self):
                return self.states

        client = Client()
        inputs = {
            "kubeconfig": Path("/synthetic/operator-kubeconfig"),
            "client": client,
            "recovery_directory": Path("/synthetic/empty-recovery"),
            "recipient": "synthetic-recipient",
        }
        with (
            patch("scripts.openbao.secrets.preflight_recovery"),
            patch("scripts.openbao.reset._snapshot", return_value=(snapshot, helm)),
            patch("scripts.openbao.reset.delete_exact") as delete,
            patch("scripts.openbao.guards.assert_mutation_allowed"),
            patch("scripts.openbao.reset._wait_helm_absent"),
            patch("scripts.openbao.reset._remove_claims"),
        ):
            preview = reset.run(confirm="", **inputs)
            self.assertEqual(preview["status"], "confirmation-required")
            delete.assert_not_called()
            client.states = [{"initialized": False}] * 3
            with self.assertRaises(SafeError):
                reset.run(confirm=preview["confirmation"], **inputs)
            delete.assert_not_called()
            client.states = [{"initialized": True}] * 3
            result = reset.run(confirm=preview["confirmation"], **inputs)
            self.assertEqual(result, {"status": "pass"})
            delete.assert_called_once_with(
                inputs["kubeconfig"],
                "/apis/helm.toolkit.fluxcd.io/v2/namespaces/openbao/helmreleases/openbao",
                "synthetic-helm",
                "17",
            )

    def test_delete_uses_api_uid_and_resource_version_preconditions(self):
        from scripts.openbao import reset

        calls = []

        def command(argv, *, input_bytes=None, timeout=60):
            calls.append((argv, json.loads(input_bytes), timeout))
            return b"{}"

        with patch("scripts.openbao.guards.command", side_effect=command):
            reset.delete_exact(
                Path("/synthetic/operator-kubeconfig"),
                "/apis/helm.toolkit.fluxcd.io/v2/namespaces/openbao/helmreleases/openbao",
                "synthetic-helm-uid",
                "27",
            )
        self.assertEqual(len(calls), 1)
        argv, body, _ = calls[0]
        self.assertEqual(
            argv[argv.index("--raw") + 1],
            "/apis/helm.toolkit.fluxcd.io/v2/namespaces/openbao/helmreleases/openbao",
        )
        self.assertEqual(
            body["preconditions"], {"uid": "synthetic-helm-uid", "resourceVersion": "27"}
        )
        self.assertEqual(body["propagationPolicy"], "Foreground")
        with (
            patch("scripts.openbao.guards.command") as command,
            self.assertRaises(SafeError),
        ):
            reset.delete_exact(
                Path("/synthetic/operator-kubeconfig"),
                "/apis/helm.toolkit.fluxcd.io/v2/namespaces/openbao/helmreleases/openbao/unexpected",
                "synthetic-helm-uid",
                "27",
            )
        command.assert_not_called()
        with (
            patch("scripts.openbao.guards.command", side_effect=SafeError("timeout")) as command,
            self.assertRaises(AmbiguousWrite),
        ):
            reset.delete_exact(
                Path("/synthetic/operator-kubeconfig"),
                "/api/v1/namespaces/openbao/persistentvolumeclaims/data-openbao-0",
                "synthetic-pvc-uid",
                "31",
            )
        self.assertEqual(command.call_count, 1)

    def test_extra_workload_or_changed_claim_ref_refuses_reset(self):
        from scripts.openbao import reset

        target = {
            "statefulset_uid": "synthetic-sts",
            "pod_uids": {f"openbao-{i}": f"synthetic-pod-{i}" for i in range(3)},
            "pvc_uids": {f"data-openbao-{i}": f"synthetic-pvc-{i}" for i in range(3)},
        }
        reviewed_helm = yaml.safe_load((PACKAGE / "app/helmrelease.yaml").read_text())
        items = [
            {
                "kind": "HelmRelease",
                "metadata": {"name": "openbao", "uid": "synthetic-helm"},
                "spec": reviewed_helm["spec"],
            },
            {"kind": "StatefulSet", "metadata": {"name": "openbao", "uid": "synthetic-sts"}},
        ]
        items += [
            {"kind": "Pod", "metadata": {"name": name, "uid": uid}}
            for name, uid in target["pod_uids"].items()
        ]
        items += [
            {
                "kind": "PersistentVolumeClaim",
                "metadata": {"name": name, "uid": uid},
                "spec": {"volumeName": f"synthetic-pv-{i}"},
            }
            for i, (name, uid) in enumerate(target["pvc_uids"].items())
        ]
        pvs = [
            {
                "metadata": {"name": f"synthetic-pv-{i}", "uid": f"synthetic-pv-uid-{i}"},
                "spec": {
                    "persistentVolumeReclaimPolicy": "Delete",
                    "claimRef": {"uid": f"synthetic-pvc-{i}"},
                },
            }
            for i in range(3)
        ]
        expected = reset.validate_staged_inventory(target, items, pvs)
        self.assertEqual(len(expected["pvs"]), 3)
        with self.assertRaises(SafeError):
            reset.validate_staged_inventory(
                target, items + [{"kind": "Job", "metadata": {"name": "unexpected"}}], pvs
            )
        changed = json.loads(json.dumps(pvs))
        changed[0]["spec"]["claimRef"]["uid"] = "replacement-claim"
        with self.assertRaises(SafeError):
            reset.validate_staged_inventory(target, items, changed)
        changed_items = json.loads(json.dumps(items))
        changed_items[0]["spec"]["releaseName"] = "other-release"
        with self.assertRaises(SafeError):
            reset.validate_staged_inventory(target, changed_items, pvs)


if __name__ == "__main__":
    unittest.main()
