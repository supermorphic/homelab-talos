import io
import json
import unittest
from contextlib import nullcontext, redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

from scripts.openbao import operator


class OperatorTunnelTest(unittest.TestCase):
    def test_workstation_can_list_with_explicit_operator_session(self):
        client = operator.OperatorClient(Path("/synthetic/kubeconfig"))
        peer = Mock()
        with patch.object(client, "peer", return_value=peer):
            client.read(
                "auth/homelab-approle/role/agent-workstation/secret-id",
                token="synthetic-operator",
                list_request=True,
            )
        peer.read.assert_called_once_with(
            "auth/homelab-approle/role/agent-workstation/secret-id",
            token="synthetic-operator",
            list_request=True,
        )

    def test_dead_tunnel_is_reopened_before_next_read(self):
        client = operator.OperatorClient(Path("/synthetic/kubeconfig"))
        dead, fresh = Mock(), Mock()
        dead.process.poll.return_value = 1
        fresh.process.poll.return_value = None
        old_api, new_api = Mock(), Mock()
        client.tunnels["openbao-0"] = dead
        client.clients["openbao-0"] = old_api
        with (patch("scripts.openbao.operator.Tunnel", return_value=fresh),
              patch("scripts.openbao.operator.BaoClient", return_value=new_api)):
            client.read("sys/seal-status")
            client.read("sys/leader")
        dead.close.assert_called_once()
        fresh.start.assert_called_once()
        old_api.read.assert_not_called()
        self.assertEqual(new_api.read.call_count, 2)

    def test_password_session_uses_leader_and_retires_scoped_token(self):
        self.assertTrue(hasattr(operator, "operator_password_session"))
        client = operator.OperatorClient(Path("/synthetic/kubeconfig"))
        peers = {name: Mock() for name in ("openbao-0", "openbao-1", "openbao-2")}
        for name, peer in peers.items():
            peer.read.side_effect = lambda path, token=None, name=name: (
                {"is_self": name == "openbao-1"} if path == "sys/leader"
                else {"data": {"policies": ["openbao-operator"]}}
            )
        peers["openbao-1"].post.return_value = {
            "auth": {"client_token": "synthetic-session", "policies": ["openbao-operator"]}
        }
        with (patch.object(client, "peer", side_effect=lambda name: peers[name]),
              patch.object(client, "wait_quorum") as quorum,
              patch("scripts.openbao.operator.bootstrap._revoke_checked") as revoke):
            with operator.operator_password_session(client, "synthetic-password") as token:
                self.assertEqual(token, "synthetic-session")
                self.assertEqual(client.active, "openbao-1")
            quorum.assert_called_once_with("synthetic-session")
            revoke.assert_called_once_with(client, "synthetic-session")
            peers["openbao-1"].post.assert_called_once_with(
                "auth/homelab-userpass/login/openbao-operator",
                {"password": "synthetic-password"}, token=None,
            )

    def test_password_session_rejects_broader_policy_and_revokes_token(self):
        self.assertTrue(hasattr(operator, "operator_password_session"))
        client = operator.OperatorClient(Path("/synthetic/kubeconfig"))
        peers = {name: Mock() for name in ("openbao-0", "openbao-1", "openbao-2")}
        for name, peer in peers.items():
            peer.read.return_value = {"is_self": name == "openbao-0"}
        peers["openbao-0"].post.return_value = {
            "auth": {"client_token": "synthetic-session", "policies": ["root"]}
        }
        with (patch.object(client, "peer", side_effect=lambda name: peers[name]),
              patch("scripts.openbao.operator.bootstrap._revoke_checked") as revoke,
              self.assertRaisesRegex(operator.SafeError, "authentication-failed"),
              operator.operator_password_session(client, "synthetic-password")):
            self.fail("unexpected authenticated session")
        revoke.assert_called_once_with(client, "synthetic-session")


