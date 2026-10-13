"""Scoped controller, network and RWX acceptance using only synthetic claims."""

import copy
import json
import math
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.openbao.guards import _controlled_body

PLATFORM = ROOT / "kubernetes/apps/applications/career-ops/platform"
PREFIX = "career-ops-boundary-"
TARGETS = ["api", "database", "dns-tcp", "dns-udp"]
NETWORK_MODES = [
    "network-" + stage + "-" + target for stage in ["write", "read"] for target in TARGETS
]
MODES = ["seed", "write", "read", "cleanup", *NETWORK_MODES]
IMAGE = (
    "python:3.13.14-slim@sha256:9662417aace5ae7b8e2609cce472b72a8958e134ba372808abe9cc1a0c0125e6"
)
TEST_RUNNER = "system:serviceaccount:kube-system:homelab-test-runner"


def job(mode, run, addresses, hostname=None):
    obj = yaml.safe_load((ROOT / "tests/fixtures/application-boundary/job.yaml").read_text())
    obj["metadata"]["name"] = PREFIX + mode
    account = PREFIX + ("coordinator" if mode in {"seed", "cleanup"} else "renderer")
    labels = {
        "app.kubernetes.io/name": account,
        "homelab.supermorphic.com/test-run": run,
        "homelab.supermorphic.com/test-phase": mode,
    }
    obj["metadata"]["labels"] = labels.copy()
    obj["spec"]["template"]["metadata"]["labels"] = labels.copy()
    obj["spec"]["activeDeadlineSeconds"] = 300
    pod = obj["spec"]["template"]["spec"]
    pod["serviceAccountName"] = account
    pod["securityContext"]["fsGroup"] = 1000
    if hostname:
        pod["nodeSelector"] = {"kubernetes.io/hostname": hostname}
    container = pod["containers"][0]
    container.update(
        image=IMAGE,
        command=["python", "-I", "-B", "/fixture/probe.py"],
        args=[mode, run, *addresses],
    )
    pod["volumes"] = [
        {"name": "program", "configMap": {"name": PREFIX + "program", "defaultMode": 292}}
    ]
    container["volumeMounts"] = [{"name": "program", "mountPath": "/fixture", "readOnly": True}]

    def mount(name, claim, path, sub=None, read_only=False):
        pod["volumes"].append(
            {
                "name": name,
                "persistentVolumeClaim": {"claimName": PREFIX + claim, "readOnly": read_only},
            }
        )
        entry = {"name": name, "mountPath": path, "readOnly": read_only}
        if sub:
            entry["subPath"] = sub
        container["volumeMounts"].append(entry)

    if mode in {"seed", "cleanup"}:
        for name in ["releases", "requests", "artifacts"]:
            mount(name, name, "/" + name)
    elif mode in {"write", "read"}:
        release = "candidates" if mode == "write" else "published"
        mount("releases", "releases", "/releases", f"{release}/{run}", True)
        request = f"requests/{run}"
        source = (
            f"{request}/input"
            if mode == "write"
            else f"{request}/attempts/attempt/pods/write/input"
        )
        mount("input", "requests", "/input", source, True)
        mount("staging", "requests", "/staging", f"{request}/attempts/attempt/pods/{mode}")
    return obj


def controlled(item):
    item = copy.deepcopy(item)
    if item["kind"] == "PersistentVolumeClaim":
        item["spec"].pop("volumeName", None)  # Assigned by the binder; checked separately.
    if item["kind"] == "LimitRange":
        for limit in item["spec"]["limits"]:
            if limit["type"] == "Container":
                for key in ["default", "defaultRequest"]:
                    limit.setdefault(key, copy.deepcopy(limit["max"]))
    return _controlled_body(item)


def denial_metrics(response, run, phase):
    if (
        response.get("status") != "success"
        or response.get("data", {}).get("resultType") != "vector"
    ):
        return False
    identity = {
        "k8s:homelab.supermorphic.com/test-run=" + run,
        "k8s:homelab.supermorphic.com/test-phase=" + phase,
        "k8s:io.cilium.k8s.policy.serviceaccount=career-ops-boundary-renderer",
        "k8s:io.kubernetes.pod.namespace=career-ops",
    }
    if phase not in NETWORK_MODES:
        return False
    protocol = "UDP" if phase.endswith("dns-udp") else "TCP"
    for series in response["data"].get("result", []):
        metric = series.get("metric", {})
        if metric.get("reason") != "POLICY_DENIED" or not identity.issubset(
            set(metric.get("source", "").split(","))
        ):
            continue
        try:
            value = float(series["value"][1])
        except (KeyError, IndexError, TypeError, ValueError):
            continue
        if math.isfinite(value) and value > 0 and metric.get("protocol") == protocol:
            return True
    return False


