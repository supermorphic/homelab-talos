"""Synthetic API oracles: status codes, actual identities, and real expiry semantics."""

import base64
import importlib
import json
import unittest


class Clock:
    def __init__(self):
        self.now = 1000

    def time(self):
        return self.now

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def jwt(**changes):
    claims = {
        "sub": "system:serviceaccount:openbao-acceptance:openbao-issued-reader",
        "aud": ["https://kubernetes.default.svc.cluster.local"],
        "iat": 1000,
        "exp": 1600,
    }
    claims.update(changes)
    return (
        "fixture."
        + base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
        + ".synthetic"
    )


class API:
    def __init__(self, clock):
        self.clock = clock
        self.token = jwt()
        self.identity = "system:serviceaccount:openbao-acceptance:openbao-issued-reader"
        self.allowed_status = 201
        self.denied_status = 403
        self.expired_status = 401
        self.calls = []

    def request(self, method, path, *, payload=None, token=None, headers=None):
        self.calls.append((method, path, payload, headers))
        if path.endswith("/token"):
            if (
                path
                == "/api/v1/namespaces/openbao-acceptance/serviceaccounts/openbao-issued-reader/token"
            ):
                return self.allowed_status, {
                    "status": {"token": self.token, "expirationTimestamp": "1970-01-01T00:26:40Z"}
                }
            if isinstance(self.denied_status, Exception):
                raise self.denied_status
            return self.denied_status, {}
        if path.endswith("selfsubjectreviews"):
            if headers:
                return self.denied_status, {}
            return 201, {"status": {"userInfo": {"username": self.identity}}}
        if path.endswith("/configmaps/openbao-canary"):
            return (
                (self.expired_status, {})
                if self.clock.now > 1600
                else (200, {"data": {"marker": "synthetic-openbao-reader-canary"}})
            )
        return self.denied_status, {}

    def login(self):
        return "synthetic-session"

    def issue(self, session):
        return {
            "service_account_name": "openbao-issued-reader",
            "service_account_namespace": "openbao-acceptance",
            "service_account_token": self.token,
        }

    def revoke(self, session):
        pass

    def deny_unapproved(self, session):
        return True


class IssuanceTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(
            importlib.util.find_spec("scripts.openbao.issuance"), "issuance implementation missing"
        )
        self.module = importlib.import_module("scripts.openbao.issuance")
        self.clock = Clock()
        self.api = API(self.clock)

    def test_openbao_denial_is_proved_before_revoke_and_kubernetes_use(self):
        events = []
        self.api.deny_unapproved = lambda session: events.append("denied") or True
        self.api.revoke = lambda session: events.append("revoked")
        self.module.acceptance(self.api, self.api, self.clock, wait_expiry=False)
        self.assertEqual(events, ["denied", "revoked"])
        self.api.calls.clear()
        self.api.deny_unapproved = lambda session: False
        with self.assertRaises(self.module.AcceptanceError):
            self.module.acceptance(self.api, self.api, self.clock, wait_expiry=False)
        self.assertEqual(self.api.calls, [])

    def test_adapter_sends_unapproved_issuance_and_requires_exact_acl_denial(self):
        from scripts.test.scenarios.openbao_issuance import PodAPI

        adapter = PodAPI(None, None)
        calls = []
        for status in (403, 200, 400, 404, 500):
            def request(method, path, **kwargs):
                calls.append((method, path, kwargs))
                return status, {"data": {"service_account_token": "synthetic-unexpected-token"}}
            adapter.request = request
            if status == 403:
                self.assertIs(adapter.deny_unapproved("synthetic-session"), True)
            else:
                with self.assertRaises(self.module.AcceptanceError):
                    adapter.deny_unapproved("synthetic-session")
        self.assertEqual(len(calls), 5)
        for method, path, kwargs in calls:
            self.assertEqual((method, path), ("POST", "/v1/kubernetes/creds/openbao-unapproved"))
            self.assertEqual(kwargs, {"target": "bao", "token": "synthetic-session",
                                     "payload": {"kubernetes_namespace": "openbao-acceptance", "ttl": "600s"}})

    def test_real_identity_canary_and_elapsed_expiry_without_token_output(self):
        result = self.module.acceptance(self.api, self.api, self.clock)
        self.assertEqual(result["identity"], self.api.identity)
        self.assertEqual(result["expires_at"], 1600)
        self.assertGreater(self.clock.now, 1600)
        self.assertNotIn(self.api.token, json.dumps(result))
        self.assertTrue(
            any(p.endswith("/configmaps/openbao-protected") for _, p, _, _ in self.api.calls)
        )

    def test_wrong_claims_and_authenticated_identity_are_rejected(self):
        for changes in (
            {"sub": "wrong"},
            {"aud": ["wrong"]},
            {"exp": 4600},
            {"iat": 900},
            {"exp": True},
        ):
            with self.subTest(changes=changes):
                self.api.token = jwt(**changes)
                with self.assertRaises(self.module.AcceptanceError):
                    self.module.acceptance(self.api, self.api, self.clock)
        self.api.token = jwt()
        self.api.identity = "system:anonymous"
        with self.assertRaises(self.module.AcceptanceError):
            self.module.acceptance(self.api, self.api, self.clock)

    def test_post_expiry_success_or_forbidden_is_not_expiration(self):
        for status in (200, 403, 500):
            self.clock.now = 1000
            self.api.expired_status = status
            with self.assertRaises(self.module.AcceptanceError):
                self.module.acceptance(self.api, self.api, self.clock)

    def test_exact_positive_and_negative_tokenrequest_calls(self):
        result = self.module.issuer_boundary(self.api, self.clock, "synthetic-run")
        self.assertEqual(result["status"], "pass")
        paths = [p for _, p, _, _ in self.api.calls]
        self.assertIn(
            "/api/v1/namespaces/openbao-acceptance/serviceaccounts/openbao-unapproved/token", paths
        )
        self.assertIn(
            "/api/v1/namespaces/openbao-acceptance-wrong/serviceaccounts/openbao-issued-reader/token",
            paths,
        )
        for _, path, payload, _ in self.api.calls:
            if path.endswith("/roles"):
                self.assertEqual(payload["rules"], [])
            if path.endswith("/rolebindings"):
                self.assertEqual(payload["subjects"], [])

    def test_denial_requires_forbidden_and_allowed_requires_success(self):
        for status in (200, 401, 404, 429, 500, TimeoutError("credential-marker")):
            with self.subTest(status=status):
                self.api.denied_status = status
                with self.assertRaises(self.module.AcceptanceError):
                    self.module.issuer_boundary(self.api, self.clock, "synthetic-run")
        self.api.denied_status = 403
        for status in (401, 403):
            self.api.allowed_status = status
            with self.assertRaises(self.module.AcceptanceError):
                self.module.issuer_boundary(self.api, self.clock, "synthetic-run")


