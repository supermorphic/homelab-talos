"""Opt-in live proof of a mapped test's actual client refresh and API boundary.

Bearer values stay in memory. Only fixed check labels and timing enter the
existing canonical diagnostics/JUnit artifacts. No persistent API object is made.
"""

import base64
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

import yaml

from scripts.openbao import credentials, guards, issuance
from scripts.openbao.configuration import SafeError
from scripts.test import access, junit_report
from scripts.test.scenarios.resilience_support import atomic_write_json, install_interrupt_handlers

ROOT = Path(__file__).resolve().parents[2]
CONFIRMATION = "verify:scoped-access:ttl-and-denials"
SELF_REVIEW = "/apis/authentication.k8s.io/v1/selfsubjectreviews"
NODES = "/api/v1/nodes?limit=1"
NATIVE_SONOBUOY_SECONDS = 600 + issuance.SKEW + issuance.API_EXPIRY_LEEWAY + 5


def sonobuoy_native_manifest(source):
    """Keep the native quick client polling without changing the E2E program."""
    from scripts.test.scenarios.openbao_issuance import IMAGE

    documents = [doc for doc in yaml.safe_load_all(source) if doc]
    plugins = [
        doc
        for doc in documents
        if doc.get("kind") == "ConfigMap"
        and doc.get("metadata", {}).get("name") == "sonobuoy-plugins-cm"
    ]
    if len(plugins) != 1 or set(plugins[0].get("data", {})) != {"plugin-0.yaml"}:
        raise SafeError("invalid-source")
    plugin = yaml.safe_load(plugins[0]["data"]["plugin-0.yaml"])
    if (
        plugin.get("sonobuoy-config")
        != {"driver": "Job", "plugin-name": "e2e", "result-format": "junit"}
        or [entry for entry in plugin["spec"]["env"] if entry["name"] == "E2E_FOCUS"]
        != [{"name": "E2E_FOCUS", "value": "Pods should be submitted and removed"}]
        or plugin["podSpec"].get("initContainers")
    ):
        raise SafeError("invalid-source")
    plugin["podSpec"]["initContainers"] = [
        {
            "name": "scoped-client-lifetime",
            "image": IMAGE,
            "command": ["python", "-c", f"import time; time.sleep({NATIVE_SONOBUOY_SECONDS})"],
            "resources": {
                "requests": {"cpu": "1m", "memory": "16Mi"},
                "limits": {"cpu": "100m", "memory": "64Mi"},
            },
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": 65532,
                "allowPrivilegeEscalation": False,
                "readOnlyRootFilesystem": True,
                "capabilities": {"drop": ["ALL"]},
                "seccompProfile": {"type": "RuntimeDefault"},
            },
        }
    ]
    plugins[0]["data"]["plugin-0.yaml"] = yaml.safe_dump(plugin, sort_keys=False)
    return yaml.safe_dump_all(documents, sort_keys=False)


def sonobuoy_native_window(start, finish):
    if type(start) is not int or type(finish) is not int or start < 0 or finish < start:
        raise SafeError("invalid-source")
    elapsed = finish - start
    return {
        "status": "pass" if elapsed >= NATIVE_SONOBUOY_SECONDS else "fail",
        "elapsed_seconds": elapsed,
        "minimum_seconds": NATIVE_SONOBUOY_SECONDS,
    }


def native_sonobuoy_main(argv):
    result = {"status": "fail"}
    run_dir = None
    phase = argv[1]
    try:
        config, run_dir = access.suite_inputs(ROOT, "conformance.quick")
        binding = access.validate_invocation(ROOT, config)
        if binding["profile"] != "test-conformance" or binding["suite_id"] != "conformance.quick":
            raise SafeError("invalid-source")
        if phase == "native-sonobuoy-manifest" and len(argv) == 2:
            print(sonobuoy_native_manifest(sys.stdin.read()), end="")
            return 0
        if phase != "native-sonobuoy-window" or len(argv) != 4:
            raise SafeError("invalid-source")
        result = sonobuoy_native_window(int(argv[2]), int(argv[3]))
    except BaseException as error:  # noqa: BLE001 -- Never expose adapter/source bodies.
        result["classification"] = (
            str(error) if isinstance(error, SafeError) else "invalid-response"
        )
    if phase == "native-sonobuoy-window" and run_dir is not None:
        atomic_write_json(run_dir / "diagnostics/sonobuoy/native-client-lifetime.json", result)
        junit_report.write_case(
            run_dir / "diagnostics/fragments/sonobuoy-native-client.xml",
            "conformance.quick",
            "native-sonobuoy-client-refresh",
            "passed" if result["status"] == "pass" else "failed",
            str(result.get("elapsed_seconds", 0)),
        )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


