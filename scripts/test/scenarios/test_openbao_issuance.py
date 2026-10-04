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
        "aud": ["https://192.168.90.20:6443"],
        "iat": 1000,
        "exp": 1600,
    }
    claims.update(changes)
    return (
        "fixture."
        + base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
        + ".synthetic"
    )


BROKER_ACCOUNTS = [
    "homelab-observer",
    "homelab-diagnostic",
    "homelab-report-publisher",
    "homelab-campaign-coordinator",
    "homelab-test-runner",
    "homelab-test-flux-restart",
    "homelab-test-cilium-connectivity",
    "homelab-test-node-reschedule",
    "homelab-test-conformance",
    "homelab-test-openbao-issuance",
    "homelab-test-openbao-ha",
    "homelab-test-openbao-restore",
    "homelab-test-openbao-lifecycle"
]


class API:
    def __init__(self, clock):
        self.clock = clock
        self.token = jwt()
        self.identity = "system:serviceaccount:openbao-acceptance:openbao-issued-reader"
        self.allowed_status = 201
        self.denied_status = 403
        self.expired_status = 401
        self.calls = []
        self.broker_tokens = {}
        self.broker_identity_override = None
        self.broker_ttl = 600
        self.broker_status = 201

    def request(self, method, path, *, payload=None, token=None, headers=None):
        self.calls.append((method, path, payload, headers))
        prefix = "/api/v1/namespaces/kube-system/serviceaccounts/"
        if path.startswith(prefix) and path.endswith("/token"):
            account = path[len(prefix) : -len("/token")]
            if account in BROKER_ACCOUNTS:
                identity = "system:serviceaccount:kube-system:" + account
                issued_token = jwt(sub=identity, exp=1000 + self.broker_ttl)
                self.broker_tokens[issued_token] = identity
                return self.broker_status, {
                    "status": {
                        "token": issued_token,
                        "expirationTimestamp": "1970-01-01T00:26:40Z",
                    }
                }
        if path.endswith("selfsubjectreviews") and token in self.broker_tokens:
            return 201, {
                "status": {
                    "userInfo": {
                        "username": self.broker_identity_override or self.broker_tokens[token]
                    }
                }
            }
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
            def request(method, path, status=status, **kwargs):
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


    def test_issuer_proves_every_expanded_named_account_with_actual_api_identity(self):
        result = self.module.issuer_boundary(self.api, self.clock, "synthetic-run")
        actual = {
            path
            for method, path, _, _ in self.api.calls
            if method == "POST"
            and path.startswith("/api/v1/namespaces/kube-system/serviceaccounts/")
            and path.endswith("/token")
            and path.split("/")[-2] in BROKER_ACCOUNTS
        }
        self.assertEqual(
            actual,
            {
                f"/api/v1/namespaces/kube-system/serviceaccounts/{account}/token"
                for account in BROKER_ACCOUNTS
            },
        )
        self.assertEqual(set(result["agent_accounts"]), set(BROKER_ACCOUNTS))
        self.assertEqual(len(result["agent_accounts"]), 13)
        paths = {p for _, p, _, _ in self.api.calls}
        self.assertIn(
            "/api/v1/namespaces/kube-system/serviceaccounts/openbao-unapproved/token", paths
        )
        self.assertIn(
            "/api/v1/namespaces/openbao/serviceaccounts/homelab-test-runner/token", paths
        )
        self.assertNotIn("fixture.", json.dumps(result))
        for _, path, payload, _ in self.api.calls:
            if path.endswith("/token"):
                self.assertEqual(
                    payload["spec"],
                    {"audiences": ["https://192.168.90.20:6443"], "expirationSeconds": 600},
                )


    def test_expanded_issuer_claims_require_ten_minute_lifetime_and_actual_api_authentication(
        self,
    ):
        for status in (401, 403, 404, 429, 500):
            self.api.broker_status = status
            with self.subTest(status=status), self.assertRaises(self.module.AcceptanceError):
                self.module.issuer_boundary(self.api, self.clock, "synthetic-run")
        self.api.broker_status = 201
        self.api.broker_ttl = 1200
        with self.assertRaises(self.module.AcceptanceError):
            self.module.issuer_boundary(self.api, self.clock, "synthetic-run")
        self.api.broker_ttl = 600
        self.api.broker_identity_override = "system:anonymous"
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
            sources = spec["volumes"][0]["projected"]["sources"]
            if issuer:
                self.assertEqual(sources[0], {"secret": {"name": "openbao-issuer-token-v1",
                    "items": [{"key": "token", "path": "token"}]}})
            else:
                self.assertEqual(sources[0]["serviceAccountToken"]["expirationSeconds"], 600)

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

    def test_probe_failure_retains_only_request_position_and_safe_status(self):
        from pathlib import Path

        from scripts.test.scenarios import openbao_issuance as live

        scope = live.Scope(Path("/synthetic/operator"), "synthetic-run")
        pod = live.pod_document("synthetic-run", True)
        scope.check = lambda: None
        scope.assert_owned = lambda _: pod
        scope.command = lambda *args, **kwargs: b'{"status":403,"body":{"token":"private-marker"}}'
        live.PodAPI(scope, pod).request("POST", "/synthetic", token="private-marker")
        self.assertEqual(getattr(scope, "probe", None), {"request": 1, "phase": "response", "status": 403})
        self.assertNotIn("private-marker", json.dumps(getattr(scope, "probe", None)))

        def interrupted(*args, **kwargs):
            raise RuntimeError("private-marker")

        scope.command = interrupted
        with self.assertRaises(RuntimeError):
            live.PodAPI(scope, pod).request("POST", "/synthetic", token="private-marker")
        self.assertEqual(getattr(scope, "probe", None), {"request": 2, "phase": "transport"})
        self.assertNotIn("private-marker", json.dumps(getattr(scope, "probe", None)))