class AdapterTests(unittest.TestCase):
    def test_pod_has_only_projected_identity_no_seal_or_data(self):
        from scripts.test.scenarios import openbao_issuance as live

        for issuer in (True, False):
            pod = live.pod_document("synthetic-run", issuer)
            spec = pod["spec"]
            self.assertIs(spec["automountServiceAccountToken"], False)
            self.assertEqual(
                spec["serviceAccountName"], "openbao" if issuer else "openbao-acceptance"
            )
            self.assertEqual(len(spec["volumes"]), 1)
            self.assertIn("projected", spec["volumes"][0])
            self.assertLessEqual(spec["activeDeadlineSeconds"], 1800)
            self.assertFalse(spec.get("hostNetwork", False))

    def test_bridge_has_verified_tls_discards_errors_and_never_follows_redirects(self):
        import io
        from unittest.mock import patch

        from scripts.test.scenarios import openbao_issuance as live

        output = io.StringIO()
        response = type(
            "Response", (), {"status": 307, "read": lambda self, n: b"credential-marker"}
        )()
        context = type("Context", (), {"verify_mode": 2, "check_hostname": True})()
        observed = []
        connection = type(
            "Connection",
            (),
            {
                "request": lambda *a, **k: observed.append((a, k)),
                "getresponse": lambda self: response,
                "close": lambda self: None,
            },
        )()
        args = {"target": "bao", "method": "GET", "path": "/v1/sys/health"}
        with (
            patch("sys.stdin", io.StringIO(json.dumps(args))),
            patch("sys.stdout", output),
            patch("ssl.create_default_context", return_value=context),
            patch("http.client.HTTPSConnection", return_value=connection) as transport,
        ):
            exec(compile(live.BRIDGE, "<synthetic-bridge>", "exec"), {})  # noqa: S102 -- Execute repository bridge with synthetic transport only.
        self.assertEqual(json.loads(output.getvalue()), {"status": 307, "body": {}})
        self.assertNotIn("credential-marker", output.getvalue())
        self.assertIs(transport.call_args.kwargs["context"], context)
        self.assertEqual(len(observed), 1)


