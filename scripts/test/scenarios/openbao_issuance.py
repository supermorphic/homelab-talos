"""Attended issuance acceptance with bounded Pods and exact owned-resource cleanup."""

import copy
import hashlib
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.openbao import guards, issuance
from scripts.openbao.configuration import strict_json
from scripts.openbao.operator import private_prompt
from scripts.test.scenarios.resilience_support import atomic_write_json, install_interrupt_handlers

OWNER = "homelab.supermorphic.com/test-run"
IMAGE = (
    "python:3.13.14-slim@sha256:9662417aace5ae7b8e2609cce472b72a8958e134ba372808abe9cc1a0c0125e6"
)
BRIDGE = """
import http.client, json, socket, ssl, sys
from pathlib import Path
try:
    args = json.load(sys.stdin)
    bao = args['target'] == 'bao'
    hostname = 'openbao.lab.supermorphic.com' if bao else 'kubernetes.default.svc'
    context = ssl.create_default_context() if bao else ssl.create_default_context(cafile='/identity/ca.crt')
    connection = http.client.HTTPSConnection(hostname, 8200 if bao else 443, context=context, timeout=15)
    if bao:
        connection._create_connection = lambda address, timeout, source_address: socket.create_connection(('openbao.openbao.svc', 8200), timeout=timeout)
    headers = {'Content-Type': 'application/json'}
    token = args.get('token')
    if not bao and token is None:
        token = Path('/identity/token').read_text().strip()
    if token:
        headers['X-Vault-Token' if bao else 'Authorization'] = token if bao else 'Bearer ' + token
    headers.update(args.get('headers') or {})
    payload = args.get('payload')
    if args.get('login'):
        payload['jwt'] = Path('/identity/token').read_text().strip()
    connection.request(args['method'], args['path'], json.dumps(payload) if payload is not None else None, headers)
    response = connection.getresponse()
    data = response.read(1048577)
    if len(data) > 1048576:
        raise ValueError()
    body = json.loads(data) if data and 200 <= response.status < 300 else {}
    print(json.dumps({'status': response.status, 'body': body}))
    connection.close()
except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
    sys.exit(1)
"""


def pod_document(run_id, issuer):
    suffix = hashlib.sha256(run_id.encode()).hexdigest()[:16]
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": "openbao-issuer-" + suffix if issuer else "openbao-acceptance-" + suffix,
            "namespace": "openbao" if issuer else issuance.NAMESPACE,
            "annotations": {OWNER: run_id},
            "labels": {"app.kubernetes.io/name": "openbao-acceptance"},
        },
        "spec": {
            "restartPolicy": "Never",
            "activeDeadlineSeconds": 1800,
            "automountServiceAccountToken": False,
            "enableServiceLinks": False,
            "serviceAccountName": "openbao" if issuer else "openbao-acceptance",
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": 65532,
                "seccompProfile": {"type": "RuntimeDefault"},
            },
            "containers": [
                {
                    "name": "probe",
                    "image": IMAGE,
                    "command": ["python", "-c", "import time; time.sleep(1800)"],
                    "resources": {
                        "requests": {"cpu": "10m", "memory": "32Mi"},
                        "limits": {"cpu": "200m", "memory": "128Mi"},
                    },
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                        "readOnlyRootFilesystem": True,
                        "capabilities": {"drop": ["ALL"]},
                    },
                    "volumeMounts": [
                        {"name": "identity", "mountPath": "/identity", "readOnly": True}
                    ],
                }
            ],
            "volumes": [
                {
                    "name": "identity",
                    "projected": {
                        "sources": [
                            {
                                "serviceAccountToken": {
                                    "path": "token",
                                    "expirationSeconds": 600,
                                    "audience": issuance.AUDIENCE
                                    if issuer
                                    else "openbao-kubernetes-broker",
                                }
                            },
                            {
                                "configMap": {
                                    "name": "kube-root-ca.crt",
                                    "items": [{"key": "ca.crt", "path": "ca.crt"}],
                                }
                            },
                        ]
                    },
                }
            ],
        },
    }