class ExpiryReviewTests(unittest.TestCase):
    def test_record_requires_new_issuance_after_real_expiry_without_server_restart(self):
        import contextlib
        import io
        from pathlib import Path
        from unittest.mock import Mock, patch

        from scripts.test.scenarios import openbao_issuance as live

        for second_issue_ok, processes_unchanged in ((True, True), (False, True), (True, False)):
            with self.subTest(second_issue_ok=second_issue_ok, processes_unchanged=processes_unchanged):
                clock = Clock()
                api = API(clock)
                issued_at = []
                real_request = api.request

                def issue(session, issued_at=issued_at, clock=clock, api=api, second_issue_ok=second_issue_ok):
                    issued_at.append(clock.time())
                    if len(issued_at) > 1 and not second_issue_ok:
                        raise live.issuance.AcceptanceError()
                    api.token = jwt(iat=int(clock.time()), exp=int(clock.time()) + 600)
                    return API.issue(api, session)

                def request(method, path, *, clock=clock, real_request=real_request, **kwargs):
                    if path.endswith("/configmaps/openbao-canary"):
                        claims = json.loads(base64.urlsafe_b64decode(kwargs["token"].split('.')[1] + '=='))
                        return ((401, {}) if clock.time() > claims["exp"] else
                                (200, {"data": {"marker": "synthetic-openbao-reader-canary"}}))
                    return real_request(method, path, **kwargs)

                api.issue, api.request = issue, request
                scope = Mock(run_id="synthetic-run", probe=None, objects=[])
                scope.get.side_effect = lambda doc: ({"metadata": {"uid": "cluster"}}
                    if doc["kind"] == "Namespace" else None)
                process = {"openbao-0": ("uid", 0, "start")}
                with (
                    patch.object(live, "run_scope", return_value=(scope, Path("/synthetic/result"))),
                    patch.object(live.guards, "source_revision", return_value="source"),
                    patch.object(live.guards, "require_deployed_revision"),
                    patch.dict("os.environ", {"OPENBAO_ISSUANCE_CONFIRM": "issuance:openbao:source:synthetic-run"}),
                    patch.object(live, "install_interrupt_handlers"),
                    patch.object(live, "diagnostic_boundary", return_value=True),
                    patch.object(live, "provision", return_value=(Mock(), api)),
                    patch.object(live.issuer_identity, "verify_identity"),
                    patch.object(live.issuer_identity, "server_processes", side_effect=[process,
                        process if processes_unchanged else {"openbao-0": ("uid", 1, "restart")}]),
                    patch.object(live.issuance, "issuer_boundary", return_value={"status": "pass"}),
                    patch.object(live, "time", clock),
                    patch.object(live, "atomic_write_json"),
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    self.assertEqual(live.main(), 0 if second_issue_ok and processes_unchanged else 1)
                self.assertEqual(len(issued_at), 2)
                self.assertGreater(issued_at[1] - issued_at[0], 600)
                scope.cleanup.assert_called_once()

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
        actual["spec"]["volumes"][0]["projected"].setdefault("defaultMode", 420)
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

class DiagnosticBoundaryTest(unittest.TestCase):
    def test_actual_identity_and_both_exec_transports_must_be_forbidden(self):
        from scripts.test.scenarios import openbao_issuance as adapter
        self.assertTrue(callable(getattr(adapter, 'diagnostic_boundary', None)))
        import subprocess
        from pathlib import Path
        from tempfile import TemporaryDirectory
        from unittest.mock import patch
        identity = 'system:serviceaccount:kube-system:homelab-diagnostic'
        whoami = subprocess.CompletedProcess([], 0, json.dumps({'status': {'userInfo': {'username': identity}}}), '')
        cluster = subprocess.CompletedProcess([], 0, json.dumps({'metadata': {'uid': 'expected-cluster'}}), '')
        wrong_cluster = subprocess.CompletedProcess([], 0, json.dumps({'metadata': {'uid': 'other-cluster'}}), '')
        def denied(verb, *, article='', namespace='openbao'):
            return subprocess.CompletedProcess([], 1, '',
                f'Error from server (Forbidden): User "{identity}" cannot {verb} resource "pods/exec" in API group "" in {article}namespace "{namespace}"')
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'config'; path.touch()
            for responses, succeeds in [([whoami, wrong_cluster], False), ([whoami, cluster, denied('create'), denied('get')], True),
                ([whoami, cluster, denied('create', article='the '), denied('get', article='the ')], True),
                ([whoami, cluster, denied('create', namespace='other')], False),
                ([whoami, cluster, subprocess.CompletedProcess([], 1, '', 'NotFound')], False),
                ([whoami, cluster, subprocess.CompletedProcess([], 1, '', 'Upgrade request required')], False),
                ([whoami, cluster, subprocess.CompletedProcess([], 0, '', '')], False)]:
                with patch.object(adapter, 'validate_scoped_kubeconfig') as validate, patch.object(adapter.subprocess, 'run', side_effect=responses) as run:
                    if succeeds:
                        try:
                            accepted = adapter.diagnostic_boundary(path, 'expected-cluster')
                        except adapter.issuance.AcceptanceError:
                            accepted = False
                        self.assertTrue(accepted)
                        calls = [call.args[0] for call in run.call_args_list]
                        self.assertTrue(all('--as' not in command for command in calls))
                        validate.assert_called_once_with(path, adapter.ROOT)
                        self.assertIn('create', calls[2]); self.assertIn('get', calls[3])
                        self.assertTrue(all('--context' not in command for command in calls))
                        self.assertTrue(all(str(path) in command for command in calls))
                    else:
                        with self.assertRaises(adapter.issuance.AcceptanceError):
                            adapter.diagnostic_boundary(path, 'expected-cluster')

    def test_invalid_config_is_rejected_before_any_api_request(self):
        from pathlib import Path
        from tempfile import TemporaryDirectory
        from unittest.mock import patch

        from scripts.openbao.configuration import SafeError
        from scripts.test.scenarios import openbao_issuance as adapter

        with TemporaryDirectory() as directory:
            path = Path(directory) / 'config'
            path.touch()
            with patch.object(adapter, 'validate_scoped_kubeconfig', side_effect=SafeError('invalid-source')), patch.object(adapter.subprocess, 'run') as run:
                with self.assertRaises(adapter.issuance.AcceptanceError):
                    adapter.diagnostic_boundary(path, 'expected-cluster')
                run.assert_not_called()
