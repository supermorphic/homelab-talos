import copy
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.openbao import bootstrap, guards
from scripts.openbao.client import AmbiguousWrite
from scripts.openbao.configuration import SafeError


class BootstrapClient:
    def __init__(self):
        self.calls = []
        self.states = [False, False, False]
        self.fail_after_initialization_commits = False
        self.deleted_pvcs = []
        self.initialized_peers = []
        self.joined = True
        self.login_ok = True
        self.revoke_ok = True
        self.revoked = False

    def states_now(self):
        return [{"initialized": value} for value in self.states]

    def post(self, path, payload, token=None):
        self.calls.append(("POST", path))
        if path == "sys/init":
            self.states[0] = True
            self.initialized_peers.append("openbao-0")
            if self.fail_after_initialization_commits:
                raise AmbiguousWrite("ambiguous-write")
            return {"root_token": "synthetic-root", "recovery_keys_base64": ["synthetic-share"]}
        if path.endswith("/login/openbao-operator"):
            if not self.login_ok:
                raise SafeError("authentication-failed")
            return {
                "auth": {"client_token": "synthetic-operator", "policies": ["openbao-operator"]}
            }
        if path == "auth/token/revoke-self":
            if not self.revoke_ok:
                raise AmbiguousWrite("ambiguous-write")
            self.revoked = True
        return {}

    def read(self, path, token=None):
        self.calls.append(("GET", path))
        if path == "auth/token/lookup-self":
            if token == "synthetic-root" and self.revoked:
                raise SafeError("read-denied")
            return {"data": {"policies": ["openbao-operator"]}}
        return {"data": {}}

    def wait_quorum(self, token):
        if not self.joined:
            raise SafeError("timeout")

    def prepare(self, approved):
        self.calls.append(("prepare", "owned-units"))
        return copy.deepcopy(approved)

    def configure_audit(self, token):
        self.calls.append(("audit", "verified"))


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.client = BootstrapClient()
        self.target = {
            "source_revision": "a" * 40,
            "package_digest": "b" * 64,
            "cluster_uid": "synthetic-cluster",
            "namespace_uid": "synthetic-ns",
            "statefulset_uid": "synthetic-sts",
            "pvc_uids": ["p0", "p1", "p2"],
            "pod_uids": {"openbao-0": "synthetic-pod"},
            "recipient": "synthetic-recipient",
            "seal_key_id": "1",
        }
        self.journal = []
        self.inputs = {
            "client": self.client,
            "kubeconfig": Path("/synthetic"),
            "recovery_directory": Path("/synthetic-recovery"),
            "recipient": "synthetic-recipient",
            "journal": self.journal,
            "confirm": guards.confirmation("initialize", "a" * 40, guards.digest(self.target)),
        }
        for name, value in [("freeze_target", self.target), ("assert_mutation_allowed", None)]:
            self.mock(name, value, "guards")
        self.mock("preflight_recovery", None, "secrets")
        self.mock("write_recovery", Path("/synthetic-retained"), "secrets")
        self.mock("install_initial", None, "apply")

    def mock(self, name, value, module):
        p = patch(f"scripts.openbao.{module}.{name}", return_value=value)
        mock = p.start()
        self.addCleanup(p.stop)
        return mock

    def test_initialization_response_loss_never_retries_or_deletes(self):
        self.client.fail_after_initialization_commits = True
        with self.assertRaises(AmbiguousWrite):
            bootstrap.run("initialize", **self.inputs)
        self.assertEqual(self.client.calls.count(("POST", "sys/init")), 1)
        self.assertEqual(self.client.deleted_pvcs, [])
        self.assertEqual(self.client.initialized_peers, ["openbao-0"])

    def test_unusable_init_http_responses_are_ambiguous_without_retry_or_storage_deletion(self):
        import http.client

        from scripts.openbao.client import BaoClient
        from scripts.test.core.test_openbao_client import Response

        class Truncated(Response):
            def read(self, size=-1):
                raise http.client.IncompleteRead(b"synthetic", 100)

        for response in (
            Response(b"{", url="https://openbao.example/v1/sys/init"),
            Response(b"x" * 33, url="https://openbao.example/v1/sys/init"),
            Truncated(url="https://openbao.example/v1/sys/init"),
        ):
            self.client.calls.clear()
            self.client.states = [False, False, False]
            self.client.initialized_peers.clear()

            def opener(request, timeout, response=response):
                self.client.calls.append(("POST", "sys/init"))
                self.client.states[0] = True
                self.client.initialized_peers.append("openbao-0")
                return response

            transport = BaoClient("https://openbao.example", max_bytes=32, opener=opener)
            with (
                patch.object(self.client, "post", side_effect=transport.post),
                self.assertRaises(AmbiguousWrite) as caught,
            ):
                bootstrap.run("initialize", **self.inputs)
            self.assertEqual(str(caught.exception), "ambiguous-write")
            self.assertEqual(self.client.calls, [("POST", "sys/init")])
            self.assertEqual(self.client.deleted_pvcs, [])
            self.assertEqual(self.client.initialized_peers, ["openbao-0"])

    def test_initialized_mixed_malformed_and_inaccessible_refuse_all_writes(self):
        for states in (
            [True] * 3,
            [False, True, False],
            [False, None, False],
            [False, "false", False],
        ):
            self.client.states = states
            with self.subTest(states=states), self.assertRaises(SafeError):
                bootstrap.run("initialize", **self.inputs)
            self.assertEqual(self.client.calls, [])
        with (
            patch.object(self.client, "states_now", side_effect=SafeError("timeout")),
            self.assertRaises(SafeError),
        ):
            bootstrap.run("initialize", **self.inputs)
        self.assertEqual(self.client.calls, [])

    def test_missing_confirmation_and_changed_identity_refuse(self):
        self.inputs["confirm"] = ""
        result = bootstrap.run("initialize", **self.inputs)
        self.assertEqual(result["status"], "confirmation-required")
        self.assertEqual(self.client.calls, [])
        self.inputs["confirm"] = result["confirmation"]
        for field in (
            "namespace_uid",
            "statefulset_uid",
            "pvc_uids",
            "source_revision",
            "recipient",
        ):
            changed = copy.deepcopy(self.target)
            changed[field] = "changed"
            with (
                patch("scripts.openbao.guards.freeze_target", side_effect=[self.target, changed]),
                self.subTest(field=field),
                self.assertRaises(SafeError),
            ):
                bootstrap.run("initialize", **self.inputs)
            self.assertEqual(self.client.calls, [])

    def test_encrypted_retention_precedes_configuration_and_root_revocation(self):
        result = bootstrap.run("initialize", **self.inputs)
        self.assertEqual(result["status"], "pass")
        self.assertLess(
            self.journal.index("recovery-retained"), self.journal.index("configuration-written")
        )
        self.assertLess(
            self.journal.index("operator-login-verified"), self.journal.index("root-revoked")
        )
        self.assertTrue(self.client.revoked)

    def test_partial_failures_cannot_report_success_or_retry_initialization(self):
        for failure in ("recovery", "joined", "login_ok", "revoke_ok"):
            self.setUp()
            if failure != "recovery":
                setattr(self.client, failure, False)
            recovery = (
                patch("scripts.openbao.secrets.write_recovery", side_effect=SafeError())
                if failure == "recovery"
                else patch(
                    "scripts.openbao.secrets.write_recovery",
                    return_value=Path("/synthetic-retained"),
                )
            )
            with recovery, self.subTest(failure=failure), self.assertRaises(SafeError):
                bootstrap.run("initialize", **self.inputs)
            self.assertEqual(self.client.calls.count(("POST", "sys/init")), 1)
            with self.assertRaises(SafeError):
                bootstrap.run("initialize", **self.inputs)
            self.assertEqual(self.client.calls.count(("POST", "sys/init")), 1)

    def test_prepare_only_resumes_owned_units_after_confirmation(self):
        self.inputs["confirm"] = guards.confirmation("prepare", "a" * 40, "b" * 64)
        result = bootstrap.run("prepare", **self.inputs)
        self.assertEqual(result["status"], "prepared")
        self.assertEqual(self.client.calls, [("prepare", "owned-units")])

    def test_prepare_returns_only_local_nonsecret_observed_target_summary(self):
        self.inputs["confirm"] = guards.confirmation("prepare", "a" * 40, "b" * 64)
        observed = {**self.target, "namespace_uid": "actually-prepared-namespace",
                    "password": "synthetic-private", "recovery_directory": "/private/path"}
        self.client.prepare = lambda target: observed
        result = bootstrap.run("prepare", **self.inputs)
        self.assertEqual(result["target"], {key: observed[key] for key in (
            "source_revision", "cluster_uid", "namespace_uid", "statefulset_uid",
            "pod_uids", "pvc_uids")})
        self.assertNotIn("synthetic-private", str(result))
        self.assertNotIn("/private/path", str(result))


