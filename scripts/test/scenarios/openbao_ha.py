"""Operator-owned HA/upgrade adapters. All replacements use policy/v1 Eviction."""

import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import yaml

from scripts.openbao import guards, issuance, maintenance, restore
from scripts.openbao.configuration import strict_json
from scripts.openbao.manifests import validate_documents
from scripts.openbao.operator import OperatorClient, lease, private_prompt
from scripts.test.scenarios.openbao_issuance import PodAPI, Scope, pod_document, run_scope
from scripts.test.scenarios.resilience_support import atomic_write_json, install_interrupt_handlers


def snapshot_evidence(path, now, expected_version):
    path = Path(path)
    metadata = restore.load_metadata(path.parent / "metadata.json", path)
    restore.validate_snapshot(
        path, metadata, {"seal_key_id": "openbao-static-seal-v1", "recovery_generation": "1"}
    )
    created = datetime.fromisoformat(metadata["created_at"]).timestamp()
    if not 0 <= now - created <= 3600 or metadata["openbao_version"] != expected_version:
        raise maintenance.MaintenanceError()
    return metadata["sha256"]


class LiveCluster:
    def __init__(self, scope, bao, workload):
        self.scope, self.bao, self.workload = scope, bao, workload
        self.pod_uids = {}
        self.source = None
        self.old_version = None

    def get(self, kind, name):
        return strict_json(self.scope.command("-n", "openbao", "get", kind, name, "-o", "json"))

    def check(self):
        self.scope.check()
        revision = guards.source_revision()
        if self.source is not None and revision != self.source:
            raise maintenance.MaintenanceError()
        guards.require_deployed_revision(self.scope.kubeconfig, revision)

    def snapshot(self):
        sts = self.get("statefulset", "openbao")
        pdb = self.get("pdb", "openbao")
        if (
            validate_documents([sts, pdb])
            or sts["metadata"].get("annotations", {}).get("meta.helm.sh/release-name") != "openbao"
            or sts["metadata"].get("annotations", {}).get("meta.helm.sh/release-namespace")
            != "openbao"
        ):
            raise maintenance.MaintenanceError()
        pods = strict_json(
            self.scope.command(
                "-n",
                "openbao",
                "get",
                "pods",
                "-l",
                "app.kubernetes.io/name=openbao,component=server",
                "-o",
                "json",
            )
        )["items"]
        if {p["metadata"]["name"] for p in pods} != maintenance.NAMES or len(pods) != 3:
            raise maintenance.MaintenanceError()
        result = {"owner_uid": sts["metadata"]["uid"], "pods": {}, "members": {}}
        clusters, leaders = set(), []
        for pod in pods:
            name, uid = pod["metadata"]["name"], pod["metadata"]["uid"]
            if name in self.pod_uids and self.pod_uids[name] != uid:
                tunnel = self.bao.tunnels.pop(name, None)
                if tunnel:
                    tunnel.close()
                self.bao.clients.pop(name, None)
            self.pod_uids[name] = uid
            owners = [
                o["uid"] for o in pod["metadata"].get("ownerReferences", []) if o.get("controller")
            ]
            if owners != [sts["metadata"]["uid"]] or pod["metadata"].get("deletionTimestamp"):
                raise maintenance.MaintenanceError()
            seal = self.bao.peer(name).read("sys/seal-status")
            leader = self.bao.peer(name).read("sys/leader")
            if seal.get("sealed") is not False or seal.get("initialized") is not True:
                raise maintenance.MaintenanceError()
            clusters.add(seal["cluster_id"])
            if leader.get("is_self") is True:
                leaders.append(name)
            result["pods"][name] = {
                "uid": uid,
                "resource_version": pod["metadata"]["resourceVersion"],
                "owner_uid": owners[0],
                "node": pod["spec"]["nodeName"],
                "ready": any(
                    c["type"] == "Ready" and c["status"] == "True"
                    for c in pod.get("status", {}).get("conditions", [])
                ),
                "image": next(
                    c["image"] for c in pod["spec"]["containers"] if c["name"] == "openbao"
                ),
                "revision": pod["metadata"]["labels"].get("controller-revision-hash"),
            }
        if len(clusters) != 1 or len(leaders) != 1:
            raise maintenance.MaintenanceError()
        self.bao.active = leaders[0]
        result.update(cluster_id=clusters.pop(), leader=leaders[0])
        peers = self.bao.read("sys/storage/raft/configuration", token=self.bao.token)["data"][
            "config"
        ]["servers"]
        state = self.bao.read("sys/storage/raft/autopilot/state", token=self.bao.token)
        state = state.get("data", state)
        if (
            state.get("healthy") is not True
            or state.get("failure_tolerance") != 1
            or set(state["voters"]) != maintenance.NAMES
            or state["leader"] != leaders[0]
            or len(peers) != 3
            or {p["node_id"] for p in peers} != maintenance.NAMES
        ):
            raise maintenance.MaintenanceError()
        for peer in peers:
            name = peer["node_id"]
            observed = state["servers"][name]
            result["members"][name] = {
                "voter": peer["voter"],
                "leader": peer["leader"],
                "healthy": observed["healthy"] is True and observed["node_status"] == "alive",
                "index": observed["last_index"],
            }
        return result

    def probe(self):
        try:
            return (
                issuance.acceptance(self.workload, self.workload, time, wait_expiry=False)[
                    "status"
                ]
                == "pass"
            )
        except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
            return False

    def evict(self, name, uid, resource_version):
        if name not in maintenance.NAMES or not uid or not resource_version:
            raise maintenance.MaintenanceError()
        body = {
            "apiVersion": "policy/v1",
            "kind": "Eviction",
            "metadata": {"name": name, "namespace": "openbao"},
            "deleteOptions": {"preconditions": {"uid": uid, "resourceVersion": resource_version}},
        }
        self.scope.check()
        self.scope.command(
            "create",
            "--raw",
            f"/api/v1/namespaces/openbao/pods/{name}/eviction",
            "-f",
            "-",
            input_bytes=json.dumps(body).encode(),
        )

    def transfer(self, old, allowed):
        self.check()
        fresh = self.snapshot()
        if (
            not maintenance.healthy(fresh)
            or fresh["leader"] != old
            or not allowed <= maintenance.NAMES - {old}
        ):
            raise maintenance.MaintenanceError()
        self.scope.check()
        self.bao.peer(old).post("sys/step-down", {}, token=self.bao.token)

    def upgrade_preconditions(self):
        self.check()
        values = yaml.safe_load((guards.PACKAGE / "app/values.yaml").read_bytes())
        image = values["server"]["image"]
        target = image["registry"] + "/" + image["repository"] + ":" + image["tag"]
        sts = self.get("statefulset", "openbao")
        containers = sts["spec"]["template"]["spec"]["containers"]
        if (
            sts["spec"]["updateStrategy"]["type"] != "OnDelete"
            or next(c["image"] for c in containers if c["name"] == "openbao") != target
            or sts["status"].get("observedGeneration") != sts["metadata"]["generation"]
        ):
            raise maintenance.MaintenanceError()
        checksum = snapshot_evidence(
            os.environ["OPENBAO_UPGRADE_SNAPSHOT"], time.time(), self.old_version
        )
        return {"image": target, "revision": sts["status"]["updateRevision"], "snapshot": checksum}