class OwnershipTests(unittest.TestCase):
    def test_pod_spec_change_blocks_credential_transport(self):
        import copy
        from pathlib import Path

        from scripts.test.scenarios import openbao_issuance as live

        scope = live.Scope(Path("/synthetic/operator"), "synthetic-run")
        pod = live.pod_document("synthetic-run", False)
        pod["metadata"]["uid"] = "synthetic-pod"
        altered = copy.deepcopy(pod)
        altered["spec"]["containers"][0]["image"] = "unexpected-image"
        scope.get = lambda _: altered
        with self.assertRaises(live.issuance.AcceptanceError):
            scope.assert_owned(pod)

    def test_cleanup_uses_exact_uid_and_refuses_foreign_ownership(self):
        from pathlib import Path

        from scripts.test.scenarios import openbao_issuance as live

        scope = live.Scope(Path("/synthetic/operator"), "synthetic-run")
        pod = live.pod_document("synthetic-run", False)
        pod["metadata"].update(uid="synthetic-pod", resourceVersion="42")
        scope.objects = [pod]
        scope.check = lambda: None
        calls = []
        values = iter([pod, None])
        scope.get = lambda _: next(values)
        scope.command = lambda *args, **kwargs: calls.append((args, kwargs))
        scope.cleanup()
        body = json.loads(calls[0][1]["input_bytes"])
        self.assertEqual(body["preconditions"], {"uid": "synthetic-pod", "resourceVersion": "42"})
        scope.objects = [pod]
        pod["metadata"]["annotations"][live.OWNER] = "foreign-run"
        scope.get = lambda _: pod
        with self.assertRaises(live.issuance.AcceptanceError):
            scope.cleanup()
        self.assertEqual(len(calls), 1)

    def test_transport_keeps_tokens_off_argv(self):
        from pathlib import Path

        from scripts.test.scenarios import openbao_issuance as live

        scope = live.Scope(Path("/synthetic/operator"), "synthetic-run")
        pod = live.pod_document("synthetic-run", False)
        scope.check = lambda: None
        scope.assert_owned = lambda _: pod
        calls = []

        def command(*args, **kwargs):
            calls.append((args, kwargs))
            return b'{"status":403,"body":{}}'

        scope.command = command
        live.PodAPI(scope, pod).request("GET", "/synthetic", token="synthetic-bearer-marker")
        self.assertNotIn("synthetic-bearer-marker", repr(calls[0][0]))
        self.assertIn(b"synthetic-bearer-marker", calls[0][1]["input_bytes"])


class ExpiryReviewTests(unittest.TestCase):
    def test_accepts_rejection_after_api_leeway_and_bounded_clock_skew(self):
        from scripts.openbao import issuance

        for extra_seconds in (60, 90):
            with self.subTest(extra_seconds=extra_seconds):
                clock = Clock()
                api = API(clock)
                original = api.request
                observed = []

                def request(
                    method,
                    path,
                    *,
                    clock=clock,
                    observed=observed,
                    extra_seconds=extra_seconds,
                    original=original,
                    **kwargs,
                ):
                    if path.endswith("/configmaps/openbao-canary") and clock.now > 1600:
                        observed.append(clock.now)
                        return (
                            (200, {"data": {"marker": "synthetic-openbao-reader-canary"}})
                            if clock.now <= 1600 + extra_seconds
                            else (401, {})
                        )
                    return original(method, path, **kwargs)

                api.request = request
                self.assertEqual(issuance.acceptance(api, api, clock)["status"], "pass")
                self.assertTrue(any(value <= 1600 + extra_seconds for value in observed))
                self.assertGreater(clock.now, 1600 + extra_seconds)
                self.assertLessEqual(clock.now, 1700)

    def test_session_is_revoked_once_before_its_own_ttl_expires(self):
        from scripts.openbao import issuance

        clock, revoked = Clock(), []
        api = API(clock)

        def revoke(session):
            if clock.now >= 1600:
                raise issuance.AcceptanceError()
            revoked.append(clock.now)

        api.revoke = revoke
        result = issuance.acceptance(api, api, clock)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(revoked, [1000])
        self.assertGreater(clock.now, 1600)

    def test_permanent_success_fails_within_expiry_leeway_skew_bound(self):
        from scripts.openbao import issuance

        clock = Clock()
        api = API(clock)
        api.expired_status = 200
        with self.assertRaises(issuance.AcceptanceError):
            issuance.acceptance(api, api, clock)
        self.assertLessEqual(clock.now, 1700)