def safe_probe_spec(expected, actual):
    """Require the exact probe boundary after removing known Kubernetes defaults.

    Subset matching is unsafe for credential-bearing Pods: extra containers,
    projections, mounts, environment, or security fields must fail closed.
    """
    try:
        observed = copy.deepcopy(actual)

        def defaults(value, permitted):
            for field, default in permitted.items():
                if field in value and value[field] == default:
                    del value[field]

        defaults(
            observed,
            {
                "dnsPolicy": "ClusterFirst",
                "schedulerName": "default-scheduler",
                "terminationGracePeriodSeconds": 30,
                "priority": 0,
                "preemptionPolicy": "PreemptLowerPriority",
                "serviceAccount": expected["serviceAccountName"],
                "hostNetwork": False,
                "hostPID": False,
                "hostIPC": False,
                "shareProcessNamespace": False,
                "hostUsers": True,
                "setHostnameAsFQDN": False,
                "initContainers": [],
                "ephemeralContainers": [],
            },
        )
        if "nodeName" in observed:
            if not isinstance(observed["nodeName"], str) or not observed["nodeName"]:
                return False
            del observed["nodeName"]
        if "tolerations" in observed:
            allowed = [
                {
                    "key": "node.kubernetes.io/" + condition,
                    "operator": "Exists",
                    "effect": "NoExecute",
                    "tolerationSeconds": 300,
                }
                for condition in ("not-ready", "unreachable")
            ]
            tolerations = observed.pop("tolerations")
            if len(tolerations) > 2 or any(t not in allowed for t in tolerations):
                return False
        for container in observed["containers"]:
            defaults(
                container,
                {
                    "imagePullPolicy": "IfNotPresent",
                    "terminationMessagePath": "/dev/termination-log",
                    "terminationMessagePolicy": "File",
                    "stdin": False,
                    "stdinOnce": False,
                    "tty": False,
                },
            )
            defaults(container["securityContext"], {"privileged": False, "procMount": "Default"})
            for mount in container["volumeMounts"]:
                defaults(mount, {"mountPropagation": "None", "recursiveReadOnly": "Disabled"})
        for volume in observed["volumes"]:
            if "projected" in volume:
                defaults(volume["projected"], {"defaultMode": 420})
        return observed == expected
    except (KeyError, TypeError, AttributeError):
        return False


class Scope:
    def __init__(self, kubeconfig, run_id):
        self.kubeconfig, self.run_id = kubeconfig, run_id
        self.objects = []
        self.ambiguous = False

    def command(self, *args, input_bytes=None):
        return guards.command(
            ["kubectl", "--kubeconfig", str(self.kubeconfig), "--request-timeout=15s", *args],
            input_bytes=input_bytes,
        )

    def check(self):
        if os.environ.get("OPENBAO_LEASE_HOLDER"):
            guards.assert_mutation_allowed(self.kubeconfig)
        run_dir = os.environ.get("HOMELAB_TEST_RUN_DIR", "")
        if run_dir and (Path(run_dir) / "diagnostics/lease-renewal-failed").exists():
            raise issuance.AcceptanceError()
        marker = os.environ.get("TEST_CAMPAIGN_LEASE_FAILURE_MARKER", "")
        if marker and Path(marker).exists():
            raise issuance.AcceptanceError()
        holder = os.environ.get("HOMELAB_DISRUPTION_LEASE_HOLDER", "")
        if not holder:
            raise issuance.AcceptanceError()
        guards.command(
            ["bash", str(ROOT / "scripts/openbao/lock.sh"), "check", str(self.kubeconfig), holder]
        )

    def get(self, document):
        meta = document["metadata"]
        scope = ["-n", meta["namespace"]] if meta.get("namespace") else []
        raw = self.command(
            *scope, "get", document["kind"], meta["name"], "--ignore-not-found", "-o", "json"
        )
        return strict_json(raw) if raw.strip() else None

    def create(self, document):
        self.check()
        if self.get(document):
            raise issuance.AcceptanceError()
        self.ambiguous = True
        self.objects.append(document)
        actual = strict_json(
            self.command(
                "create", "-f", "-", "-o", "json", input_bytes=json.dumps(document).encode()
            )
        )
        document["metadata"]["uid"] = actual["metadata"]["uid"]
        if document["kind"] == "Pod" and not safe_probe_spec(document["spec"], actual.get("spec")):
            raise issuance.AcceptanceError()
        self.ambiguous = False
        return document

    def assert_owned(self, document):
        actual = self.get(document)
        if (
            not actual
            or actual["metadata"].get("annotations", {}).get(OWNER) != self.run_id
            or actual["metadata"]["uid"] != document["metadata"].get("uid")
            or not safe_probe_spec(document.get("spec", {}), actual.get("spec", {}))
        ):
            raise issuance.AcceptanceError()
        return actual

    def cleanup(self):
        for document in reversed(self.objects):
            self.check()
            actual = self.get(document)
            if not actual:
                continue
            meta = actual["metadata"]
            if meta.get("annotations", {}).get(OWNER) != self.run_id or (
                document["metadata"].get("uid") and meta["uid"] != document["metadata"]["uid"]
            ):
                raise issuance.AcceptanceError()
            kind = document["kind"]
            resource = {
                "Pod": "pods",
                "ServiceAccount": "serviceaccounts",
                "Namespace": "namespaces",
                "Role": "roles",
                "RoleBinding": "rolebindings",
            }[kind]
            prefix = (
                "/apis/rbac.authorization.k8s.io/v1"
                if kind in {"Role", "RoleBinding"}
                else "/api/v1"
            )
            namespace = "/namespaces/" + meta["namespace"] if meta.get("namespace") else ""
            body = {
                "apiVersion": "v1",
                "kind": "DeleteOptions",
                "preconditions": {"uid": meta["uid"], "resourceVersion": meta["resourceVersion"]},
            }
            self.command(
                "delete",
                "--raw",
                prefix + namespace + "/" + resource + "/" + meta["name"],
                "-f",
                "-",
                input_bytes=json.dumps(body).encode(),
            )
            deadline = time.monotonic() + 90
            while self.get(document):
                if time.monotonic() >= deadline:
                    raise issuance.AcceptanceError()
                time.sleep(1)
        self.objects.clear()


