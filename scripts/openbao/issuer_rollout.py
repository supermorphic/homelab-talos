"""Attended adoption of a reviewed issuer mount; no Secret reads or config writes."""

import copy
import json
import os
import re
import time
from pathlib import Path

import yaml

from scripts.test.scenarios.openbao_ha import LiveCluster
from scripts.test.scenarios.openbao_issuance import PodAPI, Scope, pod_document
from scripts.test.scenarios.resilience_support import install_interrupt_handlers

from . import apply, guards, issuance, issuer, maintenance
from .configuration import SafeError
from .operator import OperatorClient, lease, operator_password_session, private_prompt


def matches_pod_spec(expected, actual, member=None):
    """Exact reviewed spec, allowing only explicit API/controller defaults."""
    wanted, observed = copy.deepcopy(expected), copy.deepcopy(actual)

    def defaults(value, source, permitted):
        for key, default in permitted.items():
            if key not in source and value.get(key) == default:
                value.pop(key, None)

    try:
        # The API omits an explicit false hostNetwork from the chart.
        wanted.setdefault("hostNetwork", False)
        observed.setdefault("hostNetwork", False)
        defaults(observed, wanted, {
            "dnsPolicy": "ClusterFirst", "restartPolicy": "Always",
            "schedulerName": "default-scheduler", "enableServiceLinks": True,
            "serviceAccount": wanted.get("serviceAccountName"), "priority": 0,
            "preemptionPolicy": "PreemptLowerPriority", "hostPID": False, "hostIPC": False,
            "hostUsers": True, "shareProcessNamespace": False, "setHostnameAsFQDN": False,
            "initContainers": [], "ephemeralContainers": [],
        })
        if member is not None:
            if not observed.pop("nodeName", None):
                return False
            defaults(observed, wanted, {"hostname": member, "subdomain": "openbao-internal"})
            allowed = [{"key": "node.kubernetes.io/" + condition, "operator": "Exists",
                        "effect": "NoExecute", "tolerationSeconds": 300}
                       for condition in ("not-ready", "unreachable")]
            if "tolerations" in observed and "tolerations" not in wanted:
                tolerations = observed.pop("tolerations")
                if len(tolerations) > 2 or any(t not in allowed for t in tolerations):
                    return False
            wanted["volumes"].append({"name": "data", "persistentVolumeClaim": {"claimName": "data-" + member}})
        expected_containers = {c["name"]: c for c in wanted["containers"]}
        for container in observed["containers"]:
            source = expected_containers.get(container["name"], {})
            defaults(container, source, {"terminationMessagePath": "/dev/termination-log",
                "terminationMessagePolicy": "File", "stdin": False, "stdinOnce": False, "tty": False})
            defaults(container.get("securityContext", {}), source.get("securityContext", {}),
                     {"privileged": False, "procMount": "Default"})
            for port in container.get("ports", []):
                defaults(port, {}, {"protocol": "TCP"})
            for env in container.get("env", []):
                defaults(env.get("valueFrom", {}).get("fieldRef", {}), {}, {"apiVersion": "v1"})
            for mount in container.get("volumeMounts", []):
                defaults(mount, {}, {"mountPropagation": "None", "recursiveReadOnly": "Disabled"})
        expected_volumes = {v["name"]: v for v in wanted["volumes"]}
        for volume in observed["volumes"]:
            for kind in ("secret", "configMap", "projected"):
                if kind in volume:
                    defaults(volume[kind], expected_volumes.get(volume["name"], {}).get(kind, {}),
                             {"defaultMode": 420})
        # API/controller ordering is not part of the credential boundary.
        for spec in (wanted, observed):
            for field in ("volumes", "containers"):
                spec[field].sort(key=lambda value: value["name"])
        return observed == wanted
    except (KeyError, TypeError, AttributeError):
        return False