class OperatorPromptTest(unittest.TestCase):
    def run_cli(self, phase, answer="exact-confirm", env_confirm=None, tty=True,
                auth_mode="token"):
        confirm_env = "OPENBAO_CONFIG_CONFIRM" if phase == "config-apply" else "OPENBAO_BOOTSTRAP_CONFIRM"
        env = {"OPENBAO_OPERATOR_KUBECONFIG": "/synthetic/kubeconfig"}
        if env_confirm is not None:
            env[confirm_env] = env_confirm
        if phase == "config-apply":
            env["OPENBAO_CONFIG_AUTH"] = auth_mode
        plan = {"status": "confirmation-required", "confirmation": "exact-confirm", "changes": []}
        output = io.StringIO()
        path = {"config-apply": "apply.run", "finalize": "bootstrap.finalize",
                "restart-staged": "restart.run"}[phase]
        with (
            patch.dict("os.environ", env, clear=True),
            patch("scripts.openbao.operator.Path.is_file", return_value=True),
            patch("scripts.openbao.operator.guards.freeze_target"),
            patch("scripts.openbao.operator.OperatorClient"),
            patch("scripts.openbao.operator.operator_password_session",
                  return_value=nullcontext("synthetic-session"), create=True) as session,
            patch("scripts.openbao.operator.private_prompt", side_effect=["synthetic-root", "synthetic-password"]) as private,
            patch("scripts.openbao.operator.sys.stdin.isatty", return_value=tty),
            patch("builtins.input", return_value=answer) as confirmation,
            patch("scripts.openbao.operator." + path, side_effect=[plan, {"status": "pass"}]) as run,
            patch("scripts.openbao.operator.lease", return_value=nullcontext()) as lease,
            redirect_stdout(output),
        ):
            status = operator.main(["operator", phase])
        self.assertNotIn("synthetic-root", output.getvalue())
        self.assertNotIn("synthetic-password", output.getvalue())
        return status, run, lease, private, confirmation, output.getvalue(), session

    def test_config_apply_confirms_in_same_terminal_run(self):
        status, run, lease, _, confirm, output, _ = self.run_cli("config-apply")
        self.assertEqual(status, 0)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.kwargs["confirm"], "exact-confirm")
        lease.assert_called_once()
        confirm.assert_called_once()
        self.assertEqual(json.loads(output.splitlines()[0])["status"], "confirmation-required")

    def test_empty_confirmation_and_nonterminal_stay_read_only(self):
        for env, tty in (("", True), (None, False), ("wrong", True)):
            with self.subTest(env=env, tty=tty):
                status, run, lease, _, confirm, _, _ = self.run_cli("config-apply", env_confirm=env, tty=tty)
                self.assertEqual(status, 2)
                self.assertEqual(run.call_count, 1)
                lease.assert_not_called()
                confirm.assert_not_called()

    def test_wrong_interactive_confirmation_stops_before_lease(self):
        status, run, lease, *_ = self.run_cli("config-apply", answer="wrong")
        self.assertEqual(status, 2)
        self.assertEqual(run.call_count, 1)
        lease.assert_not_called()

    def test_config_apply_password_mode_uses_private_login_token(self):
        status, run, lease, private, _, output, session = self.run_cli(
            "config-apply", auth_mode="userpass")
        self.assertEqual(status, 0)
        self.assertEqual(private.call_count, 1)
        session.assert_called_once()
        self.assertEqual(session.call_args.args[1], "synthetic-root")
        self.assertEqual(run.call_args.kwargs["token"], "synthetic-session")
        self.assertNotIn("synthetic-session", output)
        lease.assert_called_once()

    def test_finalize_prompts_for_root_and_password_then_calls_only_finalize(self):
        status, run, lease, private, *_ = self.run_cli("finalize")
        self.assertEqual(status, 0)
        self.assertEqual(private.call_count, 2)
        self.assertEqual(run.call_args.kwargs["password"], "synthetic-password")
        self.assertEqual(run.call_args.kwargs["token"], "synthetic-root")
        lease.assert_called_once()

    def test_staged_restart_requires_confirmation_and_only_prompts_for_token(self):
        status, run, lease, private, *_ = self.run_cli("restart-staged")
        self.assertEqual(status, 0)
        self.assertEqual(private.call_count, 1)
        self.assertEqual(run.call_args.kwargs["confirm"], "exact-confirm")
        lease.assert_called_once()


if __name__ == "__main__":
    unittest.main()