ADMISSION_PROFILES = {
    "test-runner": "homelab-test-probe-pods",
    "test-flux-restart": "homelab-test-flux-restart",
    "test-cilium-connectivity": "homelab-test-cilium-namespaces",
    "test-node-reschedule": "homelab-test-node-scheduling",
    "test-openbao-issuance": "homelab-test-openbao-probe-pods",
    "test-openbao-ha": "homelab-test-openbao-probe-pods",
    "test-openbao-restore": "homelab-test-openbao-restore-private",
}
ADMISSION_MESSAGES = {
    "test-runner": "Only bounded run-owned Plex control and selected probes may be created or deleted.",
    "test-flux-restart": "Only the four Flux controller templates may restart; preserve their workloads, metadata and status.",
    "test-cilium-connectivity": "Only the three registered connectivity fixture namespaces may be allocated, updated or removed.",
    "test-node-reschedule": "Only the three named Nodes scheduling flag may change; preserve all other Node state.",
    "test-openbao-issuance": "Only the registered acceptance and issuer probe parents, with stable ownership and specification, are admitted.",
    "test-openbao-ha": "Only the registered acceptance and issuer probe parents, with stable ownership and specification, are admitted.",
    "test-openbao-restore": "Only immutable, run-owned scratch private fixtures may be created or removed.",
}


def forbidden(response):
    status, body = response
    return status == 403 and body.get("reason") == "Forbidden" and body.get("code") == 403


def admission_forbidden(response, profile):
    # Kubernetes defaults validation denials to Invalid/422. Require the exact
    # policy, binding and intended validation message; CEL errors and unrelated
    # schema/RBAC failures cannot establish the intended admission boundary.
    status, body = response
    message = response[1].get("message", "")
    policy = ADMISSION_PROFILES[profile]
    return (
        (status, body.get("reason"), body.get("code"))
        in {(403, "Forbidden", 403), (422, "Invalid", 422)}
        and isinstance(message, str)
        and message.endswith(
            f"ValidatingAdmissionPolicy '{policy}' with binding '{policy}' "
            f"denied request: {ADMISSION_MESSAGES[profile]}"
        )
    )


def prove(client, profile, checkpoint, phases, *, clock=time):
    """An open process alone is insufficient: require fresh authenticated replies."""
    expected = "system:serviceaccount:kube-system:" + credentials.PROFILES[profile]
    checkpoint()
    expiry = client.bootstrap()
    with client.proxy():
        checkpoint()
        if client.identity() != expected:
            raise SafeError("authentication-failed")
        # A successful first response bounds the latest possible issuance time
        # of this actual cached client, even if its login followed our raw token.
        first_success = clock.time()
        phases.append("client-identity-before-expiry")
        if profile != "test-conformance":
            checkpoint()
            if not forbidden(client.denial()):
                raise SafeError("invalid-response")
            phases.append("server-dry-run-boundary-denied")
            if profile in ADMISSION_PROFILES:
                checkpoint()
                if not admission_forbidden(client.admission_denial(profile), profile):
                    raise SafeError("invalid-response")
                phases.append("server-dry-run-admission-denied")
        deadline = (
            max(expiry, first_success + 600 + issuance.SKEW) + issuance.API_EXPIRY_LEEWAY + 5
        )
        while clock.time() <= deadline:
            checkpoint()
            clock.sleep(min(5, max(0.1, deadline - clock.time() + 0.1)))
        checkpoint()
        status, body = client.expired()
        if status != 401 or body.get("reason") != "Unauthorized" or body.get("code") != 401:
            raise SafeError("invalid-response")
        phases.append("original-bearer-expired-at-api")
        checkpoint()
        if client.identity() != expected:
            raise SafeError("authentication-failed")
        if profile != "test-conformance":
            checkpoint()
            if not forbidden(client.denial()):
                raise SafeError("invalid-response")
        if profile in ADMISSION_PROFILES:
            checkpoint()
            if not admission_forbidden(client.admission_denial(profile), profile):
                raise SafeError("invalid-response")
        phases.append(
            "client-refreshed-and-boundary-denied"
            if profile != "test-conformance"
            else "admin-client-refreshed"
        )


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SafeError("invalid-response")