class IssuerCluster(LiveCluster):
    def __init__(self, scope, bao):
        super().__init__(scope, bao, None)
        self.credential_probe = None
        self.approved = None
        self.rendered = list(yaml.safe_load_all(guards.command([
            "helm", "template", "openbao",
            "oci://ghcr.io/openbao/charts/openbao@sha256:98c8fc901e2579ac6da9a805537fcd7a19525ef8e563ae8737dc16fc8f641e3e",
            "--namespace", "openbao", "--values", str(guards.PACKAGE / "app/values.yaml"),
        ])))

    def rollout_target(self):
        super().check()
        sts = self.get("statefulset", "openbao")
        expected = next(d for d in self.rendered if d and d.get("kind") == "StatefulSet")
        config = next(d for d in self.rendered if d and d.get("kind") == "ConfigMap"
                      and d["metadata"]["name"] == "openbao-config")
        expected_template = expected["spec"]["template"]
        actual_template = sts["spec"]["template"]
        account = self.get("serviceaccount", "openbao")
        actual_metadata = copy.deepcopy(actual_template.get("metadata", {}))
        if actual_metadata.get("creationTimestamp") is None:
            actual_metadata.pop("creationTimestamp", None)
        if (not guards.contains_statefulset_source(expected["spec"], sts["spec"])
                or not matches_pod_spec(expected_template["spec"], actual_template["spec"])
                or actual_metadata != expected_template.get("metadata", {})
                or len(sts["spec"].get("volumeClaimTemplates", [])) != len(expected["spec"].get("volumeClaimTemplates", []))
                or sts["status"].get("observedGeneration") != sts["metadata"]["generation"]
                or self.get("configmap", "openbao-config")["data"] != config["data"]
                or account.get("secrets")
                or account.get("automountServiceAccountToken") is not False):
            raise maintenance.MaintenanceError()
        expected_pod = expected["spec"]["template"]["spec"]
        image = next(c["image"] for c in expected_pod["containers"] if c["name"] == "openbao")
        claims = {}
        for name in sorted(maintenance.NAMES):
            pvc = self.get("pvc", "data-" + name)
            if (pvc["status"]["phase"] != "Bound" or pvc["spec"]["storageClassName"] != "longhorn"
                    or pvc["spec"]["accessModes"] != ["ReadWriteOnce"]):
                raise maintenance.MaintenanceError()
            claims[name] = pvc["metadata"]["uid"]
            pod = self.get("pod", name)
            expected_volumes = copy.deepcopy(expected_pod["volumes"])
            current = next(v for v in pod["spec"]["volumes"] if v["name"] == "kubernetes-api-token")
            if pod["metadata"]["labels"].get("controller-revision-hash") != sts["status"]["updateRevision"]:
                # Only the issuer volume may differ from the reviewed template.
                sources = current.get("projected", {}).get("sources", [])
                first = sources[0] if sources else {}
                old_projection = first == {"serviceAccountToken": {"path": "token", "expirationSeconds": 600}}
                old_secret = first.get("secret", {})
                old_stable = (re.fullmatch(r"openbao-issuer-token-v[1-9][0-9]*", old_secret.get("name", ""))
                              and old_secret.get("items") == [{"key": "token", "path": "token"}])
                permitted = issuer.volume()
                if old_projection:
                    permitted["projected"]["defaultMode"] = 420
                    permitted["projected"]["sources"][0] = first
                elif old_stable:
                    permitted["projected"]["sources"][0]["secret"]["name"] = old_secret["name"]
                if not (old_projection or old_stable) or current != permitted:
                    raise maintenance.MaintenanceError()
                expected_volumes = [current if v["name"] == "kubernetes-api-token" else v for v in expected_volumes]
            reviewed_pod = {**expected_pod, "volumes": expected_volumes}
            if not matches_pod_spec(reviewed_pod, pod["spec"], member=name):
                raise maintenance.MaintenanceError()
        return {"source": self.source, "statefulset_uid": sts["metadata"]["uid"],
                "revision": sts["status"]["updateRevision"], "image": image,
                "pvc_uids": claims, "issuer_volume": issuer.volume()}

    def check(self):
        super().check()
        if self.approved is not None and self.rollout_target() != self.approved:
            raise maintenance.MaintenanceError()
        if self.credential_probe is not None:
            issuer.verify_identity(self.credential_probe)

    def probe(self):
        # The old issuer may already be expired. This repair guards quorum;
        # issuance is required after the last pending member is replaced.
        try:
            return maintenance.healthy(self.snapshot())
        except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
            return False