class PinnedReadbackTest(unittest.TestCase):
    def test_bootstrap_reaches_root_revocation_with_complete_jwt_readback(self):
        from scripts.test.core.test_openbao_apply import StateClient

        class Client(StateClient, BootstrapClient):
            def __init__(self):
                StateClient.__init__(self)
                BootstrapClient.__init__(self)

            def post(self, path, payload, token=None):
                if path in {
                    "sys/init",
                    "auth/token/revoke-self",
                    "auth/homelab-userpass/login/openbao-operator",
                }:
                    return BootstrapClient.post(self, path, payload, token)
                return StateClient.post(self, path, payload, token)

            def set_token(self, token):
                pass

        client = Client()
        client.state[("issuance-role", "openbao-acceptance")]["token_max_ttl"] = 900
        client.state[("jwt-config", "homelab-jwt")] = None
        target = {
            "source_revision": "a" * 40,
            "package_digest": "b" * 64,
            "recipient": "synthetic",
        }
        journal = []
        with (
            patch("scripts.openbao.guards.freeze_target", return_value=target),
            patch("scripts.openbao.guards.assert_mutation_allowed"),
            patch("scripts.openbao.secrets.preflight_recovery"),
            patch("scripts.openbao.secrets.write_recovery"),
        ):
            result = bootstrap.run(
                "initialize",
                client=client,
                kubeconfig=Path("/synthetic"),
                recovery_directory=Path("/synthetic"),
                recipient="synthetic",
                journal=journal,
                confirm=guards.confirmation("initialize", "a" * 40, guards.digest(target)),
            )
        self.assertEqual(result["status"], "pass")
        self.assertIn("root-revoked", journal)
        self.assertEqual(
            client.state[("issuance-role", "openbao-acceptance")]["token_max_ttl"], 600
        )