class AdmissionReviewTests(unittest.TestCase):
    def test_additive_admission_changes_cannot_extend_probe_authority(self):
        import copy
        from pathlib import Path

        from scripts.test.scenarios import openbao_issuance as live

        mutations = {
            "secret-volume": lambda p: p["volumes"].append(
                {"name": "seal", "secret": {"secretName": "openbao-seal"}}
            ),
            "host-volume": lambda p: p["volumes"].append(
                {"name": "host", "hostPath": {"path": "/"}}
            ),
            "extra-mount": lambda p: p["containers"][0]["volumeMounts"].append(
                {"name": "identity", "mountPath": "/another"}
            ),
            "sidecar": lambda p: p["containers"].append(
                {"name": "extra", "image": "synthetic-sidecar"}
            ),
            "init": lambda p: p.update(
                initContainers=[{"name": "extra", "image": "synthetic-init"}]
            ),
            "ephemeral": lambda p: p.update(
                ephemeralContainers=[{"name": "extra", "image": "synthetic-debug"}]
            ),
            "host-network": lambda p: p.update(hostNetwork=True),
            "host-pid": lambda p: p.update(hostPID=True),
            "host-ipc": lambda p: p.update(hostIPC=True),
            "shared-processes": lambda p: p.update(shareProcessNamespace=True),
            "privileged": lambda p: p["containers"][0]["securityContext"].update(privileged=True),
            "extra-capability": lambda p: p["containers"][0]["securityContext"][
                "capabilities"
            ].update(add=["SYS_ADMIN"]),
            "secret-env": lambda p: p["containers"][0].update(
                envFrom=[{"secretRef": {"name": "injected"}}]
            ),
            "token-projection": lambda p: p["volumes"][0]["projected"]["sources"].append(
                {"serviceAccountToken": {"path": "other"}}
            ),
        }
        for issuer in (True, False):
            for name, mutate in mutations.items():
                with self.subTest(issuer=issuer, mutation=name):
                    scope = live.Scope(Path("/synthetic/operator"), "synthetic-run")
                    pod = live.pod_document("synthetic-run", issuer)
                    pod["metadata"]["uid"] = "synthetic-pod"
                    actual = copy.deepcopy(pod)
                    mutate(actual["spec"])
                    scope.get = lambda _, actual=actual: actual
                    with self.assertRaises(live.issuance.AcceptanceError):
                        scope.assert_owned(pod)

    def test_necessary_kubernetes_defaults_do_not_break_exact_probe_boundary(self):
        import copy
        from pathlib import Path

        from scripts.test.scenarios import openbao_issuance as live

        scope = live.Scope(Path("/synthetic/operator"), "synthetic-run")
        pod = live.pod_document("synthetic-run", True)
        pod["metadata"]["uid"] = "synthetic-pod"
        actual = copy.deepcopy(pod)
        actual["spec"].update(
            nodeName="synthetic-node",
            dnsPolicy="ClusterFirst",
            schedulerName="default-scheduler",
            terminationGracePeriodSeconds=30,
            serviceAccount="openbao",
            priority=0,
            preemptionPolicy="PreemptLowerPriority",
            tolerations=[
                {
                    "key": "node.kubernetes.io/not-ready",
                    "operator": "Exists",
                    "effect": "NoExecute",
                    "tolerationSeconds": 300,
                },
                {
                    "key": "node.kubernetes.io/unreachable",
                    "operator": "Exists",
                    "effect": "NoExecute",
                    "tolerationSeconds": 300,
                },
            ],
        )
        actual["spec"]["volumes"][0]["projected"]["defaultMode"] = 420
        actual["spec"]["containers"][0].update(
            imagePullPolicy="IfNotPresent",
            terminationMessagePath="/dev/termination-log",
            terminationMessagePolicy="File",
        )
        scope.get = lambda _: actual
        self.assertEqual(scope.assert_owned(pod)["metadata"]["uid"], "synthetic-pod")


class RevokeAndCreationReviewTests(unittest.TestCase):
    def test_ambiguous_early_revoke_fails_once_before_waiting(self):
        from scripts.openbao import issuance

        clock, attempts = Clock(), []
        api = API(clock)

        def revoke(session):
            attempts.append(clock.now)
            raise TimeoutError("synthetic-private-marker")

        api.revoke = revoke
        with self.assertRaises(issuance.AcceptanceError) as failure:
            issuance.acceptance(api, api, clock)
        self.assertEqual(attempts, [1000])
        self.assertEqual(clock.now, 1000)
        self.assertNotIn("synthetic-private-marker", str(failure.exception))

    def test_unsafe_admission_is_rejected_at_creation_with_owned_cleanup_record(self):
        import copy
        from pathlib import Path

        from scripts.test.scenarios import openbao_issuance as live

        scope = live.Scope(Path("/synthetic/operator"), "synthetic-run")
        requested = live.pod_document("synthetic-run", True)
        admitted = copy.deepcopy(requested)
        admitted["metadata"]["uid"] = "synthetic-pod"
        admitted["spec"]["volumes"].append(
            {"name": "extra", "secret": {"secretName": "synthetic"}}
        )
        scope.check = lambda: None
        scope.get = lambda _: None
        scope.command = lambda *args, **kwargs: json.dumps(admitted).encode()
        with self.assertRaises(live.issuance.AcceptanceError):
            scope.create(requested)
        self.assertEqual(scope.objects[0]["metadata"]["uid"], "synthetic-pod")
