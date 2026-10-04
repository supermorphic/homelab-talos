"""Actual client, expired bearer and dry-run denial are separate acceptance controls."""

import copy
import io
import json
import subprocess
import tarfile
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.openbao.configuration import SafeError
from scripts.test import scoped_access_acceptance as acceptance


class NativeSonobuoyLifetimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # An explicit version makes this native generation cluster-independent.
        # The nonexistent config prevents any use of ambient credentials.
        cls.source = subprocess.run(
            [
                "sonobuoy",
                "gen",
                "--mode",
                "quick",
                "--plugin",
                "e2e",
                "--show-default-podspec",
                "--kubernetes-version",
                "v1.35.6",
                "--kubeconfig",
                str(acceptance.ROOT / ".tmp/synthetic-no-kubeconfig"),
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    def test_native_delay_preserves_all_e2e_and_resource_fields(self):
        before = [d for d in yaml.safe_load_all(self.source) if d]
        after = list(yaml.safe_load_all(acceptance.sonobuoy_native_manifest(self.source)))
        expected = copy.deepcopy(before)
        plugins = next(
            d
            for d in expected
            if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "sonobuoy-plugins-cm"
        )
        plugin = yaml.safe_load(plugins["data"]["plugin-0.yaml"])
        hold = plugin["podSpec"].setdefault("initContainers", [])
        hold.append(
            {
                "name": "scoped-client-lifetime",
                "image": "python:3.13.14-slim@sha256:9662417aace5ae7b8e2609cce472b72a8958e134ba372808abe9cc1a0c0125e6",
                "command": ["python", "-c", "import time; time.sleep(695)"],
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
        )
        plugins["data"]["plugin-0.yaml"] = yaml.safe_dump(plugin, sort_keys=False)
        # Compare parsed embedded YAML, not the emitter's whitespace choices.
        for documents in (expected, after):
            item = next(
                d
                for d in documents
                if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "sonobuoy-plugins-cm"
            )
            item["data"]["plugin-0.yaml"] = yaml.safe_load(item["data"]["plugin-0.yaml"])
        self.assertEqual(after, expected)

    def test_changed_focus_existing_delay_and_duplicate_plugins_are_rejected(self):
        for mutation in ("focus", "init", "duplicate"):
            documents = [d for d in yaml.safe_load_all(self.source) if d]
            plugins = next(
                d
                for d in documents
                if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "sonobuoy-plugins-cm"
            )
            plugin = yaml.safe_load(plugins["data"]["plugin-0.yaml"])
            if mutation == "focus":
                next(e for e in plugin["spec"]["env"] if e["name"] == "E2E_FOCUS")["value"] = (
                    "other"
                )
            elif mutation == "init":
                plugin["podSpec"]["initContainers"] = [{"name": "other"}]
            else:
                documents.append(copy.deepcopy(plugins))
            plugins["data"]["plugin-0.yaml"] = yaml.safe_dump(plugin)
            with self.subTest(mutation=mutation), self.assertRaises(SafeError):
                acceptance.sonobuoy_native_manifest(yaml.safe_dump_all(documents))

    def test_native_runtime_must_cross_expiry_allowance(self):
        for elapsed, status in ((0, "fail"), (694, "fail"), (695, "pass"), (800, "pass")):
            with self.subTest(elapsed=elapsed):
                result = acceptance.sonobuoy_native_window(1000, 1000 + elapsed)
                self.assertEqual(
                    result, {"status": status, "elapsed_seconds": elapsed, "minimum_seconds": 695}
                )
        for start, finish in ((-1, 800), (1000, 999), (True, 1000), (1000, "1700")):
            with self.subTest(start=start, finish=finish), self.assertRaises(SafeError):
                acceptance.sonobuoy_native_window(start, finish)

    def test_native_subcommands_require_the_quick_binding_and_redact_input_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for profile, suite, source, phase in (
                ("test-runner", "conformance.quick", self.source, "native-sonobuoy-window"),
                (
                    "test-conformance",
                    "conformance.certified",
                    self.source,
                    "native-sonobuoy-window",
                ),
                (
                    "test-conformance",
                    "conformance.quick",
                    "data: ['synthetic-private-value",
                    "native-sonobuoy-manifest",
                ),
            ):
                output = io.StringIO()
                with (
                    patch.object(
                        acceptance.access, "suite_inputs", return_value=(root / "config", root)
                    ),
                    patch.object(
                        acceptance.access,
                        "validate_invocation",
                        return_value={"profile": profile, "suite_id": suite},
                    ),
                    patch("sys.stdin", io.StringIO(source)),
                    patch("sys.stdout", output),
                ):
                    argv = ["acceptance", phase]
                    if phase.endswith("window"):
                        argv += ["1000", "1700"]
                    self.assertEqual(acceptance.main(argv), 1)
                self.assertEqual(json.loads(output.getvalue())["status"], "fail")
                self.assertNotIn("synthetic-private-value", output.getvalue())


class NativeConformanceRoutingTests(unittest.TestCase):
    setUpClass = classmethod(NativeSonobuoyLifetimeTests.setUpClass.__func__)

    def setUp(self):
        from scripts.test.core.test_coordination_routing import CoordinationRoutingTests

        CoordinationRoutingTests.setUp(self)
        manifest = self.root / "native-quick.yaml"
        manifest.write_text(self.source)
        report = self.root / "junit.xml"
        report.write_text(
            '<testsuite name="e2e"><testcase name="native-quick-assertion"/></testsuite>'
        )
        archive = self.root / "native.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            output.add(report, arcname="plugins/e2e/results/global/junit.xml")
        self.calls = self.root / "sonobuoy-calls"
        self.environment.update(
            {
                "FAKE_SONOBUOY_MANIFEST": str(manifest),
                "FAKE_SONOBUOY_ARCHIVE": str(archive),
                "FAKE_SONOBUOY_CALLS": str(self.calls),
                "TEST_SONOBUOY_BIN": str(
                    acceptance.ROOT / "tests/fixtures/result-coordinator/fake-sonobuoy.sh"
                ),
                "TEST_KUBECTL_BIN": str(
                    acceptance.ROOT / "tests/fixtures/result-coordinator/fake-kubectl.sh"
                ),
                "TEST_SONOBUOY_PRIVATE_ROOT": str(self.root / "private-native-results"),
            }
        )

    def execute(self, mode="quick", acceptance_enabled=False):
        environment = {**self.environment, "MODE": mode}
        if acceptance_enabled:
            environment["TEST_ACCESS_ACCEPTANCE_CONFIRM"] = acceptance.CONFIRMATION
        return subprocess.run(
            ["scripts/test/run-conformance.sh"],
            cwd=acceptance.ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )

    def test_fast_native_success_cannot_pass_lifetime_acceptance(self):
        result = self.execute(acceptance_enabled=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        run_dir = next((self.root / "results").iterdir())
        import xml.etree.ElementTree as ET

        cases = {
            case.get("name"): case
            for case in ET.parse(run_dir / "junit.xml").getroot().iter("testcase")
        }
        self.assertIsNone(cases["native-quick-assertion"].find("failure"))
        self.assertIsNotNone(cases["native-sonobuoy-client-refresh"].find("failure"))
        self.assertIn("run --file", self.calls.read_text())
        self.assertNotIn("acceptance conformance.quick", (self.root / "trace").read_text())
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_default_quick_and_certified_keep_their_original_native_commands(self):
        for mode, enabled in (("quick", False), ("certified", True)):
            with self.subTest(mode=mode):
                result = self.execute(mode=mode, acceptance_enabled=enabled)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls.read_text()
        self.assertIn("run --mode quick --plugin e2e --timeout 900 --wait=20", calls)
        self.assertIn(
            "run --mode certified-conformance --plugin e2e --timeout 10800 --wait=190", calls
        )
        self.assertNotIn("gen ", calls)


class Clock:
    def __init__(self):
        self.now = 1000

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class API:
    def __init__(self, clock):
        self.clock = clock
        self.events = []
        self.expiry_status = 401
        self.denial_status = 403
        self.username = "system:serviceaccount:kube-system:homelab-test-flux-restart"
        self.stopped = False

    def bootstrap(self):
        self.events.append("bootstrap")
        return 1600

    @contextmanager
    def proxy(self):
        self.events.append("proxy")
        try:
            yield
        finally:
            self.stopped = True

    def identity(self):
        self.events.append(("identity", self.clock.time()))
        return self.username

    def denial(self):
        self.events.append(("denial", self.clock.time()))
        return self.denial_status, {"reason": "Forbidden", "code": self.denial_status}

    def admission_denial(self, profile):
        self.events.append(("admission-denial", self.clock.time(), profile))
        return self.denial_status, {
            "reason": "Forbidden",
            "code": self.denial_status,
            "message": "deployments.apps \"source-controller\" is forbidden: "
            "ValidatingAdmissionPolicy 'homelab-test-flux-restart' with binding "
            "'homelab-test-flux-restart' denied request: Only the four Flux controller "
            "templates may restart; preserve their workloads, metadata and status.",
        }

    def expired(self):
        self.events.append(("expired", self.clock.time()))
        return self.expiry_status, {"reason": "Unauthorized", "code": self.expiry_status}


class ScopedAccessAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.api = API(self.clock)
        self.checks = []

    def checkpoint(self):
        self.checks.append(self.clock.time())

    def test_actual_identity_before_after_bound_and_real_expired_token_denial(self):
        phases = []
        acceptance.prove(self.api, "test-flux-restart", self.checkpoint, phases, clock=self.clock)
        identities = [
            event[1]
            for event in self.api.events
            if isinstance(event, tuple) and event[0] == "identity"
        ]
        self.assertEqual(len(identities), 2)
        self.assertGreater(identities[1], identities[0] + 600 + 60 + 30)
        self.assertIn(("expired", identities[1]), self.api.events)
        self.assertEqual(
            len(
                [
                    event
                    for event in self.api.events
                    if isinstance(event, tuple) and event[0] == "denial"
                ]
            ),
            2,
        )
        self.assertTrue(self.api.stopped)
        self.assertGreater(len(self.checks), 100)
        self.assertEqual(phases[-1], "client-refreshed-and-boundary-denied")

    def test_protocol_errors_or_wrong_identity_never_count_as_authority_denial(self):
        for status in (200, 400, 404, 500):
            with self.subTest(status=status):
                self.api.denial_status = status
                with self.assertRaises(SafeError):
                    acceptance.prove(
                        self.api, "test-flux-restart", self.checkpoint, [], clock=self.clock
                    )
                self.assertTrue(self.api.stopped)
        self.api.denial_status = 403
        self.api.username = "system:serviceaccount:kube-system:homelab-observer"
        with self.assertRaises(SafeError):
            acceptance.prove(self.api, "test-flux-restart", self.checkpoint, [], clock=self.clock)

    def test_expired_token_success_is_failure_even_if_client_survives(self):
        self.api.expiry_status = 200
        with self.assertRaises(SafeError):
            acceptance.prove(self.api, "test-flux-restart", self.checkpoint, [], clock=self.clock)
        self.assertTrue(self.api.stopped)

    def test_source_or_lease_loss_stops_before_next_request_and_closes_proxy(self):
        def checkpoint():
            if self.clock.time() > 1010:
                raise SafeError("source-mismatch")

        with self.assertRaises(SafeError):
            acceptance.prove(self.api, "test-flux-restart", checkpoint, [], clock=self.clock)
        self.assertTrue(self.api.stopped)
        self.assertFalse(any(isinstance(e, tuple) and e[0] == "expired" for e in self.api.events))

    def test_conformance_keeps_its_declared_admin_exception_and_still_proves_refresh(self):
        self.api.username = "system:serviceaccount:kube-system:homelab-test-conformance"
        acceptance.prove(self.api, "test-conformance", self.checkpoint, [], clock=self.clock)
        self.assertFalse(any(isinstance(e, tuple) and e[0] == "denial" for e in self.api.events))
        self.assertTrue(any(isinstance(e, tuple) and e[0] == "expired" for e in self.api.events))

    def test_rbac_denial_cannot_be_reported_as_admission_evidence(self):
        with (
            patch.object(
                self.api,
                "admission_denial",
                return_value=(
                    403,
                    {"reason": "Forbidden", "code": 403, "message": "RBAC forbidden"},
                ),
            ),
            self.assertRaises(SafeError),
        ):
            acceptance.prove(self.api, "test-flux-restart", self.checkpoint, [], clock=self.clock)

    def test_named_policy_denial_accepts_kubernetes_default_invalid_reason(self):
        response = self.api.admission_denial("test-flux-restart")[1]
        response.update(reason="Invalid", code=422)
        with patch.object(self.api, "admission_denial", return_value=(422, response)):
            phases = []
            acceptance.prove(self.api, "test-flux-restart", self.checkpoint, phases, clock=self.clock)
        self.assertIn("server-dry-run-admission-denied", phases)
        self.assertEqual(phases[-1], "client-refreshed-and-boundary-denied")

    def test_invalid_response_requires_exact_policy_binding_and_intended_message(self):
        message = self.api.admission_denial("test-flux-restart")[1]["message"]
        for changed in (
            message.replace("with binding 'homelab-test-flux-restart'", "with binding 'other'"),
            message.replace("ValidatingAdmissionPolicy 'homelab-test-flux-restart'", "ValidatingAdmissionPolicy 'other'"),
            message.split("denied request:")[0] + "denied request: expression resulted in error: no such key: labels",
            "unrelated schema validation failed: homelab-test-flux-restart",
            message + " expression resulted in error: no such key: labels",
        ):
            with self.subTest(message=changed):
                for status, reason in ((422, "Invalid"), (403, "Forbidden")):
                    self.assertFalse(acceptance.admission_forbidden(
                        (status, {"reason": reason, "code": status, "message": changed}),
                        "test-flux-restart",
                    ))
        for status, reason, code in ((400, "BadRequest", 400), (403, "Invalid", 403), (422, "Forbidden", 422), (422, "Invalid", 403)):
            with self.subTest(status=status, reason=reason, code=code):
                self.assertFalse(acceptance.admission_forbidden(
                    (status, {"reason": reason, "code": code, "message": message}), "test-flux-restart"
                ))


class LiveClientRequestTests(unittest.TestCase):
    def test_openbao_denial_keeps_complete_probe_shape_and_changes_only_parent_name(self):
        for profile, namespace, account in (
            ("test-openbao-issuance", "openbao", "openbao"),
            ("test-openbao-ha", "openbao-acceptance", "openbao-acceptance"),
        ):
            with self.subTest(profile=profile):
                client = acceptance.LiveClient(Path("/synthetic/config"), lambda: None)
                client.proxy_url = "http://127.0.0.1:12345"
                with patch.object(client, "request", return_value=(422, {})) as request:
                    client.admission_denial(profile)
                payload = request.call_args.kwargs["payload"]
                self.assertEqual(payload["metadata"]["name"], "homelab-scoped-denial-probe")
                self.assertEqual(payload["metadata"]["namespace"], namespace)
                self.assertEqual(payload["metadata"]["labels"], {"app.kubernetes.io/name": "openbao-acceptance"})
                self.assertEqual(payload["metadata"]["annotations"], {"homelab.supermorphic.com/test-run": "scoped-denial-probe"})
                spec = payload["spec"]
                self.assertEqual(spec["serviceAccountName"], account)
                self.assertEqual(spec["activeDeadlineSeconds"], 1800)
                self.assertFalse(spec["automountServiceAccountToken"])
                self.assertEqual(spec["securityContext"]["seccompProfile"], {"type": "RuntimeDefault"})
                self.assertEqual(spec["containers"][0]["volumeMounts"], [{"name": "identity", "mountPath": "/identity", "readOnly": True}])
                self.assertEqual(spec["volumes"][0]["name"], "identity")
                self.assertEqual(len(spec["volumes"][0]["projected"]["sources"]), 2)
                self.assertTrue(request.call_args.args[1].endswith("?dryRun=All"))

    def test_runner_probe_supplies_policy_run_label_without_claiming_an_allowed_name(self):
        client = acceptance.LiveClient(Path("/synthetic/config"), lambda: None)
        client.proxy_url = "http://127.0.0.1:12345"
        with patch.object(client, "request", return_value=(422, {})) as request:
            client.admission_denial("test-runner")
        payload = request.call_args.kwargs["payload"]
        self.assertRegex(payload["metadata"]["labels"]["homelab-talos/run-id"], r"^[0-9]{10}-[0-9]+$")
        self.assertEqual(payload["metadata"]["name"], "homelab-scoped-denial-probe")
        self.assertTrue(request.call_args.args[1].endswith("?dryRun=All"))

    def test_registered_test_families_are_eligible_but_verification_is_not(self):
        for source in ("test", "chainsaw", "probe", "sonobuoy", "verification"):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as temp:
                with (
                    patch.object(
                        acceptance.access,
                        "suite_inputs",
                        return_value=(Path("/synthetic/config"), Path(temp)),
                    ),
                    patch.object(
                        acceptance.access,
                        "_canonical_entry",
                        return_value=({"metadata": {"source": source}}, None),
                    ),
                    patch.object(
                        acceptance.access,
                        "validate_invocation",
                        return_value={"profile": "test-conformance"},
                    ),
                    patch.object(acceptance.guards, "source_revision", return_value="a" * 40),
                    patch.object(acceptance, "install_interrupt_handlers"),
                    patch.object(acceptance, "prove") as prove,
                    patch("sys.stdout", new_callable=io.StringIO),
                ):
                    status = acceptance.main(
                        ["acceptance", "conformance.quick", acceptance.CONFIRMATION]
                    )
                self.assertEqual(status, 1 if source == "verification" else 0)
                self.assertEqual(prove.call_count, 0 if source == "verification" else 1)

    def test_unexpected_transport_message_does_not_enter_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            run_dir = Path(temp)
            with (
                patch.object(
                    acceptance.access,
                    "suite_inputs",
                    return_value=(Path("/synthetic/config"), run_dir),
                ),
                patch.object(
                    acceptance.access,
                    "_canonical_entry",
                    return_value=({"metadata": {"source": "test"}}, None),
                ),
                patch.object(
                    acceptance.access,
                    "validate_invocation",
                    return_value={"profile": "test-flux-restart"},
                ),
                patch.object(acceptance.guards, "source_revision", return_value="a" * 40),
                patch.object(acceptance, "install_interrupt_handlers"),
                patch.object(
                    acceptance, "prove", side_effect=RuntimeError("synthetic-private-bearer")
                ),
                patch("sys.stdout", new_callable=io.StringIO) as output,
            ):
                status = acceptance.main(
                    ["acceptance", "test.flux-restart", acceptance.CONFIRMATION]
                )
            self.assertEqual(status, 1)
            self.assertNotIn("synthetic-private-bearer", output.getvalue())
            diagnostic = (run_dir / "diagnostics/scoped-access.json").read_text()
            self.assertEqual(json.loads(diagnostic)["classification"], "invalid-response")
            self.assertNotIn("synthetic-private-bearer", diagnostic)
            self.assertNotIn(
                "synthetic-private-bearer",
                (run_dir / "diagnostics/fragments/scoped-access.xml").read_text(),
            )

    def test_bad_intent_rejected_before_selecting_credentials(self):
        with (
            patch.object(acceptance.access, "suite_inputs") as inputs,
            patch("sys.stdout", new_callable=io.StringIO),
        ):
            self.assertEqual(acceptance.main(["acceptance", "test.flux-restart", "wrong"]), 1)
        inputs.assert_not_called()

    def test_each_admission_probe_is_dry_run_with_exact_target_and_fresh_patch_guards(self):
        targets = {
            "test-runner": "/api/v1/namespaces/media/pods",
            "test-flux-restart": "/apis/apps/v1/namespaces/flux-system/deployments/source-controller",
            "test-node-reschedule": "/api/v1/nodes/nuc1",
            "test-cilium-connectivity": "/api/v1/namespaces",
            "test-openbao-issuance": "/api/v1/namespaces/openbao/pods",
            "test-openbao-ha": "/api/v1/namespaces/openbao-acceptance/pods",
            "test-openbao-restore": "/api/v1/namespaces/openbao-restore-test/configmaps",
        }
        for profile, target in targets.items():
            with self.subTest(profile=profile):
                client = acceptance.LiveClient(Path("/synthetic/config"), lambda: None)
                client.proxy_url = "http://127.0.0.1:12345"
                calls = []

                def request(base, path, *, calls=calls, **kwargs):
                    calls.append((path, kwargs))
                    if not kwargs:
                        return 200, {
                            "metadata": {"uid": "observed-uid", "resourceVersion": "37"},
                            "spec": {"replicas": 1},
                        }
                    return 403, {"reason": "Forbidden", "code": 403}

                with patch.object(client, "request", side_effect=request):
                    client.admission_denial(profile)
                path, args = calls[-1]
                self.assertEqual(path, target + "?dryRun=All")
                if profile in {"test-flux-restart", "test-node-reschedule"}:
                    self.assertEqual(calls[0][0], target)
                    self.assertEqual(args["method"], "PATCH")
                    self.assertEqual(args["content_type"], "application/json-patch+json")
                    self.assertEqual(
                        args["payload"][:2],
                        [
                            {"op": "test", "path": "/metadata/uid", "value": "observed-uid"},
                            {"op": "test", "path": "/metadata/resourceVersion", "value": "37"},
                        ],
                    )
                else:
                    self.assertEqual(
                        args["payload"]["metadata"]["name"], "homelab-scoped-denial-probe"
                    )

    def test_missing_live_patch_identity_stops_before_write(self):
        client = acceptance.LiveClient(Path("/synthetic/config"), lambda: None)
        with patch.object(client, "request", return_value=(200, {"metadata": {}})) as request:
            with self.assertRaises(SafeError):
                client.admission_denial("test-node-reschedule")
            self.assertEqual(request.call_count, 1)

    def test_redirect_refused_before_forwarding_bearer(self):
        with self.assertRaises(SafeError):
            acceptance.NoRedirect().redirect_request(
                None, None, 302, "redirect", {}, "https://example.invalid"
            )


if __name__ == "__main__":
    unittest.main()