def execute(scope, mode):
    bao = OperatorClient(scope.kubeconfig)
    try:
        cluster = LiveCluster(scope, bao, None)
        cluster.source = guards.source_revision()
        guards.require_deployed_revision(scope.kubeconfig, cluster.source)
        token = private_prompt("Existing authorized OpenBao token: ")
        if not token:
            raise maintenance.MaintenanceError()
        bao.set_token(token)
        initial = cluster.snapshot()
        if not maintenance.healthy(initial):
            raise maintenance.MaintenanceError()
        old = {maintenance.version(p["image"]) for p in initial["pods"].values()}
        if len(old) != 1:
            raise maintenance.MaintenanceError()
        cluster.old_version = ".".join(map(str, old.pop()))
        target = {"source": cluster.source, "state": maintenance.identities(initial)}
        if mode == "upgrade":
            target["plan"] = cluster.upgrade_preconditions()
        required = f"{mode}:openbao:{guards.digest(target)}:{scope.run_id}"
        supplied = os.environ.get("OPENBAO_MAINTENANCE_CONFIRM") or private_prompt(
            f"Exact confirmation {required}: "
        )
        if supplied != required:
            raise maintenance.MaintenanceError()
        install_interrupt_handlers()
        pod = scope.create(pod_document(scope.run_id, False))
        scope.command(
            "-n",
            "openbao-acceptance",
            "wait",
            "--for=condition=Ready",
            "pod/" + pod["metadata"]["name"],
            "--timeout=120s",
        )
        cluster.workload = PodAPI(scope, pod)
        fresh = cluster.snapshot()
        if maintenance.identities(fresh) != maintenance.identities(initial):
            raise maintenance.MaintenanceError()
        if mode == "upgrade":
            return maintenance.upgrade(cluster, cluster, time)
        standby = min(maintenance.NAMES - {initial["leader"]})
        results = [
            maintenance.replace_member(
                initial["pods"][standby]["uid"], "standby", cluster, cluster, time
            )
        ]
        fresh = cluster.snapshot()
        if fresh["leader"] != initial["leader"]:
            raise maintenance.MaintenanceError()
        results.append(
            maintenance.replace_member(
                initial["pods"][initial["leader"]]["uid"], "leader", cluster, cluster, time
            )
        )
        return {"status": "pass", "replacements": results}
    finally:
        bao.close()