def replace_pending(cluster, approved, initial, clock, progress):
    expected = initial
    results = []
    order = sorted(maintenance.NAMES - {initial["leader"]}) + [initial["leader"]]
    for name in order:
        cluster.check()
        current = cluster.snapshot()
        if (cluster.rollout_target() != approved or not maintenance.healthy(current)
                or maintenance.identities(current) != maintenance.identities(expected)
                or any(p["image"] != approved["image"] for p in current["pods"].values())):
            raise maintenance.MaintenanceError()
        if current["pods"][name]["revision"] == approved["revision"]:
            continue
        progress["stage"] = "member-replacement"
        result = maintenance.replace_member(current["pods"][name]["uid"],
            "leader" if name == current["leader"] else "standby", cluster, cluster, clock, progress=progress)
        current = cluster.snapshot()
        if (not maintenance.healthy(current)
                or current["pods"][name]["revision"] != approved["revision"]
                or (name != initial["leader"] and current["leader"] != initial["leader"])):
            raise maintenance.MaintenanceError()
        expected = current
        results.append({k: result[k] for k in ("member", "role", "recovery_seconds")})
    cluster.check()
    return {"status": "pass", "replacements": results}


def execute(scope, bao, progress):
    progress["stage"] = "source-preflight"
    cluster = IssuerCluster(scope, bao)
    cluster.source = guards.source_revision()
    cluster.check()
    apply.verify_configuration(apply.DESIRED, bao)
    initial = cluster.snapshot()
    if not maintenance.healthy(initial):
        raise maintenance.MaintenanceError()
    approved = cluster.rollout_target()
    required = f"issuer-rollout:openbao:{guards.digest({'plan': approved, 'state': maintenance.identities(initial)})}:{scope.run_id}"
    print(json.dumps({"status": "confirmation-required", "confirmation": required,
                      "actions": ["verify-stable-issuer", "replace-pending-standbys",
                                  "replace-pending-leader", "verify-issuance"]}, sort_keys=True))
    if (os.environ.get("OPENBAO_ISSUER_CONFIRM") or private_prompt("Exact confirmation: ")) != required:
        raise maintenance.MaintenanceError()
    install_interrupt_handlers()
    cluster.approved = approved
    progress["stage"] = "credential-preflight"
    probes = []
    for is_issuer in (True, False):
        pod = scope.create(pod_document(scope.run_id, is_issuer))
        scope.command("-n", pod["metadata"]["namespace"], "wait", "--for=condition=Ready",
                      "pod/" + pod["metadata"]["name"], "--timeout=120s")
        probes.append(PodAPI(scope, pod))
    cluster.credential_probe = probes[0]
    cluster.check()
    result = replace_pending(cluster, approved, initial, time, progress)
    progress["stage"] = "issuance"
    issuer.server_processes(scope)
    issuance.acceptance(probes[1], probes[1], time, wait_expiry=False)
    progress["stage"] = "configuration-verification"
    apply.verify_configuration(apply.DESIRED, bao)
    apply.require_audit(bao)
    return {**result, "stable_issuer": True, "issuance": "passed"}


def main():
    result = {"status": "fail", "stage": "operator-input", "cleanup": "not-required", "recovery": "not-required"}
    bao = None
    try:
        selected = os.environ.get("OPENBAO_OPERATOR_KUBECONFIG", "")
        if not selected or not Path(selected).is_absolute() or not Path(selected).is_file():
            raise maintenance.MaintenanceError()
        result["stage"] = "source-preflight"
        guards.require_deployed_revision(Path(selected), guards.source_revision())
        bao = OperatorClient(Path(selected))
        result["stage"] = "operator-login"
        with operator_password_session(bao, private_prompt("Retained OpenBao operator password: ")) as token:
            bao.set_token(token)
            with lease(Path(selected)):
                class OperatorScope(Scope):
                    def check(self):
                        guards.assert_mutation_allowed(self.kubeconfig)

                scope = OperatorScope(Path(selected), os.environ["OPENBAO_LEASE_HOLDER"])
                try:
                    result.update(execute(scope, bao, result))
                finally:
                    result["cleanup"] = "failed"
                    scope.cleanup()
                    result["cleanup"] = "passed"
    except SafeError as error:
        result.update(status="fail", classification=str(error))
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        result["status"] = "fail"
    finally:
        if bao:
            bao.close()
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
