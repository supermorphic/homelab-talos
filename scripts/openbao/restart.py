"""Attended staged-server restart using the existing PDB-bound eviction path."""

import copy
import time

import yaml

from . import apply, guards, maintenance
from .configuration import SafeError


def require_staged(kubeconfig):
    expected = {"openbao-prerequisites": False, "openbao": False,
                "openbao-access": True, "openbao-acceptance": True,
                "openbao-backup": True, "openbao-monitoring": True}
    source = list(yaml.safe_load_all((guards.PACKAGE / "ks.yaml").read_bytes()))
    live = guards.kube(kubeconfig, "-n", "flux-system", "get", "kustomizations", "-o", "json")["items"]
    for units in (source, live):
        selected = [u for u in units if u["metadata"]["name"] in expected]
        if len(selected) != len(expected) or any(
            u["spec"].get("suspend") is not expected[u["metadata"]["name"]]
            for u in selected
        ):
            raise SafeError("source-mismatch")


def run(*, client, token, kubeconfig, journal, confirm=""):
    # Lazy imports avoid the operator CLI / maintenance adapter import cycle.
    from scripts.test.scenarios.openbao_ha import LiveCluster
    from scripts.test.scenarios.openbao_issuance import Scope

    require_staged(kubeconfig)
    target = guards.freeze_target(kubeconfig, "config-apply")
    client.wait_quorum(token)
    apply.verify_configuration(apply.DESIRED, client)

    class StagedScope(Scope):
        def check(self):
            # The operator owns the common disruption lock; no test harness is running.
            guards.assert_mutation_allowed(kubeconfig)

    class StagedCluster(LiveCluster):
        def check(self):
            super().check()
            require_staged(kubeconfig)
            if guards.freeze_target(kubeconfig, "config-apply") != self.approved_target:
                raise SafeError("source-mismatch")

        def probe(self):
            # This is quorum recovery, not an issuance acceptance test.
            try:
                return maintenance.healthy(self.snapshot())
            except Exception:
                return False

    cluster = StagedCluster(StagedScope(kubeconfig, "openbao-staged-restart"), client, None)
    cluster.source = target["source_revision"]
    cluster.approved_target = copy.deepcopy(target)
    initial = cluster.snapshot()
    if not maintenance.healthy(initial):
        raise SafeError("source-mismatch")
    leader = initial["leader"]
    order = sorted(maintenance.NAMES - {leader}) + [leader]
    required = guards.confirmation("restart-staged", target["source_revision"],
                                   guards.digest({"target": target, "leader": leader}))
    if confirm != required:
        return {"status": "confirmation-required", "confirmation": required,
                "actions": [{"action": "restart", "pod": name} for name in order]}

    results = []
    for name in order:
        cluster.check()
        current = cluster.snapshot()
        if current["leader"] != leader:
            raise SafeError("source-mismatch")
        apply.verify_configuration(apply.DESIRED, client)
        journal.append("member-replacement-requested")
        result = maintenance.replace_member(
            initial["pods"][name]["uid"], "leader" if name == leader else "standby",
            cluster, cluster, time,
        )
        after = guards.freeze_target(kubeconfig, "config-apply")
        approved = copy.deepcopy(cluster.approved_target)
        approved["pod_uids"][name] = after["pod_uids"][name]
        if after != approved or after["pod_uids"][name] == target["pod_uids"][name]:
            raise SafeError("source-mismatch")
        cluster.approved_target = after
        results.append({k: result[k] for k in ("member", "role", "recovery_seconds")})
    cluster.check()
    client.wait_quorum(token)
    apply.verify_configuration(apply.DESIRED, client)
    apply.require_audit(client)
    return {"status": "pass", "replacements": results}
