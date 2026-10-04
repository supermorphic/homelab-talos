"""Actual client, expired bearer and dry-run denial are separate acceptance controls."""

import io
import json
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

from scripts.openbao.configuration import SafeError
from scripts.test import scoped_access_acceptance as acceptance


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
            "message": 'ValidatingAdmissionPolicy "homelab-test-flux-restart" denied request',
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


class LiveClientRequestTests(unittest.TestCase):
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