class GuardTest(unittest.TestCase):
    def test_source_refuses_dirty_or_unpublished_candidate(self):
        with (
            patch("scripts.openbao.guards.command", return_value=b" M synthetic"),
            self.assertRaises(SafeError),
        ):
            guards.source_revision()
        with (
            patch(
                "scripts.openbao.guards.command",
                side_effect=[b"", b"a" * 40, b"b" * 40 + b" refs/heads/main"],
            ),
            self.assertRaises(SafeError),
        ):
            guards.source_revision()

    def test_operator_cli_never_falls_back_to_ambient_kubeconfig(self):
        import contextlib
        import io

        from scripts.openbao.operator import main

        output = io.StringIO()
        with (
            patch.dict(
                "os.environ", {"KUBECONFIG": "/synthetic-admin", "OPENBAO_OPERATOR_KUBECONFIG": ""}
            ),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(main(["operator", "initialize"]), 1)
        self.assertNotIn("synthetic-admin", output.getvalue())

    def test_private_prompt_refuses_echo_fallback(self):
        import getpass
        import warnings

        from scripts.openbao.operator import private_prompt

        def fallback(*args, **kwargs):
            warnings.warn("synthetic echo fallback", getpass.GetPassWarning, stacklevel=2)
            return "synthetic-password"

        with (
            patch("scripts.openbao.operator.getpass.getpass", side_effect=fallback),
            self.assertRaises(SafeError),
        ):
            private_prompt("synthetic prompt")

    def test_live_pod_comparison_accepts_generated_claim_but_rejects_changed_seal(self):
        expected = {
            "containers": [{"name": "openbao", "image": "pinned"}],
            "volumes": [{"name": "seal", "secret": {"secretName": "openbao-seal"}}],
        }
        actual = {
            "containers": [
                {"name": "openbao", "image": "pinned", "imagePullPolicy": "IfNotPresent"}
            ],
            "volumes": [
                {"name": "data", "persistentVolumeClaim": {"claimName": "data-openbao-0"}},
                {"name": "seal", "secret": {"secretName": "openbao-seal", "defaultMode": 288}},
            ],
        }
        self.assertTrue(guards.contains_source(expected, actual))
        actual["volumes"][1]["secret"]["secretName"] = "unrelated"
        self.assertFalse(guards.contains_source(expected, actual))

    def test_recovery_failure_never_reaches_configuration(self):
        fixture = BootstrapTest("test_initialization_response_loss_never_retries_or_deletes")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        with (
            patch("scripts.openbao.secrets.write_recovery", side_effect=SafeError()),
            patch("scripts.openbao.apply.install_initial") as install,
            self.assertRaises(SafeError),
        ):
            bootstrap.run("initialize", **fixture.inputs)
        install.assert_not_called()


class PrepareRaceTest(unittest.TestCase):
    def test_changed_source_or_unit_during_prerequisite_wait_blocks_server_resume(self):
        import json

        import yaml

        from scripts.openbao.operator import OperatorClient

        for changed in ("revision", "artifact", "path", "sourceRef", "uid"):
            with self.subTest(changed=changed):
                units = {
                    u["metadata"]["name"]: u
                    for u in yaml.safe_load_all((guards.PACKAGE / "ks.yaml").read_text())
                }
                for name, unit in units.items():
                    unit["metadata"].update(uid="synthetic-" + name, resourceVersion="1")
                approved = {
                    "source_revision": "a" * 40,
                    "package_digest": "b" * 64,
                    "cluster_uid": "synthetic-cluster",
                    "flux_unit_uids": {name: u["metadata"]["uid"] for name, u in units.items()},
                }
                live = {"revision": "a" * 40, "artifact": "a" * 40}
                resumed = []

                def kube(config, *args, live=live, units=units):
                    if "gitrepository" in args:
                        return {
                            "status": {"artifact": {"revision": "main@sha1:" + live["artifact"]}}
                        }
                    if "cluster-apps" in args:
                        return {"status": {"lastAppliedRevision": "main@sha1:" + live["artifact"]}}
                    if "kube-system" in args:
                        return {"metadata": {"uid": "synthetic-cluster"}}
                    return copy.deepcopy(units[args[args.index("kustomization") + 1]])

                def command(
                    argv, live=live, units=units, changed=changed, resumed=resumed, **kwargs
                ):
                    if argv[0] == "git":
                        if "status" in argv:
                            return b""
                        return (
                            live["revision"] + (" refs/heads/main" if "ls-remote" in argv else "")
                        ).encode()
                    if argv[0] == "flux":
                        if changed in {"revision", "artifact"}:
                            live[changed] = "c" * 40
                        elif changed == "uid":
                            units["openbao"]["metadata"]["uid"] = "changed"
                        else:
                            units["openbao"]["spec"][changed] = "unrelated"
                        return b""
                    operations = json.loads(argv[argv.index("-p") + 1])
                    if operations[-1]["value"] is False:
                        resumed.append(argv[argv.index("kustomization") + 1])
                    return b""

                with (
                    patch("scripts.openbao.guards.command", side_effect=command),
                    patch("scripts.openbao.guards.kube", side_effect=kube),
                    patch(
                        "scripts.openbao.guards.package_digest", return_value="b" * 64, create=True
                    ),
                    patch("scripts.openbao.guards.assert_mutation_allowed"),
                    patch("scripts.openbao.guards.freeze_target", return_value=approved),
                    patch("scripts.openbao.bootstrap._uninitialized"),
                    self.assertRaises(SafeError),
                ):
                    OperatorClient(Path("/synthetic")).prepare(approved)
                self.assertEqual(resumed, ["openbao-prerequisites"])


if __name__ == "__main__":
    unittest.main()