class NativeRunner:
    def __init__(self, config):
        self.kc = ["kubectl", "--kubeconfig", str(config)]
        self.run = uuid.uuid4().hex
        self.directory = ROOT / ".tmp/issue-593/native" / self.run
        self.directory.mkdir(parents=True, mode=0o700)
        self.ledger = self.directory / "owned.jsonl"
        self.controls = []
        for root in [PLATFORM, PLATFORM.parent / "fixture-storage"]:
            self.controls.extend(
                yaml.safe_load_all(
                    subprocess.check_output(["kustomize", "build", str(root)], text=True)
                )
            )
        self.revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        self.claim_uids = {}

    def read(self, *args, optional=False):
        command = self.kc + ["get", *args, "-o", "json"]
        if optional:
            command.append("--ignore-not-found")
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode:
            raise RuntimeError(
                "Scoped observation failed; no broader credential fallback is permitted"
            )
        return json.loads(result.stdout) if result.stdout.strip() else None

    def precondition(self):
        identity = subprocess.run(
            self.kc + ["auth", "whoami", "-o", "json"], capture_output=True, text=True, check=False
        )
        if (
            identity.returncode
            or json.loads(identity.stdout)["status"]["userInfo"]["username"] != TEST_RUNNER
        ):
            raise RuntimeError("Native fixtures require the selected test-runner identity")
        for expected in self.controls:
            args = [expected["kind"], expected["metadata"]["name"]]
            if namespace := expected["metadata"].get("namespace"):
                args += ["-n", namespace]
            actual = self.read(*args)
            if controlled(expected) != controlled(actual):
                raise RuntimeError("Installed fixture controls differ from reviewed source")
            if expected["kind"] == "CiliumNetworkPolicy" and not any(
                c.get("type") == "Valid" and c.get("status") == "True"
                for c in actual.get("status", {}).get("conditions", [])
            ):
                raise RuntimeError("An installed Cilium policy has not reported valid")
            if expected["kind"] == "Namespace" and any(
                actual["metadata"]["labels"].get(k) != v
                for k, v in expected["metadata"]["labels"].items()
            ):
                raise RuntimeError("Namespace security labels differ from source")
            if expected["kind"] == "ValidatingAdmissionPolicy":
                status = actual.get("status", {})
                if status.get("observedGeneration") != actual["metadata"][
                    "generation"
                ] or status.get("typeChecking", {}).get("expressionWarnings"):
                    raise RuntimeError("Admission type checking is incomplete")
            if expected["kind"] == "PersistentVolumeClaim":
                name = actual["metadata"]["name"]
                if (
                    actual.get("status", {}).get("phase") != "Bound"
                    or actual["metadata"]
                    .get("annotations", {})
                    .get("kustomize.toolkit.fluxcd.io/prune")
                    != "disabled"
                ):
                    raise RuntimeError("Synthetic claims must be Bound and prune protected")
                previous = self.claim_uids.setdefault(name, actual["metadata"]["uid"])
                if previous != actual["metadata"]["uid"]:
                    raise RuntimeError("Synthetic claim identity changed during acceptance")
                pv = self.read("persistentvolume", actual["spec"]["volumeName"])
                if (
                    pv["spec"].get("persistentVolumeReclaimPolicy") != "Retain"
                    or pv["spec"].get("storageClassName") != "career-ops-retain"
                    or pv["spec"].get("claimRef", {}).get("uid") != previous
                    or pv["spec"].get("csi", {}).get("driver") != "driver.longhorn.io"
                ):
                    raise RuntimeError(
                        "Synthetic volumes lack their owned Longhorn Retain binding"
                    )
        for name in ["career-ops-platform", "career-ops-fixture-storage"]:
            unit = self.read("kustomization", name, "-n", "flux-system")
            status = unit.get("status", {})
            if not status.get("lastAppliedRevision", "").endswith(self.revision):
                raise RuntimeError(
                    "Native acceptance requires this exact deployed platform revision"
                )
            generation = unit["metadata"]["generation"]
            if status.get("observedGeneration") != generation or not any(
                c.get("type") == "Ready"
                and c.get("status") == "True"
                and c.get("observedGeneration") == generation
                for c in status.get("conditions", [])
            ):
                raise RuntimeError("Native fixture prerequisites have not reported Ready")
        connection = self.read("kustomization", "career-ops-connection", "-n", "flux-system")
        if connection["spec"].get("suspend") is not True:
            raise RuntimeError(
                "Application enrollment must remain suspended during these bootstrap fixtures"
            )
        for kind, name in [("gitrepository", "career-ops"), ("kustomization", "career-ops-apps")]:
            source = self.read(kind, name, "-n", "career-ops", optional=True)
            if source and source["spec"].get("suspend") is not True:
                raise RuntimeError("Application source consumption is active")

    def mutate_owned(self, operation, mode):
        # Source/authority/claim checks immediately precede every mutation.
        self.precondition()
        if operation == "create":
            path = self.directory / (mode + ".json")
            path.write_text(json.dumps(self.templates[mode]))
            arguments = [str(self.ledger), str(path), *self.kc, "-n", "career-ops"]
        else:
            arguments = [
                str(self.ledger),
                "Job",
                "career-ops",
                PREFIX + mode,
                *self.kc,
                "-n",
                "career-ops",
            ]
        result = subprocess.run(
            [
                "bash",
                "-c",
                "source scripts/test/lib/owned-resources.sh; test_" + operation + '_owned "$@"',
                "owned-fixture",
                *arguments,
            ],
            capture_output=True,
            text=True,
            check=False,
            cwd=ROOT,
        )
        if result.returncode:
            raise RuntimeError(
                "Owned fixture "
                + operation
                + " failed; retained ownership ledger requires scoped follow-up"
            )

    def require_drops(self, mode):
        # The pinned Cilium writer omits CEP policy fields. Its existing Hubble
        # sourceContext=identity drop counters preserve run/phase attribution.
        vip = subprocess.check_output(
            ["bash", "-c", 'source scripts/lib/network.sh; printf %s "$HOMELAB_GATEWAY_VIP"'],
            cwd=ROOT,
            text=True,
        ).strip()
        query = (
            'hubble_drop_total{reason="POLICY_DENIED",source=~".*homelab[.]supermorphic[.]com/test-run='
            + self.run
            + '.*"}'
        )
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            result = subprocess.run(
                [
                    "curl",
                    "--silent",
                    "--show-error",
                    "--fail",
                    "--max-time",
                    "15",
                    "--resolve",
                    "prometheus.lab.supermorphic.com:443:" + vip,
                    "--get",
                    "--data-urlencode",
                    "query=" + query,
                    "https://prometheus.lab.supermorphic.com/api/v1/query",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode:
                raise RuntimeError("Scoped Hubble metric observation failed")
            if denial_metrics(json.loads(result.stdout), self.run, mode):
                return
            time.sleep(2)
        raise RuntimeError(
            "No current-run Hubble POLICY_DENIED evidence for every fixture target/protocol"
        )

    def wait(self, mode):
        deadline = time.monotonic() + 300
        node = None
        while time.monotonic() < deadline:
            current = self.read("job", PREFIX + mode, "-n", "career-ops")
            pods = self.read(
                "pods", "-n", "career-ops", "-l", "batch.kubernetes.io/job-name=" + PREFIX + mode
            )["items"]
            owned = [
                p
                for p in pods
                if any(
                    o.get("uid") == current["metadata"]["uid"]
                    and o.get("kind") == "Job"
                    and o.get("controller") is True
                    for o in p["metadata"].get("ownerReferences", [])
                )
            ]
            if len(owned) > 1:
                raise RuntimeError("Fixture started duplicate Pods")
            if owned:
                pod = owned[0]
                node = pod["spec"].get("nodeName", node)
                terminated = [
                    s.get("state", {}).get("terminated")
                    for s in pod["status"].get("containerStatuses", [])
                ]
                terminated = [t for t in terminated if t]
                if terminated:
                    result = json.loads(terminated[0].get("message", "{}"))
                    if (
                        terminated[0].get("exitCode") != 0
                        or result.get("result") != "passed"
                        or result.get("phase") != mode
                    ):
                        raise RuntimeError(
                            "Fixed synthetic probe failed: "
                            + mode
                            + " ("
                            + str(result.get("error", "missing termination evidence"))
                            + ")"
                        )
                    if node is None or current.get("status", {}).get("succeeded") != 1:
                        time.sleep(1)
                        continue
                    if mode in NETWORK_MODES:
                        self.require_drops(mode)
                    print("Native fixture passed: " + mode, flush=True)
                    return node
            if current.get("status", {}).get("failed", 0):
                raise RuntimeError(
                    "Controller fixture failed; scheduling and image pulls are not policy denials"
                )
            time.sleep(1)
        raise RuntimeError(
            "Controller fixture timed out; no scheduling or image failure counts as acceptance"
        )

    def network_probes(self, stage, node, addresses):
        # A fixed process sends traffic to one target only. Its phase label gives
        # independent drop attribution even when service-IP workload labels are absent.
        for target in TARGETS:
            mode = "network-" + stage + "-" + target
            self.templates[mode] = job(
                mode, self.run, addresses, node["metadata"]["labels"]["kubernetes.io/hostname"]
            )
            self.mutate_owned("create", mode)
        for target in TARGETS:
            mode = "network-" + stage + "-" + target
            actual_node = self.wait(mode)
            if actual_node != node["metadata"]["name"]:
                raise RuntimeError("Single-target probe did not run on its worker node")
            self.mutate_owned("delete", mode)

    def execute(self):
        if subprocess.check_output(["git", "status", "--porcelain"], text=True):
            raise RuntimeError("Native acceptance requires clean reviewed source")
        self.precondition()
        for mode in MODES:
            if self.read("job", PREFIX + mode, "-n", "career-ops", optional=True):
                raise RuntimeError(
                    "A fixture Job already exists; no existing object will be adopted"
                )
        addresses = [
            self.read("service", name, "-n", namespace)["spec"]["clusterIP"]
            for namespace, name in [
                ("default", "kubernetes"),
                ("automation-data", "automation-data-postgresql"),
                ("kube-system", "kube-dns"),
            ]
        ]
        self.templates = {mode: job(mode, self.run, addresses) for mode in MODES}
        seeded = False
        cleanup_done = False
        try:
            self.mutate_owned("create", "seed")
            seeded = True
            first = self.wait("seed")
            self.mutate_owned("delete", "seed")
            nodes = self.read("nodes")["items"]
            usable = [
                n
                for n in nodes
                if not n["spec"].get("unschedulable")
                and not n["spec"].get("taints")
                and any(
                    c["type"] == "Ready" and c["status"] == "True"
                    for c in n["status"]["conditions"]
                )
            ]
            other = next((n for n in usable if n["metadata"]["name"] != first), None)
            initial = next((n for n in usable if n["metadata"]["name"] == first), None)
            if other is None or initial is None:
                raise RuntimeError("Cross-node acceptance requires two Ready schedulable nodes")
            self.templates["write"] = job(
                "write", self.run, addresses, other["metadata"]["labels"]["kubernetes.io/hostname"]
            )
            self.templates["read"] = job(
                "read",
                self.run,
                addresses,
                initial["metadata"]["labels"]["kubernetes.io/hostname"],
            )
            self.mutate_owned("create", "write")
            writer = self.wait("write")
            if writer != other["metadata"]["name"]:
                raise RuntimeError("Writer did not run on the selected other node")
            self.mutate_owned("delete", "write")
            self.network_probes("write", other, addresses)
            self.mutate_owned("create", "read")
            reader = self.wait("read")
            if reader != first or reader == writer:
                raise RuntimeError(
                    "Fresh retained-data reader did not run on the required other node"
                )
            self.mutate_owned("delete", "read")
            self.network_probes("read", initial, addresses)
            self.mutate_owned("create", "cleanup")
            self.wait("cleanup")
            cleanup_done = True
        finally:
            if seeded and not cleanup_done:
                try:
                    if (
                        self.read("job", PREFIX + "cleanup", "-n", "career-ops", optional=True)
                        is None
                    ):
                        self.mutate_owned("create", "cleanup")
                        self.wait("cleanup")
                except (RuntimeError, subprocess.SubprocessError):
                    print(
                        "Synthetic directory cleanup needs scoped follow-up; ownership ledger remains under .tmp/issue-593/native/"
                        + self.run,
                        file=sys.stderr,
                    )
            # No unrecorded objects, claims, volumes or application data are deleted.
            for mode in reversed(MODES):
                self.mutate_owned("delete", mode)
        print(
            "Native controller Pods, paired TCP/DNS controls, two-node RWX, EROFS read-only mounts, exclusive publication and data retention after Job removal passed. Source reconciliation/pruning, grants, ingress, preparation destinations, delivered alerts and backup restore remain separate acceptance."
        )


def main(argv):
    if (
        len(argv) != 1
        or os.environ.get("APPLICATION_BOUNDARY_NATIVE_CONFIRM")
        != "test:application-boundary:storage-network"
    ):
        print(
            "Use the catalog-selected kubeconfig and APPLICATION_BOUNDARY_NATIVE_CONFIRM=test:application-boundary:storage-network",
            file=sys.stderr,
        )
        return 2
    try:
        if not Path(argv[0]).is_file():
            raise RuntimeError("Selected test kubeconfig is unavailable")
        NativeRunner(Path(argv[0])).execute()
    except (RuntimeError, subprocess.SubprocessError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
