import io
import json
import unittest
from contextlib import nullcontext, redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

from scripts.openbao import operator


class OperatorTunnelTest(unittest.TestCase):
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


class OperatorPromptTest(unittest.TestCase):
    def run_cli(self, phase, answer="exact-confirm", env_confirm=None, tty=True):
        confirm_env = "OPENBAO_CONFIG_CONFIRM" if phase == "config-apply" else "OPENBAO_BOOTSTRAP_CONFIRM"
        env = {"OPENBAO_OPERATOR_KUBECONFIG": "/synthetic/kubeconfig"}
        if env_confirm is not None:
            env[confirm_env] = env_confirm
        plan = {"status": "confirmation-required", "confirmation": "exact-confirm", "changes": []}
        output = io.StringIO()
        path = {"config-apply": "apply.run", "finalize": "bootstrap.finalize",
                "restart-staged": "restart.run"}[phase]
        with (
            patch.dict("os.environ", env, clear=True),
            patch("scripts.openbao.operator.Path.is_file", return_value=True),
            patch("scripts.openbao.operator.guards.freeze_target"),
            patch("scripts.openbao.operator.OperatorClient"),
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
        return status, run, lease, private, confirmation, output.getvalue()

    def test_config_apply_confirms_in_same_terminal_run(self):
        status, run, lease, private, confirm, output = self.run_cli("config-apply")
        self.assertEqual(status, 0)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.kwargs["confirm"], "exact-confirm")
        lease.assert_called_once()
        confirm.assert_called_once()
        self.assertEqual(json.loads(output.splitlines()[0])["status"], "confirmation-required")

    def test_empty_confirmation_and_nonterminal_stay_read_only(self):
        for env, tty in (("", True), (None, False), ("wrong", True)):
            with self.subTest(env=env, tty=tty):
                status, run, lease, private, confirm, _ = self.run_cli("config-apply", env_confirm=env, tty=tty)
                self.assertEqual(status, 2)
                self.assertEqual(run.call_count, 1)
                lease.assert_not_called()
                confirm.assert_not_called()

    def test_wrong_interactive_confirmation_stops_before_lease(self):
        status, run, lease, *_ = self.run_cli("config-apply", answer="wrong")
        self.assertEqual(status, 2)
        self.assertEqual(run.call_count, 1)
        lease.assert_not_called()

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