class PodAPI:
    def __init__(self, scope, pod):
        self.scope, self.pod = scope, pod

    def request(
        self, method, path, *, payload=None, token=None, headers=None, target="kube", login=False
    ):
        self.scope.check()
        self.scope.assert_owned(self.pod)
        meta = self.pod["metadata"]
        args = {
            "target": target,
            "method": method,
            "path": path,
            "payload": payload,
            "token": token,
            "headers": headers,
            "login": login,
        }
        body = strict_json(
            self.scope.command(
                "-n",
                meta["namespace"],
                "exec",
                "-i",
                meta["name"],
                "-c",
                "probe",
                "--",
                "python",
                "-c",
                BRIDGE,
                input_bytes=json.dumps(args).encode(),
            )
        )
        return body["status"], body["body"]

    def login(self):
        body = issuance.call(
            self,
            "POST",
            "/v1/auth/homelab-jwt/login",
            {200},
            target="bao",
            payload={"role": "openbao-acceptance"},
            login=True,
        )
        return body["auth"]["client_token"]

    def issue(self, token):
        body = issuance.call(
            self,
            "POST",
            "/v1/kubernetes/creds/openbao-acceptance",
            {200},
            target="bao",
            token=token,
            payload={"kubernetes_namespace": issuance.NAMESPACE, "ttl": "600s"},
        )
        return body["data"]

    def revoke(self, token):
        issuance.call(
            self,
            "POST",
            "/v1/auth/token/revoke-self",
            {204},
            target="bao",
            token=token,
            payload={},
        )


def provision(scope):
    import yaml

    for filename in ("namespace.yaml", "rbac.yaml", "canary.yaml"):
        for document in yaml.safe_load_all(
            (guards.PACKAGE / "acceptance" / filename).read_bytes()
        ):
            actual = scope.get(document)
            if not actual or not guards.contains_source(document, actual):
                raise issuance.AcceptanceError()
    pods = [scope.create(pod_document(scope.run_id, issuer)) for issuer in (True, False)]
    for pod in pods:
        scope.command(
            "-n",
            pod["metadata"]["namespace"],
            "wait",
            "--for=condition=Ready",
            "pod/" + pod["metadata"]["name"],
            "--timeout=120s",
        )
    return [PodAPI(scope, pod) for pod in pods]


def run_scope():
    selected = os.environ.get("OPENBAO_OPERATOR_KUBECONFIG", "")
    if (
        not selected
        or not Path(selected).is_absolute()
        or not Path(selected).is_file()
        or os.environ.get("TEST_KUBECONFIG") != selected
    ):
        raise issuance.AcceptanceError()
    run_dir = Path(os.environ["HOMELAB_TEST_RUN_DIR"])
    if not run_dir.is_dir():
        raise issuance.AcceptanceError()
    return Scope(Path(selected), run_dir.name), run_dir


def main():
    result = {"status": "fail", "cleanup": "not-required"}
    scope = run_dir = None
    try:
        scope, run_dir = run_scope()
        revision = guards.source_revision()
        guards.require_deployed_revision(scope.kubeconfig, revision)
        required = f"issuance:openbao:{revision}:{scope.run_id}"
        supplied = os.environ.get("OPENBAO_ISSUANCE_CONFIRM") or private_prompt(
            f"Exact confirmation {required}: "
        )
        if supplied != required:
            raise issuance.AcceptanceError()
        install_interrupt_handlers()
        issuer, workload = provision(scope)
        suffix = hashlib.sha256(scope.run_id.encode()).hexdigest()[:16]
        # Predeclare exact empty objects for cleanup even after an ambiguous API response.
        for kind in ("ServiceAccount", "Role", "RoleBinding"):
            document = {
                "kind": kind,
                "metadata": {
                    "namespace": issuance.NAMESPACE,
                    "name": "openbao-zero-" + suffix,
                    "annotations": {OWNER: scope.run_id},
                },
            }
            if scope.get(document):
                raise issuance.AcceptanceError()
            scope.objects.append(document)
        result["issuer"] = issuance.issuer_boundary(issuer, time, suffix, owner=scope.run_id)
        result["credential"] = issuance.acceptance(workload, workload, time)
        result["status"] = "pass"
    except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
        result["status"] = "fail"
    finally:
        if scope is not None:
            try:
                scope.cleanup()
                result["cleanup"] = "passed"
            except Exception:  # noqa: BLE001 -- Discard credential-bearing adapter exception text.
                result.update(status="fail", cleanup="failed")
        if run_dir is not None:
            atomic_write_json(run_dir / "diagnostics/openbao-issuance.json", result)
            for name in ("cleanup", "recovery"):
                atomic_write_json(
                    run_dir / (name + ".json"),
                    {"status": result["cleanup"], "reason": "owned acceptance resources"},
                )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