class LiveClient:
    def __init__(self, config, checkpoint):
        self.config = config
        self.checkpoint = checkpoint
        self.token = None
        self.process = None
        self.proxy_url = None
        self.server = None
        self.context = None

    def bootstrap(self):
        from scripts.openbao import workstation

        local = credentials.load_workstation(workstation.DIRECTORY)
        cluster = local["cluster"]
        self.server = cluster["server"]
        self.context = ssl.create_default_context(
            cadata=base64.b64decode(cluster["certificate_authority_data"]).decode()
        )
        result = subprocess.run(
            [str(ROOT / credentials.LAUNCHER), "invocation", str(self.config)],
            env={
                **os.environ,
                "KUBERNETES_EXEC_INFO": json.dumps(
                    {
                        "apiVersion": credentials.API_VERSION,
                        "kind": "ExecCredential",
                        "spec": {"interactive": False},
                    }
                ),
            },
            capture_output=True,
            timeout=45,
            check=False,
        )
        if result.returncode != 0 or len(result.stdout) > 1048576:
            raise SafeError("invalid-response")
        value = json.loads(result.stdout)
        if (
            value.get("apiVersion") != credentials.API_VERSION
            or value.get("kind") != "ExecCredential"
        ):
            raise SafeError("invalid-response")
        self.token = value["status"]["token"]
        return datetime.fromisoformat(value["status"]["expirationTimestamp"]).timestamp()

    def request(
        self,
        base,
        path,
        *,
        payload=None,
        token=None,
        context=None,
        method=None,
        content_type="application/json",
    ):
        self.checkpoint()
        headers = {"Content-Type": content_type}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(
            base + path,
            data=json.dumps(payload).encode() if payload is not None else None,
            headers=headers,
            method=method,
        )
        try:
            opener = urllib.request.build_opener(
                NoRedirect(), urllib.request.HTTPSHandler(context=context)
            )
            response = opener.open(request, timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            body = response.read(1048577)
            if len(body) > 1048576:
                raise SafeError("invalid-response")
            value = json.loads(body)
            if not isinstance(value, dict):
                raise SafeError("invalid-response")
            return response.code, value

    @contextmanager
    def proxy(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.proxy_url = f"http://127.0.0.1:{port}"
        self.process = subprocess.Popen(
            [
                "kubectl",
                "--kubeconfig",
                str(self.config),
                "proxy",
                "--address=127.0.0.1",
                f"--port={port}",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 30
            while True:
                if self.process.poll() is not None or time.monotonic() >= deadline:
                    raise SafeError("invalid-response")
                try:
                    status, body = self.request(self.proxy_url, NODES)
                except OSError:
                    time.sleep(0.5)
                    continue
                if status != 200 or body.get("kind") != "NodeList":
                    raise SafeError("invalid-response")
                break
            yield
        finally:
            self.token = None
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)

    def identity(self):
        if self.process.poll() is not None:
            raise SafeError("invalid-response")
        status, body = self.request(
            self.proxy_url,
            SELF_REVIEW,
            payload={"apiVersion": "authentication.k8s.io/v1", "kind": "SelfSubjectReview"},
        )
        if status != 201 or body.get("kind") != "SelfSubjectReview":
            raise SafeError("invalid-response")
        return body["status"]["userInfo"]["username"]

    def denial(self):
        # All non-admin mapped profiles exclude Secret creation in OpenBao.
        # dryRun=All guarantees that even an unexpected grant creates no object.
        return self.request(
            self.proxy_url,
            "/api/v1/namespaces/openbao/secrets?dryRun=All",
            payload={
                "apiVersion": "v1",
                "kind": "Secret",
                "type": "Opaque",
                "metadata": {"name": "homelab-scoped-denial-probe", "namespace": "openbao"},
                "data": {"marker": "c3ludGhldGlj"},
            },
        )

    def admission_denial(self, profile):
        if profile in {"test-flux-restart", "test-node-reschedule"}:
            path = (
                "/apis/apps/v1/namespaces/flux-system/deployments/source-controller"
                if profile == "test-flux-restart"
                else "/api/v1/nodes/nuc1"
            )
            status, current = self.request(self.proxy_url, path)
            if status != 200:
                raise SafeError("invalid-response")
            meta = current["metadata"]
            if not meta.get("uid") or not meta.get("resourceVersion"):
                raise SafeError("invalid-response")
            patches = [
                {"op": "test", "path": "/metadata/uid", "value": meta["uid"]},
                {
                    "op": "test",
                    "path": "/metadata/resourceVersion",
                    "value": meta["resourceVersion"],
                },
            ]
            if profile == "test-flux-restart":
                patches.append(
                    {
                        "op": "replace",
                        "path": "/spec/replicas",
                        "value": current["spec"]["replicas"] + 1,
                    }
                )
            else:
                patches.append(
                    {
                        "op": "add",
                        "path": "/metadata/labels/homelab-talos~1denial-probe",
                        "value": "synthetic",
                    }
                )
            return self.request(
                self.proxy_url,
                path + "?dryRun=All",
                payload=patches,
                method="PATCH",
                content_type="application/json-patch+json",
            )
        if profile == "test-cilium-connectivity":
            return self.request(
                self.proxy_url,
                "/api/v1/namespaces?dryRun=All",
                payload={
                    "apiVersion": "v1",
                    "kind": "Namespace",
                    "metadata": {"name": "homelab-scoped-denial-probe"},
                },
            )
        if profile == "test-openbao-restore":
            from scripts.test.scenarios.openbao_restore import scratch_configuration

            return self.request(
                self.proxy_url,
                "/api/v1/namespaces/openbao-restore-test/configmaps?dryRun=All",
                payload={
                    "apiVersion": "v1",
                    "kind": "ConfigMap",
                    "immutable": True,
                    "metadata": {
                        "name": "homelab-scoped-denial-probe",
                        "namespace": "openbao-restore-test",
                        "annotations": {
                            "homelab.supermorphic.com/test-run": "credential-issuer-denial-probe"
                        },
                    },
                    "data": {"server.hcl": scratch_configuration("credential-issuer-acceptance")},
                },
            )
        namespace = {
            "test-runner": "media",
            "test-openbao-issuance": "openbao",
            "test-openbao-ha": "openbao-acceptance",
        }.get(profile)
        if namespace is None:
            raise SafeError("invalid-source")
        if profile in {"test-openbao-issuance", "test-openbao-ha"}:
            from scripts.test.scenarios.openbao_issuance import pod_document

            payload = pod_document("scoped-denial-probe", profile == "test-openbao-issuance")
            payload["metadata"]["name"] = "homelab-scoped-denial-probe"
        else:
            payload = {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {
                    "name": "homelab-scoped-denial-probe",
                    "namespace": namespace,
                    "labels": {"homelab-talos/run-id": "1700000000-1"},
                },
                "spec": {
                    "restartPolicy": "Never",
                    "automountServiceAccountToken": False,
                    "containers": [{"name": "probe", "image": "registry.k8s.io/pause:3.10"}],
                },
            }
        return self.request(
            self.proxy_url,
            f"/api/v1/namespaces/{namespace}/pods?dryRun=All",
            payload=payload,
        )

    def expired(self):
        return self.request(self.server, NODES, token=self.token, context=self.context)


def main(argv):
    if len(argv) > 1 and argv[1] in {"native-sonobuoy-manifest", "native-sonobuoy-window"}:
        return native_sonobuoy_main(argv)
    result = {"status": "fail", "phases": []}
    run_dir = None
    started = time.monotonic()
    try:
        if len(argv) != 3 or argv[2] != CONFIRMATION:
            raise SafeError("invalid-source")
        suite = argv[1]
        config, run_dir = access.suite_inputs(ROOT, suite)
        entry, _ = access._canonical_entry(ROOT, suite)
        binding = access.validate_invocation(ROOT, config)
        if (
            entry["metadata"]["source"] not in {"test", "chainsaw", "probe", "sonobuoy"}
            or binding["profile"] is None
        ):
            raise SafeError("invalid-source")
        revision = guards.source_revision()
        install_interrupt_handlers()
        result["profile"] = binding["profile"]

        def checkpoint():
            if (
                access.validate_invocation(ROOT, config) != binding
                or guards.source_revision() != revision
            ):
                raise SafeError("source-mismatch")
            markers = [run_dir / "diagnostics/lease-renewal-failed"]
            if os.environ.get("TEST_CAMPAIGN_LEASE_FAILURE_MARKER"):
                markers.append(Path(os.environ["TEST_CAMPAIGN_LEASE_FAILURE_MARKER"]))
            if any(marker.exists() for marker in markers):
                raise SafeError("read-denied")

        prove(LiveClient(config, checkpoint), binding["profile"], checkpoint, result["phases"])
        result["status"] = "pass"
    except BaseException as error:  # noqa: BLE001 -- Never render bearer/transport responses.
        result["classification"] = (
            str(error) if isinstance(error, SafeError) else "invalid-response"
        )
    finally:
        if run_dir is not None:
            atomic_write_json(run_dir / "diagnostics/scoped-access.json", result)
            junit_report.write_case(
                run_dir / "diagnostics/fragments/scoped-access.xml",
                argv[1],
                "scoped-client-refresh-and-boundary",
                "passed" if result["status"] == "pass" else "failed",
                str(round(time.monotonic() - started, 3)),
            )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