def main(mode="ha"):
    result = {"status": "fail", "cleanup": "not-required", "recovery": "not-required"}
    scope = run_dir = None
    try:
        scope, run_dir = run_scope()
        result.update(execute(scope, mode))
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        result["status"] = "fail"
        result["recovery"] = "failed"
    finally:
        if scope:
            try:
                scope.cleanup()
                result["cleanup"] = "passed"
            except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
                result.update(status="fail", cleanup="failed")
        if run_dir:
            atomic_write_json(run_dir / "diagnostics/openbao-maintenance.json", result)
            for key in ("cleanup", "recovery"):
                atomic_write_json(
                    run_dir / (key + ".json"),
                    {"status": result[key], "reason": "attended member replacement"},
                )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


def upgrade_main():
    """Operational upgrade uses the same disruption Lease without a test coordinator."""
    scope = None
    result = {"status": "fail"}
    try:
        selected = os.environ.get("OPENBAO_OPERATOR_KUBECONFIG", "")
        if not selected or not Path(selected).is_absolute() or not Path(selected).is_file():
            raise maintenance.MaintenanceError()
        with lease(Path(selected)):
            os.environ["HOMELAB_DISRUPTION_LEASE_HOLDER"] = os.environ["OPENBAO_LEASE_HOLDER"]
            scope = Scope(Path(selected), os.environ["OPENBAO_LEASE_HOLDER"])
            try:
                result = execute(scope, "upgrade")
            finally:
                scope.cleanup()
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        result = {"status": "fail", "recovery": "attended-inspection-required"}
    finally:
        os.environ.pop("HOMELAB_DISRUPTION_LEASE_HOLDER", None)
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    if sys.argv[1:] not in ([], ["upgrade"]):
        print(json.dumps({"status": "refused"}))
        raise SystemExit(2)
    raise SystemExit(upgrade_main() if sys.argv[1:] == ["upgrade"] else main())
